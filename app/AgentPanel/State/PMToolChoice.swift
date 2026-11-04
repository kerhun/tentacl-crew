import Foundation
import Observation

/// What the "PM runs on" picker knows about the two tools (N367).
struct PMToolStatus: Equatable, Sendable {
    var installed: Set<AgentTool> = []
    var signedIn: Set<AgentTool> = []
    /// Codex's models (a Codex PM needs one); empty with a reason when codex cannot list them.
    var codexModels = CodexCatalog()

    /// The live answer: both tools looked up, signed in asked (bounded), Codex's models listed when codex is there.
    static func live(probes: SetupProbes, catalog: CodexModelCatalog = CodexModelCatalog()) async -> PMToolStatus {
        var status = PMToolStatus()
        for tool in [AgentTool.claude, .codex] where probes.findTool(tool.rawValue) != nil { status.installed.insert(tool) }
        async let claude = SetupCheck.signedIn(.claude, probes: probes)
        async let codex = SetupCheck.signedIn(.codex, probes: probes)
        if await claude == true { status.signedIn.insert(.claude) }
        if await codex == true { status.signedIn.insert(.codex) }
        if status.installed.contains(.codex) { status.codexModels = await catalog.load() }
        return status
    }
}

/// The PM's tool lives in the project's own pm role (`tool`); a project without one uses the shared pm role, as before.
enum PMToolChoice {
    /// The signed-in tool; Claude when both or neither are.
    static func defaultTool(_ status: PMToolStatus) -> AgentTool {
        status.signedIn.contains(.codex) && !status.signedIn.contains(.claude) ? .codex : .claude
    }

    /// Why `tool` cannot be picked, or nil when it can.
    static func disabledReason(_ tool: AgentTool, _ status: PMToolStatus) -> String? {
        let name = tool == .claude ? "Claude Code" : "Codex"
        guard status.installed.contains(tool) else { return "\(name) is not installed (Setup installs it)." }
        if tool == .codex, status.codexModels.models.isEmpty { return "Codex lists no models" + (status.codexModels.reason.map { ": \($0)." } ?? ".") }
        return nil
    }

    /// The tool the project's PM runs on now (the resolved pm role; Claude when it has no `tool` or cannot be found).
    static func current(project: ProjectConfig, store: RoleStore) -> AgentTool {
        store.resolve("pm", in: project).role?.config.tool == "codex" ? .codex : .claude
    }

    enum ChangeError: Error, Equatable { case readOnly, noCodexModel, write(String) }

    /// The project's pm role on `tool`, or nil when the PM already runs on it (then nothing is written).
    /// Codex: the first Codex model and its default effort, `acceptEdits`, no Claude-only fields. Claude: the shared pm role's Claude settings.
    static func role(for tool: AgentTool, project: ProjectConfig, store: RoleStore, codexModels: CodexCatalog) throws -> (config: RoleConfig, instructions: String, replacing: ResolvedRole?)? {
        guard tool != current(project: project, store: store) else { return nil }
        let resolved = store.resolve("pm", in: project).role
        if let resolved, !resolved.isEditable { throw ChangeError.readOnly }
        let shared = store.baseRoles().roles.first { $0.config.name == "pm" }
        var config = resolved?.config ?? shared?.config ?? Self.template
        config.name = "pm"
        switch tool {
        case .codex:
            guard let model = codexModels.models.first else { throw ChangeError.noCodexModel }
            config.tool = "codex"; config.model = model.id
            config.effort = model.efforts.contains(model.defaultEffort) ? model.defaultEffort : (model.efforts.first ?? "medium")
            config.permissionMode = "acceptEdits"; config.skills = []; config.allowedTools = []; config.advanced = nil
            config.thinking = nil; config.language = nil
        case .claude:
            let claude = shared.map(\.config).flatMap { $0.tool == "claude" ? $0 : nil } ?? Self.template
            config.tool = "claude"; config.model = claude.model; config.effort = claude.effort; config.permissionMode = claude.permissionMode
            config.skills = claude.skills; config.allowedTools = claude.allowedTools; config.advanced = claude.advanced; config.outputStyle = claude.outputStyle
            config.thinking = claude.thinking; config.language = claude.language
        }
        let instructions = resolved.map { store.instructions(of: $0) } ?? shared.map { store.instructions(of: $0) } ?? ""
        return (config, instructions, resolved?.source == .project ? resolved : nil)
    }

    /// Writes the project's pm role through `RoleWriter`; false when nothing had to change.
    @discardableResult
    static func apply(_ tool: AgentTool, project: ProjectConfig, store: RoleStore, codexModels: CodexCatalog) throws -> Bool {
        guard let change = try role(for: tool, project: project, store: store, codexModels: codexModels) else { return false }
        do { _ = try RoleWriter(store: store).save(change.config, instructions: change.instructions, at: .project(project), replacing: change.replacing) }
        catch { throw ChangeError.write("\(error)") }
        return true
    }

    /// The shipped pm role (examples/roles/pm.json), for a project with no pm role anywhere.
    static let template = RoleConfig(name: "pm", kind: "interactive", tool: "claude", model: "opus", effort: "high", permissionMode: "manual",
                                     outputStyle: "concise", allowedTools: ["Read", "Bash"], skills: ["superpowers"], instructionFile: "pm.md", displayName: nil, advanced: nil)

    static func describe(_ error: Error) -> String {
        switch error as? ChangeError {
        case .readOnly?: return "The pm role of this project is set in project.json's \"roles\" and cannot be changed here."
        case .noCodexModel?: return "Codex lists no models, so the PM cannot be set to Codex."
        case .write(let why)?: return "The pm role could not be written: \(why)"
        case nil: return "\(error)"
        }
    }
}

/// The "PM runs on" picker of Add project and Edit project.
@Observable @MainActor
final class PMToolPicker {
    /// The tool the PM runs on now (Add project: Claude, the default of a new project).
    let current: AgentTool
    var choice: AgentTool { didSet { if choice != oldValue { touched = true } } }
    private(set) var status: PMToolStatus?
    /// The PM of this project runs now: a change applies at its next start.
    let pmRunning: Bool
    /// Add project: the choice follows the signed-in tool until the user picks one.
    @ObservationIgnored private let followsDefault: Bool
    @ObservationIgnored private var touched = false
    @ObservationIgnored private let loadStatus: @Sendable () async -> PMToolStatus
    @ObservationIgnored let rules: CodexRules

    init(current: AgentTool, followsDefault: Bool, pmRunning: Bool = false, rules: CodexRules = CodexRules(),
         status: @escaping @Sendable () async -> PMToolStatus) {
        self.current = current; self.choice = current; self.followsDefault = followsDefault; self.pmRunning = pmRunning
        self.rules = rules; self.loadStatus = status
    }

    func load() async {
        let found = await loadStatus()
        status = found
        if followsDefault, !touched {
            let tool = PMToolChoice.defaultTool(found)
            if PMToolChoice.disabledReason(tool, found) == nil { choice = tool; touched = false }
        }
    }

    /// Why an option is disabled (nil while the check runs, and for the tool the PM already uses).
    func reason(_ tool: AgentTool) -> String? {
        guard let status, tool != current else { return nil }
        return PMToolChoice.disabledReason(tool, status)
    }

    var changed: Bool { choice != current }
    var restartNote: String? { pmRunning && changed ? "Restart the PM to switch: it keeps running on \(current == .claude ? "Claude Code" : "Codex") until then." : nil }
    /// Codex is picked and `~/.codex/AGENTS.md` lacks the user's Claude rules: the sheet offers to copy them.
    var offersRules: Bool { choice == .codex && rules.needsOffer }

    /// Writes the choice into the project's pm role (nothing when it did not change).
    func apply(to project: ProjectConfig, store: RoleStore) throws {
        guard changed else { return }
        try PMToolChoice.apply(choice, project: project, store: store, codexModels: status?.codexModels ?? CodexCatalog())
    }
}
