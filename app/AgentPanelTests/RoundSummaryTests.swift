import XCTest
import SwiftUI
@testable import AgentPanel

/// N210: where a round's time went (wall time, agents, waiting for you, packets and rebases, fix turns, cost), from a fixture action log.
final class RoundSummaryTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-19T10:00:00Z")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T16:00:00Z")!
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private let roundA = PlanRound(name: "A · Packets", cards: ["N1", "N2"], reason: "", status: "done")
    private let roundB = PlanRound(name: "B · Notch", cards: ["N3"], reason: "", status: "running")
    private let old = PlanRound(name: "Old", cards: ["N8"], reason: "", status: "done")
    private let empty = PlanRound(name: "Empty", cards: ["N9"], reason: "", status: "waiting")

    private func card(_ id: String, _ status: TaskStatus = .done) -> TaskCard {
        TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: "\(id) · Title of \(id)",
                 sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private var cards: [TaskCard] { [card("N1"), card("N2"), card("N3", .doing), card("N8"), card("N9", .todo)] }

    private func decision(_ minutes: Double, _ cardID: String, kind: String, by: DecisionRecord.By = .pm, _ result: DecisionRecord.Result = .answered,
                          question: String, answer: String = "", why: String = "", cost: Double? = nil) -> DecisionRecord {
        DecisionRecord(id: UUID().uuidString, time: at(minutes), cardID: cardID, agent: "a", kind: kind, question: question, by: by, result: result,
                       answer: answer, why: why, costUSD: cost)
    }

    /// The round click; a packet whose test run broke (a full disk) and went to the agent as a fix (before N202); a rebase request with its
    /// fix request; a broken run N202 retried by itself.
    /// Never write app-test.sh's runner-restart wording here: a compiler warning on these lines prints them into the test log, and the
    /// script then reports a runner restart that did not happen (N210). `"rebase"` is `AutopilotModel.rebaseKind`, written out for that reason
    /// (the main-actor constant read from here gave such a warning).
    private var decisions: [DecisionRecord] {
        [decision(4, "N1, N2", kind: "round", by: .you, question: "Round of 2 tasks", answer: "N1, N2"),
         decision(37, "N2", kind: DecisionCategory.fix.rawValue, question: "Packet failed: No space left on device (AgentPanelTests)", answer: "Passed on to the developer", cost: 0.20),
         decision(66, "N2", kind: "rebase", question: "Branch is behind main", answer: "Asked to rebase onto main", why: "main is 2 commits ahead of the branch."),
         decision(141, "N3", kind: DecisionCategory.review.rawValue, question: "Agent finished: prepare the review", answer: "Retry",
                  why: "Packet could not run (No space left on device); trying once more.")]
    }

    func testTheFixtureRebaseKindIsTheAutopilots() async {
        let kind = await MainActor.run { AutopilotModel.rebaseKind }
        XCTAssertEqual(kind, "rebase")
    }

    private func events() throws -> [ActionLogEvent] { ActionLogEvents.parse(try Fixture.text("rounds/actions.log")) }

    private func build(_ round: PlanRound, costs: [String: Double] = [:]) throws -> RoundTimelineData {
        RoundTimeline.build(round: round, project: "p", cards: cards, events: try events(), decisions: decisions, agentCosts: costs)
    }

    // MARK: a finished round

    func testAFinishedRoundSplitsItsTime() throws {
        let s = try build(roundA).summary
        XCTAssertTrue(s.finished)
        XCTAssertEqual(s.roundSeconds, 90 * 60, "10:00 sheet request → 11:30 script merge")
        XCTAssertEqual(s.workingSeconds, (35 + 25 + 20) * 60, "N1 35, N2 25 and the 20-minute fix; the rebase is not the agent's own work")
        XCTAssertEqual(s.waitingSeconds, (4 + 5) * 60, "the Round sheet and one question")
        XCTAssertEqual(s.packetSeconds, (8 + 7 + 8 + 6 + 10) * 60, "N1's packet, N2's failed one, two prepared ones and the rebase turn")
    }

    func testFixTurnsLeaveOutRebasesAndNameTheBrokenRuns() throws {
        let s = try build(roundA).summary
        XCTAssertEqual(s.fixRounds, 1)
        XCTAssertEqual(s.rebaseRounds, 1)
        XCTAssertEqual(s.infrastructureFixes, 1, "the fix went out for a broken test run")
        XCTAssertEqual(s.infrastructureRuns, 0)
        XCTAssertEqual(s.fixTurns, 1)
        XCTAssertEqual(s.infrastructureTurns, 1)
        XCTAssertEqual(Stats.fixTurnsText(s), "1 · 1 infra")
        XCTAssertTrue(try build(roundA).lanes.flatMap(\.items).contains { $0.title == "N2 rebasing" })
    }

    func testScriptMergesAreExactMergeTimes() throws {
        let data = try build(roundA)
        XCTAssertEqual(data.lanes.first { $0.id == "N2" }?.items.filter { $0.kind == .merged }.map(\.start), [at(90)])
        XCTAssertFalse(data.gaps.contains { $0.contains("No merge time") })
        XCTAssertFalse(data.summary.estimated.contains(.round))
    }

    func testPacketsRunFromTheirStartLineAndAFailedOneIsAnEstimate() throws {
        let data = try build(roundA)
        let packets = data.lanes.first { $0.id == "N2" }!.items.filter { $0.kind == .packet }
        XCTAssertEqual(packets.map { [$0.start, $0.end!] }, [[at(30), at(37)], [at(57), at(65)], [at(76), at(82)]])
        XCTAssertEqual(packets.first?.title, "N2 review packet failed")
        XCTAssertEqual(data.summary.estimated.subtracting([.cost]), [.packets], "only the failed packet's end is a guess (the cost always is)")
        XCTAssertTrue(data.summary.notes.contains { $0.hasPrefix("Packet") && $0.contains("(N2)") })
    }

    func testCostIsAlwaysAnEstimate() throws {
        let s = try build(roundA, costs: ["N1": 1.0, "N2": 2.5]).summary
        XCTAssertEqual(s.cost ?? 0, 3.70, accuracy: 0.0001)
        XCTAssertTrue(s.estimated.contains(.cost))
    }

    // MARK: a running round

    func testARunningRoundSaysWhatIsGuessed() throws {
        let s = try build(roundB).summary
        XCTAssertFalse(s.finished)
        XCTAssertEqual(s.roundSeconds, 31 * 60, "the other project's line is left out")
        XCTAssertEqual(s.workingSeconds, 20 * 60, "no finish line: up to the packet's start")
        XCTAssertEqual(s.packetSeconds, 10 * 60)
        XCTAssertEqual(s.waitingSeconds, 0)
        XCTAssertEqual(s.infrastructureRuns, 1, "retried by the panel, never sent to the agent")
        XCTAssertEqual(s.fixTurns, 1)
        XCTAssertEqual(s.estimated, [.working, .waiting])
        XCTAssertEqual(s.notes.count, 2)
        XCTAssertEqual(Stats.roundText(s.workingSeconds, .working, in: s), "≈ 20m")
        XCTAssertEqual(Stats.roundText(s.packetSeconds, .packets, in: s), "10m")
    }

    // MARK: Stats

    func testStatsRowsAreNewestFirstAndInTheRange() throws {
        let rows = Stats.rounds([old, roundA, roundB, empty], project: "p", cards: cards, events: try events(), decisions: decisions,
                                agentCosts: ["N1": 1.0], calendar: utc, now: now, days: 14)
        XCTAssertEqual(rows.map(\.name), ["B · Notch", "A · Packets"], "the September round is out of range; the empty one has nothing recorded")
        XCTAssertEqual(rows[1].summary, try build(roundA, costs: ["N1": 1.0]).summary, "the same numbers as the Timeline")
        XCTAssertEqual(Stats.rounds([old], project: "p", cards: cards, events: try events(), decisions: [], calendar: utc, now: now, days: 60).map(\.name), ["Old"])
    }

    // MARK: snapshots

    @MainActor func testSnapshots() throws {
        var stats = Stats()
        stats.rounds = Stats.rounds([old, roundA, roundB, empty], project: "p", cards: cards, events: try events(), decisions: decisions,
                                    agentCosts: ["N1": 1.2, "N2": 2.4, "N3": 0.8], calendar: utc, now: now, days: 14)
        let screen = StatsContent(stats: stats, usage: nil, range: .twoWeeks, now: now, calendar: utc, onRange: { _ in }, onOpen: { _ in }).background(Tok.bg)
        let statsPNG = try XCTUnwrap(SnapshotRenderer.render(view: screen, size: CGSize(width: 1280, height: 1060)))
        XCTAssertGreaterThan(statsPNG.count, 20_000)
        try save(statsPNG, "N210-stats-rounds.png")

        let events = try events(), decisions = decisions, cards = cards
        let build: (PlanRound) -> RoundTimelineData = {
            RoundTimeline.build(round: $0, project: "p", cards: cards, events: events, decisions: decisions, agentCosts: ["N1": 1.2, "N2": 2.4, "N3": 0.8])
        }
        for (round, name) in [(roundA, "N210-timeline-finished.png"), (roundB, "N210-timeline-running.png")] {
            let png = try XCTUnwrap(SnapshotRenderer.render(view: TimelineView(rounds: [roundA, roundB], initial: round.name, build: build), size: CGSize(width: 1280, height: 860)))
            XCTAssertGreaterThan(png.count, 20_000)
            try save(png, name)
        }
    }

    private func save(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    // MARK: N341: agents' time stops at the merge; notes per kind

    func testWorkingSecondsStopAtTheMergeAndNotesAreGroupedByKind() {
        let round = PlanRound(name: "Z", cards: ["N1", "N2", "N3"], reason: "", status: "done")
        func ev(_ m: Double, _ text: String) -> ActionLogEvent { ActionLogEvent(time: at(m), text: text, project: "p") }
        let events = [ev(0, "start N1 agent=a branch=b pane=c"), ev(10, "approved N1"),
                      ev(20, "fix request sent to c for N1"), ev(30, "command to w0:pA: Panel: N1 finished its work (Report written)."), ev(35, "approved N1"),
                      ev(0, "start N2 agent=a branch=b pane=d"), ev(12, "approved N2"),
                      ev(0, "start N3 agent=a branch=b pane=e"), ev(60, "command to w0:pA: Panel: N3 finished its work (Report written)."), ev(61, "approved N3")]
        let s = RoundTimeline.build(round: round, project: "p", cards: cards, events: events, decisions: []).summary
        XCTAssertEqual(s.workingSeconds, (10 + 10 + 12 + 60) * 60, "N1 0–10 and 20–30, N2 0–12, N3 0–60: nothing after a merge")
        XCTAssertEqual(s.notes, ["Work turn has no finish line (N1, N2): counted up to the next packet, merge or turn."])
    }
}
