import XCTest
@testable import AgentPanel

private final class MutableTerminal: TerminalListing, @unchecked Sendable {
    var list: [AgentStatus]
    init(_ list: [AgentStatus]) { self.list = list }
    func agents() async throws -> [AgentStatus] { list }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

@MainActor
final class CleanupFlowTests: XCTestCase {
    private func project(_ id: String = "demo", simulator: Bool = false) -> ProjectConfig {
        ProjectConfig(id: id, name: id.capitalized, repoPath: "/repo/\(id)", dataDir: "/data/\(id)", maxParallel: 3, buildCommand: nil, xcodeProject: nil,
                      simulator: simulator ? .init(baseDevice: "iPhone") : nil, sharedFiles: [], openWith: nil)
    }

    private func card(_ id: String, status: TaskStatus, agent: String? = nil, branch: String? = nil) -> TaskCard {
        TaskCard(id: id, project: "demo", status: status, agent: agent, branch: branch, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/data/\(id).md"))
    }

    private func agent(_ name: String, cwd: String) -> AgentStatus {
        AgentStatus(paneID: "w\(name):p1", workspaceID: "w\(name)", state: .idle, cwd: cwd, title: name, name: name)
    }

    private let clean = WorktreeState(branch: "feat/old", dirty: false, merged: true)

    private func flow(cards: [TaskCard] = [], folders: [String] = [], agents: [AgentStatus] = [], states: [String: WorktreeState] = [:], simulator: Bool = false,
                      scripts: FakeScripts = FakeScripts()) -> CleanupFlow {
        CleanupFlow(projects: [project(simulator: simulator)], cards: { _ in cards }, folders: { _ in folders }, adapter: FakeTerminal(agentsResult: .success(agents)),
                    inspect: { _, folder in states[folder] ?? WorktreeState(branch: nil, dirty: false, merged: false) }, scripts: scripts)
    }

    func testLeftoverWorktreeAndAgentAreFoundAsOneItem() async {
        let f = flow(folders: ["feat-old"], agents: [agent("dev-old-demo", cwd: "/repo/demo/.agent-worktrees/feat-old")], states: ["feat-old": clean])
        await f.scan()
        XCTAssertEqual(f.items.count, 1)
        let item = f.items[0]
        XCTAssertEqual(item.agent, "dev-old-demo")
        XCTAssertEqual(item.worktreePath, "/repo/demo/.agent-worktrees/feat-old")
        XCTAssertTrue(item.isOffered)
        XCTAssertEqual(item.steps, ["Close the agent", "Remove the worktree", "Delete the branch feat/old (merged into main)"])
    }

    func testRunningCardsAreNeverListed() async {
        let running = card("T1", status: .doing, agent: "dev-t1-demo", branch: "feat/t1")
        let f = flow(cards: [running], folders: ["feat-t1"], agents: [agent("dev-t1-demo", cwd: "/repo/demo/.agent-worktrees/feat-t1")],
                     states: ["feat-t1": WorktreeState(branch: "feat/t1", dirty: false, merged: true)])
        await f.scan()
        XCTAssertTrue(f.items.isEmpty)
    }

    func testAnAgentWithoutRunningCardIsListedEvenWithoutWorktree() async {
        let done = card("T2", status: .done, agent: "dev-t2-demo", branch: "feat/t2")
        let f = flow(cards: [done], agents: [agent("dev-t2-demo", cwd: "/repo/demo/.agent-worktrees/feat-t2")])
        await f.scan()
        XCTAssertEqual(f.items.count, 1)
        XCTAssertNil(f.items[0].worktreePath)
        XCTAssertEqual(f.items[0].steps, ["Close the agent"])
        XCTAssertTrue(f.items[0].isOffered)
    }

    func testAgentsOfOtherPlacesAndUnnamedSessionsAreIgnored() async {
        let f = flow(agents: [agent("dev-x-other", cwd: "/repo/other/.agent-worktrees/x"),
                              AgentStatus(paneID: "w9:p1", workspaceID: "w9", state: .idle, cwd: "/repo/demo/.agent-worktrees/hand", title: "hand")])
        await f.scan()
        XCTAssertTrue(f.items.isEmpty)
    }

    func testDirtyOrUnmergedWorktreesAreListedButNotOffered() async {
        let f = flow(folders: ["dirty", "unmerged"], states: ["dirty": WorktreeState(branch: "a", dirty: true, merged: true),
                                                             "unmerged": WorktreeState(branch: "b", dirty: false, merged: false)])
        await f.scan()
        XCTAssertEqual(f.items.count, 2)
        XCTAssertTrue(f.items.allSatisfy { !$0.isOffered && $0.blocked != nil })
        XCTAssertTrue(f.selectedIDs.isEmpty)
    }

    func testConfirmRunsOneStopPerSelectedItem() async {
        let scripts = FakeScripts()
        let f = flow(folders: ["feat-old", "dirty"], agents: [agent("dev-old-demo", cwd: "/repo/demo/.agent-worktrees/feat-old")],
                     states: ["feat-old": clean, "dirty": WorktreeState(branch: "d", dirty: true, merged: true)], scripts: scripts)
        await f.scan()
        XCTAssertTrue(scripts.calls.isEmpty, "scanning removes nothing")
        await f.runCleanup()
        XCTAssertEqual(scripts.calls, [.init(script: .stop, args: ["dev-old-demo", "/repo/demo/.agent-worktrees/feat-old", "--remove-worktree", "--delete-branch", "--expect-branch", "feat/old", "--no-sim"])])
        XCTAssertTrue(f.items.isEmpty == false && f.items.allSatisfy { $0.id != "demo:feat-old" }, "the cleaned item is gone, the dirty one stays")
    }

    func testDeselectedItemsAreSkippedAndAgentOnlyKeepsTheWorktree() async {
        let scripts = FakeScripts()
        let f = flow(folders: ["feat-old"], agents: [agent("dev-t2-demo", cwd: "/repo/demo/.agent-worktrees/gone")], states: ["feat-old": clean], simulator: true, scripts: scripts)
        await f.scan()
        XCTAssertEqual(f.items.count, 2)
        f.toggle(f.items.first { $0.worktreePath?.hasSuffix("feat-old") == true }!)
        await f.runCleanup()
        XCTAssertEqual(scripts.calls, [.init(script: .stop, args: ["dev-t2-demo", "/repo/demo/.agent-worktrees/gone"])])
    }

    func testFailedStopIsReportedAndKeptInTheList() async {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 1, stdout: "", stderr: "ERROR: no terminal workspace") }
        let f = flow(folders: ["feat-old"], states: ["feat-old": clean], scripts: scripts)
        await f.scan()
        await f.runCleanup()
        XCTAssertEqual(f.items.count, 1)
        XCTAssertTrue(f.failures.first?.contains("no terminal workspace") == true)
    }

    // MARK: real git repo (N52)

    private var nowCards: [TaskCard] = []

    private func git(_ dir: String, _ args: String...) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
    }

    /// A repo with a `main` commit and two worktrees: `feat-merged` (no commits of its own) and `feat-ahead` (one commit not in main).
    private func realRepo() throws -> (ProjectConfig, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        try git(root, "init", "-q", "-b", "main"); try git(root, "commit", "-q", "--allow-empty", "-m", "init")
        for (folder, branch) in [("feat-merged", "feat/merged"), ("feat-ahead", "feat/ahead")] {
            try git(root, "worktree", "add", "-q", "-b", branch, "\(root)/.agent-worktrees/\(folder)")
        }
        try "x".write(toFile: "\(root)/.agent-worktrees/feat-ahead/a.txt", atomically: true, encoding: .utf8)
        try git("\(root)/.agent-worktrees/feat-ahead", "add", "a.txt"); try git("\(root)/.agent-worktrees/feat-ahead", "commit", "-q", "-m", "work")
        var p = project(); p = ProjectConfig(id: p.id, name: p.name, repoPath: root, dataDir: "/data/demo", maxParallel: 3, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
        return (p, root)
    }

    private func realFlow(_ p: ProjectConfig, agents: [AgentStatus] = [], scripts: FakeScripts = FakeScripts()) -> CleanupFlow {
        let git = GitInspector()
        return CleanupFlow(projects: [p], cards: { [unowned self] _ in self.nowCards }, folders: { _ in ["feat-ahead", "feat-merged"] }, adapter: FakeTerminal(agentsResult: .success(agents)),
                           inspect: { p, folder in await git.state(repo: p.repoPath, worktree: p.worktreesURL.appendingPathComponent(folder).path, base: p.baseBranch) }, scripts: scripts)
    }

    func testRealGitAnUnmergedBranchIsNotOfferedAndAMergedOneIs() async throws {
        let (p, _) = try realRepo()
        let f = realFlow(p)
        await f.scan()
        XCTAssertEqual(f.items.first { $0.id == "demo:feat-ahead" }?.isOffered, false)
        XCTAssertEqual(f.items.first { $0.id == "demo:feat-merged" }?.isOffered, true)
    }

    func testRealGitAFileEditedBetweenScanAndConfirmKeepsTheItem() async throws {
        let (p, root) = try realRepo()
        let scripts = FakeScripts()
        let f = realFlow(p, scripts: scripts)
        await f.scan()
        try "late".write(toFile: "\(root)/.agent-worktrees/feat-merged/late.txt", atomically: true, encoding: .utf8)
        await f.runCleanup()
        XCTAssertTrue(scripts.calls.isEmpty, "nothing is removed")
        XCTAssertNotNil(f.items.first { $0.id == "demo:feat-merged" })
        XCTAssertTrue(f.failures.first?.contains("uncommitted") == true, "\(f.failures)")
    }

    func testACardThatIsAboutToStartOnTheBranchKeepsTheItem() async throws {
        let (p, _) = try realRepo()
        let scripts = FakeScripts()
        nowCards = []
        let f = realFlow(p, scripts: scripts)
        await f.scan()
        nowCards = [card("T9", status: .awaitingStartApproval, branch: "feat/merged")]
        await f.runCleanup()
        XCTAssertTrue(scripts.calls.filter { $0.args.contains("feat/merged") }.isEmpty)
        XCTAssertNotNil(f.items.first { $0.id == "demo:feat-merged" })
    }

    func testTheAgentSessionChangingKeepsTheItem() async throws {
        let (p, root) = try realRepo()
        let scripts = FakeScripts()
        let terminal = MutableTerminal([agent("dev-a", cwd: "\(root)/.agent-worktrees/feat-merged")])
        let git = GitInspector()
        let f = CleanupFlow(projects: [p], cards: { _ in [] }, folders: { _ in ["feat-merged"] }, adapter: terminal,
                            inspect: { p, folder in await git.state(repo: p.repoPath, worktree: p.worktreesURL.appendingPathComponent(folder).path, base: p.baseBranch) }, scripts: scripts)
        await f.scan()
        terminal.list = [AgentStatus(paneID: "wNEW:p1", workspaceID: "wNEW", state: .idle, cwd: "\(root)/.agent-worktrees/feat-merged", title: "dev-a", name: "dev-a")]
        await f.runCleanup()
        XCTAssertTrue(scripts.calls.isEmpty)
        XCTAssertEqual(f.items.count, 1)
    }

    func testExit4CountsAsSuccess() async {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 4, stdout: "", stderr: "ERROR: no terminal workspace for worktree /w (agent a)") }
        let f = flow(folders: ["feat-old"], states: ["feat-old": clean], scripts: scripts)
        await f.scan(); await f.runCleanup()
        XCTAssertTrue(f.items.isEmpty); XCTAssertTrue(f.failures.isEmpty)
    }

    func testTheBranchKeptWarningIsShown() async {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "", stderr: "WARNING: branch feat/old kept (it has commits that are not merged)") }
        let f = flow(folders: ["feat-old"], states: ["feat-old": clean], scripts: scripts)
        await f.scan(); await f.runCleanup()
        XCTAssertTrue(f.items.isEmpty); XCTAssertTrue(f.failures.isEmpty)
        XCTAssertEqual(f.warnings.count, 1)
        XCTAssertTrue(f.warnings[0].contains("branch feat/old kept"))
    }
}
