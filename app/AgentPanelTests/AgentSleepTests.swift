import XCTest
@testable import AgentPanel

final class AgentSleepTests: XCTestCase {
    private var dir: TempDir!

    override func setUpWithError() throws { dir = try TempDir() }

    private func card(_ id: String = "A5", status: String = "doing") throws -> TaskCard {
        let url = try dir.write("data/tasks/\(id).md", "---\nid: \(id)\nproject: demo\nstatus: \(status)\nagent: dev-\(id.lowercased())\nbranch: pilot/\(id.lowercased())\nfiles:\n  - a\n---\n# \(id) · T\n\n## Report\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private func marker(_ card: TaskCard) -> SleepMarker {
        SleepMarker(agent: card.agent ?? "x", project: "demo", card: card.id, cardPath: card.url.path, branch: "b", session: "s", source: "/p.json", role: "/r.json", since: "t")
    }

    // MARK: idle detection and the never-sleep cases

    func testAnIdleOrDoneAgentOnAWorkedOnCardMaySleep() {
        for state in [AgentState.idle, .done] {
            XCTAssertNil(AgentSleep.refusal(status: .doing, agent: state, waiting: 0, hasSession: true), "\(state)")
            XCTAssertNil(AgentSleep.refusal(status: .needsFix, agent: state, waiting: 0, hasSession: true), "\(state)")
        }
    }

    func testNeverASleepWhileWorkingBlockedOrUnknown() {
        for state in [AgentState.working, .blocked, .unknown("x")] {
            XCTAssertNotNil(AgentSleep.refusal(status: .doing, agent: state, waiting: 0, hasSession: true), "\(state)")
        }
    }

    func testNeverWithAnOpenQuestionNoSessionOrABusyPanel() {
        XCTAssertEqual(AgentSleep.refusal(status: .doing, agent: .idle, waiting: 1, hasSession: true), "The agent has an open question; answer it first.")
        XCTAssertNotNil(AgentSleep.refusal(status: .doing, agent: .idle, waiting: 0, hasSession: false))
        XCTAssertNotNil(AgentSleep.refusal(status: .doing, agent: .idle, waiting: 0, hasSession: true, busy: true))
    }

    func testNeverACardInReviewOrAnyOtherStatus() {
        for status in [TaskStatus.review, .todo, .done, .blocked, .cancelled, .awaitingStartApproval] {
            XCTAssertNotNil(AgentSleep.refusal(status: status, agent: .idle, waiting: 0, hasSession: true), status.label)
        }
    }

    func testAutoSleepAlsoNeedsAReportAndANotFixedCard() {
        XCTAssertNil(AgentSleep.autoRefusal(status: .doing, agent: .idle, waiting: 0, hasSession: true, hasReport: true))
        XCTAssertNotNil(AgentSleep.autoRefusal(status: .doing, agent: .idle, waiting: 0, hasSession: true, hasReport: false), "stuck, not finished")
        XCTAssertNotNil(AgentSleep.autoRefusal(status: .needsFix, agent: .idle, waiting: 0, hasSession: true, hasReport: true))
        XCTAssertNotNil(AgentSleep.autoRefusal(status: .doing, agent: .working, waiting: 0, hasSession: true, hasReport: true))
        XCTAssertNotNil(AgentSleep.autoRefusal(status: .doing, agent: .idle, waiting: 2, hasSession: true, hasReport: true))
    }

    // MARK: idle timer

    func testTheTimerCountsFromWhenTheAgentWasFirstSeenIdle() {
        var tracker = AgentSleep.IdleTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        tracker.note(idle: ["a"], now: t0)
        tracker.note(idle: ["a"], now: t0.addingTimeInterval(299))
        XCTAssertEqual(tracker.due(minutes: 5, now: t0.addingTimeInterval(299)), [])
        XCTAssertEqual(tracker.due(minutes: 5, now: t0.addingTimeInterval(300)), ["a"])
        XCTAssertEqual(tracker.due(minutes: 0, now: t0.addingTimeInterval(9999)), [], "off")
    }

    func testAnAgentSeenWorkingAgainStartsOver() {
        var tracker = AgentSleep.IdleTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        tracker.note(idle: ["a", "b"], now: t0)
        tracker.note(idle: ["b"], now: t0.addingTimeInterval(200))
        tracker.note(idle: ["a", "b"], now: t0.addingTimeInterval(250))
        XCTAssertEqual(tracker.due(minutes: 5, now: t0.addingTimeInterval(320)), ["b"])
    }

    // MARK: markers and slots

    func testAMarkerRoundTripsAndIsRemovedOnWake() throws {
        let c = try card()
        XCTAssertFalse(AgentSleep.isSleeping(c, cache: dir.url))
        try AgentSleep.write(marker(c), cache: dir.url)
        XCTAssertTrue(AgentSleep.isSleeping(c, cache: dir.url))
        XCTAssertEqual(AgentSleep.markers(cache: dir.url), [marker(c)])
        AgentSleep.remove(agent: c.agent!, cache: dir.url)
        XCTAssertFalse(AgentSleep.isSleeping(c, cache: dir.url))
    }

    func testSleepingAgentsDoNotCountAgainstMaxParallel() throws {
        let a = try card("A5"), b = try card("B6"), c = try card("C7", status: "review"), d = try card("D8", status: "todo")
        XCTAssertEqual(AgentSleep.slotsHeld([a, b, c, d], markers: []), 3)
        XCTAssertEqual(AgentSleep.slotsHeld([a, b, c, d], markers: [marker(b)]), 2)
        try AgentSleep.write(marker(a), cache: dir.url)
        XCTAssertEqual(AgentSleep.slotsHeld([a, b, c, d], cache: dir.url), 2)
    }

    func testMarkersOfDoneCancelledOrMissingCardsAreStale() throws {
        let doing = try card("A5"), done = try card("B6", status: "done"), cancelled = try card("C7", status: "cancelled"), review = try card("D8", status: "review")
        let gone = try card("E9")
        let markers = [doing, done, cancelled, review, gone].map(marker)
        let stale = AgentSleep.stale(markers, project: "demo", cards: [doing, done, cancelled, review])
        XCTAssertEqual(Set(stale.map(\.card)), ["B6", "C7", "E9"])
        XCTAssertTrue(AgentSleep.stale(markers, project: "demo", cards: []).isEmpty, "no cards loaded yet: nothing is dropped")
        XCTAssertTrue(AgentSleep.stale(markers, project: "other", cards: [doing]).isEmpty, "another project's markers are left alone")
    }

    func testTheMarkerHasTheKeysTermShReads() throws {
        let c = try card()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(marker(c))) as? [String: Any]
        for key in ["agent", "card", "branch", "session", "source", "role"] { XCTAssertNotNil(object?[key], key) }
    }
}

final class AgentWakeFlowTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{\"agent\":\"dev-a5\",\"workspace_id\":\"wW\",\"pane_id\":\"wW:p1\",\"worktree_path\":\"/repo/.agent-worktrees/pilot-a5\",\"udid\":\"\"}\n", stderr: "") }
        try dir.write("roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\"}")
    }

    private func flow() -> StartTaskFlow {
        let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: dir.url.appendingPathComponent("data").path, maxParallel: 2,
                                    buildCommand: "build", xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: "Xcode",
                                    roles: ["dev": dir.url.appendingPathComponent("roles/dev.json").path], sourcePath: "/etc/demo/project.json")
        return StartTaskFlow(project: project, scripts: scripts, commander: commander, writer: CardWriter(), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")),
                             roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: { [] })
    }

    private func card() throws -> TaskCard {
        let url = try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: doing\nagent: dev-a5\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5 · T\n\n## Report\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    func testWakeForAMessageResumesTheSameSessionAndSendsNoCarryOnLine() async throws {
        _ = try await flow().resume(try card(), session: "sess-1", nudge: false)
        XCTAssertEqual(scripts.calls(of: .spawn).map(\.args.first), ["--resume"])
        XCTAssertEqual(scripts.calls(of: .spawn).first?.args[1], "sess-1")
        XCTAssertTrue(commander.prompts.isEmpty, "the message itself follows; the agent is not told to carry on first")
    }

    func testAManualWakeStillTellsTheAgentToCarryOn() async throws {
        _ = try await flow().resume(try card(), session: "sess-1")
        XCTAssertEqual(commander.prompts.count, 1)
    }
}

final class AgentSleepSnapshotTests: XCTestCase {
    @MainActor
    func testThePaneShowsAnActiveRowAndASleepingOne() throws {
        let agents = [AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .idle, cwd: "/repo/.agent-worktrees/a5", title: "dev-a5")]
        let pane = AgentsPane(state: .available(agents), phase: { _ in .idle }, onSleep: { _ in }, sleepWhy: { _ in nil },
                              sleeping: [SleepingAgent(cardID: "N261", title: "Put idle agents to sleep", agent: "dev-n261")], onWake: { _ in })
        XCTAssertNil(AgentsPane.text(for: .available([]), hasSleeping: true), "only sleeping agents: no empty-list line")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: pane.preferredColorScheme(.dark), size: CGSize(width: 420, height: 300)))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N261-sleeping.png")) }
    }
}
