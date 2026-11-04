import XCTest
@testable import AgentPanel

/// FlowLayout line breaking (the Dashboard and Timeline still wrap with it).
final class TaskRowLayoutTests: XCTestCase {
    private func sizes(_ widths: [CGFloat]) -> [CGSize] { widths.map { CGSize(width: $0, height: 10) } }

    func testFlowFitsOnOneLine() {
        XCTAssertEqual(FlowLayout.breakLines(sizes([30, 30, 30]), width: 100, spacing: 4), [[0, 1, 2]])
    }

    func testFlowWrapsWhenTheNextDoesNotFit() {
        XCTAssertEqual(FlowLayout.breakLines(sizes([40, 40, 40]), width: 100, spacing: 4), [[0, 1], [2]])
        XCTAssertEqual(FlowLayout.breakLines(sizes([46, 50]), width: 100, spacing: 4), [[0, 1]])
        XCTAssertEqual(FlowLayout.breakLines(sizes([46, 51]), width: 100, spacing: 4), [[0], [1]])
    }

    func testFlowKeepsATooWideItemOnItsOwnLine() {
        XCTAssertEqual(FlowLayout.breakLines(sizes([20, 300, 20]), width: 100, spacing: 4), [[0], [1], [2]])
        XCTAssertEqual(FlowLayout.breakLines(sizes([300]), width: 100, spacing: 4), [[0]])
    }

    func testFlowOfNothingIsNoLines() {
        XCTAssertEqual(FlowLayout.breakLines([], width: 100, spacing: 4), [])
    }
}
