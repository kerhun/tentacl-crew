import XCTest
import SwiftUI
@testable import AgentPanel

/// The Stats screen (N137) drawn from fixture data: no PanelModel, no AppKit parts (N117), so the picture is the same on every machine.
final class StatsViewTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T16:20:00Z")!

    /// 14 days of merges with costs and step times, as the action log would give them.
    /// `codexEvery`: every n-th card ran on Codex (tokens only); 0 for none.
    private func fixture(codexEvery: Int = 0) -> Stats {
        let perDay = [2, 0, 4, 3, 6, 1, 0, 5, 7, 9, 3, 4, 6, 8]
        var log = "", cards: [TaskCard] = [], costs: [String: CardCost] = [:]
        let iso = ISO8601DateFormatter()
        var n = 60
        for (i, count) in perDay.enumerated() {
            let day = utc.date(byAdding: .day, value: i - 13, to: utc.startOfDay(for: now))!
            for k in 0..<count {
                n += 1
                let id = "N\(n)", start = day.addingTimeInterval(Double(8 * 3600 + k * 1800))
                let packet = start.addingTimeInterval(Double(20 + (n * 7) % 90) * 60)
                let fix = n % 5 == 0
                var lines = ["\(iso.string(from: start)) [p] start \(id) agent=a branch=b pane=1",
                             "\(iso.string(from: packet)) [p] review packet prepared for \(id)"]
                var end = packet.addingTimeInterval(Double(5 + (n * 3) % 30) * 60)
                if fix {
                    lines.append("\(iso.string(from: end)) [p] fix request sent to 1 for \(id)")
                    end = end.addingTimeInterval(25 * 60)
                    lines.append("\(iso.string(from: end)) [p] review packet prepared for \(id)")
                    end = end.addingTimeInterval(10 * 60)
                }
                lines.append("\(iso.string(from: end)) [p] approved \(id)")
                log += lines.joined(separator: "\n") + "\n"
                var c = TaskCard(id: id, project: "p", status: .done, agent: "a", branch: "task/\(id.lowercased())", kind: nil, files: [],
                                 title: "Card \(id) with a readable title", sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
                c.roles = ["dev"]
                cards.append(c)
                var session = SessionCost()
                session.byFamily[.sonnet] = TokenUsage(input: 20_000 * n, output: 9_000 * n, cacheWrite: 30_000 * n, cacheRead: 900_000 * n)
                session.models["claude-sonnet-5-5"] = 1
                if codexEvery > 0, n % codexEvery == 0 {
                    var codex = SessionCost()
                    codex.tokensOnly = TokenUsage(input: 30_000 * n, output: 6_000 * n, cacheWrite: 0, cacheRead: 400_000 * n)
                    codex.models["gpt-5.5-codex"] = 1
                    costs[id] = CardCost(agent: nil, pm: 0.12, session: codex)
                    continue
                }
                costs[id] = CardCost(agent: Double(n % 9) * 0.45 + 0.6, pm: 0.12, session: session)
            }
        }
        let role = RoleConfig(name: "dev", kind: "interactive", model: "sonnet", effort: "medium", permissionMode: "auto", outputStyle: "concise",
                              allowedTools: [], skills: [], instructionFile: "dev.md")
        return Stats.compute(cards: cards, events: ActionLogEvents.parse(log), costs: costs, roles: ["dev": role], calendar: utc, now: now, days: 14)
    }

    @MainActor func testStatsScreenSnapshot() throws {
        let usage = PlanUsage(fiveHour: .init(percent: 34, resetsAt: now.addingTimeInterval(100 * 60)),
                              week: .init(percent: 71, resetsAt: now.addingTimeInterval(2 * 86400 + 17 * 3600)), todayCost: 3)
        let view = StatsContent(stats: fixture(), usage: usage, range: .twoWeeks, now: now, calendar: utc, onRange: { _ in }, onOpen: { _ in })
            .background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 1300)))
        XCTAssertGreaterThan(data.count, 50_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("stats-combined.png")) }
    }

    /// N217: the Codex plan section under Claude's, and the same screen without it.
    @MainActor func testCodexSectionSnapshot() throws {
        let claude = PlanUsage(fiveHour: .init(percent: 34, resetsAt: now.addingTimeInterval(100 * 60)),
                               week: .init(percent: 71, resetsAt: now.addingTimeInterval(2 * 86400 + 17 * 3600)), todayCost: 3)
        let codex = PlanUsage(fiveHour: .init(percent: 62, resetsAt: now.addingTimeInterval(140 * 60)),
                              week: .init(percent: 18, resetsAt: now.addingTimeInterval(4 * 86400)), todayCost: 0, seenAt: now.addingTimeInterval(-25 * 60))
        for (name, usage) in [("N217-stats-codex", Optional(codex)), ("N217-stats-no-codex", nil)] {
            let view = StatsContent(stats: fixture(codexEvery: 4), usage: claude, codexUsage: usage, range: .twoWeeks, now: now, calendar: utc, onRange: { _ in }, onOpen: { _ in })
                .background(Tok.bg)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 1500)))
            XCTAssertGreaterThan(data.count, 50_000)
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
        }
    }

    /// N140: a 74-card day at the right edge with its tooltip open: 6 × 8 ids ending "+27 more", inside the chart box, left of the bar.
    @MainActor func testMergedTooltipOnABigDayNearTheRightEdge() throws {
        let start = utc.date(byAdding: .day, value: -6, to: utc.startOfDay(for: now))!
        let counts = [0, 0, 0, 0, 30, 40, 74]
        var n = 0
        let days = counts.enumerated().map { i, c in
            DayCount(day: utc.date(byAdding: .day, value: i, to: start)!, count: c, ids: (0..<c).map { _ in n += 1; return "N\(n)" })
        }
        let view = RatioRow(ratios: [1.55, 1]) {
            StatsBox("Cards merged per day", note: "144 in 7 days") { MergedBarChart(days: days, hovered: days.last!.day) }
            StatsBox("Plan limits", note: "") { Color.clear.frame(height: 190) }
        }
        .padding(30).background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 340)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("stats-merged-tooltip.png")) }
    }

    @MainActor func testEmptyStatsScreenRenders() throws {
        let view = StatsContent(stats: Stats(), usage: nil, range: .week, now: now, calendar: utc, onRange: { _ in }, onOpen: { _ in }).background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 900)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("stats-empty.png")) }
    }

    func testRangeIsRememberedPerProject() {
        let defaults = makeTestDefaults(prefix: "stats-range")
        XCTAssertEqual(StatsRange.load(defaults, project: "a"), .twoWeeks, "the default")
        StatsRange.month.save(defaults, project: "a")
        XCTAssertEqual(StatsRange.load(defaults, project: "a"), .month)
        XCTAssertEqual(StatsRange.load(defaults, project: "b"), .twoWeeks)
    }
}
