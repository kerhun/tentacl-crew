import XCTest
import AppKit
@testable import AgentPanel

@MainActor
final class ChatModelTests: XCTestCase {
    private var dir: TempDir!
    private var root: URL { dir.url }

    override func setUpWithError() throws { dir = try TempDir() }

    private func agent(_ pane: String, session: String?, cwd: String = "/work/demo", state: AgentState = .idle) -> AgentStatus {
        AgentStatus(paneID: pane, workspaceID: "w", state: state, cwd: cwd, title: "PM", sessionID: session)
    }
    private func file(_ session: String, cwd: String = "/work/demo") -> URL {
        TranscriptReader.path(projectsRoot: root, cwd: cwd, session: session)
    }
    private func write(_ session: String, _ lines: String...) throws {
        try dir.write(file(session).path.replacingOccurrences(of: root.path + "/", with: ""), lines.joined())
    }
    private func user(_ t: String) -> String { #"{"type":"user","uuid":"u\#(t)","message":{"role":"user","content":"\#(t)"}}"# + "\n" }
    private func reply(_ t: String) -> String { #"{"type":"assistant","uuid":"a\#(t)","message":{"role":"assistant","content":[{"type":"text","text":"\#(t)"}]}}"# + "\n" }
    private func append(_ session: String, _ text: String) throws {
        let h = try FileHandle(forWritingTo: file(session))
        defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8))
    }

    func testNoSessionFileSaysNoConversationYet() async {
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertTrue(m.entries.isEmpty)
        XCTAssertFalse(m.hasConversation)
    }

    func testSwitchingAgentsShowsThatAgentsThread() async throws {
        try write("s1", user("to pm"), reply("pm here"))
        try write("s2", user("to dev"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertEqual(m.entries.map(\.text), ["to pm", "pm here"])
        await m.refresh(agent: agent("p2", session: "s2"), viewing: true)
        XCTAssertEqual(m.entries.map(\.text), ["to dev"])
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertEqual(m.entries.map(\.text), ["to pm", "pm here"])
        XCTAssertFalse(m.unread, "switching is not a new reply")
    }

    /// N131: the file is read off the main thread, so a read for an agent that is no longer chosen must not overwrite the new thread.
    func testAReadThatFinishesAfterSwitchingAgentsIsDropped() async throws {
        try write("s1", user("to pm"), reply("pm here"))
        try write("s2", user("to dev"))
        let m = ChatModel(projectsRoot: root)
        let first = Task { await m.refresh(agent: agent("p1", session: "s1"), viewing: true) }
        await Task.yield()   // the first read is running off the main thread
        await m.refresh(agent: agent("p2", session: "s2"), viewing: true)
        await first.value
        XCTAssertEqual(m.entries.map(\.text), ["to dev"])
    }

    func testAgentWithoutSessionHasNoThread() async throws {
        try write("s1", user("x"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        await m.refresh(agent: agent("p9", session: nil), viewing: true)
        XCTAssertTrue(m.entries.isEmpty)
        await m.refresh(agent: nil, viewing: true)
        XCTAssertTrue(m.entries.isEmpty)
    }

    func testReplyWhileAwayMarksUnreadAndSeeingClearsIt() async throws {
        try write("s1", user("hi"), reply("old"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: false)
        XCTAssertFalse(m.unread, "history that was already there is not new")
        try append("s1", user("more") + reply("new"))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: false)
        XCTAssertTrue(m.unread)
        m.markSeen()
        XCTAssertFalse(m.unread)
    }

    func testTextAddedToTheSameTurnWhileAwayIsUnread() async throws {
        try write("s1", user("hi"), reply("old"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: false)
        try append("s1", reply("more"))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: false)
        XCTAssertTrue(m.unread)
    }

    func testReplyWhileLookingIsNotUnread() async throws {
        try write("s1", user("hi"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        try append("s1", reply("new"))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertFalse(m.unread)
    }

    func testToolLinesAndPromptsNeverMarkUnread() async throws {
        try write("s1", reply("a"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: false)
        try append("s1", user("question"))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: false)
        XCTAssertFalse(m.unread)
    }

    func testReplyInProgressFollowsTheAgentState() async throws {
        try write("s1", user("hi"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        XCTAssertTrue(m.working)
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true)
        XCTAssertFalse(m.working)
    }

    // MARK: queued messages

    func testASentMessageShowsAtOnceAndLosesItsMarkWhenDelivered() async throws {
        try write("s1", user("old"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        m.addPending("do it  \n", kind: .user)
        XCTAssertEqual(m.entries.map(\.text), ["old", "do it"])
        XCTAssertEqual(m.entries.last?.pending, .queued)
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        XCTAssertEqual(m.entries.last?.pending, .queued, "still waiting while the transcript has nothing new")
        try append("s1", user("do it") + reply("done"))
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true)
        XCTAssertEqual(m.entries.map(\.text), ["old", "do it", "done"], "never shown twice")
        XCTAssertTrue(m.entries.allSatisfy { $0.pending == nil })
    }

    func testAnOlderIdenticalMessageDoesNotDeliverTheQueuedOne() async throws {
        try write("s1", user("again"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        m.addPending("again", kind: .user)
        m.addPending("again", kind: .user)
        XCTAssertEqual(m.entries.map(\.pending), [nil, .queued, .queued])
        try append("s1", #"{"type":"user","uuid":"u2","message":{"role":"user","content":"again"}}"# + "\n")
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertEqual(m.entries.map(\.pending), [nil, nil, .queued], "one transcript line delivers one queued copy")
    }

    /// N270: Claude Code stores a long paste wrapped in `<pasted_content>`; the pending copy must still match and no second copy stays.
    func testAWrappedDeliveryReplacesThePendingLongMessage() async throws {
        let long = (1...300).map { "line \($0)" }.joined(separator: "\\n")
        let wrapped = "<pasted_content id=\\\"a1\\\">\(long)</pasted_content id=\\\"a1\\\">"
        try write("s1", user("old"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true)
        m.addPending(long.replacingOccurrences(of: "\\n", with: "\n"), kind: .user)
        XCTAssertEqual(m.entries.last?.pending, .queued)
        try append("s1", user(wrapped))
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        XCTAssertEqual(m.entries.count, 2, "one copy only")
        XCTAssertNil(m.entries.last?.pending)
        XCTAssertFalse(m.entries.contains { $0.text.contains("pasted_content") })
    }

    func testAWrappedDeliveryAlsoReplacesAFailedLongMessage() async throws {
        try write("s1", user("old"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true)
        let id = m.addPending("a\nb", kind: .user)
        m.markFailed(id, reason: "gone")
        XCTAssertEqual(m.entries.last?.pending, .failed("gone"), "a real failure keeps its reason")
        try append("s1", user("<pasted_content id=\\\"b\\\">a\\nb</pasted_content id=\\\"b\\\">"))
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true)
        XCTAssertEqual(m.entries.map(\.text), ["old", "a\nb"])
    }

    func testAFailedSendShowsTheReasonInsteadOfTheMark() async throws {
        let m = ChatModel(projectsRoot: root)
        let id = m.addPending("hello", kind: .user)
        m.markFailed(id, reason: "agent is no longer running")
        XCTAssertEqual(m.entries.last?.pending, .failed("agent is no longer running"))
        try write("s1", user("hello"))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertEqual(m.entries.map(\.pending), [nil], "a failed copy that arrived anyway is matched away (N189)")
    }

    func testAQueuedPanelMessageMatchesThePanelLine() async throws {
        try write("s1", user("hi"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        m.addPending("Panel: started N1.", kind: .panel)
        XCTAssertEqual(m.entries.last?.kind, .panel)
        try append("s1", user("Panel: started N1."))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertEqual(m.entries.map(\.kind), [.user, .panel])
        XCTAssertNil(m.entries.last?.pending)
    }

    // MARK: N189 · a sent message never stays stuck

    private func queuedCommand(_ t: String, uuid: String = "q1") -> String {
        #"{"type":"attachment","uuid":"\#(uuid)","attachment":{"type":"queued_command","prompt":"\#(t)","commandMode":"prompt","origin":{"kind":"human"}}}"# + "\n"
    }

    func testAMessageInjectedMidTurnReplacesItsQueuedCopy() async throws {
        try write("s1", user("old"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        m.addPending("fix it", kind: .user)
        try append("s1", queuedCommand("fix it"))
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        XCTAssertEqual(m.entries.map(\.text), ["old", "fix it"], "exactly one copy")
        XCTAssertNil(m.entries.last?.pending)
    }

    func testAFailedMessageThatArrivedAnywayIsReplacedByItsLine() async throws {
        try write("s1", user("old"))
        let m = ChatModel(projectsRoot: root)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        let id = m.addPending("hello", kind: .user)
        m.markFailed(id, reason: "timed out")
        try append("s1", user("hello"))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true)
        XCTAssertEqual(m.entries.map(\.text), ["old", "hello"])
        XCTAssertNil(m.entries.last?.pending)
    }

    func testTheSameTextSentTwiceShowsTwoCopiesThenOneEach() async throws {
        let m = ChatModel(projectsRoot: root)
        try write("s1", user("old"))
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        m.addPending("go", kind: .user)
        m.addPending("go", kind: .user)
        try append("s1", queuedCommand("go", uuid: "q1"))
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        XCTAssertEqual(m.entries.map(\.pending), [nil, nil, .queued])
        try append("s1", user("go"))
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true)
        XCTAssertEqual(m.entries.map(\.pending), [nil, nil, nil])
    }

    func testAnUnmatchedMessageBecomesNotSeenOnlyAfterTheAgentIsIdleForTwoMinutes() async throws {
        try write("s1", user("old"))
        let m = ChatModel(projectsRoot: root)
        let t0 = Date()
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true, now: t0)
        m.addPending("lost", kind: .user)
        await m.refresh(agent: agent("p1", session: "s1", state: .working), viewing: true, now: t0 + 3_600)
        XCTAssertEqual(m.entries.last?.pending, .queued, "never while the agent is working")
        let idle = t0 + 3_600
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true, now: idle)
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true, now: idle + ChatModel.notSeenAfter - 1)
        XCTAssertEqual(m.entries.last?.pending, .queued)
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true, now: idle + ChatModel.notSeenAfter)
        XCTAssertEqual(m.entries.last?.pending, .notSeen)
        XCTAssertEqual(m.entries.last?.text, "lost", "nothing is re-sent or dropped by itself")
    }

    func testANotSeenMessageStillMatchesALateLine() async throws {
        try write("s1", user("old"))
        let m = ChatModel(projectsRoot: root)
        let t0 = Date()
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true, now: t0)
        m.addPending("late", kind: .user)
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true, now: t0 + 300)
        XCTAssertEqual(m.entries.last?.pending, .notSeen)
        try append("s1", user("late"))
        await m.refresh(agent: agent("p1", session: "s1"), viewing: true, now: t0 + 301)
        XCTAssertEqual(m.entries.map(\.text), ["old", "late"])
        XCTAssertNil(m.entries.last?.pending)
    }

    func testRemoveDropsAPendingMessageOfAnyState() async throws {
        let m = ChatModel(projectsRoot: root)
        let a = m.addPending("a", kind: .user)
        let b = m.addPending("b", kind: .user)
        m.markFailed(b, reason: "x")
        m.remove(a); m.remove(b)
        XCTAssertTrue(m.entries.isEmpty)
    }

    func testRetryTakesTheMessageOutAndReturnsItToBeSentAgain() async throws {
        let m = ChatModel(projectsRoot: root)
        let img = ChatImage.file("/a/b.png")
        let id = m.addPending("again", kind: .user, images: [img])
        m.markFailed(id, reason: "x")
        let entry = try XCTUnwrap(m.retry(id))
        XCTAssertEqual(entry.text, "again")
        XCTAssertEqual(entry.images, [img])
        XCTAssertTrue(m.entries.isEmpty, "the caller's new send draws a fresh queued copy")
        XCTAssertNil(m.retry(id))
    }

    func testPendingStaysAcrossASessionChangeAndTimesOut() async throws {
        try write("s1", user("old")); try write("s2", user("new"))
        let m = ChatModel(projectsRoot: root)
        let t0 = Date()
        await m.refresh(agent: agent("p1", session: "s1", state: .idle), viewing: true, now: t0)
        m.addPending("in the old file", kind: .user)
        await m.refresh(agent: agent("p1", session: "s2", state: .idle), viewing: true, now: t0 + 1)
        XCTAssertEqual(m.entries.map(\.text), ["new", "in the old file"])
        await m.refresh(agent: agent("p1", session: "s2", state: .idle), viewing: true, now: t0 + 200)
        XCTAssertEqual(m.entries.last?.pending, .notSeen)
    }

    // MARK: reply text

    func testPreviewCutsLongRepliesToAFewLines() {
        let long = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let p = ChatText.preview(long, maxLines: 5)
        XCTAssertTrue(p.cut)
        XCTAssertEqual(p.text.split(separator: "\n").count, 5)
        XCTAssertFalse(ChatText.preview("short", maxLines: 5).cut)
    }

    func testBlocksRecogniseHeadingsListsCodeAndTables() {
        let blocks = ChatText.blocks("# Title\n\ntext **bold**\n\n- one\n- two\n\n```\ncode\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph, .bullet, .bullet, .code, .table])
        XCTAssertEqual(blocks[4].text, "code")
        XCTAssertEqual(blocks[2].text, "one")
    }

    func testATableDirectlyAfterAParagraphIsItsOwnBlock() {
        let blocks = ChatText.blocks("The files:\n| a | b |\n|---|---|\n| 1 | 2 |\nAfter.")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .table, .paragraph])
        XCTAssertEqual(blocks[1].text, "| a | b |\n|---|---|\n| 1 | 2 |")
    }

    func testPipeLinesWithoutAnAlignmentRowAreCodeNotATable() {
        XCTAssertEqual(ChatText.blocks("| a | b |\n| 1 | 2 |").map(\.kind), [.code])
    }

    func testATableInsideACodeFenceStaysCode() {
        let blocks = ChatText.blocks("```\n| a | b |\n|---|---|\n```")
        XCTAssertEqual(blocks.map(\.kind), [.code])
        XCTAssertEqual(blocks[0].text, "| a | b |\n|---|---|")
    }

    func testBoxDrawingLinesOutsideAFenceBecomeOneCodeBlock() {
        let diagram = "┌─────┐     ┌─────┐\n│ PM  │ ──► │ Dev │\n└──┬──┘     └─────┘\n   ▼\n┌─────┐\n└─────┘"
        let blocks = ChatText.blocks("The flow:\n\(diagram)\nThat is all.")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code, .paragraph])
        XCTAssertEqual(blocks[0].text, "The flow:")
        XCTAssertEqual(blocks[1].text, diagram)
        XCTAssertEqual(blocks[2].text, "That is all.")
    }

    func testArrowsInProseStayProse() {
        XCTAssertEqual(ChatText.blocks("A → B, then ▼ C.").map(\.kind), [.paragraph])
    }

    func testBlockOrderIsUnchangedAroundTablesAndDiagrams() {
        let text = "# T\n\nintro\n\n| a |\n|:-:|\n| 1 |\n\n- item\n\n╔═╗\n║x║\n╚═╝\n\n```swift\nlet x = 1\n```\n\nend"
        XCTAssertEqual(ChatText.blocks(text).map(\.kind), [.heading, .paragraph, .table, .bullet, .code, .code, .paragraph])
    }

    // N288: nested and numbered lists, the fence's language.
    func testNestedBulletsKeepTheirLevel() {
        let blocks = ChatText.blocks("- a\n  - b\n    - c\n  - d\n- e\n\t- f")
        XCTAssertEqual(blocks.map(\.kind), Array(repeating: .bullet, count: 6))
        XCTAssertEqual(blocks.map(\.level), [0, 1, 2, 1, 0, 1])
        XCTAssertEqual(blocks.map(\.text), ["a", "b", "c", "d", "e", "f"])
    }

    func testFourSpaceIndentIsOneLevelAndLevelsStopAtTwo() {
        XCTAssertEqual(ChatText.blocks("- a\n    - b\n        - c\n          - d").map(\.level), [0, 1, 2, 2])
    }

    func testNumberedListsKeepTheirNumber() {
        let blocks = ChatText.blocks("1. x\n2) y\n   - z")
        XCTAssertEqual(blocks.map(\.kind), [.numbered, .numbered, .bullet])
        XCTAssertEqual(blocks.map(\.number), [1, 2, nil])
        XCTAssertEqual(blocks.map(\.text), ["x", "y", "z"])
        XCTAssertEqual(blocks.map(\.level), [0, 0, 1])
    }

    func testFencedCodeKeepsItsLanguage() {
        let blocks = ChatText.blocks("Run:\n```shell\nrequest-start.sh N287\n```\n```\nplain\n```")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code, .code])
        XCTAssertEqual(blocks[1].language, "shell")
        XCTAssertEqual(blocks[1].text, "request-start.sh N287")
        XCTAssertNil(blocks[2].language)
    }
}

@MainActor
final class CommandBoxSnapshotTests: XCTestCase {
    func testCommandBoxWithShortThreadRenders() async throws {
        let dir = try TempDir()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("tests/fixtures/transcripts/session.jsonl")
        let target = TranscriptReader.path(projectsRoot: dir.url, cwd: "/work/demo", session: "s1")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        let model = await DemoSupport.makeModel()
        let chat = model.chats.session(project: model.selectedProjectID ?? "", pane: "", projectsRoot: dir.url).chat
        await chat.refresh(agent: AgentStatus(paneID: "p1", workspaceID: "w", state: .working, cwd: "/work/demo", title: "PM", sessionID: "s1"), viewing: true)
        XCTAssertEqual(chat.entries.count, 4, "N287: one PM turn is one entry")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: CommandBar(model: model), size: CGSize(width: 340, height: 520)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("command-box.png")) }
    }

    func testCommandBoxWithTwoThumbnailsRenders() async throws {
        let store = Attachments(root: try TempDir().url)
        func swatch(_ color: NSColor) throws -> Data {
            let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in color.setFill(); rect.fill(); return true }
            return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        }
        let images = [try store.pending(pasted: try swatch(.systemTeal)), try store.pending(pasted: try swatch(.systemOrange))]
        let model = await DemoSupport.makeModel()
        model.chats.session(project: model.selectedProjectID ?? "", pane: "").images = images
        let data = try XCTUnwrap(SnapshotRenderer.render(view: CommandBar(model: model), size: CGSize(width: 340, height: 520)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("command-box-images.png")) }
    }

    func testThreadWithUserPanelAndQueuedMessagesRenders() throws {
        let entries = [
            ChatEntry(id: "1", kind: .user, text: "Start N4 and N5, please.", time: nil),
            ChatEntry(id: "2", kind: .agent, text: "Asking the panel to start them.", time: nil),
            ChatEntry(id: "3", kind: .panel, text: "Panel: started N4, N5.", time: nil),
            ChatEntry(id: "4", kind: .user, text: "Also look at N6 when you can.", time: nil, pending: .queued),
            ChatEntry(id: "5", kind: .panel, text: "Panel: N4 is ready for review.", time: nil, pending: .queued),
            ChatEntry(id: "6", kind: .user, text: "And N7.", time: nil, pending: .failed("That agent is no longer running; pick another one.")),
            ChatEntry(id: "7", kind: .user, text: "Is N8 still going?", time: nil, pending: .notSeen),
            ChatEntry(id: "8", kind: .panel, text: "Panel: N8 is done.", time: nil, pending: .notSeen),
        ]
        let view = ChatThread(place: ChatPlace(), entries: entries, agentLabel: "PM", working: true, onRetry: { _ in }).environment(\.snapshotMode, true).padding(12).background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 340, height: 640)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("chat-panel-queued.png")) }
    }

    func testThreadWithAPastedMessageDeliveredRenders() throws {
        let dir = try TempDir()
        let long = (1...40).map { "line \($0) of the pasted log" }.joined(separator: "\n")
        let wrapped = "<pasted_content id=\"a1\">\(long)</pasted_content id=\"a1\">"
        let l = try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "u1", "message": ["role": "user", "content": wrapped]])
        let file = try dir.write("s.jsonl", String(decoding: l, as: UTF8.self) + "\n")
        var reader = TranscriptReader(url: file)
        XCTAssertTrue(reader.poll())
        let entries = reader.entries + [ChatEntry(id: "2", kind: .agent, text: "Got the log.", time: nil)]
        XCTAssertFalse(entries.contains { $0.text.contains("pasted_content") })
        let view = ChatThread(place: ChatPlace(), entries: entries, agentLabel: "PM", working: false, onRetry: { _ in }).environment(\.snapshotMode, true).padding(12).background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 340, height: 480)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N270-chat.png")) }
    }

    func testImagePasteIsTakenOnlyInTheCommandBox() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let command = NSTextField(), other = NSTextField()
        window.contentView?.addSubview(command); window.contentView?.addSubview(other)
        command.setAccessibilityIdentifier(CommandBar.inputIdentifier)
        // The window shares one field editor; its delegate is whichever field is being edited.
        command.isEditable = true; other.isEditable = true
        XCTAssertTrue(window.makeFirstResponder(command))
        let editor = try! XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(CommandBar.takesImagePaste(responder: editor, hasImage: true))
        XCTAssertFalse(CommandBar.takesImagePaste(responder: editor, hasImage: false))
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertFalse(CommandBar.takesImagePaste(responder: editor, hasImage: true))
        XCTAssertFalse(CommandBar.takesImagePaste(responder: NSTextView(), hasImage: true))
        XCTAssertFalse(CommandBar.takesImagePaste(responder: nil, hasImage: true))
    }
}

@MainActor
final class ChatDraftsTests: XCTestCase {
    func testEachProjectAndTargetKeepsItsOwnDraftAcrossLookups() {
        let store = ChatStore()
        store.session(project: "a", pane: "p1").text = "for p1"
        store.session(project: "a", pane: "p2").text = "for p2"
        store.session(project: "b", pane: "p1").text = "other project"
        XCTAssertEqual(store.session(project: "a", pane: "p1").text, "for p1")
        XCTAssertEqual(store.session(project: "a", pane: "p2").text, "for p2")
        XCTAssertEqual(store.session(project: "b", pane: "p1").text, "other project")
        XCTAssertTrue(store.session(project: "a", pane: "p1") === store.session(project: "a", pane: "p1"), "the thread is the same object, not reloaded")
    }

    func testTheDraftSurvivesTheModelBeingAskedAgainAfterSwitchingProject() async {
        let model = await DemoSupport.makeModel()
        model.chats.session(project: "demo", pane: "p1").text = "half a thought"
        await model.selectProject("other")
        await model.selectProject("demo")
        XCTAssertEqual(model.chats.session(project: "demo", pane: "p1").text, "half a thought")
    }

    func testSendingClearsOnlyThatDraft() {
        let store = ChatStore()
        store.session(project: "a", pane: "p1").text = "one"
        store.session(project: "a", pane: "p2").text = "two"
        store.session(project: "a", pane: "p1").clearDraft()
        XCTAssertEqual(store.session(project: "a", pane: "p1").text, "")
        XCTAssertTrue(store.session(project: "a", pane: "p1").images.isEmpty)
        XCTAssertEqual(store.session(project: "a", pane: "p2").text, "two")
    }

    func testUnreadIsPerProject() {
        let store = ChatStore()
        XCTAssertFalse(store.unread(project: "a"))
        store.session(project: "a", pane: "p1").chat.setUnreadForTest(true)
        XCTAssertTrue(store.unread(project: "a"))
        XCTAssertFalse(store.unread(project: "b"))
        store.markSeen(project: "a")
        XCTAssertFalse(store.unread(project: "a"))
    }
}
