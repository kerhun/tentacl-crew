import SwiftUI

/// One terminal of the Terminals screen (N224, N234): a running agent of the selected project, a row in the sidebar.
struct TerminalTab: Identifiable, Equatable {
    enum Kind: Equatable { case pm, card, shell }
    /// The row's one state icon (States.dc.html).
    enum Icon: Equatable {
        /// The ring, filled by how far the card is through its steps.
        case working(Double)
        case asks, permission, done, idle, failed, shell, pm
    }

    let paneID: String
    let sessionID: String?
    let kind: Kind
    /// "PM", the card id, "session" for an agent session on no card, or "shell".
    let label: String
    let title: String
    let icon: Icon
    let stateLabel: String
    var cardID: String?
    /// The agent's one live line (N251); empty for the user's shell.
    var statusLine = ""
    /// New output since the terminal was last on screen.
    var unread = false
    /// `:5173` when the terminal shows a local page (N229).
    var port: String?
    var id: String { paneID }

    /// The user's own shell (N245), not an agent.
    var mine: Bool { TerminalShells.isUserShell(paneID) }
    var asks: Bool { icon == .asks || icon == .permission }
    var isWorking: Bool { if case .working = icon { true } else { false } }

    var color: Color {
        switch icon {
        case .working: Tok.work
        case .asks: Tok.askText
        case .permission: Tok.wait
        case .done: Tok.go
        case .idle, .shell: Tok.ink2
        case .failed: Tok.stop
        case .pm: Tok.you
        }
    }
}

/// The sidebar's rules (N224, N234): which agents get a row, in which order, with which icon.
enum TerminalTabs {
    /// The PM first, then the cards by id, then the sessions on no card by title.
    static func make(agents: [AgentStatus], pmPane: String?, card: (AgentStatus) -> TaskCard?, phase: (TaskCard) -> TaskPhase?,
                     questions: [PendingQuestion], unread: Set<String> = [], line: (AgentStatus) -> String = { _ in "" }) -> [TerminalTab] {
        var pm: [TerminalTab] = [], cards: [TerminalTab] = [], shells: [TerminalTab] = []
        for agent in agents {
            let question = questions.first { $0.paneID == agent.paneID }?.question.kind
            let plainTitle = agent.title.isEmpty ? agent.paneID : agent.title
            if agent.paneID == pmPane {
                let (icon, label) = state(agent: agent.state, kind: .pm, card: nil, phase: nil, question: question)
                pm.append(TerminalTab(paneID: agent.paneID, sessionID: agent.sessionID, kind: .pm, label: "PM", title: agent.name ?? plainTitle, icon: icon, stateLabel: label,
                                      statusLine: line(agent), unread: unread.contains(agent.paneID)))
            } else if let c = card(agent) {
                let p = phase(c)
                let (icon, label) = state(agent: agent.state, kind: .card, card: c, phase: p, question: question)
                cards.append(TerminalTab(paneID: agent.paneID, sessionID: agent.sessionID, kind: .card, label: c.id, title: AgentSummary.plainTitle(c.title, id: c.id),
                                         icon: icon, stateLabel: label, cardID: c.id, statusLine: line(agent), unread: unread.contains(agent.paneID)))
            } else {
                let (icon, label) = state(agent: agent.state, kind: .shell, card: nil, phase: nil, question: question)
                shells.append(TerminalTab(paneID: agent.paneID, sessionID: agent.sessionID, kind: .shell, label: agent.sessionID == nil ? "shell" : "session",
                                          title: TerminalShells.isUserShell(agent.paneID) ? TerminalShells.title(agent.paneID) : plainTitle, icon: icon, stateLabel: label,
                                          statusLine: TerminalShells.isUserShell(agent.paneID) ? "" : line(agent), unread: unread.contains(agent.paneID)))
            }
        }
        cards.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        shells.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return pm + cards + shells
    }

    /// The icon and the state's words: a question first (whoever asks), then an exited process, then the card's phase.
    static func state(agent: AgentState, kind: TerminalTab.Kind, card: TaskCard?, phase: TaskPhase?, question: AgentQuestion.Kind?) -> (TerminalTab.Icon, String) {
        switch question {
        case .permission?: return (.permission, "Needs permission")
        case .plan?: return (.permission, "Needs approval")
        case .choice?, .freeText?: return (.asks, "Asks you")
        case .signIn?: return (.failed, "Needs sign-in")
        case nil: break
        }
        if case .unknown = agent { return (.failed, "Exited") }
        switch kind {
        case .pm: return (.pm, agent == .working ? "PM working" : "PM")
        case .shell: return (.shell, agent == .working ? "Working" : "Shell")
        case .card:
            guard let phase else { return (.idle, "Idle") }
            switch phase {
            case .waitingForYou, .blocked: return (.asks, phase.label)
            case .finished, .inReview: return (.done, phase.label)
            case .idle: return (.idle, phase.label)
            case .starting, .working, .pmHandling, .needsFix: return (.working(progress(card, phase)), phase.label)
            }
        }
    }

    /// The ring: the card's step out of all steps (agents do not report a finer progress yet).
    static func progress(_ card: TaskCard?, _ phase: TaskPhase) -> Double {
        guard let card, let step = StepProgress.of(status: card.status, phase: phase) else { return 0 }
        return Double(step.current.rawValue + 1) / Double(TaskStep.allCases.count)
    }

    /// ⌘1…⌘9.
    static func tab(forDigit digit: Int, in tabs: [TerminalTab]) -> TerminalTab? {
        (1...9).contains(digit) && digit <= tabs.count ? tabs[digit - 1] : nil
    }

    /// "6 terminals · 4 running".
    static func countText(_ tabs: [TerminalTab]) -> String {
        "\(tabs.count) terminal\(tabs.count == 1 ? "" : "s") · \(tabs.filter(\.isWorking).count) running"
    }
}

/// Which terminals have new output: the state counter moved while the terminal was not on screen. A pane seen for the first time is not new.
struct TerminalUnread: Equatable {
    private var seen: [String: Int?] = [:]
    private(set) var panes: Set<String> = []

    mutating func observe(_ agents: [AgentStatus], selected: String?) { observe(agents, shown: selected.map { [$0] } ?? []) }

    /// `shown`: the terminals in a pane now; they are being looked at.
    mutating func observe(_ agents: [AgentStatus], shown: Set<String>) {
        for agent in agents {
            if shown.contains(agent.paneID) || seen[agent.paneID] == nil {
                seen[agent.paneID] = .some(agent.changeSeq)
                panes.remove(agent.paneID)
            } else if seen[agent.paneID] != .some(agent.changeSeq) {
                panes.insert(agent.paneID)
            }
        }
        let live = Set(agents.map(\.paneID))
        seen = seen.filter { live.contains($0.key) }
        panes.formIntersection(live)
    }
}

/// The ⌘L prompt box over the focused pane (N234; before, the message box at the bottom of every terminal card).
enum TerminalComposer {
    static let typingNote = "You are typing · panel prompts wait"
    static let hint = "Enter sends · ⇧Enter new line · Esc closes"

    /// Why nothing can be sent now; nil when the box is usable.
    static func disabledReason(agents: AgentsState, tab: TerminalTab?) -> String? {
        switch agents {
        case .loading: return "Checking the terminals…"
        case .unavailable(let message): return "The terminal backend cannot be reached: \(message)"
        case .available(let list): return tab.map { t in list.contains { $0.paneID == t.paneID } } == true ? nil : "This terminal is gone."
        }
    }

    static func placeholder(_ tab: TerminalTab) -> String {
        tab.kind == .shell ? "Message \(tab.title)…" : "Message \(tab.label) — what should it do next?"
    }

    static func canSend(text: String, reason: String?, sending: Bool) -> Bool {
        reason == nil && !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the text as a prompt to the pane; nil when it went, else why not.
    static func send(_ text: String, to pane: String, commander: TerminalCommanding) async -> String? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return "Nothing to send." }
        do { try await commander.prompt(target: pane, text: prompt); return nil }
        catch { return "Could not send: \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
    }

    /// Filter (⇧⌘F): only the screen's lines that hold the query, ignoring case.
    static func filter(_ screen: String, query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return screen }
        return screen.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(q) }.joined(separator: "\n")
    }
}

/// Who has the keyboard (N234): the focused pane's live terminal, or the ⌘L box while it is open and focused. There is one place to type.
enum TerminalKeyboard {
    /// The pane header's button. A polled pane (no live terminal) takes no keys: it says where to write.
    static func paneText(focused: Bool, prompt: Bool, live: Bool = true) -> String {
        if focused && prompt { return "Keyboard → prompt box" }
        guard live else { return "Use ⌘L to send" }
        return focused ? "Keyboard → this terminal" : "Click to type here"
    }

    /// The bar at the bottom starts with this, then `owner`.
    static func barLead(prompt: Bool, live: Bool) -> String { prompt || live ? "Keystrokes go to " : "Use ⌘L to send to " }

    /// The bar at the bottom: "Keystrokes go to <owner>".
    static func owner(label: String, pane: Int, panes: Int, prompt: Bool) -> String {
        prompt ? "the prompt box (\(label))" : "\(label) terminal" + (panes > 1 ? " · pane \(pane)" : "")
    }

    /// The typing hold's pane (N215, N245): the ⌘L box's terminal while the box has the keys, else the terminal a key went to in the
    /// last few seconds (`held`).
    static func typingPane(held: String?, promptTerminal: String?, promptHasKeys: Bool) -> String? {
        promptHasKeys ? promptTerminal : held
    }
}

/// ⌘F and ⇧⌘F on the Terminals screen (N256): ⌘F is the focused pane's find bar (N252), ⇧⌘F the toolbar's line filter.
enum TerminalFindKeys {
    static let filter = (key: KeyEquivalent("f"), modifiers: EventModifiers([.command, .shift]), label: "⇧⌘F")
    static let find = (key: KeyEquivalent("f"), modifiers: EventModifiers.command, label: "⌘F")
    static let filterHelp = "Show only the lines that hold a word (the focused pane) · ⇧⌘F"
    static let filterIdentifier = "terminal-filter"

    enum Route: Equatable {
        case none
        /// The focused pane takes the keyboard and opens its find bar; a running filter ends first, so the live terminal shows.
        case openFind(endFilter: Bool)
    }

    /// ⌘F while the keyboard is elsewhere on the screen (inside a terminal, the terminal's own key monitor answers first). Nothing without
    /// a focused pane or when that pane shows polled text (no live terminal, no find bar).
    static func route(focusedTerminal: String?, live: Bool, filtering: Bool) -> Route {
        guard focusedTerminal != nil, live else { return .none }
        return .openFind(endFilter: filtering)
    }
}

/// A key typed into a terminal holds panel prompts to that agent for a few seconds (N245). Having the keyboard is not enough: the
/// focused terminal has it all the time, also while the window is behind.
struct TerminalTypingHold: Equatable {
    static let seconds: TimeInterval = 5
    private(set) var pane: String?
    private(set) var keyAt: Date?

    mutating func key(pane: String, at now: Date) { self.pane = pane; keyAt = now }
    mutating func clear() { pane = nil; keyAt = nil }
    func active(at now: Date) -> String? {
        guard let pane, let keyAt, now.timeIntervalSince(keyAt) < Self.seconds else { return nil }
        return pane
    }
}

/// Watches the keys typed into the live terminals and the window's key state for the typing hold (N245). A key counts only while the
/// window is the key window and a terminal has the keyboard; the hold ends 5 s after the last key and when the window resigns key.
@MainActor
final class TerminalKeyWatch {
    private(set) var hold = TerminalTypingHold()
    private(set) var windowKey = true
    /// The terminal whose live view is the first responder.
    var terminalWithKeys: String?
    /// The hold or the window changed: the screen re-reads who is typing.
    var onChange: () -> Void = {}
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private var expiry: Task<Void, Never>?

    func active(at now: Date = Date()) -> String? { windowKey ? hold.active(at: now) : nil }

    func noteKey(windowIsKey: Bool, now: Date = Date()) {
        guard windowIsKey, windowKey, let pane = terminalWithKeys else { return }
        hold.key(pane: pane, at: now)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TerminalTypingHold.seconds + 0.05))
            if !Task.isCancelled { self?.onChange() }
        }
        onChange()
    }

    func windowChanged(isKey: Bool) {
        windowKey = isKey
        if !isKey { clearHold() }
        onChange()
    }

    /// The terminal let go of the keyboard.
    func clearHold() {
        hold.clear()
        expiry?.cancel(); expiry = nil
    }

    /// Follows `window`'s key state; nil when the view has no window.
    func attach(_ next: NSWindow?) {
        guard next !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = next
        guard let next else { return }
        windowKey = next.isKeyWindow
        for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: next, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged(isKey: isKey) }
            })
        }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                // A shortcut (⌘1, ⌘L…) is not typing to the terminal.
                if let self, !event.modifierFlags.contains(.command), let w = event.window, w === self.window || self.window == nil,
                   w.isKeyWindow, w.firstResponder is LiveTerminalNSView {
                    self.noteKey(windowIsKey: true)
                }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = nil
        clearHold()
    }
}

/// Gives the screen its window (the key watch follows it).
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }

    func makeNSView(context: Context) -> Probe { let v = Probe(); v.onWindow = onWindow; return v }
    func updateNSView(_ view: Probe, context: Context) { view.onWindow = onWindow }
}

/// The user's own shells (N245): login shells in the project folder, opened from the sidebar's "+". They are tentacld sessions named
/// `my-shell-N`; the panel shows them like any terminal and never reads or answers them.
enum TerminalShells {
    static let prefix = "my-shell-"
    static func isUserShell(_ paneID: String) -> Bool { paneID.hasPrefix(prefix) }
    static func title(_ paneID: String) -> String { "Shell " + paneID.dropFirst(prefix.count) }

    /// The agents without the user's shells: what every read of a screen, every prompt and every count of the autopilot, outbox and PM notices works on.
    static func withoutUserShells(_ agents: [AgentStatus]) -> [AgentStatus] { agents.filter { !isUserShell($0.paneID) } }

    /// The first `my-shell-N` not used by any session (exited ones stay in tentacld's list until they are killed).
    static func nextID(existing: [String]) -> String {
        var n = 1
        while existing.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// Opens a shell in `cwd` under the first free `my-shell-N` of every session in the daemon (ids are global, not per project). When
    /// the daemon says the id is running (another window took it meanwhile) the next number is tried, a few times.
    /// `listed`: the ids to start from (tests); default the daemon's list.
    static func open(client: TentacldClient, cwd: String, argv: [String] = TerminalShells.argv(), listed: (() async throws -> [String])? = nil, history: Bool = true) async throws -> String {
        var taken: [String]
        if let listed { taken = try await listed() } else { taken = try await client.list().map(\.id) }
        var failure: Error?
        for _ in 0..<4 {
            let id = nextID(existing: taken)
            do { try await client.spawn(id: id, argv: argv, cwd: cwd, history: history); return id }
            catch let e as TentacldClient.TentacldError where e.message.contains("is running") { failure = e; taken.append(id) }
        }
        throw failure ?? TentacldClient.TentacldError(message: "No free shell name.")
    }

    /// Ends the user's shell and returns once tentacld no longer lists it (it hangs up the shell, which ends it, and drops a user's shell at
    /// once; a session still listed as exited is killed again, which removes it). Throws when it is still listed after `wait`.
    static func close(client: TentacldClient, id: String, wait: Duration = .seconds(3)) async throws {
        do { try await client.kill(id: id) } catch {
            if try await client.list().contains(where: { $0.id == id }) { throw error }
            return
        }
        let end = ContinuousClock.now + wait
        while ContinuousClock.now < end {
            guard let s = try await client.list().first(where: { $0.id == id }) else { return }
            if !s.alive { try? await client.kill(id: id) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if try await client.list().contains(where: { $0.id == id }) { throw TentacldClient.TentacldError(message: "The shell did not end.") }
    }

    static func argv(shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> [String] {
        [shell.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh", "-l"]
    }
}

/// Closing a user's shell (N247): the × of its pane, "Close shell" in the sidebar row's menu and in the pane's "i" popover all ask once,
/// then kill the session.
@MainActor @Observable
final class ShellCloser {
    private(set) var pending: String?
    @ObservationIgnored var kill: (String) -> Void = { _ in }

    func request(_ id: String) { pending = id }
    func cancel() { pending = nil }
    func confirm(_ id: String) { pending = nil; kill(id) }
}

/// The saved panes of the project, read from UserDefaults once (N245); the screen is built again on every render of its parent.
@MainActor
final class SavedPanesLoader {
    private var value: TerminalPaneLayout??

    func layout(_ defaults: UserDefaults, project: String?) -> TerminalPaneLayout? {
        if let value { return value }
        let loaded = project.flatMap { TerminalPaneStore.load(defaults, project: $0) }
        value = .some(loaded)
        return loaded
    }
}

extension PanelModel {
    /// The Terminals screen's live terminal or ⌘L box has the keyboard for `pane` (nil: neither has it). Panel prompts to that pane wait
    /// in the outbox and a call of several questions is not stepped there, as when the user is typing to the pane (N215).
    func setTerminalTyping(_ pane: String?) {
        guard outbox.typingPane != pane else { return }
        outbox.typingPane = pane
        for watch in watches.values { watch.inbox.typingPane = pane }
        inbox.typingPane = pane
        if pane == nil { Task { await deliverOutbox() } }
    }
}

/// Layout requests for tests: the same changes as a row dropped on a pane and a divider dragged.
@MainActor @Observable
final class TerminalDropProbe {
    private(set) var serial = 0
    private(set) var request: (terminal: String, pane: Int, zone: TerminalPaneLayout.Zone)?
    private(set) var ratio: (path: [Bool], value: Double)?
    func drop(_ terminal: String, on pane: Int, zone: TerminalPaneLayout.Zone) { request = (terminal, pane, zone); ratio = nil; serial += 1 }
    /// The divider at `path` dragged to `value`.
    func divide(_ path: [Bool], at value: Double) { request = nil; ratio = (path, value); serial += 1 }
}

/// The Terminals screen (N224, N234 board A): the project's terminals in a sidebar on the left, 1 to 4 of them in panes (drag a row onto
/// a pane's middle to replace it, onto an edge to split), the focused pane with its ask dock and status line, Preview of its local page
/// on the right, and a bar that says where keystrokes go. The terminal itself is the one place to type; ⌘L opens a prompt box.
struct TerminalsView: View {
    @Bindable var model: PanelModel
    var onOpenCard: (String) -> Void = { _ in }
    var onOpenChanges: (String) -> Void = { _ in }
    /// Snapshots: the questions and screens shown instead of the live ones, the terminal that has the keyboard.
    var fixedQuestions: [PendingQuestion]? = nil
    var fixedScreens: [String: String]? = nil
    var shownTyping: String? = nil
    /// Snapshots: the preview's state (console, picked element), the focused card's fix notes, a drop zone lit as if a row were dragged.
    var fixedPreview: PreviewModel? = nil
    var fixedNotes: [FixNoteItem]? = nil
    var shownDrop: TerminalDropTarget? = nil
    /// Tests: a drop made without a mouse.
    var dropProbe: TerminalDropProbe? = nil
    /// tentacld (N231): a terminal whose pane id is one of its sessions shows the live terminal. nil in the test host.
    private let givenClient: TentacldClient?
    /// Snapshots: the labels as if the focused pane's terminal were live (true) or polled (false).
    var shownLive: Bool? = nil
    @State private var foundClient: TentacldClient?
    private var tentacld: TentacldClient? { givenClient ?? foundClient }
    /// Tests: the socket to look for instead of the app's own, and how often (a daemon that starts after the screen is found within it).
    private let socket: String?
    private let lookupEvery: Duration
    @State private var closer = ShellCloser()
    /// Shells brought back after a restart, with their saved text (N273); snapshots and tests give their own.
    private let restoredShells: RestoredShells
    @State private var panes: TerminalPaneLayout?
    /// The layout was given (a snapshot or a test), so the saved one is not read.
    private let panesGiven: Bool
    @State private var loader = SavedPanesLoader()
    @State private var previewOpen: Bool
    @State private var promptOpen: Bool
    @State private var promptText: String
    @State private var promptHasKeys: Bool
    @State private var keyWatch = TerminalKeyWatch()
    /// Bumped when the typing hold changes, so the "You are typing" chips redraw.
    @State private var typingTick = 0
    @State private var finding: Bool
    @State private var appearanceOpen = false
    /// The toolbar's hint has room enough to be read (N327).
    @State private var hintReadable = true
    @State private var query: String
    /// The filter field takes the keyboard when ⇧⌘F or Filter opens it (N266), so typing filters at once.
    @FocusState private var filterFocused: Bool
    /// The toolbar's yellow note (Preview closed, a split not possible); cleared by the next change.
    @State private var notice: String?
    @State private var collapsed: Bool
    @State private var drops = TerminalDropState()
    /// The user's new shell, to be put into the focused pane once the terminal list has it.
    @State private var pendingShell: String?
    /// Bumped when the focused pane's terminal should take the keyboard (a pane picked, the ⌘L box closed).
    @State private var keyboardRequest = 0
    /// Bumped by ⌘F with the keyboard elsewhere on the screen: the focused pane opens its find bar (N256).
    @State private var findRequest = 0
    @State private var unread = TerminalUnread()
    @State private var pages: TerminalPageWatch
    /// Bumped after a fix note is written, so the Fix notes read the card again.
    @State private var notesRevision = 0
    /// Broadcast (N271): typing into the focused live terminal also goes to the other picked panes. Not saved.
    @State private var broadcast = TerminalBroadcast()
    @State private var broadcastRouter: TerminalBroadcastRouter?
    @State private var broadcastMonitor: Any?
    @State private var escapes = TerminalEscapeTracker()
    /// Saved commands (N272): the toolbar's list.
    @State private var snippetsOpen: Bool
    /// The agent pane waiting for the answer to "Also type into agent panes?".
    @State private var agentAsk: String?
    @Environment(\.snapshotMode) private var snapshot

    init(model: PanelModel, onOpenCard: @escaping (String) -> Void = { _ in }, onOpenChanges: @escaping (String) -> Void = { _ in },
         fixedQuestions: [PendingQuestion]? = nil, fixedScreens: [String: String]? = nil, panes: TerminalPaneLayout? = nil, selected: String? = nil,
         typing: String? = nil, preview: Bool = false, prompt: String? = nil, filter: String? = nil, sidebarCollapsed: Bool? = nil, drop: TerminalDropTarget? = nil,
         fixedPreview: PreviewModel? = nil, fixedNotes: [FixNoteItem]? = nil, tentacld: TentacldClient?? = nil,
         dropProbe: TerminalDropProbe? = nil, keysLive: Bool? = nil, socket: String? = nil, lookupEvery: Duration = .seconds(2), broadcast: Bool = false, snippets: Bool = false, restoredShells: RestoredShells? = nil) {
        self.model = model
        self.restoredShells = restoredShells ?? .shared
        self.socket = socket
        self.lookupEvery = lookupEvery
        self.dropProbe = dropProbe
        // The app's own daemon is looked up when the screen appears, not on every render of the parent.
        givenClient = tentacld ?? nil
        shownLive = keysLive
        self.onOpenCard = onOpenCard
        self.onOpenChanges = onOpenChanges
        self.fixedQuestions = fixedQuestions
        self.fixedScreens = fixedScreens
        self.shownTyping = typing
        self.fixedPreview = fixedPreview
        self.fixedNotes = fixedNotes
        self.shownDrop = drop
        let watch = TerminalPageWatch()
        for (pane, text) in fixedScreens ?? [:] { watch.update(pane: pane, text: text) }
        _pages = State(initialValue: watch)
        let given = panes ?? selected.map { TerminalPaneLayout(terminal: $0) }
        panesGiven = given != nil
        _panes = State(initialValue: given)
        // Snapshots: the screen as right after Broadcast was turned on.
        var started = TerminalBroadcast()
        if broadcast { started.start(panes: given?.terminals ?? []) }
        _broadcast = State(initialValue: started)
        _previewOpen = State(initialValue: preview)
        _snippetsOpen = State(initialValue: snippets)
        _promptOpen = State(initialValue: prompt != nil)
        // A snapshot with the box open shows it focused.
        _promptHasKeys = State(initialValue: prompt != nil)
        _promptText = State(initialValue: prompt ?? "")
        // Tests: the screen opens with the filter open, as right after ⇧⌘F.
        _finding = State(initialValue: filter != nil)
        _query = State(initialValue: filter ?? "")
        _collapsed = State(initialValue: sidebarCollapsed ?? TerminalPaneStore.sidebarCollapsed(model.defaults))
    }

    private var agents: [AgentStatus] { if case .available(let list) = model.visibleAgents { list } else { [] } }
    /// The saved panes, read from UserDefaults on the first use (N245).
    private var savedPanes: TerminalPaneLayout? { panes ?? (panesGiven ? nil : loader.layout(model.defaults, project: model.selectedProjectID)) }
    /// A shell of the user's own is never asked about (N245).
    private var questions: [PendingQuestion] { (fixedQuestions ?? model.autopilot.forUser(model.inbox.questions)).filter { !TerminalShells.isUserShell($0.paneID) } }
    private var tabs: [TerminalTab] {
        TerminalTabs.make(agents: agents, pmPane: model.selectedProjectID.flatMap { model.pmAgent(forProject: $0)?.paneID },
                          card: { model.card(of: $0) }, phase: { model.phase(of: $0) }, questions: questions, unread: unread.panes, line: { model.statusLine($0) })
            .map { tab in var t = tab; t.port = pages.pages[tab.paneID].map { TerminalPreview.port($0.url) }; return t }
    }
    private var livePanes: [String] { agents.map(\.paneID) }

    /// The saved panes with closed terminals replaced; one pane with the first terminal when nothing is saved.
    private func layout(_ tabs: [TerminalTab]) -> TerminalPaneLayout? {
        let ids = tabs.map(\.paneID)
        return (savedPanes ?? ids.first.map { TerminalPaneLayout(terminal: $0) })?.reconciled(with: ids)
    }

    private func typingPane(_ layout: TerminalPaneLayout?) -> String? {
        shownTyping ?? TerminalKeyboard.typingPane(held: keyWatch.active(), promptTerminal: promptOpen ? layout?.focusedTerminal : nil,
                                                   promptHasKeys: promptHasKeys && keyWatch.windowKey)
    }

    /// Whether the pane's terminal is live (takes keys) or polled text (the labels say so).
    private func keysLive(_ pane: String) -> Bool {
        if let shownLive { return shownLive }
        guard !snapshot, fixedScreens == nil, let client = tentacld else { return false }
        return model.liveTerminals.session(id: pane, client: client).isLive
    }

    var body: some View {
        let tabs = tabs
        let layout = layout(tabs)
        let focused = layout?.focusedTerminal.flatMap { id in tabs.first { $0.paneID == id } }
        HStack(spacing: 0) {
            TerminalSidebar(tabs: tabs, paneNumbers: Dictionary(uniqueKeysWithValues: (layout?.panes ?? []).map { ($0.terminal, $0.number) }),
                            focusedTerminal: layout?.focusedTerminal, collapsed: collapsed,
                            localPages: TerminalPreview.rows(tabs: tabs, pages: pages.pages), info: { info($0) },
                            onPick: { pick($0) }, onToggle: toggleSidebar, onDragStart: { drops.begin($0) }, onOpenPage: { openPreview($0.paneID) },
                            onNewShell: tentacld == nil ? nil : newShell,
                            newShellHelp: tentacld == nil ? "The terminal backend cannot be reached." : "Open a new shell in the project folder")
            VStack(spacing: 0) {
                toolbar(layout, focused: focused)
                Divider().overlay(Tok.line)
                if broadcast.isOn { broadcastBanner }
                if let layout, let focused {
                    HStack(spacing: Tok.Space.m) {
                        grid(layout, tabs: tabs)
                        if previewOpen { preview(focused) }
                    }
                    .pageMargin(.horizontal).padding(.vertical, Tok.Space.m)
                    keyboardBar(layout, focused: focused)
                } else {
                    empty.pageMargin(.horizontal).padding(.vertical, Tok.Space.l)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Tok.bg)
        .background(WindowReader { keyWatch.attach($0) })
        .modifier(AgentStopDialog(model: model))
        .confirmationDialog("Close this shell?", isPresented: Binding(get: { closer.pending != nil }, set: { if !$0 { closer.cancel() } }),
                            titleVisibility: .visible, presenting: closer.pending) { id in
            Button("Close \(TerminalShells.title(id))", role: .destructive) { closer.confirm(id) }
            Button("Cancel", role: .cancel) {}
        } message: { id in
            Text("\(TerminalShells.title(id)) ends, together with anything running in it.")
        }
        .task(id: lookingForTentacld) {
            while lookingForTentacld && !Task.isCancelled {
                try? await Task.sleep(for: lookupEvery)
                lookUpTentacld()
            }
        }
        .task(id: drops.isDragging) {
            // A cancelled drag tells nobody: with the button up the drop zone and the dragged row are let go of.
            while drops.isDragging && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                drops.settle(buttonDown: NSEvent.pressedMouseButtons & 1 != 0)
            }
        }
        .onAppear {
            closer.kill = { closeShell($0) }
            lookUpTentacld()
            restoreGoneShells()
            if !snapshot {
                keyWatch.onChange = { typingTick += 1; syncTyping() }
                keyWatch.start()
            }
            showRequestedTab()
            unread.observe(agents, shown: Set(layout?.terminals ?? []))
            if fixedScreens == nil && !snapshot { pages.start(reader: model.makeReader()) { [model] in
                if case .available(let list) = model.visibleAgents { list.map(\.paneID).filter { !TerminalShells.isUserShell($0) } } else { [] }
            } }
        }
        .onChange(of: model.terminalFocus) { _, _ in showRequestedTab() }
        .onChange(of: layout?.terminals ?? []) { _, now in broadcast.reconcile(panes: now) }
        .confirmationDialog("Also type into agent panes?", isPresented: Binding(get: { agentAsk != nil }, set: { if !$0 { agentAsk = nil } }),
                            titleVisibility: .visible, presenting: agentAsk) { id in
            Button("Yes, include \(tabs.first { $0.paneID == id }?.label ?? "this agent")") { broadcast.allowAgents(andPick: id); agentAsk = nil }
            Button("No", role: .cancel) { agentAsk = nil }
        } message: { _ in
            Text("What you type then reaches the agent too, as if you had written it to it yourself.")
        }
        .onChange(of: dropProbe?.serial) { _, _ in
            if let r = dropProbe?.request { _ = change(keys: true) { $0.drop(r.terminal, on: r.pane, zone: r.zone, preview: previewOpen) } }
            if let r = dropProbe?.ratio { _ = change { $0.setRatio(r.value, ofSplitAt: r.path); return true } }
        }
        .onChange(of: model.agents) { _, _ in
            lookUpTentacld()
            restoreGoneShells()
            let tabs = self.tabs
            let now = self.layout(tabs)
            unread.observe(agents, shown: Set(now?.terminals ?? []))
            guard case .available = model.visibleAgents else { return }
            pages.keep(Set(livePanes))
            model.liveTerminals.keep(Set(livePanes))
            // The layout shown follows the terminals; what is saved changes only when the user changes it (N245).
            if let id = pendingShell, tabs.contains(where: { $0.paneID == id }) { pendingShell = nil; pick(id) }
            enforcePreview(now, tabs: tabs)
        }
        .onChange(of: pages.pages) { _, _ in enforcePreview(self.layout(self.tabs), tabs: self.tabs) }
        .onDisappear { stopBroadcast(); keyWatch.stop(); keyWatch.onChange = {}; model.setTerminalTyping(nil); pages.stop() }
    }

    // MARK: changes

    private func store(_ next: TerminalPaneLayout, save: Bool = true) {
        panes = next
        if save { saveLayout() }
    }

    private func saveLayout() {
        if let panes, let project = model.selectedProjectID { TerminalPaneStore.save(model.defaults, project: project, panes) }
    }

    /// Every pane change: saved, the ⌘L box closes when the focus moves, Preview follows the focused terminal. `keys`: the focused
    /// terminal takes the keyboard.
    @discardableResult
    private func change(keys: Bool = false, save: Bool = true, _ edit: (inout TerminalPaneLayout) -> Bool) -> Bool {
        let tabs = tabs
        guard let shown = layout(tabs) else { return false }
        var next = shown
        let before = next.focused
        guard edit(&next) else { return false }
        // A terminal that is gone for a moment keeps its place in what is saved.
        store(savedPanes.map { next.keepingMissingTerminals(saved: $0, shown: shown) } ?? next, save: save)
        notice = nil
        if next.focused != before && promptOpen { closePrompt() }
        enforcePreview(next, tabs: tabs)
        unread.observe(agents, shown: Set(next.terminals))
        if keys { keyboardRequest += 1 }
        return true
    }

    /// Preview is open only while the focused terminal serves a page; otherwise it closes with a yellow note.
    private func enforcePreview(_ layout: TerminalPaneLayout?, tabs: [TerminalTab]) {
        guard previewOpen, fixedPreview == nil else { return }
        let terminal = layout?.focusedTerminal
        guard !TerminalPreview.stays(open: true, page: terminal.flatMap { pages.pages[$0] }) else { return }
        previewOpen = false
        notice = TerminalPreview.closedNote(label: tabs.first { $0.paneID == terminal }?.label ?? "This terminal")
    }

    /// An Open terminal button asked for this agent's terminal (N233): load it into the focused pane and clear the request.
    private func showRequestedTab() {
        guard let request = model.terminalFocus else { return }
        model.terminalFocus = nil
        if layout(tabs) == nil { panes = TerminalPaneLayout(terminal: request.pane) } else { pick(request.pane) }
    }

    /// A sidebar row or ⌘1…⌘9: into the focused pane (a terminal in another pane swaps with it).
    private func pick(_ terminal: String) {
        change(keys: true) { $0.showInFocused(terminal); return true }
    }

    /// A LOCAL PAGES row: its terminal into the focused pane, and Preview.
    private func openPreview(_ terminal: String) {
        pick(terminal)
        if pages.pages[terminal] != nil { previewOpen = true; notice = nil }
    }

    private func togglePreview(_ focused: TerminalTab?) {
        previewOpen = TerminalPreview.toggled(open: previewOpen, page: focused.flatMap { pages.pages[$0.paneID] })
        notice = nil
    }

    /// A row dropped on a pane (the grid only accepts a drag that began on a sidebar row).
    private func drop(on pane: Int, zone: TerminalPaneLayout.Zone, providers: [NSItemProvider]) {
        guard let terminal = drops.dragging, tabs.contains(where: { $0.paneID == terminal }) else { return }
        change(keys: true) { $0.drop(terminal, on: pane, zone: zone, preview: previewOpen) }
    }

    /// The sidebar's "+": a login shell of the user's in the project folder, a tentacld session the panel only displays.
    private func newShell() {
        guard let client = tentacld, let project = model.selectedProject else { return }
        Task {
            do {
                pendingShell = try await TerminalShells.open(client: client, cwd: project.repoPath, history: TerminalSettings.restoreHistory(model.defaults))
                notice = nil
                await model.refreshAgents()
            } catch {
                notice = "Could not open a shell: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
    }

    /// The app's daemon, when its socket is there: looked up when the screen appears, when the agents change, and every `lookupEvery` while
    /// there is none, so a pane built before tentacld started switches to the live terminal by itself.
    private func lookUpTentacld() {
        if givenClient == nil && foundClient == nil && !snapshot { foundClient = LiveTerminalSession.appClient(socket: socket) }
    }

    private var lookingForTentacld: Bool { givenClient == nil && foundClient == nil && !snapshot && (socket != nil || !PanelModel.runsUnderXCTest) }

    /// "Clear" on a restored shell's text: gone from the pane and from what the daemon keeps.
    private func clearRestored(_ id: String) {
        restoredShells.drop(id)
        if let client = tentacld { Task { await TerminalHistory.forget(client: client, id: id) } }
    }

    /// Shells saved in this project's panes whose session is gone (the Mac or tentacld restarted) start again in their folder with their
    /// saved text above (N273), once per app launch.
    private func restoreGoneShells() {
        guard let client = tentacld, !snapshot, fixedScreens == nil, case .available = model.visibleAgents, let project = model.selectedProject,
              TerminalSettings.restoreHistory(model.defaults) else { return }
        let live = Set(livePanes)
        let gone = (savedPanes?.terminals ?? []).filter { TerminalShells.isUserShell($0) && !live.contains($0) && restoredShells.claim($0) }
        guard !gone.isEmpty else { return }
        Task {
            for id in gone {
                if let text = try? await TerminalHistory.restore(client: client, id: id, fallbackCwd: project.repoPath) { restoredShells.set(id, text) }
            }
            await model.refreshAgents()
        }
    }

    private func closeShell(_ id: String) {
        guard let client = tentacld else { return }
        restoredShells.drop(id)
        Task {
            do { try await TerminalShells.close(client: client, id: id); notice = nil }
            catch { notice = "Could not close the shell: \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
            await model.refreshAgents()
        }
    }

    /// ⌘D (right) and ⌘⇧D (down): the focused pane splits with the next terminal not on screen.
    private func splitFocused(_ zone: TerminalPaneLayout.Zone) {
        let order = tabs.map(\.paneID)
        guard let layout = layout(tabs), let pane = layout.focusedPane else { return }
        guard let terminal = layout.nextFree(in: order) else { notice = "Every terminal is already on screen."; return }
        guard layout.canSplit(pane.id, zone, preview: previewOpen) else {
            notice = previewOpen ? "At most 2 panes while Preview is open." : "At most 4 panes, 2 across and 2 down."
            return
        }
        change(keys: true) { $0.split(pane.id, zone, with: terminal, preview: previewOpen) }
    }

    private func toggleSidebar() {
        collapsed.toggle()
        TerminalPaneStore.setSidebarCollapsed(model.defaults, collapsed)
    }

    // MARK: keyboard

    private func terminalFocus(_ terminal: String, pane: Int, _ on: Bool) {
        if on {
            keyWatch.terminalWithKeys = terminal
            if layout(tabs)?.focused != pane { change { $0.focus(pane); return true } }
            syncTyping()
        } else if keyWatch.terminalWithKeys == terminal {
            keyWatch.terminalWithKeys = nil
            keyWatch.clearHold()
            // The keys often go to the ⌘L box or another terminal right after: no gap that lets a held prompt out.
            DispatchQueue.main.async { syncTyping() }
        }
    }

    private func promptFocus(_ on: Bool) {
        promptHasKeys = on
        if on { syncTyping() } else { DispatchQueue.main.async { syncTyping() } }
    }

    private func syncTyping() {
        guard shownTyping == nil else { return }
        model.setTerminalTyping(typingPane(layout(tabs)))
    }

    private func togglePrompt() {
        if promptOpen { closePrompt() } else { promptOpen = true }
    }

    /// After Send or Esc the keyboard goes back to the terminal.
    private func closePrompt() {
        promptOpen = false
        promptHasKeys = false
        keyboardRequest += 1
        DispatchQueue.main.async { syncTyping() }
    }

    /// A pane's VoiceOver actions: the split and move-focus shortcuts, which have no visible button.
    private func paneAction(_ action: TerminalPaneAction, pane: Int) {
        change(keys: true) { $0.focus(pane); return true }
        switch action {
        case .splitRight: splitFocused(.right)
        case .splitDown: splitFocused(.bottom)
        case .move(let direction): change(keys: true) { $0.moveFocus(direction); return true }
        }
    }

    // MARK: broadcast (N271)

    private func toggleBroadcast() {
        if broadcast.isOn { stopBroadcast(); return }
        guard let panes = layout(tabs)?.terminals, panes.count > 1 else { return }
        broadcast.start(panes: panes)
        escapes.reset()
        if !snapshot && broadcastMonitor == nil {
            broadcastMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { broadcastKey(event) }
                return event
            }
        }
        keyboardRequest += 1
    }

    private func stopBroadcast() {
        if let broadcastMonitor { NSEvent.removeMonitor(broadcastMonitor); self.broadcastMonitor = nil }
        broadcast.stop()
        escapes.reset()
    }

    private func toggleBroadcastPane(_ id: String) {
        if broadcast.toggle(id) == .needsAgentConsent { agentAsk = id }
    }

    /// Observes keys while the keyboard is in a live terminal and copies them to the other picked panes; the key itself goes on to its
    /// terminal. Esc twice stops broadcast. Keys in the find bar, the ⌘L box and the filter field are not terminal input.
    private func broadcastKey(_ event: NSEvent) {
        guard broadcast.isOn, let window = event.window, window.isKeyWindow, let source = keyWatch.terminalWithKeys, let client = tentacld,
              model.liveTerminals.session(id: source, client: client).view === window.firstResponder else { return }
        let flags = event.modifierFlags
        if event.keyCode == 53 {
            if escapes.press(at: Date()) { stopBroadcast(); return }
        } else { escapes.reset() }
        let out = TerminalBroadcastKeys.output(keyCode: event.keyCode, characters: event.characters, plain: event.charactersIgnoringModifiers,
                                               command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift))
        let bytes: [UInt8]
        switch out {
        case .bytes(let b): bytes = b
        case .paste: bytes = NSPasteboard.general.string(forType: .string).map(TerminalBroadcastKeys.pasteBytes) ?? []
        case .none: return
        }
        let targets = broadcast.targets(from: source, panes: layout(tabs)?.terminals ?? [])
        guard !targets.isEmpty else { return }
        let router = broadcastRouter ?? TerminalBroadcastRouter(writer: client)
        broadcastRouter = router
        router.send(bytes, to: targets)
    }

    private var broadcastBanner: some View {
        HStack(spacing: Tok.Space.s) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12)).foregroundStyle(Tok.you).accessibilityHidden(true)
            Text(TerminalBroadcast.banner(count: broadcast.count)).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink)
            Text("Esc Esc or Stop ends it").font(Tok.Font.small).foregroundStyle(Tok.ink2)
            Spacer(minLength: Tok.Space.s)
            Button("Stop", action: stopBroadcast)
                .buttonStyle(.plain).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.you)
                .padding(.horizontal, Tok.Space.s + 2).frame(height: 24)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.you)).contentShape(Rectangle())
                .accessibilityIdentifier("broadcast-stop")
        }
        .pageMargin(.horizontal)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(Tok.youFill)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.you.opacity(0.5)).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TerminalBroadcast.banner(count: broadcast.count))
    }

    // MARK: toolbar

    private func toolbar(_ layout: TerminalPaneLayout?, focused: TerminalTab?) -> some View {
        let page = focused.flatMap { pages.pages[$0.paneID] }
        let items = TerminalToolbarFit.items(panes: layout?.count ?? 0)
        let hint: (text: String, color: Color)? = if let notice { (notice, Tok.wait) }
            else if let focused, page == nil { (TerminalPreview.hint(label: focused.label), Tok.ink2) }
            else if (layout?.count ?? 0) > 1 { ("A sidebar click loads the focused pane · drag a terminal onto a pane's edge to split", Tok.ink2) }
            else { nil }
        return HStack(spacing: Tok.Space.s + 2) {
            if let hint {
                // N327: it gives way to the buttons first; cut down to a stub it would read like "…", so it is hidden then.
                Text(hint.text).font(.system(size: 12)).foregroundStyle(hint.color).lineLimit(1)
                    .onGeometryChange(for: Bool.self) { $0.size.width >= 120 } action: { hintReadable = $0 }
                    .opacity(hintReadable ? 1 : 0)
                    .help(hint.text)
            }
            Spacer(minLength: Tok.Space.s)
            // N327: the buttons keep their one-line size; the ones that do not fit go, from the right end, into "…".
            ViewThatFits(in: .horizontal) {
                ForEach(TerminalToolbarFit.splits(items), id: \.bar.count) { split in toolRow(split, layout: layout, focused: focused) }
            }
            .layoutPriority(1)
            shortcuts(layout, focused: focused)
        }
        .frame(minHeight: 52)
        .pageMargin(.horizontal)
    }

    /// One toolbar button: in the bar, as a "…" menu item and as its keyboard shortcut (N327).
    private struct ToolSpec {
        let title: String
        let key: String
        let shortcut: KeyboardShortcut?
        /// On/off: a checkmark in the menu.
        let toggles: Bool
        let on: Bool
        let enabled: Bool
        let help: String
        let action: () -> Void
    }

    private func spec(_ item: TerminalToolItem, layout: TerminalPaneLayout?, focused: TerminalTab?) -> ToolSpec? {
        let panes = layout?.count ?? 0
        switch item {
        case .prompt:
            return ToolSpec(title: "Prompt", key: "⌘L", shortcut: KeyboardShortcut("l", modifiers: .command), toggles: true, on: promptOpen, enabled: focused != nil,
                            help: "Write a longer prompt for the focused terminal", action: togglePrompt)
        case .swap:
            return ToolSpec(title: "Swap 1 ⇄ 2", key: "", shortcut: nil, toggles: false, on: false, enabled: true, help: "Swap pane 1 and pane 2") {
                change(keys: true) { $0.swapFirstTwo(); return true }
            }
        case .filter:
            return ToolSpec(title: finding ? "Done" : "Filter", key: TerminalFindKeys.filter.label,
                            shortcut: KeyboardShortcut(TerminalFindKeys.filter.key, modifiers: TerminalFindKeys.filter.modifiers),
                            toggles: true, on: finding, enabled: focused != nil, help: TerminalFindKeys.filterHelp) {
                finding.toggle()
                if !finding { query = ""; keyboardRequest += 1 }
            }
        case .broadcast:
            return ToolSpec(title: broadcast.isOn ? "Stop broadcast" : "Broadcast", key: "⌥⌘I", shortcut: KeyboardShortcut("i", modifiers: [.command, .option]),
                            toggles: true, on: broadcast.isOn, enabled: broadcast.isOn || panes > 1,
                            help: broadcast.isOn ? "Stop typing into several panes" : panes > 1 ? "Type into several panes at once" : "Needs two panes: split first") { toggleBroadcast() }
        case .preview:
            let page = focused.flatMap { pages.pages[$0.paneID] }
            let reason = TerminalPreview.disabledReason(label: focused?.label, page: page)
            return ToolSpec(title: "Preview", key: "⌘P", shortcut: KeyboardShortcut("p", modifiers: .command), toggles: true, on: previewOpen, enabled: previewOpen || reason == nil,
                            help: previewOpen ? "Close the preview" : reason ?? "Open \(page?.url.absoluteString ?? "the page") beside the terminals") { togglePreview(focused) }
        case .commands:
            return ToolSpec(title: "Commands", key: "⌥⌘S", shortcut: KeyboardShortcut("s", modifiers: [.command, .option]), toggles: false, on: snippetsOpen, enabled: true,
                            help: "Saved commands for the focused pane") { snippetsOpen.toggle() }
        case .appearance, .backend:
            return nil
        }
    }

    /// One candidate row for `ViewThatFits`: the split's bar items, the filter field while filtering, and "…" with the rest.
    private func toolRow(_ split: TerminalToolbarFit.Split<TerminalToolItem>, layout: TerminalPaneLayout?, focused: TerminalTab?) -> some View {
        HStack(spacing: Tok.Space.s + 2) {
            ForEach(split.bar, id: \.self) { item in
                if item == .filter, finding { filterField }
                toolItem(item, layout: layout, focused: focused)
            }
            // The field stays in the bar while filtering, where the Filter button would be.
            if finding, !split.bar.contains(.filter) { filterField }
            if !split.menu.isEmpty { moreMenu(split.menu, layout: layout, focused: focused) }
        }
        .fixedSize()
    }

    @ViewBuilder private func toolItem(_ item: TerminalToolItem, layout: TerminalPaneLayout?, focused: TerminalTab?) -> some View {
        switch item {
        case .commands: snippetsButton(focused)
        case .appearance: appearanceButton
        case .backend: backendChip.fixedSize()
        default:
            if let s = spec(item, layout: layout, focused: focused) {
                toolButton(s.title, key: s.key, on: s.on, enabled: s.enabled, help: s.help, action: s.action)
            }
        }
    }

    private var filterField: some View {
        TextField("Filter the focused pane", text: $query).textFieldStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink)
            .padding(.horizontal, Tok.Space.s).frame(width: 180, height: 28)
            .background(Tok.rail, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.line))
            .focused($filterFocused)
            .accessibilityIdentifier(TerminalFindKeys.filterIdentifier)
            .task {
                // The field joins the window after it appears: focus is asked for again until it lands (~0.5 s at most).
                for _ in 0..<15 where !filterFocused { filterFocused = true; try? await Task.sleep(for: .milliseconds(30)) }
            }
            .onExitCommand { finding = false; query = ""; keyboardRequest += 1 }
    }

    /// "…": the items that do not fit, same titles, keys (as text), disabled state and checkmarks. Commands and Aa open their popover
    /// from here, anchored to "…". The backend status is its last line, with a dot on "…" in its colour.
    private func moreMenu(_ items: [TerminalToolItem], layout: TerminalPaneLayout?, focused: TerminalTab?) -> some View {
        let status = backendStatus
        let label = Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tok.ink)
        return Group {
            // A snapshot cannot draw a menu button: the label alone.
            if snapshot { label } else {
                Menu {
                    ForEach(items, id: \.self) { item in menuItem(item, layout: layout, focused: focused) }
                } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .frame(width: 32, height: 32)
        .background(snippetsOpen || appearanceOpen ? Tok.youFill : Tok.raise, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .overlay(alignment: .topTrailing) {
            if items.contains(.backend) { Circle().fill(status.color).frame(width: 7, height: 7).offset(x: 2, y: -2).accessibilityHidden(true) }
        }
        .help(items.contains(.backend) ? "More · \(status.text)" : "More")
        .accessibilityLabel("More")
        .accessibilityIdentifier("terminal-more")
        .popover(isPresented: items.contains(.commands) ? $snippetsOpen : .constant(false), arrowEdge: .bottom) { snippetsPanel(focused) }
        .background {
            Color.clear.popover(isPresented: items.contains(.appearance) ? $appearanceOpen : .constant(false), arrowEdge: .bottom) {
                AppearancePanel(store: model.terminalAppearance)
            }
        }
    }

    @ViewBuilder private func menuItem(_ item: TerminalToolItem, layout: TerminalPaneLayout?, focused: TerminalTab?) -> some View {
        switch item {
        case .appearance:
            // The menu closes before the popover can open.
            Button("Appearance: \(model.terminalAppearance.appearance.palette.name)") { DispatchQueue.main.async { appearanceOpen = true } }
                .help("Terminal appearance: theme, font, size, cursor, padding")
                .accessibilityIdentifier("terminal-appearance")
        case .backend:
            Divider()
            Button(backendStatus.text) {}.disabled(true)
        default:
            if let s = spec(item, layout: layout, focused: focused) {
                // The key is shown as text only: a pull-down menu's items answer their keys while closed, and the hidden shortcut
                // group already owns them, so a second registration would fire twice (N327 F1).
                let title = TerminalToolbarFit.menuTitle(s.title, key: s.key)
                if s.toggles {
                    Toggle(title, isOn: Binding(get: { s.on }, set: { _ in s.action() }))
                        .disabled(!s.enabled).help(s.help)
                } else {
                    Button(title) { if item == .commands { DispatchQueue.main.async { snippetsOpen = true } } else { s.action() } }
                        .disabled(!s.enabled).help(s.help)
                        .accessibilityIdentifier(item == .commands ? "terminal-snippets" : "")
                }
            }
        }
    }

    private func toolButton(_ title: String, key: String, on: Bool, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(title).foregroundStyle(Tok.ink); if !key.isEmpty { Text(key).foregroundStyle(Tok.ink2) } }
                .font(.system(size: 12)).padding(.horizontal, Tok.Space.s + 2).frame(height: 32)
                .background(on ? Tok.youFill : Tok.raise, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Tok.you : Tok.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: saved commands (N272)

    private func snippetsButton(_ focused: TerminalTab?) -> some View {
        toolButton("Commands", key: "⌥⌘S", on: snippetsOpen, enabled: true, help: "Saved commands for the focused pane") { snippetsOpen.toggle() }
            .accessibilityIdentifier("terminal-snippets")
            .popover(isPresented: $snippetsOpen, arrowEdge: .bottom) { snippetsPanel(focused) }
    }

    private func snippetsPanel(_ focused: TerminalTab?) -> some View {
        TerminalSnippetsPanel(store: TerminalSnippetStore(defaults: model.defaults), project: model.selectedProjectID, promptText: promptText,
                              canSend: focused != nil) { item in
            snippetsOpen = false
            if let focused { sendSnippet(item, to: focused) }
        }
    }

    /// A shell gets the text typed (Return only when run at once); an agent pane goes through the ⌘L box's path, never raw keystrokes.
    private func sendSnippet(_ item: TerminalSnippet, to tab: TerminalTab) {
        switch TerminalSnippetSend.route(item, pane: tab.paneID) {
        case .shell(let bytes):
            guard let client = tentacld else { notice = "The terminal backend cannot be reached."; return }
            Task {
                do { try await client.write(id: tab.paneID, data: Data(bytes)); model.actionLog.append("sent saved command \(item.name) to \(tab.label) from Terminals", project: model.selectedProjectID) }
                catch { notice = "Could not send: \(error.localizedDescription)" }
            }
            keyboardRequest += 1
        case .agentPrompt(let text):
            Task { if let failure = await send(text, to: tab, question: nil) { notice = failure } }
        case .agentBox(let text):
            promptText = text
            promptOpen = true
        }
    }

    /// "Aa <theme>": the terminal appearance (N235's panel), for every terminal at once.
    private var appearanceButton: some View {
        let store = model.terminalAppearance
        return Button { appearanceOpen.toggle() } label: {
            HStack(spacing: 6) { Text("Aa").fontWeight(.bold); Text(store.appearance.palette.name) }
                .font(.system(size: 12)).foregroundStyle(Tok.ink).padding(.horizontal, Tok.Space.s + 2).frame(height: 32)
                .background(appearanceOpen ? Tok.youFill : Tok.raise, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(appearanceOpen ? Tok.you : Tok.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Terminal appearance: theme, font, size, cursor, padding")
        .accessibilityLabel("Terminal appearance, \(store.appearance.palette.name)")
        .accessibilityIdentifier("terminal-appearance")
        .popover(isPresented: $appearanceOpen, arrowEdge: .bottom) { AppearancePanel(store: store) }
    }

    /// ⌘F with the keyboard elsewhere on the screen: the focused pane takes it and opens its find bar.
    private func openFind() {
        let layout = layout(tabs)
        let terminal = layout?.focusedTerminal
        guard case .openFind(let endFilter) = TerminalFindKeys.route(focusedTerminal: terminal, live: terminal.map(keysLive) ?? false, filtering: finding) else { return }
        if endFilter { finding = false; query = "" }
        if promptOpen { closePrompt() }
        findRequest += 1
    }

    /// ⌘F, ⌘D, ⌘⇧D and ⌥⌘ arrows: no button of their own. The toolbar buttons' keys are here too (N327), so they work the same
    /// whether the button is in the bar or in "…".
    private func shortcuts(_ layout: TerminalPaneLayout?, focused: TerminalTab?) -> some View {
        ZStack {
            ForEach(TerminalToolItem.allCases, id: \.self) { item in
                if let s = spec(item, layout: layout, focused: focused), let key = s.shortcut {
                    Button(s.title, action: s.action).keyboardShortcut(key).disabled(!s.enabled)
                }
            }
            Button("Find in terminal", action: openFind).keyboardShortcut(TerminalFindKeys.find.key, modifiers: TerminalFindKeys.find.modifiers)
            Button("Split right") { splitFocused(.right) }.keyboardShortcut("d", modifiers: .command)
            Button("Split down") { splitFocused(.bottom) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Pane left") { change(keys: true) { $0.moveFocus(.left); return true } }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Pane right") { change(keys: true) { $0.moveFocus(.right); return true } }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Pane up") { change(keys: true) { $0.moveFocus(.top); return true } }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Pane down") { change(keys: true) { $0.moveFocus(.bottom); return true } }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private var backendChip: some View {
        let status = backendStatus
        return Chip(text: status.text, style: status.style).lineLimit(1)
    }

    private var backendStatus: (text: String, style: Chip.Style, color: Color) {
        let backend = "Tentacl"
        switch model.agents {
        case .available: return ("\(backend) connected", .ok, Tok.go)
        case .unavailable: return ("\(backend) not reachable", .problem, Tok.wait)
        case .loading: return ("Checking \(backend)…", .neutral, Tok.ink2)
        }
    }

    private var empty: some View {
        VStack(spacing: Tok.Space.s) {
            Text("No terminals").font(Tok.Font.heading).foregroundStyle(Tok.ink)
            Text(AgentsPane.text(for: model.visibleAgents) ?? "No agent of this project is running.").font(Tok.Font.body).foregroundStyle(Tok.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }

    private func keyboardBar(_ layout: TerminalPaneLayout, focused: TerminalTab) -> some View {
        let number = layout.focusedPane?.number ?? 1
        let prompt = promptOpen && promptHasKeys
        return HStack(spacing: 14) {
            (Text(TerminalKeyboard.barLead(prompt: prompt, live: keysLive(focused.paneID)))
                + Text(TerminalKeyboard.owner(label: focused.label, pane: number, panes: layout.count, prompt: prompt)).foregroundStyle(Tok.ink).fontWeight(.semibold))
                .fixedSize()
                .layoutPriority(1)
            // N327: hints that do not fit drop out whole from the right; "…" carries them as help.
            ViewThatFits(in: .horizontal) {
                ForEach(TerminalToolbarFit.splits(TerminalToolbarFit.hints), id: \.bar.count) { split in
                    HStack(spacing: 14) {
                        ForEach(split.bar, id: \.self) { Text($0) }
                        if !split.menu.isEmpty {
                            Text("…").help(split.menu.joined(separator: "\n")).accessibilityLabel("More keys: \(split.menu.joined(separator: ", "))")
                        }
                    }
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1)
        .pageMargin(.horizontal)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(Tok.rail)
        .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
    }

    // MARK: panes

    private func grid(_ layout: TerminalPaneLayout, tabs: [TerminalTab]) -> some View {
        let node = previewOpen ? layout.withPreview() : layout.root
        return TerminalPaneGrid(node: node, layout: layout, preview: previewOpen, resizable: node == layout.root, drops: drops, shownTarget: shownDrop,
                                onDrop: { pane, zone, providers in drop(on: pane, zone: zone, providers: providers) },
                                // A divider drag changes the panes on every step and saves when it ends.
                                onRatio: { path, ratio in change(save: false) { $0.setRatio(ratio, ofSplitAt: path); return true } },
                                onRatioEnd: saveLayout) { pane in
            if let tab = tabs.first(where: { $0.paneID == pane.terminal }) { card(tab, pane: pane, layout: layout) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ tab: TerminalTab, pane: TerminalPaneLayout.Pane, layout: TerminalPaneLayout) -> some View {
        let focused = pane.id == layout.focused
        let question = questions.first { $0.paneID == tab.paneID }
        let card = tab.cardID.flatMap { model.card(id: $0) }
        let prompt = focused && promptOpen
            ? TerminalPromptBox(label: tab.label, placeholder: TerminalComposer.placeholder(tab), text: $promptText,
                                disabledReason: TerminalComposer.disabledReason(agents: model.visibleAgents, tab: tab),
                                send: { text in await send(text, to: tab, question: question) },
                                onClose: closePrompt, onFocus: promptFocus)
            : nil
        return TerminalPaneCard(tab: tab, number: pane.number, panes: previewOpen ? min(layout.count, TerminalPaneLayout.maxPanesWithPreview) : layout.count,
                                focused: focused, appearance: model.terminalAppearance, reader: model.makeReader(), live: fixedScreens == nil ? tentacld.map { model.liveTerminals.session(id: tab.paneID, client: $0) } : nil, fixedScreen: fixedScreens?[tab.paneID],
                                question: focused ? question : nil, inbox: model.inbox, status: status(tab, question: question),
                                typing: tab.paneID == typingPane(layout), promptOpen: focused && promptOpen, promptKeys: focused && promptOpen && promptHasKeys, keysLive: keysLive(tab.paneID),
                                query: focused && finding ? query : "",
                                keyboardRequest: keyboardRequest, findRequest: findRequest, info: info(tab),
                                notes: tab.cardID == nil ? nil : CardFixNotes(card: card, revision: notesRevision, fixed: fixedNotes, onOpenCard: nil),
                                prompt: prompt,
                                onFocusPane: { change(keys: true) { $0.focus(pane.id); return true } },
                                // The × of an unfocused pane taps it too: the focus goes back to the pane that had it.
                                // A shell of the user's ends (after asking); any other terminal only leaves the pane.
                                onClose: tab.mine ? { closer.request(tab.paneID) }
                                    : layout.count > 1 ? { [before = layout.focused] in change(keys: true) { $0.close(pane.id, focusing: before); return true } } : nil,
                                onTerminalFocus: { on in terminalFocus(tab.paneID, pane: pane.id, on) },
                                onAction: { action in paneAction(action, pane: pane.id) },
                                broadcastMark: broadcast.isOn ? broadcast.isPicked(tab.paneID) : nil,
                                onBroadcast: { toggleBroadcastPane(tab.paneID) },
                                restored: TerminalSettings.restoreHistory(model.defaults) ? restoredShells.items[tab.paneID] : nil, onClearRestored: { clearRestored(tab.paneID) })
            .id(tab.paneID)
    }

    // MARK: preview

    /// The focused terminal's local page (N225's pane). Opens only when there is one (N234).
    @ViewBuilder private func preview(_ tab: TerminalTab) -> some View {
        let page = pages.pages[tab.paneID]
        let card = tab.cardID.flatMap { model.card(id: $0) }
        let add = card.map { c in { (line: String) in addFixNote(line, to: c) } }
        let send: (String) async -> String? = { line in await send(line, to: tab, question: nil) }
        let close = { previewOpen = false }
        Group {
            if let fixedPreview {
                PreviewPane(model: fixedPreview, source: page?.command, cardID: tab.label, addFixNote: add, sendToAgent: send, onClose: close)
            } else {
                PreviewPane(url: page?.url, source: page?.command, cardID: tab.label,
                            assetsFolder: card.map { $0.url.deletingLastPathComponent().appendingPathComponent("assets") },
                            addFixNote: add, sendToAgent: send, onClose: close)
            }
        }
        .id("\(tab.paneID)|\(page?.url.absoluteString ?? "")")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain).accessibilityLabel("Preview of \(tab.label)")
    }

    /// Pick element's note and the console errors go to the card's `## Fix notes` (the same path as the Preview tab, N225).
    private func addFixNote(_ line: String, to card: TaskCard) -> String? {
        do {
            try PreviewNote.append(line, toCardAt: card.url, writer: model.cardWriter)
            notesRevision += 1
            model.actionLog.append("added a preview fix note to \(card.id) from Terminals", project: model.selectedProjectID)
            return nil
        } catch {
            return "Could not add the note: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
    }

    /// The ⌘L box's Send: a typed answer to the agent's open free-text question goes through the Inbox's answer path; anything else is a prompt.
    private func send(_ text: String, to tab: TerminalTab, question: PendingQuestion?) async -> String? {
        if let question, question.question.kind == .freeText {
            return await model.inbox.answer(question, text: text) ? nil : (model.inbox.error ?? "The answer could not be sent.")
        }
        let failure = await TerminalComposer.send(text, to: tab.paneID, commander: model.makeCommander())
        if failure == nil { model.actionLog.append("prompted \(tab.label) from Terminals (\(tab.paneID))", project: model.selectedProjectID) }
        return failure
    }

    /// The status line: what the agent does (its last action, or the question), how long it has run and, for the PM, its context.
    private func status(_ tab: TerminalTab, question: PendingQuestion?) -> TerminalStatusLine {
        let agent = agents.first { $0.paneID == tab.paneID }
        let summary = agent.flatMap { model.agentSummary($0) }
        let message: String
        if question != nil { message = "Waiting for your answer" }
        else if let line = summary?.lastAction, !line.isEmpty { message = line }
        else if tab.kind == .shell, let cwd = agent?.cwd, !cwd.isEmpty { message = (cwd as NSString).abbreviatingWithTildeInPath }
        else { message = tab.stateLabel }
        var meta: [String] = []
        if let elapsed = summary?.elapsed { meta.append(Stats.durationText(elapsed)) }
        if tab.kind == .pm, let fraction = model.pmContextFraction { meta.append("ctx \(Int((fraction * 100).rounded()))%") }
        return TerminalStatusLine(color: tab.color, message: message, meta: meta.joined(separator: " · "))
    }

    // MARK: agent facts

    /// What the AGENT column showed: for the "i" popover and the sidebar row's menu.
    private func info(_ tab: TerminalTab) -> TerminalAgentInfo {
        let card = tab.cardID.flatMap { model.card(id: $0) }
        let agent = agents.first { $0.paneID == tab.paneID }
        let role: String
        let branch: String
        let facts: String
        switch tab.kind {
        case .pm:
            role = "PM"
            branch = model.selectedProject?.baseBranch ?? "—"
            facts = model.roleConfig(named: "pm").map { [ModelName.display($0.model), $0.effort].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "—"
        case .card:
            role = card?.roles.first ?? "dev"
            branch = card?.branch ?? "—"
            facts = card.map { c in let f = model.configuredAgentFacts(c); return f.effort == "—" ? f.model : "\(f.model) · \(f.effort)" } ?? "—"
        case .shell:
            role = "—"
            branch = "—"
            facts = "—"
        }
        let restart = agent.map { model.canRestartConversation($0) } == true
            ? StartButtonState(enabled: !model.isBusy, help: model.isBusy ? "Another action is running; wait until it finishes." : "Starts a new conversation with a hand-off note")
            : StartButtonState(enabled: false, help: "An agent on a task card is restarted with its card.")
        let stop = agent.map { model.canStop($0) } == true
            ? StartButtonState(enabled: !model.isBusy, help: "Closes this session (asks first)")
            : StartButtonState(enabled: false, help: "A task agent stops with its card.")
        return TerminalAgentInfo(role: role, branch: branch, model: facts, restart: restart, stop: stop,
                                 onOpenCard: tab.cardID.map { id in { onOpenCard(id) } }, onOpenChanges: tab.cardID.map { id in { onOpenChanges(id) } },
                                 onRestart: { if let agent { Task { await model.restartConversation(.handoff, agent: agent) } } },
                                 onStop: { if let agent { model.requestStop(agent) } },
                                 onCloseShell: tab.mine ? { closer.request(tab.paneID) } : nil)
    }
}

/// A card's Fix notes, read from the card file when the card, its file or a note written here changes.
private struct CardFixNotes: View {
    let card: TaskCard?
    let revision: Int
    let fixed: [FixNoteItem]?
    let onOpenCard: (() -> Void)?
    @State private var items: [FixNoteItem] = []

    var body: some View {
        FixNotesColumn(cardID: card?.id, items: fixed ?? items, onOpenCard: onOpenCard)
            .task(id: "\(card?.url.path ?? "")|\(card?.modified?.timeIntervalSince1970 ?? 0)|\(revision)") {
                guard fixed == nil else { return }
                items = card.map { FixNotes.items(cardAt: $0.url) } ?? []
            }
    }
}

struct TerminalStatusLine: Equatable {
    let color: Color
    let message: String
    let meta: String
}

/// The row's and the pane header's state icon (States.dc.html).
struct TerminalStateIcon: View {
    let icon: TerminalTab.Icon

    var body: some View {
        switch icon {
        case .working(let progress):
            ZStack {
                Circle().stroke(Tok.line, lineWidth: 2)
                Circle().trim(from: 0, to: max(0.04, progress)).stroke(Tok.work, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .padding(2)
        case .asks, .permission:
            Circle().fill(icon == .asks ? Tok.ask : Tok.wait).overlay { Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(Tok.askInk) }
        case .done:
            Circle().stroke(Tok.go, lineWidth: 1.6).overlay { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Tok.go) }.padding(1)
        case .idle:
            Circle().stroke(Tok.ink2, lineWidth: 1.6).padding(3)
        case .failed:
            Circle().stroke(Tok.stop, lineWidth: 1.6).overlay { Image(systemName: "xmark").font(.system(size: 6, weight: .bold)).foregroundStyle(Tok.stop) }.padding(1)
        case .shell:
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tok.ink2)
        case .pm:
            Circle().fill(Tok.you).frame(width: 8, height: 8)
        }
    }
}

enum TerminalPaneAction {
    case splitRight, splitDown
    case move(TerminalPaneLayout.Zone)
}

/// One pane: header (number, terminal, who has the keyboard, "i", ×), the terminal, and for the focused pane the ask dock; the status
/// line at the bottom; the ⌘L box over it while open.
private struct TerminalPaneCard: View {
    let tab: TerminalTab
    let number: Int
    let panes: Int
    let focused: Bool
    let appearance: TerminalAppearanceStore
    let fixedScreen: String?
    let question: PendingQuestion?
    @Bindable var inbox: AgentInboxModel
    let status: TerminalStatusLine
    let typing: Bool
    let promptOpen: Bool
    /// The ⌘L box has the keys (open and focused), not only open.
    let promptKeys: Bool
    /// The terminal is live and takes keys; else it shows polled text.
    let keysLive: Bool
    /// Filter: the focused pane's query ("" shows the whole screen).
    let query: String
    let keyboardRequest: Int
    /// Bumped by ⌘F from elsewhere on the screen: the focused pane's live terminal takes the keyboard and opens its find bar (N256).
    let findRequest: Int
    let info: TerminalAgentInfo
    let notes: CardFixNotes?
    let prompt: TerminalPromptBox?
    let onFocusPane: () -> Void
    let onClose: (() -> Void)?
    let onTerminalFocus: (Bool) -> Void
    let onAction: (TerminalPaneAction) -> Void
    /// Broadcast (N271): nil while it is off, else whether this pane is picked.
    let broadcastMark: Bool?
    let onBroadcast: () -> Void
    /// The text of the shell this one replaced after a restart (N273).
    let restored: RestoredHistory?
    let onClearRestored: () -> Void
    @State private var poller: AgentScreenPoller
    /// The live terminal when tentacld has a session with this pane id (N231); until then, and without one, the polled text. Owned by
    /// `LiveTerminalStore`, so it survives this pane (N237).
    private let live: LiveTerminalSession?
    /// Find in a live terminal: the session's text from tentacld.
    @State private var liveText = ""
    @State private var showInfo = false
    @Environment(\.snapshotMode) private var snapshot

    init(tab: TerminalTab, number: Int, panes: Int, focused: Bool, appearance: TerminalAppearanceStore, reader: TerminalReading, live: LiveTerminalSession?, fixedScreen: String?, question: PendingQuestion?,
         inbox: AgentInboxModel, status: TerminalStatusLine, typing: Bool, promptOpen: Bool, promptKeys: Bool, keysLive: Bool, query: String, keyboardRequest: Int,
         findRequest: Int = 0, info: TerminalAgentInfo, notes: CardFixNotes?, prompt: TerminalPromptBox?, onFocusPane: @escaping () -> Void, onClose: (() -> Void)?,
         onTerminalFocus: @escaping (Bool) -> Void, onAction: @escaping (TerminalPaneAction) -> Void,
         broadcastMark: Bool? = nil, onBroadcast: @escaping () -> Void = {}, restored: RestoredHistory? = nil, onClearRestored: @escaping () -> Void = {}) {
        self.broadcastMark = broadcastMark; self.onBroadcast = onBroadcast; self.restored = restored; self.onClearRestored = onClearRestored
        self.tab = tab; self.number = number; self.panes = panes; self.focused = focused; self.appearance = appearance; self.fixedScreen = fixedScreen; self.question = question
        self.inbox = inbox; self.status = status; self.typing = typing; self.promptOpen = promptOpen; self.promptKeys = promptKeys; self.keysLive = keysLive; self.query = query
        self.keyboardRequest = keyboardRequest; self.findRequest = findRequest; self.info = info; self.notes = notes; self.prompt = prompt
        self.onFocusPane = onFocusPane; self.onClose = onClose; self.onTerminalFocus = onTerminalFocus; self.onAction = onAction
        // More lines than the Preview poll (60): this pane is the whole terminal.
        _poller = State(initialValue: AgentScreenPoller(reader: reader, target: tab.paneID, lines: 200, text: fixedScreen ?? ""))
        self.live = live
    }

    private var showsLive: Bool { !snapshot && live?.isLive == true }
    private var ring: Bool { focused && panes > 1 }
    /// The theme's colors: the header, status line and ask dock take them too, so the pane reads as one terminal (N236).
    private var t: TerminalTheme { appearance.appearance.palette }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.lineColor).frame(height: 1)
            screen
            if let question { AskDock(question: question, inbox: inbox, theme: t) }
            statusLine
        }
        .background(t.bg)
        .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(ring ? Tok.you : t.lineColor, lineWidth: ring ? 2 : 1))
        .overlay(alignment: .bottom) { if let prompt { prompt.padding(.horizontal, Tok.Space.m).padding(.bottom, 42) } }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { if !focused { onFocusPane() } })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(number): \(tab.label) terminal")
        .accessibilityAction(named: "Split right") { onAction(.splitRight) }
        .accessibilityAction(named: "Split down") { onAction(.splitDown) }
        .accessibilityAction(named: "Focus the pane on the left") { onAction(.move(.left)) }
        .accessibilityAction(named: "Focus the pane on the right") { onAction(.move(.right)) }
        .accessibilityAction(named: "Focus the pane above") { onAction(.move(.top)) }
        .accessibilityAction(named: "Focus the pane below") { onAction(.move(.bottom)) }
        .onAppear {
            if fixedScreen == nil && !snapshot { poller.appear(); live?.appear() }
            if focused && !promptOpen { takeKeys() }
        }
        .onDisappear { poller.disappear(); onTerminalFocus(false) }
        .onChange(of: live.map { ObjectIdentifier($0) }) { _, now in if now != nil, fixedScreen == nil, !snapshot { live?.appear() } }
        .onChange(of: live?.isLive) { _, now in if now == true { poller.disappear() } else if fixedScreen == nil && !snapshot { poller.appear() } }
        .onChange(of: showsLive) { _, now in if now && focused && !promptOpen { takeKeys() } }
        .onChange(of: keyboardRequest) { _, _ in if focused && !promptOpen { takeKeys() } }
        .onChange(of: findRequest) { _, _ in if focused { openFind() } }
        .task(id: showsLive && !query.isEmpty ? query : nil) {
            guard showsLive, !query.isEmpty, let live else { liveText = ""; return }
            // The program keeps writing: the lines Find shows are read again every second (N245).
            while !Task.isCancelled {
                liveText = await live.text()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The live terminal becomes the first responder: keystrokes go to it.
    private func takeKeys() {
        guard !snapshot, let live, showsLive else { return }
        DispatchQueue.main.async {
            if let window = live.view.window, window.firstResponder !== live.view { window.makeFirstResponder(live.view) }
        }
    }

    /// ⌘F from the toolbar or the sidebar: the terminal takes the keyboard, then its find bar opens and takes it from there. A filter that
    /// just ended puts the live terminal back on the next pass, so this waits one turn.
    private func openFind() {
        guard !snapshot, let live, live.isLive else { return }
        DispatchQueue.main.async {
            if let window = live.view.window, window.firstResponder !== live.view { window.makeFirstResponder(live.view) }
            live.view.find.open()
        }
    }

    private var header: some View {
        HStack(spacing: Tok.Space.s) {
            if panes > 1 {
                Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(focused ? Tok.askInk : t.fg)
                    .frame(width: 20, height: 20).background(focused ? Tok.you : t.lineColor, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            Circle().fill(tab.color).frame(width: 8, height: 8)
            Text(tab.label).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(t.fg).lineLimit(1).fixedSize()
            Text(tab.title).font(.system(size: 12)).foregroundStyle(t.dim).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Tok.Space.s)
            if let picked = broadcastMark {
                Button(action: onBroadcast) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(picked ? Tok.askInk : t.dim).frame(width: 26, height: 26)
                        .background(picked ? Tok.you : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(picked ? Tok.you : t.lineColor))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(picked ? "Broadcast reaches this pane: click to leave it out" : "Click to type into this pane too")
                .accessibilityLabel("Broadcast to \(tab.label)")
                .accessibilityValue(picked ? "on" : "off")
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
            Button(action: onFocusPane) {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard").font(.system(size: 11))
                    Text(TerminalKeyboard.paneText(focused: focused, prompt: promptKeys, live: keysLive)).lineLimit(1)
                }
                .font(Tok.Font.small).foregroundStyle(focused ? Tok.you : t.dim)
                .padding(.horizontal, Tok.Space.s).frame(height: 26)
                .background(focused ? Tok.youFill : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Tok.you : t.lineColor))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).fixedSize()
            .help(!keysLive ? "This terminal shows text only: use ⌘L to send a prompt" : focused ? "Typing goes to this terminal" : "Move the keyboard to this pane (⌥⌘ arrows)")
            iconButton("info.circle", label: "About \(tab.label)", help: "Role, branch, model, Open card, Changes, Restart and Stop") { showInfo.toggle() }
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { TerminalAgentPopover(tab: tab, info: info, notes: notes) }
            if let onClose {
                iconButton("xmark", label: tab.mine ? "Close shell \(tab.title)" : "Close pane \(number)",
                           help: tab.mine ? "Close this shell (it ends)" : "Close this pane (the agent keeps running)", action: onClose)
            }
        }
        .padding(.leading, Tok.Space.s + 2).padding(.trailing, Tok.Space.s)
        .frame(height: 38)
        .background(t.chromeColor)
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(t.dim).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(label)
    }

    private var shown: String { TerminalComposer.filter(showsLive ? liveText : poller.text, query: query) }

    @ViewBuilder private var screen: some View {
        let look = appearance.appearance
        let style = look.polledText
        let lines = Text(shown.isEmpty ? " " : shown).font(Font(style.font as CTFont)).foregroundStyle(Color(nsColor: TerminalAppearance.ns(style.foreground))).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(style.padding)
        VStack(alignment: .leading, spacing: 0) {
            if let restored { RestoredHistoryBlock(restored: restored, theme: t, font: Font(style.font as CTFont), onClear: onClearRestored) }
            if let live, showsLive {
                if !query.isEmpty { ScrollView { lines }.defaultScrollAnchor(.bottom) }
                else { LiveTerminalView(session: live, onFocus: onTerminalFocus).padding(look.paddingPoints).accessibilityLabel("Terminal \(tab.label)") }
            } else {
                if let failure = live.flatMap(\.failure) { Text(failure).font(Tok.Font.small).foregroundStyle(Tok.wait).padding(.horizontal, Tok.Space.l).padding(.top, Tok.Space.s) }
                if let error = poller.error { Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).padding(.horizontal, Tok.Space.l).padding(.top, Tok.Space.s) }
                if snapshot {
                    // The newest lines are at the bottom of a terminal.
                    Color.clear.overlay(alignment: .bottomLeading) { lines }.clipped()
                } else {
                    ScrollView { lines }.defaultScrollAnchor(.bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity)
        .background(t.bg)
    }

    private var statusLine: some View {
        // A tentacld session that exited shows its last screen and the exit code (N231).
        let exited = snapshot ? nil : live?.exitCode
        return HStack(spacing: Tok.Space.s) {
            Circle().fill(exited.map { $0 == 0 || $0 == nil ? Tok.ink2 : Tok.stop } ?? status.color).frame(width: 6, height: 6)
            Text(exited.map { LiveTerminalSession.exitText($0) } ?? status.message).foregroundStyle(t.fg).lineLimit(1).truncationMode(.tail)
            if !status.meta.isEmpty { Text(status.meta).foregroundStyle(t.dim).lineLimit(1) }
            Spacer(minLength: Tok.Space.s)
            if typing {
                Text(TerminalComposer.typingNote).foregroundStyle(Tok.you).lineLimit(1)
                    .padding(.horizontal, Tok.Space.s).padding(.vertical, 1).background(Tok.youFill, in: Capsule())
            }
        }
        .font(Tok.Font.small)
        .padding(.horizontal, Tok.Space.m)
        .frame(height: 30)
        .background(t.chromeColor)
        .overlay(alignment: .top) { Rectangle().fill(t.lineColor).frame(height: 1) }
    }
}

extension TerminalAppearance {
    /// The polled text (no tentacld session) and Find's lines: the live terminal's font, size, foreground and padding (N236).
    var polledText: (font: NSFont, foreground: UInt32, padding: CGFloat) { (nsFont(), palette.foreground, paddingPoints) }
}

/// The ⌘L box (N234): a longer prompt for the focused pane's terminal, sent as one message. Enter sends, ⇧Enter adds a line, Esc
/// closes; after Send or Esc the keyboard goes back to the terminal.
private struct TerminalPromptBox: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let disabledReason: String?
    let send: (String) async -> String?
    let onClose: () -> Void
    let onFocus: (Bool) -> Void
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshot

    private var canSend: Bool { TerminalComposer.canSend(text: text, reason: disabledReason, sending: sending) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            (Text("Prompt to ") + Text(label).foregroundStyle(Tok.ink).fontWeight(.semibold) + Text(" · sent as one message · \(TerminalComposer.hint)"))
                .font(.system(size: 12)).foregroundStyle(Tok.ink2).lineLimit(2)
            field
                .padding(.horizontal, Tok.Space.s + 2).padding(.vertical, Tok.Space.s)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .background(Tok.rail, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
            HStack(spacing: Tok.Space.s) {
                if let message = error ?? disabledReason { Text(message).font(Tok.Font.small).foregroundStyle(Tok.wait).lineLimit(2) }
                Spacer(minLength: 0)
                Button(action: onClose) { Text("Cancel").font(.system(size: 12)).foregroundStyle(Tok.ink2).padding(.horizontal, Tok.Space.m).frame(height: 30).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Close the box (Esc)")
                Button(action: submit) {
                    Text("Send ↩").font(.system(size: 12, weight: .bold)).foregroundStyle(Tok.askInk)
                        .padding(.horizontal, Tok.Space.m).frame(height: 30).background(Tok.you, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(!canSend).opacity(canSend ? 1 : 0.5)
                .help(disabledReason ?? "Send to \(label) as one prompt")
            }
        }
        .padding(Tok.Space.s + 2)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.you))
        .shadow(color: .black.opacity(Tok.shadowOpacity(0.45)), radius: 20, y: 16)
        .onAppear { if !snapshot { DispatchQueue.main.async { focused = true } } }
        .onChange(of: focused) { _, now in onFocus(now) }
        .onDisappear { if focused { onFocus(false) } }
        .accessibilityElement(children: .contain).accessibilityLabel("Prompt box for \(label)")
    }

    @ViewBuilder private var field: some View {
        if snapshot {
            Text(text.isEmpty ? placeholder : text).font(Tok.Font.body).foregroundStyle(text.isEmpty ? Tok.ink3 : Tok.ink)
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Tok.Font.body).foregroundStyle(Tok.ink)
                .lineLimit(3...8)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { text += "\n"; return .handled }
                    submit()
                    return .handled
                }
                .onExitCommand(perform: onClose)
                .accessibilityLabel("Prompt to \(label)")
        }
    }

    private func submit() {
        guard canSend else { return }
        let message = text
        sending = true
        error = nil
        Task {
            let failure = await send(message)
            sending = false
            error = failure
            if failure == nil {
                if text == message { text = "" }
                onClose()
            }
        }
    }
}

/// The question an agent asks, under the focused pane's terminal: the numbered options and Skip, answered through the Inbox (as `QuestionCards`).
private struct AskDock: View {
    let question: PendingQuestion
    @Bindable var inbox: AgentInboxModel
    let theme: TerminalTheme

    private var q: AgentQuestion { question.question }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s + 2) {
                Chip(text: q.kind == .permission ? "Needs permission" : q.kind == .plan ? "Needs approval" : "Asks you", style: .ask)
                Text(q.isCall ? q.title : q.text).font(q.kind == .permission ? Tok.Font.mono : Tok.Font.body.weight(.semibold)).foregroundStyle(theme.fg)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if q.terminalOnly || q.isCall {
                Text(q.isCall ? "Several questions: answer them from the Inbox (Answer…) or in the terminal." : "Answer this one in the terminal.")
                    .font(Tok.Font.small).foregroundStyle(theme.dim)
            } else if q.kind == .freeText {
                HStack(spacing: Tok.Space.s) {
                    Text("Type the answer in the terminal, or in the prompt box (⌘L).").font(Tok.Font.small).foregroundStyle(theme.dim)
                    skip
                }
            } else {
                FlowLayout(spacing: Tok.Space.s, lineSpacing: Tok.Space.s) {
                    ForEach(q.options.filter { !$0.isSpecial }, id: \.number) { option in
                        Button { Task { await inbox.answer(question, option: option) } } label: {
                            HStack(spacing: 5) {
                                Text("\(option.number)").foregroundStyle(theme.dim)
                                Text(option.label).foregroundStyle(option.role == .allowAlways ? Tok.stop : theme.fg).lineLimit(1)
                            }
                            .font(Tok.Font.body).padding(.horizontal, Tok.Space.m).frame(height: 32)
                            .background(theme.chromeColor, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.lineColor))
                        }
                        .buttonStyle(.plain).disabled(inbox.sending)
                        .help(option.role == .allowAlways ? alwaysAllowWarning : option.detail)
                    }
                    if q.kind == .choice { skip }
                }
            }
            if let error = inbox.error { Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).lineLimit(2) }
        }
        .padding(.horizontal, Tok.Space.l - 2).padding(.vertical, Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.ask.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(Tok.ask.opacity(0.5)).frame(height: 1) }
    }

    private var skip: some View {
        Button { Task { await inbox.skip(question) } } label: {
            Text("Skip").foregroundStyle(theme.dim).font(Tok.Font.body).padding(.horizontal, Tok.Space.m).frame(height: 32)
        }
        .buttonStyle(.plain).disabled(inbox.sending)
        .help("Tell the agent to carry on without an answer")
    }
}

/// The pane header's "i" popover (N234, the AGENT column before): role, branch and model, Open card and Changes, Restart and Stop,
/// and a card's Fix notes.
private struct TerminalAgentPopover: View {
    let tab: TerminalTab
    let info: TerminalAgentInfo
    let notes: CardFixNotes?

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            Text("AGENT").font(Tok.Font.small.weight(.semibold)).tracking(0.9).foregroundStyle(Tok.ink2)
            HStack(spacing: Tok.Space.s) {
                Text(tab.label).font(Tok.Font.body.weight(.semibold)).foregroundStyle(Tok.ink)
                Text(tab.stateLabel).font(Tok.Font.small).foregroundStyle(tab.color).padding(.horizontal, Tok.Space.s).padding(.vertical, 2)
                    .background(tab.color.opacity(0.16), in: Capsule())
            }
            Grid(alignment: .leading, horizontalSpacing: Tok.Space.s + 2, verticalSpacing: Tok.Space.s) {
                row("Role", Text(info.role))
                row("Branch", Text(info.branch).font(Tok.Font.mono))
                row("Model", Text(info.model))
            }
            .font(.system(size: 12))
            HStack(spacing: Tok.Space.s) {
                Button("Open card") { info.onOpenCard?() }.buttonStyle(PanelButtonStyle()).disabled(info.onOpenCard == nil)
                Button("Changes") { info.onOpenChanges?() }.buttonStyle(PanelButtonStyle(tint: WaitingTint.review.color)).disabled(info.onOpenChanges == nil)
            }
            if let close = info.onCloseShell {
                Button("Close shell", action: close).buttonStyle(PanelButtonStyle(tint: Tok.stop)).help("Ends this shell (asks first)")
            }
            HStack(spacing: Tok.Space.s) {
                Button("Restart", action: info.onRestart).buttonStyle(PanelButtonStyle()).disabled(!info.restart.enabled).help(info.restart.help)
                Button("Stop", action: info.onStop).buttonStyle(PanelButtonStyle(tint: Tok.stop)).disabled(!info.stop.enabled).help(info.stop.help)
            }
            if let notes { notes }
        }
        .padding(Tok.Space.l)
        .frame(width: 300, alignment: .leading)
        .background(Tok.pane)
    }

    private func row(_ label: String, _ value: Text) -> some View {
        GridRow {
            Text(label).foregroundStyle(Tok.ink2)
            value.foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
        }
    }
}
