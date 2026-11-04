import XCTest
import SwiftUI
@testable import AgentPanel

final class UsageReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func folder() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func write(_ d: URL, _ id: String, seen: TimeInterval, five: (Double, TimeInterval)? = nil, week: (Double, TimeInterval)? = nil, cost: Double? = nil) throws {
        var limits: [String: Any] = [:]
        if let five { limits["five_hour"] = ["used_percentage": five.0, "resets_at": five.1] }
        if let week { limits["seven_day"] = ["used_percentage": week.0, "resets_at": week.1] }
        var obj: [String: Any] = ["session_id": id, "seen_at": seen]
        if !limits.isEmpty { obj["rate_limits"] = limits }
        if let cost { obj["cost"] = ["total_cost_usd": cost] }
        try JSONSerialization.data(withJSONObject: obj).write(to: d.appendingPathComponent("\(id).json"))
    }

    func testNewestFileWins() throws {
        let d = try folder(), t = now.timeIntervalSince1970
        try write(d, "old", seen: t - 600, five: (10, t + 3600), week: (20, t + 86400))
        try write(d, "new", seen: t - 60, five: (30, t + 1800), week: (45, t + 86400))
        let u = try XCTUnwrap(UsageReader.read(root: d, now: now, calendar: utc))
        XCTAssertEqual(u.fiveHour?.percent, 30)
        XCTAssertEqual(u.fiveHour?.resetsAt, Date(timeIntervalSince1970: t + 1800))
        XCTAssertEqual(u.week?.percent, 45)
    }

    func testAWindowThatHasResetIsDropped() throws {
        let d = try folder(), t = now.timeIntervalSince1970
        try write(d, "a", seen: t - 60, five: (30, t - 10), week: (45, t + 86400))
        let u = try XCTUnwrap(UsageReader.read(root: d, now: now, calendar: utc))
        XCTAssertNil(u.fiveHour)
        XCTAssertEqual(u.week?.percent, 45)
    }

    func testNewerFileWithOnlyResetWindowsFallsBackToOlderLiveOne() throws {
        let d = try folder(), t = now.timeIntervalSince1970
        try write(d, "live", seen: t - 600, five: (12, t + 3600))
        try write(d, "dead", seen: t - 60, five: (99, t - 5), week: (99, t - 5))
        XCTAssertEqual(UsageReader.read(root: d, now: now, calendar: utc)?.fiveHour?.percent, 12)
    }

    func testNoDataWhenEmptyMissingOrAllReset() throws {
        let d = try folder(), t = now.timeIntervalSince1970
        XCTAssertNil(UsageReader.read(root: d, now: now, calendar: utc))
        XCTAssertNil(UsageReader.read(root: d.appendingPathComponent("none"), now: now, calendar: utc))
        try write(d, "x", seen: t - 60, five: (50, t - 1))
        try Data("not json".utf8).write(to: d.appendingPathComponent("bad.json"))
        try write(d, "nolimits", seen: t - 30, cost: 1)
        XCTAssertNil(UsageReader.read(root: d, now: now, calendar: utc))
    }

    func testTodaysSessionCostsSumSessionsSeenToday() throws {
        let d = try folder(), t = now.timeIntervalSince1970
        let startOfDay = utc.startOfDay(for: now).timeIntervalSince1970
        try write(d, "a", seen: t - 60, five: (30, t + 100), cost: 1.5)
        try write(d, "b", seen: startOfDay + 1, cost: 2)
        try write(d, "yesterday", seen: startOfDay - 1, cost: 9)
        XCTAssertEqual(try XCTUnwrap(UsageReader.read(root: d, now: now, calendar: utc)).todayCost, 3.5, accuracy: 1e-9)
    }

    @MainActor func testPlanUsageCardRenders() async throws {
        let model = await DemoSupport.makeModel()
        let t = Date().timeIntervalSince1970
        for (name, usage) in [("stats-usage", PlanUsage(fiveHour: .init(percent: 23, resetsAt: Date(timeIntervalSince1970: t + 7200)), week: .init(percent: 41, resetsAt: Date(timeIntervalSince1970: t + 3 * 86400)), todayCost: 3.5)),
                              ("stats-usage-none", nil)] {
            let stats = StatsModel(model: model); stats.usageSource = { usage }; await stats.reload()
            let data = try XCTUnwrap(SnapshotRenderer.render(view: AnyView(StatsView(stats: stats)), size: CGSize(width: 900, height: 700)))
            XCTAssertGreaterThan(data.count, 10_000)
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
        }
    }

    func testResetTextAndBarFraction() {
        XCTAssertEqual(PlanUsage.resetText(Date(timeIntervalSince1970: 1_800_000_000 + 90 * 60), now: now), "resets in 1 h 30 min")
        XCTAssertEqual(PlanUsage.Window(percent: 140, resetsAt: now).fraction, 1)
    }

    // MARK: Codex chip (N205)

    private func codex(five: Double = 34, week: Double? = 12, seen: TimeInterval? = nil) -> PlanUsage {
        PlanUsage(fiveHour: .init(percent: five, resetsAt: now.addingTimeInterval(5400)), week: week.map { .init(percent: $0, resetsAt: now.addingTimeInterval(2 * 86400)) },
                  todayCost: 0, seenAt: seen.map { now.addingTimeInterval(-$0) })
    }

    func testCodexUsageCarriesWhenItsSessionFileLastWrote() throws {
        let root = try folder(), t = now.timeIntervalSince1970
        let dir = root.appendingPathComponent("2026/10/20")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-10-20T10-00-00-a.jsonl")
        let lines = [#"{"type":"session_meta","payload":{"id":"a","cwd":"/w"}}"#,
                     #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"primary":{"used_percent":34,"window_minutes":300,"resets_at":\#(t + 5400)}}}}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let written = now.addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        let u = try XCTUnwrap(UsageReader.readCodex(root: root, now: now))
        XCTAssertEqual(u.fiveHour?.percent, 34)
        XCTAssertEqual(u.seenAt?.timeIntervalSince1970 ?? 0, written.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(u.seenRecently(now: now))
        XCTAssertNil(UsageReader.read(root: try folder(), now: now, calendar: utc)?.seenAt, "Claude windows carry no time")
    }

    func testTheCodexChipShowsForACodexRoleOrARunOfTheLastFiveHours() {
        XCTAssertNotNil(TopBarExtras.codexShown(codex(), roleUsesCodex: true, now: now), "a role uses Codex")
        XCTAssertNotNil(TopBarExtras.codexShown(codex(seen: 4 * 3600), roleUsesCodex: false, now: now), "ran 4 hours ago")
        XCTAssertNil(TopBarExtras.codexShown(codex(seen: 5 * 3600 + 1), roleUsesCodex: false, now: now), "ran over 5 hours ago")
        XCTAssertNil(TopBarExtras.codexShown(codex(), roleUsesCodex: false, now: now), "no run time, no role")
        XCTAssertNil(TopBarExtras.codexShown(nil, roleUsesCodex: true, now: now), "no data")
    }

    func testTheCodexRingSitsBesideTheClaudeRing() {
        XCTAssertEqual(TopBarExtras.items(autopilotAvailable: true, codex: true), [.usage, .codexUsage, .autopilot, .caffeinate])
        XCTAssertEqual(TopBarExtras.items(autopilotAvailable: false, codex: true), [.usage, .codexUsage, .caffeinate])
        XCTAssertEqual(TopBarExtras.items(autopilotAvailable: false), [.usage, .caffeinate])
    }

    func testTheCodexRingNamesItsPlanAndItsResetsInTheHoverText() throws {
        let c = try XCTUnwrap(UsageRing.content(codex(five: 86), tool: .codex, now: now))
        XCTAssertEqual(c.help, "Codex · 5h resets in 1 h 30 min · week resets in 2 d")
        XCTAssertEqual(c.percentText, "86%")
        XCTAssertTrue(c.warn)
        XCTAssertEqual(UsageRing.accessibilityLabel(.codex), "Codex plan usage")
        XCTAssertEqual(UsageRing.accessibilityLabel(.claude), "Claude plan usage")
        XCTAssertEqual(UsageRing.accessibilityLabel(nil), "Plan usage")
        XCTAssertEqual(UsageRing.content(codex(), now: now)?.help, "5h resets in 1 h 30 min · week resets in 2 d", "no name without a tool")
    }

    @MainActor func testTheModelReadsCodexWithoutACodexRoleAndShowsARecentRun() async throws {
        let model = PanelModel.isolatedForTests()
        let t = Date()
        model.codexUsageSource = { PlanUsage(fiveHour: .init(percent: 34, resetsAt: t.addingTimeInterval(5400)), week: nil, todayCost: 0, seenAt: t.addingTimeInterval(-600)) }
        XCTAssertFalse(model.anyRoleUsesCodex)
        await model.refreshAgents()
        for _ in 0..<200 where model.shownCodexUsage == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.shownCodexUsage?.fiveHour?.percent, 34)
    }

    @MainActor func testTheTopBarChipsRender() throws {
        let claude = PlanUsage(fiveHour: .init(percent: 62, resetsAt: Date().addingTimeInterval(7200)), week: .init(percent: 41, resetsAt: Date().addingTimeInterval(3 * 86400)), todayCost: 0)
        let codexUsage = PlanUsage(fiveHour: .init(percent: 86, resetsAt: Date().addingTimeInterval(5400)), week: .init(percent: 30, resetsAt: Date().addingTimeInterval(2 * 86400)), todayCost: 0)
        let guardModel = SleepGuard(power: InertPowerAssertions(), environment: InertPowerEnvironment(), defaults: makeTestDefaults(prefix: "n205"))
        let view = VStack(alignment: .trailing, spacing: 12) {
            TopBarExtras(guardModel: guardModel, usage: claude, codexUsage: codexUsage, onOpenStats: {})
            TopBarExtras(guardModel: guardModel, usage: claude, onOpenStats: {})
        }.padding(12).background(Tok.rail)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AnyView(view), size: CGSize(width: 320, height: 100)))
        XCTAssertGreaterThan(data.count, 2_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N205-chip.png")) }
    }
}
