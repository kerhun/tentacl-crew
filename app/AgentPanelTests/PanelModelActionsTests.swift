import XCTest
@testable import AgentPanel

@MainActor
final class PanelModelActionsTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
        defaults = makeTestDefaults()
    }

    private func card(_ id: String, _ status: String, branch: String = "pilot/a5") -> String {
        "---\nid: \(id)\nproject: demo\nstatus: \(status)\nagent:\nbranch: \(branch)\nfiles:\n  - App/\(id).swift\n---\n# \(id) · Title\n\n## Goal\nGoal.\n"
    }

    /// One project with a dev role; the scripts folder is configured unless `withScripts` is false.
    private func makeModel(withScripts: Bool = true, withRole: Bool = true, agents: [AgentStatus] = [], projectID: String = "demo") throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\"}")
        try dir.write("data/tasks/A5.md", card("A5", "awaiting-start-approval"))
        let roles = withRole ? ",\"roles\":{\"dev\":\"\(dir.url.appendingPathComponent("roles/dev.json").path)\"}" : ""
        let project = try dir.write("p/\(projectID).json", """
        {"id":"\(projectID)","name":"Demo","repoPath":"/repo","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"b","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"\(roles)}
        """)
        let scriptsKey = withScripts ? ",\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"" : ""
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"]\(scriptsKey)}")
        let terminal = FakeTerminal(agentsResult: .success(agents))
        let s = scripts!, c = commander!
        return PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: RecordingOpener(),
                          makeScripts: { _ in s }, makeCommander: { c }, log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                          defaults: defaults, roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")))
    }

    private func pm() -> AgentStatus { AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: "/x", title: "PM", sessionID: "pm-session") }

    func testStartPlanFailsWithoutScriptsDir() async throws {
        let m = try makeModel(withScripts: false)
        await m.reload()
        XCTAssertFalse(m.canStart)
        XCTAssertTrue(m.startDisabledReason?.contains("scriptsDir") ?? false)
        guard case .failure(.invalid) = m.startPlan(for: try XCTUnwrap(m.cards.first.flatMap { if case .card(let c) = $0 { return c } else { return nil } })) else { return XCTFail("expected a failure") }
    }

    func testStartIsNotDisabledForAMissingRoleButThePlanSaysWhichRoleIsMissing() async throws {
        let m = try makeModel(withRole: false)
        await m.reload()
        XCTAssertTrue(m.canStart, "roles are resolved when a task is planned, not before")
        let card = try XCTUnwrap(m.selectedCardForTest)
        guard case .failure(let error) = m.startPlan(for: card), case .missingRole = error else { return XCTFail("expected a missing-role plan") }
        let message = error.message
        XCTAssertTrue(message.contains("dev"), message)
    }

    func testConfirmStartRefreshesCardsAndAgents() async throws {
        let m = try makeModel(agents: [pm()])
        await m.reload()
        let plan = try XCTUnwrap(try? m.startPlan(for: try XCTUnwrap(m.selectedCardForTest)).get())
        await m.confirmStart(plan)
        guard case .done = m.actionState else { return XCTFail("expected done, got \(m.actionState)") }
        let a5 = try XCTUnwrap(m.cards.compactMap { r -> TaskCard? in if case .card(let c) = r { return c } else { return nil } }.first)
        XCTAssertEqual(a5.status, .doing)
        XCTAssertEqual(a5.agent, "dev-a5")
        XCTAssertEqual(m.agents, .available([pm()]))
    }

    func testFailedStartShowsMessageAndKeepsCard() async throws {
        scripts.handler = { script, _ in script == .spawn ? ScriptResult(status: 1, stdout: "", stderr: "ERROR: terminal is not reachable\n") : ScriptResult(status: 0, stdout: "", stderr: "") }
        let m = try makeModel()
        await m.reload()
        let plan = try XCTUnwrap(try? m.startPlan(for: try XCTUnwrap(m.selectedCardForTest)).get())
        await m.confirmStart(plan)
        guard case .failed(let message) = m.actionState else { return XCTFail("expected failed, got \(m.actionState)") }
        XCTAssertTrue(message.contains("terminal is not reachable"))
        XCTAssertEqual(try XCTUnwrap(m.selectedCardForTest).status, .awaitingStartApproval)
    }

    /// Review Focus 2: two confirms in a row (double click, two windows) start one agent.
    func testDoubleConfirmRunsOnce() async throws {
        let gate = TestGate()
        let base = FakeScripts().handler
        scripts.handler = { script, args in if script == .spawn { await gate.wait() }; return try await base(script, args) }
        let m = try makeModel()
        await m.reload()
        let plan = try XCTUnwrap(try? m.startPlan(for: try XCTUnwrap(m.selectedCardForTest)).get())
        let first = Task { await m.confirmStart(plan) }
        for _ in 0..<300 where scripts.calls(of: .spawn).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await m.confirmStart(plan)   // the second one must return at once without starting anything
        await gate.release()
        await first.value
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1)
        XCTAssertEqual(commander.prompts.count, 1)
    }

    func testSendCommandShowsFailureWhenAgentVanished() async throws {
        let m = try makeModel(agents: [])
        await m.reload()
        await m.sendCommand("hello", to: "w9:p1", session: nil)
        guard case .failed(let message) = m.actionState else { return XCTFail("expected failed, got \(m.actionState)") }
        XCTAssertTrue(message.contains("no longer running"))
        XCTAssertEqual(commander.prompts.count, 0)
    }

    func testSendCommandSucceedsAndRemembersTarget() async throws {
        let m = try makeModel(agents: [pm()])
        await m.reload()
        await m.sendCommand("plan the next tasks", to: "w2:pA", session: "pm-session")
        guard case .done = m.actionState else { return XCTFail("expected done, got \(m.actionState)") }
        // The fixture's waiting start request is also told to the PM (first run: only cards that need it), then the user's command.
        XCTAssertTrue(commander.prompts.allSatisfy { $0.target == "w2:pA" })
        XCTAssertTrue(commander.prompts.contains { $0.text == "plan the next tasks" })
        XCTAssertEqual(m.rememberedTarget, "w2:pA|pm-session")
    }

    func testActionsDisabledWhileAnotherRuns() async throws {
        let gate = TestGate()
        let base = FakeScripts().handler
        scripts.handler = { script, args in if script == .spawn { await gate.wait() }; return try await base(script, args) }
        let m = try makeModel(agents: [pm()])
        await m.reload()
        let plan = try XCTUnwrap(try? m.startPlan(for: try XCTUnwrap(m.selectedCardForTest)).get())
        let start = Task { await m.confirmStart(plan) }
        for _ in 0..<300 where scripts.calls(of: .spawn).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await m.sendCommand("hello", to: "w2:pA", session: "pm-session")
        XCTAssertEqual(commander.prompts.filter { $0.text == "hello" }.count, 0, "a command must wait for the running action")
        await gate.release()
        await start.value
    }

    func testRememberedTargetPersistsPerProject() async throws {
        let m = try makeModel(agents: [pm()])
        await m.reload()
        await m.sendCommand("hi", to: "w2:pA", session: "pm-session")
        XCTAssertEqual(m.rememberedTarget, "w2:pA|pm-session")
        XCTAssertEqual(defaults.string(forKey: "commandTarget.demo"), "w2:pA|pm-session")
        XCTAssertNil(defaults.string(forKey: "commandTarget.other"))
    }

    func testTheAddProjectFormStartsInTheFoldersOfTheFirstProject() async throws {
        let m = try makeModel()
        await m.reload()
        let flow = try XCTUnwrap(m.makeAddProjectFlow())
        XCTAssertEqual(flow.repoParent, "/")
        XCTAssertEqual(flow.dataRoot, dir.url.path)
    }

    func testTheAddProjectFormNeedsTheScriptsFolder() async throws {
        let m = try makeModel(withScripts: false)
        await m.reload()
        XCTAssertNil(m.makeAddProjectFlow())
    }

    func testAnAddedProjectIsShownAndSelected() async throws {
        let m = try makeModel()
        await m.reload()
        let other = try dir.write("p/other.json", #"{"id":"other","name":"Other","repoPath":"/o","dataDir":"\#(dir.url.path)/odata","maxParallel":2,"sharedFiles":[]}"#)
        let settings = dir.url.appendingPathComponent("settings.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        object["projects"] = ((object["projects"] as? [String]) ?? []) + [other.path]
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
        await m.projectAdded("other")
        XCTAssertEqual(m.selectedProject?.id, "other")
        XCTAssertEqual(m.projects.count, 2)
    }

    func testMessageToAnAgentOnNoCardInsideTheRepoMakesItThePM() async throws {
        let real = AgentStatus(paneID: "w5:p1", workspaceID: "w", state: .idle, cwd: "/repo", title: "◐ Tentacl PM iletişim", sessionID: "sess-pm")
        let m = try makeModel(agents: [real])
        await m.reload()
        await m.sendCommand("hello", to: "w5:p1", session: "sess-pm")
        XCTAssertEqual(defaults.string(forKey: "pmSession.demo"), "sess-pm")
        XCTAssertEqual(m.pmPane(forProject: "demo"), "w5:p1")
        XCTAssertEqual(m.pmSession(forProject: "demo"), "sess-pm")
        guard case .available(let shown) = m.visibleAgents else { return XCTFail() }
        XCTAssertEqual(shown.map(\.paneID), ["w5:p1"])
    }

    /// N129: an agent outside the project's folder never becomes its PM by a first message.
    func testMessageToAnAgentOutsideTheRepoDoesNotMakeItThePM() async throws {
        let real = AgentStatus(paneID: "w5:p1", workspaceID: "w", state: .idle, cwd: "/elsewhere/orchard", title: "◐ Tentacl PM iletişim", sessionID: "sess-pm")
        let m = try makeModel(agents: [real])
        await m.reload()
        await m.sendCommand("hello", to: "w5:p1", session: "sess-pm")
        XCTAssertNil(m.pmSession(forProject: "demo"))
        XCTAssertNil(m.pmPane(forProject: "demo"))
    }

    /// N110: the last Command box target no longer makes a PM; only a chosen session or a PM-titled agent in the repo does.
    func testTheLastCommandBoxTargetIsNotAPM() async throws {
        let real = AgentStatus(paneID: "w5:p1", workspaceID: "w", state: .idle, cwd: "/elsewhere/orchard", title: "◐ Tentacl PM iletişim", sessionID: "sess-pm")
        defaults.set("w5:p1|sess-pm", forKey: "commandTarget.demo")
        let m = try makeModel(agents: [real])
        await m.reload()
        XCTAssertNil(m.pmSession(forProject: "demo"))
        XCTAssertNil(m.pmPane(forProject: "demo"))
    }
}

extension PanelModel {
    /// The first card of the loaded project (tests only).
    var selectedCardForTest: TaskCard? {
        for case .card(let c) in cards { return c }
        return nil
    }

}
