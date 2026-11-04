import XCTest
@testable import AgentPanel

@MainActor
final class NotesModelTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    /// 2026-10-19 12:00 UTC.
    private let monday = Date(timeIntervalSince1970: 1_792_411_200)

    private func makeModel(_ dir: TempDir, now: Date? = nil) -> NotesModel {
        let date = now ?? monday
        return NotesModel(fileURL: dir.url.appendingPathComponent("notes.md"), now: { date }, calendar: calendar)
    }

    private let sample = """
    ## 2026-10-19
    - [ ] Tasks: show how many cards each section has
    - [x] Notes panel: compare A and B <!-- done 2026-10-19 -->

    ## 2026-10-18
    - [ ] Chat: type a card id and show it as a link <!-- task N124 -->
    - [x] Old idea <!-- done 2026-10-18 -->
    """

    // MARK: file format

    func testParseReadsDaysLinesDoneDatesAndTaskLinks() {
        let days = NotesFile.parse(sample)
        XCTAssertEqual(days.map(\.date), ["2026-10-19", "2026-10-18"])
        XCTAssertEqual(days[0].lines.map(\.text), ["Tasks: show how many cards each section has", "Notes panel: compare A and B"])
        XCTAssertEqual(days[0].lines.map(\.done), [false, true])
        XCTAssertEqual(days[0].lines[1].doneOn, "2026-10-19")
        XCTAssertEqual(days[1].lines[0].task, "N124")
        XCTAssertEqual(days[1].lines[0].text, "Chat: type a card id and show it as a link")
    }

    func testWriteOfParseGivesTheSameText() {
        XCTAssertEqual(NotesFile.write(NotesFile.parse(sample)), sample + "\n")
    }

    func testMalformedLinesAreKeptAsWritten() {
        let text = """
        a line before any day
        ## 2026-10-19
        - [ ] fine
        just some words
        - [?] odd box
        ## not a date
        """
        let days = NotesFile.parse(text)
        XCTAssertEqual(days[0].date, nil)
        XCTAssertEqual(days[0].lines.map(\.raw), [true])
        XCTAssertEqual(days[1].lines.map(\.text), ["fine", "just some words", "- [?] odd box", "## not a date"])
        XCTAssertEqual(days[1].lines.map(\.raw), [false, true, true, true])
        XCTAssertEqual(NotesFile.write(days), """
        a line before any day

        ## 2026-10-19
        - [ ] fine
        just some words
        - [?] odd box
        ## not a date

        """)
    }

    func testWriteSortsDaysNewestFirstAndMergesARepeatedHeading() {
        let days = NotesFile.parse("## 2026-10-17\n- [ ] a\n## 2026-10-19\n- [ ] b\n## 2026-10-17\n- [ ] c\n")
        XCTAssertEqual(NotesFile.write(days), "## 2026-10-19\n- [ ] b\n\n## 2026-10-17\n- [ ] a\n- [ ] c\n")
    }

    func testAMultiLineNoteIsOneItemWithIndentedContinuationLines() throws {
        let text = "## 2026-10-19\n- [ ] one <!-- task N130 -->\n  two\n    three, indented\n- [x] single <!-- done 2026-10-19 -->\n"
        let days = NotesFile.parse(text)
        XCTAssertEqual(days[0].lines.map(\.text), ["one\ntwo\n  three, indented", "single"])
        XCTAssertEqual(days[0].lines[0].task, "N130")
        XCTAssertEqual(NotesFile.write(days), text)
        // Saved by the model and read back from disk as the same one note.
        let dir = try TempDir()
        let notes = makeModel(dir)
        notes.add("  first line\n\nsecond line  \n")
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-19\n- [ ] first line\n  second line\n")
        let id = try XCTUnwrap(notes.groups.first?.lines.first?.id)
        notes.edit(id, to: "first line\nsecond\nthird")
        XCTAssertEqual(makeModel(dir).groups.first?.lines.map(\.text), ["first line\nsecond\nthird"])
        XCTAssertEqual(makeModel(dir).openCount, 1)
        notes.delete(id)
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "")
    }

    func testAnIndentedLineAfterAHandWrittenLineStaysAsWritten() {
        let days = NotesFile.parse("## 2026-10-19\njust words\n  indented words\n")
        XCTAssertEqual(days[0].lines.map(\.text), ["just words", "indented words"])
        XCTAssertEqual(days[0].lines.map(\.raw), [true, true])
    }

    // MARK: grouping and folding

    func testGroupsByDayNewestFirstWithTodayAndYesterdayTitles() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-16\n- [ ] older\n## 2026-10-19\n- [ ] today\n## 2026-10-18\n- [ ] yesterday\n")
        let notes = makeModel(dir)
        XCTAssertEqual(notes.groups.map(\.title), ["Today", "Yesterday", "Fri 16 Oct"])
        XCTAssertEqual(notes.groups.map { $0.lines.map(\.text) }, [["today"], ["yesterday"], ["older"]])
        XCTAssertEqual(notes.openCount, 3)
    }

    func testDoneLinesFoldAwayADayAfterTheyWereChecked() throws {
        let dir = try TempDir()
        try dir.write("notes.md", sample)
        let notes = makeModel(dir)
        // Checked today: still shown, struck through. Checked yesterday: folded.
        XCTAssertEqual(notes.groups.map { $0.lines.map(\.text) }, [["Tasks: show how many cards each section has", "Notes panel: compare A and B"],
                                                                   ["Chat: type a card id and show it as a link"]])
        XCTAssertEqual(notes.foldedCount, 1)
        notes.showDone = true
        XCTAssertEqual(notes.groups[1].lines.map(\.text), ["Chat: type a card id and show it as a link", "Old idea"])
        // The next day the line checked today folds too.
        let tomorrow = makeModel(dir, now: monday.addingTimeInterval(86_400))
        XCTAssertEqual(tomorrow.foldedCount, 2)
    }

    func testADayWithOnlyFoldedLinesIsNotShown() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-19\n- [ ] a\n## 2026-10-10\n- [x] old <!-- done 2026-10-10 -->\n")
        XCTAssertEqual(makeModel(dir).groups.map(\.title), ["Today"])
    }

    // MARK: editing

    func testAddPutsTheLineFirstUnderTodayAndSavesTheFile() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-18\n- [ ] yesterday\n")
        let notes = makeModel(dir)
        notes.add("  first  ")
        notes.add("second")
        notes.add("   ")
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-19\n- [ ] second\n- [ ] first\n\n## 2026-10-18\n- [ ] yesterday\n")
        XCTAssertEqual(notes.openCount, 3)
        XCTAssertNil(notes.saveError)
    }

    func testAddCreatesTheFileWhenThereIsNone() throws {
        let dir = try TempDir()
        let notes = makeModel(dir)
        XCTAssertTrue(notes.groups.isEmpty)
        notes.add("idea")
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-19\n- [ ] idea\n")
    }

    func testCheckWritesTheDoneDateAndUncheckRemovesIt() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-18\n- [ ] a\n")
        let notes = makeModel(dir)
        let id = try XCTUnwrap(notes.groups.first?.lines.first?.id)
        notes.toggle(id)
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-18\n- [x] a <!-- done 2026-10-19 -->\n")
        XCTAssertEqual(notes.openCount, 0)
        notes.toggle(id)
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-18\n- [ ] a\n")
    }

    func testEditAndDelete() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-19\n- [ ] a\n- [ ] b\n")
        let notes = makeModel(dir)
        let lines = try XCTUnwrap(notes.groups.first?.lines)
        notes.edit(lines[0].id, to: " a, better ")
        notes.edit(lines[1].id, to: "  ")   // an empty edit changes nothing
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-19\n- [ ] a, better\n- [ ] b\n")
        notes.delete(lines[1].id)
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-19\n- [ ] a, better\n")
        notes.delete(lines[0].id)
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "")
        XCTAssertTrue(notes.groups.isEmpty)
    }

    func testLinkTaskMarksTheLineWithTheCardID() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-19\n- [ ] make me a card\n")
        let notes = makeModel(dir)
        notes.linkTask(text: "make me a card", to: "N130")
        XCTAssertEqual(notes.groups.first?.lines.first?.task, "N130")
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-19\n- [ ] make me a card <!-- task N130 -->\n")
    }

    // MARK: disk

    func testReloadsWhenTheFileChangesOnDisk() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-19\n- [ ] a\n")
        let notes = makeModel(dir)
        notes.add("b")
        XCTAssertFalse(notes.reloadIfChanged())   // its own write is not a change
        try "## 2026-10-19\n- [ ] by hand\n".write(to: notes.fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: notes.fileURL.path)
        XCTAssertTrue(notes.reloadIfChanged())
        XCTAssertEqual(notes.groups.first?.lines.map(\.text), ["by hand"])
    }

    func testANotesIDOutlivesAReloadSoTogglesEditsAndDeletesHitTheLineThatWasClicked() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-19\n- [ ] one\n  more\n- [ ] two\n\n## 2026-10-18\n- [ ] three\n- [ ] four\n")
        let notes = makeModel(dir)
        let ids = Dictionary(uniqueKeysWithValues: notes.groups.flatMap(\.lines).map { ($0.text, $0.id) })
        // Written from outside (the user or the PM): a new line on top, "two" ticked by hand.
        try "## 2026-10-19\n- [ ] new\n- [ ] one\n  more\n- [x] two\n\n## 2026-10-18\n- [ ] three\n- [ ] four\n"
            .write(to: notes.fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: notes.fileURL.path)
        XCTAssertTrue(notes.reloadIfChanged())
        XCTAssertEqual(notes.days.flatMap(\.lines).filter { $0.text != "new" }.map(\.id), ["one\nmore", "two", "three", "four"].map { ids[$0] })
        notes.toggle(try XCTUnwrap(ids["three"]))
        notes.edit(try XCTUnwrap(ids["four"]), to: "four, better")
        notes.delete(try XCTUnwrap(ids["one\nmore"]))
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8),
                       "## 2026-10-19\n- [ ] new\n- [x] two\n\n## 2026-10-18\n- [x] three <!-- done 2026-10-19 -->\n- [ ] four, better\n")
    }

    func testTwoNotesWithTheSameTextKeepTheirOwnIDs() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## 2026-10-19\n- [ ] same\n- [ ] same\n")
        let notes = makeModel(dir)
        let ids = try XCTUnwrap(notes.groups.first?.lines.map(\.id))
        notes.reload()
        XCTAssertEqual(notes.groups.first?.lines.map(\.id), ids)
        notes.toggle(ids[1])
        XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8), "## 2026-10-19\n- [ ] same\n- [x] same <!-- done 2026-10-19 -->\n")
    }

    func testEachProjectHasItsOwnFile() throws {
        let a = try TempDir(), b = try TempDir()
        let book = NotesBook(now: { self.monday }, calendar: calendar)
        book.notes(dataDir: a.url).add("for a")
        book.notes(dataDir: b.url).add("for b")
        XCTAssertTrue(book.notes(dataDir: a.url) === book.notes(dataDir: a.url))
        XCTAssertEqual(try String(contentsOf: a.url.appendingPathComponent("notes.md"), encoding: .utf8), "## 2026-10-19\n- [ ] for a\n")
        XCTAssertEqual(try String(contentsOf: b.url.appendingPathComponent("notes.md"), encoding: .utf8), "## 2026-10-19\n- [ ] for b\n")
    }

    func testAFailedWriteIsReported() throws {
        let dir = try TempDir()
        try dir.write("notes.md/blocker", "a folder sits where the file should be")
        let notes = makeModel(dir)
        notes.add("x")
        XCTAssertNotNil(notes.saveError)
    }
}
