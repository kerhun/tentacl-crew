import XCTest
@testable import AgentPanel

final class CommandCenterTests: XCTestCase {
    private var dir: TempDir!
    private var commander: FakeCommander!
    private var logURL: URL!

    override func setUpWithError() throws {
        dir = try TempDir()
        commander = FakeCommander()
        logURL = dir.url.appendingPathComponent("actions.log")
    }

    private func agent(_ pane: String, _ title: String = "", _ state: AgentState = .idle, session: String? = nil) -> AgentStatus {
        AgentStatus(paneID: pane, workspaceID: "w", state: state, cwd: "/x", title: title, sessionID: session)
    }

    /// Records the order of calls so a test can see that the target check came before the send.
    private final class OrderedTerminal: TerminalListing, TerminalCommanding, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        var agentsNow: [AgentStatus]
        var listError: BackendError?
        init(_ agents: [AgentStatus]) { agentsNow = agents }
        func agents() async throws -> [AgentStatus] { note("list"); if let listError { throw listError }; return agentsNow }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
        func prompt(target: String, text: String) async throws { note("prompt:\(target):\(text)") }
        private func note(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
    }

    private func center(_ terminal: OrderedTerminal) -> CommandCenter {
        CommandCenter(adapter: terminal, commander: terminal, log: ActionLog(fileURL: logURL))
    }

    func testCommandLineNamesTheProject() async throws {
        let h = OrderedTerminal([agent("w3:p1", "PM")])
        try await center(h).send("hello", to: "w3:p1", project: "demo")
        XCTAssertTrue(ActionLog(fileURL: logURL).read().contains(" [demo] command to w3:p1"))
    }

    func testSendsToExistingTarget() async throws {
        let h = OrderedTerminal([agent("w3:p1", "PM")])
        try await center(h).send("plan the next tasks", to: "w3:p1")
        XCTAssertEqual(h.events, ["list", "prompt:w3:p1:plan the next tasks"])
    }

    /// Review Focus 5: the pane closed (or was reused) between selecting it and sending.
    func testVanishedTargetIsNotSent() async throws {
        let h = OrderedTerminal([agent("w3:p1", "PM")])
        do { try await center(h).send("hello", to: "w9:p1"); XCTFail("expected an error") }
        catch let e as BackendError { XCTAssertEqual(e, .failed("agent is no longer running")) }
        XCTAssertEqual(h.events, ["list"], "nothing may be sent to an agent that is gone")
    }

    func testTargetCheckHappensRightBeforeSending() async throws {
        let h = OrderedTerminal([agent("w3:p1")])
        let c = center(h)
        try await c.send("one", to: "w3:p1")
        h.agentsNow = []
        do { try await c.send("two", to: "w3:p1"); XCTFail("second send must notice the agent is gone") } catch {}
        XCTAssertEqual(h.events, ["list", "prompt:w3:p1:one", "list"])
    }

    func testEmptyTextRejected() async throws {
        let h = OrderedTerminal([agent("w3:p1")])
        do { try await center(h).send("  \n ", to: "w3:p1"); XCTFail("expected an error") }
        catch let e as BackendError { XCTAssertEqual(e, .failed("empty command")) }
        XCTAssertEqual(h.events, [])
    }

    func testPanelNoticeIsLoggedWholeOnOneLine() async throws {
        let h = OrderedTerminal([agent("w3:p1")])
        let notice = "Panel: N91 is done; " + String(repeating: "y", count: 120) + "\nN92 is ready for review."
        try await center(h).send(notice, to: "w3:p1")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("command to w3:p1: Panel: N91 is done; " + String(repeating: "y", count: 120) + " N92 is ready for review.\n"), log)
        XCTAssertEqual(log.split(separator: "\n").count, 1)
    }

    func testLogsTargetAndPreview() async throws {
        let h = OrderedTerminal([agent("w3:p1")])
        let long = String(repeating: "x", count: 200)
        try await center(h).send(long, to: "w3:p1")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("command to w3:p1"))
        XCTAssertTrue(log.contains(String(repeating: "x", count: 80)))
        XCTAssertFalse(log.contains(String(repeating: "x", count: 81)), "only the first 80 characters are logged")
    }

    func testFailedSendIsNotLoggedAsSent() async throws {
        let h = OrderedTerminal([])
        _ = try? await center(h).send("hello", to: "w3:p1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testTerminalDownGivesClearError() async throws {
        let h = OrderedTerminal([]); h.listError = .notRunning("no terminal server")
        do { try await center(h).send("hello", to: "w3:p1"); XCTFail("expected an error") }
        catch let e as BackendError { XCTAssertEqual(e, .notRunning("no terminal server")) }
        XCTAssertEqual(h.events, ["list"])
    }

    func testDefaultTargetPrefersRemembered() {
        let agents = [agent("w2:pA", "PM"), agent("w3:p1", "dev-a5")]
        XCTAssertEqual(CommandCenter.defaultTarget(in: agents, remembered: "w3:p1"), "w3:p1")
    }

    func testDefaultTargetFallsBackToPM() {
        let agents = [agent("w3:p1", "dev-a5"), agent("w2:pA", "PM · orchard")]
        XCTAssertEqual(CommandCenter.defaultTarget(in: agents, remembered: "gone"), "w2:pA")
        XCTAssertEqual(CommandCenter.defaultTarget(in: agents, remembered: nil), "w2:pA")
        XCTAssertEqual(CommandCenter.defaultTarget(in: [agent("w3:p1", "dev"), agent("w4:p1", "dev2")], remembered: nil), "w3:p1")
    }

    /// I5: the pane id is not an identity by itself; the session running in it is.
    func testSendRefusesWhenPaneNowHostsAnotherSession() async throws {
        let h = OrderedTerminal([agent("w3:p1", "PM", session: "session-NEW")])
        do { try await center(h).send("revert and force-push", to: "w3:p1", expectingSession: "session-OLD"); XCTFail("expected an error") }
        catch let e as BackendError { XCTAssertEqual(e, .failed("agent is no longer running")) }
        XCTAssertEqual(h.events, ["list"], "the command must not reach the new occupant of the pane")
    }

    func testSendWithMatchingSessionWorks() async throws {
        let h = OrderedTerminal([agent("w3:p1", "PM", session: "session-1")])
        try await center(h).send("hello", to: "w3:p1", expectingSession: "session-1")
        XCTAssertEqual(h.events, ["list", "prompt:w3:p1:hello"])
    }

    func testRememberedTargetWithSessionMustMatchTheSession() {
        let agents = [agent("w3:p1", "dev", session: "other-session"), agent("w2:pA", "PM", session: "pm-session")]
        XCTAssertEqual(CommandCenter.defaultTarget(in: agents, remembered: "w3:p1|old-session"), "w2:pA", "a reused pane must not be picked from memory")
        XCTAssertEqual(CommandCenter.defaultTarget(in: agents, remembered: "w3:p1|other-session"), "w3:p1")
    }

    func testResolveTargetKeepsAChosenAgentThatIsStillThere() {
        let agents = [agent("w3:p1", "dev", session: "s1")]
        XCTAssertEqual(CommandCenter.resolveTarget(chosen: ChosenTarget(paneID: "w3:p1", sessionID: "s1", label: "dev"), agents: agents, remembered: nil), .keep("w3:p1"))
    }

    /// I5: the agent the user picked is gone: say so, do not quietly retarget to the PM.
    func testResolveTargetReportsAVanishedAgentInsteadOfRetargeting() {
        let agents = [agent("w2:pA", "PM", session: "pm")]
        XCTAssertEqual(CommandCenter.resolveTarget(chosen: ChosenTarget(paneID: "w3:p1", sessionID: "s1", label: "dev-a5"), agents: agents, remembered: nil), .gone("dev-a5"))
    }

    func testResolveTargetTreatsAReusedPaneAsGone() {
        let agents = [agent("w3:p1", "something else", session: "s2")]
        XCTAssertEqual(CommandCenter.resolveTarget(chosen: ChosenTarget(paneID: "w3:p1", sessionID: "s1", label: "dev-a5"), agents: agents, remembered: nil), .gone("dev-a5"))
    }

    func testResolveTargetUsesTheDefaultOnlyWhenNothingWasChosen() {
        let agents = [agent("w3:p1", "dev"), agent("w2:pA", "PM")]
        XCTAssertEqual(CommandCenter.resolveTarget(chosen: nil, agents: agents, remembered: nil), .choose("w2:pA"))
        XCTAssertEqual(CommandCenter.resolveTarget(chosen: nil, agents: [], remembered: nil), .choose(nil))
    }

    func testDefaultTargetNilWhenNoAgents() {
        XCTAssertNil(CommandCenter.defaultTarget(in: [], remembered: "w3:p1"))
    }

    // N50
    func testReadyOnlySendRefusesBlockedAndWorking() async {
        for state in [AgentState.blocked, .working] {
            let h = OrderedTerminal([agent("w3:p1", "PM", state)])
            do { try await center(h).send("hi", to: "w3:p1", requireReady: true); XCTFail("sent to \(state)") } catch {}
            XCTAssertEqual(h.events, ["list"])
        }
        for state in [AgentState.idle, .done] {
            let h = OrderedTerminal([agent("w3:p1", "PM", state)])
            try? await center(h).send("hi", to: "w3:p1", requireReady: true)
            XCTAssertEqual(h.events, ["list", "prompt:w3:p1:hi"])
        }
    }

    // N92: the panel's lines to a busy PM wait in an outbox instead of being dropped.

    @MainActor
    func testOutboxWaitsWhileTheAgentIsBusyAndThenSendsInOrder() async {
        let box = PanelOutbox()
        box.add("Panel: one.", pane: "p1")
        box.add("Panel: two.", pane: "p1")
        var sent: [String] = []
        for state in [AgentState.working, .blocked, .unknown("x")] {
            await box.deliver(agents: [agent("p1", "PM", state)], send: { item, _ in sent.append(item.text) }, dropped: { _ in XCTFail("dropped") })
        }
        XCTAssertEqual(sent, [], "never sent while working or while a menu is showing")
        XCTAssertEqual(box.items.map(\.text), ["Panel: one.", "Panel: two."])
        await box.deliver(agents: [agent("p1", "PM", .idle)], send: { item, _ in sent.append(item.text) }, dropped: { _ in })
        XCTAssertEqual(sent, ["Panel: one.", "Panel: two."])
        XCTAssertTrue(box.items.isEmpty)
    }

    @MainActor
    func testOutboxKeepsTheOrderWhenASendFails() async {
        let box = PanelOutbox()
        box.add("a", pane: "p1"); box.add("b", pane: "p1"); box.add("c", pane: "p2")
        var sent: [String] = []
        await box.deliver(agents: [agent("p1", "PM", .idle), agent("p2", "PM", .done)], send: { item, _ in
            if item.text == "a" { throw BackendError.failed("agent is busy") }
            sent.append(item.text)
        }, dropped: { _ in })
        XCTAssertEqual(sent, ["c"], "a failure stops that pane only; b never jumps ahead of a")
        XCTAssertEqual(box.items.map(\.text), ["a", "b"])
        await box.deliver(agents: [agent("p1", "PM", .idle)], send: { item, _ in sent.append(item.text) }, dropped: { _ in })
        XCTAssertEqual(sent, ["c", "a", "b"])
    }

    @MainActor
    func testOutboxDropsAndReportsAMessageStillWaitingAfterHalfAnHour() async {
        let box = PanelOutbox()
        let start = Date(timeIntervalSince1970: 1_000)
        box.add("old", pane: "p1", now: start)
        box.add("new", pane: "p1", now: start.addingTimeInterval(25 * 60))
        var dropped: [String] = []
        await box.deliver(agents: [agent("p1", "PM", .working)], now: start.addingTimeInterval(29 * 60), send: { _, _ in }, dropped: { dropped.append($0.text) })
        XCTAssertEqual(dropped, [])
        await box.deliver(agents: [agent("p1", "PM", .working)], now: start.addingTimeInterval(31 * 60), send: { _, _ in }, dropped: { dropped.append($0.text) })
        XCTAssertEqual(dropped, ["old"])
        XCTAssertEqual(box.items.map(\.text), ["new"])
    }

    // N211: a dropped message becomes a Waiting for you item with Retry and Dismiss.

    @MainActor
    func testDroppedMessageIsKeptWithItsReason() async {
        let box = PanelOutbox()
        let start = Date(timeIntervalSince1970: 1_000)
        box.add("busy", pane: "p1", project: "proj", now: start)
        box.add("gone", pane: "p9", project: "proj", now: start)
        await box.deliver(agents: [agent("p1", "PM", .working)], now: start.addingTimeInterval(31 * 60), send: { _, _ in }, dropped: { _ in })
        XCTAssertTrue(box.items.isEmpty)
        XCTAssertEqual(box.undelivered.map(\.item.text), ["busy", "gone"])
        XCTAssertEqual(box.undelivered.map(\.reason), ["the agent was busy for 30 minutes", "the agent's pane is gone"])
        let items = dashboardWaitingItems(questions: [], fixes: [], cards: [], roundWaiting: [], approveRound: 0, undelivered: box.undelivered.map(\.id))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(waitingDecisionCount(items), 2)
    }

    @MainActor
    func testRetryRequeuesADroppedMessageAndDismissForgetsIt() async {
        let box = PanelOutbox()
        let start = Date(timeIntervalSince1970: 1_000)
        box.add("a", pane: "p1", project: "proj", now: start)
        box.add("b", pane: "p1", now: start)
        await box.deliver(agents: [agent("p1", "PM", .working)], now: start.addingTimeInterval(31 * 60), send: { _, _ in }, dropped: { _ in })
        let ids = box.undelivered.map(\.id)
        box.dismiss(ids[1])
        XCTAssertEqual(box.undelivered.map(\.item.text), ["a"])
        let again = box.retry(ids[0], now: start.addingTimeInterval(32 * 60))
        XCTAssertEqual(again?.project, "proj")
        XCTAssertTrue(box.undelivered.isEmpty)
        XCTAssertNil(box.retry(ids[0]), "already retried")
        var sent: [String] = []
        await box.deliver(agents: [agent("p1", "PM", .idle)], now: start.addingTimeInterval(33 * 60), send: { item, _ in sent.append(item.text) }, dropped: { _ in XCTFail("dropped") })
        XCTAssertEqual(sent, ["a"])
        XCTAssertTrue(box.items.isEmpty)
    }

    func testPreferredTargetBeatsTitleGuess() {
        let agents = [agent("a", "pm-g1"), agent("b", "PM")]
        XCTAssertEqual(CommandCenter.defaultTarget(in: agents, remembered: nil, preferred: "b"), "b")
        XCTAssertEqual(CommandCenter.defaultTarget(in: agents, remembered: nil, preferred: "gone"), "a")
    }
}
