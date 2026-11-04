import XCTest
import SwiftUI
@testable import AgentPanel

/// The Terminals screen (N224): the tab model, ⌘ digits, the message box's send path, the typing hold and the screen's snapshots.
@MainActor
final class TerminalsViewTests: XCTestCase {
    private let repo = "/Users/you/Projects/demo"
    private var worktrees: URL { URL(fileURLWithPath: repo).appendingPathComponent(".agent-worktrees") }

    private func card(_ id: String, _ status: TaskStatus, branch: String) -> TaskCard {
        TaskCard(id: id, project: "demo", status: status, agent: "dev-\(id.lowercased())", branch: branch, kind: nil, files: [], title: "\(id) · Title of \(id)", sections: [:],
                 url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }
    private func agent(_ pane: String, _ state: AgentState, cwd: String, title: String, seq: Int? = nil) -> AgentStatus {
        var a = AgentStatus(paneID: pane, workspaceID: "w", state: state, cwd: cwd, title: title, sessionID: "s-" + pane)
        a.changeSeq = seq
        return a
    }
    private func question(_ pane: String, _ kind: AgentQuestion.Kind, card: String = "") -> PendingQuestion {
        PendingQuestion(paneID: pane, sessionID: "s-" + pane, agentLabel: card, cardID: card,
                        question: AgentQuestion(kind: kind, title: "Window", text: "Which window should the usage meter show first?",
                                                options: [QuestionOption(number: 1, label: "5-hour window", detail: "", isSpecial: false),
                                                          QuestionOption(number: 2, label: "7-day window", detail: "", isSpecial: false),
                                                          QuestionOption(number: 3, label: "Both", detail: "", isSpecial: false)]))
    }

    // MARK: tabs

    func testThePMComesFirstThenTheCardsByIdThenTheSessionsOnNoCard() {
        let cards = ["N10": card("N10", .doing, branch: "task/n10"), "N9": card("N9", .doing, branch: "task/n9")]
        let agents = [agent("p-shell", .idle, cwd: repo, title: "zsh"),
                      agent("p10", .working, cwd: worktrees.appendingPathComponent("task-n10").path, title: "dev"),
                      agent("p-pm", .idle, cwd: repo, title: "pm-demo"),
                      agent("p9", .working, cwd: worktrees.appendingPathComponent("task-n9").path, title: "dev")]
        let tabs = TerminalTabs.make(agents: agents, pmPane: "p-pm", card: { a in a.paneID == "p10" ? cards["N10"] : a.paneID == "p9" ? cards["N9"] : nil },
                                     phase: { _ in .working }, questions: [])
        XCTAssertEqual(tabs.map(\.label), ["PM", "N9", "N10", "session"], "N9 before N10: ids compare as numbers; a Claude session on no card")
        XCTAssertEqual(tabs.map(\.kind), [.pm, .card, .card, .shell])
        XCTAssertEqual(tabs[1].title, "Title of N9", "the card title without its id")
        XCTAssertEqual(tabs[1].cardID, "N9")
        XCTAssertEqual(TerminalTabs.countText(tabs), "4 terminals · 2 running")
        XCTAssertEqual(TerminalTabs.countText(Array(tabs.prefix(1))), "1 terminal · 0 running")
    }

    func testTheIconFollowsTheStateAndAQuestionComesFirst() {
        let c = card("N1", .doing, branch: "task/n1")
        func icon(_ phase: TaskPhase?, kind: TerminalTab.Kind = .card, question: AgentQuestion.Kind? = nil, state: AgentState = .working) -> TerminalTab.Icon {
            TerminalTabs.state(agent: state, kind: kind, card: c, phase: phase, question: question).0
        }
        XCTAssertEqual(icon(.working), .working(2.0 / 6.0), "the ring is the card's step: work is step 2 of 6")
        XCTAssertEqual(icon(.starting), .working(1.0 / 6.0))
        XCTAssertEqual(icon(.waitingForYou), .asks)
        XCTAssertEqual(icon(.finished), .done)
        XCTAssertEqual(icon(.inReview), .done)
        XCTAssertEqual(icon(.idle), .idle)
        XCTAssertEqual(icon(nil), .idle)
        XCTAssertEqual(icon(.working, question: .choice), .asks, "a question wins over the phase")
        XCTAssertEqual(icon(.working, question: .permission), .permission)
        XCTAssertEqual(icon(.working, state: .unknown("exited")), .failed)
        XCTAssertEqual(icon(nil, kind: .pm, state: .idle), .pm)
        XCTAssertEqual(icon(nil, kind: .pm, question: .choice, state: .blocked), .asks, "the PM's menu shows as asking too")
        XCTAssertEqual(icon(nil, kind: .shell, state: .idle), .shell)
        XCTAssertEqual(TerminalTabs.state(agent: .working, kind: .card, card: c, phase: nil, question: .choice).1, "Asks you")
    }

    func testNewOutputIsMarkedUntilTheTabIsSelected() {
        var unread = TerminalUnread()
        unread.observe([agent("a", .working, cwd: repo, title: "a", seq: 1), agent("b", .working, cwd: repo, title: "b", seq: 5)], selected: "a")
        XCTAssertEqual(unread.panes, [], "a pane seen for the first time is not new")
        unread.observe([agent("a", .working, cwd: repo, title: "a", seq: 2), agent("b", .done, cwd: repo, title: "b", seq: 6)], selected: "a")
        XCTAssertEqual(unread.panes, ["b"], "the selected tab is being looked at")
        unread.observe([agent("a", .working, cwd: repo, title: "a", seq: 2), agent("b", .done, cwd: repo, title: "b", seq: 6)], selected: "b")
        XCTAssertEqual(unread.panes, [])
        unread.observe([agent("a", .idle, cwd: repo, title: "a", seq: 3)], selected: "b")
        XCTAssertEqual(unread.panes, ["a"])
        let tabs = TerminalTabs.make(agents: [agent("a", .idle, cwd: repo, title: "a")], pmPane: nil, card: { _ in nil }, phase: { _ in nil }, questions: [], unread: unread.panes)
        XCTAssertTrue(tabs[0].unread)
    }

    func testCommandDigitsPickTabsAndTheRailLetsGoOfThemThere() {
        let tabs = (1...11).map { TerminalTab(paneID: "p\($0)", sessionID: nil, kind: .card, label: "N\($0)", title: "", icon: .idle, stateLabel: "Idle") }
        XCTAssertEqual(TerminalTabs.tab(forDigit: 1, in: tabs)?.paneID, "p1")
        XCTAssertEqual(TerminalTabs.tab(forDigit: 9, in: tabs)?.paneID, "p9")
        XCTAssertNil(TerminalTabs.tab(forDigit: 10, in: tabs))
        XCTAssertNil(TerminalTabs.tab(forDigit: 0, in: tabs))
        XCTAssertNil(TerminalTabs.tab(forDigit: 3, in: Array(tabs.prefix(2))))
        XCTAssertFalse(ShellScreen.railShortcutsActive(on: .terminals))
        XCTAssertTrue(ShellScreen.railShortcutsActive(on: .tasks))
        XCTAssertEqual(ShellScreen.terminals.shortcutDigit, 3)
        XCTAssertEqual(ShellScreen.terminals.railSymbol, "terminal")
        XCTAssertEqual(ShellScreen(stored: "terminals"), .terminals, "the saved screen restores it")
    }

    func testTheRailDotShowsWhenATerminalAsks() {
        XCTAssertTrue(ShellScreen.terminals.railDot(current: .dashboard, unreadReply: false, terminalAsks: true))
        XCTAssertTrue(ShellScreen.terminals.railDot(current: .terminals, unreadReply: false, terminalAsks: true))
        XCTAssertFalse(ShellScreen.terminals.railDot(current: .dashboard, unreadReply: true, terminalAsks: false))
        XCTAssertFalse(ShellScreen.tasks.railDot(current: .dashboard, unreadReply: false, terminalAsks: true))
    }

    // MARK: message box

    private final class RecordingCommander: TerminalCommanding, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(String, String)] = []
        var fail = false
        var prompts: [(String, String)] { lock.lock(); defer { lock.unlock() }; return sent }
        func prompt(target: String, text: String) async throws {
            if fail { throw BackendError.notRunning("terminal is not running") }
            lock.lock(); sent.append((target, text)); lock.unlock()
        }
    }

    func testSendCallsPromptWithTheText() async {
        let commander = RecordingCommander()
        let failure = await TerminalComposer.send("  Rebase onto main\nthen run the tests  ", to: "w3:p1", commander: commander)
        XCTAssertNil(failure)
        XCTAssertEqual(commander.prompts.map(\.0), ["w3:p1"])
        XCTAssertEqual(commander.prompts.map(\.1), ["Rebase onto main\nthen run the tests"], "trimmed, the line break kept")
        let empty = await TerminalComposer.send(" \n ", to: "w3:p1", commander: commander)
        XCTAssertNotNil(empty)
        XCTAssertEqual(commander.prompts.count, 1, "nothing is sent for an empty box")
        commander.fail = true
        let failed = await TerminalComposer.send("hello", to: "w3:p1", commander: commander)
        XCTAssertTrue(failed?.contains("Could not send") == true, failed ?? "")
    }

    func testTheBoxSaysWhyItCannotSend() {
        let tab = TerminalTab(paneID: "p1", sessionID: nil, kind: .card, label: "N1", title: "", icon: .idle, stateLabel: "")
        XCTAssertNil(TerminalComposer.disabledReason(agents: .available([agent("p1", .idle, cwd: repo, title: "")]), tab: tab))
        XCTAssertEqual(TerminalComposer.disabledReason(agents: .unavailable("terminal is not running."), tab: tab), "The terminal backend cannot be reached: terminal is not running.")
        XCTAssertEqual(TerminalComposer.disabledReason(agents: .available([]), tab: tab), "This terminal is gone.")
        XCTAssertNotNil(TerminalComposer.disabledReason(agents: .loading, tab: tab))
        XCTAssertFalse(TerminalComposer.canSend(text: "hi", reason: "gone", sending: false))
        XCTAssertFalse(TerminalComposer.canSend(text: "hi", reason: nil, sending: true))
        XCTAssertFalse(TerminalComposer.canSend(text: "  ", reason: nil, sending: false))
        XCTAssertTrue(TerminalComposer.canSend(text: "hi", reason: nil, sending: false))
        XCTAssertEqual(TerminalComposer.placeholder(tab), "Message N1 — what should it do next?")
    }

    func testFindShowsOnlyTheLinesThatHoldTheWord() {
        let screen = "● Bash swift test\n  ⎿ Executed 14 tests\n● Write PTYSession.swift"
        XCTAssertEqual(TerminalComposer.filter(screen, query: "swift"), "● Bash swift test\n● Write PTYSession.swift")
        XCTAssertEqual(TerminalComposer.filter(screen, query: "EXECUTED"), "  ⎿ Executed 14 tests")
        XCTAssertEqual(TerminalComposer.filter(screen, query: " "), screen)
    }

    // MARK: ⌘F find, ⇧⌘F filter (N256)

    func testTheFilterIsShiftCommandFAndFindIsCommandF() {
        XCTAssertEqual(TerminalFindKeys.filter.key, KeyEquivalent("f"))
        XCTAssertEqual(TerminalFindKeys.filter.modifiers, [.command, .shift])
        XCTAssertEqual(TerminalFindKeys.filter.label, "⇧⌘F")
        XCTAssertEqual(TerminalFindKeys.find.key, KeyEquivalent("f"))
        XCTAssertEqual(TerminalFindKeys.find.modifiers, .command)
        XCTAssertEqual(TerminalFindKeys.find.label, "⌘F")
        XCTAssertNotEqual(TerminalFindKeys.filter.modifiers, TerminalFindKeys.find.modifiers, "the two keys never collide")
        XCTAssertTrue(TerminalFindKeys.filterHelp.contains("⇧⌘F"), "the tooltip names the new key")
        XCTAssertFalse(TerminalFindKeys.filterHelp.contains(" ⌘F"))
    }

    func testCommandFOpensTheFocusedPanesFindBarAndNothingWithoutOne() {
        XCTAssertEqual(TerminalFindKeys.route(focusedTerminal: "w5:p1", live: true, filtering: false), .openFind(endFilter: false))
        XCTAssertEqual(TerminalFindKeys.route(focusedTerminal: "w5:p1", live: true, filtering: true), .openFind(endFilter: true),
                       "a running filter ends so the live terminal and its bar show")
        XCTAssertEqual(TerminalFindKeys.route(focusedTerminal: nil, live: true, filtering: false), .none, "no pane focused: nothing")
        XCTAssertEqual(TerminalFindKeys.route(focusedTerminal: "w5:p1", live: false, filtering: true), .none, "polled text has no find bar")
    }

    /// Inside a terminal, the terminal's own monitor still answers ⌘F (N252) and leaves ⇧⌘F to the toolbar's Filter.
    func testInsideATerminalCommandFIsTheFindBarAndShiftCommandFIsLeftToTheFilter() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = LiveTerminalNSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        defer { view.find.close(); window.orderOut(nil) }
        window.makeFirstResponder(view)
        func press(_ key: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 3))
        }
        XCTAssertFalse(view.findKey(try press("F", [.command, .shift])), "⇧⌘F goes on to the toolbar's Filter")
        XCTAssertFalse(view.find.isOpen)
        XCTAssertTrue(view.findKey(try press("f", .command)))
        XCTAssertTrue(view.find.isOpen)
    }

    // MARK: typing hold

    func testWhileTheUserTypesPanelPromptsToThatAgentWait() async {
        let box = PanelOutbox()
        box.add("Panel: N1 is ready for review.", pane: "pm")
        box.typingPane = "pm"
        var sent: [String] = []
        await box.deliver(agents: [agent("pm", .idle, cwd: repo, title: "pm")], send: { item, _ in sent.append(item.text) }, dropped: { _ in })
        XCTAssertEqual(sent, [], "held while the message box has the focus")
        box.typingPane = "other"
        await box.deliver(agents: [agent("pm", .idle, cwd: repo, title: "pm")], send: { item, _ in sent.append(item.text) }, dropped: { _ in })
        XCTAssertEqual(sent, ["Panel: N1 is ready for review."], "another pane's box does not hold it")
    }

    func testTheModelPassesTheTypingPaneToTheOutboxAndTheInbox() async {
        let model = await terminalsModel()
        model.setTerminalTyping("w3:p1")
        XCTAssertEqual(model.outbox.typingPane, "w3:p1")
        XCTAssertEqual(model.inbox.typingPane, "w3:p1")
        model.setTerminalTyping(nil)
        XCTAssertNil(model.outbox.typingPane)
        XCTAssertNil(model.inbox.typingPane)
    }

    // MARK: one input (N234)

    func testTheTypingHoldFollowsTheLastKeyAndThePromptBox() {
        XCTAssertEqual(TerminalKeyboard.typingPane(held: "w3:p1", promptTerminal: nil, promptHasKeys: false), "w3:p1", "a key went to the terminal")
        XCTAssertNil(TerminalKeyboard.typingPane(held: nil, promptTerminal: nil, promptHasKeys: false), "nothing typed: prompts go out")
        XCTAssertEqual(TerminalKeyboard.typingPane(held: nil, promptTerminal: "w4:p1", promptHasKeys: true), "w4:p1", "the ⌘L box holds its terminal")
        XCTAssertNil(TerminalKeyboard.typingPane(held: nil, promptTerminal: "w4:p1", promptHasKeys: false), "an open box without the keys holds nothing")
        XCTAssertEqual(TerminalKeyboard.paneText(focused: true, prompt: false), "Keyboard → this terminal")
        XCTAssertEqual(TerminalKeyboard.paneText(focused: true, prompt: true), "Keyboard → prompt box")
        XCTAssertEqual(TerminalKeyboard.paneText(focused: false, prompt: true), "Click to type here")
        XCTAssertEqual(TerminalKeyboard.owner(label: "N302", pane: 2, panes: 2, prompt: false), "N302 terminal · pane 2")
        XCTAssertEqual(TerminalKeyboard.owner(label: "N302", pane: 1, panes: 1, prompt: false), "N302 terminal")
        XCTAssertEqual(TerminalKeyboard.owner(label: "N302", pane: 2, panes: 2, prompt: true), "the prompt box (N302)")
    }

    // MARK: typing hold (N245)

    func testAFocusedTerminalDoesNotHoldUntilAKeyIsTypedInAKeyWindow() {
        let watch = TerminalKeyWatch()
        var changes = 0
        watch.onChange = { changes += 1 }
        watch.terminalWithKeys = "w3:p1"
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(watch.active(at: t0), "the terminal has the keyboard but nobody typed")
        watch.windowChanged(isKey: false)
        watch.noteKey(windowIsKey: false, now: t0)
        XCTAssertNil(watch.active(at: t0), "a key while the window is not key holds nothing")
        watch.windowChanged(isKey: true)
        watch.noteKey(windowIsKey: true, now: t0)
        XCTAssertEqual(watch.active(at: t0), "w3:p1")
        XCTAssertEqual(watch.active(at: t0.addingTimeInterval(4.9)), "w3:p1", "held for about 5 s")
        XCTAssertNil(watch.active(at: t0.addingTimeInterval(5.1)), "then let go")
        watch.noteKey(windowIsKey: true, now: t0.addingTimeInterval(6))
        XCTAssertEqual(watch.active(at: t0.addingTimeInterval(7)), "w3:p1", "a new key holds again")
        watch.windowChanged(isKey: false)
        XCTAssertNil(watch.active(at: t0.addingTimeInterval(7)), "the window resigned key: cleared at once")
        watch.windowChanged(isKey: true)
        XCTAssertNil(watch.active(at: t0.addingTimeInterval(7)), "and not back when the window returns")
        XCTAssertGreaterThan(changes, 0, "the screen is told")
    }

    func testNoKeyHoldsWithoutATerminalHavingTheKeyboard() {
        let watch = TerminalKeyWatch()
        watch.noteKey(windowIsKey: true)
        XCTAssertNil(watch.active(), "the keys went to the ⌘L box or Find")
        watch.terminalWithKeys = "p1"
        watch.noteKey(windowIsKey: true)
        XCTAssertEqual(watch.active(), "p1")
        watch.terminalWithKeys = nil
        watch.clearHold()
        XCTAssertNil(watch.active(), "the terminal let go of the keyboard")
    }

    func testTheHoldReachesPanelPromptsOnlyWhileTyping() async {
        let model = await terminalsModel()
        let watch = TerminalKeyWatch()
        watch.terminalWithKeys = "w3:p1"
        let t0 = Date()
        watch.noteKey(windowIsKey: true, now: t0)
        model.setTerminalTyping(TerminalKeyboard.typingPane(held: watch.active(at: t0), promptTerminal: nil, promptHasKeys: false))
        XCTAssertEqual(model.outbox.typingPane, "w3:p1")
        model.setTerminalTyping(TerminalKeyboard.typingPane(held: watch.active(at: t0.addingTimeInterval(6)), promptTerminal: nil, promptHasKeys: false))
        XCTAssertNil(model.outbox.typingPane)
    }

    // MARK: labels (N245)

    func testPolledPanesSayWhereToWriteInsteadOfClaimingKeystrokes() {
        XCTAssertEqual(TerminalKeyboard.paneText(focused: true, prompt: false, live: false), "Use ⌘L to send")
        XCTAssertEqual(TerminalKeyboard.paneText(focused: false, prompt: false, live: false), "Use ⌘L to send")
        XCTAssertEqual(TerminalKeyboard.paneText(focused: true, prompt: false, live: true), "Keyboard → this terminal")
        XCTAssertEqual(TerminalKeyboard.paneText(focused: true, prompt: true, live: false), "Keyboard → prompt box", "the box has the keys")
        XCTAssertEqual(TerminalKeyboard.barLead(prompt: false, live: true), "Keystrokes go to ")
        XCTAssertEqual(TerminalKeyboard.barLead(prompt: false, live: false), "Use ⌘L to send to ")
        XCTAssertEqual(TerminalKeyboard.barLead(prompt: true, live: false), "Keystrokes go to ")
    }

    // MARK: drag and drop (N245)

    func testADropAndACancelBothClearTheDropZoneAtOnce() {
        let state = TerminalDropState()
        let target = TerminalDropTarget(pane: 3, zone: .left)
        state.begin("w4:p1")
        state.enter(target)
        XCTAssertEqual(state.target, target)
        state.finish()
        XCTAssertNil(state.target, "dropped")
        XCTAssertNil(state.dragging)
        state.update(target)
        XCTAssertNil(state.target, "an update that arrives after the drop lights nothing")
        XCTAssertFalse(state.isDragging)
        state.begin("w4:p1")
        state.enter(target)
        state.cancel()
        XCTAssertNil(state.target, "cancelled")
        XCTAssertNil(state.dragging, "the dragged row is forgotten")
        state.begin("w4:p1")
        state.enter(target)
        state.leave(pane: 3)
        XCTAssertNil(state.target, "the pointer left the pane")
        XCTAssertEqual(state.dragging, "w4:p1")
    }

    func testADragNobodyEndedIsLetGoOfWhenTheButtonIsUp() {
        let state = TerminalDropState()
        state.begin("w4:p1")
        state.enter(TerminalDropTarget(pane: 1, zone: .center))
        state.settle(buttonDown: true)
        state.settle(buttonDown: false)
        XCTAssertNotNil(state.target, "once is not enough")
        state.settle(buttonDown: true)
        state.settle(buttonDown: false)
        XCTAssertNotNil(state.target)
        state.settle(buttonDown: false)
        XCTAssertNil(state.target)
        XCTAssertNil(state.dragging)
    }

    func testOnlyARowDraggedFromTheSidebarLightsAZone() {
        let state = TerminalDropState()
        state.enter(TerminalDropTarget(pane: 1, zone: .center))
        XCTAssertNil(state.target, "text dragged from another app: no row was dragged")
        XCTAssertNil(state.dragging)
    }

    // MARK: accessibility and saved panes (N245)

    func testDividersHaveTheirOwnWordsAndSteps() {
        XCTAssertEqual(TerminalDividerAccessibility.label(axis: .row), "Divider between the left and right panes")
        XCTAssertEqual(TerminalDividerAccessibility.label(axis: .column), "Divider between the top and bottom panes")
        XCTAssertEqual(TerminalDividerAccessibility.value(ratio: 0.5), "50 percent")
        XCTAssertEqual(TerminalDividerAccessibility.adjusted(0.5, steps: 1), 0.55, accuracy: 0.0001)
        XCTAssertEqual(TerminalDividerAccessibility.adjusted(0.5, steps: -1), 0.45, accuracy: 0.0001)
        XCTAssertEqual(TerminalDividerAccessibility.adjusted(0.78, steps: 1), 0.8, accuracy: 0.0001, "kept between 20 and 80 %")
        XCTAssertEqual(TerminalDividerAccessibility.adjusted(0.22, steps: -1), 0.2, accuracy: 0.0001)
    }

    func testTheSavedPanesAreReadOnce() {
        let defaults = makeTestDefaults()
        TerminalPaneStore.save(defaults, project: "p", TerminalPaneLayout(terminal: "a"))
        let loader = SavedPanesLoader()
        XCTAssertEqual(loader.layout(defaults, project: "p")?.terminals, ["a"])
        TerminalPaneStore.save(defaults, project: "p", TerminalPaneLayout(terminal: "b"))
        XCTAssertEqual(loader.layout(defaults, project: "p")?.terminals, ["a"], "not read again on the next render")
        XCTAssertNil(SavedPanesLoader().layout(defaults, project: nil))
    }

    // MARK: the user's own shells (N245)

    func testNewShellTakesTheNextNumberOfAllTheDaemonsSessionsNotOnlyThisProjects() async throws {
        let dir = "/tmp/shl-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir + "/other", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/mine", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let client = TentacldClient(socketPath: dir + "/s.sock")
        let daemon = Process()
        daemon.executableURL = client.helper
        daemon.arguments = ["--socket", dir + "/s.sock"]
        try daemon.run()
        defer { daemon.terminate(); daemon.waitUntilExit() }
        for _ in 0..<100 where await !client.ping() { try await Task.sleep(nanoseconds: 50_000_000) }
        // An alive shell of another project holds my-shell-1.
        try await client.spawn(id: "my-shell-1", argv: ["/bin/sh", "-c", "sleep 30"], cwd: dir + "/other")
        let id = try await TerminalShells.open(client: client, cwd: dir + "/mine", argv: ["/bin/sh", "-c", "sleep 30"])
        XCTAssertEqual(id, "my-shell-2")
        let sessions = try await client.list()
        XCTAssertEqual(sessions.first { $0.id == "my-shell-2" }?.cwd, dir + "/mine")
        XCTAssertTrue(sessions.first { $0.id == "my-shell-2" }?.alive == true)
        // Another window took the number between the list and the spawn: the next one is tried.
        let again = try await TerminalShells.open(client: client, cwd: dir + "/mine", argv: ["/bin/sh", "-c", "sleep 30"], listed: { ["my-shell-1"] })
        XCTAssertEqual(again, "my-shell-3", "my-shell-2 is running: one more try")
        for id in ["my-shell-1", "my-shell-2", "my-shell-3"] { try await client.kill(id: id) }
    }

    func testTheUsersShellGetsItsOwnNameAndIsNeverAnAgent() {
        XCTAssertEqual(TerminalShells.nextID(existing: ["a", "b"]), "my-shell-1")
        XCTAssertEqual(TerminalShells.nextID(existing: ["my-shell-1", "my-shell-3"]), "my-shell-2")
        XCTAssertTrue(TerminalShells.isUserShell("my-shell-2"))
        XCTAssertFalse(TerminalShells.isUserShell("dev-n245-agent-panel"))
        XCTAssertEqual(TerminalShells.argv(shell: "/bin/fish"), ["/bin/fish", "-l"])
        XCTAssertEqual(TerminalShells.argv(shell: ""), ["/bin/zsh", "-l"])
        let tabs = TerminalTabs.make(agents: [agent("my-shell-2", .idle, cwd: repo, title: "my-shell-2")], pmPane: nil, card: { _ in nil }, phase: { _ in nil }, questions: [])
        XCTAssertEqual(tabs.first?.title, "Shell 2")
        XCTAssertEqual(tabs.first?.kind, .shell)
        XCTAssertEqual(tabs.first?.mine, true)
    }

    func testClosingAShellAsksOnceThenKillsTheSession() {
        let closer = ShellCloser()
        var killed: [String] = []
        closer.kill = { killed.append($0) }
        closer.request("my-shell-1")
        XCTAssertEqual(closer.pending, "my-shell-1")
        XCTAssertEqual(killed, [], "nothing ends before the answer")
        closer.cancel()
        XCTAssertNil(closer.pending)
        XCTAssertEqual(killed, [])
        closer.request("my-shell-2")
        closer.confirm("my-shell-2")
        XCTAssertNil(closer.pending)
        XCTAssertEqual(killed, ["my-shell-2"], "killed once")
    }

    func testTheLiveTerminalSaysWhenItGetsAndLosesTheKeyboard() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = LiveTerminalNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let other = NSTextField(frame: CGRect(x: 0, y: 200, width: 100, height: 20))
        var seen: [Bool] = []
        view.onFocus = { seen.append($0) }
        window.contentView?.addSubview(view)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(view)
        XCTAssertEqual(seen, [true])
        window.makeFirstResponder(other)
        XCTAssertEqual(seen, [true, false])
        window.makeFirstResponder(view)
        view.removeFromSuperview()
        XCTAssertEqual(seen, [true, false, true, false], "a terminal that leaves the window lets go of the keyboard")
    }

    func testTheSidebarGroupsTheTerminalsAndShowsTheirPanes() {
        func tab(_ pane: String, _ kind: TerminalTab.Kind, _ label: String) -> TerminalTab {
            TerminalTab(paneID: pane, sessionID: nil, kind: kind, label: label, title: "t", icon: .idle, stateLabel: "Idle")
        }
        let tabs = [tab("pm", .pm, "PM"), tab("p9", .card, "N9"), tab("p10", .card, "N10"), tab("sh", .shell, "shell")]
        let groups = TerminalSidebarGroups.make(tabs)
        XCTAssertEqual(groups.map(\.name), ["PM", "CARDS", "SHELLS"])
        XCTAssertEqual(groups[1].tabs.map(\.label), ["N9", "N10"], "the order of TerminalTabs.make")
        XCTAssertEqual(TerminalSidebarGroups.make(Array(tabs.dropFirst())).map(\.name), ["CARDS", "SHELLS"], "an empty group is left out")
        XCTAssertEqual(TerminalSidebarGroups.help(tabs[1], digit: 2), "N9 · Idle · ⌘2")
        XCTAssertEqual(TerminalSidebarGroups.help(tabs[1], digit: 10), "N9 · Idle")
        XCTAssertEqual(TerminalSidebarGroups.accessibilityLabel(tabs[1], pane: 2), "N9 t, Idle, in pane 2")
        var layout = TerminalPaneLayout(terminal: "p10")
        layout.drop("pm", on: 1, zone: .right)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.terminal, $0.number) }), ["p10": 1, "pm": 2], "the row's pane number")
    }

    // MARK: preview (N229)

    func testPreviewOpensOnlyForATerminalThatServesAPage() {
        let page = LocalPage(url: URL(string: "http://localhost:5173/")!, command: "npm run dev")
        XCTAssertTrue(TerminalPreview.toggled(open: false, page: page))
        XCTAssertFalse(TerminalPreview.toggled(open: false, page: nil), "⌘P does nothing without a page")
        XCTAssertFalse(TerminalPreview.toggled(open: true, page: page), "⌘P again closes it")
        XCTAssertNil(TerminalPreview.disabledReason(label: "N303", page: page))
        XCTAssertEqual(TerminalPreview.disabledReason(label: "N302", page: nil), "Preview needs a local page. N302\u{2019}s terminal serves none.")
        XCTAssertEqual(TerminalPreview.hint(label: "N302"), "Preview: N302 serves no local page")
        XCTAssertTrue(TerminalPreview.stays(open: true, page: page))
        XCTAssertFalse(TerminalPreview.stays(open: true, page: nil), "focus moved to a terminal without a page: Preview closes")
        XCTAssertEqual(TerminalPreview.closedNote(label: "N302"), "N302 has no local page · Preview closed")
    }

    func testClosingThePreviewGoesBackToTheTerminalWhenAPageWasFound() {
        let page = LocalPage(url: URL(string: "http://localhost:5173/")!, command: "npm run dev")
        XCTAssertEqual(PreviewClose.after(found: page), .terminal, "not the \"No local page found\" empty state")
        XCTAssertEqual(PreviewClose.after(found: nil), .empty)
    }

    func testATerminalWithALocalPageGetsAPortLabelThatStaysUntilTheTerminalCloses() {
        let watch = TerminalPageWatch()
        watch.update(pane: "p1", text: "> npm run dev\n  VITE v7.1.4  ready in 412 ms\n  ➜  Local:   http://localhost:5173/\n")
        watch.update(pane: "p2", text: "● Bash swift test\n  ⎿  Executed 14 tests")
        XCTAssertEqual(watch.pages["p1"], LocalPage(url: URL(string: "http://localhost:5173/")!, command: "npm run dev"))
        XCTAssertNil(watch.pages["p2"])
        XCTAssertEqual(TerminalPreview.port(watch.pages["p1"]!.url), ":5173")
        XCTAssertEqual(TerminalPreview.host(watch.pages["p1"]!.url), "localhost:5173")
        watch.update(pane: "p1", text: "● Update site/src/Hero.tsx (+24 −9)")
        XCTAssertNotNil(watch.pages["p1"], "the address scrolled off the screen; the page stays")
        watch.update(pane: "p1", text: "Local: http://localhost:3000/")
        XCTAssertEqual(watch.pages["p1"]?.url.port, 3000, "a newer address replaces it")
        watch.keep(["p2"])
        XCTAssertNil(watch.pages["p1"], "a closed terminal drops its page")
    }

    func testLocalPagesListEveryPageInTabOrder() {
        func tab(_ pane: String, _ label: String) -> TerminalTab {
            TerminalTab(paneID: pane, sessionID: nil, kind: .card, label: label, title: "t", icon: .idle, stateLabel: "Idle", cardID: label)
        }
        let a = LocalPage(url: URL(string: "http://localhost:5173/")!, command: "npm run dev")
        let b = LocalPage(url: URL(string: "http://localhost:3000/")!, command: nil)
        let rows = TerminalPreview.rows(tabs: [tab("p1", "N1"), tab("p2", "N2"), tab("p3", "N3")], pages: ["p3": b, "p1": a, "gone": b])
        XCTAssertEqual(rows.map(\.label), ["N1", "N3"], "in the sidebar's order; a page of a terminal that is not open is not listed")
        XCTAssertEqual(rows.first?.page.command, "npm run dev")
    }

    func testPickNotesAndConsoleErrorsAreAppendedToTheCardsFixNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n229-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = dir.appendingPathComponent("N9.md")
        try "---\nid: N9\nproject: p\nstatus: doing\n---\n# N9 · T\n\n## Report\n\n## Fix notes\n- The PM: keep the old header\n\n## Decision\n".write(to: card, atomically: true, encoding: .utf8)
        let page = URL(string: "http://localhost:5173/settings")!
        try PreviewNote.append(PreviewNote.line(url: page, selector: "button.btn-primary", note: "Button sticks to the field"), toCardAt: card)
        let console = [PreviewConsoleLine(level: .error, text: "GET /api/currencies 404"), PreviewConsoleLine(level: .warn, text: "slow"),
                       PreviewConsoleLine(level: .error, text: "TypeError: list.map is not a function\n    at settings.tsx:31"),
                       PreviewConsoleLine(level: .error, text: "GET /api/currencies 404")]
        let errors = try XCTUnwrap(PreviewNote.consoleLines(url: page, console: console))
        XCTAssertEqual(errors, "- http://localhost:5173/settings console: GET /api/currencies 404\n- http://localhost:5173/settings console: TypeError: list.map is not a function",
                       "errors only, once each, first line")
        XCTAssertNil(PreviewNote.consoleLines(url: page, console: [PreviewConsoleLine(level: .warn, text: "slow")]))
        try PreviewNote.append(errors, toCardAt: card)

        let items = FixNotes.items(cardAt: card)
        XCTAssertEqual(items.map(\.kind), [.text, .element, .console, .console])
        XCTAssertEqual(items[0].text, "The PM: keep the old header")
        XCTAssertEqual(items[1].place, "button.btn-primary")
        XCTAssertEqual(items[1].text, "Button sticks to the field")
        XCTAssertEqual(items[3].text, "TypeError: list.map is not a function")
        XCTAssertTrue(try String(contentsOf: card, encoding: .utf8).contains("status: doing"), "the status stays")
    }

    // MARK: snapshots

    /// The demo cards with agents in the project's own folder, plus a shell, so every kind of tab shows.
    private func terminalsModel(shells: [String] = []) async -> PanelModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-terminals-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = """
        {"id":"demo","name":"Demo App","repoPath":"\(repo)","dataDir":"\(DemoSupport.demoDir.appendingPathComponent("data").path)","maxParallel":4,"sharedFiles":[]}
        """
        try? project.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try? "{\"projects\":[\"\(dir.appendingPathComponent("project.json").path)\"]}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let list = [agent("w2:pA", .idle, cwd: repo, title: "pm-demo", seq: 1),
                    agent("w3:p1", .working, cwd: repo + "/.agent-worktrees/feat-b3-a11y", title: "dev-1 · B3", seq: 1),
                    agent("w5:p1", .working, cwd: repo + "/.agent-worktrees/fix-a5-widget", title: "dev-4 · A5", seq: 1),
                    agent("w4:p1", .blocked, cwd: repo + "/.agent-worktrees/docs-a4-open-items", title: "dev-2 · A4", seq: 1),
                    agent("w6:p1", .idle, cwd: repo, title: "zsh ~/demo", seq: 1)]
            + shells.map { agent($0, .idle, cwd: repo, title: "zsh", seq: 1) }
        let model = PanelModel(settingsURL: dir.appendingPathComponent("settings.json"), makeTerminal: { FakeTerminal(agentsResult: .success(list)) }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() }, log: ActionLog(fileURL: dir.appendingPathComponent("actions.log")),
                               writer: DemoCardWriter(), defaults: makeTestDefaults(), roleStore: RoleStore(baseDir: dir.appendingPathComponent("roles")))
        await model.reload()
        return model
    }

    private let screens: [String: String] = [
        "w5:p1": """
        > Read tasks/A5.md and start. Card: Widget refresh.

        ● Read app/Widget/WidgetProvider.swift
          ⎿  Read 182 lines
        ● Update app/Widget/WidgetProvider.swift  (+24 −9)
          ⎿  timeline reloads every 15 minutes, placeholder kept
        ● Bash  xcodebuild test -only-testing:WidgetTests
          ⎿  Executed 14 tests, with 0 failures

        ✻ Checking the lock screen sizes… (3m 12s · ↓ 8.1k tokens)
        """,
        "w4:p1": """
        ● The card leaves the default window open.

          Which window should the usage meter show first?

          ❯ 1. 5-hour window
            2. 7-day window
            3. Both
        """,
        "w3:p1": """
        ● Bash  swift test --filter AccessibilityTests
          ⎿  Executed 6 tests, with 1 failure
        ● The VoiceOver label of the gauge is still empty.
        ✻ Fixing the gauge label… (1m 40s)
        """,
    ]

    private func render(_ view: some View, name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 900)))
        XCTAssertGreaterThan(data.count, 40_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    private func window(_ model: PanelModel, _ content: some View) -> some View {
        HStack(spacing: 0) {
            Rail(screen: .terminals, terminalAsks: true, onSelect: { _ in })
            Divider().overlay(Tok.line)
            content
        }
        .background(Tok.bg)
    }

    /// Two terminals side by side: A5 left, A4 (asking) right and focused.
    private var twoPanes: TerminalPaneLayout {
        var l = TerminalPaneLayout(terminal: "w5:p1")
        l.drop("w4:p1", on: 1, zone: .right)
        return l
    }

    private var fourPanes: TerminalPaneLayout {
        var l = TerminalPaneLayout(terminal: "w2:pA")
        l.drop("w5:p1", on: 1, zone: .right)
        l.drop("w3:p1", on: 1, zone: .bottom)
        l.drop("w4:p1", on: l.pane(showing: "w5:p1")!.id, zone: .bottom)
        l.focus(l.pane(showing: "w5:p1")!.id)
        return l
    }

    func testSnapshotSingle() async throws {
        let model = await terminalsModel()
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: previewScreens, selected: "w5:p1", typing: "w5:p1")
        let tabs = TerminalTabs.make(agents: { if case .available(let l) = model.visibleAgents { l } else { [] } }(), pmPane: model.pmAgent(forProject: "demo")?.paneID,
                                     card: { model.card(of: $0) }, phase: { model.phase(of: $0) }, questions: [])
        XCTAssertEqual(tabs.first?.label, "PM")
        XCTAssertEqual(tabs.last?.label, "session")
        XCTAssertTrue(tabs.contains { $0.label == "A5" })
        try render(window(model, view), name: "N234-single")
    }

    func testSnapshotTwoPanesWithTheAskDock() async throws {
        let model = await terminalsModel()
        let view = TerminalsView(model: model, fixedQuestions: [question("w4:p1", .choice, card: "A4")], fixedScreens: screens, panes: twoPanes, typing: "w4:p1")
        try render(window(model, view), name: "N234-two")
    }

    func testSnapshotFourPanes() async throws {
        let model = await terminalsModel()
        let view = TerminalsView(model: model, fixedQuestions: [question("w4:p1", .choice, card: "A4")], fixedScreens: previewScreens, panes: fourPanes, typing: "w5:p1")
        try render(window(model, view), name: "N234-four")
    }

    func testSnapshotDropZone() async throws {
        let model = await terminalsModel()
        let layout = twoPanes
        let target = TerminalDropTarget(pane: layout.pane(showing: "w4:p1")!.id, zone: layout.accepted(.bottom, on: layout.pane(showing: "w4:p1")!.id))
        XCTAssertEqual(target.zone, .bottom, "a second row is allowed")
        XCTAssertEqual(layout.accepted(.right, on: target.pane), .center, "a third column is not: the edge does not light up")
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: layout, drop: target)
        try render(window(model, view), name: "N234-drop-zone")
    }

    func testSnapshotPromptBox() async throws {
        let model = await terminalsModel()
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes,
                                 typing: "w4:p1", prompt: "Use the 7-day window first.\nThen run the widget tests again and report.")
        try render(window(model, view), name: "N234-prompt")
    }

    /// The toolbar's Filter button with ⇧⌘F and the key list that names ⌘F find (N256).
    func testSnapshotFilterButton() async throws {
        let model = await terminalsModel()
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes, typing: "w4:p1")
        try render(window(model, view), name: "N256-filter")
    }

    /// Broadcast on (N271): the banner, the Stop button and the marks on the panes (two shells ticked, the agent left out).
    func testSnapshotBroadcast() async throws {
        let model = await terminalsModel(shells: ["my-shell-1", "my-shell-2"])
        var layout = TerminalPaneLayout(terminal: "my-shell-1")
        layout.drop("my-shell-2", on: 1, zone: .right)
        layout.drop("w5:p1", on: 2, zone: .bottom)
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: layout, typing: "my-shell-1", broadcast: true)
        try render(window(model, view), name: "N271-broadcast")
    }

    /// Saved commands (N272): the list as the panel shows it.
    func testSnapshotSnippets() async throws {
        let model = await terminalsModel(shells: ["my-shell-1"])
        let store = TerminalSnippetStore(defaults: model.defaults)
        store.add(name: "Run tests", text: "bash tests/run.sh", runAtOnce: true, to: .project("demo"))
        store.add(name: "Git status", text: "git status -sb", runAtOnce: false, to: .project("demo"))
        store.add(name: "Tail log", text: "tail -f ~/Library/Logs/app.log", runAtOnce: true, to: .project("demo"))
        let panel = TerminalSnippetsPanel(store: store, project: "demo", promptText: "swift build 2>&1 | tail", canSend: true) { _ in }
            .background(Tok.pane).environment(\.snapshotMode, true)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: panel.padding(24).background(Tok.bg), size: CGSize(width: 428, height: 300)))
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N272-snippets.png")) }
    }

    /// A shell that came back after a restart: its saved text dimmed above it, under "Restored from … · Clear" (N273).
    func testSnapshotRestoredShell() async throws {
        let model = await terminalsModel(shells: ["my-shell-1"])
        let restored = RestoredShells()
        let text = (1...8).map { "build step \($0) ok" }.joined(separator: "\n") + "\n~/demo % swift test\nExecuted 42 tests, with 0 failures"
        restored.set("my-shell-1", RestoredHistory(text: text, saved: Date(timeIntervalSince1970: 1_792_000_000), cwd: "/tmp"))
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: TerminalPaneLayout(terminal: "my-shell-1"), selected: "my-shell-1", restoredShells: restored)
        try render(window(model, view), name: "N273-restore")
    }

    func testSnapshotPreviewDisabled() async throws {
        let model = await terminalsModel()
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: previewScreens, selected: "w3:p1")
        try render(window(model, view), name: "N234-preview-disabled")
    }

    func testSnapshotSidebarCollapsed() async throws {
        let model = await terminalsModel()
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes, sidebarCollapsed: true)
        try render(window(model, view), name: "N234-sidebar-collapsed")
    }

    /// A5's terminal runs a dev server (N229).
    private var previewScreens: [String: String] {
        var s = screens
        s["w5:p1"] = """
        > Read tasks/A5.md and start. Card: Widget refresh.

        ● Bash  npm run dev --prefix site  (background)
          ⎿  VITE v7.1.4  ready in 412 ms
          ⎿  ➜  Local:   http://localhost:5173/
        ● Update site/src/Hero.tsx  (+24 −9)
          ⎿  hero copy, CTA button, three feature tiles
        ● Update site/src/hero.css  (+11 −3)

        ✻ Styling the hero button… (6m 40s · ↓ 12.4k tokens)
        """
        return s
    }

    func testSnapshotTerminalAndPreview() async throws {
        let model = await terminalsModel()
        let preview = PreviewModel(url: URL(string: "http://localhost:5173/"), picking: true)
        preview.record(PreviewConsoleLine(level: .error, text: "GET /api/pricing 404"))
        preview.picked = PickedElement(selector: "a.cta", rect: CGRect(x: 22, y: 150, width: 172, height: 36))
        preview.note = "Button needs more contrast on hover"
        let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: previewScreens, selected: "w5:p1", preview: true, fixedPreview: preview)
        try render(window(model, view), name: "N234-preview")
    }

    // MARK: appearance (N236)

    func testThePolledTextUsesTheTerminalsFontColorsAndPadding() {
        let d = TerminalAppearance.default.polledText
        XCTAssertEqual(d.font.pointSize, 12)
        XCTAssertEqual(d.foreground, Tok.Hex.ink)
        XCTAssertEqual(d.padding, 16)
        var a = TerminalAppearance()
        a.followApp = false; a.theme = .dracula; a.font = .menlo; a.size = 16; a.padding = .roomy
        let p = a.polledText
        XCTAssertEqual(p.font.fontName, "Menlo-Regular")
        XCTAssertEqual(p.font.pointSize, 16)
        XCTAssertEqual(p.foreground, 0xF8F8F2)
        XCTAssertEqual(p.padding, 26)
    }

    func testSnapshotFourPanesDracula() async throws {
        let model = await terminalsModel()
        model.terminalAppearance.appearance.followApp = false; model.terminalAppearance.appearance.theme = .dracula
        model.terminalAppearance.appearance.font = .menlo
        model.terminalAppearance.appearance.size = 13
        let view = TerminalsView(model: model, fixedQuestions: [question("w4:p1", .choice, card: "A4")], fixedScreens: previewScreens, panes: fourPanes, typing: "w5:p1")
        try render(window(model, view), name: "N236-four-dracula")
    }

    func testSnapshotTwoPanesOneLightWithThePanel() async throws {
        let model = await terminalsModel()
        model.terminalAppearance.appearance.followApp = false; model.terminalAppearance.appearance.theme = .oneLight
        model.terminalAppearance.appearance.padding = .roomy
        let view = TerminalsView(model: model, fixedQuestions: [question("w4:p1", .choice, card: "A4")], fixedScreens: screens, panes: twoPanes, typing: "w4:p1")
        // The popover does not render offscreen: the panel is drawn where it opens, under the toolbar's "Aa".
        let shown = window(model, view).overlay(alignment: .topTrailing) {
            AppearancePanel(store: model.terminalAppearance).clipShape(RoundedRectangle(cornerRadius: Tok.radius))
                .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line)).shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                .padding(.top, 50).padding(.trailing, 150)
        }
        try render(shown, name: "N236-two-onelight-panel")
    }

    // MARK: label snapshots (N245)

    func testSnapshotLabelsLivePolledAndPromptBox() async throws {
        let model = await terminalsModel()
        try render(window(model, TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes, typing: "w4:p1", keysLive: true)), name: "N245-labels-live")
        try render(window(model, TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes, keysLive: false)), name: "N245-labels-polled")
        try render(window(model, TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes, typing: "w4:p1", prompt: "Use the 7-day window first.", keysLive: true)),
                   name: "N245-labels-prompt")
    }

    // MARK: keyboard and hit areas (N266)

    private func until(_ done: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The test host's windows are not always key (another app is in front); SwiftUI moves focus only in a key window, as in the app.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    private func host(_ view: some View, size: NSSize) -> NSWindow {
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
    }

    /// The filter field when it has the keyboard: the window's field editor works for it.
    private func filterField(_ window: NSWindow) -> NSTextField? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField,
              field.placeholderString == "Filter the focused pane" else { return nil }
        return field
    }

    /// ⇧⌘F (and the Filter button) opens the filter with the keyboard in it: the next keys filter at once. The screen starts with the filter
    /// open, the state ⇧⌘F leaves (its key is checked above; a synthetic ⇧⌘F also matches ⌘F in a test window).
    func testTheOpenFilterFieldHasTheKeyboard() async throws {
        let model = await terminalsModel()
        let socket = NSTemporaryDirectory() + "n266-no-daemon-\(UUID().uuidString).sock"
        let window = host(TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes, filter: "", socket: socket),
                          size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil) }
        await until { self.filterField(window) != nil }
        let field = try XCTUnwrap(filterField(window), "the filter field has the keyboard without a click")
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("usage", replacementRange: editor.selectedRange())
        await until { field.stringValue == "usage" }
        XCTAssertEqual(field.stringValue, "usage", "typing goes into the filter")
    }

    /// Every choice in the Aa panel takes a click anywhere on its tile, also on the empty edge beside the name (a clear background is
    /// no hit area by itself). Two columns are clicked top to bottom, 4 pt inside the panel's content edges, where no text is drawn.
    func testEveryAppearanceTileTakesAClickAnywhereOnIt() async throws {
        let store = TerminalAppearanceStore(defaults: makeTestDefaults(prefix: "n266-appearance"))
        let window = host(AppearancePanel(store: store), size: NSSize(width: 340, height: 600))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        let height = window.contentView?.bounds.height ?? 0
        func changed(_ base: TerminalAppearance, x: CGFloat) async -> Set<String> {
            var fields = Set<String>()
            for top in stride(from: CGFloat(0), to: height, by: 2) {
                store.appearance = base
                click(NSPoint(x: x, y: height - top), in: window)
                try? await Task.sleep(for: .milliseconds(3))
                let a = store.appearance
                if a.theme != base.theme { fields.insert("theme") }
                if a.font != base.font { fields.insert("font") }
                if a.size != base.size { fields.insert("size") }
                if a.cursor != base.cursor { fields.insert("cursor") }
                if a.blink != base.blink { fields.insert("blink") }
                if a.padding != base.padding { fields.insert("padding") }
            }
            return fields
        }
        // Nothing on the scanned edge is chosen at the start, so any click there that lands on a tile changes a field.
        var left = TerminalAppearance()
        left.followApp = false; left.theme = .dracula; left.font = .menlo; left.cursor = .underline; left.padding = .roomy
        var right = TerminalAppearance()
        right.followApp = false; right.theme = .tentacl; right.font = .sfMono; right.cursor = .block; right.padding = .compact
        let inset = Tok.Space.l + 4
        let leftFields = await changed(left, x: inset)
        let rightFields = await changed(right, x: 340 - inset)
        XCTAssertTrue(leftFields.isSuperset(of: ["theme", "font", "size", "cursor", "padding"]), "left edge: \(leftFields.sorted())")
        XCTAssertTrue(rightFields.isSuperset(of: ["theme", "font", "blink", "padding"]), "right edge: \(rightFields.sorted())")
    }

    // MARK: toolbar fit (N327)

    func testToolbarSplitsKeepTheOrderAndMoveTheRightOnesFirst() {
        let items = TerminalToolbarFit.items(panes: 2)
        XCTAssertEqual(items, [.prompt, .swap, .filter, .broadcast, .preview, .commands, .appearance, .backend])
        XCTAssertFalse(TerminalToolbarFit.items(panes: 1).contains(.swap), "Swap only with two panes")
        let splits = TerminalToolbarFit.splits(items)
        XCTAssertEqual(splits.count, items.count + 1)
        XCTAssertEqual(splits.first, .init(bar: items, menu: []), "wide: all in the bar, no menu")
        XCTAssertEqual(splits[2], .init(bar: Array(items.prefix(6)), menu: [.appearance, .backend]), "narrower: the right end goes first")
        XCTAssertEqual(splits.last, .init(bar: [], menu: items))
        for s in splits { XCTAssertEqual(s.bar + s.menu, items, "order kept") }
        let hints = TerminalToolbarFit.splits(TerminalToolbarFit.hints)
        XCTAssertEqual(hints[1].menu, ["⌘F find · ⇧⌘F filter"], "the bottom bar drops whole hints from the right")
    }

    /// F1: a key is registered once, by the hidden shortcut group; a "…" item shows its key as text only.
    func testMenuItemsShowTheKeyAndRegisterNone() throws {
        XCTAssertEqual(TerminalToolbarFit.menuTitle("Commands", key: "⌥⌘S"), "Commands   ⌥⌘S")
        XCTAssertEqual(TerminalToolbarFit.menuTitle("Swap 1 ⇄ 2", key: ""), "Swap 1 ⇄ 2")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentPanel/Views/TerminalsView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func menuItem("))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        XCTAssertFalse(source[start.lowerBound..<end.lowerBound].contains(".keyboardShortcut"), "a \"…\" item registers a key a second time")
        let group = try XCTUnwrap(source.range(of: "private func shortcuts("))
        XCTAssertTrue(source[group.upperBound...].prefix(600).contains("keyboardShortcut(key)"), "the hidden group owns the toolbar keys")
    }

    func testSnapshotsOfTheToolbarAtFourWidths() async throws {
        let model = await terminalsModel()
        for width in [1440, 1100, 900, 760] as [CGFloat] {
            let view = TerminalsView(model: model, fixedQuestions: [], fixedScreens: screens, panes: twoPanes, typing: "w4:p1")
            let data = try XCTUnwrap(SnapshotRenderer.render(view: window(model, view), size: CGSize(width: width, height: 600)))
            XCTAssertGreaterThan(data.count, 20_000)
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N327-\(Int(width)).png")) }
        }
    }
}
