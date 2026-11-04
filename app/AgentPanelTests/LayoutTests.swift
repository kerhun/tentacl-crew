import XCTest
@testable import AgentPanel

final class LayoutTests: XCTestCase {
    func testTheConversationHeightStaysBetweenTheMinimumAndWhatTheColumnLeaves() {
        XCTAssertEqual(CommandBar.clampedHeight(230, max: 600), 230)
        XCTAssertEqual(CommandBar.clampedHeight(40, max: 600), CommandBar.minChatHeight)
        XCTAssertEqual(CommandBar.clampedHeight(900, max: 600), 600)
        XCTAssertEqual(CommandBar.clampedHeight(300, max: 50), CommandBar.minChatHeight, "a short window still shows the minimum")
    }

    /// The window's minimum width minus the rail still fits the dashboard's three columns; narrower widths wrap to two, then one.
    func testTheDashboardKeepsThreeColumnsAtTheWindowsMinimumWidthAndWrapsWhenNarrower() {
        let minimum = ShellView.minimumWindow.width - ClickTargets.railWidth - 1
        let wide = DashboardLayout(width: minimum)
        XCTAssertEqual(wide.columns, 3)
        XCTAssertLessThanOrEqual(wide.left + wide.right + DashboardLayout.minCentre + 2 * DashboardLayout.gap + 2 * DashboardLayout.padding, minimum)
        XCTAssertEqual(DashboardLayout(width: 760).columns, 2)
        XCTAssertEqual(DashboardLayout(width: 480).columns, 1)
        let huge = DashboardLayout(width: 2400)
        XCTAssertGreaterThan(huge.left, wide.left, "the side columns grow a little with the window")
        XCTAssertLessThanOrEqual(huge.left, DashboardLayout.maxLeft)
        XCTAssertLessThanOrEqual(huge.right, DashboardLayout.maxRight)
    }
}

@MainActor
final class PanelActionResultTests: XCTestCase {
    /// A round start or a passed-on fix that worked returns nil; it must not come back as "The panel is closing." (seen in the Round sheet).
    func testASuccessfulActionIsNotReportedAsAFailure() async throws {
        let dir = try TempDir()
        let iso = TestIsolation(dir, owner: self)
        let panel = PanelModel(settingsURL: dir.url.appendingPathComponent("projects.json"), makeTerminal: { FakeTerminal(agentsResult: .success([])) }, opener: WorkspaceURLOpener(),
                               log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        let ok = await PanelModel.failure(of: panel) { _ in nil }
        XCTAssertNil(ok)
        let failed = await PanelModel.failure(of: panel) { _ in "no slot" }
        XCTAssertEqual(failed, "no slot")
        let gone = await PanelModel.failure(of: nil) { _ in nil }
        XCTAssertEqual(gone, "The panel is closing.")
    }
}
