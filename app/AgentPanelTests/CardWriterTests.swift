import XCTest
@testable import AgentPanel

final class CardWriterTests: XCTestCase {
    private let base = "---\nid: A1\nproject: demo\nstatus: todo\nfiles:\n  - App/A.swift\n---\n# A1 · Title\n\n## Goal\nDo it: carefully # not a comment.\n\n## Report\n"

    private func make(_ dir: TempDir, _ text: String? = nil) throws -> (URL, TaskCard) {
        let url = try dir.write("tasks/A1.md", text ?? base)
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n"), url: url)
        return (url, card)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testUpdatesStatusLineOnly() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        try CardWriter().update(card, set: [.status: "doing"], expectingStatus: .todo)
        let after = try read(url)
        XCTAssertTrue(after.contains("\nstatus: doing\n"))
        XCTAssertFalse(after.contains("status: todo"))
        XCTAssertEqual(try CardParser.parse(after, url: url).status, .doing)
    }

    /// Review Focus 7: only the requested front-matter lines may differ.
    func testBodyAndOtherLinesByteIdentical() throws {
        let dir = try TempDir()
        let text = base.replacingOccurrences(of: "status: todo\n", with: "status: todo\nagent:\nbranch:\n")
        let (url, card) = try make(dir, text)
        try CardWriter().update(card, set: [.status: "doing", .agent: "dev-a1", .branch: "feat/a1"], expectingStatus: .todo)
        let before = text.components(separatedBy: "\n"), after = try read(url).components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        let changed = zip(before, after).filter { $0 != $1 }.map { $1 }
        XCTAssertEqual(changed.sorted(), ["agent: dev-a1", "branch: feat/a1", "status: doing"])
    }

    func testAddsMissingAgentAndBranchBeforeClosingDelimiter() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        try CardWriter().update(card, set: [.status: "doing", .agent: "dev-a1", .branch: "feat/a1"], expectingStatus: .todo)
        let parsed = try CardParser.parse(try read(url), url: url)
        XCTAssertEqual(parsed.agent, "dev-a1")
        XCTAssertEqual(parsed.branch, "feat/a1")
        XCTAssertEqual(parsed.files, ["App/A.swift"])
        XCTAssertTrue(try read(url).hasSuffix("## Goal\nDo it: carefully # not a comment.\n\n## Report\n"))
    }

    func testPreservesCRLF() throws {
        let dir = try TempDir()
        let crlf = base.replacingOccurrences(of: "\n", with: "\r\n")
        let (url, card) = try make(dir, crlf)
        try CardWriter().update(card, set: [.status: "doing", .agent: "dev-a1"], expectingStatus: .todo)
        let after = try read(url)
        XCTAssertFalse(after.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line ending must stay CRLF")
        XCTAssertTrue(after.contains("status: doing\r\n"))
        XCTAssertTrue(after.contains("agent: dev-a1\r\n"))
    }

    /// Review Focus 4: someone else changed the card after the panel read it.
    func testConflictWhenStatusChangedSinceRead() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        try base.replacingOccurrences(of: "status: todo", with: "status: doing").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CardWriter().update(card, set: [.status: "doing", .agent: "x"], expectingStatus: .todo)) {
            XCTAssertEqual($0 as? CardWriteError, .conflict(expected: "todo", found: "doing"))
        }
    }

    func testConflictLeavesFileUntouched() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        let changed = base.replacingOccurrences(of: "status: todo", with: "status: review")
        try changed.write(to: url, atomically: true, encoding: .utf8)
        _ = try? CardWriter().update(card, set: [.status: "doing"], expectingStatus: .todo)
        XCTAssertEqual(try read(url), changed)
    }

    /// I4: an edit to another front-matter line (not the status) while the panel was showing the card must not be overwritten.
    func testConflictWhenAnotherFrontMatterLineChangedSinceRead() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        let edited = base.replacingOccurrences(of: "project: demo", with: "project: demo\nbranch: chosen/by-the-pm")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CardWriter().update(card, set: [.status: "doing", .branch: "old/branch"], expectingStatus: .todo)) {
            guard case .conflict = $0 as? CardWriteError else { return XCTFail("expected a conflict, got \($0)") }
        }
        XCTAssertEqual(try read(url), edited)
    }

    func testBodyEditsDoNotCauseAConflict() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        try (base + "\nThe agent added a line to the body.\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try CardWriter().update(card, set: [.status: "doing"], expectingStatus: .todo))
    }

    func testRefusesSymlinkedCard() throws {
        let dir = try TempDir()
        let real = try dir.write("real/A1.md", base)
        let link = dir.url.appendingPathComponent("tasks/A1.md")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let card = try CardParser.parse(base, url: link)
        XCTAssertThrowsError(try CardWriter().update(card, set: [.status: "doing"], expectingStatus: .todo)) {
            XCTAssertEqual($0 as? CardWriteError, .isSymlink)
        }
        XCTAssertEqual(try read(real), base)
    }

    func testKeepsFilePermissions() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try CardWriter().update(card, set: [.status: "doing"], expectingStatus: .todo)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o640)
    }

    func testNoTempFileLeftBehind() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        try CardWriter().update(card, set: [.status: "doing"], expectingStatus: .todo)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["A1.md"])
    }

    func testValuesWithSpecialCharactersAreWrittenVerbatim() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        try CardWriter().update(card, set: [.branch: "feat/x: a #b \"q\""], expectingStatus: .todo)
        XCTAssertEqual(try CardParser.parse(try read(url), url: url).branch, "feat/x: a #b \"q\"")
    }

    func testRejectsValueWithLineBreak() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir)
        XCTAssertThrowsError(try CardWriter().update(card, set: [.agent: "dev\nstatus: done"], expectingStatus: .todo)) {
            guard case .writeFailed = $0 as? CardWriteError else { return XCTFail("expected writeFailed, got \($0)") }
        }
        XCTAssertEqual(try read(url), base, "front-matter injection must not reach the file")
    }

    func testUnreadableCardIsReported() throws {
        let dir = try TempDir()
        let card = try CardParser.parse(base, url: dir.url.appendingPathComponent("tasks/gone.md"))
        XCTAssertThrowsError(try CardWriter().update(card, set: [.status: "doing"], expectingStatus: .todo)) {
            guard case .unreadable = $0 as? CardWriteError else { return XCTFail("expected unreadable, got \($0)") }
        }
    }

    // MARK: sections (phase 3)

    private let review = "---\nid: A1\nproject: demo\nstatus: review\nagent: dev-a1\nbranch: feat/a1\n---\n# A1 · Title\n\n## Goal\nDo it.\n\n## Report\nDone.\n\n## Decision\n"

    func testFixNotesCreateTheSectionAndLaterRequestsAppendBelow() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir, review)
        try CardWriter().update(card, set: [.status: "needs-fix"], section: SectionEdit(.fixNotes, "- First: change X."), expectingStatus: .review)
        var after = try read(url)
        XCTAssertTrue(after.contains("\n## Fix notes\n\n- First: change X.\n"))
        XCTAssertTrue(after.contains("\nstatus: needs-fix\n"))
        // every original line is still there, in order, except the status line
        let kept = review.components(separatedBy: "\n").filter { !$0.hasPrefix("status:") && !$0.isEmpty }
        let now = after.components(separatedBy: "\n")
        var cursor = 0
        for line in kept { guard let at = now[cursor...].firstIndex(of: line) else { return XCTFail("lost line: \(line)") }; cursor = at + 1 }

        let second = try CardParser.parse(after, url: url)
        try CardWriter().update(second, set: [.status: "needs-fix"], section: SectionEdit(.fixNotes, "- Second: and Y."), expectingStatus: .needsFix)
        after = try read(url)
        let first = try XCTUnwrap(after.range(of: "- First: change X.")), next = try XCTUnwrap(after.range(of: "- Second: and Y."))
        XCTAssertLessThan(first.lowerBound, next.lowerBound)
        XCTAssertEqual(after.components(separatedBy: "## Fix notes").count, 2, "one section, not two")
    }

    func testFixNotesAppendBeforeTheNextHeading() throws {
        let dir = try TempDir()
        let text = review.replacingOccurrences(of: "## Decision\n", with: "## Fix notes\n\n- Old.\n\n## Decision\nkept\n")
        let (url, card) = try make(dir, text)
        try CardWriter().update(card, set: [:], section: SectionEdit(.fixNotes, "- New."), expectingStatus: .review)
        let after = try read(url)
        XCTAssertTrue(after.contains("## Fix notes\n\n- Old.\n\n- New.\n\n## Decision\nkept\n"), after)
    }

    func testDecisionReplacesOnlyItsSection() throws {
        let dir = try TempDir()
        let text = review + "approved long ago\n\n## Notes\nstay\n"
        let (url, card) = try make(dir, text)
        try CardWriter().update(card, set: [.status: "done"], section: SectionEdit(.decision, "Approved 2026-10-17, merged abc1234."), expectingStatus: .review)
        let after = try read(url)
        XCTAssertTrue(after.contains("## Decision\n\nApproved 2026-10-17, merged abc1234.\n\n## Notes\nstay\n"), after)
        XCTAssertFalse(after.contains("approved long ago"))
        XCTAssertTrue(after.contains("## Report\nDone.\n"))
    }

    func testDecisionAsLastSectionKeepsOneTrailingNewline() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir, review)
        try CardWriter().update(card, set: [.status: "done"], section: SectionEdit(.decision, "Approved."), expectingStatus: .review)
        XCTAssertTrue(try read(url).hasSuffix("## Decision\n\nApproved.\n"))
    }

    func testRefusedStatusWriteLeavesTheSectionUntouchedToo() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir, review)
        XCTAssertThrowsError(try CardWriter().update(card, set: [.status: "done"], section: SectionEdit(.decision, "x"), expectingStatus: .doing))
        XCTAssertEqual(try read(url), review)
    }

    func testSectionWriteRefusedWhenBodyChangedSinceRead() throws {
        let dir = try TempDir()
        let (url, card) = try make(dir, review)
        try review.replacingOccurrences(of: "Done.", with: "Done, and more.").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CardWriter().update(card, set: [.status: "needs-fix"], section: SectionEdit(.fixNotes, "- x"), expectingStatus: .review)) {
            guard case .conflict = $0 as? CardWriteError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(try read(url).contains("Fix notes"))
    }

    func testSectionWritePreservesCRLF() throws {
        let dir = try TempDir()
        let crlf = review.replacingOccurrences(of: "\n", with: "\r\n")
        let (url, card) = try make(dir, crlf)
        try CardWriter().update(card, set: [:], section: SectionEdit(.fixNotes, "- one\n- two"), expectingStatus: .review)
        let after = try read(url)
        XCTAssertFalse(after.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line ending stays CRLF")
        XCTAssertTrue(after.contains("## Fix notes\r\n\r\n- one\r\n- two\r\n"))
    }
}
