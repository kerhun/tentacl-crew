import XCTest
@testable import AgentPanel

final class DockBadgeTests: XCTestCase {
    func testBadgeShowsTheWaitingCount() {
        XCTAssertEqual(DockBadge.label(count: 3, enabled: true), "3")
    }

    func testZeroHidesTheBadge() {
        XCTAssertNil(DockBadge.label(count: 0, enabled: true))
    }

    func testSettingOffHidesTheBadge() {
        XCTAssertNil(DockBadge.label(count: 5, enabled: false))
    }

    @MainActor func testBadgeIsTheInboxCount() {
        func content(_ ready: Int) -> TopBarInbox.Content { TopBarInbox.Content(questions: [], ready: (0..<ready).map { TopBarInbox.Ready(id: "\($0)", title: "C") }) }
        XCTAssertEqual(DockBadge.label(count: content(2).count, enabled: true), "2", "ready cards count like in the Inbox")
        XCTAssertEqual(DockBadge.label(count: content(3).count, enabled: true), "3", "a card turning ready raises it")
        XCTAssertEqual(DockBadge.label(count: content(2).count, enabled: true), "2", "approving lowers it")
        XCTAssertNil(DockBadge.label(count: content(0).count, enabled: true))
    }
}
