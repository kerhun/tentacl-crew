import XCTest
@testable import AgentPanel

final class TranscriptReaderTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var fixture: URL { root.appendingPathComponent("tests/fixtures/transcripts/session.jsonl") }

    /// N291: a file larger than the first window starts mid-file; Load earlier adds the 2 MB before it, no entry twice, in order.
    func testLoadEarlierReadsThePreviousWindowWithoutDuplicates() throws {
        let filler = String(repeating: "x", count: 1000)
        var text = ""
        for i in 0..<5000 { text += line(user: "m\(String(format: "%05d", i)) \(filler)") }   // ~5.3 MB
        let dir = try TempDir(); let file = try dir.write("big.jsonl", text)
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertTrue(reader.hasEarlier)
        let firstShown = try XCTUnwrap(reader.entries.first).text
        let before = reader.entries.count
        XCTAssertTrue(reader.loadEarlier())
        XCTAssertGreaterThan(reader.entries.count, before)
        let texts = reader.entries.map { String($0.text.prefix(6)) }
        XCTAssertEqual(Set(texts).count, texts.count, "no duplicates")
        XCTAssertEqual(texts, texts.sorted(), "older entries come first")
        XCTAssertTrue(reader.entries.contains { $0.text == firstShown })
        XCTAssertEqual(reader.entries.last?.text.prefix(6), "m04999")
        var loads = 0
        while reader.hasEarlier, loads < 10 { XCTAssertTrue(reader.loadEarlier()); loads += 1 }
        XCTAssertFalse(reader.hasEarlier, "the start of the file is reached")
        XCTAssertEqual(reader.entries.count, 5000)
        XCTAssertFalse(reader.loadEarlier())
    }

    func testFolderNameReplacesSlashesAndDots() {
        let url = TranscriptReader.path(projectsRoot: URL(fileURLWithPath: "/h/.claude/projects"), cwd: "/Users/me/repo/.agent-worktrees/task-n22", session: "abc")
        XCTAssertEqual(url.path, "/h/.claude/projects/-Users-me-repo--agent-worktrees-task-n22/abc.jsonl")
    }

    func testPromptsRepliesAndFoldedToolLinesInOrder() {
        var reader = TranscriptReader(url: fixture)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.kind), [.user, .agent, .user, .agent])
        XCTAssertEqual(reader.entries.map(\.text), [
            "Plan the next tasks", "I'll read the board first.\n\nHere is the plan:\n\n- A1 first\n- A2 after\n\n```\nswift build\n```", "Thanks, update both cards", "Done."])
        XCTAssertEqual(reader.entries[1].toolSummary, "ran 2 commands, read 1 file")
        XCTAssertEqual(reader.entries[1].tools.count, 3)
        XCTAssertEqual(reader.entries[3].toolSummary, "edited 2 files")
        XCTAssertNotNil(reader.entries[0].time)
    }

    /// N189: a message sent while the agent works is injected into the running turn as a `queued_command` attachment; no `user` line ever follows.
    func testAMessageSentMidTurnComesAsAUserLineOrPanelLine() {
        var reader = TranscriptReader(url: root.appendingPathComponent("tests/fixtures/transcripts/mid-turn.jsonl"))
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.kind), [.tools, .user, .panel], "the task notification and hooks are not messages")
        XCTAssertEqual(reader.entries.map(\.text), ["ran 1 command", "fix that line, then run the tests", "Panel: started N1."])
        XCTAssertEqual(reader.entries[1].id, "q1")
    }

    private func compactLine() -> String {
        #"{"type":"user","uuid":"c1","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}}"# + "\n"
    }
    private func toolLine(_ name: String, _ input: String) -> String {
        #"{"type":"assistant","uuid":"t\#(UUID().uuidString)","message":{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"\#(name)","input":\#(input)}]}}"# + "\n"
    }

    func testCompactionSummaryIsASummaryEntryNotAUserMessage() throws {
        let dir = try TempDir(); let file = try dir.write("s.jsonl", compactLine() + line(user: "go"))
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.kind), [.summary, .user])
        XCTAssertTrue(reader.entries[0].text.hasPrefix("This session is being continued"))
    }

    func testAuthorityKeyNoticeIsDropped() throws {
        let dir = try TempDir(); let file = try dir.write("s.jsonl", line(user: "Panel: new authority key abc123") + line(user: "Panel: started N1."))
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.text), ["Panel: started N1."])
    }

    func testTheAckOfAKeyNoticeIsDroppedToo() throws {
        let dir = try TempDir(); let file = try dir.write("s.jsonl", line(user: "Panel: new authority key abc") + toolLine("Bash", "{}") + line(assistant: "✓") + line(assistant: "real reply"))
        var reader = TranscriptReader(url: file)
        _ = reader.poll()
        XCTAssertEqual(reader.entries.map(\.text), ["real reply"])
        let file2 = try dir.write("t.jsonl", line(user: "Panel: new authority key abc") + line(assistant: "✓"))
        var r2 = TranscriptReader(url: file2)
        _ = r2.poll()
        XCTAssertTrue(r2.entries.isEmpty)
    }

    func testTextBlocksOfOneTurnJoinAndKeepTheToolList() throws {
        let dir = try TempDir(); let file = try dir.write("s.jsonl", line(user: "go") + line(assistant: "first") + toolLine("Bash", #"{"command":"git log --oneline -1"}"#) + line(assistant: "second") + toolLine("Read", #"{"file_path":"/d/pm-handoff.md"}"#))
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.kind), [.user, .agent])
        XCTAssertEqual(reader.entries[1].text, "first\n\nsecond")
        XCTAssertEqual(reader.entries[1].tools, ["Bash · git log --oneline -1", "Read · pm-handoff.md"])
        XCTAssertEqual(reader.entries[1].toolSummary, "ran 1 command, read 1 file")
        XCTAssertEqual(reader.entries[1].id, "afirst", "the id stays the first block's")
    }

    func testIncrementalReadsOnlyAddNewEntries() throws {
        let dir = try TempDir()
        let file = try dir.write("s.jsonl", line(user: "one"))
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertFalse(reader.poll(), "nothing new")
        try append(file, line(assistant: "two"))
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.text), ["one", "two"])
    }

    func testToolLineKeepsGrowingAcrossPolls() throws {
        let dir = try TempDir()
        let file = try dir.write("s.jsonl", line(tool: "Bash", input: "{}"))
        var reader = TranscriptReader(url: file)
        _ = reader.poll()
        XCTAssertEqual(reader.entries.map(\.text), ["ran 1 command"])
        try append(file, line(tool: "Bash", input: "{}"))
        _ = reader.poll()
        XCTAssertEqual(reader.entries.map(\.text), ["ran 2 commands"])
    }

    func testHalfWrittenLastLineWaitsForItsEnd() throws {
        let dir = try TempDir()
        let whole = line(assistant: "finished")
        let cut = whole.index(whole.startIndex, offsetBy: 30)
        let file = try dir.write("s.jsonl", line(user: "go") + String(whole[..<cut]))
        var reader = TranscriptReader(url: file)
        _ = reader.poll()
        XCTAssertEqual(reader.entries.map(\.text), ["go"])
        try append(file, String(whole[cut...]))
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.text), ["go", "finished"])
    }

    func testMissingFileGivesNoEntries() {
        var reader = TranscriptReader(url: URL(fileURLWithPath: "/nonexistent/none.jsonl"))
        XCTAssertFalse(reader.poll())
        XCTAssertTrue(reader.entries.isEmpty)
        XCTAssertFalse(reader.fileExists)
    }

    func testGarbageLineIsSkipped() throws {
        let dir = try TempDir()
        let file = try dir.write("s.jsonl", "not json\n" + line(user: "ok"))
        var reader = TranscriptReader(url: file)
        _ = reader.poll()
        XCTAssertEqual(reader.entries.map(\.text), ["ok"])
    }

    private func line(user text: String) -> String {
        #"{"type":"user","uuid":"u\#(text)","timestamp":"2026-01-05T10:00:00.000Z","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }
    private func line(assistant text: String) -> String {
        #"{"type":"assistant","uuid":"a\#(text)","timestamp":"2026-01-05T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
    }
    private func line(tool: String, input: String) -> String {
        #"{"type":"assistant","uuid":"t\#(UUID().uuidString)","message":{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"\#(tool)","input":\#(input)}]}}"# + "\n"
    }
    private func append(_ url: URL, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    func testImageLinesInsideTheAttachmentsFolderBecomeThumbnails() throws {
        let dir = try TempDir()
        let att = URL(fileURLWithPath: "/att")
        let text = "see this\n[Image: /att/demo/a.png]\n[Image: /att/demo/b.png]\n[Image: /elsewhere/c.png]"
        let file = try dir.write("s.jsonl", line(user: text.replacingOccurrences(of: "\n", with: "\\n")))
        var reader = TranscriptReader(url: file, attachmentsRoot: att)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries[0].images, [.file("/att/demo/a.png"), .file("/att/demo/b.png")])
        XCTAssertEqual(reader.entries[0].text, "see this\n[Image: /elsewhere/c.png]", "a path outside the panel's folder stays text")
    }

    func testFileAndFolderLinesBecomeChips() throws {
        let dir = try TempDir()
        let text = "check these\n[Image: /att/demo/a.png]\n[File: /att/demo/x1/plan.md]\n[File: /Users/me/dump.bin]\n[Folder: /Users/me/design]\n[File: relative.txt]"
        let file = try dir.write("s.jsonl", line(user: text.replacingOccurrences(of: "\n", with: "\\n")))
        var reader = TranscriptReader(url: file, attachmentsRoot: URL(fileURLWithPath: "/att"))
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries[0].images, [.file("/att/demo/a.png")])
        XCTAssertEqual(reader.entries[0].files, [ChatFile(path: "/att/demo/x1/plan.md", folder: false, copied: true),
                                                 ChatFile(path: "/Users/me/dump.bin", folder: false, copied: false),
                                                 ChatFile(path: "/Users/me/design", folder: true, copied: false)])
        XCTAssertEqual(reader.entries[0].text, "check these\n[File: relative.txt]", "only absolute paths become chips")
        XCTAssertEqual(reader.entries[0].files.map(\.name), ["plan.md", "dump.bin", "design"])
    }

    func testMessageOfOnlyAFolderStillShows() throws {
        let dir = try TempDir()
        let file = try dir.write("s.jsonl", line(user: "[Folder: /Users/me/design]"))
        var reader = TranscriptReader(url: file, attachmentsRoot: URL(fileURLWithPath: "/att"))
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries[0].text, "")
        XCTAssertEqual(reader.entries[0].files.count, 1)
    }

    func testMessageOfOnlyAnImageStillShows() throws {
        let dir = try TempDir()
        let file = try dir.write("s.jsonl", line(user: "[Image: /att/p/a.png]"))
        var reader = TranscriptReader(url: file, attachmentsRoot: URL(fileURLWithPath: "/att"))
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries[0].text, "")
        XCTAssertEqual(reader.entries[0].images, [.file("/att/p/a.png")])
    }

    func testClaudeImageContentBlockBecomesInlineImage() throws {
        let dir = try TempDir()
        let b64 = Data([1, 2, 3]).base64EncodedString()
        let l = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"[Image #1]"},{"type":"text","text":"what is this"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(b64)"}}]}}"# + "\n"
        let file = try dir.write("s.jsonl", l)
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries[0].text, "what is this")
        XCTAssertEqual(reader.entries[0].images, [.inline(Data([1, 2, 3]))])
    }

    func testThePanelsOwnMessagesAreAKindOfTheirOwn() throws {
        let dir = try TempDir()
        let panel = ["Panel: started N1, N2.", "Your task card: /w/tasks/N1.md (read it fully, then do the task).",
                     "Fix request for your task card /w/tasks/N1.md: read the newest entry", "Please write a short hand-off note to /d/pm-handoff.md so a fresh conversation can take over.",
                     "Read /d/pm-handoff.md and your project's roadmap, then continue as the PM.",
                     "Your worktree has uncommitted work, so the review cannot be prepared. Commit it.",
                     "Skip this question and carry on with your best judgment. Say in your report which assumption you made."]
        let file = try dir.write("s.jsonl", (panel + ["Panel looks fine", "Read the card please"]).map { line(user: $0) }.joined())
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.kind), Array(repeating: .panel, count: panel.count) + [.user, .user])
    }

    // MARK: N270 pasted_content

    private func json(_ obj: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self) + "\n" }
    private func userJSON(_ id: String, _ content: Any) throws -> String { try json(["type": "user", "uuid": id, "message": ["role": "user", "content": content]]) }
    private func wrap(_ text: String, id: String = "abc-1") -> String { "<pasted_content id=\"\(id)\">\(text)</pasted_content id=\"\(id)\">" }

    func testPastedContentUnwrapsOneBlockTwoBlocksTextAroundAndNone() {
        XCTAssertEqual(PastedContent.unwrap(wrap("line1\nline2")), "line1\nline2")
        XCTAssertEqual(PastedContent.unwrap(wrap("A", id: "x") + "\n" + wrap("B", id: "y")), "A\nB")
        XCTAssertEqual(PastedContent.unwrap("before " + wrap("mid") + " after"), "before mid after")
        XCTAssertEqual(PastedContent.unwrap("plain text with <b> tags"), "plain text with <b> tags")
        XCTAssertEqual(PastedContent.unwrap("<pasted_content id=\"z\">x</pasted_content>"), "x", "a plain closing tag works too")
    }

    func testAWrappedLongMessageShowsWithoutTagsAndKeepsImages() throws {
        let dir = try TempDir()
        let long = (1...400).map { "line \($0) of a long pasted log" }.joined(separator: "\n")
        let file = try dir.write("s.jsonl", try userJSON("u1", wrap(long)) + (try userJSON("u2", "look " + wrap("one", id: "p") + "\n[Image: /att/p/a.png]")))
        var reader = TranscriptReader(url: file, attachmentsRoot: URL(fileURLWithPath: "/att"))
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries[0].text, long)
        XCTAssertEqual(reader.entries[1].text, "look one")
        XCTAssertEqual(reader.entries[1].images, [.file("/att/p/a.png")])
        XCTAssertFalse(reader.entries.contains { $0.text.contains("pasted_content") })
    }

    func testAWrappedMessageSentMidTurnComesWithoutTags() throws {
        let dir = try TempDir()
        let l = try json(["type": "attachment", "uuid": "q1", "attachment": ["type": "queued_command", "commandMode": "prompt", "prompt": wrap("queued paste")]])
        let file = try dir.write("s.jsonl", l)
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.text), ["queued paste"])
    }

    func testAWrappedPanelMessageStaysAPanelLine() throws {
        let dir = try TempDir()
        let file = try dir.write("s.jsonl", try userJSON("u1", wrap("Panel: started N1.")))
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.kind), [.panel])
    }

    func testCodexKeepsALongUserMessageWhole() throws {
        let dir = try TempDir()
        let long = (1...400).map { "row \($0)" }.joined(separator: "\n")
        let l = try json(["type": "response_item", "payload": ["type": "message", "role": "user", "id": "m1", "content": [["type": "input_text", "text": long]]]])
        let file = try dir.write("rollout-1.jsonl", l)
        var reader = CodexSessionReader(url: file)
        XCTAssertTrue(reader.poll())
        XCTAssertEqual(reader.entries.map(\.text), [long])
    }
}
