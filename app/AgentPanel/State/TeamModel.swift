import Foundation
import Observation

enum SelectionResult: Equatable { case switched, needsConfirmation }

struct SkillChoice: Equatable, Identifiable {
    let name: String
    let kind: SkillEntry.Kind?
    let isSelected: Bool
    /// Named by the role but not installed on this machine.
    let isMissing: Bool
    var id: String { name }
}

/// The Team screen's state: the role lists, the role being edited as a draft, live validation, save and delete, and the launch preview.
@Observable @MainActor
final class TeamModel {
    /// The template picker sheet on the Team screen (open while it has a location); here so quitting can close it.
    var templateLocation: NewRoleLocation?
    enum NewRoleLocation { case base, project }

    private(set) var groups: [(title: String, roles: [ResolvedRole])] = []
    private(set) var loadProblems: [String] = []
    private(set) var selectedRole: ResolvedRole?
    private(set) var isNew = false
    private(set) var pendingDelete: ResolvedRole?
    private(set) var saveError: String?
    private(set) var preview: LaunchPreview?
    /// The models `codex debug models` lists (empty with a reason until loaded, or when codex is missing).
    private(set) var codexModels = CodexCatalog()
    var draft = RoleDraft()
    /// The selected role was changed on disk (outside the app) while the form has unsaved edits: they stay, and the Team screen offers Reload or Keep mine.
    private(set) var diskChanged = false
    var project: ProjectConfig? { didSet { chart.project = project } }
    /// The team chart of the current project.
    let chart: TeamChartModel
    /// Set when the selected role is in the project's team chart: what deleting it will also do.
    var pendingDeleteWarning: String? {
        guard pendingDelete != nil, let role = pendingDelete?.config.name, chart.savedChart?.member(role) != nil else { return nil }
        return "This role is in the team chart. It will be removed from the chart too, and the roles that report to it will report to its manager."
    }

    @ObservationIgnored private var savedDraft = RoleDraft()
    /// The on-disk version of the selected role that "Keep mine" answered; the banner returns only when the file changes again.
    @ObservationIgnored private var keptDisk: RoleDraft?
    @ObservationIgnored private var diskState: [String: Date] = [:]
    @ObservationIgnored private var newLocation: NewRoleLocation = .base
    @ObservationIgnored private let store: RoleStore
    @ObservationIgnored private let catalog: SkillCatalog
    @ObservationIgnored private let claudeHome: URL
    @ObservationIgnored private let makeScripts: (URL) -> ScriptRunning?
    @ObservationIgnored private let codexCatalog: CodexModelCatalog
    /// The Claude-only fields put aside while the draft is a Codex role, so switching back gives them again.
    @ObservationIgnored private var claudeFields: RoleDraft?
    @ObservationIgnored private var baseRoles: [ResolvedRole] = []
    @ObservationIgnored private var projectRoles: [ResolvedRole] = []

    init(store: RoleStore = RoleStore(), catalog: SkillCatalog = SkillCatalog(), claudeHome: URL = SkillCatalog().claudeHome,
         makeScripts: @escaping (URL) -> ScriptRunning?, project: ProjectConfig? = nil, chartStore: TeamChartStore = TeamChartStore(),
         codexCatalog: CodexModelCatalog = CodexModelCatalog()) {
        self.chart = TeamChartModel(store: chartStore, roleStore: store)
        self.chart.project = project
        self.store = store; self.catalog = catalog; self.claudeHome = claudeHome; self.makeScripts = makeScripts; self.project = project
        self.codexCatalog = codexCatalog
    }

    // MARK: loading and selecting

    /// First launch: creates the default roles when the shared folder does not exist, then reads everything.
    func load(seed: Bool = true) {
        if seed { RoleSeeder.seedIfMissing(baseDir: store.baseDir) }
        reload()
    }

    /// Every file in the roles folders with its modification time: a change here means the folders were edited.
    private func diskSignature() -> [String: Date] {
        var out: [String: Date] = [:]
        let folders = [store.baseDir] + (project.flatMap { store.projectRolesDir($0) }.map { [$0] } ?? [])
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let path = folder.appendingPathComponent(name).path
                out[path] = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            }
        }
        return out
    }

    /// Reads the role files again when something in the roles folders changed since the last read (the Team screen calls this when it
    /// opens and every couple of seconds while it is open). The open role follows the file, unless the form has unsaved edits: those are
    /// never overwritten, `diskChanged` is set instead.
    func refreshFromDisk() {
        guard diskSignature() != diskState else { return }
        let before = selectedRole
        reload()
        guard !isNew, before != nil, let fresh = selectedRole else { return }
        let onDisk = RoleDraft(role: fresh, instructions: store.instructions(of: fresh))
        guard onDisk != savedDraft else { return }
        if isDirty { diskChanged = onDisk != keptDisk } else { open(fresh) }
    }

    /// "Reload": the form shows the file again, the unsaved edits are dropped.
    func reloadFromDisk() {
        guard let role = selectedRole else { return }
        open(role)
    }

    /// "Keep mine": the edits stay, and the banner goes until the file changes again.
    func keepMine() {
        guard let role = selectedRole else { return }
        keptDisk = RoleDraft(role: role, instructions: store.instructions(of: role)); diskChanged = false
    }

    func reload() {
        diskState = diskSignature()
        if !chart.isDirty { chart.reload() }   // unsaved chart edits survive saving a role
        let base = store.baseRoles()
        baseRoles = base.roles
        loadProblems = base.problems
        var result: [(title: String, roles: [ResolvedRole])] = [("Base roles", base.roles)]
        if let project {
            let own = store.projectRoles(project)
            projectRoles = own.roles
            loadProblems += own.problems
            result.append(("Only in \(project.name)", own.roles))
        } else {
            projectRoles = []
        }
        groups = result
        if let current = selectedRole, !isNew {
            if let fresh = (baseRoles + projectRoles).first(where: { $0.fileURL == current.fileURL }) { selectedRole = fresh }
            else { selectedRole = nil; draft = RoleDraft(); savedDraft = draft; preview = nil; pendingDelete = nil }   // the role is no longer listed (another project)
        }
    }

    /// "Overridden in <project>" for a shared role that the project replaces with a role of the same name.
    func shadowNote(for role: ResolvedRole) -> String? {
        guard role.source == .base, let project, projectRoles.contains(where: { $0.config.name == role.config.name }) else { return nil }
        return "Overridden in \(project.name)"
    }

    var isDirty: Bool { draft != savedDraft }

    /// The fields of the draft that differ from the saved role (or the empty form of a new one).
    var unsavedChangeCount: Int { draft.changeCount(from: savedDraft) }

    /// The role list's search text: a role is shown when its name, display name, model (as the list shows it) or one of its skills contains it.
    var roleQuery = ""

    /// `groups` narrowed by `roleQuery`; every group stays so its heading does.
    var filteredGroups: [(title: String, roles: [ResolvedRole])] {
        let q = roleQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        func has(_ text: String) -> Bool { text.range(of: q, options: .caseInsensitive) != nil }
        return groups.map { group in
            (group.title, group.roles.filter { r in has(r.config.name) || has(r.config.displayName ?? "") || has(listModel(for: r)) || r.config.skills.contains(where: has) })
        }
    }

    /// Unsaved edits to the role form or to the team chart.
    var hasUnsavedChanges: Bool { isDirty || chart.isDirty }

    func revertAll() { revert(); chart.revert() }

    func select(_ role: ResolvedRole) -> SelectionResult {
        if !isNew, role.fileURL == selectedRole?.fileURL { return .switched }
        if isDirty { return .needsConfirmation }
        open(role)
        return .switched
    }

    func discardAndSelect(_ role: ResolvedRole) { open(role) }

    @discardableResult
    func newRole(in location: NewRoleLocation) -> SelectionResult {
        if isDirty { return .needsConfirmation }
        startNewRole(in: location)
        return .switched
    }

    func discardAndNewRole(in location: NewRoleLocation) { startNewRole(in: location) }

    /// A new role whose form starts filled from a template (asks first when there are unsaved edits).
    @discardableResult
    func newRole(from template: RoleTemplate, in location: NewRoleLocation) -> SelectionResult {
        if isDirty { return .needsConfirmation }
        startNewRole(in: location, template: template)
        return .switched
    }

    /// The "add the missing role" offer: a new role in the shared library, its form filled from the template of that name (nil when there is none).
    @discardableResult
    func addRoleFromTemplate(named id: String) -> SelectionResult? {
        guard let template = RoleTemplates.all.first(where: { $0.id == id && $0.id != "empty" }) else { return nil }
        return newRole(from: template, in: .base)
    }

    func discardAndNewRole(from template: RoleTemplate, in location: NewRoleLocation) { startNewRole(in: location, template: template) }

    /// "Duplicate" on the Roster: a template holding a copy of `role` under a free name (no display name), and where the copy goes
    /// (a project's or mapped role's copy goes to the project). Start it with `newRole(from:in:)`.
    func duplicate(of role: ResolvedRole) -> (template: RoleTemplate, location: NewRoleLocation) {
        let location: NewRoleLocation = role.source == .base || project == nil ? .base : .project
        let siblings = location == .base ? baseRoles : projectRoles
        var draft = RoleDraft(role: role, instructions: store.instructions(of: role))
        draft.name = TeamRoster.copyName(of: role.config.name, taken: Set(siblings.map(\.config.name)))
        draft.displayName = ""
        return (RoleTemplate(id: "copy-\(role.id)", title: draft.name, summary: "", draft: draft), location)
    }

    private func startNewRole(in location: NewRoleLocation, template: RoleTemplate? = nil) {
        if location == .project, project == nil { return }
        diskChanged = false; selectedRole = nil; isNew = true; newLocation = location
        draft = RoleDraft(); savedDraft = RoleDraft(); saveError = nil; preview = nil; claudeFields = nil
        draft.instructions = ""
        savedDraft = draft
        draft.name = ""   // a new role starts dirty only once something is typed
        if let template { draft = template.draft }   // a filled template is saveable at once; it carries no link to the template
    }

    func revert() { draft = savedDraft; saveError = nil; claudeFields = nil }

    /// A base role the selected project does not define yet: "Override for <project>" makes a project copy of it.
    var canOverride: Bool {
        guard !isNew, let role = selectedRole, role.source == .base, project != nil else { return false }
        return !projectRoles.contains { $0.config.name == role.config.name }
    }

    /// Starts a new role of the project with the base role's fields (the edits made so far included); saving it shadows the base role here only.
    func overrideForProject() {
        guard canOverride else { return }
        let copy = draft
        startNewRole(in: .project)
        draft = copy
    }

    private func open(_ role: ResolvedRole) {
        selectedRole = role; isNew = false; saveError = nil; preview = nil; claudeFields = nil; diskChanged = false; keptDisk = nil
        draft = RoleDraft(role: role, instructions: store.instructions(of: role))
        savedDraft = draft
    }

    // MARK: editing state

    var isEditable: Bool { isNew || (selectedRole?.isEditable ?? false) }

    var readOnlyReason: String? {
        guard let role = selectedRole, !role.isEditable, !isNew else { return nil }
        return "This role is listed in the \"roles\" section of the project's project.json. Edit the file there: \(role.fileURL.path)"
    }

    /// Everything wrong or worth knowing about the draft, updated as the form changes.
    var problems: [RoleProblem] {
        let (config, parse) = draft.config()
        var out = RoleValidator.problems(for: config, knownStyles: styleNames, codexEfforts: codexModels.efforts(for: draft.model)) + parse
        if isCodex, !codexModels.models.isEmpty, !draft.model.trimmingCharacters(in: .whitespaces).isEmpty {
            if let listed = codexModels.models.first(where: { $0.id == draft.model }) {
                if !listed.efforts.contains(draft.effort) { out.append(RoleProblem(field: "effort", message: "\(listed.label) does not list the effort \"\(draft.effort)\"; it offers \(listed.efforts.joined(separator: ", ")).", severity: .warning)) }
            } else {
                out.append(RoleProblem(field: "model", message: "Codex does not list the model \"\(draft.model)\" on this machine.", severity: .warning))
            }
        }
        if nameClashes { out.append(RoleProblem(field: "name", message: "A role with this name already exists here.", severity: .error)) }
        return out
    }

    private var nameClashes: Bool {
        guard RoleValidator.validName(draft.name), isNew || draft.name != selectedRole?.config.name else { return false }
        let siblings: [ResolvedRole]
        if isNew { siblings = newLocation == .base ? baseRoles : projectRoles } else { siblings = selectedRole?.source == .base ? baseRoles : projectRoles }
        return siblings.contains { $0.config.name == draft.name }
    }

    var saveDisabledReason: String? {
        if let readOnlyReason { return readOnlyReason }
        if selectedRole == nil && !isNew { return "Select a role first." }
        if problems.contains(where: { $0.severity == .error }) { return "Fix the problems above first." }
        if !isDirty { return "There are no changes to save." }
        return nil
    }

    // MARK: save and delete

    func save() async {
        guard saveDisabledReason == nil else { return }
        let location: RoleLocation
        switch (isNew ? newLocation : (selectedRole?.source == .base ? .base : .project)) {
        case .base: location = .base
        case .project:
            guard let project else { saveError = "No project is selected."; return }
            location = .project(project)
        }
        let (config, _) = draft.config()
        do {
            let saved = try RoleWriter(store: store).save(config, instructions: draft.instructions, at: location, replacing: isNew ? nil : selectedRole)
            reload()
            let fresh = (baseRoles + projectRoles).first { $0.fileURL.standardizedFileURL == saved.fileURL.standardizedFileURL } ?? saved
            open(fresh)
        } catch {
            saveError = Self.message(for: error)
        }
    }

    func requestDelete() {
        guard !isNew, let role = selectedRole, role.isEditable else { return }
        pendingDelete = role
    }

    func cancelDelete() { pendingDelete = nil }

    func confirmDelete() async {
        guard let role = pendingDelete else { return }
        pendingDelete = nil
        let list = (role.source == .base ? baseRoles : projectRoles)
        let index = list.firstIndex { $0.fileURL == role.fileURL } ?? 0
        // A role in the team chart leaves the chart first: if the chart cannot be written, the role stays.
        // (A role of the same name that stays resolvable, e.g. the shared one under a project role, keeps its place in the chart.)
        let name = role.config.name
        let stillThere = (baseRoles + projectRoles).contains { $0.config.name == name && $0.fileURL != role.fileURL }
        let prior = chart.savedChart
        var chartChanged = false
        if let saved = prior, saved.member(name) != nil, !stillThere {
            if chart.isDirty { saveError = "Save or revert your chart changes first; deleting this role also changes the chart."; return }
            if let failure = chart.write(saved.removing(role: name)) { saveError = failure; return }
            chartChanged = true
        }
        do { try RoleWriter(store: store).delete(role, project: project) } catch {
            if chartChanged, let prior { _ = chart.write(prior) }   // the role stayed, so the chart gets it back
            saveError = Self.message(for: error); return
        }
        reload()
        let remaining = role.source == .base ? baseRoles : projectRoles
        if remaining.isEmpty { selectedRole = nil; draft = RoleDraft(); savedDraft = draft; preview = nil }
        else { open(remaining[min(index, remaining.count - 1)]) }
    }

    static func message(for error: Error) -> String {
        switch error as? RoleWriteError {
        case .invalidName?: return "The name must be lowercase letters, digits or _, starting with a letter."
        case .readOnly?: return "This role is read-only."
        case .outsideRolesFolder?: return "The role is not in a folder the panel may write to."
        case .isSymlink?: return "A role file or folder is a symbolic link; the panel does not write through it."
        case .problems(let p)?: return p.map { "\($0.field): \($0.message)" }.joined(separator: " ")
        case .exists?: return "A role with this name already exists here."
        case .writeFailed(let m)?: return "The role could not be saved: \(m)"
        case nil: return error.localizedDescription
        }
    }

    // MARK: agent program (Claude Code or Codex)

    var isCodex: Bool { draft.tool == "codex" }

    /// The programs the role may run on.
    var toolOptions: [String] { RoleValidator.tools }

    static func toolLabel(_ tool: String) -> String { tool == "codex" ? "Codex" : "Claude Code" }

    /// What the role list shows for a role: the selected role shows the form's (unsaved) values, the others their file.
    func listModel(for role: ResolvedRole) -> String { isListedDraft(role) ? draft.model : role.config.model }
    func listIsCodex(for role: ResolvedRole) -> Bool { (isListedDraft(role) ? draft.tool : role.config.tool) == "codex" }
    private func isListedDraft(_ role: ResolvedRole) -> Bool { !isNew && selectedRole?.fileURL == role.fileURL }

    /// The model picker's list: Claude's aliases and versions, or the models Codex lists.
    var modelChoices: [ModelChoice] { isCodex ? codexModels.choices : ModelCatalog.claude }

    var modelLabel: String { isCodex ? (codexModels.models.first { $0.id == draft.model }?.label ?? draft.model) : ModelCatalog.label(for: draft.model) }

    /// For Codex: the efforts the model lists that the role file accepts (all of them when the model is not listed).
    var effortOptions: [String] {
        guard isCodex else { return RoleValidator.efforts }
        let listed = codexModels.efforts(for: draft.model)
        return listed.isEmpty ? RoleValidator.codexEfforts : listed
    }

    var permissionModeOptions: [String] { isCodex ? RoleValidator.codexPermissionModes : RoleValidator.permissionModes }

    /// What a permission mode means for a Codex agent (the flags spawn-agent.sh gives it).
    static func codexMeaning(of mode: String) -> String {
        switch mode {
        case "manual": return "Read only sandbox; asks before every edit and command (-s read-only -a on-request)."
        case "plan": return "Read only: it can look and plan but change nothing (-s read-only -a on-request, told \"Plan only: do not edit files\")."
        case "bypassPermissions": return "No sandbox and it never asks (--dangerously-bypass-approvals-and-sandbox). Only for a role you fully trust."
        default: return "Edits in the worktree, asks when it needs more (-s workspace-write -a on-request). The sandbox leaves the network open."
        }
    }

    func loadCodexModels(refresh: Bool = false) async {
        codexModels = await codexCatalog.load(refresh: refresh)
        // Codex was picked before its models were known: the first listed model fills the empty field.
        if isCodex, draft.model.isEmpty, let first = codexModels.models.first { draft.model = first.id; draft.effort = defaultEffort(of: first) }
    }

    /// Switches the draft between Claude Code and Codex. Codex gets its first listed model and a mode it knows; the Claude-only
    /// fields (skills, allowed tools, advanced, model, effort, mode) are put aside and come back when switching back.
    func setTool(_ tool: String) {
        guard tool != draft.tool, toolOptions.contains(tool) else { return }
        if tool == "codex" {
            claudeFields = draft
            draft.tool = tool; draft.skills = []; draft.allowedTools = []; draft.advancedText = ""
            let first = codexModels.models.first
            draft.model = first?.id ?? ""
            draft.effort = first.map(defaultEffort) ?? "medium"
            if !RoleValidator.codexPermissionModes.contains(draft.permissionMode) { draft.permissionMode = "acceptEdits" }
        } else {
            let kept = claudeFields ?? RoleDraft()
            draft.tool = tool; draft.skills = kept.skills; draft.allowedTools = kept.allowedTools; draft.advancedText = kept.advancedText
            draft.model = kept.model; draft.effort = kept.effort; draft.permissionMode = kept.permissionMode
            claudeFields = nil
        }
    }

    /// Picks a model; for Codex an effort the new model does not offer becomes its default effort.
    func setModel(_ id: String) {
        draft.model = id
        guard isCodex, !effortOptions.contains(draft.effort) else { return }
        draft.effort = codexModels.models.first { $0.id == id }.map(defaultEffort) ?? effortOptions[0]
    }

    private func defaultEffort(of model: CodexModel) -> String {
        return model.efforts.contains(model.defaultEffort) ? model.defaultEffort : (model.efforts.first ?? "medium")
    }

    // MARK: tools

    struct ToolChoice: Equatable, Identifiable { let name: String; let summary: String; let isSelected: Bool; var id: String { name } }

    func toolChoices() -> [ToolChoice] {
        ToolCatalog.claude.map { ToolChoice(name: $0.name, summary: $0.summary, isSelected: draft.allowedTools.contains($0.name)) }
    }

    /// The output styles the picker offers (the role's own value is added when it is not among them, so it is never lost).
    var styleNames: [String] { OutputStyleCatalog(claudeHome: claudeHome, repo: project?.repoURL).names() }

    func toggleTool(_ name: String) { draft.toggleTool(name) }

    // MARK: skills

    func toggleSkill(_ name: String) {
        if let i = draft.skills.firstIndex(of: name) { draft.skills.remove(at: i) } else { draft.skills.append(name) }
    }

    func skillEntries(matching query: String = "") -> [SkillChoice] {
        let installed = catalog.installed()
        var choices: [SkillChoice] = []
        var seen = Set<String>()
        for entry in installed where seen.insert(entry.name).inserted {
            choices.append(SkillChoice(name: entry.name, kind: entry.kind, isSelected: draft.skills.contains(entry.name), isMissing: false))
        }
        for name in draft.skills where seen.insert(name).inserted { choices.append(SkillChoice(name: name, kind: nil, isSelected: true, isMissing: true)) }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? choices : choices.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }

    // MARK: preview

    /// What the preview adds to the problems the form already lists (a missing skill, a script failure).
    var previewNotes: [String] {
        let shown = Set(problems.map { "\($0.field): \($0.message)" })
        return (preview?.problems ?? []).filter { !shown.contains($0) }
    }

    func refreshPreview() async {
        guard selectedRole != nil || isNew else { preview = nil; return }
        guard makeScripts(URL(fileURLWithPath: NSTemporaryDirectory())) != nil else {
            var p = LaunchPreview()
            p.problems = ["Set \"scriptsDir\" in ~/.config/tentacl/projects.json to see what will be started."]
            p.tool = draft.tool
            if !isCodex { p.overrides = ClaudeSettingsSummary.lines(claudeHome: claudeHome, repo: project?.repoURL, roleSkills: draft.skills) }
            preview = p
            return
        }
        let snapshot = (draft, selectedRole?.fileURL, isNew)
        let (config, parse) = draft.config()
        if !parse.isEmpty {   // the Advanced text is broken: a preview built without it would not show what a start uses
            var p = LaunchPreview()
            p.tool = draft.tool
            if !isCodex { p.overrides = ClaudeSettingsSummary.lines(claudeHome: claudeHome, repo: project?.repoURL, roleSkills: draft.skills) }
            preview = p
            return
        }
        var result = await makePreview(draft: config, instructions: draft.instructions, project: project, makeScripts: { state in self.makeScripts(state) ?? NoScripts() }, catalog: catalog, claudeHome: claudeHome)
        // An older, slower run must not overwrite the preview of what the form says now.
        guard snapshot.0 == draft, snapshot.1 == selectedRole?.fileURL, snapshot.2 == isNew else { return }
        preview = result
    }
}

/// Stands in when scripts are not configured (the preview checks that first, so this never runs).
/// What a role is doing in the selected project: its live agents and its finished cards, for the Team screen's header and list dots.
struct RoleActivity: Equatable { var running = 0; var done = 0 }

/// Agent names are `<role>-<task>…` and role names have no "-": a live agent counts for the text before its first "-". A done card counts
/// for its agent's role, else the first role it asks for, else `dev` (the default role).
func roleActivity(cards: [TaskCard], agents: [AgentStatus]) -> [String: RoleActivity] {
    func role(of agent: String) -> String? { agent.firstIndex(of: "-").map { String(agent[..<$0]) } }
    var out: [String: RoleActivity] = [:]
    for agent in agents { if let name = agent.name, let r = role(of: name) { out[r, default: RoleActivity()].running += 1 } }
    for card in cards where card.status == .done {
        let r = card.agent.flatMap(role(of:)) ?? card.roles.first ?? "dev"
        out[r, default: RoleActivity()].done += 1
    }
    return out
}

private struct NoScripts: ScriptRunning {
    func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { throw ScriptError.notConfigured(script.rawValue) }
}
