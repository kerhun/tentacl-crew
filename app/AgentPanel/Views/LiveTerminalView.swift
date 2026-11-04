import SwiftUI
import AppKit
import SwiftTerm

/// SwiftTerm's view, with the terminal's own answers dropped. tentacld's headless terminal already answers every query in the output
/// (device attributes, cursor position, OSC 7501), so an answer from this view would reach the program twice: from the ring replayed on
/// attach (old queries) and from live output. Mouse reports go through the same path but are made outside a feed, so they still go out.
final class LiveTerminalNSView: TerminalView {
    /// Only touched on the main thread: every feed runs there.
    private var feeding = false

    func feedQuiet(_ bytes: [UInt8]) {
        feeding = true
        feed(byteArray: bytes[...])
        feeding = false
        find.outputArrived()
    }

    /// ⌘F find bar (N252).
    private(set) lazy var find = TerminalFind(view: self)
    private var findKeys: Any?

    /// ⌘F opens the bar, ⌘G / ⇧⌘G step, only while the keyboard is in this terminal or its bar. A local monitor, because SwiftTerm's
    /// key methods cannot be overridden from here and it comes before the Terminals toolbar's own ⌘F.
    func findKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, event.modifierFlags.intersection([.command, .option, .control]) == .command,
              let responder = window.firstResponder, responder === self || ((responder as? NSView)?.isDescendant(of: self) ?? false)
                || ((responder as? NSTextView)?.delegate as? NSView)?.isDescendant(of: self) == true else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f" where !event.modifierFlags.contains(.shift): find.open(); return true  // ⇧⌘F is the Terminals Filter (N256)
        case "g" where find.isOpen: find.step(forward: !event.modifierFlags.contains(.shift)); return true
        default: return false
        }
    }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if Thread.isMainThread, MainActor.assumeIsolated({ if engine == nil { engine = source }; return feeding }) { return }
        super.send(source: source, data: data)
    }

    /// The view's terminal engine, which SwiftTerm keeps to itself: learned from its first answer (a status report asked for at init).
    private var engine: Terminal?

    override init(frame: CGRect) {
        super.init(frame: frame)
        feedQuiet([0x1B, 0x5B, 0x35, 0x6E])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var columns: Int { engine?.cols ?? 80 }

    /// The visible grid, one string per row, each cut at the view's width (a row can still hold cells from when the view was wider).
    func screenLines() -> [String] {
        guard let engine else { return [] }
        return engine.terminalLock.withLock { (0..<engine.rows).map { Self.rowText(engine, $0) } }
    }

    private static func rowText(_ engine: Terminal, _ row: Int) -> String {
        (engine.getLine(row: row)?.translateToString(trimRight: true, startCol: 0, endCol: engine.cols, skipNullCellsFollowingWide: true, textProvider: { engine.getText(for: $0) }) ?? "")
            .replacingOccurrences(of: "\u{0}", with: " ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// Copy on select, and the editor for file:line links (N268): set from the appearance by `apply`.
    var copyOnSelect = false
    var editor: TerminalAppearance.Editor = .defaultApp
    /// The folder relative paths are looked up in: where the program was started, or the directory it reported (OSC 7) since.
    var folder: String?
    private var pressPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let moved = pressPoint.map { hypot($0.x - point.x, $0.y - point.y) > 3 } ?? false
        super.mouseUp(with: event)
        if copyOnSelect, let text = getSelection(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if event.modifierFlags.contains(.command), !moved, let link = fileLink(at: point) { TerminalFileLink.open(link, editor: editor) }
    }

    /// The file named under `point` (view coordinates), if it exists.
    func fileLink(at point: NSPoint) -> TerminalFileLink.Match? {
        guard let cell = cell(at: point), let engine else { return nil }
        let line = engine.terminalLock.withLock { Self.rowText(engine, cell.row) }
        return TerminalFileLink.word(in: line, at: cell.col).flatMap { TerminalFileLink.match(word: $0, folder: folder) }
    }

    /// The grid cell under `point`: the view has no padding, so the cell size is the optimal frame over the grid (less a classic scroller).
    private func cell(at point: NSPoint) -> (col: Int, row: Int)? {
        let dims = terminalDimensions
        guard dims.cols > 0, dims.rows > 0 else { return nil }
        let optimal = getOptimalFrameSize().size
        let scroller = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let w = (optimal.width - scroller) / CGFloat(dims.cols), h = optimal.height / CGFloat(dims.rows)
        guard w > 0, h > 0 else { return nil }
        let col = Int(point.x / w), row = Int((bounds.height - point.y) / h)
        return (0..<dims.cols).contains(col) && (0..<dims.rows).contains(row) ? (col, row) : nil
    }

    /// The keyboard came to (true) or left (false) this terminal (N234: the typing hold and the focused pane follow it). SwiftTerm's
    /// first responder methods cannot be overridden here, so the window's first responder is watched.
    var onFocus: ((Bool) -> Void)?
    private var focusWatch: NSKeyValueObservation?
    private var keysHere = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let findKeys { NSEvent.removeMonitor(findKeys); self.findKeys = nil }
        if window != nil {
            findKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.findKey(event) == true ? nil : event }
            }
        } else { find.close() }
        focusWatch = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.focusChanged(window.firstResponder === self) }
        }
        if window == nil { focusChanged(false) }
    }

    private func focusChanged(_ now: Bool) {
        guard now != keysHere else { return }
        keysHere = now
        onFocus?(now)
    }
}

/// One tentacld session shown live (N231): checks `list` for the id, sends the view's size, attaches, shows the daemon's screen snapshot
/// without answering, then feeds live bytes. Keystrokes go to the attachment, size changes to `resize` (debounced). The session and its
/// view belong to `LiveTerminalStore` (N237), not to a pane: panes come and go, the screen stays. `disappear` detaches.
@MainActor @Observable
final class LiveTerminalSession {
    enum Phase: Equatable {
        case checking
        /// tentacld has no session with this id (or does not answer): the card shows its polled text.
        case absent
        case live
        case exited(Int?)
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    @ObservationIgnored let id: String
    @ObservationIgnored let client: TentacldClient
    @ObservationIgnored let view: LiveTerminalNSView
    @ObservationIgnored private var attachment: TentacldClient.Attachment?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var lastSizeChange: ContinuousClock.Instant?
    /// Attachments made so far (tests count re-attaches).
    @ObservationIgnored private(set) var attachCount = 0
    /// The last input sent with `write` while no attachment is there; the next one waits for it (order).
    @ObservationIgnored private var inputTail: Task<Void, Never>?
    /// Set when the attachment is closed to attach again at the view's size.
    @ObservationIgnored private var resync = false
    /// False asks the daemon for the raw ring only, as an older daemon without snapshots would answer (tests).
    @ObservationIgnored private let snapshots: Bool
    @ObservationIgnored private let recheck: Duration
    @ObservationIgnored private let resizeDelay: Duration
    /// The session is gone from the daemon after it was shown (a user's shell that ended is removed by tentacld at once).
    @ObservationIgnored var onGone: (() -> Void)?
    @ObservationIgnored private lazy var bridge = LiveTerminalBridge(session: self)
    /// The look (N236): applied at start and again on every change, so all open terminals change at once.
    @ObservationIgnored let appearance: TerminalAppearanceStore
    @ObservationIgnored private var appearanceToken: UUID?

    init(id: String, client: TentacldClient, appearance: TerminalAppearanceStore, recheck: Duration = .seconds(3), resizeDelay: Duration = .milliseconds(150),
         snapshots: Bool = true) {
        self.id = id
        self.snapshots = snapshots
        self.client = client
        self.appearance = appearance
        self.recheck = recheck
        self.resizeDelay = resizeDelay
        view = LiveTerminalNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        appearance.appearance.apply(to: view)
        view.terminalDelegate = bridge
        appearanceToken = appearance.addListener { [weak view] next in if let view { next.apply(to: view) } }
    }

    deinit {
        if let token = appearanceToken { Task { @MainActor [appearance] in appearance.removeListener(token) } }
    }

    /// Live or exited: the view shows the session's screen.
    var isLive: Bool { if case .live = phase { true } else if case .exited = phase { true } else { false } }
    var failure: String? { if case .failed(let message) = phase { message } else { nil } }
    var exitCode: Int?? { if case .exited(let code) = phase { .some(code) } else { nil } }

    func appear() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func disappear() {
        task?.cancel(); task = nil
        resizeTask?.cancel(); resizeTask = nil
        attachment?.close(); attachment = nil
        resync = false
    }

    /// The session's text from tentacld (Find in a live terminal filters it).
    func text(lines: Int = 2000) async -> String { (try? await client.read(id: id, lines: lines)) ?? "" }

    /// Looks for the session, then attaches: the view's size goes to the daemon first, so the snapshot it makes fits the view. A size
    /// change attaches again (`resync`): the view and the daemon each resize on their own, and bytes written for the old size may reach a
    /// view that already has the new one; a snapshot taken at the new size puts the view back on the daemon's screen.
    ///
    /// Never ends by itself (N244): when the stream ends (the program exited, an agent restarted under the same name, tentacld
    /// restarted) it goes back to polling `list` and attaches again as soon as the id shows another process, or comes back alive. Daemon
    /// errors back off (up to ten times `recheck`).
    private func run() async {
        var backoff = recheck
        let slowest = recheck * 10
        var everAttached = false
        var quietRetry = false
        /// The process whose screen the view shows: attaching again is only for another process, or one that is alive after an exited one.
        var shown: (pid: Int, alive: Bool)?
        while !Task.isCancelled {
            let found: TentacldClient.SessionInfo?
            do {
                found = try await client.list().first { $0.id == id }
                backoff = recheck
            } catch {
                found = nil
                backoff = min(backoff * 2, slowest)
            }
            if Task.isCancelled { return }
            guard var info = found else {
                if !everAttached, phase != .absent { phase = .absent }
                try? await Task.sleep(for: backoff)
                continue
            }
            if let shown, shown == (info.pid, info.alive) {
                try? await Task.sleep(for: backoff)
                continue
            }
            var daemonSize = (cols: info.cols, rows: info.rows)
            while !Task.isCancelled {
                let dims = view.terminalDimensions
                if info.alive, dims.cols >= 2, dims.rows >= 2, (daemonSize.cols, daemonSize.rows) != (dims.cols, dims.rows) {
                    // a failed resize is tried once more before attaching at the old size (the attach mismatch then resyncs)
                    do { try await client.resize(id: id, cols: dims.cols, rows: dims.rows) } catch {
                        try? await Task.sleep(for: recheck / 10)
                        _ = try? await client.resize(id: id, cols: dims.cols, rows: dims.rows)
                    }
                }
                let a: TentacldClient.Attachment
                do { a = try await client.attach(id: id, snapshot: snapshots) } catch {
                    if Task.isCancelled { return }
                    // the first failure after a working attach is retried quietly; only a repeated one shows
                    if !(everAttached && quietRetry) { phase = .failed((error as? LocalizedError)?.errorDescription ?? "Could not attach to the terminal.") }
                    shown = nil
                    everAttached = true
                    backoff = quietRetry ? recheck : backoff
                    quietRetry = false
                    backoff = min(backoff * 2, slowest)
                    try? await Task.sleep(for: backoff)
                    break
                }
                if Task.isCancelled { a.close(); return }
                attachment = a
                quietRetry = true
                attachCount += 1
                resync = false
                everAttached = true
                daemonSize = (a.cols, a.rows)
                // RIS first: an attach starts from a clean screen, then the snapshot rebuilds it. A daemon without snapshots only has the
                // raw ring, drawn at other sizes: it is not replayed; the size sent above and the redraw that daemon asks for on attach repaint.
                view.feedQuiet([0x1B, 0x63] + (a.isSnapshot ? [UInt8](a.ring) : []))
                phase = info.alive ? .live : .exited(info.exitCode)
                view.folder = info.cwd
                shown = (info.pid, info.alive)
                if resizeTask == nil { requestResync() }   // the view may have been resized while attaching (a pending trailing change does that itself)
                for await chunk in a.output {
                    if Task.isCancelled { break }
                    view.feedQuiet([UInt8](chunk))
                }
                if Task.isCancelled { return }
                attachment = nil
                if resync, info.alive { continue }
                let after = try? await client.list().first { $0.id == id }
                if let after, !after.alive {
                    phase = .exited(after.exitCode)
                    shown = (after.pid, false)
                    info = after
                } else {
                    shown = nil   // gone, or the connection broke on a live session: look again, attach if it is there
                    if after == nil { phase = .failed("tentacld closed the terminal."); onGone?() }
                }
                try? await Task.sleep(for: recheck)
                break
            }
        }
    }

    /// Typed input and pastes: written off the main thread, in order (to the attachment, or by `write` while there is none).
    fileprivate func typed(_ data: ArraySlice<UInt8>) {
        guard case .live = phase else { return }
        let bytes = Data(data)
        if let attachment { attachment.send(bytes); return }
        let previous = inputTail
        inputTail = Task { [client, id] in
            await previous?.value
            try? await client.write(id: id, data: bytes)
        }
    }

    /// Leading + trailing throttle: the first change after a quiet period (`resizeDelay`) goes at once (a font step, padding, a pane added);
    /// a burst (a divider or window drag, an animation) sends the first change and one more after the last, so the view does not
    /// re-attach many times a second.
    fileprivate func sizeChanged(cols: Int, rows: Int) {
        // The program follows every step of a drag at once (in order); the re-attach below only settles the view's screen.
        if case .live = phase, attachment != nil, cols >= 2, rows >= 2 {
            let previous = inputTail
            inputTail = Task { [client, id] in
                await previous?.value
                try? await client.resize(id: id, cols: cols, rows: rows)
            }
        }
        let now = ContinuousClock.now
        let quiet = lastSizeChange.map { now - $0 >= resizeDelay } ?? true
        lastSizeChange = now
        resizeTask?.cancel(); resizeTask = nil
        if quiet { requestResync(); return }
        resizeTask = Task { [weak self, resizeDelay] in
            try? await Task.sleep(for: resizeDelay)
            if Task.isCancelled { return }
            self?.resizeTask = nil
            self?.requestResync()
        }
    }

    /// The view's size is not the daemon's: end the attachment, `run` makes the daemon match and attaches again.
    private func requestResync() {
        let size = view.terminalDimensions
        guard case .live = phase, size.cols >= 2, size.rows >= 2, let attachment, (attachment.cols, attachment.rows) != (size.cols, size.rows) else { return }
        resync = true
        attachment.close()
    }
}

/// The live sessions of the Terminals screen, by session id (N237). A pane came and went with every tab switch and every drop that
/// rebuilt the pane tree, and its session (and view) with it; the new view then had to be filled again from the daemon. Here a session
/// outlives its pane: the same view, with its screen, is shown wherever the terminal is, and stays attached while hidden. A session is
/// released when its terminal is gone from the project (closed agent, another project).
@MainActor
final class LiveTerminalStore {
    let appearance: TerminalAppearanceStore
    private var sessions: [String: LiveTerminalSession] = [:]
    /// A shown session is gone from the daemon (its id).
    var onGone: ((String) -> Void)?

    init(appearance: TerminalAppearanceStore) { self.appearance = appearance }

    /// The terminal's session; a session made for another daemon is replaced.
    func session(id: String, client: TentacldClient) -> LiveTerminalSession {
        if let s = sessions[id], s.client.socketPath == client.socketPath { return s }
        sessions[id]?.disappear()
        let s = LiveTerminalSession(id: id, client: client, appearance: appearance)
        s.onGone = { [weak self] in self?.onGone?(id) }
        sessions[id] = s
        return s
    }

    /// Releases (detaches) every session not in `ids`.
    func keep(_ ids: Set<String>) {
        for (id, s) in sessions where !ids.contains(id) { s.disappear(); sessions[id] = nil }
    }

    func removeAll() { keep([]) }

    var ids: Set<String> { Set(sessions.keys) }
}

/// The view's delegate: keystrokes and size changes back to the session. A separate object so the session needs no NSObject.
@MainActor
private final class LiveTerminalBridge: TerminalViewDelegate {
    weak var session: LiveTerminalSession?
    init(session: LiveTerminalSession) { self.session = session }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { session?.typed(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session?.sizeChanged(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let live = source as? LiveTerminalNSView else { return }
        let path = URL(string: directory).flatMap { $0.scheme == "file" ? $0.path : nil } ?? directory
        if path.hasPrefix("/") { live.folder = path }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The session's view in SwiftUI. The NSView lives in the session, so a re-render keeps the screen.
struct LiveTerminalView: NSViewRepresentable {
    let session: LiveTerminalSession
    var onFocus: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> LiveTerminalNSView { session.view.onFocus = onFocus; return session.view }
    func updateNSView(_ nsView: LiveTerminalNSView, context: Context) { nsView.onFocus = onFocus }
}

extension LiveTerminalSession {
    /// The daemon the Terminals screen asks; none in the test host, so tests never reach the real term.sock.
    /// `TENTACL_TERM_SOCKET` (a trial build, N236) points it at another daemon instead of the real socket.
    nonisolated static var appClient: TentacldClient? { appClient(socket: nil) }

    /// `socket`: tests name a temp socket; the test host then looks for it like the app looks for term.sock. nil: the app's own.
    nonisolated static func appClient(socket given: String?) -> TentacldClient? {
        let socket = given ?? ProcessInfo.processInfo.environment["TENTACL_TERM_SOCKET"] ?? TentacldClient.defaultSocketPath
        return (given == nil && PanelModel.runsUnderXCTest) || !FileManager.default.fileExists(atPath: socket) ? nil : TentacldClient(socketPath: socket)
    }

    /// The status line of an exited session.
    nonisolated static func exitText(_ code: Int?) -> String { code.map { "exited (code \($0))" } ?? "exited" }
}
