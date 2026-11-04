import XCTest
import SwiftUI
@testable import AgentPanel

final class TokenTests: XCTestCase {
    func testColorsMatchSpec() {
        XCTAssertEqual(Tok.Hex.bg, 0x14161B)
        XCTAssertEqual(Tok.Hex.rail, 0x101216)
        XCTAssertEqual(Tok.Hex.pane, 0x1A1D23)
        XCTAssertEqual(Tok.Hex.raise, 0x21252D)
        XCTAssertEqual(Tok.Hex.line, 0x2A2F39)
        XCTAssertEqual(Tok.Hex.ink, 0xE9ECF2)
        XCTAssertEqual(Tok.Hex.ink2, 0xA2A9B8)
        XCTAssertEqual(Tok.Hex.ink3, 0x8A92A3)
        XCTAssertEqual(Tok.Hex.go, 0x4CC38A)
        XCTAssertEqual(Tok.Hex.work, 0x5AA2F0)
        XCTAssertEqual(Tok.Hex.wait, 0xE6B450)
        XCTAssertEqual(Tok.Hex.ask, 0xFF5A36)
        XCTAssertEqual(Tok.Hex.askInk, 0x1B0C07)
        XCTAssertEqual(Tok.radius, 10)
    }

    /// Orange means "waiting for your decision" and nothing else.
    func testAskColorOnlyUsedForPendingApproval() {
        XCTAssertEqual(StatusDot.color(for: .review), Tok.ask)
        XCTAssertEqual(StatusDot.color(for: .awaitingStartApproval), Tok.ask)
        for status: TaskStatus in [.todo, .doing, .needsFix, .done, .blocked, .unknown("x")] {
            XCTAssertNotEqual(StatusDot.color(for: status), Tok.ask, "\(status) must not use the ask colour")
        }
    }

    func testEveryStatusHasADistinctMeaningColour() {
        XCTAssertEqual(StatusDot.color(for: .doing), Tok.work)
        XCTAssertEqual(StatusDot.color(for: .done), Tok.go)
        XCTAssertEqual(StatusDot.color(for: .needsFix), Tok.wait)
    }
}
