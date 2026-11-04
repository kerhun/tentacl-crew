import XCTest
@testable import AgentPanel

final class CardParserTests: XCTestCase {
    private func parse(_ name: String) throws -> TaskCard {
        try CardParser.parse(Fixture.text("cards/\(name)"), url: Fixture.url("cards/\(name)"))
    }

    func testParsesExampleCard() throws {
        let card = try parse("example.md")
        XCTAssertEqual(card.id, "A5")
        XCTAssertEqual(card.status, .todo)
        XCTAssertEqual(card.files, ["MyAppWidgets/MyAppWidgets.swift"])
        XCTAssertFalse(card.sections["Scope"]?.isEmpty ?? true)
        XCTAssertEqual(card.title, "A5 · Verify the widget findings")
    }

    func testParsesAnalysisCardWithReportTable() throws {
        let card = try parse("analysis.md")
        XCTAssertEqual(card.kind, "analysis")
        XCTAssertEqual(card.status, .review)
        XCTAssertEqual(card.agent, "dev-a3")
        XCTAssertTrue(card.sections["Report"]?.contains("| Item | Status |") ?? false)
        XCTAssertTrue(card.sections["Review packet"]?.contains("no build or screenshots") ?? false)
    }

    func testFingerprintChangesWithFrontMatterOnly() throws {
        let a = try CardParser.parse("---\nid: A\nstatus: todo\n---\n# A\nbody one\n", url: URL(fileURLWithPath: "/tmp/a.md"))
        let sameFront = try CardParser.parse("---\nid: A\nstatus: todo\n---\n# A\nbody two\n", url: URL(fileURLWithPath: "/tmp/a.md"))
        let otherFront = try CardParser.parse("---\nid: A\nstatus: todo\nbranch: x\n---\n# A\nbody one\n", url: URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertFalse(a.fingerprint.isEmpty)
        XCTAssertEqual(a.fingerprint, sameFront.fingerprint)
        XCTAssertNotEqual(a.fingerprint, otherFront.fingerprint)
    }

    func testUnknownStatusIsKept() throws {
        XCTAssertEqual(try parse("unknown-status.md").status, .unknown("waiting"))
    }

    func testKnownStatusRawValues() {
        XCTAssertEqual(TaskStatus(raw: "awaiting-start-approval"), .awaitingStartApproval)
        XCTAssertEqual(TaskStatus(raw: "needs-fix"), .needsFix)
        XCTAssertEqual(TaskStatus(raw: "done"), .done)
    }

    func testNoFrontMatterThrows() {
        XCTAssertThrowsError(try parse("no-front-matter.md")) { XCTAssertEqual($0 as? CardParseError, .noFrontMatter) }
    }

    func testMissingIdThrows() {
        XCTAssertThrowsError(try parse("missing-id.md")) { XCTAssertEqual($0 as? CardParseError, .missingID) }
    }

    func testHalfWrittenCardWithoutClosingDelimiterThrowsNoFrontMatter() {
        XCTAssertThrowsError(try parse("unterminated.md")) { XCTAssertEqual($0 as? CardParseError, .noFrontMatter) }
    }

    func testFlowStyleFilesAreParsedAsList() throws {
        XCTAssertEqual(try parse("flow-files.md").files, ["App/A.swift", "App/B.swift"])
    }

    func testEmptySectionsAreEmptyStrings() throws {
        let card = try parse("empty-sections.md")
        XCTAssertEqual(card.sections["Goal"], "")
        XCTAssertEqual(card.sections["Scope"], "")
        XCTAssertEqual(card.sections["Report"], "")
    }

    func testPriorityRoundTrip() throws {
        func parsed(_ line: String) throws -> TaskCard {
            try CardParser.parse("---\nid: A\nstatus: todo\n\(line)---\n# A\n", url: URL(fileURLWithPath: "/tmp/a.md"))
        }
        XCTAssertEqual(try parsed("priority: high\n").priority, .high)
        XCTAssertEqual(try parsed("priority: Low\n").priority, .low)
        XCTAssertEqual(try parsed("priority: normal\n").priority, .normal)
        XCTAssertEqual(try parsed("").priority, .normal, "missing is normal")
        XCTAssertEqual(try parsed("priority: urgent\n").priority, .normal, "unknown is normal")
        XCTAssertEqual(try parsed("priority: \n").priority, .normal)
    }
}
