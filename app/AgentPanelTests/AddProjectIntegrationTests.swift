import XCTest
@testable import AgentPanel

/// "Add project" with the real create-project.sh, a real git repository and the fake terminal, then a whole task in the new project
/// without a build, a simulator or screenshots: the proof that the panel is not tied to iOS.
@MainActor
final class AddProjectIntegrationTests: XCTestCase {
    private var dir: TempDir!
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var fixtures: URL { root.appendingPathComponent("tests/fixtures") }
    private var state: URL { dir.url.appendingPathComponent("term-state") }
    private var code: String { dir.url.appendingPathComponent("code").path }
    private var wiki: String { dir.url.appendingPathComponent("wiki").path }
    private var settingsFile: URL { dir.url.appendingPathComponent("projects.json") }
    private var settings: AppSettings { AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: []) }

    override func setUpWithError() throws {
        dir = try TempDir()
        try FileManager.default.createDirectory(atPath: code, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: wiki, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("shared-roles"), withIntermediateDirectories: true)
        for (key, value) in [("FAKE_TERM_STATE", state.path), ("AGENT_PANEL_STATE", dir.url.appendingPathComponent("agent-state").path),
                             ("AGENT_PANEL_CLAUDE_HOME", fixtures.appendingPathComponent("claude-home").path),
                             ("TENTACL_ROLES_DIR", dir.url.appendingPathComponent("shared-roles").path),
                             ("AGENT_PANEL_CLAUDE_JSON", dir.url.appendingPathComponent("claude.json").path)] { setenv(key, value, 1) }   // trust-folder.sh never writes the real ~/.claude.json
    }

    override func tearDown() { for key in ["FAKE_TERM_STATE", "AGENT_PANEL_STATE", "AGENT_PANEL_CLAUDE_HOME", "TENTACL_ROLES_DIR", "AGENT_PANEL_CLAUDE_JSON"] { unsetenv(key) } }

    private var runner: ScriptRunning {
        ProcessScriptRunner(settings: settings, timeout: 60, extraEnvironment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "AGENT_PANEL_TERM_SCRIPT": "\(fixtures.path)/fake-term/term-fake.sh"])
    }
    private var commander: TerminalCommanding { ScriptTerminal(fixtures: fixtures) }

    private func makeFlow() -> AddProjectFlow {
        let inspector = RepoInspector(runner: ProcessRunner(timeout: 30))
        return AddProjectFlow(scripts: runner, registry: ProjectRegistry(settingsURL: settingsFile, scripts: runner),
                              probe: { await inspector.probe($0) }, listSimulators: { ["iPhone 17 Pro"] }, existingIDs: { [] }, repoParent: code, dataRoot: wiki)
    }

    @discardableResult
    private func git(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testANewProjectWithoutBuildOrSimulatorRunsAWholeTask() async throws {
        let flow = makeFlow()
        flow.name = "Recipe Box"; flow.github = .privateRepo
        let created = await flow.submit()
        let project = try XCTUnwrap(created, "\(flow.phase)")
        XCTAssertNil(project.buildCommand); XCTAssertNil(project.simulator); XCTAssertFalse(project.screenshotsEnabled)
        XCTAssertEqual(try git(code + "/recipe-box", ["rev-parse", "--abbrev-ref", "HEAD"]), "main")
        XCTAssertNotNil(flow.publishRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki + "/recipe-box/tasks/G1.md"))
        let listed = ProjectStore.load(settingsURL: settingsFile)
        XCTAssertEqual(listed.problems, [])
        let loaded = try XCTUnwrap(listed.projects.first)

        // A role in the project's own folder, and a task started and reviewed for real.
        try dir.write("wiki/recipe-box/agent-panel/roles/dev.md", "Be brief.")
        try dir.write("wiki/recipe-box/agent-panel/roles/dev.json", """
        {"name":"dev","kind":"interactive","model":"sonnet","effort":"medium","permissionMode":"acceptEdits","outputStyle":"concise","allowedTools":["Read","Edit"],"skills":[],"instructionFile":"dev.md"}
        """)
        let url = try dir.write("wiki/recipe-box/tasks/T1.md", "---\nid: T1\nproject: recipe-box\nstatus: awaiting-start-approval\nagent:\nbranch: pilot/t1\nfiles:\n  - c.txt\n---\n# T1 · Add c\n\n## Goal\nAdd c.\n\n## Report\nAdded c.\n")
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        let log = ActionLog(fileURL: dir.url.appendingPathComponent("actions.log"))
        let start = StartTaskFlow(project: loaded, scripts: runner, commander: commander, writer: CardWriter(), log: log,
                                  roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: { [] })
        let started = try await start.start(try start.plan(for: card))
        XCTAssertEqual(started.udid, "", "no simulator for a project that has none")

        let worktree = code + "/recipe-box/.agent-worktrees/pilot-t1"
        try dir.write("code/recipe-box/.agent-worktrees/pilot-t1/c.txt", "c\n")
        try git(worktree, ["add", "c.txt"]); try git(worktree, ["commit", "-q", "-m", "feat: add c"])
        let review = ReviewFlow(project: loaded, scripts: runner, adapter: FakeTerminal(agentsResult: .success([])), commander: commander, writer: CardWriter(), log: log)
        let reloaded = { try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url) }
        try await review.preparePacket(for: try reloaded())
        let inReview = try reloaded()
        XCTAssertEqual(inReview.status, .review)
        let packet = packetSections(from: inReview.sections["Review packet"] ?? "")
        XCTAssertTrue(packet.buildAcceptable); XCTAssertTrue(packet.screenshotsAcceptable)
        XCTAssertTrue(inReview.sections["Review packet"]?.contains("Build: none") == true)

        let plan = try await review.approvalPlan(for: inReview)
        try await review.approve(plan)
        XCTAssertEqual(try reloaded().status, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: code + "/recipe-box/c.txt"))
        let calls = (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        XCTAssertFalse(calls.contains("simctl"), "no simulator is ever asked for")
    }

    func testAnExistingRepositoryIsAddedWithoutAnyChangeToIt() async throws {
        let repo = code + "/Legacy App"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q", "-b", "trunk"]); try dir.write("code/Legacy App/a.txt", "a\n")
        try git(repo, ["add", "."]); try git(repo, ["commit", "-q", "-m", "init"])
        let before = try git(repo, ["status", "--porcelain", "--ignored"]) + (try git(repo, ["log", "--oneline"]))

        let flow = makeFlow()
        flow.mode = .existing
        await flow.chooseRepo(repo)
        XCTAssertTrue(flow.canSubmit, flow.problems.joined(separator: "; "))
        let created = await flow.submit()
        let project = try XCTUnwrap(created, "\(flow.phase)")
        XCTAssertEqual(project.id, "legacy-app")
        XCTAssertEqual(project.mainBranch, "trunk")
        XCTAssertEqual(project.repoPath, repo)
        XCTAssertEqual(try git(repo, ["status", "--porcelain", "--ignored"]) + (try git(repo, ["log", "--oneline"])), before, "the repository is exactly as it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wiki + "/legacy-app/agent-panel/project.json"))
    }
}
