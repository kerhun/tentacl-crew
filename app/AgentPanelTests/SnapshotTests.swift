import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class SnapshotTests: XCTestCase {
    func testDemoModelHasCardsAgentsAndAnUnreadableCard() async throws {
        let model = await DemoSupport.makeModel()
        XCTAssertEqual(model.projects.map(\.id), ["demo"])
        XCTAssertGreaterThanOrEqual(model.cards.count, 9)
        XCTAssertTrue(model.cards.contains { if case .unreadable = $0 { return true } else { return false } })
        guard case .available(let agents) = model.agents else { return XCTFail("demo agents should be available") }
        XCTAssertGreaterThanOrEqual(agents.count, 3)
        XCTAssertEqual(model.pendingApprovalCount, 3)   // A1, A4 (review) and B1 (awaiting start)
        XCTAssertNotNil(model.selectedCard)
    }

    func testRendersNonEmptyPNG() async throws {
        let model = await DemoSupport.makeModel()
        let data = try XCTUnwrap(SnapshotRenderer.render(model: model, size: CGSize(width: 1440, height: 860)))
        XCTAssertGreaterThan(data.count, 20_000)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 2880)
        XCTAssertEqual(rep.pixelsHigh, 1720)
        // For visual checks: TEST_RUNNER_AGENT_PANEL_SNAPSHOT_PATH=/tmp/panel.png scripts/app-test.sh -only-testing:AgentPanelTests/SnapshotTests
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }

    /// Every screen but Dashboard and Tasks starts its content one page margin from the rail (N222): each one beside the rail, at the same
    /// window size, so the left edges can be compared (page-<screen>.png in AGENT_PANEL_SNAPSHOT_DIR).
    func testScreensBesideTheRail() async throws {
        let model = await DemoSupport.makeModel()
        let settings = model.makeSettingsFlow()
        let git = GitScreenModel(reader: nil, details: GitDetails(branch: "main", remoteURL: "git@github.com:kerhun/demo.git", upstream: "origin/main", lastFetch: Date()),
                                 projectID: model.selectedProjectID)
        let screens: [(ShellScreen, AnyView)] = [
            (.team, AnyView(TeamView(model: model.team, cards: model.selectedTaskCards))),
            (.stats, AnyView(StatsView(stats: StatsModel(model: model)))),
            (.git, AnyView(GitView(model: model, git: git))),
            (.plan, AnyView(PlanView(model: model))),
            (.settings, AnyView(SettingsView(flow: settings, onCleanup: {}))),
            (.timeline, AnyView(TimelineScreen(model: model))),
        ]
        for (screen, content) in screens {
            let view = HStack(spacing: 0) { Rail(screen: screen, onSelect: { _ in }); Divider().overlay(Tok.line); content }.background(Tok.bg)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1200, height: 640)))
            XCTAssertGreaterThan(data.count, 20_000)
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("page-\(screen.rawValue).png")) }
        }
    }
}
