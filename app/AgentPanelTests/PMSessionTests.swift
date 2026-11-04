import XCTest
@testable import AgentPanel

final class PMStatusTests: XCTestCase {
    private func agent(_ state: AgentState) -> AgentStatus { AgentStatus(paneID: "p", workspaceID: "w", state: state, cwd: "/repo", title: "PM") }

    func testNoSessionIsMissing() {
        XCTAssertEqual(PMStatus(agent: nil), .missing)
    }

    func testWorkingOrBlockedIsRunningAndTheRestIsIdle() {
        XCTAssertEqual(PMStatus(agent: agent(.working)), .running)
        XCTAssertEqual(PMStatus(agent: agent(.blocked)), .running)
        XCTAssertEqual(PMStatus(agent: agent(.idle)), .idle)
        XCTAssertEqual(PMStatus(agent: agent(.done)), .idle)
        XCTAssertEqual(PMStatus(agent: agent(.unknown("x"))), .idle)
    }

    func testEachStateHasAWordForTheUser() {
        XCTAssertEqual(PMStatus.missing.label, "Not running")
        XCTAssertEqual(PMStatus.running.label, "Running")
        XCTAssertEqual(PMStatus.idle.label, "Idle")
    }
}

@MainActor
final class PMSessionTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        defaults = makeTestDefaults()
    }

    private func makeModel(agents: [AgentStatus] = [], withPMRole: Bool = true, pmTool: String? = nil, keySender: TerminalKeySending? = nil, server: TerminalServerEnsuring = NoTerminalServerCheck()) async throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        let toolKey = pmTool.map { "\"tool\":\"\($0)\"," } ?? ""
        let role = "{\"name\":\"pm\",\"kind\":\"interactive\",\(toolKey)\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"pm.md\"}"
        try dir.write("roles/pm.json", role)
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: todo\nagent:\nbranch: pilot/a5\nfiles:\n  - App/A5.swift\n---\n# A5 · Title\n\n## Goal\nGoal.\n")
        let roles = withPMRole ? ",\"roles\":{\"pm\":\"\(dir.url.appendingPathComponent("roles/pm.json").path)\"}" : ""
        let project = try dir.write("p/demo.json", """
        {"id":"demo","name":"Demo","repoPath":"/repo","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"b","sharedFiles":[],"openWith":"Xcode"\(roles)}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let terminal = FakeTerminal(agentsResult: .success(agents))
        let s = scripts!, c = FakeCommander()
        let m = PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: RecordingOpener(),
                           makeScripts: { _ in s }, makeCommander: { c }, log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                           defaults: defaults, roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")),
                           makeKeySender: { keySender ?? PanelModel.inertTerminal }, terminalServer: server)
        await m.reload()
        return m
    }

    private func pm(_ state: AgentState = .idle) -> AgentStatus { AgentStatus(paneID: "w2:p1", workspaceID: "w2", state: state, cwd: "/repo", title: "pm-demo", sessionID: "pm-s", name: "pm-demo") }
    private func task() -> AgentStatus { AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .working, cwd: "/repo/.agent-worktrees/pilot-a5", title: "dev-a5") }

    func testThePMStateIsReadFromTheProjectsAgents() async throws {
        let none = try await makeModel(agents: [task()])
        XCTAssertEqual(none.pmStatus, .missing, "a task agent is never the PM")
        let idle = try await makeModel(agents: [pm(.idle)])
        XCTAssertEqual(idle.pmStatus, .idle)
        let busy = try await makeModel(agents: [pm(.working)])
        XCTAssertEqual(busy.pmStatus, .running)
    }

    func testStartPMRunsTheSpawnScriptWithThePMRoleAndNoCard() async throws {
        let m = try await makeModel()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{\"agent\":\"pm-demo\"}\n", stderr: "") }
        await m.startPM()
        let call = try XCTUnwrap(scripts.calls(of: .spawn).first)
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1)
        XCTAssertEqual(call.args.count, 3)
        XCTAssertEqual(call.args[0], "--no-card")
        XCTAssertTrue(call.args[1].hasSuffix("p/demo.json"), call.args[1])
        XCTAssertTrue(call.args[2].hasSuffix("roles/pm.json"), call.args[2])
        guard case .done = m.actionState else { return XCTFail("expected done, got \(m.actionState)") }
    }

    func testStartPMChecksTheServerFirstAndRunsNothingWhenItCannotStart() async throws {
        let server = RecordingServer()
        let m = try await makeModel(server: server)
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{}\n", stderr: "") }
        await m.startPM()
        XCTAssertEqual(server.calls, 1)
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1)

        let down = RecordingServer(); down.failure = BackendError.failed("the terminal did not start within 5 s")
        let m2 = try await makeModel(server: down)
        await m2.startPM()
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1, "no new spawn")
        guard case .failed(let message) = m2.actionState else { return XCTFail("expected failed, got \(m2.actionState)") }
        XCTAssertEqual(message, "the terminal did not start within 5 s")
    }

    func testRawTerminalJSONFromTheScriptIsShownAsItsMessage() async throws {
        let m = try await makeModel()
        let raw = #"ERROR: terminal is not reachable: {"id":"x","error":{"code":"server_not_running","message":"no terminal server is running; run `terminal` to start or attach it"}}"#
        scripts.handler = { _, _ in ScriptResult(status: 1, stdout: "", stderr: raw) }
        await m.startPM()
        guard case .failed(let message) = m.actionState else { return XCTFail("expected failed") }
        XCTAssertEqual(message, "ERROR: terminal is not reachable: no terminal server is running; run `terminal` to start or attach it")
    }

    func testACodexPMRoleStartsWithoutAClaudeNote() async throws {
        let m = try await makeModel(pmTool: "codex")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{\"agent\":\"pm-demo\"}\n", stderr: "") }
        await m.startPM()
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1)
        guard case .done(let message) = m.actionState else { return XCTFail("expected done, got \(m.actionState)") }
        XCTAssertEqual(message, "Started the PM.")
    }

    func testAClaudePMRoleGetsNoClaudeNote() async throws {
        let m = try await makeModel(pmTool: "claude")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{}\n", stderr: "") }
        await m.startPM()
        guard case .done(let message) = m.actionState else { return XCTFail("expected done") }
        XCTAssertFalse(message.contains("Claude Code"), message)
    }

    func testStartPMWithoutAPMRoleSaysSoAndRunsNothing() async throws {
        let m = try await makeModel(withPMRole: false)
        await m.startPM()
        XCTAssertTrue(scripts.calls.isEmpty)
        guard case .failed(let message) = m.actionState else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("pm"), message)
    }

    func testStartPMDoesNothingWhileAPMRuns() async throws {
        let m = try await makeModel(agents: [pm()])
        await m.startPM()
        XCTAssertTrue(scripts.calls.isEmpty)
    }

    func testAFailedStartShowsTheScriptsReason() async throws {
        let m = try await makeModel()
        scripts.handler = { _, _ in ScriptResult(status: 1, stdout: "", stderr: "ERROR: dev-demo is already running\n") }
        await m.startPM()
        guard case .failed(let message) = m.actionState else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("already running"), message)
    }

    func testStopAsksFirstAndOnlyTheConfirmationRunsTheStopScript() async throws {
        let m = try await makeModel(agents: [pm()])
        m.requestStop(pm())
        XCTAssertEqual(m.pendingStop, pm())
        XCTAssertTrue(scripts.calls.isEmpty, "asking must not stop anything")
        m.cancelStop()
        XCTAssertNil(m.pendingStop)
        XCTAssertTrue(scripts.calls.isEmpty)
        m.requestStop(pm())
        await m.confirmStop()
        let call = try XCTUnwrap(scripts.calls(of: .stop).first)
        XCTAssertEqual(call.args, ["pm-demo", "/repo", "--no-sim"])
        XCTAssertNil(m.pendingStop)
    }

    func testStopRunsEvenWhenTheDialogHasAlreadyClearedThePendingAgent() async throws {
        let m = try await makeModel(agents: [pm()])
        m.requestStop(pm())
        let agent = try XCTUnwrap(m.pendingStop)
        m.cancelStop() // the dialog dismissing itself before the button's Task runs
        await m.stop(agent)
        XCTAssertEqual(scripts.calls(of: .stop).count, 1)
    }

    func testAFailedStopIsShownNotReportedAsStopped() async throws {
        let m = try await makeModel(agents: [pm()])
        scripts.handler = { _, _ in ScriptResult(status: 1, stdout: "", stderr: "ERROR: could not close\n") }
        await m.stop(pm())
        guard case .failed(let message) = m.actionState else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("could not close"), message)
    }

    func testAnAgentOnACardCannotBeStoppedFromHere() async throws {
        let m = try await makeModel(agents: [task()])
        let onCard = AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .working, cwd: "/repo/.agent-worktrees/pilot-a5", title: "dev-a5")
        XCTAssertFalse(m.canStop(onCard))
        XCTAssertTrue(m.canStop(pm()))
    }

    func testOpenTerminalAsksTheTerminalsScreenForTheAgentsTab() async throws {
        let m = try await makeModel(agents: [pm()])
        XCTAssertNil(m.terminalFocus)
        await m.openTerminal(pm())
        XCTAssertEqual(m.terminalFocus?.pane, "w2:p1")
        let first = m.terminalFocus
        await m.openTerminal(pm())
        XCTAssertNotEqual(m.terminalFocus, first, "asking again for the same tab is a new request")
    }
}
