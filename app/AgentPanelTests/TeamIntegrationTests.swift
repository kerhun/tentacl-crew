import XCTest
@testable import AgentPanel

/// The team chart through the real scripts: who may give a task to whom decides whether a start is planned as allowed, the agent's
/// instructions get their place in the team, and the user can still give a task themselves.
final class TeamIntegrationTests: XCTestCase {
    private var dir: TempDir!
    private var repo: URL!
    private var state: URL!
    private var agentState: URL!
    private var settings: AppSettings!
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var fixtures: URL { root.appendingPathComponent("tests/fixtures") }
    private var baseDir: URL { dir.url.appendingPathComponent("base-roles") }

    override func setUpWithError() throws {
        dir = try TempDir()
        repo = dir.url.appendingPathComponent("repo")
        state = dir.url.appendingPathComponent("term-state")
        agentState = dir.url.appendingPathComponent("agent-state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"]); try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"])
        settings = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        for (key, value) in [("FAKE_TERM_STATE", state.path), ("AGENT_PANEL_STATE", agentState.path),
                             ("AGENT_PANEL_CLAUDE_HOME", fixtures.appendingPathComponent("claude-home").path),
                             ("AGENT_PANEL_SIM_SCRIPT", fixtures.appendingPathComponent("fake-sim.sh").path)] { setenv(key, value, 1) }
    }

    override func tearDown() {
        for key in ["FAKE_TERM_STATE", "AGENT_PANEL_STATE", "AGENT_PANEL_CLAUDE_HOME", "AGENT_PANEL_SIM_SCRIPT"] { unsetenv(key) }
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo.path] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func roleJSON(_ name: String, model: String, extra: String = "") -> String {
        "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"\(model)\",\"effort\":\"medium\",\"permissionMode\":\"acceptEdits\",\"outputStyle\":\"concise\",\"allowedTools\":[\"Read\"],\"skills\":[\"keepme\"],\"instructionFile\":\"\(name).md\"\(extra)}"
    }

    private func project() throws -> ProjectConfig {
        let source = try dir.write("project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"\(repo.path)\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":3,\"buildCommand\":\"true\",\"simulator\":{\"baseDevice\":\"iPhone 17 Pro\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private func card(roles: String) throws -> TaskCard {
        let url = try dir.write("data/tasks/T1.md", "---\nid: T1\nproject: demo\nstatus: todo\nagent:\nbranch: feat/t1\nroles: \(roles)\nfiles:\n  - a.swift\n---\n# T1 · Title\n\n## Goal\nx\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private var runner: ScriptRunning {
        ProcessScriptRunner(settings: settings, timeout: 60, extraEnvironment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "AGENT_PANEL_TERM_SCRIPT": "\(fixtures.path)/fake-term/term-fake.sh"])
    }

    private func flow(_ project: ProjectConfig, scripts: ScriptRunning? = nil) -> StartTaskFlow {
        StartTaskFlow(project: project, scripts: scripts ?? runner, commander: ScriptTerminal(fixtures: fixtures), writer: CardWriter(),
                      log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")), roleStore: RoleStore(baseDir: baseDir), teamStore: TeamChartStore(), runningCards: { [] })
    }

    private func calls() -> String { (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }

    private let standard = #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"reviewer","reportsTo":"pm"},{"role":"dev","reportsTo":"reviewer"}]}"#

    private func card(roles: String, from: String?) throws -> TaskCard {
        let f = from.map { "from: \($0)\n" } ?? ""
        let url = try dir.write("data/tasks/T1.md", "---\nid: T1\nproject: demo\nstatus: todo\nagent:\nbranch: feat/t1\nroles: \(roles)\n\(f)files:\n  - a.swift\n---\n# T1 · Title\n\n## Goal\nx\n\n## Report\nBody stays.\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private func setUpRoles() throws {
        for r in ["pm", "reviewer", "dev"] {
            try dir.write("base-roles/\(r).json", roleJSON(r, model: "sonnet"))
            try dir.write("base-roles/\(r).md", "ROLE TEXT \(r)\n")
        }
    }

    private func instructions(_ agent: String) throws -> String { try String(contentsOf: agentState.appendingPathComponent("\(agent)/instructions.md"), encoding: .utf8) }

    func testAnAllowedTaskStartsAndTheAgentLearnsItsPlaceInTheTeam() async throws {
        try setUpRoles(); try dir.write("team.json", standard)
        let p = try project(), f = flow(p)
        let plan = try f.plan(for: try card(roles: "[dev]", from: "reviewer"))
        XCTAssertEqual(plan.authority, .allowed(from: "reviewer", to: "dev"))
        _ = try await f.start(plan)
        let text = try instructions("dev-t1-demo")
        XCTAssertTrue(text.hasPrefix("ROLE TEXT dev"))
        XCTAssertTrue(text.contains("## Your place in the team"))
        XCTAssertTrue(text.contains("You report to: reviewer."))
        XCTAssertTrue(text.contains("You may give tasks to: nobody."))
    }

    func testADeniedTaskDoesNotStartUntilTheUserGivesItThemselves() async throws {
        try setUpRoles(); try dir.write("team.json", standard)
        let p = try project(), f = flow(p)
        let c = try card(roles: "[pm]", from: "dev")
        let plan = try f.plan(for: c)
        guard case .denied = plan.authority else { return XCTFail("a developer cannot give a task to the PM") }
        do { _ = try await f.start(plan); XCTFail("should throw") }
        catch let error as StartError { guard case .notAuthorized = error else { return XCTFail("\(error)") } }
        XCTAssertFalse(calls().contains("start "), "no agent was started")
        XCTAssertEqual(try CardParser.parse(try String(contentsOf: c.url, encoding: .utf8), url: c.url).status, .todo)

        _ = try await f.start(plan, givingItMyself: true)
        let after = try CardParser.parse(try String(contentsOf: c.url, encoding: .utf8), url: c.url)
        XCTAssertEqual(after.from, "user")
        XCTAssertEqual(after.status, .doing)
        XCTAssertEqual(after.sections["Report"], "Body stays.")
        XCTAssertTrue(try instructions("pm-t1-demo").contains("You may give tasks to: reviewer, dev."))
    }

    func testPlacingADeveloperAboveThePmLetsTheDeveloperGiveThePmATask() async throws {
        try setUpRoles(); try dir.write("team.json", #"{"version":1,"members":[{"role":"dev","reportsTo":null},{"role":"pm","reportsTo":"dev"}]}"#)
        let p = try project(), f = flow(p)
        XCTAssertEqual(try f.plan(for: try card(roles: "[pm]", from: "dev")).authority, .allowed(from: "dev", to: "pm"))
        guard case .denied = try f.plan(for: try card(roles: "[dev]", from: "pm")).authority else { return XCTFail("the PM is now below") }
    }

    func testABrokenChartStopsTheStartBeforeAnyScriptRuns() throws {
        try setUpRoles(); try dir.write("team.json", #"{"version":1,"members":[{"role":"a","reportsTo":"b"},{"role":"b","reportsTo":"a"}]}"#)
        XCTAssertThrowsError(try flow(try project()).plan(for: try card(roles: "[dev]", from: nil))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("cycle"), m)
        }
        XCTAssertFalse(calls().contains("start "))
    }

    func testWithoutAChartTheInstructionsHaveNoTeamSection() async throws {
        try setUpRoles()
        let p = try project(), f = flow(p)
        let plan = try f.plan(for: try card(roles: "[dev]", from: "anyone-at-all"))
        XCTAssertEqual(plan.authority, .notApplicable)
        _ = try await f.start(plan)
        let text = try instructions("dev-t1-demo")
        XCTAssertTrue(text.hasPrefix("ROLE TEXT dev\n\n## Your simulator"), "the role text, then only the simulator section as before")
        XCTAssertFalse(text.contains("team"), "no chart: nothing about a team is added")
    }
}
