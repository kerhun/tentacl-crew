import XCTest
@testable import AgentPanel

final class ChatRowsTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func e(_ id: String, _ kind: ChatEntry.Kind, _ text: String, at s: TimeInterval = 0, pending: ChatEntry.Pending? = nil) -> ChatEntry {
        ChatEntry(id: id, kind: kind, text: text, time: t0.addingTimeInterval(s), pending: pending)
    }
    private func build(_ entries: [ChatEntry]) -> [ChatRow] { ChatRows.build(entries: entries, previous: [], now: t0, calendar: cal) }

    func testPanelNotesWithAcksFoldIntoOneSystemRow() {
        let rows = build([e("1", .panel, "Panel: started N280"), e("2", .agent, "✓", at: 5), e("3", .panel, "Panel: started N281", at: 10), e("4", .agent, "✓.", at: 15)])
        XCTAssertEqual(rows.count, 2)
        guard case .system(let events) = rows[1] else { return XCTFail() }
        XCTAssertEqual(events.map(\.acked), [true, true])
        XCTAssertFalse(rows.contains { if case .turn = $0 { true } else { false } })
    }

    func testToolsBetweenANoteAndItsAckAreDropped() {
        let rows = build([e("1", .panel, "Panel: x"), e("2", .tools, "ran 1 command", at: 1), e("3", .agent, "✓", at: 2)])
        XCTAssertEqual(rows.count, 2)
        guard case .system(let events) = rows[1] else { return XCTFail() }
        XCTAssertEqual(events.map(\.acked), [true])
    }

    func testAFailedPanelNoteStaysItsOwnRowAndIsNotAcked() {
        let rows = build([e("1", .panel, "Panel: a"), e("2", .panel, "Panel: b", at: 1, pending: .failed("no")), e("3", .panel, "Panel: c", at: 2), e("4", .agent, "✓", at: 3)])
        XCTAssertEqual(rows.count, 4, "day + three system rows")
        guard case .system(let last) = rows[3] else { return XCTFail() }
        XCTAssertEqual(last.map(\.id), ["3"])
        XCTAssertEqual(last.map(\.acked), [true])
        guard case .system(let stuck) = rows[2] else { return XCTFail() }
        XCTAssertEqual(stuck.map(\.acked), [false])
    }

    func testOtherKindsAndTextAcksStayTurns() {
        let rows = build([e("1", .user, "hi"), e("2", .agent, "✓ done"), e("3", .summary, "s"), e("4", .tools, "ran 1 command")])
        XCTAssertEqual(rows.dropFirst().map(\.id), ["1", "2", "3", "4"])
    }

    func testDayAndGapRows() {
        let rows = build([e("1", .user, "a"), e("2", .agent, "b", at: 7200), e("3", .user, "c", at: 86_400 * 2)])
        XCTAssertEqual(rows.count, 6)
        guard case .day = rows[0], case .gap(let g) = rows[2], case .day = rows[4] else { return XCTFail() }
        XCTAssertEqual(g, 7200)
    }
}
