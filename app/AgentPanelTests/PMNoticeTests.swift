import XCTest
@testable import AgentPanel

@MainActor
final class PMNoticeTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus) -> TaskCard { TaskCard(id: id, project: "d", status: status, agent: nil, branch: nil, kind: nil, files: [], title: "T", sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md")) }
    private func pm(_ state: AgentState = .idle, title: String = "PM", session: String? = "s1") -> AgentStatus { AgentStatus(paneID: "p1", workspaceID: "w", state: state, cwd: "/x", title: title, sessionID: session) }
    private let none: (TaskCard) -> TaskPhase? = { _ in nil }

    /// A notice that has already looked at the cards once (the first look only records).
    private func primed(_ cards: [TaskCard]) -> PMNotice {
        var n = PMNotice()
        n.observe(cards: cards, phase: none)
        return n
    }

    private final class Sent { var texts: [String] = []; var panes: [String] = [] }
    private func deliver(_ n: inout PMNotice, enabled: Bool = true, agents: [AgentStatus], sent: Sent) async {
        await n.deliver(enabled: enabled, agents: agents) { pane, session, text in sent.panes.append(pane); sent.texts.append(text) }
    }

    func testFirstRunTellsOnlyWhatNeedsThePM() async {
        var n = PMNotice(); let sent = Sent()
        n.observe(cards: [card("N1", .done), card("N2", .cancelled), card("N3", .review), card("N4", .needsFix), card("N5", .awaitingStartApproval), card("N6", .doing)], phase: none)
        XCTAssertEqual(n.pending.count, 3)
        XCTAssertTrue(n.pending[0].contains("N3") && n.pending[1].contains("N4") && n.pending[2].contains("N5"))
        await deliver(&n, agents: [pm()], sent: sent)
        XCTAssertFalse(sent.texts[0].contains("N1") || sent.texts[0].contains("N2"))
    }

    func testRestartWithNoChangeSendsNoCardLines() async {
        var n = PMNotice(told: ["N1": "done", "N2": "review", "N3": "needsFix"]); let sent = Sent()
        n.observe(cards: [card("N1", .done), card("N2", .review), card("N3", .needsFix), card("N4", .doing)], phase: none)
        await deliver(&n, agents: [pm()], sent: sent)
        XCTAssertTrue(n.pending.isEmpty)
        XCTAssertTrue(sent.texts.isEmpty)
    }

    func testRestartWithOneChangeSendsOneLine() async {
        var n = PMNotice(told: ["N1": "done", "N2": "review"]); let sent = Sent()
        n.observe(cards: [card("N1", .done), card("N2", .done)], phase: none)
        XCTAssertEqual(n.pending.count, 1)
        await deliver(&n, agents: [pm()], sent: sent)
        XCTAssertEqual(sent.texts, ["Panel: N2 is done."])
    }

    func testToldIsRememberedOnlyAfterDelivery() async {
        var n = PMNotice(told: ["N1": "review"]); let sent = Sent()
        n.observe(cards: [card("N1", .done)], phase: none)
        XCTAssertEqual(n.told, ["N1": "review"], "not delivered yet: a restart now would send it again")
        await deliver(&n, agents: [pm()], sent: sent)
        XCTAssertEqual(n.told, ["N1": "done"])
    }

    func testNoCardsYetKeepsWhatWasTold() {
        var n = PMNotice(told: ["N1": "done"])
        n.observe(cards: [], phase: none)
        n.observe(cards: [card("N1", .done)], phase: none)
        XCTAssertTrue(n.pending.isEmpty)
    }

    func testOneLinePerChange() async {
        var n = primed([card("N1", .doing), card("N2", .doing), card("N3", .doing), card("N4", .doing)])
        n.observe(cards: [card("N1", .review), card("N2", .needsFix), card("N3", .done), card("N4", .doing)], phase: { $0.id == "N4" ? .finished : nil })
        let lines = n.pending
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("N1") && lines[0].contains("ready for review"))
        XCTAssertTrue(lines[1].contains("N2") && lines[1].contains("needs a fix"))
        XCTAssertTrue(lines[2].contains("N3") && lines[2].contains("done"))
        XCTAssertTrue(lines[3].contains("N4") && lines[3].contains("finished"))
    }

    func testFinishedAnnouncedOncePerReport() {
        func c(_ report: String) -> TaskCard { TaskCard(id: "N1", project: "d", status: .doing, agent: nil, branch: nil, kind: nil, files: [], title: "T", sections: ["Report": report], url: URL(fileURLWithPath: "/tmp/N1.md")) }
        var n = primed([c("a")])
        n.observe(cards: [c("a")], phase: { _ in .finished })
        XCTAssertEqual(n.pending.count, 1)
        n.observe(cards: [c("a")], phase: none)
        n.observe(cards: [c("a")], phase: { _ in .finished })
        XCTAssertEqual(n.pending.count, 1, "busy then finished with the same Report is not news")
        n.observe(cards: [c("b")], phase: { _ in .finished })
        XCTAssertEqual(n.pending.count, 2, "a changed Report is")
    }

    func testBatchedIntoOneMessageNoRepeat() async {
        var n = primed([card("N1", .doing), card("N2", .doing)]); let sent = Sent()
        n.observe(cards: [card("N1", .review), card("N2", .review)], phase: none)
        await deliver(&n, agents: [pm()], sent: sent)
        XCTAssertEqual(sent.texts.count, 1)
        XCTAssertTrue(sent.texts[0].hasPrefix("Panel:"))
        XCTAssertTrue(sent.texts[0].contains("N1") && sent.texts[0].contains("N2"))
        XCTAssertEqual(sent.panes, ["p1"])
        n.observe(cards: [card("N1", .review), card("N2", .review)], phase: none)
        await deliver(&n, agents: [pm()], sent: sent)
        XCTAssertEqual(sent.texts.count, 1)
    }

    func testWaitsWhilePMWorksThenSendsOnce() async {
        var n = primed([card("N1", .doing)]); let sent = Sent()
        n.observe(cards: [card("N1", .review)], phase: none)
        await deliver(&n, agents: [pm(.working)], sent: sent)
        XCTAssertTrue(sent.texts.isEmpty)
        await deliver(&n, agents: [pm(.idle)], sent: sent)
        XCTAssertEqual(sent.texts.count, 1)
        await deliver(&n, agents: [pm(.idle)], sent: sent)
        XCTAssertEqual(sent.texts.count, 1)
    }

    func testOffSwitchSendsNothingAndDoesNotReplayLater() async {
        var n = primed([card("N1", .doing)]); let sent = Sent()
        n.observe(cards: [card("N1", .review)], phase: none)
        await deliver(&n, enabled: false, agents: [pm()], sent: sent)
        await deliver(&n, enabled: true, agents: [pm()], sent: sent)
        XCTAssertTrue(sent.texts.isEmpty)
    }

    func testNoPMPaneSendsNothing() async {
        var n = primed([card("N1", .doing)]); let sent = Sent()
        n.observe(cards: [card("N1", .review)], phase: none)
        await deliver(&n, agents: [], sent: sent)
        await deliver(&n, agents: [pm(title: "dev N1")], sent: sent)
        XCTAssertTrue(sent.texts.isEmpty)
    }

    func testFailedSendIsRetriedNextTime() async {
        var n = primed([card("N1", .doing)])
        n.observe(cards: [card("N1", .review)], phase: none)
        await n.deliver(enabled: true, agents: [pm()]) { _, _, _ in throw BackendError.failed("gone") }
        XCTAssertEqual(n.pending.count, 1)
    }

    // N50
    private let wt = URL(fileURLWithPath: "/repo/.agent-worktrees")
    private func agent(_ pane: String, _ title: String, cwd: String, _ state: AgentState = .idle, session: String? = nil) -> AgentStatus {
        AgentStatus(paneID: pane, workspaceID: "w", state: state, cwd: cwd, title: title, sessionID: session)
    }
    private func cardOn(_ id: String, branch: String) -> TaskCard {
        TaskCard(id: id, project: "d", status: .doing, agent: "dev-\(id)", branch: branch, kind: nil, files: [], title: "T", sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    func testTaskAgentNamedPMIsNeverThePM() {
        let task = agent("p2", "pm-g1", cwd: "/repo/.agent-worktrees/task-g1")
        let real = agent("p1", "PM", cwd: "/repo")
        let cards = [cardOn("G1", branch: "task/g1")]
        XCTAssertEqual(PMNotice.pmAgent(in: [task, real], cards: cards, worktrees: wt)?.paneID, "p1")
        XCTAssertNil(PMNotice.pmAgent(in: [task], cards: cards, worktrees: wt))
    }

    func testChosenSessionBeatsTitle() {
        let a = agent("p1", "PM", cwd: "/repo", session: "s1"), b = agent("p2", "notes", cwd: "/repo", session: "s2")
        XCTAssertEqual(PMNotice.pmAgent(in: [a, b], cards: [], worktrees: wt, chosenSession: "s2")?.paneID, "p2")
        XCTAssertEqual(PMNotice.pmAgent(in: [a, b], cards: [], worktrees: wt, chosenSession: "gone")?.paneID, "p1")
    }

    func testBlockedPMGetsNothingUntilIdleOrDone() async {
        var n = primed([card("N1", .doing)]); let sent = Sent()
        n.observe(cards: [card("N1", .review)], phase: none)
        await deliver(&n, agents: [pm(.blocked)], sent: sent)
        XCTAssertTrue(sent.texts.isEmpty)
        await deliver(&n, agents: [pm(.done)], sent: sent)
        XCTAssertEqual(sent.texts.count, 1)
    }

    func testTwoProjectsEachGetOnlyTheirOwnNotices() async {
        let a = agent("pA", "PM", cwd: "/repoA"), b = agent("pB", "PM", cwd: "/repoB")
        var na = primed([card("A1", .doing)]), nb = primed([card("B1", .doing)]); let sent = Sent()
        na.observe(cards: [card("A1", .review)], phase: none); nb.observe(cards: [card("B1", .review)], phase: none)
        for (i, repo) in ["/repoA", "/repoB"].enumerated() {
            let mine = agents([a, b], belongingToRepo: repo)
            if i == 0 { await deliver(&na, agents: mine, sent: sent) } else { await deliver(&nb, agents: mine, sent: sent) }
        }
        XCTAssertEqual(sent.panes, ["pA", "pB"])
        XCTAssertTrue(sent.texts[0].contains("A1") && !sent.texts[0].contains("B1"))
        XCTAssertTrue(sent.texts[1].contains("B1") && !sent.texts[1].contains("A1"))
    }

    func testTwoConcurrentRefreshesSendOnce() async {
        let gate = TellGate(); var calls = 0; var started = false; var release: CheckedContinuation<Void, Never>?
        // the first call is held open until the second has arrived, so the order never depends on scheduling
        let first = Task { await gate.run { calls += 1; started = true; await withCheckedContinuation { release = $0 } } }
        while !started { await Task.yield() }
        await gate.run { calls += 1 }
        XCTAssertEqual(calls, 1, "a call that arrives while one runs is skipped")
        release?.resume()
        await first.value
        await gate.run { calls += 1 }
        XCTAssertEqual(calls, 2, "a later refresh runs again")
    }

    // N50 fix: the real PM has a free title and lives outside the repo
    func testTitleWithGlyphAndPMWordIsFound() {
        let real = agent("p1", "◐ Tentacl PM iletişim hiyerarşisi", cwd: "/repo")
        XCTAssertEqual(PMNotice.pmAgent(in: [real])?.paneID, "p1")
        XCTAssertEqual(PMNotice.pmAgent(in: [agent("p1", "✳ pm", cwd: "/repo")])?.paneID, "p1")
        XCTAssertNil(PMNotice.pmAgent(in: [agent("p1", "Upmarket notes", cwd: "/repo")]))
    }

    func testRememberedPMOutsideTheRepoIsValidButNeverOnACard() {
        let outside = agent("p1", "Tentacl", cwd: "/elsewhere/orchard", session: "s1")
        XCTAssertEqual(PMNotice.pmAgent(in: [outside], repo: "/repo", chosenSession: "s1")?.paneID, "p1")
        XCTAssertNil(PMNotice.pmAgent(in: [agent("p1", "◐ Tentacl PM", cwd: "/elsewhere/orchard")], repo: "/repo"), "title fallback stays inside the repo")
        let onCard = agent("p2", "x", cwd: "/repo/.agent-worktrees/task-g1", session: "s2")
        XCTAssertNil(PMNotice.pmAgent(in: [onCard], cards: [cardOn("G1", branch: "task/g1")], worktrees: wt, repo: "/repo", chosenSession: "s2"))
    }

    func testNoticeReachesRememberedPMOutsideTheRepo() async {
        var n = primed([card("N1", .doing)]); let sent = Sent()
        n.observe(cards: [card("N1", .review)], phase: none)
        await n.deliver(enabled: true, agents: [agent("p1", "◐ Tentacl PM", cwd: "/elsewhere", session: "s1")], repo: "/repo", chosenSession: "s1") { p, _, t in sent.panes.append(p); sent.texts.append(t) }
        XCTAssertEqual(sent.panes, ["p1"])
    }
}
