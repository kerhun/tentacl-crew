import XCTest
@testable import AgentPanel

@MainActor
final class UsageGateTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

    private func usage(five: Double? = nil, week: Double? = nil, fiveResetsIn: TimeInterval = 5400, weekResetsIn: TimeInterval = 86400) -> PlanUsage {
        PlanUsage(fiveHour: five.map { .init(percent: $0, resetsAt: now.addingTimeInterval(fiveResetsIn)) },
                  week: week.map { .init(percent: $0, resetsAt: now.addingTimeInterval(weekResetsIn)) }, todayCost: 0)
    }

    func testDefaultsAreNinetyAndNinetyFiveAndEachCanBeOff() {
        let g = UsageGate(fiveHourStored: nil, weekStored: nil)
        XCTAssertEqual(g.fiveHour, 90)
        XCTAssertEqual(g.week, 95)
        let off = UsageGate(fiveHourStored: 0, weekStored: 0)
        XCTAssertNil(off.fiveHour); XCTAssertNil(off.week)
        XCTAssertNil(off.reason(usage(five: 100, week: 100), now: now, calendar: utc))
        XCTAssertEqual(UsageGate(fiveHourStored: 10, weekStored: 200).fiveHour, 50)
        XCTAssertEqual(UsageGate(fiveHourStored: 10, weekStored: 200).week, 100)
    }

    func testAboveTheThresholdHoldsWithTheReasonAtOrBelowDoesNot() {
        let g = UsageGate()
        XCTAssertNil(g.reason(usage(five: 90), now: now, calendar: utc))
        XCTAssertEqual(g.reason(usage(five: 93), now: now, calendar: utc), "5 h usage 93% — resets at 09:30")
        XCTAssertEqual(g.reason(usage(week: 96), now: now, calendar: utc), "Week usage 96% — resets Sat 08:00")
        XCTAssertNil(g.reason(usage(five: 80, week: 95), now: now, calendar: utc))
    }

    func testEachWindowHasItsOwnThreshold() {
        let g = UsageGate(fiveHour: nil, week: 95)
        XCTAssertNil(g.reason(usage(five: 99), now: now, calendar: utc))
        XCTAssertNotNil(g.reason(usage(five: 99, week: 97), now: now, calendar: utc))
    }

    func testUnknownUsageNeverBlocks() {
        XCTAssertNil(UsageGate().reason(nil, now: now, calendar: utc))
        XCTAssertNil(UsageGate().reason(usage(), now: now, calendar: utc))
    }

    func testAWindowThatHasResetNoLongerBlocks() {
        let u = usage(five: 95, fiveResetsIn: 60)
        XCTAssertNotNil(UsageGate().reason(u, now: now, calendar: utc))
        XCTAssertNil(UsageGate().reason(u, now: now.addingTimeInterval(61), calendar: utc))
        XCTAssertNil(UsageGate().reason(usage(five: 20), now: now.addingTimeInterval(61), calendar: utc), "after the reset the new low usage")
    }

    func testTheOverrideLastsUntilTheLatestHeldReset() {
        let u = usage(five: 95, week: 99)
        XCTAssertEqual(UsageGate().overrideUntil(u, now: now), now.addingTimeInterval(86400))
        XCTAssertNil(UsageGate().overrideUntil(usage(five: 10), now: now))
    }

    // MARK: the model

    private func model(usage: PlanUsage?) async throws -> PanelModel {
        let dir = try TempDir()
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("data/tasks/N1.md", "---\nid: N1\nproject: demo\nstatus: todo\nroles: [dev]\nfiles:\n  - a\n---\n# N1 · Task\n")
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success([])) }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        m.now = { [now] in now }
        m.usageSource = { usage }
        await m.reload()
        await m.refreshAgents()
        for _ in 0..<200 where m.planUsage != usage { try await Task.sleep(for: .milliseconds(5)) }
        withExtendedLifetime(dir) {}
        keep.append(dir)
        return m
    }
    private var keep: [TempDir] = []

    func testStartPathsStopAboveTheThresholdWithTheReason() async throws {
        let m = try await model(usage: usage(five: 93))
        m.safePoint = SafePoint(percent: nil)
        let reason = "5 h usage 93% — resets at \(Self.hhmm(now.addingTimeInterval(5400)))"
        XCTAssertEqual(m.usageGateReason, reason)
        XCTAssertEqual(m.startDisabledReason, reason)
        XCTAssertFalse(m.canStart)
        XCTAssertNil(m.makeFlow(role: "dev"))
        let card = try XCTUnwrap(m.selectedTaskCards.first)
        XCTAssertEqual(m.startDisabledReason(for: card), reason)
        guard case .failure(let error) = m.startPlan(for: card) else { return XCTFail("the plan must not be made") }
        XCTAssertEqual(error.message, "Cannot start: \(reason)")
    }

    func testARequestStartIsAnsweredWithTheReason() async throws {
        let m = try await model(usage: usage(week: 97))
        let card = try XCTUnwrap(m.selectedTaskCards.first)
        let plan = StartPlan(card: card, agentName: "dev-n1", branch: "task/n1", rolePath: "/r", worktreePath: "/w", commandPreview: "x")
        let failure = await m.startInRound(plan)
        XCTAssertTrue(try XCTUnwrap(failure).hasPrefix("Week usage 97%"))
    }

    func testUnknownUsageAndLowUsageStartNormally() async throws {
        let none = try await model(usage: nil)
        XCTAssertNil(none.usageGateReason)
        let low = try await model(usage: usage(five: 40, week: 40))
        XCTAssertNil(low.usageGateReason)
        XCTAssertNil(low.usageHold)
    }

    func testStartAnywayLiftsTheGateUntilTheResetThenItComesBack() async throws {
        let m = try await model(usage: usage(five: 95))
        m.safePoint = SafePoint(percent: nil)
        XCTAssertNotNil(m.usageGateReason)
        XCTAssertTrue(m.startAnyway())
        XCTAssertNil(m.usageGateReason)
        XCTAssertNil(m.usageHold)
        m.now = { [now] in now.addingTimeInterval(5401) }
        XCTAssertFalse(m.usageGateOverridden, "the override ends with the window")
        let clear = try await model(usage: usage(five: 10))
        XCTAssertFalse(clear.startAnyway(), "nothing holds, so nothing to override")
    }

    func testTheThresholdsAreKeptInTheDefaults() async throws {
        let m = try await model(usage: usage(five: 80))
        XCTAssertNil(m.usageGateReason)
        m.usageGate = UsageGate(fiveHour: 75, week: nil)
        XCTAssertEqual(m.usageGate, UsageGate(fiveHour: 75, week: nil))
        XCTAssertNotNil(m.usageGateReason)
    }

    func testTheSafePointStillHoldsWhenTheGateIsOff() async throws {
        let m = try await model(usage: usage(five: 95))
        m.usageGate = UsageGate(fiveHour: nil, week: nil)
        XCTAssertTrue(try XCTUnwrap(m.usageHold).hasPrefix("Safe point reached"))
    }

    private static func hhmm(_ d: Date) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current
        let f = DateFormatter(); f.calendar = c; f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
