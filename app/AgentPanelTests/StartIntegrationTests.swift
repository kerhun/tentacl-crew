import XCTest
@testable import AgentPanel

/// The panel's start flow against the real Phase 0 scripts (spawn-agent.sh, check-conflicts.sh, stop-agent.sh), a real git
/// repository and the fake terminal from tests/fixtures: proves that the Swift side and the scripts agree on arguments, output and exit codes.
final class StartIntegrationTests: XCTestCase {
    private var dir: TempDir!
    private var repo: URL!
    private var state: URL!
    private var settings: AppSettings!
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var fixtures: URL { root.appendingPathComponent("tests/fixtures") }

    override func setUpWithError() throws {
        dir = try TempDir()
        repo = dir.url.appendingPathComponent("repo")
        state = dir.url.appendingPathComponent("term-state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"]); try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"])
        settings = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        XCTAssertNotNil(settings.scriptURL(.spawn), "the Phase 0 scripts must be next to the app folder")
        setenv("FAKE_TERM_STATE", state.path, 1)
        setenv("AGENT_PANEL_STATE", dir.url.appendingPathComponent("agent-state").path, 1)
        setenv("AGENT_PANEL_CLAUDE_HOME", fixtures.appendingPathComponent("claude-home").path, 1)
        setenv("AGENT_PANEL_SIM_SCRIPT", fixtures.appendingPathComponent("fake-sim.sh").path, 1)
    }

    override func tearDown() {
        for key in ["FAKE_TERM_STATE", "AGENT_PANEL_STATE", "AGENT_PANEL_CLAUDE_HOME", "AGENT_PANEL_SIM_SCRIPT", "FAKE_START", "FAKE_PROMPT"] { unsetenv(key) }
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo.path] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func calls() -> String { (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }

    /// A project whose role file is valid for validate-config.sh.
    private func makeProject() throws -> ProjectConfig {
        try dir.write("roles/dev.md", "Be brief.")
        let role = try dir.write("roles/dev.json", """
        {"name":"dev","kind":"interactive","model":"sonnet","effort":"medium","permissionMode":"acceptEdits","outputStyle":"concise",
         "allowedTools":["Read","Edit"],"skills":["superpowers"],"instructionFile":"dev.md"}
        """)
        let source = try dir.write("project.json", """
        {"id":"demo","name":"Demo","repoPath":"\(repo.path)","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"true","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":["App/Localizable.xcstrings"],"openWith":"Xcode",
         "roles":{"dev":"\(role.path)"}}
        """)
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private func card(_ id: String, status: String = "awaiting-start-approval", branch: String = "pilot/a5-widget", files: [String] = ["App/Widget.swift"]) throws -> TaskCard {
        let list = files.map { "  - \($0)" }.joined(separator: "\n")
        let url = try dir.write("data/tasks/\(id).md", "---\nid: \(id)\nproject: demo\nstatus: \(status)\nagent:\nbranch: \(branch)\nfiles:\n\(list)\n---\n# \(id) · Title\n\n## Goal\nDo it.\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private func flow(_ project: ProjectConfig, running: [TaskCard] = []) -> StartTaskFlow {
        let commander = ScriptTerminal(fixtures: fixtures)
        return StartTaskFlow(project: project, scripts: ProcessScriptRunner(settings: settings, timeout: 60,
                                                                           extraEnvironment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "AGENT_PANEL_TERM_SCRIPT": "\(fixtures.path)/fake-term/term-fake.sh"]),
                             commander: commander, writer: CardWriter(), log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                             roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: { running })
    }

    func testEndToEndStartMovesCardToDoingAndSendsThePrompt() async throws {
        let project = try makeProject(); let c = try card("A5")
        let f = flow(project)
        let started = try await f.start(try f.plan(for: c))
        XCTAssertEqual(started.agent, "dev-a5-demo")
        let written = try CardParser.parse(try String(contentsOf: c.url, encoding: .utf8), url: c.url)
        XCTAssertEqual(written.status, .doing)
        XCTAssertEqual(written.agent, "dev-a5-demo")
        XCTAssertEqual(written.branch, "pilot/a5-widget")
        let log = calls()
        XCTAssertTrue(log.contains("start dev-a5-demo dev-a5-demo"), log)
        XCTAssertTrue(log.contains("prompt dev-a5-demo Your task card: \(c.url.path)"), log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".agent-worktrees/pilot-a5-widget").path))
        XCTAssertFalse(try git(["branch", "--list", "pilot/a5-widget"]).isEmpty)
    }

    func testEndToEndSpawnFailureRollsBackAndKeepsCard() async throws {
        setenv("FAKE_START", "fail", 1)
        let project = try makeProject(); let c = try card("A5")
        let before = try String(contentsOf: c.url, encoding: .utf8)
        let f = flow(project)
        do { _ = try await f.start(try f.plan(for: c)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .spawnFailed(let m) = e else { return XCTFail("\(e)") }; XCTAssertTrue(m.contains("agent start failed"), m) }
        XCTAssertEqual(try String(contentsOf: c.url, encoding: .utf8), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".agent-worktrees/pilot-a5-widget").path))
        XCTAssertTrue(try git(["branch", "--list", "pilot/a5-widget"]).isEmpty, "a failed start must not leave its branch behind")
    }

    func testEndToEndPromptFailureStopsTheAgentAndRemovesItsBranch() async throws {
        setenv("FAKE_PROMPT", "fail", 1)
        let project = try makeProject(); let c = try card("A5")
        let f = flow(project)
        do { _ = try await f.start(try f.plan(for: c)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .promptFailed = e else { return XCTFail("\(e)") } }
        XCTAssertTrue(try String(contentsOf: c.url, encoding: .utf8).contains("status: awaiting-start-approval"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".agent-worktrees/pilot-a5-widget").path), "the worktree is removed again")
        XCTAssertTrue(try git(["branch", "--list", "pilot/a5-widget"]).isEmpty, "the fresh branch is removed again")
    }

    func testEndToEndConflictingRunningCardBlocksStart() async throws {
        let project = try makeProject()
        let running = try card("R1", status: "doing", branch: "other/r1", files: ["App/Localizable.xcstrings"])
        let c = try card("A5", files: ["App/Resources/Localizable.xcstrings"])
        let f = flow(project, running: [running])
        do { _ = try await f.start(try f.plan(for: c)); XCTFail("expected a conflict") }
        catch let e as StartError { guard case .conflict(let m) = e else { return XCTFail("\(e)") }; XCTAssertTrue(m.contains("Localizable.xcstrings"), m) }
        XCTAssertFalse(calls().contains("open "), "no agent may be started when the files conflict")
    }

    func testEndToEndNothingOutsideTheCardChanges() async throws {
        let project = try makeProject()
        let backlog = try dir.write("data/backlog.md", "# backlog\n")
        let other = try dir.write("data/tasks/OTHER.md", "---\nid: OTHER\nstatus: todo\n---\n# other\n")
        let c = try card("A5")
        let f = flow(project)
        _ = try await f.start(try f.plan(for: c))
        XCTAssertEqual(try String(contentsOf: backlog, encoding: .utf8), "# backlog\n")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "---\nid: OTHER\nstatus: todo\n---\n# other\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: c.url.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(names, ["A5.md", "OTHER.md"], "no stray temp files in the tasks folder")
    }
}
