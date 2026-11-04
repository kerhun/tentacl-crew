import XCTest
import SwiftUI
import AppKit
@testable import AgentPanel

/// The chat v2 thread (N290): the rows of `ChatRows` drawn after `design/chat-v2/MainDark.dc.html`.
@MainActor
final class ChatRowViewsTests: XCTestCase {
    private static let today = Calendar.current.startOfDay(for: Date())
    private static func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        today.addingTimeInterval(TimeInterval(dayOffset * 86_400 + hour * 3600 + minute * 60))
    }
    private static func e(_ id: String, _ kind: ChatEntry.Kind, _ text: String, _ time: Date?, tools: [String] = [], summary: String = "", pending: ChatEntry.Pending? = nil) -> ChatEntry {
        ChatEntry(id: id, kind: kind, text: text, time: time, pending: pending, tools: tools, toolSummary: summary)
    }

    // MARK: badge and rows

    func testTheBadgeCountsOnlyTheUsersMessagesAndTheAgentsTurns() {
        let entries = [
            Self.e("1", .panel, "Panel: N280 started", Self.at(3, 15)),
            Self.e("2", .agent, "✓", Self.at(3, 15)),
            Self.e("3", .panel, "Panel: N281 started", Self.at(3, 16)),
            Self.e("4", .tools, "ran 1 command", Self.at(3, 17)),
            Self.e("5", .user, "status?", Self.at(5, 0)),
            Self.e("6", .agent, "All quiet.", Self.at(5, 1)),
            Self.e("7", .summary, "summary", Self.at(15, 0)),
            Self.e("8", .tools, "read 1 file", Self.at(15, 1)),
        ]
        XCTAssertEqual(ChatPlace.messages(entries), 2, "system, tools, summary, day and gap rows are never counted")
        let place = ChatPlace()
        place.scrolled(top: 0, fromBottom: 2000, visible: 500, messages: ChatPlace.messages(entries))
        let more = entries + [Self.e("9", .panel, "Panel: N282 started", Self.at(15, 2)), Self.e("10", .agent, "✓", Self.at(15, 2)),
                              Self.e("11", .user, "and now?", Self.at(15, 3))]
        XCTAssertEqual(place.newCount(in: more), 1, "a panel note and its ✓ do not raise the badge; the user's message does")
    }

    func testAFoldedAckMakesNoRow() {
        let rows = ChatRows.build(entries: [Self.e("1", .panel, "Panel: N285 is done", Self.at(14, 50)), Self.e("2", .agent, "✓", Self.at(14, 50))])
        XCTAssertEqual(rows.map(\.id), ["day-\(Self.today.timeIntervalSinceReferenceDate)", "system-1"], "the ✓ has no row of its own")
        guard case .system(let events) = rows[1] else { return XCTFail("a system row") }
        XCTAssertEqual(events.map(\.acked), [true])
    }

    func testCopyOnATurnCopiesAllItsTextAlsoUnderShowAll() {
        let text = (1...10).map { "Line \($0) of the answer." }.joined(separator: "\n")
        XCTAssertTrue(ChatText.preview(text, maxLines: TurnRow.maxLines).cut, "the turn is cut to Show all")
        let board = NSPasteboard(name: NSPasteboard.Name("agent-panel-turn-copy-test"))
        ChatRowText.copy(text, to: board)
        XCTAssertEqual(board.string(forType: .string), text)
        board.releaseGlobally()
    }

    func testQuoteAndLabels() {
        XCTAssertEqual(ChatRowText.quote("First.\n\nSecond.\n"), "> First.\n>\n> Second.\n\n")
        XCTAssertEqual(ChatRowText.gap(9 * 3600 + 35 * 60 + 20), "9 h 35 min later")
        XCTAssertEqual(ChatRowText.gap(2 * 3600), "2 h later")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 (UTC)
        XCTAssertEqual(ChatRowText.day(now, now: now, calendar: cal), "TODAY")
        XCTAssertEqual(ChatRowText.day(now.addingTimeInterval(-86_400), now: now, calendar: cal), "YESTERDAY")
        XCTAssertEqual(ChatRowText.day(now.addingTimeInterval(-86_400 * 2), now: now, calendar: cal), "OCT 24")
        XCTAssertEqual(ChatRowText.tool("Bash · git log --oneline -1").kind, "Bash")
        XCTAssertEqual(ChatRowText.tool("TodoWrite").what, "")
        XCTAssertEqual(ChatRowText.elapsed(72), "1:12")
    }

    func testTheWorkingLineNamesTheLastToolOfTheTurnUnderWay() {
        let entries = [Self.e("1", .user, "go", Self.at(14, 52)),
                       Self.e("2", .agent, "On it.", Self.at(14, 53), tools: ["Read · pm-handoff.md", "Bash · git log main..task/n287 --oneline"])]
        XCTAssertEqual(ChatThread.lastTool(entries), "Bash · git log main..task/n287 --oneline")
        XCTAssertEqual(ChatThread.turnStart(entries), Self.at(14, 52))
        XCTAssertNil(ChatThread.lastTool(entries + [Self.e("3", .user, "next", Self.at(14, 54))]), "a new message starts a new turn")
    }

    func testPreviousConversationKeepsItsRowsAboveTheDivider() {
        let previous = [Self.e("p1", .user, "old", Self.at(9, 0, dayOffset: -1)), Self.e("p2", .agent, "old answer", Self.at(9, 1, dayOffset: -1))]
        let entries = [Self.e("n1", .user, "new", Self.at(10, 0))]
        let rows = ChatRows.build(entries: entries, previous: previous)
        let split = ChatThread.firstNewRow(rows, entries: entries)
        XCTAssertEqual(rows[..<split].map(\.id), [rows[0].id, "p1", "p2"])
        XCTAssertEqual(rows[split...].map(\.id).last, "n1")
        if case .day = rows[split] {} else { XCTFail("today's divider starts the new conversation") }
    }

    // MARK: snapshots

    /// Today's PM session: yesterday's stack of panel notes and a turn with tools, a gap, today's summary, an acked note,
    /// the user's message, a turn with tools and Markdown, and the working line.
    private static var session: [ChatEntry] {
        let events = [("N280 started under your standing authority", 15), ("N281 started", 15), ("N282 started", 16),
                      ("N283 is ready for review", 52), ("N284 needs a fix", 60 + 20), ("N284 is done", 60 + 42)]
        var out: [ChatEntry] = []
        for (i, ev) in events.enumerated() {
            let time = at(3, ev.1, dayOffset: -1)
            out.append(e("s\(i)", .panel, "Panel: \(ev.0)", time))
            out.append(e("a\(i)", .agent, "✓", time))
        }
        out.append(e("t1", .agent, "Round T is done (N280–N284). `main` = **stable-220**. No agent is running.", at(4, 42, dayOffset: -1),
                     tools: ["Bash · git log --oneline -1", "Edit · pm-handoff.md", "Bash · git tag stable-220"],
                     summary: "ran 2 commands, edited 1 file"))
        out.append(e("u0", .user, "Anything new?", at(4, 58)))
        out.append(e("t0", .agent, "No, all quiet. I'll wait for your go.", at(4, 59)))
        out.append(e("sum", .summary, "The PM ran round T (N280–N284); main is stable-220; no agent is running.", at(14, 34)))
        out.append(e("s9", .panel, "Panel: N285 is done", at(14, 50)))
        out.append(e("a9", .agent, "✓", at(14, 50)))
        out.append(e("u2", .user, "I did not see the permission question the PM got. Let's first design a more advanced chat.", at(14, 52)))
        out.append(e("t2", .agent, """
            The hand-off note is up to date. `main` = **stable-221**, no agent is running. Waiting for your approval:
            - **N287** (S–M): panel notes as one quiet line
              - a bare `✓` answer becomes a check on that line
            - **N288** (M): one PM turn = one entry
            ```shell
            request-start.sh --key ••• …/agent-panel "N287" N287
            ```
            If you approve, I'll start N287.
            """, at(14, 53),
                     tools: ["Read · pm-handoff.md", "Bash · tail -5 actions.log; git log --oneline -1", "Bash · graphify query \"permission prompt in PM pane\"",
                             "Read · agent-panel-chat-analiz.md", "Bash · grep -n \"isPM\" State/AgentInboxModel.swift"],
                     summary: "read 2 files, ran 3 commands"))
        out.append(e("t3", .tools, "ran 1 command", at(14, 55), tools: ["Bash · git log main..task/n287 --oneline"], summary: "ran 1 command"))
        return out
    }

    private func card(openAll: Bool) -> some View {
        ChatThread(place: ChatPlace(), entries: Self.session, agentLabel: "PM", working: true,
                   onRetry: { _ in }, onQuote: { _ in }, onEditAgain: { _ in }, openAll: openAll, now: Self.at(14, 55).addingTimeInterval(12))
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            .background(Tok.pane)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tok.line))
            .environment(\.colorScheme, .dark)
    }

    private func write(_ view: some View, _ name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 760, height: 1200)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    func testThreadSnapshot() throws { try write(card(openAll: false), "N290-thread.png") }

    func testThreadExpandedSnapshot() throws { try write(card(openAll: true), "N290-thread-expanded.png") }

    // MARK: attachments (N315)

    private static func swatch(_ dir: TempDir, _ name: String, _ color: NSColor) throws -> URL {
        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in color.setFill(); rect.fill(); return true }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        let url = dir.url.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    func testFileChipDetailReadsTheSizeAndSaysLinked() throws {
        let dir = try TempDir()
        let doc = dir.url.appendingPathComponent("plan.md")
        try Data(count: 2048).write(to: doc)
        XCTAssertEqual(FileChips.detail(ChatFile(path: doc.path, folder: false, copied: true)), Attachments.sizeText(2048))
        XCTAssertEqual(FileChips.detail(ChatFile(path: doc.path, folder: false, copied: false)), Attachments.sizeText(2048) + " · linked, not copied")
        XCTAssertEqual(FileChips.detail(ChatFile(path: dir.url.path, folder: true, copied: false)), "Folder · linked, not copied")
        XCTAssertEqual(FileChips.detail(ChatFile(path: "/nowhere/gone.pdf", folder: false, copied: false)), "linked, not copied")
    }

    /// The Command box with an image, a document and a folder attached, and the sent message, in Dark and Light.
    func testAttachmentsSnapshotsInDarkAndLight() async throws {
        let dir = try TempDir()
        let store = Attachments(root: dir.url.appendingPathComponent("attachments"))
        let doc = dir.url.appendingPathComponent("release-notes.pdf")
        try Data(count: 184_000).write(to: doc)
        let folder = dir.url.appendingPathComponent("design")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pending = [try store.pending(file: Self.swatch(dir, "shot.png", .systemTeal)), try store.pending(file: doc), try store.pending(file: folder)]
        XCTAssertEqual(pending.map(\.kind), [.image, .file, .linked])
        let model = await DemoSupport.makeModel()
        let session = model.chats.session(project: model.selectedProjectID ?? "", pane: "")
        session.images = pending
        defer { session.images = [] }

        let stored = try store.store(pending, project: "demo")
        let shown = Attachments.split(stored, root: store.root)
        XCTAssertEqual(shown.images.count, 1)
        XCTAssertEqual(shown.files.map(\.folder), [false, true])
        let sent = ChatEntry(id: "u", kind: .user, text: "Here are the notes and the design folder.", time: Self.at(14, 52), images: shown.images, files: shown.files)
        let row = UserRow(entry: sent, onRemove: { _ in }, onOpenImage: { _, _ in }).padding(20).background(Tok.pane)

        let theme = AppTheme.current
        defer { AppTheme.current = theme }
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            AppTheme.current = scheme == .dark ? .dark : .light
            let box = try XCTUnwrap(SnapshotRenderer.render(view: CommandBar(model: model).environment(\.colorScheme, scheme), size: CGSize(width: 520, height: 560)))
            XCTAssertGreaterThan(box.count, 8_000)
            let msg = try XCTUnwrap(SnapshotRenderer.render(view: row.environment(\.colorScheme, scheme), size: CGSize(width: 620, height: 240)))
            XCTAssertGreaterThan(msg.count, 8_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                try box.write(to: URL(fileURLWithPath: out).appendingPathComponent("N315-command-box-\(name).png"))
                try msg.write(to: URL(fileURLWithPath: out).appendingPathComponent("N315-sent-\(name).png"))
            }
        }
    }
}
