import XCTest
@testable import AgentPanel

private struct NoGit: CommandRunner { func run(_ executable: URL, _ arguments: [String]) async throws -> Data { Data() } }
private final class NoLogin: LoginItemControlling, @unchecked Sendable { var isEnabled = false; func setEnabled(_ on: Bool) throws {} }

@MainActor
final class SafePointTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

    private func usage(five percent: Double?, resetsIn: TimeInterval = 5400) -> PlanUsage {
        PlanUsage(fiveHour: percent.map { PlanUsage.Window(percent: $0, resetsAt: now.addingTimeInterval(resetsIn)) }, week: nil, todayCost: 0)
    }

    func testReachedAtAndAboveTheSafePointButNotUnder() {
        let sp = SafePoint(percent: 90)
        XCTAssertFalse(sp.reached(usage(five: 89.9)))
        XCTAssertTrue(sp.reached(usage(five: 90)))
        XCTAssertTrue(sp.reached(usage(five: 97)))
    }

    func testOffUnknownUsageAndNoFiveHourWindowNeverReach() {
        XCTAssertFalse(SafePoint(percent: nil).reached(usage(five: 99)))
        XCTAssertFalse(SafePoint(percent: 90).reached(nil))
        XCTAssertFalse(SafePoint(percent: 90).reached(usage(five: nil)))
    }

    func testTheWeekWindowDoesNotCount() {
        let u = PlanUsage(fiveHour: nil, week: PlanUsage.Window(percent: 99, resetsAt: now.addingTimeInterval(86400)), todayCost: 0)
        XCTAssertFalse(SafePoint(percent: 90).reached(u))
    }

    func testStoredValuesDefaultOffAndClamp() {
        XCTAssertEqual(SafePoint(stored: nil).percent, 90)
        XCTAssertNil(SafePoint(stored: 0).percent)
        XCTAssertEqual(SafePoint(stored: 50).percent, 80)
        XCTAssertEqual(SafePoint(stored: 99).percent, 95)
        XCTAssertEqual(SafePoint(percent: 85).stored, 85)
        XCTAssertEqual(SafePoint(percent: nil).stored, 0)
    }

    func testReasonNamesPercentAndResetTime() {
        let text = SafePoint(percent: 90).reason(usage(five: 91.2, resetsIn: 5400), now: now, calendar: utc)
        XCTAssertEqual(text, "Safe point reached: 91% of the 5-hour limit used, resets at 09:30.")
        XCTAssertNil(SafePoint(percent: 90).reason(usage(five: 50), now: now, calendar: utc))
        XCTAssertNil(SafePoint(percent: nil).reason(usage(five: 99), now: now, calendar: utc))
    }

    func testResetOnAnotherDayNamesTheDay() {
        let text = SafePoint(percent: 90).reason(usage(five: 95, resetsIn: 86400), now: now, calendar: utc)
        XCTAssertEqual(text, "Safe point reached: 95% of the 5-hour limit used, resets at Sat 08:00.")
    }

    func testThePromptHasTheSafePointAndTheUsage() {
        let request = RoundRequest(projectName: "Demo", slots: 2, candidates: [], safePoint: SafePoint(percent: 90), usage: usage(five: 80))
        let message = RoundPrompt.message(for: request)
        XCTAssertTrue(message.contains("Safe point: 90%"))
        XCTAssertTrue(message.contains("Used now: 80%."))
        XCTAssertTrue(RoundPrompt.system.contains("safe point"))
    }

    func testThePromptSaysNothingWhenOff() {
        let message = RoundPrompt.message(for: RoundRequest(projectName: "Demo", slots: 2, candidates: []))
        XCTAssertFalse(message.contains("Safe point"))
    }

    func testPlanARoundStopsAtTheSafePointWithTheReasonAndAsksNoPM() async {
        var asked = false
        let reason: String? = "Safe point reached: 91% of the 5-hour limit used, resets at 09:30."
        let card = TaskCard(id: "A", project: "d", status: .todo, agent: nil, branch: nil, kind: nil, files: ["a"], title: "A", sections: ["Goal": "g"], url: URL(fileURLWithPath: "/tmp/A.md"))
        let model = RoundModel(enabled: { true }, cards: { [card] }, maxParallel: { 3 }, projectName: { "Demo" },
                               propose: { _ in asked = true; throw PMDecisionError.unreadable }, planStart: { _ in .failure(.invalid("x")) },
                               conflict: { _, _ in nil }, start: { _ in nil }, record: { _ in }, safePointReason: { reason })
        await model.plan()
        XCTAssertEqual(model.state, .failed(reason!))
        XCTAssertFalse(asked)
    }

    func testPlanARoundTellsThePMTheSafePoint() async {
        var seen: RoundRequest?
        let card = TaskCard(id: "A", project: "d", status: .todo, agent: nil, branch: nil, kind: nil, files: ["a"], title: "A", sections: ["Goal": "g"], url: URL(fileURLWithPath: "/tmp/A.md"))
        let plan = StartPlan(card: card, agentName: "dev-a", branch: "task/a", rolePath: "/r", worktreePath: "/w", commandPreview: "x", roleName: "dev")
        let u = usage(five: 80)
        let model = RoundModel(enabled: { true }, cards: { [card] }, maxParallel: { 3 }, projectName: { "Demo" },
                               propose: { r in seen = r; return RoundReply(proposal: RoundProposal(cards: [RoundPick(id: "A", why: "w")]), costUSD: nil) },
                               planStart: { _ in .success(plan) }, conflict: { _, _ in nil }, start: { _ in nil }, record: { _ in },
                               safePoint: { (SafePoint(percent: 90), u) })
        await model.plan()
        XCTAssertEqual(seen?.safePoint, SafePoint(percent: 90))
        XCTAssertEqual(seen?.usage, u)
    }

    private var todoCard: TaskCard {
        TaskCard(id: "N900", project: "d", status: .todo, agent: nil, branch: nil, kind: nil, files: ["a"], title: "Add the thing", sections: ["Goal": "g"], url: URL(fileURLWithPath: "/tmp/N900.md"))
    }

    func testStartIsOffWithTheReason() {
        let reason = SafePoint(percent: 90).reason(usage(five: 91), now: now, calendar: utc)
        let state = startButtonState(card: todoCard, canStart: reason == nil, reason: reason)
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.help, reason)
        XCTAssertTrue(startButtonState(card: todoCard, canStart: true, reason: nil).enabled)
    }

    func testSnapshotsOfTheSettingAndOfAStartThatIsOff() async throws {
        let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"]
        let reason = SafePoint(percent: 90).reason(usage(five: 91), now: now, calendar: utc)
        let detail = TaskDetailView(card: todoCard, shots: [], opener: nil, startState: startButtonState(card: todoCard, canStart: false, reason: reason),
                                    reviewState: reviewButtonStates(card: todoCard, canAct: true, reason: nil),
                                    onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {})
        let start = try XCTUnwrap(SnapshotRenderer.render(view: detail, size: CGSize(width: 900, height: 300)))
        XCTAssertGreaterThan(start.count, 5_000)
        let flow = SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: URL(fileURLWithPath: "/tmp/p.json"), stableDir: URL(fileURLWithPath: "/tmp/s"),
                                signingConfigured: false, git: NoGit(), release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") },
                                appURL: URL(fileURLWithPath: "/tmp/T.app"), processID: 1, launch: { _, _ in },
                                extras: SettingsExtras(defaults: makeTestDefaults(prefix: "safe-point"), loginItem: NoLogin(), toolProbe: { _ in nil }))
        flow.show(.keepAwake)
        let settings = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: flow, safePoint: SafePoint(percent: 90), safePointReason: reason), size: CGSize(width: 900, height: 640)))
        XCTAssertGreaterThan(settings.count, 20_000)
        if let dir {
            try start.write(to: URL(fileURLWithPath: dir).appendingPathComponent("safe-point-start-off.png"))
            try settings.write(to: URL(fileURLWithPath: dir).appendingPathComponent("safe-point-settings.png"))
        }
    }
}
