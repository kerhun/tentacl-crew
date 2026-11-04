import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

/// N292: the quote box of the input and the display name on the agent's turns.
final class ChatQuoteTests: XCTestCase {
    private let answer = ChatQuote(speaker: "Ibrahim", text: "First line.\n\nSecond line.\nThird line.")

    func testSendIsTheQuoteThenTheTypedText() {
        XCTAssertEqual(ChatQuote.message(quote: answer, typed: "Yes, go on."), "> **Ibrahim:**\n> First line.\n>\n> Second line.\n> Third line.\n\nYes, go on.")
        XCTAssertEqual(ChatQuote.message(quote: answer, typed: "  "), "> **Ibrahim:**\n> First line.\n>\n> Second line.\n> Third line.", "a quote alone is sent as it is")
        XCTAssertEqual(ChatQuote.message(quote: nil, typed: "Plain"), "Plain")
    }

    /// N322: a user message splits into its quote and the typed text; what Send makes splits back into the same quote.
    func testSplitIsTheLeadingQuoteAndTheText() {
        let parts = ChatQuote.split(ChatQuote.message(quote: answer, typed: "Yes, go on.\n\nSecond paragraph."))
        XCTAssertEqual(parts.quote, answer, "multi-line with an empty line, the speaker from the first line")
        XCTAssertEqual(parts.text, "Yes, go on.\n\nSecond paragraph.")
        let alone = ChatQuote.split(ChatQuote.message(quote: answer, typed: ""))
        XCTAssertEqual(alone.quote, answer); XCTAssertEqual(alone.text, "", "no text")
        let old = ChatQuote.split("> First.\n>\n> Second.\n\nOk")
        XCTAssertEqual(old.quote, ChatQuote(speaker: "", text: "First.\n\nSecond."), "an old message without the speaker line")
        XCTAssertEqual(old.text, "Ok")
        XCTAssertNil(ChatQuote.split("Just text").quote, "no quote")
        XCTAssertEqual(ChatQuote.split("Just text").text, "Just text")
        let middle = "As the PM said:\n> run the tests\nthen merge"
        XCTAssertNil(ChatQuote.split(middle).quote, "a > further down is part of the text")
        XCTAssertEqual(ChatQuote.split(middle).text, middle)
        XCTAssertNil(ChatQuote.split(">\n>").quote, "an empty quote is no quote")
    }

    /// N322: the quote's Markdown as plain text: table rows as cells, no rule lines, fences, backticks or bold.
    func testPlainLinesDropTheMarkdownSyntax() {
        let quote = ChatQuote(speaker: "pm", text: "## Plan\n\n| Card | Agent |\n|---|:--:|\n| N316 | `dev` |\n\n```\nscripts/app-test.sh\n```\n- **first**\n* second")
        XCTAssertEqual(quote.plainLines, ["Plan", "", "Card · Agent", "N316 · dev", "", "scripts/app-test.sh", "• first", "• second"])
        XCTAssertEqual(quote.plainPreview, "Plan\nCard · Agent\nN316 · dev\nscripts/app-test.sh\n• first\n• second")
    }

    /// N322: Edit again / Edit / Undo on a quoted message put the quote back into the box and only the typed text into the field.
    func testEditAgainRestoresTheQuoteBox() {
        var quotes = ChatQuotes()
        quotes.put(answer, for: "demo|p1")
        let sent = quotes.send("Yes, go on.", for: "demo|p1")
        XCTAssertNil(quotes["demo|p1"])
        XCTAssertEqual(quotes.restore(sent, for: "demo|p1"), "Yes, go on.")
        XCTAssertEqual(quotes["demo|p1"], answer)
        quotes.remove(for: "demo|p1")
        XCTAssertEqual(quotes.restore("Plain", for: "demo|p1"), "Plain")
        XCTAssertNil(quotes["demo|p1"], "a message without a quote leaves the box alone")
        XCTAssertEqual(quotes.send(quotes.restore(sent, for: "demo|p1"), for: "demo|p1"), sent, "sent again unchanged")
    }

    func testPreviewIsTheFirstTwoLines() {
        XCTAssertEqual(answer.preview, "First line.\nSecond line…", "one … in place of the final period")
        XCTAssertEqual(ChatQuote(speaker: "pm", text: "One\nTwo").preview, "One\nTwo")
    }

    /// N293: "present.…" never again; a text shown in full has no "…", a cut one exactly one.
    func testTheCutAddsOneEllipsisOnlyWhenTextIsLeftOut() {
        XCTAssertEqual(ChatQuote(speaker: "pm", text: "Both shots are present.").preview, "Both shots are present.")
        XCTAssertEqual(ChatQuote(speaker: "pm", text: "Tests pass.\nBoth shots are present.").preview, "Tests pass.\nBoth shots are present.")
        XCTAssertEqual(ChatQuote(speaker: "pm", text: "Tests pass.\nBoth shots are present.\nN293 next.").preview, "Tests pass.\nBoth shots are present…")
        XCTAssertEqual(ChatQuote(speaker: "pm", text: "One\nTwo…\nThree").preview, "One\nTwo…", "never two")
        let long = (1...6).map { "Line \($0) of a long answer" }.joined(separator: "\n")
        XCTAssertEqual(ChatQuote(speaker: "pm", text: long).preview.filter { $0 == "…" }.count, 1)
    }

    func testRemoveClearsAndASecondQuoteReplaces() {
        var quotes = ChatQuotes()
        quotes.put(answer, for: "demo|p1")
        quotes.put(ChatQuote(speaker: "pm", text: "Newer"), for: "demo|p1")
        XCTAssertEqual(quotes["demo|p1"]?.text, "Newer", "one quote at a time")
        quotes.remove(for: "demo|p1")
        XCTAssertNil(quotes["demo|p1"])
        quotes.put(answer, for: "demo|p1")
        quotes.put(answer, for: "demo|p2")
        XCTAssertEqual(quotes.send("Ok", for: "demo|p1"), ChatQuote.message(quote: answer, typed: "Ok"))
        XCTAssertNil(quotes["demo|p1"], "Send clears the box with the text")
        XCTAssertNotNil(quotes["demo|p2"], "another agent's quote stays")
    }

    func testTurnLabelIsTheDisplayNameWithTheRole() {
        XCTAssertTrue(ChatRowText.turnLabel(agent: "pm-agent-panel", displayNames: ["pm": "Ibrahim"]) == ("Ibrahim", "pm"))
        XCTAssertTrue(ChatRowText.turnLabel(agent: "pm-agent-panel", displayNames: [:]) == ("pm", nil))
        XCTAssertTrue(ChatRowText.turnLabel(agent: "dev-n292-agent-panel", displayNames: ["dev": "  "]) == ("dev", nil), "a blank display name counts as none")
        XCTAssertTrue(ChatRowText.turnLabel(agent: "PM", displayNames: ["pm": "Ibrahim"]) == ("PM", nil), "a session started by hand keeps its name")
    }
}

private final class SwitchingAgent: TerminalListing, @unchecked Sendable {
    let cwd: String
    var session: String?
    init(cwd: String, session: String?) { self.cwd = cwd; self.session = session }
    func agents() async throws -> [AgentStatus] {
        [AgentStatus(paneID: "pm-agent-panel", workspaceID: "pm-agent-panel", state: .idle, cwd: cwd, title: "pm-agent-panel", sessionID: session, name: "pm-agent-panel")]
    }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// The Command box in a real window: the PM chosen before a /clear, the quote box, the turn label (dark snapshots).
@MainActor
final class ChatQuoteWindowTests: XCTestCase {
    private var model: PanelModel!
    private var terminal: SwitchingAgent!
    private var window: NSWindow!

    override func setUp() async throws {
        let settings = DemoSupport.prepareSettings()
        let work = settings.deletingLastPathComponent()
        let roles = work.appendingPathComponent("n292-roles")
        try FileManager.default.createDirectory(at: roles, withIntermediateDirectories: true)
        try #"{"name":"pm","kind":"interactive","model":"opus","effort":"high","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"pm.md","displayName":"Ibrahim"}"#
            .write(to: roles.appendingPathComponent("pm.json"), atomically: true, encoding: .utf8)
        try "PM\n".write(to: roles.appendingPathComponent("pm.md"), atomically: true, encoding: .utf8)
        let terminal = SwitchingAgent(cwd: work.appendingPathComponent("repo").path, session: nil)
        self.terminal = terminal
        model = PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: WorkspaceURLOpener(),
                           makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                           log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-n292-tests.log")),
                           writer: DemoCardWriter(), defaults: makeTestDefaults(prefix: "agent-panel-n292-tests"), roleStore: RoleStore(baseDir: roles))
        await model.reload()
    }

    override func tearDown() async throws {
        model.chats.existingSession(project: model.selectedProjectID ?? "", pane: "pm-agent-panel")?.clearDraft()
        window?.contentView = nil
        window?.orderOut(nil); window = nil
        try? await Task.sleep(for: .milliseconds(50))
    }

    private var project: String { model.selectedProjectID ?? "" }

    private func show() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        window.contentView = NSHostingView(rootView: CommandBar(model: model, chatHeight: .constant(360), maxChatHeight: 500).environment(\.colorScheme, .dark))
    }

    private func write(_ name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    /// N292 (1) on screen: the PM chosen before its session was known, then a /clear typed in the terminal; the header keeps
    /// "New conversation…" (the logic is `ChosenAgentTests`; the snapshot shows it).
    func testNewConversationStaysAfterTheSessionChanges() async throws {
        show()
        try? await Task.sleep(for: .milliseconds(300))
        for session in ["s2", "s3"] {
            terminal.session = session
            await model.refreshAgents(waitForFreshStart: false)
            try? await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertEqual(model.pmSession(forProject: project).map { $0 == "s3" } ?? true, true, "a remembered PM session follows the /clear")
        model.chats.session(project: project, pane: "pm-agent-panel").chat.addPending("Asked the reviewer to look at N291; the report is in.\nN292 can start once you approve.", kind: .agent, id: "turn1")
        try? await Task.sleep(for: .milliseconds(200))
        try write("N292-header.png")
    }

    func testQuoteBoxInTheInput() async throws {
        terminal.session = "s1"
        await model.refreshAgents(waitForFreshStart: false)
        model.chats.session(project: project, pane: "pm-agent-panel").chat.addPending("Report for N291 is in.\nTests 1774/0, both shots present.\nI'll start N292 next.", kind: .agent, id: "turn1")
        model.chatQuotes.put(ChatQuote(speaker: "Ibrahim", text: "Report for N291 is in.\nTests 1774/0, both shots present.\nI'll start N292 next."), for: project + "|pm-agent-panel")
        model.chats.session(project: project, pane: "pm-agent-panel").text = "Go ahead with N292."
        show()
        try? await Task.sleep(for: .milliseconds(400))
        try write("N292-quote.png")
    }

    /// N322 F1: a failed send with a quote refills an empty input with the typed text and the quote box with the quote.
    func testFailedSendPutsTheQuoteBackInTheBox() {
        let key = project + "|pm-agent-panel"
        let session = model.chats.session(project: project, pane: "pm-agent-panel")
        let quote = ChatQuote(speaker: "Ibrahim", text: "Report for N291 is in.\n\nTests 1774/0.")
        let held = HeldMessage(text: ChatQuote.message(quote: quote, typed: "Go ahead."), images: [], stored: [], deadline: Date())
        session.clearDraft(); model.chatQuotes.remove(for: key)
        CommandBar.refill(held, session: session, model: model, quoteKey: key)
        XCTAssertEqual(session.text, "Go ahead.", "the typed text alone in the field")
        XCTAssertEqual(model.chatQuotes[key], quote, "the quote back in the box")
        session.text = "New text"; model.chatQuotes.remove(for: key)
        CommandBar.refill(held, session: session, model: model, quoteKey: key)
        XCTAssertEqual(session.text, "New text", "an input typed in since is left alone")
        XCTAssertNil(model.chatQuotes[key])
        session.clearDraft()
        CommandBar.refill(HeldMessage(text: "Plain", images: [], stored: [], deadline: Date()), session: session, model: model, quoteKey: key)
        XCTAssertEqual(session.text, "Plain"); XCTAssertNil(model.chatQuotes[key], "no quote, no box")
    }

    /// N322: a message sent with a quote, short, long (a table, code, a list) and the quote alone; the one above as sent, the one
    /// below held (Sending in… Edit Undo). In Light, Dark and Midnight.
    func testSentQuoteInEveryTheme() async throws {
        terminal.session = "s1"
        await model.refreshAgents(waitForFreshStart: false)
        let long = ChatQuote(speaker: "Ibrahim", text: "I'm writing the card for the quote bug (N322).\n\nSeven fix cards, none started:\n\n| Card | Agent | Topic |\n|---|---|---|\n| N316 | dev | Terminal colours follow the system theme |\n| N317 | dev | `[File:]` lines as chips |\n\n```\nscripts/app-test.sh\n```\n\n- first\n- second\n\nI'll ask before I start them.")
        let short = ChatQuote(speaker: "Ibrahim", text: "Tests 1774/0, both shots present.")
        let cases: [(String, ChatQuote, String)] = [("short", short, "Good, go on with N293."), ("long", long, "Taking a screenshot of this quote."), ("alone", long, "")]
        for (name, quote, typed) in cases {
            for theme in [AppTheme.light, .dark, .midnight] {
                AppTheme.current = theme
                let chat = model.chats.session(project: project, pane: "pm-agent-panel").chat
                chat.addPending(ChatQuote.message(quote: quote, typed: typed), kind: .user, id: "sent-\(name)-\(theme.rawValue)")
                chat.hold(text: ChatQuote.message(quote: quote, typed: typed), images: [], stored: [], delay: .seconds(600)) { _ in }
                window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                window.makeKeyAndOrderFront(nil)
                window.contentView = NSHostingView(rootView: CommandBar(model: model, chatHeight: .constant(760), maxChatHeight: 800)
                    .environment(\.colorScheme, theme == .light ? .light : .dark).environment(\.snapshotMode, true))
                try? await Task.sleep(for: .milliseconds(400))
                try write("N322-\(name)-\(theme.rawValue).png")
                _ = chat.takeBack(editing: false)
                chat.remove("sent-\(name)-\(theme.rawValue)")
                window.contentView = nil; window.orderOut(nil)
            }
        }
        AppTheme.current = .dark
    }
}
