import Foundation
import Observation

/// What git says about a worktree folder: its branch, whether it has uncommitted work, whether the branch is merged into the main branch.
struct WorktreeState: Equatable {
    var branch: String?
    var dirty: Bool
    var merged: Bool
}

/// One leftover: a worktree folder, a terminal agent, or both together. Nothing here is removed until the user confirms the sheet.
struct CleanupItem: Identifiable, Equatable {
    let id: String
    let projectID: String
    let projectName: String
    let agent: String?
    let worktreePath: String?
    let branch: String?
    let steps: [String]
    /// Why it is listed but not offered (uncommitted or unmerged work); nil when it can be cleaned up.
    let blocked: String?
    let hasSimulator: Bool
    /// Where an agent without a worktree folder is running (what `stop-agent.sh` finds its terminal workspace by).
    var cwd: String? = nil
    /// The terminal pane of the agent when listed; the confirm checks it is still the same session.
    var paneID: String? = nil
    var isOffered: Bool { blocked == nil }
}

/// Settings, "Clean up…": agents and worktrees that outlived their card (a card closed by hand, a crash). `scan()` only reads;
/// `runCleanup()` runs one `stop-agent.sh` per selected item.
@Observable @MainActor
final class CleanupFlow {
    enum Phase: Equatable { case idle, scanning, ready, running }

    private(set) var items: [CleanupItem] = []
    private(set) var phase: Phase = .idle
    private(set) var failures: [String] = []
    /// Things that worked but need a look (a branch that was kept).
    private(set) var warnings: [String] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var scanError: String?

    @ObservationIgnored private let projects: [ProjectConfig]
    @ObservationIgnored private let cards: (ProjectConfig) -> [TaskCard]
    @ObservationIgnored private let folders: (ProjectConfig) -> [String]
    @ObservationIgnored private let adapter: TerminalListing
    @ObservationIgnored private let inspect: (ProjectConfig, String) async -> WorktreeState
    @ObservationIgnored private let scripts: ScriptRunning

    init(projects: [ProjectConfig], cards: @escaping (ProjectConfig) -> [TaskCard], folders: @escaping (ProjectConfig) -> [String], adapter: TerminalListing,
         inspect: @escaping (ProjectConfig, String) async -> WorktreeState, scripts: ScriptRunning) {
        self.projects = projects; self.cards = cards; self.folders = folders; self.adapter = adapter; self.inspect = inspect; self.scripts = scripts
    }

    var offered: [CleanupItem] { items.filter(\.isOffered) }
    var selectedCount: Int { items.filter { selectedIDs.contains($0.id) }.count }

    func toggle(_ item: CleanupItem) {
        guard item.isOffered else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    /// Reads the cards, the worktree folders and the terminal's agents; changes nothing.
    func scan() async {
        phase = .scanning; scanError = nil; failures = []; warnings = []
        var agents: [AgentStatus] = []
        do { agents = try await adapter.agents() } catch { scanError = "the terminal could not be asked, so only worktrees are listed." }
        var found: [CleanupItem] = []
        for project in projects {
            let running = cards(project).filter { $0.status.holdsAgent }
            let runningAgents = Set(running.compactMap(\.agent))
            let runningFolders = Set(running.compactMap { $0.branch.map(StartTaskFlow.worktreeFolder) })
            let root = project.worktreesURL.standardizedFileURL.path + "/"
            var byFolder: [String: AgentStatus] = [:], loose: [AgentStatus] = []
            for agent in agents {
                guard let name = agent.name, agent.cwd.hasPrefix(root) else { continue }
                let folder = String(agent.cwd.dropFirst(root.count).prefix { $0 != "/" })
                if runningAgents.contains(name) || runningFolders.contains(folder) { continue }
                if folders(project).contains(folder) { byFolder[folder] = agent } else { loose.append(agent) }
            }
            for folder in folders(project).sorted() where !runningFolders.contains(folder) {
                let state = await inspect(project, folder)
                let path = project.worktreesURL.appendingPathComponent(folder).path
                let agent = byFolder[folder]?.name, pane = byFolder[folder]?.paneID
                var steps = agent == nil ? [] : ["Close the agent"]
                steps.append("Remove the worktree")
                var blocked: String?
                if state.dirty { blocked = "Has uncommitted changes; kept." }
                else if state.branch == nil || !state.merged { blocked = "Its branch is not merged into \(project.baseBranch); kept." }
                else if let branch = state.branch { steps.append("Delete the branch \(branch) (merged into \(project.baseBranch))") }
                found.append(CleanupItem(id: "\(project.id):\(folder)", projectID: project.id, projectName: project.name, agent: agent, worktreePath: path,
                                         branch: state.branch, steps: steps, blocked: blocked, hasSimulator: project.simulator != nil, paneID: pane))
            }
            for agent in loose {
                guard let name = agent.name else { continue }
                found.append(CleanupItem(id: "\(project.id):agent:\(name)", projectID: project.id, projectName: project.name, agent: name, worktreePath: nil,
                                         branch: nil, steps: ["Close the agent"], blocked: nil, hasSimulator: project.simulator != nil, cwd: agent.cwd, paneID: agent.paneID))
            }
        }
        items = found
        selectedIDs = Set(found.filter(\.isOffered).map(\.id))
        phase = .ready
    }

    /// Why an item must not be removed any more, or nil. Looks again at the folder, the cards and the agents, because the scan can be old.
    private func changedSinceScan(_ item: CleanupItem, agents: [AgentStatus]?) async -> String? {
        guard let project = projects.first(where: { $0.id == item.projectID }) else { return "its project is gone" }
        guard let agents else { return "the terminal could not be asked" }
        let root = project.worktreesURL.standardizedFileURL.path + "/"
        let folder = item.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let session = agents.first { a in
            guard let name = a.name else { return false }
            if let folder { return a.cwd.hasPrefix(root) && String(a.cwd.dropFirst(root.count).prefix { $0 != "/" }) == folder && (item.agent == nil || name == item.agent) }
            return name == item.agent
        }
        if session?.name != item.agent || session?.paneID != item.paneID { return "its agent session changed" }
        guard let folder else { return nil }
        if let branch = item.branch, cards(project).contains(where: { ($0.status == .todo || $0.status == .awaitingStartApproval) && $0.branch == branch }) { return "a task is about to start on it" }
        let state = await inspect(project, folder)
        if state.dirty { return "it has uncommitted changes now" }
        if state.branch != item.branch { return "its branch changed" }
        if !state.merged { return "its branch is not merged into \(project.baseBranch) any more" }
        return nil
    }

    /// One `stop-agent.sh` per selected item, after a fresh check of that item; an item that fails or changed stays in the list with the reason.
    func runCleanup() async {
        phase = .running; failures = []; warnings = []
        let agents = try? await adapter.agents()
        for item in items where selectedIDs.contains(item.id) && item.isOffered {
            let name = item.agent ?? item.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.id
            if let reason = await changedSinceScan(item, agents: agents) { failures.append("\(name): kept, \(reason)."); continue }
            var args = [name, item.worktreePath ?? item.cwd ?? ""]
            if item.worktreePath != nil {
                args += ["--remove-worktree", "--delete-branch"]
                if let branch = item.branch { args += ["--expect-branch", branch] }
            }
            if !item.hasSimulator { args.append("--no-sim") }
            do {
                let result = try await scripts.run(.stop, arguments: args)
                // 4: the terminal no longer knew the workspace, everything else was removed.
                if result.status == 0 || result.status == 4 {
                    items.removeAll { $0.id == item.id }; selectedIDs.remove(item.id)
                    for line in result.stderr.split(whereSeparator: \.isNewline) where line.hasPrefix("WARNING:") {
                        warnings.append("\(name): \(line.dropFirst("WARNING:".count).trimmingCharacters(in: .whitespaces))")
                    }
                } else {
                    let detail = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "stop-agent.sh exited with status \(result.status)"
                    failures.append("\(name): \(detail)")
                }
            } catch { failures.append("\(name): \(StartTaskFlow.describe(error))") }
        }
        phase = .ready
    }
}
