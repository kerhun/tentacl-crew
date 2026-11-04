import XCTest
import SwiftUI
@testable import AgentPanel

final class RoundTimelineTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-18T19:00:00Z")!
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func ev(_ minutes: Double, _ text: String, project: String? = "p") -> ActionLogEvent { ActionLogEvent(time: at(minutes), text: text, project: project) }

    private func card(_ id: String, _ status: TaskStatus = .done, decision: String? = nil) -> TaskCard {
        var sections = ["Goal": "Goal of \(id)."]
        if let decision { sections["Decision"] = decision }
        return TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: "Title \(id)",
                        sections: sections, url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func decision(_ minutes: Double, _ cardID: String, kind: String = "choice", by: DecisionRecord.By, _ result: DecisionRecord.Result,
                          question: String = "Q?", answer: String = "", why: String = "", cost: Double? = nil) -> DecisionRecord {
        DecisionRecord(id: UUID().uuidString, time: at(minutes), cardID: cardID, agent: "a", kind: kind, question: question, by: by, result: result,
                       answer: answer, why: why, costUSD: cost)
    }

    private let round = PlanRound(name: "R", cards: ["N1", "N2"], reason: "", status: "done")

    /// N1: requested in the sheet at 0, clicked at 4, worked 5–25, packet at 27, packet again at 40, a question 41–51, merged at 52.
    /// N2: worked 5–15, packet at 16, fix 20–30, packet at 31, done notice at 33 (no merge line).
    private var events: [ActionLogEvent] {
        [ev(0, "start-request 1 sheet cards=N1,N2 started= refused="),
         ev(5, "start N1 agent=dev-n1-p branch=task/n1 pane=w1:p1"),
         ev(5, "start N2 agent=dev-n2-p branch=task/n2 pane=w2:p1"),
         ev(15, "command to w0:pA: Panel: N2 finished its work (Report written)."),
         ev(16, "review packet prepared for N2"),
         ev(20, "fix request sent to w2:p1 for N2"),
         ev(25, "command to w0:pA: Panel: N1 finished its work (Report written)."),
         ev(27, "review packet prepared for N1"),
         ev(30, "command to w0:pA: Panel: N2 finished its work (Report written); N1 is ready for review."),
         ev(31, "review packet prepared for N2"),
         ev(33, "command to w0:pA: Panel: N2 is done; N1 is r"),
         ev(40, "review packet prepared for N1"),
         ev(41, "asked N1 (choice)"),
         ev(51, "answered N1 (w1:p1)"),
         ev(52, "approved N1"),
         ev(53, "start N9 agent=dev-n9-p branch=task/n9 pane=w9:p1"),
         ev(54, "start N1 agent=other branch=x pane=y", project: "other")]
    }

    private var decisions: [DecisionRecord] {
        [decision(4, "N1, N2", kind: "round", by: .you, .answered, question: "Round of 2 tasks", answer: "N1, N2"),
         decision(16, "N2", kind: "review", by: .pm, .answered, question: "Agent finished: prepare the review", answer: "Review prepared", cost: 0.10),
         decision(41.1, "N1", by: .pm, .escalated, question: "Add a key first?", why: "Security choice", cost: 0.05),
         decision(51, "N1", by: .you, .answered, question: "Add a key first?", answer: "Yes")]
    }

    private func build(cards: [TaskCard]? = nil, events: [ActionLogEvent]? = nil, decisions: [DecisionRecord]? = nil, costs: [String: Double] = [:], now: Date = Date()) -> RoundTimelineData {
        RoundTimeline.build(round: round, project: "p", cards: cards ?? [card("N1", decision: "2026-10-18 · PM: merged."), card("N2")],
                            events: events ?? self.events, decisions: decisions ?? self.decisions, agentCosts: costs, now: now)
    }

    private func items(_ data: RoundTimelineData, lane: String, _ kind: TimelineItem.Kind) -> [TimelineItem] {
        data.lanes.first { $0.id == lane }?.items.filter { $0.kind == kind } ?? []
    }

    func testAResetOfThePMStartCountInsideTheRoundShowsInThePMLane() {
        let reset = decision(20, "PM authority", kind: AutopilotModel.authorityResetKind, by: .you, .answered, question: "PM start count reset", answer: "0",
                             why: "count reset by the user")
        let later = decision(90, "PM authority", kind: AutopilotModel.authorityResetKind, by: .you, .answered, question: "PM start count reset", answer: "0")
        let pm = items(build(decisions: decisions + [reset, later]), lane: "PM", .pmDecision)
        XCTAssertEqual(pm.filter { $0.title.contains("count reset") }.map(\.start), [at(20)], "only the reset inside the round's span")
        XCTAssertEqual(pm.first { $0.start == at(20) }?.why, "count reset by the user")
    }

    func testLanesArePMThenTheRoundCardsInPlanOrder() {
        let data = build()
        XCTAssertEqual(data.lanes.map(\.id), ["PM", "N1", "N2"])
        XCTAssertEqual(data.lanes[1].title, "Title N1")
        let titled = TaskCard(id: "N1", project: "p", status: .done, agent: nil, branch: nil, kind: nil, files: [], title: "N1 · Short", sections: [:], url: URL(fileURLWithPath: "/tmp/N1.md"))
        XCTAssertEqual(build(cards: [titled]).lanes[1].title, "Short")
    }

    func testWorkingBarsRunFromStartOrFixToTheNextFinish() {
        let data = build()
        XCTAssertEqual(items(data, lane: "N1", .working).map { [$0.start, $0.end] }, [[at(5), at(25)]])
        XCTAssertEqual(items(data, lane: "N2", .working).map { [$0.start, $0.end] }, [[at(5), at(15)], [at(20), at(30)]])
    }

    func testPacketBarsAndRepeatsAfterARebase() {
        let n1 = items(build(), lane: "N1", .packet)
        XCTAssertEqual(n1.map { [$0.start, $0.end] }, [[at(25), at(27)], [at(27), at(40)]])
        XCTAssertEqual(n1.map(\.isRepeat), [false, true])
        XCTAssertEqual(items(build(), lane: "N2", .packet).map(\.isRepeat), [false, false])
    }

    func testWaitingBarsForTheRoundSheetAndForAQuestion() {
        let waits = items(build(), lane: "N1", .waiting)
        XCTAssertEqual(waits.map { [$0.start, $0.end] }, [[at(0), at(4)], [at(41), at(51)]])
        // the decision record of the same question does not add a second wait or dot
        XCTAssertEqual(items(build(), lane: "N1", .asked).count, 1)
        XCTAssertTrue(items(build(), lane: "N1", .asked)[0].links.contains(.question("Add a key first?")))
    }

    func testMergedDotFromTheApprovalLineElseTheDoneNotice() {
        let data = build()
        XCTAssertEqual(items(data, lane: "N1", .merged).map(\.start), [at(52)])
        let n2 = items(data, lane: "N2", .merged)
        XCTAssertEqual(n2.map(\.start), [at(33)])
        XCTAssertTrue(data.gaps.contains { $0.contains("N2") }, "a merge time taken from the done notice is a gap")
    }

    func testPMLaneHoldsThePMDecisionsOnly() {
        let pm = build().lanes[0].items
        XCTAssertEqual(pm.map(\.kind), [.pmDecision])
        XCTAssertEqual(pm.first?.start, at(16))
    }

    func testOtherProjectsAndOtherCardsAreLeftOut() {
        let all = build().lanes.flatMap(\.items)
        XCTAssertFalse(all.contains { $0.start == at(53) || $0.start == at(54) })
    }

    func testSummaryNumbers() {
        let s = build(costs: ["N1": 1.0, "N2": 2.0]).summary
        XCTAssertEqual(s.roundSeconds, 52 * 60)
        XCTAssertEqual(s.workingSeconds, (20 + 10 + 10) * 60)
        XCTAssertEqual(s.waitingSeconds, (4 + 10) * 60)
        XCTAssertEqual(s.fixRounds, 1)
        XCTAssertEqual(s.cost ?? 0, 3.15, accuracy: 0.0001)
    }

    func testDelaysAreRankedByTimeLost() {
        let delays = build().delays
        XCTAssertLessThanOrEqual(delays.count, 3)
        XCTAssertEqual(delays.map(\.kind), [.repeatedPackets, .questions, .fixes])
        XCTAssertEqual(delays[0].seconds, 13 * 60)
        XCTAssertEqual(delays[1].count, 1)
        XCTAssertTrue(delays[1].text.contains("N1"))
        XCTAssertEqual(delays.map(\.seconds), delays.map(\.seconds).sorted(by: >))
    }

    func testRankingFollowsTheData() {
        // A long Round sheet wait moves the sheet to the top.
        var long = events
        long[0] = ev(-60, "start-request 1 sheet cards=N1,N2 started= refused=")
        var d = decisions
        d[0] = decision(4, "N1, N2", kind: "round", by: .you, .answered)
        XCTAssertEqual(build(events: long, decisions: d).delays.first?.kind, .roundSheet)
    }

    func testMissingDataDegrades() {
        let data = build(events: [], decisions: [])
        XCTAssertEqual(data.lanes.map(\.id), ["PM", "N1", "N2"])
        XCTAssertTrue(data.lanes.allSatisfy(\.items.isEmpty))
        XCTAssertNil(data.start)
        XCTAssertNil(data.summary.roundSeconds)
        XCTAssertNil(data.summary.cost)
        XCTAssertTrue(data.delays.isEmpty)
        XCTAssertFalse(data.gaps.isEmpty)
    }

    func testAStartWithoutAFinishStaysOpen() {
        let data = build(events: [ev(0, "start N1 agent=a branch=b pane=c")], decisions: [])
        let w = items(data, lane: "N1", .working)
        XCTAssertEqual(w.count, 1)
        XCTAssertNil(w[0].end)
        XCTAssertEqual(data.summary.workingSeconds, 0)
    }

    func testTicksAreRoundTimesInsideTheWindow() {
        let ticks = RoundTimeline.ticks(from: at(3), to: at(52))
        XCTAssertGreaterThanOrEqual(ticks.count, 3)
        XCTAssertLessThanOrEqual(ticks.count, 9)
        XCTAssertTrue(ticks.allSatisfy { $0 >= at(3) && $0 <= at(52) })
        XCTAssertTrue(ticks.allSatisfy { Int($0.timeIntervalSince1970) % 300 == 0 })
    }

    func testDetailsSayWhatAndWhy() {
        let data = build()
        let wait = items(data, lane: "N1", .waiting)[1]
        XCTAssertTrue(wait.what.contains("Add a key first?"))
        XCTAssertEqual(wait.why, "Security choice")
        XCTAssertTrue(wait.links.contains(.card("N1")))
        let merged = items(data, lane: "N1", .merged)[0]
        XCTAssertTrue(merged.why.contains("PM: merged."))
        XCTAssertTrue(merged.links.contains(.packet("N1")))
    }

    @MainActor func testTimelineViewRenders() throws {
        let other = PlanRound(name: "Empty", cards: ["N3"], reason: "", status: "waiting")
        let data = build()
        let view = TimelineView(rounds: [round, other], initial: "R", build: { $0.name == "R" ? data : RoundTimeline.build(round: $0, project: "p", cards: [], events: [], decisions: []) })
        let png = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1200, height: 820)))
        XCTAssertGreaterThan(png.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("timeline.png")) }
        let empty = try XCTUnwrap(SnapshotRenderer.render(view: TimelineView(rounds: [other], initial: nil, build: { RoundTimeline.build(round: $0, project: "p", cards: [], events: [], decisions: []) }),
                                                          size: CGSize(width: 1200, height: 500)))
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try empty.write(to: URL(fileURLWithPath: dir).appendingPathComponent("timeline-empty.png")) }
    }

    // MARK: N341: bars end at the merge

    /// N1: started at 0, no finish line, approved at 10; reopened by a fix at 20, finished at 30, approved at 35.
    /// N2: started at 0 and finished at 60, so the round runs well past N1's merges.
    private var mergedWithoutFinish: [ActionLogEvent] {
        [ev(0, "start N1 agent=a branch=b pane=w1:p1"),
         ev(0, "start N2 agent=a branch=b pane=w2:p1"),
         ev(10, "approved N1"),
         ev(20, "fix request sent to w1:p1 for N1"),
         ev(30, "command to w0:pA: Panel: N1 finished its work (Report written)."),
         ev(35, "approved N1"),
         ev(60, "command to w0:pA: Panel: N2 finished its work (Report written).")]
    }

    func testAWorkTurnWithoutAFinishEndsAtTheMergeAndAReopenIsANewSegment() {
        let data = build(events: mergedWithoutFinish, decisions: [])
        XCTAssertEqual(items(data, lane: "N1", .working).map { [$0.start, $0.end] }, [[at(0), at(10)], [at(20), at(30)]])
        XCTAssertEqual(data.end, at(60))
        let n1 = data.lanes.first { $0.id == "N1" }!.items.filter(\.isBar)
        XCTAssertTrue(n1.allSatisfy { $0.end != nil && $0.end! <= at(35) }, "nothing of N1 is drawn after its last merge")
    }

    func testAWorkTurnWithoutAFinishEndsAtTheNextPacketOrDoneLine() {
        let data = build(events: [ev(0, "start N1 agent=a branch=b pane=c"), ev(8, "review packet started for N1"), ev(12, "review packet prepared for N1"),
                                  ev(0, "start N2 agent=a branch=b pane=d"), ev(9, "command to w0:pA: Panel: N2 is done."),
                                  ev(40, "start N9 agent=a branch=b pane=e")], decisions: [])
        XCTAssertEqual(items(data, lane: "N1", .working).map(\.end), [at(8)])
        XCTAssertEqual(items(data, lane: "N2", .working).map(\.end), [at(9)])
    }

    func testAWorkTurnWithoutAFinishEndsAtTheNextTurnAtTheLatest() {
        let data = build(events: [ev(0, "start N1 agent=a branch=b pane=c"), ev(15, "fix request sent to c for N1"),
                                  ev(25, "command to w0:pA: Panel: N1 finished its work (Report written).")], decisions: [])
        XCTAssertEqual(items(data, lane: "N1", .working).map { [$0.start, $0.end] }, [[at(0), at(15)], [at(15), at(25)]])
        XCTAssertEqual(data.summary.workingSeconds, 25 * 60)
        XCTAssertTrue(data.summary.estimated.contains(.working))
    }

    // MARK: N355: a work bar with no recorded end never runs to the round's end

    /// N1 started at 0 with no finish; N2 worked 0–60, so the round runs to 60.
    private func openEnd(_ more: [ActionLogEvent] = []) -> [ActionLogEvent] {
        [ev(0, "start N1 agent=a branch=b pane=c"), ev(0, "start N2 agent=a branch=b pane=d"),
         ev(60, "command to w0:pA: Panel: N2 finished its work (Report written).")] + more
    }

    func testAnOpenTurnOfACardStillInProgressRunsToNow() {
        let data = build(cards: [card("N1", .doing), card("N2", .review)], events: openEnd(), decisions: [], now: at(90))
        let w = items(data, lane: "N1", .working)[0]
        XCTAssertEqual(w.tail, .live)
        XCTAssertNil(w.end)
        XCTAssertEqual(data.drawnEnd(w), at(90))
        XCTAssertEqual(data.windowEnd, at(90))
        XCTAssertTrue(w.what.contains("still working"))
    }

    func testAnOpenTurnStopsAtTheCardsNextMomentAsAGuess() {
        let data = build(cards: [card("N1", .done), card("N2")], events: openEnd([ev(12, "review packet prepared for N1")]), decisions: [], now: at(90))
        let w = items(data, lane: "N1", .working)[0]
        XCTAssertEqual(w.tail, .guessed)
        XCTAssertEqual(data.drawnEnd(w), at(12))
        XCTAssertEqual(data.windowEnd, at(60))
    }

    func testAnOpenTurnWithNothingAfterItIsAShortStubNotTheRound() {
        let data = build(cards: [card("N1", .done), card("N2")], events: openEnd(), decisions: [], now: at(90))
        let w = items(data, lane: "N1", .working)[0]
        XCTAssertEqual(w.tail, .unknown)
        XCTAssertEqual(data.drawnEnd(w), at(0).addingTimeInterval(RoundTimelineData.unknownStub))
        XCTAssertLessThan(data.drawnEnd(w), at(60))
        XCTAssertEqual(data.windowEnd, at(60))
        XCTAssertEqual(data.summary.workingSeconds, 60 * 60, "the stub adds no working time")
    }

    /// The dark screenshot of the card (`tasks/N355-timeline.png`): a recorded bar, a guessed tail, a stub and a live bar.
    @MainActor func testOpenEndShot() throws {
        let r = PlanRound(name: "R", cards: ["N1", "N2", "N3", "N4"], reason: "", status: "running")
        let events = openEnd([ev(0, "start N3 agent=a branch=b pane=e"), ev(25, "review packet prepared for N3"),
                              ev(30, "start N4 agent=a branch=b pane=f")])
        let data = RoundTimeline.build(round: r, project: "p", cards: [card("N1", .done), card("N2", .review), card("N3", .review), card("N4", .doing)],
                                       events: events, decisions: [], now: at(75))
        // A real dark window (AppKit hosting), not ImageRenderer.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: TimelineView(rounds: [r], initial: "R", build: { _ in data }).environment(\.colorScheme, .dark))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N355-timeline.png")) }
    }

    /// The dark screenshot of the card (`tasks/N341-timeline.png`): chart right under the tiles, the ≈ notes under the chart.
    @MainActor func testTimelineNotesSitUnderTheChart() throws {
        let data = build(events: mergedWithoutFinish + [ev(40, "asked N2 (choice)")], decisions: [])
        XCTAssertEqual(data.summary.notes.count, 2)
        let view = TimelineView(rounds: [round], initial: "R", build: { _ in data }).preferredColorScheme(.dark)
        let png = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1200, height: 760)))
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N341-timeline.png")) }
    }
}
