import XCTest
import SwiftUI
@testable import AgentPanel

final class HistoryLogicTests: XCTestCase {
    private var cal = Calendar(identifier: .gregorian)
    private func date(_ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
    private func rec(_ id: String, _ time: Date, card: String = "N1", kind: String = "choice", by: DecisionRecord.By = .pm, cost: Double? = nil) -> DecisionRecord {
        DecisionRecord(id: id, time: time, cardID: card, agent: "dev-\(card.lowercased())", kind: kind, question: "Q \(id)", by: by, result: .answered, answer: "A \(id)", why: "because", costUSD: cost)
    }

    func testAllRecordsAreListedNewestFirstGroupedByDay() {
        let records = (1...10).map { rec("r\($0)", date($0 < 6 ? 16 : 17, $0)) }
        let days = historyDays(records, filter: HistoryFilter(), calendar: cal)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.map { $0.rows.count }, [5, 5], "not limited to six")
        XCTAssertEqual(days[0].day, cal.startOfDay(for: date(17, 0)))
        XCTAssertEqual(days[0].rows.map(\.id), ["r10", "r9", "r8", "r7", "r6"])
        XCTAssertEqual(days[1].rows.map(\.id), ["r5", "r4", "r3", "r2", "r1"])
    }

    func testTheCardSearchAndTheWhoFilterNarrowTheList() {
        let records = [rec("a", date(16, 1), card: "N74"), rec("b", date(16, 2), card: "N7", by: .you), rec("c", date(16, 3), card: "N74", by: .you), rec("d", date(16, 4), card: "A1")]
        func ids(_ f: HistoryFilter) -> [String] { historyDays(records, filter: f, calendar: cal).flatMap(\.rows).map(\.id) }
        XCTAssertEqual(ids(HistoryFilter(card: "n74")), ["c", "a"], "case-insensitive")
        XCTAssertEqual(ids(HistoryFilter(card: " N7 ")), ["c", "b", "a"])
        XCTAssertEqual(ids(HistoryFilter(who: .you)), ["c", "b"])
        XCTAssertEqual(ids(HistoryFilter(card: "N74", who: .pm)), ["a"])
        XCTAssertEqual(ids(HistoryFilter(card: "zzz")), [])
    }

    func testKindsAreNamedInPlainWords() {
        XCTAssertEqual(historyKind("choice"), "question")
        XCTAssertEqual(historyKind("freeText"), "question")
        XCTAssertEqual(historyKind("permission"), "permission")
        XCTAssertEqual(historyKind("fix"), "fix")
        XCTAssertEqual(historyKind(AutopilotModel.roundKind), "round")
        XCTAssertEqual(historyKind(AutopilotModel.rebaseKind), "rebase")
        XCTAssertEqual(historyKind(AutopilotModel.startKind), "start")
        XCTAssertEqual(historyKind(AutopilotModel.approveKind), "approve")
    }

    func testEveryKnownKindHasAColourAndAnUnknownOneStaysGrey() {
        for kind in Self.kinds { XCTAssertNotNil(historyKindTint(kind), kind) }
        XCTAssertNil(historyKindTint("something-new"))
        XCTAssertNil(historyKindTint(""))
    }

    static let kinds = ["review", AutopilotModel.startKind, "plan", "permission", "fix", AutopilotModel.roundKind, AutopilotModel.rebaseKind, "choice", "freeText", AutopilotModel.authorityResetKind, AutopilotModel.approveKind, "answered-by-pm"]

    func testTheCostShowsOnlyWhenKnown() {
        XCTAssertEqual(historyCost(0.0412), "$0.04")
        XCTAssertNil(historyCost(nil))
    }
}

@MainActor
final class HistoryViewTests: XCTestCase {
    func testClickingARowSelectsItsCard() {
        var picked: [String] = []
        let r = DecisionRecord(id: "x", time: Date(), cardID: "N74", agent: "dev", kind: "choice", question: "Q", by: .pm, result: .answered, answer: "A", why: "w")
        HistoryRow.open(r, select: { picked.append($0) })
        XCTAssertEqual(picked, ["N74"])
        HistoryRow.open(DecisionRecord(id: "y", time: Date(), cardID: "", agent: "", kind: "round", question: "", by: .pm, result: .answered, answer: "", why: ""), select: { picked.append($0) })
        XCTAssertEqual(picked, ["N74"], "a row without a card selects nothing")
    }

    func testTheHistoryTabRendersManyDaysAndFiltersEmpty() throws {
        let now = Date()
        var rows: [DecisionRecord] = []
        for i in 0..<14 {
            let card = "N\(70 + i % 4)"
            let time = now.addingTimeInterval(Double(-i) * 40_000)
            let by: DecisionRecord.By = i % 5 == 0 ? .you : .pm
            let kind = i % 3 == 0 ? "permission" : "choice"
            let cost: Double? = i % 2 == 0 ? 0.03 : nil
            rows.append(DecisionRecord(id: "r\(i)", time: time, cardID: card, agent: "dev", kind: kind, question: "Which option for step \(i)?", by: by, result: .answered, answer: "Option \(i)", why: "It keeps the change small.", costUSD: cost))
        }
        let view = HistoryView(records: rows, deciding: [], select: { _ in })
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.frame(width: 340, height: 760), size: CGSize(width: 340, height: 760)))
        XCTAssertGreaterThan(data.count, 6_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("history.png")) }
        let empty = try XCTUnwrap(SnapshotRenderer.render(view: HistoryView(records: [], deciding: [], select: { _ in }).frame(width: 340, height: 300), size: CGSize(width: 340, height: 300)))
        XCTAssertGreaterThan(empty.count, 1_000)
    }

    /// One row per kind in a typical order, so the colours can be judged side by side (N281).
    func testSnapshotTheActivityListWithEveryKind() throws {
        let now = Date()
        let kinds = HistoryLogicTests.kinds + ["unknown-kind"]
        let rows = kinds.enumerated().map { i, kind in
            DecisionRecord(id: "k\(i)", time: now.addingTimeInterval(Double(-i) * 600), cardID: kind == AutopilotModel.roundKind ? "" : "N\(270 + i)", agent: "dev", kind: kind, question: "", by: i % 4 == 3 ? .you : .pm, result: .answered, answer: "Answer for \(kind)", why: "")
        }
        for (scheme, name) in [(ColorScheme.dark, "N281-activity-dark"), (.light, "N281-activity-light")] {
            let view = HistoryView(records: rows, deciding: [], select: { _ in }).frame(width: 360, height: 760).environment(\.colorScheme, scheme)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 360, height: 760)))
            XCTAssertGreaterThan(data.count, 6_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
        }
    }
}
