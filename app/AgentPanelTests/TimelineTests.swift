import XCTest
@testable import AgentPanel

/// The Timeline screen in the rail (N112): its place and shortcut, what it opens on and its snapshot in the window.
@MainActor
final class TimelineTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus) -> TaskCard {
        TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    func testTimelineSitsAfterTasksInTheRailWithTheNextShortcut() {
        // Terminals (N224) sits between Tasks and the Timeline, so the Timeline moved to ⌘4.
        XCTAssertEqual(ShellScreen.railOrder, [.dashboard, .tasks, .terminals, .timeline, .team, .plan, .git, .stats, .settings])
        XCTAssertEqual(ShellScreen.timeline.shortcutDigit, 4)
        XCTAssertEqual(ShellScreen(shortcutDigit: 4), .timeline)
        XCTAssertEqual(ShellScreen.timeline.railHelp, "Timeline (⌘4)")
        XCTAssertEqual(ShellScreen.team.railHelp, "Team (⌘5)")
        XCTAssertEqual(ShellScreen.settings.shortcutDigit, 9)
        XCTAssertEqual(ShellScreen(stored: "timeline"), .timeline, "the window reopens on it")
        XCTAssertFalse(ShellScreen.timeline.railSymbol.isEmpty)
    }

    func testTheScreenOpensOnTheCurrentRound() {
        let file = PlanFile(rounds: [PlanRound(name: "R1", cards: ["A"], reason: "", status: "done"),
                                     PlanRound(name: "R2", cards: ["B"], reason: "", status: ""),
                                     PlanRound(name: "R3", cards: ["C"], reason: "", status: "waiting")], questions: [])
        let content = TimelineScreen.Content(plan: .plan(file), cards: [card("A", .done), card("B", .doing), card("C", .todo)])
        XCTAssertEqual(content, .rounds(file.rounds, initial: "R2"))
    }

    func testNoPlanOrABrokenOneSaysSo() {
        XCTAssertEqual(TimelineScreen.Content(plan: .missing, cards: []), .empty("No rounds yet. The PM writes them to plan.json in the project's data folder."))
        XCTAssertEqual(TimelineScreen.Content(plan: .plan(PlanFile(rounds: [], questions: [])), cards: []), .empty("No rounds yet. The PM writes them to plan.json in the project's data folder."))
        guard case .empty(let text) = TimelineScreen.Content(plan: .broken("bad json"), cards: []) else { return XCTFail("a broken plan has no rounds") }
        XCTAssertTrue(text.contains("bad json"))
    }

    func testAsAScreenTheTimelineHasNoBackButton() {
        let round = PlanRound(name: "R", cards: [], reason: "", status: "")
        let build: (PlanRound) -> RoundTimelineData = { RoundTimeline.build(round: $0, project: "p", cards: [], events: [], decisions: []) }
        XCTAssertFalse(TimelineView(rounds: [round], initial: nil, build: build).showsBack)
        XCTAssertTrue(TimelineView(rounds: [round], initial: nil, build: build, onBack: {}).showsBack)
    }

    func testTheTimelineScreenRendersInTheWindow() async throws {
        let model = await DemoSupport.makeModel()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: ShellView(model: model, screen: .timeline), size: CGSize(width: 1440, height: 860)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("shell-timeline.png")) }
    }
}
