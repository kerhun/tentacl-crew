import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

private struct RepoAgent: TerminalListing {
    let cwd: String
    func agents() async throws -> [AgentStatus] { [AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: cwd, title: "PM")] }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// The composer hosted in a real window: keys go through `NSWindow.sendEvent`, the way the running app delivers them.
@MainActor
final class CommandBarKeyTests: XCTestCase {
    private var model: PanelModel!
    private var window: NSWindow!
    private var before: Any?

    override func setUp() async throws {
        before = UserDefaults.standard.object(forKey: CommandBar.returnSendsKey)
        // The demo data with one agent working in the demo project's repository, so the Command box picks it.
        let settings = DemoSupport.prepareSettings()
        let repo = settings.deletingLastPathComponent().appendingPathComponent("repo").path
        model = PanelModel(settingsURL: settings, makeTerminal: { RepoAgent(cwd: repo) }, opener: WorkspaceURLOpener(),
                           makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                           log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-key-tests.log")),
                           writer: DemoCardWriter(), defaults: makeTestDefaults(prefix: "agent-panel-key-tests"), roleStore: RoleStore())
        await model.reload()
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(before, forKey: CommandBar.returnSendsKey)
        for session in sessions { _ = session.chat.takeBack(editing: false); session.clearDraft() }
        window?.orderOut(nil); window = nil
    }

    private var sessions: [ChatSession] {
        guard case .available(let list) = model.visibleAgents else { return [] }
        return list.compactMap { model.chats.existingSession(project: model.selectedProjectID ?? "", pane: $0.paneID) }
    }

    /// Hosts the composer, waits until it has picked an agent and returns its input with focus (`focus`: given by the test; off: the
    /// input has to take it by itself).
    private func host(returnSends: Bool, chatHeight: Double = CommandBar.defaultChatHeight, focus: Bool = true,
                      doneLineTime: Duration = PanelModel.doneLineTime, width: Double = 420, dark: Bool = false,
                      onActionsSize: ((CGSize) -> Void)? = nil) async throws -> NSTextView {
        UserDefaults.standard.set(returnSends, forKey: CommandBar.returnSendsKey)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: CommandBar(model: model, chatHeight: .constant(chatHeight), maxChatHeight: 700, doneLineTime: doneLineTime, onActionsSize: onActionsSize)
            .environment(\.colorScheme, dark ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        var input: NSTextView?
        await until { input = self.find(in: self.window.contentView); return input != nil && !self.sessions.isEmpty }
        XCTAssertFalse(sessions.isEmpty, "an agent is chosen")
        let view = try XCTUnwrap(input, "the input is an AppKit text view the window can focus")
        if focus { XCTAssertTrue(window.makeFirstResponder(view)) } else { await until { self.window.firstResponder === view } }
        XCTAssertNotNil(CommandBar.inputEditor(window.firstResponder), "the paste and Return handling recognise the focused input")
        return view
    }

    private func find(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.accessibilityIdentifier() == CommandBar.inputIdentifier { return text }
        for sub in view.subviews { if let hit = find(in: sub) { return hit } }
        return nil
    }

    /// Lets SwiftUI and AppKit lay out until `done` holds (up to 5 s), so a loaded machine only makes the test slower.
    private func until(_ done: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func type(_ text: String, into input: NSTextView) async {
        input.insertText(text, replacementRange: input.selectedRange())
        // Typing is synchronous; what depends on layout is waited for with `until` where it is checked.
        await Task.yield()
    }

    /// Types `text` as key presses sent to the window, so it lands wherever the window's focus is.
    private func press(_ text: String) {
        for c in text.map(String.init) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0) else { continue }
            window.sendEvent(event)
        }
    }

    private func pressReturn(_ modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 36) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
        // The key is handled synchronously: a send is held (or a new line typed) when sendEvent returns.
        window.sendEvent(event)
    }

    private var held: [String] { sessions.compactMap { $0.chat.held?.text } }

    func testReturnSendsIntoTheHoldWhenTicked() async throws {
        let input = try await host(returnSends: true)
        await type("Please start N8 next.", into: input)
        try await pressReturn()
        XCTAssertEqual(held, ["Please start N8 next."])
        await until { input.string.isEmpty }
        XCTAssertEqual(input.string, "", "the input is cleared")
    }

    func testKeypadEnterSendsToo() async throws {
        let input = try await host(returnSends: true)
        await type("from the keypad", into: input)
        try await pressReturn(keyCode: 76)
        XCTAssertEqual(held, ["from the keypad"])
    }

    func testShiftReturnStartsANewLineWhenTicked() async throws {
        let input = try await host(returnSends: true)
        await type("one", into: input)
        try await pressReturn(.shift)
        await type("two", into: input)
        XCTAssertEqual(input.string, "one\ntwo")
        XCTAssertEqual(held, [])
    }

    func testTypingGoesIntoTheInputAsSoonAsTheChatAppears() async throws {
        let input = try await host(returnSends: true, focus: false)
        XCTAssertTrue(window.firstResponder === input, "the input has the focus without a click")
        press("one")
        try await pressReturn(.shift)
        press("two")
        XCTAssertEqual(input.string, "one\ntwo")
        XCTAssertEqual(held, [], "Shift-Return sends nothing")
    }

    /// The input method may answer a key with `insertNewline:` after keyDown has returned (a real key in the active app); the Shift is
    /// no longer known then, so Return is decided from the key itself and a late command never sends.
    func testALateNewlineCommandNeverSends() async throws {
        let input = try await host(returnSends: true)
        await type("one", into: input)
        input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(held, [])
        XCTAssertEqual(input.string, "one\n")
    }

    func testAnotherFieldKeepsItsFocusAndTheInputTakesItBackWhenItCloses() async throws {
        let input = try await host(returnSends: true, focus: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        try await Task.sleep(for: .milliseconds(200))
        press("note")
        XCTAssertEqual(field.stringValue, "note", "a field the user is typing in keeps the focus")
        XCTAssertEqual(input.string, "")
        field.removeFromSuperview()
        await until { self.window.firstResponder === input }
        XCTAssertTrue(window.firstResponder === input, "closing the other field gives the focus back to the input")
        press("hi")
        XCTAssertEqual(input.string, "hi")
    }

    func testOffReturnStartsANewLineAndNothingIsSent() async throws {
        let input = try await host(returnSends: false)
        await type("one", into: input)
        try await pressReturn()
        await type("two", into: input)
        XCTAssertEqual(input.string, "one\ntwo")
        XCTAssertEqual(held, [])
    }

    func testReturnWhileComposingIsLeftToTheInputMethod() async throws {
        let input = try await host(returnSends: true)
        input.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: input.selectedRange())
        XCTAssertTrue(input.hasMarkedText())
        try await pressReturn()
        XCTAssertEqual(held, [], "Return is left to the input method")
    }

    func testALongMessageGrowsTheInputThenScrollsAndShrinksAfterSending() async throws {
        let input = try await host(returnSends: true, chatHeight: 500)
        let scroll = try XCTUnwrap(input.enclosingScrollView)
        let empty = scroll.frame.height
        let line = input.layoutManager!.defaultLineHeight(for: input.font!)
        await type("one line", into: input)
        await until { abs(scroll.frame.height - empty) <= 1 }
        XCTAssertEqual(scroll.frame.height, empty, accuracy: 1, "one line stays one line tall")
        await type((2...6).map { "\nline \($0)" }.joined(), into: input)
        await until { scroll.frame.height > line * 5.5 }
        XCTAssertGreaterThan(scroll.frame.height, line * 5.5, "it grows past the old five-line stop")
        let text = (1...30).map { "line \($0) of a long message" }.joined(separator: "\n")
        input.string = ""; await type(text, into: input)
        await until { scroll.frame.height > 500 * 0.4 - line - 1 && abs(scroll.contentView.bounds.maxY - input.frame.height) <= 2 }
        XCTAssertLessThanOrEqual(scroll.frame.height, 500 * 0.4 + 1, "no taller than 40% of the conversation")
        XCTAssertGreaterThan(scroll.frame.height, 500 * 0.4 - line - 1)
        XCTAssertGreaterThan(input.frame.height, scroll.contentView.bounds.height, "the rest scrolls inside")
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertEqual(input.string, text, "the whole message is in the input")
        XCTAssertEqual(scroll.contentView.bounds.maxY, input.frame.height, accuracy: 2, "the caret at the end is kept in view")
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"], let content = window.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("command-box-long-input.png"))
        }
        // Scrolled back like the scroll wheel does, with the caret left at the end.
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "the start can be scrolled back to")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "the start can be scrolled back to and stays in view")
        input.moveToEndOfDocument(nil); input.moveToBeginningOfDocument(nil)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "the arrow keys reach the start too")
        input.moveToEndOfDocument(nil)
        try await pressReturn()
        XCTAssertEqual(held, [text])
        await until { abs(scroll.frame.height - empty) <= 1 }
        XCTAssertEqual(scroll.frame.height, empty, accuracy: 1, "it shrinks back after sending")
    }

    /// N293: while a panel action runs the input still takes text; Return (and Send) wait, the draft stays, and sends once it ends.
    func testWhileAnActionRunsTheInputTakesTextAndOnlySendWaits() async throws {
        let input = try await host(returnSends: true)
        model.setActionState(.running("Starting N8…"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(input.isEditable, "the input is never locked")
        await type("Please start N8 next.", into: input)
        try await pressReturn()
        XCTAssertEqual(held, [], "Return does nothing while busy")
        XCTAssertEqual(input.string, "Please start N8 next.", "the draft is untouched")
        model.setActionState(.idle)
        try await pressReturn()
        XCTAssertEqual(held, ["Please start N8 next."], "Send works again when the action ends")
    }

    /// N293: with no open question a digit is typed like any key.
    func testADigitIsTypedWhenNoQuestionIsOpen() async throws {
        let input = try await host(returnSends: true)
        press("2")
        XCTAssertEqual(input.string, "2")
    }

    /// N303: a done line clears on a send; a failed line stays.
    func testADoneLineClearsOnSendAndAFailedLineStays() async throws {
        let input = try await host(returnSends: true)
        model.setActionState(.done("Started N8 on task/n8."))
        await type("Hello", into: input)
        try await pressReturn()
        XCTAssertEqual(held, ["Hello"])
        XCTAssertEqual(model.actionState, .idle, "the Started… line is gone after a send")
        // Undo the held message, so its delivery does not start a new action.
        for session in sessions { _ = session.chat.takeBack(editing: false) }
        model.setActionState(.failed("Could not start N8."))
        await type("Again", into: input)
        try await pressReturn()
        XCTAssertEqual(model.actionState, .failed("Could not start N8."), "a failed line stays until the next action")
    }

    /// N303: a done line clears by itself after its time; a failed line does not.
    func testADoneLineFadesAfterItsTimeAndAFailedLineStays() async throws {
        _ = try await host(returnSends: true, doneLineTime: .milliseconds(200))
        model.setActionState(.done("Command sent."))
        await until { self.model.actionState == .idle }
        XCTAssertEqual(model.actionState, .idle)
        model.setActionState(.failed("Could not send."))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.actionState, .failed("Could not send."))
    }

    /// N303: a long Waiting line wraps (two lines at most) and never squeezes the right-hand group: "Return sends" stays on one line.
    func testALongWaitingLineLeavesReturnSendsOnOneLine() async throws {
        var size = CGSize.zero
        _ = try await host(returnSends: true, width: 900, onActionsSize: { size = $0 })
        await until { size.width > 0 }
        let roomy = size
        window.orderOut(nil)
        for dark in [false, true] {
            size = .zero
            _ = try await host(returnSends: true, width: 360, dark: dark, onActionsSize: { size = $0 })
            model.setActionState(.running("Starting ui_dev-n303-agent-panel in its worktree, trusting the folder and waiting for the first prompt…"))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(size.width, roomy.width, accuracy: 0.5, "the group keeps its full width beside a long Waiting line")
            XCTAssertEqual(size.height, roomy.height, accuracy: 0.5, "Return sends stays on one line")
            try shot("N303-waiting-\(dark ? "dark" : "light").png")
            model.setActionState(.idle)
            window.orderOut(nil)
        }
    }

    private func shot(_ name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    func testClearDoneLineOnlyClearsTheShownDoneLine() {
        model.setActionState(.done("Started A."))
        model.clearDoneLine("Started B.")
        XCTAssertEqual(model.actionState, .done("Started A."), "a newer done line is not cleared by an older timer")
        model.clearDoneLine("Started A.")
        XCTAssertEqual(model.actionState, .idle)
        model.setActionState(.running("Starting…"))
        model.clearDoneLine()
        XCTAssertEqual(model.actionState, .running("Starting…"))
    }

    func testTheCapIsFortyPercentButNeverBelowFiveLines() {
        XCTAssertEqual(CommandBar.inputMaxHeight(chat: 500, line: 16), 200)
        XCTAssertEqual(CommandBar.inputMaxHeight(chat: 120, line: 16), 80)
    }
}
