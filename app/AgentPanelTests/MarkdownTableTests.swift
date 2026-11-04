import XCTest
import SwiftUI
@testable import AgentPanel

final class MarkdownTableTests: XCTestCase {
    func testHeaderAlignmentAndRows() throws {
        let t = try XCTUnwrap(MarkdownTable.parse("| Name | Count | Note |\n|:---|:---:|---:|\n| a | 1 | x |\n| b | 2 | y |"))
        XCTAssertEqual(t.header, ["Name", "Count", "Note"])
        XCTAssertEqual(t.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(t.rows, [["a", "1", "x"], ["b", "2", "y"]])
    }

    func testPlainDashesAlignLeading() throws {
        let t = try XCTUnwrap(MarkdownTable.parse("| a | b |\n|---|-|\n| 1 | 2 |"))
        XCTAssertEqual(t.alignments, [.leading, .leading])
    }

    func testEscapedPipesStayInTheCell() throws {
        let t = try XCTUnwrap(MarkdownTable.parse("| expr | means |\n|---|---|\n| `a \\| b` | a or b |"))
        XCTAssertEqual(t.rows, [["`a | b`", "a or b"]])
    }

    func testMissingCellsAreEmptyAndExtraCellsAreKept() throws {
        let t = try XCTUnwrap(MarkdownTable.parse("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |"))
        XCTAssertEqual(t.columns, 4)
        XCTAssertEqual(t.header, ["a", "b", "c", ""])
        XCTAssertEqual(t.rows, [["1", "", "", ""], ["1", "2", "3", "4"]])
        XCTAssertEqual(t.alignments.count, 4)
    }

    func testOuterPipesAreOptionalOnTheRightAndCellsAreTrimmed() throws {
        let t = try XCTUnwrap(MarkdownTable.parse("|  a|b  \n|---|---\n|1 |  2"))
        XCTAssertEqual(t.header, ["a", "b"])
        XCTAssertEqual(t.rows, [["1", "2"]])
    }

    func testNoAlignmentRowIsNotATable() {
        XCTAssertNil(MarkdownTable.parse("| a | b |\n| 1 | 2 |"))
        XCTAssertNil(MarkdownTable.parse("| a | b |"))
        XCTAssertNil(MarkdownTable.parse("| a | b |\n|---|x--|"))
    }

    func testTableBoxHasNoCopy() {
        XCTAssertNil(MarkdownTableView.copyHelp)
    }

    /// N193: without the Copy line the table box is exactly as tall as the table; a box with copyHelp adds its Copy line.
    @MainActor
    func testTableBoxStartsWithTheTable() throws {
        let table = try XCTUnwrap(MarkdownTable.parse("| a | b |\n|---|---|\n| 1 | 2 |"))
        let plain = NSHostingView(rootView: MarkdownBlockBox(source: "", copyHelp: nil) { Text("x").font(Tok.Font.mono).padding(Tok.Space.s) }).fittingSize
        let copied = NSHostingView(rootView: MarkdownBlockBox(source: "", copyHelp: "c") { Text("x").font(Tok.Font.mono).padding(Tok.Space.s) }).fittingSize
        let grid = NSHostingView(rootView: MarkdownTableView(table: table, source: "")).fittingSize
        XCTAssertGreaterThan(copied.height, plain.height + 8, "the Copy line takes room")
        XCTAssertLessThan(grid.height, 3 * 30, "two rows, no Copy line above")
    }

    func testBoxDrawingDetection() {
        XCTAssertTrue(ChatText.isBoxLine("│ PM │"))
        XCTAssertTrue(ChatText.isBoxLine("╚═══╝"))
        XCTAssertFalse(ChatText.isBoxLine("A → B"))
        XCTAssertFalse(ChatText.isBoxLine("plain text"))
    }
}

/// Snapshots for N191 (N193: tables without Copy): a chat reply with a table and a box diagram, and the Card tab of a card with a table.
@MainActor
final class MarkdownTableSnapshotTests: XCTestCase {
    static let table = """
    | Prefix | Files | Made by |
    |---|---:|---|
    | `agent-panel-tests-<uuid>` | 20,207 | `makeTestDefaults` before N186, which made a fresh suite for every test and never removed it |
    | `notes-pad-tests-<uuid>` | 290 | **NotesPadTests**.swift:9 |
    | `stats-range-<uuid>` | 219 | |
    """
    static let diagram = """
    ```
    ┌──────────┐   start   ┌──────────────┐   review   ┌──────────┐
    │    PM    │ ────────► │  ui_dev N191 │ ─────────► │ reviewer │
    └──────────┘           └──────────────┘            └──────────┘
    ```
    """
    static let bare = """
    ┌────────┐     ┌────────┐     ┌──────────────────────┐
    │ blocks │ ──► │ parser │ ──► │ Grid in a scroll box │
    └────────┘     └────────┘     └──────────────────────┘
    """

    private func write(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    func testChatReplyWithTableAndDiagramRenders() throws {
        let entries = [
            ChatEntry(id: "1", kind: .user, text: "Where do the leftover files come from?", time: nil),
            ChatEntry(id: "2", kind: .agent, text: "Counted them:\n" + Self.table, time: nil),
            ChatEntry(id: "3", kind: .agent, text: "The flow:\n" + Self.diagram, time: nil),
            ChatEntry(id: "4", kind: .agent, text: Self.bare, time: nil),
        ]
        let view = ChatThread(place: ChatPlace(), entries: entries, agentLabel: "PM", working: false).environment(\.snapshotMode, true).padding(12).background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 420, height: 560)))
        XCTAssertGreaterThan(data.count, 8_000)
        try write(data, "N191-chat.png")
        try write(data, "N193-table.png")
    }

    /// The real (scrolling) path: the sideways scroll boxes are as tall as their content, not stretched or collapsed.
    func testLiveScrollBoxesHugTheirContent() throws {
        let text = "Before.\n\n" + Self.table + "\n\n" + Self.bare + "\n\nAfter."
        let host = NSHostingView(rootView: MarkdownText(text: text).padding(12).frame(width: 420).background(Tok.pane))
        let size = host.fittingSize
        XCTAssertGreaterThan(size.height, 180, "the table and the diagram are drawn")
        XCTAssertLessThan(size.height, 420, "the scroll boxes do not stretch")
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try write(try XCTUnwrap(rep.representation(using: .png, properties: [:])), "N191-live.png")
    }

    func testCardTabWithTableRenders() throws {
        let card = TaskCard(id: "N190", project: "p", status: .doing, agent: nil, branch: nil, kind: nil, files: [], title: "Leftover test defaults",
                            sections: ["Goal": "Where they come from:\n\n" + Self.table + "\n\nAnd the flow:\n\n" + Self.bare, "Acceptance criteria": "Tests green."],
                            url: URL(fileURLWithPath: "/x/N190.md"), modified: nil)
        let view = TaskDetailView(card: card, shots: [], opener: nil, startState: StartButtonState(enabled: false, help: ""),
                                  reviewState: reviewButtonStates(card: card, canAct: false, reason: "x", worktreeExists: false, busy: false, agentWorking: false),
                                  onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}, startTab: .card)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 700, height: 760)))
        XCTAssertGreaterThan(data.count, 10_000)
        try write(data, "N191-card.png")
    }

    /// N288: nested bullets, a numbered list, a `shell` code block with its Copy, a table with its Copy, inline code.
    func testChatReplyWithListsCodeAndTableRenders() throws {
        let text = """
        Devir notu güncel. `main` = **stable-221**, çalışan ajan yok. Onayınızı bekleyenler:
        - **N287** (S–M): panel notları tek sessiz satır
          - yalın `✓` yanıtı o satıra tik olur
            - anahtar satırı hiç çizilmez
        - **N288** (M): bir PM turu = tek balon
        1. Kartı oku
        2. Başlat
        ```shell
        request-start.sh --key ••• …/agent-panel "N287" N287
        ```
        | Kart | Durum |
        |---|---|
        | N287 | doing |
        | N288 | review |
        Onay verirseniz N287'yi başlatırım.
        """
        let entries = [ChatEntry(id: "1", kind: .agent, text: text, time: nil)]
        let thread = ChatThread(place: ChatPlace(), entries: entries, agentLabel: "PM", working: false).environment(\.snapshotMode, true).padding(12).background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: thread, size: CGSize(width: 520, height: 480)))
        XCTAssertGreaterThan(data.count, 8_000)
        try write(data, "N288-thread.png")
        let full = MarkdownText(text: text).environment(\.snapshotMode, true).padding(12).frame(width: 520, height: 372, alignment: .top).background(Tok.pane)
        try write(try XCTUnwrap(SnapshotRenderer.render(view: full, size: CGSize(width: 520, height: 372))), "N288-markdown.png")
    }
}
