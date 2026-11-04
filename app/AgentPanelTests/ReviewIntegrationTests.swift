import XCTest
@testable import AgentPanel

/// The review flow against the real scripts (spawn, review-packet, merge-task, stop), a real git repository and the fake terminal:
/// proves that the Swift side and the scripts agree on arguments, output and exit codes through a whole task: start, review, approve.
final class ReviewIntegrationTests: XCTestCase {
    /// The real scripts, except `sim-for-agent.sh`, which would create a real simulator.
    private struct NoSimulator: ScriptRunning {
        let inner: ScriptRunning
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult {
            script == .sim ? ScriptResult(status: 0, stdout: "FAKE-UDID\n", stderr: "") : try await inner.run(script, arguments: arguments)
        }
    }

    private var dir: TempDir!
    private var repo: URL!
    private var state: URL!
    private var settings: AppSettings!
    private var project: ProjectConfig!
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var fixtures: URL { root.appendingPathComponent("tests/fixtures") }

    override func setUpWithError() throws {
        dir = try TempDir()
        repo = dir.url.appendingPathComponent("repo")
        state = dir.url.appendingPathComponent("term-state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q", "-b", "main"])
        try dir.write("repo/a.txt", "a\n")
        try git(repo, ["add", "."]); try git(repo, ["commit", "-q", "-m", "init"])
        settings = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        for (key, value) in [("FAKE_TERM_STATE", state.path), ("AGENT_PANEL_STATE", dir.url.appendingPathComponent("agent-state").path),
                             ("AGENT_PANEL_CLAUDE_HOME", fixtures.appendingPathComponent("claude-home").path),
                             ("AGENT_PANEL_SIM_SCRIPT", fixtures.appendingPathComponent("fake-sim.sh").path),
                             ("AGENT_PANEL_SCREENSHOT_CMD", "echo png > \"$FILE\""),
                             ("AGENT_PANEL_BUILD_ROOT", dir.url.appendingPathComponent("build").path)] { setenv(key, value, 1) }

        try dir.write("roles/dev.md", "Be brief.")
        let role = try dir.write("roles/dev.json", """
        {"name":"dev","kind":"interactive","model":"sonnet","effort":"medium","permissionMode":"acceptEdits","outputStyle":"concise",
         "allowedTools":["Read","Edit"],"skills":["superpowers"],"instructionFile":"dev.md"}
        """)
        let source = try dir.write("project.json", """
        {"id":"demo","name":"Demo","repoPath":"\(repo.path)","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"true","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode","roles":{"dev":"\(role.path)"}}
        """)
        project = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    override func tearDown() {
        for key in ["FAKE_TERM_STATE", "AGENT_PANEL_STATE", "AGENT_PANEL_CLAUDE_HOME", "AGENT_PANEL_SIM_SCRIPT", "AGENT_PANEL_SCREENSHOT_CMD", "AGENT_PANEL_BUILD_ROOT"] { unsetenv(key) }
    }

    @discardableResult
    private func git(_ at: URL, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", at.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var runner: ScriptRunning {
        NoSimulator(inner: ProcessScriptRunner(settings: settings, timeout: 60,
                                               extraEnvironment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "AGENT_PANEL_TERM_SCRIPT": "\(fixtures.path)/fake-term/term-fake.sh"]))
    }
    private var commander: TerminalCommanding { ScriptTerminal(fixtures: fixtures) }
    private func calls() -> String { (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }
    private var worktree: URL { repo.appendingPathComponent(".agent-worktrees/pilot-t1") }

    private func reviewFlow(agents: [AgentStatus] = []) -> ReviewFlow {
        ReviewFlow(project: project, scripts: runner, adapter: FakeTerminal(agentsResult: .success(agents)), commander: commander,
                   writer: CardWriter(), log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")))
    }

    private func load(_ id: String) throws -> TaskCard {
        let url = dir.url.appendingPathComponent("data/tasks/\(id).md")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    /// Starts T1 for real (worktree and branch), lets the "agent" commit a file, and builds the review packet: the card ends in `review`.
    private func startAndPrepare(kind: String? = nil, commit: Bool = true) async throws -> TaskCard {
        let k = kind.map { "kind: \($0)\n" } ?? ""
        let url = try dir.write("data/tasks/T1.md", "---\nid: T1\nproject: demo\nstatus: awaiting-start-approval\nagent:\nbranch: pilot/t1\n\(k)files:\n  - c.txt\n---\n# T1 · Add c\n\n## Goal\nAdd c.\n\n## Report\nAdded c.\n")
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        let start = StartTaskFlow(project: project, scripts: runner, commander: commander, writer: CardWriter(),
                                  log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: { [] })
        _ = try await start.start(try start.plan(for: card))
        if commit {
            try dir.write("repo/.agent-worktrees/pilot-t1/c.txt", "c\n")
            try git(worktree, ["add", "c.txt"]); try git(worktree, ["commit", "-q", "-m", "feat: add c"])
        }
        try await reviewFlow().preparePacket(for: try load("T1"))
        return try load("T1")
    }

    func testStartReviewApproveEndToEnd() async throws {
        let card = try await startAndPrepare()
        XCTAssertEqual(card.status, .review)
        XCTAssertNotNil(packetSections(from: card.sections["Review packet"] ?? "").head)

        let flow = reviewFlow()
        let plan = try await flow.approvalPlan(for: card)
        XCTAssertEqual(plan.ahead, 1)
        let tip = try git(worktree, ["rev-parse", "HEAD"])
        try await flow.approve(plan)

        XCTAssertEqual(try git(repo, ["rev-parse", "main"]), tip, "main moved to the reviewed commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("c.txt").path))
        let done = try load("T1")
        XCTAssertEqual(done.status, .done)
        XCTAssertTrue(done.sections["Decision"]?.contains(String(tip.prefix(7))) == true)
        XCTAssertEqual(done.sections["Report"], "Added c.", "the agent's report is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path), "the worktree is removed")
        XCTAssertEqual(try git(repo, ["branch", "--list", "pilot/t1"]), "", "the merged branch is deleted")
    }

    func testApprovalIsRefusedWhenMainMovedOnAndNothingChanges() async throws {
        let card = try await startAndPrepare()
        try dir.write("repo/m.txt", "m\n"); try git(repo, ["add", "."]); try git(repo, ["commit", "-q", "-m", "main moves"])
        let mainBefore = try git(repo, ["rev-parse", "main"])
        do { _ = try await reviewFlow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .notFastForward) }
        XCTAssertEqual(try git(repo, ["rev-parse", "main"]), mainBefore)
        XCTAssertEqual(try load("T1").status, .review)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
    }

    func testAgentCommittingAfterThePacketMakesItStale() async throws {
        let card = try await startAndPrepare()
        try dir.write("repo/.agent-worktrees/pilot-t1/d.txt", "d\n")
        try git(worktree, ["add", "d.txt"]); try git(worktree, ["commit", "-q", "-m", "later"])
        do { _ = try await reviewFlow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .stale) }
    }

    func testYourUnsavedEditInTheWayStopsTheMerge() async throws {
        let card = try await startAndPrepare()
        try dir.write("repo/c.txt", "my own c\n")   // untracked, same name as the file the branch adds
        do { _ = try await reviewFlow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .userFilesInTheWay(["c.txt"])) }
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("c.txt"), encoding: .utf8), "my own c\n")
    }

    func testFixRequestReachesTheAgentAndMovesTheCard() async throws {
        let card = try await startAndPrepare()
        var agent = AgentStatus(paneID: "wZ:p1", workspaceID: "wZ", state: .idle, cwd: worktree.path, title: "dev-t1", sessionID: "s"); agent.name = card.agent
        try await reviewFlow(agents: [agent]).requestFix(for: card, notes: "Please rename c to see.")
        let after = try load("T1")
        XCTAssertEqual(after.status, .needsFix)
        XCTAssertTrue(after.sections["Fix notes"]?.contains("rename c to see") == true)
        XCTAssertTrue(calls().contains("prompt wZ:p1"), calls())
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), "the agent keeps its worktree")
    }

    func testAnalysisTaskIsApprovedWithoutAMerge() async throws {
        let card = try await startAndPrepare(kind: "analysis", commit: false)
        XCTAssertEqual(card.status, .review)
        let mainBefore = try git(repo, ["rev-parse", "main"])
        let flow = reviewFlow()
        try await flow.approve(try await flow.approvalPlan(for: card))
        XCTAssertEqual(try git(repo, ["rev-parse", "main"]), mainBefore)
        XCTAssertEqual(try load("T1").status, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
    }
}
