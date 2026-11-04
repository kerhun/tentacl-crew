import XCTest
import SwiftUI
@testable import AgentPanel

final class StatsTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus, deps: String? = nil, modified: Date? = nil) -> TaskCard {
        var c = TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: "Title \(id)",
                         sections: deps.map { ["Dependencies": $0] } ?? [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        c.modified = modified
        return c
    }

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    // MARK: backlog

    @MainActor func testBacklogGroupsByStatusInOrderAndOmitsEmptyGroups() {
        let groups = Backlog.groups(from: [card("A", .done), card("B", .todo), card("C", .doing), card("D", .review)])
        XCTAssertEqual(groups.map(\.title), ["Needs your decision", "Doing", "Backlog", "Done"])
    }

    @MainActor func testDependsOnListsKnownCardsAndMarksUnfinishedOnesAsBlocking() {
        let groups = Backlog.groups(from: [card("A", .done), card("B", .todo), card("C", .todo, deps: "- A\n- B\n- Z (unknown)")])
        let c = groups.flatMap(\.items).first { $0.card.id == "C" }!
        XCTAssertEqual(c.dependsOn, ["A", "B"])
        XCTAssertEqual(c.blockedBy, ["B"])
    }

    @MainActor func testBlocksIsTheReverseOfDependsOn() {
        let groups = Backlog.groups(from: [card("B", .todo), card("C", .todo, deps: "B")])
        let b = groups.flatMap(\.items).first { $0.card.id == "B" }!
        XCTAssertEqual(b.blocks, ["C"])
    }

    @MainActor func testFinishedCardsAreNeverBlocked() {
        let groups = Backlog.groups(from: [card("B", .todo), card("C", .done, deps: "B")])
        XCTAssertEqual(groups.flatMap(\.items).first { $0.card.id == "C" }!.blockedBy, [])
    }

    // MARK: action log

    func testParsesLogLinesAndSkipsGarbage() {
        let events = ActionLogEvents.parse("2026-10-17T08:00:00Z start N1 agent=x branch=b pane=1\nnot a line\n2026-10-17T09:30:00Z approved N1\n")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].text, "approved N1")
        XCTAssertEqual(events[1].time, date("2026-10-17T09:30:00Z"))
    }

    func testProjectTagIsReadFromNewLinesAndOldLinesHaveNone() {
        let events = ActionLogEvents.parse("2026-10-17T08:00:00Z [alpha] approved N1\n2026-10-17T09:00:00Z approved N1\n")
        XCTAssertEqual(events.map(\.project), ["alpha", nil])
        XCTAssertEqual(events.map(\.text), ["approved N1", "approved N1"])
    }

    func testAppendWritesTheProjectTagWhenGiven() throws {
        let dir = try TempDir()
        let log = ActionLog(fileURL: dir.url.appendingPathComponent("log"))
        log.append("asked N1 (choice)", project: "alpha")
        log.append("plain")
        let events = ActionLogEvents.parse(log.read())
        XCTAssertEqual(events.map(\.project), ["alpha", nil])
        XCTAssertEqual(events.map(\.text), ["asked N1 (choice)", "plain"])
    }

    func testTwoProjectsWithTheSameCardIDStayApartInStats() {
        let events = ActionLogEvents.parse("""
        2026-10-17T08:00:00Z [q] start A agent=a branch=b pane=1
        2026-10-17T08:10:00Z [p] start A agent=a branch=b pane=1
        2026-10-17T09:00:00Z [p] review packet prepared for A
        2026-10-17T09:40:00Z [p] approved A
        2026-10-17T10:00:00Z [q] approved A
        """)
        let s = Stats.compute(cards: [card("A", .done)], events: events, calendar: utc, now: date("2026-10-17T12:00:00Z"))
        XCTAssertEqual(s.flows[0].total, 90 * 60, "card A is in project p: the lines of q are not used")
    }

    // MARK: stats

    func testDurationRunsFromFirstSuccessfulStartToApproval() {
        let events = ActionLogEvents.parse("""
        2026-10-17T08:00:00Z start A FAILED: nope
        2026-10-17T08:10:00Z start A agent=a branch=b pane=1
        2026-10-17T09:00:00Z review packet prepared for A
        2026-10-17T09:40:00Z approved A
        """)
        let s = Stats.compute(cards: [card("A", .done)], events: events, calendar: utc, now: date("2026-10-17T12:00:00Z"))
        XCTAssertEqual(s.flows.map(\.cardID), ["A"])
        XCTAssertEqual(s.flows[0].total, 90 * 60)
        XCTAssertEqual(s.medianTotal, 90 * 60)
    }

    /// N140: old cards merged in bulk (a start and an approval a minute apart, no review packet) and cards with no start made the medians
    /// read "agent 7m · waiting for you 0m"; they are left out of the medians and the bars, and counted.
    func testMediansSkipCardsWithoutStartPacketAndMerge() {
        let events = ActionLogEvents.parse("""
        2026-10-17T08:00:00Z start A agent=a branch=b pane=1
        2026-10-17T09:00:00Z review packet prepared for A
        2026-10-17T09:30:00Z approved A
        2026-10-17T09:27:00Z start B agent=b branch=b pane=1
        2026-10-17T09:28:00Z approved B
        2026-10-17T09:29:00Z approved C
        2026-10-17T10:00:00Z [p] start D agent=d branch=b pane=1
        2026-10-17T10:40:00Z [p] review packet prepared for D
        2026-10-17T11:00:00Z [p] merged D 0ab4cf5e5391e79f68f7062b9e422d5ec3c06263 (script)
        """)
        let s = Stats.compute(cards: ["A", "B", "C", "D"].map { card($0, .done) }, events: events, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        XCTAssertEqual(s.mergedCount, 4)
        XCTAssertEqual(Set(s.flows.map(\.cardID)), ["A", "D"], "B has no packet, C no start; D's merge line from merge-task.sh is its end")
        XCTAssertEqual(s.flowsLeftOut, 2)
        XCTAssertEqual(s.medianAgent, 50 * 60, "60 and 40 min")
        XCTAssertEqual(s.medianWaiting, 25 * 60, "30 and 20 min")
        XCTAssertNil(s.rows.first { $0.cardID == "B" }?.flow, "the table shows — for a card left out")
    }

    func testMergeLineFromTheScriptDatesTheMerge() {
        let events = ActionLogEvents.parse("""
        2026-10-16T23:00:00Z [p] merged A 0ab4cf5e5391e79f68f7062b9e422d5ec3c06263 (script)
        2026-10-16T23:00:00Z [p] merged test/v1-launch-screen into main at (nothing to merge) for V1
        """)
        let s = Stats.compute(cards: [card("A", .done, modified: date("2026-10-17T11:00:00Z"))], events: events, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 2)
        XCTAssertEqual(s.merged.map(\.count), [1, 0], "the merge line wins over the file date")
    }

    func testChangeAgainstThePreviousRange() {
        XCTAssertEqual(Stats.changeText(now: 140, before: 3, days: 7, logCoversBefore: true), "+137 vs the 7 days before")
        XCTAssertEqual(Stats.changeText(now: 4, before: 9, days: 7, logCoversBefore: true), "−5 vs the 7 days before")
        XCTAssertEqual(Stats.changeText(now: 4, before: 4, days: 14, logCoversBefore: true), "same as the 14 days before")
        XCTAssertEqual(Stats.changeText(now: 140, before: 3, days: 7, logCoversBefore: false), "no log for the 7 days before")
    }

    func testLogCoverageOfThePreviousRange() {
        let cards = [card("A", .done), card("B", .done), card("C", .done)]
        XCTAssertTrue(Stats.compute(cards: cards, events: flowLog, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 3).logCoversBefore, "the log starts on the 10th, the 3 days before start on the 12th")
        XCTAssertFalse(Stats.compute(cards: cards, events: flowLog, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7).logCoversBefore, "the 7 days before start on the 4th")
    }

    // MARK: merged tooltip (N140)

    func testTooltipCellsFitTheGrid() {
        let few = (1...7).map { "N\($0)" }
        XCTAssertEqual(MergedBarChart.tooltipCells(few), few)
        XCTAssertEqual(MergedBarChart.tooltipRows(few.count), 2)
        let full = (1...48).map { "N\($0)" }
        XCTAssertEqual(MergedBarChart.tooltipCells(full), full, "48 ids fill the grid")
        let many = (1...74).map { "N\($0)" }
        let cells = MergedBarChart.tooltipCells(many)
        XCTAssertEqual(cells.count, 48)
        XCTAssertEqual(cells.last, "+27 more")
        XCTAssertEqual(cells[46], "N47")
        XCTAssertEqual(MergedBarChart.tooltipRows(cells.count), 8)
        XCTAssertEqual(MergedBarChart.tooltipSize(ids: 74).width, MergedBarChart.tooltipWidth)
        XCTAssertEqual(MergedBarChart.tooltipSize(ids: 3).width, MergedBarChart.tooltipWidth, "same width with fewer ids")
        XCTAssertLessThan(MergedBarChart.tooltipSize(ids: 3).height, MergedBarChart.tooltipSize(ids: 74).height)
        XCTAssertLessThanOrEqual(MergedBarChart.tooltipSize(ids: 74).height, 190, "fits in the chart")
    }

    func testTooltipStaysInsideTheChart() {
        let box = CGSize(width: 800, height: 190), size = CGSize(width: 300, height: 160)
        let left = MergedBarChart.tooltipOrigin(bar: CGRect(x: 10, y: 100, width: 40, height: 90), size: size, in: box)
        XCTAssertEqual(left.x, 58, "right of the bar")
        let right = MergedBarChart.tooltipOrigin(bar: CGRect(x: 750, y: 5, width: 40, height: 185), size: size, in: box)
        XCTAssertEqual(right.x, 750 - 8 - 300, "flips left near the right edge")
        XCTAssertGreaterThanOrEqual(right.y, 0, "below the top edge")
        let narrow = MergedBarChart.tooltipOrigin(bar: CGRect(x: 100, y: 0, width: 40, height: 190), size: size, in: CGSize(width: 320, height: 190))
        XCTAssertTrue(narrow.x >= 0 && narrow.x + 300 <= 320, "clamped when it fits neither side")
        let low = MergedBarChart.tooltipOrigin(bar: CGRect(x: 10, y: 188, width: 40, height: 2), size: size, in: box)
        XCTAssertLessThanOrEqual(low.y + 160, 190, "above the bottom edge")
    }

    func testApprovalWithoutStartHasNoDuration() {
        let events = ActionLogEvents.parse("2026-10-17T09:40:00Z approved A")
        let s = Stats.compute(cards: [card("A", .done)], events: events, calendar: utc, now: date("2026-10-17T12:00:00Z"))
        XCTAssertTrue(s.flows.isEmpty)
        XCTAssertNil(s.medianTotal)
    }

    func testFinishedPerDayUsesApprovalThenCardModifiedAndFillsEmptyDays() {
        let events = ActionLogEvents.parse("2026-10-16T09:00:00Z approved A")
        let cards = [card("A", .done, modified: date("2026-10-17T01:00:00Z")),   // the log wins over the file date
                     card("B", .done, modified: date("2026-10-14T10:00:00Z")),   // no log entry: the file date
                     card("C", .doing, modified: date("2026-10-17T01:00:00Z"))]
        let s = Stats.compute(cards: cards, events: events, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 4)
        XCTAssertEqual(s.merged.count, 4)
        XCTAssertEqual(s.merged[0].count, 1)   // 14th: B
        XCTAssertEqual(s.merged[1].count, 0)   // 15th
        XCTAssertEqual(s.merged[2].count, 1)   // 16th: A
        XCTAssertEqual(s.merged[3].count, 0)   // 17th
    }

    func testDurationText() {
        XCTAssertEqual(Stats.durationText(90 * 60), "1 h 30 min")
        XCTAssertEqual(Stats.durationText(25 * 60), "25 min")
        XCTAssertEqual(Stats.durationText(26 * 3600 + 5 * 60), "1 d 2 h")
        XCTAssertEqual(Stats.durationText(20), "< 1 min")
    }

    // MARK: Stats screen (N137)

    /// A over two days with one fix round; B passed first time; C merged before the 7-day range.
    private var flowLog: [ActionLogEvent] {
        ActionLogEvents.parse("""
        2026-10-10T09:00:00Z [p] start C agent=c branch=b pane=3
        2026-10-10T09:30:00Z [p] review packet prepared for C
        2026-10-10T10:00:00Z [p] approved C
        2026-10-16T08:00:00Z [p] start A agent=a branch=b pane=1
        2026-10-16T08:40:00Z [p] review packet started for A
        2026-10-16T09:00:00Z [p] review packet prepared for A
        2026-10-16T09:20:00Z [p] fix request sent to 1 for A
        2026-10-16T09:50:00Z [p] review packet prepared for A
        2026-10-16T10:00:00Z [p] approved A
        2026-10-17T08:00:00Z [p] start B agent=b branch=b pane=2
        2026-10-17T08:30:00Z [p] review packet prepared for B
        2026-10-17T08:40:00Z [p] fix request for B NOT SENT: pane gone
        2026-10-17T09:00:00Z [p] approved B
        """)
    }

    func testFlowSplitsAgentAndWaitingWithAFixRound() throws {
        let s = Stats.compute(cards: [card("A", .done), card("B", .done)], events: flowLog, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        let a = try XCTUnwrap(s.flows.first { $0.cardID == "A" })
        XCTAssertEqual(a.agent, (60 + 30) * 60, "start → packet 60 min, fix → packet 30 min")
        XCTAssertEqual(a.waiting, (20 + 10) * 60, "packet → fix 20 min, packet → approved 10 min")
        XCTAssertEqual(a.total, 120 * 60)
        XCTAssertEqual(a.fixes, 1)
        XCTAssertEqual(a.steps.map(\.kind), [.start, .packet, .fix, .packet, .approved])
        let b = try XCTUnwrap(s.flows.first { $0.cardID == "B" })
        XCTAssertEqual(b.agent, 30 * 60)
        XCTAssertEqual(b.waiting, 30 * 60, "a fix request that was not sent is no fix round")
        XCTAssertEqual(b.fixes, 0)
        XCTAssertEqual(s.flows.map(\.cardID), ["B", "A"], "newest merge first")
    }

    func testMedianOfStartToMergeAndOfItsParts() {
        let s = Stats.compute(cards: [card("A", .done), card("B", .done)], events: flowLog, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        XCTAssertEqual(s.medianTotal, 90 * 60, "120 and 60 min")
        XCTAssertEqual(s.medianAgent, 60 * 60, "90 and 30 min")
        XCTAssertEqual(s.medianWaiting, 30 * 60, "30 and 30 min")
    }

    func testFirstPassRateCountsCardsWithAPacketAndNoFix() {
        let s = Stats.compute(cards: [card("A", .done), card("B", .done)], events: flowLog, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        XCTAssertEqual(s.packetCards, 2)
        XCTAssertEqual(s.neededFix, 1)
        XCTAssertEqual(s.firstPassPercent, 50)
    }

    func testMergedPerDayKeepsTheCardIDsAndCountsThePreviousRange() {
        let cards = [card("A", .done), card("B", .done), card("C", .done)]
        let s = Stats.compute(cards: cards, events: flowLog, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        XCTAssertEqual(s.merged.count, 7)
        XCTAssertEqual(s.merged[5].ids, ["A"])
        XCTAssertEqual(s.merged[6].ids, ["B"])
        XCTAssertEqual(s.mergedCount, 2)
        XCTAssertEqual(s.previousMergedCount, 1, "C was merged on the 10th, in the 7 days before")
    }

    func testRangeChangesEveryTotal() {
        let cards = [card("A", .done), card("B", .done), card("C", .done)]
        let costs = ["A": CardCost(agent: 2, pm: 0.5), "B": CardCost(agent: 1, pm: 0), "C": CardCost(agent: 4, pm: 0)]
        let week = Stats.compute(cards: cards, events: flowLog, costs: costs, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        let twoWeeks = Stats.compute(cards: cards, events: flowLog, costs: costs, calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 14)
        XCTAssertEqual(week.totalCost, 3.5)
        XCTAssertEqual(week.costPerMerged, 1.75)
        XCTAssertEqual(twoWeeks.totalCost, 7.5)
        XCTAssertEqual(twoWeeks.mergedCount, 3)
        XCTAssertEqual(twoWeeks.costPerDay.count, 14)
        XCTAssertEqual(week.rows.map(\.cardID), ["A", "B"], "sorted by cost")
        XCTAssertEqual(twoWeeks.rows.map(\.cardID), ["C", "A", "B"])
    }

    func testTableRowsTakeModelEffortAndTokensFromTheSessionAndTheRole() throws {
        var session = SessionCost()
        session.byFamily[.sonnet] = TokenUsage(input: 100, output: 100, cacheWrite: 0, cacheRead: 800)
        session.models["claude-sonnet-5-5"] = 100
        var a = card("A", .done); a.roles = ["ui_dev"]
        let role = RoleConfig(name: "ui_dev", kind: "interactive", model: "opus", effort: "high", permissionMode: "auto", outputStyle: "concise", allowedTools: [], skills: [], instructionFile: "x.md")
        let s = Stats.compute(cards: [a], events: flowLog, costs: ["A": CardCost(agent: 2, pm: 0, session: session)], roles: ["ui_dev": role],
                              calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        let row = try XCTUnwrap(s.rows.first)
        XCTAssertEqual(row.title, "Title A")
        XCTAssertEqual(row.facts.model, "Sonnet 5.5")
        XCTAssertEqual(row.facts.effort, "high")
        XCTAssertEqual(row.facts.tokens, "1.0 k · 80% cached")
        XCTAssertEqual(row.flow?.agent, 90 * 60)
    }

    // MARK: Codex (N217)

    func testRowsSayWhichToolAndTheTotalsSplitClaudeAndCodex() throws {
        var claude = SessionCost(); claude.byFamily[.sonnet] = TokenUsage(input: 100, output: 100, cacheWrite: 0, cacheRead: 0)
        var codex = SessionCost(); codex.tokensOnly = TokenUsage(input: 500, output: 50, cacheWrite: 0, cacheRead: 0)
        var both = codex; both.byFamily[.opus] = TokenUsage(input: 10, output: 10, cacheWrite: 0, cacheRead: 0)
        let s = Stats.compute(cards: [card("A", .done), card("B", .done), card("C", .done)], events: flowLog,
                              costs: ["A": CardCost(agent: claude.dollars, pm: 0, session: claude), "B": CardCost(agent: nil, pm: 0, session: codex),
                                      "C": CardCost(agent: both.dollars, pm: 0, session: both)],
                              calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 14)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: s.rows.map { ($0.cardID, $0.tool) }), ["A": .claude, "B": .codex, "C": .claude], "Codex only when every token was Codex's")
        XCTAssertEqual(s.claudeCards, 2)
        XCTAssertEqual(s.codexCards, 1)
        XCTAssertEqual(s.toolSplitText, "2 Claude · 1 Codex")
        XCTAssertEqual(s.tokensOnlyTasks, 1)
        XCTAssertEqual(s.unknownCostTasks, 0)
    }

    func testNoSplitWithoutCodexAndNoToolWithoutASession() {
        var claude = SessionCost(); claude.byFamily[.sonnet] = TokenUsage(input: 100, output: 100, cacheWrite: 0, cacheRead: 0)
        let s = Stats.compute(cards: [card("A", .done), card("B", .done)], events: flowLog, costs: ["A": CardCost(agent: 1, pm: 0, session: claude)],
                              calendar: utc, now: date("2026-10-17T12:00:00Z"), days: 7)
        XCTAssertEqual(s.rows.first { $0.cardID == "B" }?.tool, nil)
        XCTAssertEqual(s.claudeCards, 1)
        XCTAssertNil(s.toolSplitText, "Claude alone needs no split")
    }

    @MainActor func testTheCodexSectionFollowsTheTopBarRule() async throws {
        let model = PanelModel.isolatedForTests()
        let stats = StatsModel(model: model)
        XCTAssertNil(stats.codexUsage, "under XCTest the real ~/.codex is not read")
        let t = Date()
        model.codexUsageSource = { PlanUsage(fiveHour: .init(percent: 34, resetsAt: t.addingTimeInterval(5400)), week: .init(percent: 12, resetsAt: t.addingTimeInterval(86400)),
                                             todayCost: 0, seenAt: t.addingTimeInterval(-600)) }
        await model.refreshAgents()
        for _ in 0..<200 where stats.codexUsage == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(stats.codexUsage?.fiveHour?.percent, 34)
        XCTAssertEqual(stats.codexUsage, model.shownCodexUsage)
        let old = PlanUsage(fiveHour: nil, week: .init(percent: 12, resetsAt: t.addingTimeInterval(86400)), todayCost: 0, seenAt: t.addingTimeInterval(-6 * 3600))
        XCTAssertNil(TopBarExtras.codexShown(old, roleUsesCodex: false, now: t), "no Codex role and no session in 5 h: hidden")
        XCTAssertEqual(TopBarExtras.codexShown(old, roleUsesCodex: true, now: t), old)
    }

    // MARK: limit forecast

    private let fiveHours: TimeInterval = 5 * 3600

    func testForecastMidWindowDoublesTheUse() throws {
        let now = date("2026-10-17T12:00:00Z")
        let w = PlanUsage.Window(percent: 30, resetsAt: now.addingTimeInterval(2.5 * 3600))
        let f = try XCTUnwrap(PlanUsage.forecast(w, length: fiveHours, now: now))
        XCTAssertEqual(f.percentAtReset, 60, accuracy: 0.001)
        XCTAssertNil(f.reachesLimitAt)
    }

    func testForecastNearTheResetIsAboutTheUse() throws {
        let now = date("2026-10-17T12:00:00Z")
        let w = PlanUsage.Window(percent: 40, resetsAt: now.addingTimeInterval(60))
        let f = try XCTUnwrap(PlanUsage.forecast(w, length: fiveHours, now: now))
        XCTAssertEqual(f.percentAtReset, 40 * 5 * 60 / (5 * 60 - 1), accuracy: 0.001)
        XCTAssertNil(f.reachesLimitAt)
    }

    func testForecastOverTheLimitIsCappedAndSaysWhen() throws {
        let now = date("2026-10-17T12:00:00Z")
        // 1 h of 5 used 40 %: 200 % at reset, 100 % after 2.5 h from the start, i.e. 1.5 h from now.
        let w = PlanUsage.Window(percent: 40, resetsAt: now.addingTimeInterval(4 * 3600))
        let f = try XCTUnwrap(PlanUsage.forecast(w, length: fiveHours, now: now))
        XCTAssertEqual(f.percentAtReset, 100)
        XCTAssertEqual(f.reachesLimitAt, now.addingTimeInterval(1.5 * 3600))
        XCTAssertEqual(PlanUsage.forecastText(f, now: now, calendar: utc), "At this pace: reaches the limit around 13:30")
    }

    func testForecastWithoutDataIsNil() {
        let now = date("2026-10-17T12:00:00Z")
        XCTAssertNil(PlanUsage.forecast(nil, length: fiveHours, now: now))
        XCTAssertNil(PlanUsage.forecast(PlanUsage.Window(percent: 10, resetsAt: now.addingTimeInterval(fiveHours)), length: fiveHours, now: now), "nothing elapsed yet")
    }

    func testLimitTexts() {
        let now = date("2026-10-17T12:00:00Z")   // a Saturday
        XCTAssertEqual(PlanUsage.forecastText(LimitForecast(percentAtReset: 52.4, reachesLimitAt: nil), now: now, calendar: utc), "At this pace: about 52% at reset")
        XCTAssertEqual(PlanUsage.resetLine(now.addingTimeInterval(100 * 60), now: now, calendar: utc), "Resets at 13:40 (in 1 h 40 min)")
        XCTAssertEqual(PlanUsage.resetLine(now.addingTimeInterval(2 * 86400 + 17 * 3600), now: now, calendar: utc), "Resets Tue 05:00 (in 2 d 17 h)")
    }

    func testShortDuration() {
        XCTAssertEqual(Stats.shortDuration(65 * 60), "1h 05m")
        XCTAssertEqual(Stats.shortDuration(41 * 60), "41m")
        XCTAssertEqual(Stats.shortDuration(20), "0m")
    }

    // MARK: views

    @MainActor func testStatsViewRenders() async throws {
        let model = await DemoSupport.makeModel()
        for (name, view) in [("stats", AnyView(StatsView(stats: StatsModel(model: model))))] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 900, height: 700)))
            XCTAssertGreaterThan(data.count, 10_000)
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
        }
    }
}
