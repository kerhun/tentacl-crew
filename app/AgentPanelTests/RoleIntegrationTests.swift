import XCTest
@testable import AgentPanel

/// A card's role through the real scripts: the role the card names (a project's role shadowing a shared one) starts a real
/// `spawn-agent.sh` run against the fake terminal, and what the role says (model, instructions, advanced settings) arrives in the
/// agent's flags and settings file.
final class RoleIntegrationTests: XCTestCase {
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

    func testTheProjectsRoleShadowsTheSharedOneAndItsSettingsReachTheAgent() async throws {
        try dir.write("base-roles/reviewer.json", roleJSON("reviewer", model: "sonnet")); try dir.write("base-roles/reviewer.md", "SHARED TEXT")
        try dir.write("roles/reviewer.json", roleJSON("reviewer", model: "opus", extra: ",\"displayName\":\"Eagle\",\"advanced\":{\"permissions\":{\"deny\":[\"Bash(git push:*)\"]},\"model\":\"ignored\"}"))
        try dir.write("roles/reviewer.md", "PROJECT TEXT")
        let p = try project(), c = try card(roles: "[reviewer]")
        let f = flow(p)
        let plan = try f.plan(for: c)
        XCTAssertEqual(plan.roleName, "reviewer")
        XCTAssertEqual(plan.roleDisplayName, "Eagle")
        XCTAssertEqual(plan.agentName, "reviewer-t1-demo")
        let started = try await f.start(plan)
        XCTAssertEqual(started.agent, "reviewer-t1-demo")

        let log = calls()
        XCTAssertTrue(log.contains("ARG:opus"), "the project's model, not the shared one: \(log)")
        XCTAssertFalse(log.contains("ARG:ignored"), "advanced.model never reaches the flags")
        let settingsFile = agentState.appendingPathComponent("reviewer-t1-demo/settings.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any])
        XCTAssertEqual(((json["permissions"] as? [String: Any])?["deny"] as? [String]), ["Bash(git push:*)"])
        XCTAssertNotNil(json["enabledPlugins"], "the generated plugin switches are there too")
        let instructions = try String(contentsOf: agentState.appendingPathComponent("reviewer-t1-demo/instructions.md"), encoding: .utf8)
        XCTAssertTrue(instructions.contains("PROJECT TEXT"))
        XCTAssertFalse(instructions.contains("SHARED TEXT"))
        XCTAssertEqual(try CardParser.parse(try String(contentsOf: c.url, encoding: .utf8), url: c.url).agent, "reviewer-t1-demo")
    }

    func testASharedRoleStartsWhenTheProjectHasNone() async throws {
        try dir.write("base-roles/dev.json", roleJSON("dev", model: "sonnet")); try dir.write("base-roles/dev.md", "SHARED DEV")
        let p = try project()
        let f = flow(p)
        _ = try await f.start(try f.plan(for: try card(roles: "[dev]")))
        XCTAssertTrue(calls().contains("ARG:sonnet"))
        XCTAssertTrue(try String(contentsOf: agentState.appendingPathComponent("dev-t1-demo/instructions.md"), encoding: .utf8).contains("SHARED DEV"))
    }

    func testARoleWithEnvInItsAdvancedSettingsNeverStarts() async throws {
        try dir.write("base-roles/leaky.json", roleJSON("leaky", model: "sonnet", extra: ",\"advanced\":{\"env\":{\"TOKEN\":\"x\"}}"))
        let p = try project()
        XCTAssertThrowsError(try flow(p).plan(for: try card(roles: "[leaky]"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("env"), m)
            XCTAssertFalse(m.contains("TOKEN"))
        }
        // and the script refuses the same file when it is run directly (a hand-edited role)
        let direct = try await runner.run(.spawn, arguments: ["--print-flags", baseDir.appendingPathComponent("leaky.json").path])
        XCTAssertEqual(direct.status, 1)
        XCTAssertTrue(direct.stderr.contains("env"))
        XCTAssertFalse(calls().contains("start "))
    }

    func testAMissingRoleNamesWhereItLooked() throws {
        let p = try project()
        XCTAssertThrowsError(try flow(p).plan(for: try card(roles: "[ghost]"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains(dir.url.appendingPathComponent("roles/ghost.json").path), m)
        }
    }
}
