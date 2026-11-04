import Foundation
import Observation

/// What the probe (N161) says about a project's git state, for the Dashboard's git suggestions (N163).
struct GitState: Equatable {
    var isGitRepo: Bool
    var isTopLevel: Bool
    var hasCommits: Bool
    var remote: String?
    /// Commits on the branch that its upstream does not have; nil without an upstream.
    var unpushed: Int?

    init(probe: ProjectProbe) {
        isGitRepo = probe.facts.isGitRepo; isTopLevel = probe.facts.isTopLevel; hasCommits = probe.facts.hasCommits
        remote = probe.remote; unpushed = probe.unpushedCommits
    }

    /// What "Not now" remembers; the suggestion comes back when it is different. Without a remote it is only that there is none, so new
    /// commits (a project that merges many times a day) do not bring it back; with one it is the remote and the unpushed count.
    var pushFingerprint: String { remote.map { "\($0)|\(unpushed.map(String.init) ?? "-")" } ?? "-" }
}

enum GitPushReason: Equatable {
    case noRemote
    case unpushed(Int)
}

/// One git step the panel suggests in Waiting for you. Nothing runs, commits or pushes without the user's click.
enum GitSuggestion: Equatable {
    case initializeGit
    case pushToGitHub(GitPushReason)

    var title: String {
        switch self {
        case .initializeGit: "This folder is not a git repository"
        case .pushToGitHub(.noRemote): "No GitHub remote yet"
        case .pushToGitHub(.unpushed(let n)): n == 1 ? "1 commit not pushed" : "\(n) commits not pushed"
        }
    }

    var detail: String {
        switch self {
        case .initializeGit: "Agents work in git worktrees. Pick the files for the first commit; nothing is pushed."
        case .pushToGitHub(.noRemote): "The panel creates the repository and pushes with your GitHub login; the sheet shows what happens first."
        case .pushToGitHub(.unpushed): "The work on this branch is only on this Mac."
        }
    }
}

/// The suggestions for one project: "Initialize git" for a folder that is not a repository, else "Push to GitHub" when there is no
/// remote or there are commits the remote does not have, unless a G1 card is there already or "Not now" was said to these same facts.
func gitSuggestions(state: GitState?, notNow: String?, githubCardExists: Bool) -> [GitSuggestion] {
    guard let state else { return [] }
    // A subfolder of another repository is not offered git init: it would nest a repository.
    guard state.isGitRepo else { return [.initializeGit] }
    guard state.isTopLevel, state.hasCommits, !githubCardExists, notNow != state.pushFingerprint else { return [] }
    if state.remote == nil { return [.pushToGitHub(.noRemote)] }
    if let n = state.unpushed, n > 0 { return [.pushToGitHub(.unpushed(n))] }
    return []
}

/// Why agents cannot start yet; nil while the folder was not probed or is a repository.
func gitStartReason(state: GitState?) -> String? {
    guard let state, !state.isGitRepo else { return nil }
    return "Initialize git first"
}

/// The git state of each project and the two sheets that act on it: "Initialize git" (create-project.sh --init-git, N162) and
/// "Push to GitHub" (gh and git, N178).
@Observable @MainActor
final class GitSuggestionModel {
    struct InitSheet: Identifiable, Equatable {
        enum Phase: Equatable { case loading, ready, running, failed(String) }
        let project: ProjectConfig
        var files: [String] = []
        var unticked: Set<String> = []
        var phase: Phase = .loading
        var id: String { project.id }
        var ticked: [String] { files.filter { !unticked.contains($0) } }
        /// The script always commits .gitignore (it adds .agent-worktrees/ to it), so it is not in the list it is given: a .gitignore
        /// that is not there yet would be refused as a missing file.
        var listFile: [String] { ticked.filter { $0 != Self.gitignore } }
        static let gitignore = ".gitignore"
    }

    /// "Push to GitHub" (N178): what will happen, then the user's click runs it. Without a remote it creates the repository too.
    struct PushSheet: Identifiable, Equatable {
        enum Phase: Equatable { case loading, ready, running, done(String), failed(String) }
        let project: ProjectConfig
        var phase: Phase = .loading
        var inspection = GitPublisher.Inspection()
        var visibility: GitPublisher.Visibility = .privateRepo
        /// Empty means the signed-in account.
        var owner = ""
        var name: String
        var alsoTags = false
        /// The newest commits that stay on this Mac (N269); 0 pushes them all. Only a prefix of the branch can be pushed.
        var keep = 0
        var id: String { project.id }
        var branch: String { inspection.branch ?? "" }
        var willCreate: Bool { inspection.remoteURL == nil }
        var effectiveOwner: String { owner.isEmpty ? (inspection.login ?? "") : owner }
        var ticksTags: [String] { alsoTags ? inspection.tags : [] }
        var commitList: (shown: [GitPublisher.Commit], more: Int) { GitPublisher.commitList(inspection.commits, total: inspection.commitCount) }
        /// Row `index` of the list (newest first; `commitList.shown.count` is the "and N more" row) goes with the push.
        func isTicked(_ index: Int) -> Bool { index >= keep }
        /// How many commits the button pushes.
        var pushCount: Int { max(0, inspection.commitCount - keep) }
        /// Where a partial push stops; nil pushes the whole branch.
        var upTo: String? { willCreate || keep == 0 ? nil : inspection.commits.indices.contains(keep) ? inspection.commits[keep].sha : nil }
        var choiceText: String { GitPublisher.choiceText(pushed: pushCount, of: inspection.commitCount) }
        /// Why the button is off; nil when it can run.
        var problem: String? {
            if let text = inspection.problem { return text }
            guard willCreate else { return inspection.commitCount > 0 && pushCount == 0 ? "Tick a commit to push it and every older one." : nil }
            if !owner.isEmpty, !GitPublisher.isValidOwner(owner) { return "\"\(owner)\" is not a GitHub user or organisation name." }
            if !GitPublisher.isValidRepoName(name) { return "\"\(name)\" is not a valid repository name." }
            if effectiveOwner.isEmpty { return "The signed-in GitHub account could not be read. Enter an owner." }
            return nil
        }
        var buttonTitle: String {
            willCreate ? GitPublisher.createButtonTitle(owner: effectiveOwner, name: name, branch: branch)
                       : GitPublisher.pushButtonTitle(commits: pushCount, branch: branch, hasUpstream: inspection.hasUpstream)
        }
        var canConfirm: Bool {
            switch phase { case .ready, .failed: problem == nil; default: false }
        }
    }

    static let refreshInterval: TimeInterval = 60

    private(set) var states: [String: GitState] = [:]
    var initSheet: InitSheet?
    var pushSheet: PushSheet?
    /// Nil under XCTest unless a test sets one, so no test probes a real folder by accident.
    @ObservationIgnored var probe: ((String) async -> ProjectProbe)?
    @ObservationIgnored var scripts: () -> ScriptRunning?
    /// Nil under XCTest unless a test sets one, so no test runs a real gh or git push.
    @ObservationIgnored var publisher: (() -> GitPublisher?)?
    @ObservationIgnored var now: () -> Date = { Date() }
    /// After git init or a push: the panel reads the cards again.
    @ObservationIgnored var onChanged: (String) async -> Void = { _ in }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var probedAt: [String: Date] = [:]

    init(defaults: UserDefaults, probe: ((String) async -> ProjectProbe)?, scripts: @escaping () -> ScriptRunning?) {
        self.defaults = defaults; self.probe = probe; self.scripts = scripts
    }

    /// Probes the project again, at most once a minute unless forced (agents commit, so unpushed work changes while the panel is open).
    func refresh(_ project: ProjectConfig, force: Bool = false) async {
        guard let probe else { return }
        if !force, let last = probedAt[project.id], now().timeIntervalSince(last) < Self.refreshInterval { return }
        probedAt[project.id] = now()
        let state = GitState(probe: await probe(project.repoPath))
        if states[project.id] != state { states[project.id] = state }
    }

    func suggestions(for projectID: String, cards: [TaskCard]) -> [GitSuggestion] {
        gitSuggestions(state: states[projectID], notNow: defaults.string(forKey: Self.notNowKey(projectID)), githubCardExists: cards.contains { $0.id == "G1" })
    }

    func startReason(projectID: String) -> String? { gitStartReason(state: states[projectID]) }

    /// "Not now" on Push to GitHub: without a remote, hidden until one appears; with one, until the remote or the unpushed count changes.
    func notNow(_ projectID: String) {
        guard let state = states[projectID] else { return }
        defaults.set(state.pushFingerprint, forKey: Self.notNowKey(projectID))
    }

    static func notNowKey(_ projectID: String) -> String { "gitSuggestion.notNow.\(projectID)" }

    // MARK: Initialize git

    /// Opens the sheet and lists the files a first commit would add (a dry run that writes nothing).
    func openInitGit(_ project: ProjectConfig) async {
        initSheet = InitSheet(project: project)
        guard let runner = scripts() else { return fail("Set \"scriptsDir\" in ~/.config/tentacl/projects.json to initialize git from the panel.") }
        do {
            let result = try await runner.run(.createProject, arguments: ["--existing", "--init-git", "--list-files", project.repoPath])
            guard initSheet?.project.id == project.id else { return }
            guard result.status == 0 else { return fail(Self.message(result)) }
            initSheet?.files = Array(result.stdout.split(separator: "\n").dropFirst().map(String.init))
            initSheet?.phase = .ready
        } catch { fail("The setup script could not run: \(error)") }
    }

    func toggle(_ file: String) {
        guard var sheet = initSheet, sheet.phase == .ready, file != InitSheet.gitignore else { return }
        if sheet.unticked.contains(file) { sheet.unticked.remove(file) } else { sheet.unticked.insert(file) }
        initSheet = sheet
    }

    func setAll(_ ticked: Bool) {
        guard var sheet = initSheet, sheet.phase == .ready else { return }
        sheet.unticked = ticked ? [] : Set(sheet.files.filter { $0 != InitSheet.gitignore })
        initSheet = sheet
    }

    /// git init and the first commit with only the ticked files (and .gitignore). True when it worked; the sheet then closes.
    @discardableResult func confirmInitGit() async -> Bool {
        guard let sheet = initSheet, sheet.phase == .ready || isFailedAfterList(sheet) else { return false }
        guard let runner = scripts() else { fail("Set \"scriptsDir\" in ~/.config/tentacl/projects.json to initialize git from the panel."); return false }
        let project = sheet.project
        initSheet?.phase = .running
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("tentacl-init-git-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        do {
            try sheet.listFile.map { $0 + "\n" }.joined().write(to: list, atomically: true, encoding: .utf8)
            // The project.json and team.json already there are kept; the preset only matters for a new project.json.
            let args = ["--existing", "--init-git", "--branch", project.baseBranch, "--files", list.path, project.repoPath, project.dataDir, project.id, project.name, "other"]
            let result = try await runner.run(.createProject, arguments: args)
            guard result.status == 0 else { fail(Self.message(result)); return false }
        } catch { fail("The setup script could not run: \(error)"); return false }
        initSheet = nil
        await refresh(project, force: true)
        await onChanged(project.id)
        return true
    }

    private func isFailedAfterList(_ sheet: InitSheet) -> Bool { if case .failed = sheet.phase { !sheet.files.isEmpty } else { false } }

    private func fail(_ text: String) { initSheet?.phase = .failed(text) }

    private static func message(_ result: ScriptResult) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "create-project.sh exited with status \(result.status)." : text
    }

    // MARK: Push to GitHub

    /// Opens the sheet and reads what would happen (read-only). `visibility` and `owner` come from Add project's choice.
    func openPush(_ project: ProjectConfig, visibility: GitPublisher.Visibility = .privateRepo, owner: String = "") async {
        var sheet = PushSheet(project: project, name: project.id)
        sheet.visibility = visibility; sheet.owner = owner
        pushSheet = sheet
        guard let publisher = publisher?() else {
            pushSheet?.inspection.problem = "GitHub tools are not available here."
            pushSheet?.phase = .ready
            return
        }
        let found = await publisher.inspect(repoPath: project.repoPath)
        guard pushSheet?.project.id == project.id else { return }
        pushSheet?.inspection = found
        pushSheet?.phase = .ready
    }

    /// A row's checkbox in the push sheet: unticking keeps it and every newer commit, ticking pushes it and every older one.
    func togglePushCommit(_ index: Int) {
        guard var sheet = pushSheet, !sheet.willCreate, sheet.inspection.problem == nil else { return }
        switch sheet.phase { case .ready, .failed: break; default: return }
        let rows = sheet.commitList.shown.count + (sheet.commitList.more > 0 ? 1 : 0)
        guard (0..<rows).contains(index) else { return }
        // The "and N more" row stands for every older commit at once.
        let next = GitPublisher.keepAfterToggle(keep: sheet.keep, index: index)
        sheet.keep = index == sheet.commitList.shown.count && next > index ? sheet.inspection.commitCount : min(next, sheet.inspection.commitCount)
        pushSheet = sheet
    }

    /// The sheet's button: creates the repository (no remote) and pushes. The only way anything reaches GitHub from the panel.
    @discardableResult func confirmPush() async -> Bool {
        guard let sheet = pushSheet, sheet.canConfirm, let publisher = publisher?() else { return false }
        // Never the whole branch when the user kept some commits back.
        guard sheet.willCreate || sheet.keep == 0 || sheet.upTo != nil else { return false }
        pushSheet?.phase = .running
        let create = sheet.willCreate ? (owner: sheet.effectiveOwner, name: sheet.name, visibility: sheet.visibility) : nil
        let outcome = await publisher.publish(repoPath: sheet.project.repoPath, branch: sheet.branch, create: create, hasUpstream: sheet.inspection.hasUpstream,
                                              commits: sheet.upTo == nil ? sheet.inspection.commitCount : sheet.pushCount,
                                              upTo: sheet.upTo, kept: sheet.upTo == nil ? 0 : sheet.keep, tags: sheet.ticksTags)
        guard pushSheet?.project.id == sheet.project.id else { return false }
        switch outcome {
        case .done(let text):
            pushSheet?.phase = .done(text)
            await refresh(sheet.project, force: true)
            await onChanged(sheet.project.id)
            return true
        case .failed(let text):
            pushSheet?.phase = .failed(text)
            return false
        }
    }
}
