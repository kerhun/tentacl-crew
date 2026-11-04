import XCTest
import SwiftUI
@testable import AgentPanel

private final class FakePower: PowerAssertions {
    var created: [(kind: AssertionKind, reason: String)] = []
    var released: [UInt32] = []
    var fail = false
    var held: Int { created.count - released.count }
    var reasons: [String] { created.map(\.reason) }
    /// The kinds held right now.
    var heldKinds: Set<AssertionKind> {
        Set(created.enumerated().filter { !released.contains(UInt32($0.offset + 1)) }.map(\.element.kind))
    }
    func create(kind: AssertionKind, reason: String) -> UInt32? { if fail { return nil }; created.append((kind, reason)); return UInt32(created.count) }
    func release(_ id: UInt32) { released.append(id) }
}

@MainActor
private final class FakeEnvironment: PowerEnvironment {
    var snapshot = PowerSnapshot(hasBattery: true, onBattery: false, percent: 80)
    var onChange: (@MainActor () -> Void)?
    var willSleep: (@MainActor () -> Void)?
    var didWake: (@MainActor () -> Void)?
    func start(onChange: @escaping @MainActor () -> Void, willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {
        self.onChange = onChange; self.willSleep = willSleep; self.didWake = didWake
    }
    func set(onBattery: Bool? = nil, percent: Int? = nil) {
        if let onBattery { snapshot.onBattery = onBattery }
        if let percent { snapshot.percent = percent }
        onChange?()
    }
}

@MainActor
final class SleepGuardTests: XCTestCase {
    private func make(on: Bool = true, mode: KeepAwakeMode? = nil) -> (SleepGuard, FakePower, UserDefaults) {
        let (g, p, _, d) = makeFull(on: on, mode: mode)
        return (g, p, d)
    }

    private func makeFull(on: Bool = true, mode: KeepAwakeMode? = nil, now: @escaping () -> Date = Date.init) -> (SleepGuard, FakePower, FakeEnvironment, UserDefaults) {
        let d = makeTestDefaults(prefix: "sleep")
        d.set(on, forKey: SleepGuard.key)
        if let mode { d.set(mode.rawValue, forKey: SleepGuard.modeKey) }
        let p = FakePower(), e = FakeEnvironment()
        return (SleepGuard(power: p, environment: e, defaults: d, now: now), p, e, d)
    }

    private func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))! }

    func testHeldOnlyWhenOnAndTaskRuns() {
        let (g, p, _) = make()
        XCTAssertEqual(g.state, .waiting); XCTAssertEqual(p.held, 0)
        g.update(running: true)
        XCTAssertEqual(g.state, .holding); XCTAssertEqual(p.reasons.first, "Tentacl Crew: agents are working")
        g.update(running: false)
        XCTAssertEqual(g.state, .waiting); XCTAssertEqual(p.held, 0)
    }

    func testNeverCreatedTwice() {
        let (g, p, _) = make()
        g.update(running: true); g.update(running: true); g.update(running: true)
        XCTAssertEqual(p.created.count, 2, "one idle-sleep and one system-sleep assertion on power")
    }

    func testOffHoldsNothing() {
        let (g, p, _) = make(on: false)
        g.update(running: true)
        XCTAssertEqual(g.state, .off); XCTAssertEqual(p.created.count, 0)
    }

    func testTurningOffReleasesAndOnReacquires() {
        let (g, p, _) = make()
        g.update(running: true)
        g.isOn = false
        XCTAssertEqual(p.held, 0); XCTAssertEqual(g.state, .off); XCTAssertEqual(g.mode, .off)
        g.isOn = true
        XCTAssertEqual(g.state, .holding); XCTAssertEqual(p.created.count, 4); XCTAssertEqual(g.mode, .agents)
    }

    func testQuitReleases() {
        let (g, p, _) = make()
        g.update(running: true)
        g.prepareToQuit()
        XCTAssertEqual(p.held, 0)
        g.update(running: true)
        XCTAssertEqual(p.held, 0, "nothing is taken once quitting")
    }

    func testStateIsRemembered() {
        let (g, _, d) = make(on: false)
        g.isOn = true
        XCTAssertTrue(SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: d).isOn)
    }

    func testFailedAssertionIsNotHolding() {
        let (g, p, _) = make()
        p.fail = true
        g.update(running: true)
        XCTAssertEqual(g.state, .waiting)
    }

    func testHelpMentionsLid() {
        XCTAssertTrue(SleepGuard.help.contains("lid"))
    }

    // MARK: modes

    func testDefaultModeIsWhileAgentsWork() {
        let d = makeTestDefaults(prefix: "sleep")
        XCTAssertEqual(SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: d).mode, .agents)
    }

    func testOldOnOffSettingBecomesAMode() {
        XCTAssertEqual(make(on: true).0.mode, .agents)
        XCTAssertEqual(make(on: false).0.mode, .off)
        XCTAssertEqual(make(on: false, mode: .always).0.mode, .always, "the new setting wins")
    }

    func testAlwaysModeHoldsWithoutATask() {
        let (g, p, _) = make(mode: .always)
        XCTAssertEqual(g.state, .holding)
        XCTAssertEqual(p.heldKinds, [.idleSystem, .system])
        XCTAssertEqual(p.reasons.first, "Tentacl Crew: keeping the Mac awake while it is open")
    }

    func testAgentsModeWaitsForATask() {
        let (g, p, _) = make(mode: .agents)
        XCTAssertEqual(p.held, 0)
        g.update(running: true)
        XCTAssertEqual(p.heldKinds, [.idleSystem, .system])
    }

    func testModeAndOptionsAreSaved() {
        let (g, _, d) = make()
        g.mode = .always; g.keepDisplay = true; g.lidOnPower = false; g.warnOnBattery = false; g.stopBelowEnabled = true; g.stopBelowPercent = 35
        let again = SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: d)
        XCTAssertEqual(again.mode, .always); XCTAssertTrue(again.keepDisplay); XCTAssertFalse(again.lidOnPower)
        XCTAssertFalse(again.warnOnBattery); XCTAssertTrue(again.stopBelowEnabled); XCTAssertEqual(again.stopBelowPercent, 35)
    }

    func testDefaultsOfTheOptions() {
        let g = SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: makeTestDefaults(prefix: "sleep"))
        XCTAssertFalse(g.keepDisplay); XCTAssertTrue(g.lidOnPower); XCTAssertTrue(g.warnOnBattery)
        XCTAssertFalse(g.stopBelowEnabled); XCTAssertEqual(g.stopBelowPercent, 20)
    }

    // MARK: power source

    func testOnBatteryOnlyIdleSleepIsHeld() {
        let (g, p, e, _) = makeFull()
        e.snapshot.onBattery = true
        g.update(running: true)
        XCTAssertEqual(p.heldKinds, [.idleSystem])
    }

    func testAssertionsSwitchLiveWhenPowerChanges() {
        let (g, p, e, _) = makeFull()
        g.update(running: true)
        XCTAssertEqual(p.heldKinds, [.idleSystem, .system])
        e.set(onBattery: true)
        XCTAssertEqual(p.heldKinds, [.idleSystem], "the lid assertion goes when the cable does")
        XCTAssertEqual(p.created.count, 2, "the idle-sleep assertion is kept, not recreated")
        e.set(onBattery: false)
        XCTAssertEqual(p.heldKinds, [.idleSystem, .system])
    }

    func testLidOnPowerSwitchedOffHoldsIdleOnly() {
        let (g, p, _, _) = makeFull()
        g.lidOnPower = false
        g.update(running: true)
        XCTAssertEqual(p.heldKinds, [.idleSystem])
        g.lidOnPower = true
        XCTAssertEqual(p.heldKinds, [.idleSystem, .system])
    }

    func testMacWithoutBatteryHasNoLidAssertion() {
        let (g, p, e, _) = makeFull()
        e.snapshot = PowerSnapshot(hasBattery: false, onBattery: false, percent: nil)
        g.update(running: true)
        XCTAssertEqual(p.heldKinds, [.idleSystem])
        XCTAssertFalse(g.supportsLidClosed)
    }

    func testKeepDisplayAwakeAddsADisplayAssertion() {
        let (g, p, _, _) = makeFull()
        g.update(running: true)
        XCTAssertFalse(p.heldKinds.contains(.idleDisplay))
        g.keepDisplay = true
        XCTAssertTrue(p.heldKinds.contains(.idleDisplay))
        g.keepDisplay = false
        XCTAssertFalse(p.heldKinds.contains(.idleDisplay))
    }

    func testAssertionNamesAreReadable() {
        let (g, p, _, _) = makeFull()
        g.keepDisplay = true
        g.update(running: true)
        XCTAssertEqual(Set(p.reasons), ["Tentacl Crew: agents are working", "Tentacl Crew: agents are working (lid closed on power)", "Tentacl Crew: agents are working (display)"])
    }

    // MARK: battery threshold

    func testBelowTheThresholdOnBatteryStopsKeepingAwake() {
        let (g, p, e, _) = makeFull()
        g.stopBelowEnabled = true; g.stopBelowPercent = 20
        e.snapshot.onBattery = true; e.snapshot.percent = 40
        g.update(running: true)
        XCTAssertEqual(g.state, .holding)
        e.set(percent: 19)
        XCTAssertEqual(g.state, .lowBattery); XCTAssertEqual(p.held, 0)
        e.set(percent: 20)
        XCTAssertEqual(g.state, .holding, "at the threshold it still holds; below it does not")
    }

    func testThresholdDoesNotApplyOnPowerOrWhenOff() {
        let (g, p, e, _) = makeFull()
        g.stopBelowEnabled = true; g.stopBelowPercent = 50
        e.snapshot.percent = 10
        g.update(running: true)
        XCTAssertEqual(g.state, .holding, "on power the battery level does not matter")
        e.set(onBattery: true)
        XCTAssertEqual(g.state, .lowBattery)
        g.stopBelowEnabled = false
        XCTAssertEqual(g.state, .holding); XCTAssertFalse(p.heldKinds.isEmpty)
    }

    // MARK: battery warning

    func testWarningWhenAgentsWorkOnBattery() {
        let (g, _, e, _) = makeFull()
        g.update(running: true)
        XCTAssertNil(g.warning, "on power there is nothing to warn about")
        e.set(onBattery: true)
        XCTAssertEqual(g.warning, "On battery: closing the lid will pause the agents")
        g.update(running: false)
        XCTAssertNil(g.warning, "no agent works, nothing would be paused")
    }

    func testNoWarningWhenSwitchedOffOrKeepAwakeIsOff() {
        let (g, _, e, _) = makeFull()
        e.snapshot.onBattery = true
        g.update(running: true)
        g.warnOnBattery = false
        XCTAssertNil(g.warning)
        g.warnOnBattery = true; g.mode = .off
        XCTAssertNil(g.warning)
    }

    func testTooltipShowsModeAndWarning() {
        let (g, _, e, _) = makeFull()
        XCTAssertTrue(g.tooltip.contains("While agents work"))
        g.mode = .always
        XCTAssertTrue(g.tooltip.contains("Always while Tentacl Crew is open"))
        e.snapshot.onBattery = true
        g.update(running: true)
        XCTAssertTrue(g.tooltip.hasPrefix("On battery: closing the lid will pause the agents"))
        g.mode = .off
        XCTAssertTrue(g.tooltip.hasPrefix("Off."))
    }

    func testLowBatteryTooltipSaysWhyItStopped() {
        let (g, _, e, _) = makeFull()
        g.stopBelowEnabled = true; g.stopBelowPercent = 20
        e.snapshot.onBattery = true; e.snapshot.percent = 12
        g.update(running: true)
        XCTAssertTrue(g.tooltip.contains("battery is below 20%"))
    }

    // MARK: sleep and wake

    func testSleepOnBatteryWhileAgentsWorkPostsANotice() {
        let (g, _, e, _) = makeFull()
        var notices: [(String, String)] = []
        g.onNotice = { notices.append(($0, $1)) }
        e.snapshot.onBattery = true
        g.update(running: true, agents: 2)
        e.willSleep?()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.0, "The Mac is going to sleep on battery")
        XCTAssertEqual(notices.first?.1, "2 agents are working and will pause until it wakes.")
    }

    func testNoNoticeOnPowerWithoutAgentsOrWhenWarningIsOff() {
        let (g, _, e, _) = makeFull()
        var count = 0
        g.onNotice = { _, _ in count += 1 }
        g.update(running: true, agents: 1)
        e.willSleep?()
        e.snapshot.onBattery = true
        g.update(running: false, agents: 0)
        e.willSleep?()
        g.update(running: true, agents: 1); g.warnOnBattery = false
        e.willSleep?()
        XCTAssertEqual(count, 0)
    }

    func testWakeSaysWhatWasInterrupted() {
        var clock = at(22, 22)
        let (g, _, e, _) = makeFull(now: { clock })
        e.snapshot.onBattery = true
        g.update(running: true, agents: 2)
        e.willSleep?()
        clock = at(22, 26)
        e.didWake?()
        XCTAssertEqual(g.interruption, "Mac slept 22:22–22:26 on battery; 2 agents were working")
        XCTAssertTrue(g.tooltip.contains("Mac slept 22:22–22:26 on battery; 2 agents were working"))
        g.dismissInterruption()
        XCTAssertNil(g.interruption)
    }

    func testWakeOnPowerAndOneAgent() {
        var clock = at(9, 0)
        let (g, _, e, _) = makeFull(now: { clock })
        g.update(running: true, agents: 1)
        e.willSleep?()
        clock = at(9, 5)
        e.didWake?()
        XCTAssertEqual(g.interruption, "Mac slept 09:00–09:05 on power; 1 agent was working")
    }

    func testWakeAfterSleepWithoutAgentsSaysNothing() {
        let (g, _, e, _) = makeFull()
        g.update(running: false, agents: 0)
        e.willSleep?(); e.didWake?()
        XCTAssertNil(g.interruption)
        e.didWake?()
        XCTAssertNil(g.interruption, "a wake with no sleep before it says nothing")
    }

    func testPowerSourceIsNotWatchedTwice() {
        let (g, p, e, _) = makeFull()
        g.update(running: true)
        e.onChange?(); e.onChange?()
        XCTAssertEqual(p.created.count, 2)
    }

    // MARK: usage chip

    private func usage(five: Double?, week: Double?) -> PlanUsage {
        let r = Date().addingTimeInterval(3600)
        return PlanUsage(fiveHour: five.map { .init(percent: $0, resetsAt: r) }, week: week.map { .init(percent: $0, resetsAt: r) }, todayCost: 0)
    }

    func testChipGauges() {
        let both = UsageChip.content(usage(five: 23.4, week: 41.2))!.gauges
        XCTAssertEqual(both.map(\.label), ["5h", "wk"])
        XCTAssertEqual(both.map(\.percentText), ["23%", "41%"])
        XCTAssertEqual(both[0].fraction, 0.234, accuracy: 0.001)
        XCTAssertEqual(UsageChip.content(usage(five: 23, week: nil))?.gauges.map(\.label), ["5h"])
        XCTAssertEqual(UsageChip.content(usage(five: nil, week: 41))?.gauges.map(\.label), ["wk"])
    }

    func testChipWarnsAbove80PerWindow() {
        XCTAssertEqual(UsageChip.content(usage(five: 80, week: 10))!.gauges.map(\.warn), [false, false])
        XCTAssertEqual(UsageChip.content(usage(five: 10, week: 81))!.gauges.map(\.warn), [false, true])
        XCTAssertEqual(UsageChip.content(usage(five: 95, week: 10))!.gauges.map(\.warn), [true, false])
    }

    func testChipHelpHasResetTimes() {
        let now = Date()
        let u = PlanUsage(fiveHour: .init(percent: 23, resetsAt: now.addingTimeInterval(2 * 3600 + 600)),
                          week: .init(percent: 41, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600)), todayCost: 0)
        let help = UsageChip.content(u, now: now)!.help
        XCTAssertEqual(help, "5h \(PlanUsage.resetText(u.fiveHour!.resetsAt, now: now)) · week \(PlanUsage.resetText(u.week!.resetsAt, now: now))")
        XCTAssertTrue(help.contains("5h resets in 2 h 10 min"))
        XCTAssertEqual(UsageChip.content(usage(five: nil, week: 41), now: now)!.help.hasPrefix("week resets in"), true)
    }

    func testChipAccessibilityValue() {
        XCTAssertEqual(UsageChip.content(usage(five: 23.4, week: 41.2))!.accessibilityValue, "5 hours 23 percent, week 41 percent")
        XCTAssertEqual(UsageChip.content(usage(five: nil, week: 41))!.accessibilityValue, "week 41 percent")
    }

    func testChipHiddenWithoutData() {
        XCTAssertNil(UsageChip.content(nil))
        XCTAssertNil(UsageChip.content(usage(five: nil, week: nil)))
    }
}
