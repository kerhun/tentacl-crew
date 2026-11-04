import XCTest
import SwiftUI
import SwiftTerm
@testable import AgentPanel

/// The live terminal of the Terminals screen (N231), against the built helper on a temp socket (never the real term.sock).
@MainActor
final class LiveTerminalTests: XCTestCase {
    private var dir: String!
    private var socket: String!
    private var daemon: Process!
    private var client: TentacldClient!
    private var sessions: [LiveTerminalSession] = []
    private var appearance: TerminalAppearanceStore!

    override func setUp() async throws {
        dir = "/tmp/ltv-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        socket = dir + "/s.sock"
        client = TentacldClient(socketPath: socket)
        appearance = TerminalAppearanceStore(defaults: TestDefaults.make(self, prefix: "live-terminal-appearance"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: client.helper.path), "helper missing: \(client.helper.path)")
        daemon = Process()
        daemon.executableURL = client.helper
        daemon.arguments = ["--socket", socket]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["TENTACLD_HISTORY_DELAY": "0.1"]) { $1 }
        try daemon.run()
        try await waitUntil("daemon answers") { await self.client.ping() }
    }

    override func tearDown() async throws {
        for s in sessions { s.disappear() }
        sessions = []
        stopDaemon(daemon)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 8, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await cond()) == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func session(_ id: String) -> LiveTerminalSession {
        let s = LiveTerminalSession(id: id, client: client, appearance: appearance, recheck: .milliseconds(100), resizeDelay: .milliseconds(50))
        sessions.append(s)
        return s
    }

    private func screen(_ id: String) async throws -> [Substring] { try await client.read(id: id).split(separator: "\n") }

    /// A program that asks for the device attributes (`ESC[c`) once at start and again whenever `trig` appears, and writes all it gets to `got`.
    private func spawnAsker(_ id: String = "ask") async throws {
        let script = """
        stty raw -echo; printf '\\033[c'
        while :; do if [ -e trig ]; then rm trig; printf '\\033[c'; fi; sleep 0.05; done &
        exec cat > got
        """
        try await client.spawn(id: id, argv: ["/bin/sh", "-c", script], cwd: dir)
    }

    private func answers() -> Int {
        let got = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/got"))) ?? Data()
        return String(decoding: got, as: UTF8.self).components(separatedBy: "\u{1B}[?").count - 1
    }

    func testRingReplayDoesNotAnswerAgain() async throws {
        try await spawnAsker()
        try await waitUntil("the daemon's answer") { answers() == 1 }
        let s = session("ask")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.disappear()
        s.appear()   // reattach: the ring with the old query is replayed again
        try await waitUntil("live again") { s.phase == .live }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(answers(), 1, "only tentacld answers the query in the ring")
        // A query in live output: tentacld answers it, the view does not.
        FileManager.default.createFile(atPath: dir + "/trig", contents: Data())
        try await waitUntil("the second answer") { answers() >= 2 }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(answers(), 2)
    }

    func testKeystrokesReachThePty() async throws {
        try await client.spawn(id: "sh", argv: ["/bin/sh"], cwd: dir)
        let s = session("sh")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.view.send(txt: "echo typed-$((40+2))\r")   // the path a key press takes: the view's input sender, the delegate, the attachment
        try await waitUntil("typed-42") { try await screen("sh").contains("typed-42") }
    }

    func testResizeReachesThePty() async throws {
        try await client.spawn(id: "sh", argv: ["/bin/sh"], cwd: dir, cols: 100, rows: 30)
        let s = session("sh")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.view.setFrameSize(NSSize(width: 520, height: 260))
        try await waitUntil("new size") { let i = try await client.list().first; return (i?.cols ?? 100) < 100 && (i?.rows ?? 30) < 30 }
        let first = try await client.list().first
        let info = try XCTUnwrap(first)
        try await client.write(id: "sh", text: "stty size\n")
        try await waitUntil("stty size \(info.rows) \(info.cols)") { try await screen("sh").contains("\(info.rows) \(info.cols)") }
        XCTAssertLessThan(info.cols, 100)
    }

    func testNoSessionFallsBackToPolledText() async throws {
        let s = session("w5:p1")
        s.appear()
        try await waitUntil("absent") { s.phase == .absent }
        XCTAssertFalse(s.isLive)
        // The app's client is nil in the test host, so the Terminals screen never reaches the real term.sock.
        XCTAssertNil(LiveTerminalSession.appClient)
    }

    func testExitedSessionShowsItsLastScreenAndCode() async throws {
        try await client.spawn(id: "bye", argv: ["/bin/sh", "-c", "echo last-words; exit 4"], cwd: dir)
        try await waitUntil("exited") { try await client.list().first?.alive == false }
        let s = session("bye")
        s.appear()
        try await waitUntil("exited phase") { s.phase == .exited(4) }
        XCTAssertTrue(s.isLive, "an exited session still shows its screen")
        XCTAssertEqual(s.exitCode, .some(4))
        XCTAssertEqual(LiveTerminalSession.exitText(4), "exited (code 4)")
        let text = s.view.getText()
        XCTAssertTrue(text.contains("last-words"), text)
    }

    func testSessionThatEndsWhileAttachedTurnsExited() async throws {
        try await client.spawn(id: "sh", argv: ["/bin/sh"], cwd: dir)
        let s = session("sh")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.view.send(txt: "exit 7\r")
        try await waitUntil("exited 7") { s.phase == .exited(7) }
    }

    func testBackgroundStaysOursAfterReset() async throws {
        let view = LiveTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        TerminalAppearance.default.apply(to: view)
        let rail = NSColor(srgbRed: 0x10 / 255.0, green: 0x12 / 255.0, blue: 0x16 / 255.0, alpha: 1)
        func bg() -> String { (view.layer?.backgroundColor).flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map { "\($0.redComponent) \($0.greenComponent) \($0.blueComponent)" } ?? "none" }
        let want = "\(rail.redComponent) \(rail.greenComponent) \(rail.blueComponent)"
        XCTAssertEqual(bg(), want, "after apply")
        view.feedQuiet([0x1B, 0x63] + Array("hi".utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(bg(), want, "after RIS")
        XCTAssertEqual(view.nativeBackgroundColor.usingColorSpace(.sRGB).map { "\($0.redComponent) \($0.greenComponent) \($0.blueComponent)" }, want)
    }

    /// N236: one change of the appearance reaches every open terminal at once; a terminal opened after it starts with it.
    func testAppearanceChangeReachesEveryOpenSession() {
        let a = session("one"), b = session("two")
        XCTAssertEqual(a.view.nativeBackgroundColor, TerminalAppearance.ns(Tok.Hex.rail), "the default look is unchanged")
        XCTAssertEqual(a.view.font.pointSize, 12)
        appearance.appearance.followApp = false; appearance.appearance.theme = .dracula
        appearance.appearance.size = 16
        appearance.appearance.font = .menlo
        for s in [a, b] {
            XCTAssertEqual(s.view.nativeBackgroundColor, TerminalAppearance.ns(0x282A36))
            XCTAssertEqual(s.view.nativeForegroundColor, TerminalAppearance.ns(0xF8F8F2))
            XCTAssertEqual(s.view.font.pointSize, 16)
            XCTAssertEqual(s.view.font.fontName, "Menlo-Regular")
        }
        let c = session("three")
        XCTAssertEqual(c.view.nativeBackgroundColor, TerminalAppearance.ns(0x282A36), "a new session starts with the current look")
        XCTAssertEqual(c.view.font.pointSize, 16)
    }

    /// A session that is gone no longer listens (its view is not touched; nothing crashes on the next change).
    func testAGoneSessionStopsListening() async throws {
        weak var gone: LiveTerminalSession?
        do {
            let s = LiveTerminalSession(id: "x", client: client, appearance: appearance)
            gone = s
        }
        XCTAssertNil(gone)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(appearance.listenerCount, 0)
        appearance.appearance.followApp = false; appearance.appearance.theme = .gruvbox
    }

    /// N236: SwiftTerm has no padding, so the pane insets the live view by `paddingPoints` on every side; a change re-lays it out.
    func testPaddingInsetsTheLiveView() async throws {
        let model = await terminalsModel()
        try await client.spawn(id: "w6:p1", argv: ["/bin/sh"], cwd: dir)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalsView(model: model, selected: "w6:p1", tentacld: client).frame(width: 1200, height: 800))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        var live: LiveTerminalNSView?
        try await waitUntil("the live view in the window", timeout: 10) { live = Self.find(LiveTerminalNSView.self, in: host); return live != nil }
        let view = try XCTUnwrap(live)
        model.terminalAppearance.appearance.padding = .compact
        try await waitUntil("compact laid out") { host.layoutSubtreeIfNeeded(); return view.frame.width > 0 }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        let compact = view.frame.size
        model.terminalAppearance.appearance.padding = .roomy
        try await waitUntil("roomy laid out") { host.layoutSubtreeIfNeeded(); return view.frame.width != compact.width }
        let roomy = view.frame.size
        let extra = 2 * (TerminalAppearance.Padding.roomy.points - TerminalAppearance.Padding.compact.points)
        XCTAssertEqual(compact.width - roomy.width, extra, accuracy: 1)
        XCTAssertEqual(compact.height - roomy.height, extra, accuracy: 1)
    }

    // MARK: screenshots (written when AGENT_PANEL_SNAPSHOT_DIR is set)

    /// SwiftTerm leaves default-background cells transparent and paints its layer's color (rail) behind them; `cacheDisplay` does not
    /// draw layer colors, so the capture is flattened onto rail, which is what the window shows.
    private func png(_ view: NSView, background: UInt32 = Tok.Hex.rail) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(TerminalAppearance.ns(background).cgColor)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    private func save(_ data: Data?, _ name: String) throws {
        let data = try XCTUnwrap(data)
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
    }

    /// The Terminals screen in a real window, its shell tab attached to a tentacld session that runs vim (colors, cursor, line numbers).
    func testSnapshotLiveTerminalsScreen() async throws {
        let model = await terminalsModel()
        let file = dir + "/Demo.swift"
        try sample.write(toFile: file, atomically: true, encoding: .utf8)
        try await client.spawn(id: "w6:p1", argv: ["/usr/bin/vim", "-u", "NONE", "-N", "-c", "syntax on", "-c", "set number", "-c", "set background=dark", file], cwd: dir,
                               env: ["TERM": "xterm-256color"])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let root = TerminalsView(model: model, selected: "w6:p1", tentacld: client).frame(width: 1440, height: 872).background(Tok.bg)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        var live: LiveTerminalNSView?
        try await waitUntil("the live view in the window", timeout: 10) {
            live = Self.find(LiveTerminalNSView.self, in: host)
            return live != nil
        }
        let view = try XCTUnwrap(live)
        try await waitUntil("vim drew the file", timeout: 10) { view.getText().contains("struct Widget") }
        try await waitUntil("the session took the view's size") { let i = try await client.list().first; return i?.cols != 100 }
        try await Task.sleep(nanoseconds: 800_000_000)
        host.layoutSubtreeIfNeeded()
        try save(png(host), "N231-terminals-live")
        try save(png(view), "N231-live-view")
    }

    /// N324: a program that draws a rule across the full width on every SIGWINCH, in a real window resized several times: no wrapped line.
    func testSnapshotRulesFollowWidenAndNarrow() async throws {
        let model = await terminalsModel()
        let script = "draw() { c=$(stty size | cut -d' ' -f2); printf '\\033[2J\\033[H'; i=0; while [ $i -lt $c ]; do printf '='; i=$((i+1)); done; printf '\\ncols %s\\n' $c; }; trap draw WINCH; draw; while :; do sleep 0.1; done"
        try await client.spawn(id: "w6:p1", argv: ["/bin/sh", "-c", script], cwd: dir, env: ["TERM": "xterm-256color"])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalsView(model: model, selected: "w6:p1", tentacld: client).frame(maxWidth: .infinity, maxHeight: .infinity).background(Tok.bg))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        var live: LiveTerminalNSView?
        try await waitUntil("the live view", timeout: 10) { live = Self.find(LiveTerminalNSView.self, in: host); return live != nil }
        let view = try XCTUnwrap(live)
        for (i, w) in [1440, 1100, 760, 1250, 900].enumerated() {
            window.setContentSize(NSSize(width: w, height: 900))
            host.layoutSubtreeIfNeeded()
            let cols = view.terminalDimensions.cols
            try await waitUntil("the screen says cols \(cols)", timeout: 5) { view.getText().contains("cols \(cols)") }
            try await Task.sleep(nanoseconds: 300_000_000)
            let lines = view.getText().split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first?.count, cols, "the rule is one full line at \(cols) columns")
            XCTAssertEqual(lines.first { $0.hasPrefix("cols") }, "cols \(cols)")
            try save(png(host), "N324-resize-\(i)-\(w)")
        }
    }

    // MARK: N236 trial: four live panes in a real window, driven with real key and scroll events

    private func key(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func type(_ text: String, into window: NSWindow) {
        for ch in text { window.sendEvent(ch == "\r" ? key("\r", code: 36, in: window) : key(String(ch), in: window)) }
    }

    func testTrialFourLivePanesTypingCopyScrollAndThemes() async throws {
        let ids = ["w6:p1", "w6:p2", "w6:p3", "w6:p4"]
        let model = await terminalsModel(shells: ids)
        for id in ids { try await client.spawn(id: id, argv: ["/bin/zsh", "-f"], cwd: dir, env: ["TERM": "xterm-256color", "PS1": "%F{green}%1~%f %# "]) }
        var layout = TerminalPaneLayout(terminal: ids[0])
        layout.drop(ids[1], on: 1, zone: .right)
        layout.drop(ids[2], on: 1, zone: .bottom)
        layout.drop(ids[3], on: layout.pane(showing: ids[1])!.id, zone: .bottom)
        XCTAssertEqual(layout.count, 4)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalsView(model: model, panes: layout, tentacld: client).frame(width: 1440, height: 872).background(Tok.bg))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var views: [LiveTerminalNSView] = []
        try await waitUntil("four live views", timeout: 10) { views = Self.findAll(LiveTerminalNSView.self, in: host); return views.count == 4 }
        // zsh throws away input that arrives before its line editor starts: type only once every shell has drawn its prompt.
        for id in ids { try await waitUntil("\(id) shows its prompt", timeout: 10) { try await self.client.read(id: id).contains("%") } }
        // Typing: each pane gets the keyboard and its own line, through the window's real key path.
        for (n, view) in views.enumerated() {
            window.makeFirstResponder(view)
            type("echo typed-in-pane-\(n + 1)\r", into: window)
        }
        for n in 1...4 {
            try await waitUntil("pane \(n) echoed") { try await ids.asyncContains { try await self.client.read(id: $0).components(separatedBy: "typed-in-pane-\(n)").count > 2 } }
        }
        try await settle()
        try save(themedPNG(host, model.terminalAppearance), "N236-trial-four-default")
        // Scroll back: 300 lines, then the wheel moves the view up from the bottom.
        let first = views[0]
        // The pane focus handlers move the keyboard a moment after it is given: wait until it stays on the first pane.
        try await waitUntil("the keyboard stays on pane 1", timeout: 5) {
            window.makeFirstResponder(first)
            try await Task.sleep(nanoseconds: 300_000_000)
            return window.firstResponder === first
        }
        type("seq 1 300\r", into: window)
        try await waitUntil("seq printed") { first.getText().contains("300") }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(first.scrollPosition, 1, accuracy: 0.01, "at the bottom")
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0)!
        wheel.location = CGPoint(x: 100, y: 100)
        first.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThan(first.scrollPosition, 1, "scrolled back")
        // ⌘C: select all and copy through the menu action; the pasteboard is restored afterwards.
        let saved = NSPasteboard.general.string(forType: .string)
        defer { NSPasteboard.general.clearContents(); if let saved { NSPasteboard.general.setString(saved, forType: .string) } }
        first.selectAll()
        first.copy(self)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("typed-in-pane-1") == true)
        first.selectNone()
        // Themes, font, size, cursor: every pane changes at once.
        var look = TerminalAppearance()
        look.followApp = false; look.theme = .dracula; look.font = .menlo; look.size = 14; look.cursor = .bar
        model.terminalAppearance.appearance = look
        for v in views { XCTAssertEqual(v.nativeBackgroundColor, TerminalAppearance.ns(0x282A36)); XCTAssertEqual(v.font.pointSize, 14) }
        try await settle()
        try save(themedPNG(host, model.terminalAppearance), "N236-trial-four-dracula")
        look.followApp = false; look.theme = .oneLight; look.font = .sfMono; look.size = 12; look.cursor = .underline; look.padding = .roomy
        model.terminalAppearance.appearance = look
        try await settle()
        try save(themedPNG(host, model.terminalAppearance), "N236-trial-four-onelight")
        look.followApp = false; look.theme = .gruvbox; look.size = 16; look.padding = .compact; look.cursor = .block
        model.terminalAppearance.appearance = look
        try await settle()
        try save(themedPNG(host, model.terminalAppearance), "N236-trial-four-gruvbox")
        // ⌘L: the prompt box opens over the focused pane.
        window.makeFirstResponder(views[0])
        _ = window.performKeyEquivalent(with: key("l", code: 37, flags: .command, in: window))
        try await settle()
        try save(themedPNG(host, model.terminalAppearance), "N236-trial-prompt")
    }

    // MARK: N237: the screen stays right after a tab switch, a drop split, a swap and a resize

    /// A program that draws like Claude Code's UI: a block of 6 full-width rows, redrawn in place (cursor up, erase below, rows again) 30
    /// times, and again on SIGWINCH. Row text is `tag`, the frame number and the row number, then filler up to the width.
    private func spawnTUI(_ id: String, tag: String) async throws {
        let script = """
        frame() {
          set -- $(stty size); c=$2
          [ -n "$drawn" ] && printf '\\033[6A\\r\\033[J'
          drawn=1; i=1
          while [ $i -le 6 ]; do
            printf '\\033[3%dm%s%d.%d ' $((i % 7 + 1)) '\(tag)' $n $i
            printf "%$((c - 10))s" '' | tr ' ' '#'
            printf '\\033[0m\\r\\n'
            i=$((i + 1))
          done
        }
        n=0; while [ $n -lt 30 ]; do n=$((n + 1)); frame; sleep 0.02; done
        trap frame WINCH
        while :; do sleep 0.1; done
        """
        try await client.spawn(id: id, argv: ["/bin/sh", "-c", script], cwd: dir, env: ["TERM": "xterm-256color"])
    }

    private static func lines(_ text: String) -> [String] {
        var out = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while out.last == "" { out.removeLast() }
        return out
    }

    /// The view's screen and tentacld's, line by line; the first difference as a message ("" when equal).
    private func difference(_ view: LiveTerminalNSView, _ id: String) async throws -> String {
        let mine = Self.lines(view.screenLines().joined(separator: "\n"))
        let theirs = Self.lines(try await client.read(id: id))
        let cols = view.terminalDimensions.cols, rows = view.terminalDimensions.rows
        let info = try await client.list().first { $0.id == id }
        if mine == theirs, info?.cols == cols, info?.rows == rows { return "" }
        let n = (0..<max(mine.count, theirs.count)).first { (mine.count > $0 ? mine[$0] : "<none>") != (theirs.count > $0 ? theirs[$0] : "<none>") } ?? 0
        let v = Array(mine.count > n ? mine[n].unicodeScalars : "".unicodeScalars), t = Array(theirs.count > n ? theirs[n].unicodeScalars : "".unicodeScalars)
        let at = zip(v, t).prefix { $0 == $1 }.count
        func cut(_ x: [Unicode.Scalar]) -> String { x.dropFirst(max(0, at - 8)).prefix(24).map { String($0.value, radix: 16) }.joined(separator: ",") }
        return "\(id): view \(cols)x\(rows), tentacld \(info?.cols ?? 0)x\(info?.rows ?? 0) (\(mine.count)/\(theirs.count) rows); row \(n + 1) differs at \(at) (lengths \(v.count)/\(t.count)): view [\(cut(v))] tentacld [\(cut(t))]; view row '\(mine.count > n ? String(mine[n].prefix(30)) : "")' tentacld row '\(theirs.count > n ? String(theirs[n].prefix(30)) : "")'"
    }

    /// The live view that shows `tag`'s rows.
    private func view(tag: String, in host: NSView) -> LiveTerminalNSView? {
        Self.findAll(LiveTerminalNSView.self, in: host).first { $0.screenLines().contains { $0.hasPrefix("\(tag)30.") } }
    }

    private func expectSame(_ tags: [String: String], in host: NSView, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await settle()
        for (tag, id) in tags.sorted(by: { $0.key < $1.key }) {
            var diff = "no view shows \(tag)"
            try await waitUntil("\(what): \(tag) equals tentacld", timeout: 6) {
                guard let v = self.view(tag: tag, in: host) else { return false }
                diff = try await self.difference(v, id)
                return diff.isEmpty
            }
            XCTAssertEqual(diff, "", "\(what)", file: file, line: line)
        }
    }

    /// An older daemon answers an attach with the raw ring and no `snapshot` key: the view is not given that ring, and still works.
    func testDaemonWithoutSnapshotsStillWorks() async throws {
        try await spawnTUI("old", tag: "A")
        try await waitUntil("the TUI drew its last frame") { try await self.client.read(id: "old").contains("A30.6") }
        let raw = try await client.attach(id: "old")
        XCTAssertFalse(raw.isSnapshot)
        XCTAssertTrue(String(decoding: raw.ring, as: UTF8.self).contains("A1.1"), "the old answer is the raw ring: every frame")
        raw.close()
        let s = LiveTerminalSession(id: "old", client: client, appearance: appearance, recheck: .milliseconds(100), resizeDelay: .milliseconds(50), snapshots: false)
        sessions.append(s)
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.view.setFrameSize(NSSize(width: 900, height: 400))
        try await waitUntil("the program repainted for the view's size") {
            let dims = s.view.terminalDimensions
            let i = try await client.list().first
            return i?.cols == dims.cols && s.view.screenLines().contains { $0.hasPrefix("A30.6") }
        }
        let frames = s.view.screenLines().filter { $0.hasPrefix("A") }
        XCTAssertFalse(frames.contains { $0.hasPrefix("A1.") }, "no frame of the raw ring is replayed: \(frames)")
        s.view.send(txt: "x")
    }

    /// Colors, attributes, the alternate screen, the modes and the scrollback travel in the snapshot; the view then shows the same.
    func testSnapshotCarriesLooksModesAndScrollback() async throws {
        let script = """
        i=1; while [ $i -le 60 ]; do echo "history-$i"; i=$((i+1)); done
        printf '\\033[1;38;5;208mbold-orange\\033[0m \\033[48;2;1;2;3mtruebg\\033[0m \\033[3;4mital-ul\\033[0m çığöşü 日本語 😀\\r\\n'
        printf '\\033[?2004h\\033[?1000h\\033[?1h'
        printf '\\033[?1049h\\033[2J\\033[3;5Hin-alt\\033[7;2H\\033[31mred\\033[0m'
        sleep 30
        """
        try await client.spawn(id: "look", argv: ["/bin/sh", "-c", script], cwd: dir, env: ["TERM": "xterm-256color"], cols: 80, rows: 24)
        try await waitUntil("alt screen drawn") { try await self.client.read(id: "look").contains("in-alt") }
        let a = try await client.attach(id: "look", snapshot: true)
        defer { a.close() }
        XCTAssertTrue(a.isSnapshot)
        XCTAssertEqual([a.cols, a.rows], [80, 24])
        let text = String(decoding: a.ring, as: UTF8.self)
        for want in ["history-1\r\n", "history-60", "\u{1B}[?1049h", "\u{1B}[?2004h", "\u{1B}[?1000h", "\u{1B}[?1006h", "\u{1B}[?1h", "in-alt", "çığöşü 日本語 😀",
                     "\u{1B}[0;1;38;5;208m", "\u{1B}[0;48;2;1;2;3m", "\u{1B}[0;3;4m", "\u{1B}[0;31m", "\u{1B}[7;5H"] {
            XCTAssertTrue(text.contains(want), "snapshot lacks \(want.debugDescription)")
        }
        XCTAssertLessThan(text.range(of: "history-60")!.lowerBound, text.range(of: "\u{1B}[?1049h")!.lowerBound, "the normal screen first, then the alternate one")
        // Fed to a fresh view of the same size, the screen is the daemon's.
        let view = LiveTerminalNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        view.resize(cols: 80, rows: 24)
        view.feedQuiet([0x1B, 0x63] + [UInt8](a.ring))
        let theirs = Self.lines(try await client.read(id: "look"))
        XCTAssertEqual(Self.lines(view.screenLines().joined(separator: "\n")), theirs)
        XCTAssertTrue(theirs.contains { $0.contains("in-alt") })
    }

    /// The ring (for a client that asks without `snapshot`) never starts inside a character or an escape sequence.
    func testRingStartsAtABoundary() async throws {
        let script = "i=0; while [ $i -lt 9000 ]; do printf '\\033[38;5;196mçığöşü-%0200d\\033[0m\\r\\n' $i; i=$((i+1)); done; sleep 30"
        try await client.spawn(id: "big", argv: ["/bin/sh", "-c", script], cwd: dir)
        try await waitUntil("output is over the ring limit", timeout: 20) { try await self.client.read(id: "big", lines: 3).contains("-0000000000") }
        try await Task.sleep(nanoseconds: 500_000_000)
        let a = try await client.attach(id: "big")
        defer { a.close() }
        XCTAssertGreaterThan(a.ring.count, 1_000_000)
        XCTAssertLessThanOrEqual(a.ring.count, 2 * 1024 * 1024 + 256 * 1024)
        XCTAssertEqual(a.ring.first, 0x1B, "the ring starts at a line, which starts with the escape sequence")
        XCTAssertNotNil(String(data: a.ring, encoding: .utf8), "valid UTF-8 from the first byte")
    }

    func testStoreKeepsASessionUntilItsTerminalIsGone() async throws {
        let store = LiveTerminalStore(appearance: appearance)
        let a = store.session(id: "w6:p1", client: client)
        XCTAssertTrue(a === store.session(id: "w6:p1", client: client), "the same session, so the same view and screen, wherever the pane is")
        let b = store.session(id: "w6:p2", client: client)
        store.keep(["w6:p1"])
        XCTAssertEqual(store.ids, ["w6:p1"])
        XCTAssertTrue(a === store.session(id: "w6:p1", client: client))
        XCTAssertFalse(b === store.session(id: "w6:p2", client: client), "a released terminal starts over")
        let other = TentacldClient(socketPath: dir + "/other.sock")
        XCTAssertFalse(a === store.session(id: "w6:p1", client: other), "another daemon is another session")
        store.removeAll()
        XCTAssertTrue(store.ids.isEmpty)
    }

    func testScreenSurvivesTabSwitch() async throws {
        let model = await terminalsModel(shells: ["w6:p1"])
        try await spawnTUI("w6:p1", tag: "A")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func screen() -> NSHostingView<some View> {
            NSHostingView(rootView: TerminalsView(model: model, selected: "w6:p1", tentacld: client).frame(width: 1440, height: 872).background(Tok.bg))
        }
        window.contentView = screen()
        try await waitUntil("the TUI drew", timeout: 20) { self.view(tag: "A", in: window.contentView!) != nil }
        try await expectSame(["A": "w6:p1"], in: window.contentView!, "first show")
        for round in 1...2 {
            window.contentView = NSView()
            try await Task.sleep(nanoseconds: 500_000_000)
            window.contentView = screen()
            try await waitUntil("the TUI shows again") { self.view(tag: "A", in: window.contentView!) != nil }
            try await expectSame(["A": "w6:p1"], in: window.contentView!, "tab switch \(round)")
        }
    }

    /// A view made after the program drew (a pane opened by a drop, the app started again): its screen is the daemon's, not a mess.
    func testFreshViewShowsTheDaemonScreen() async throws {
        let model = await terminalsModel(shells: ["w6:p1"])
        try await spawnTUI("w6:p1", tag: "A")
        try await client.resize(id: "w6:p1", cols: 145, rows: 44)
        try await waitUntil("the TUI drew its last frame") { try await self.client.read(id: "w6:p1").contains("A30.6") }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalsView(model: model, selected: "w6:p1", tentacld: client).frame(width: 1440, height: 872).background(Tok.bg))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil("the live view shows the program", timeout: 20) { self.view(tag: "A", in: host) != nil }
        try await expectSame(["A": "w6:p1"], in: host, "a fresh view")
    }

    func testScreenSurvivesDropSplitSwapAndDividerResize() async throws {
        let ids = ["w6:p1", "w6:p2"]
        let model = await terminalsModel(shells: ids)
        try await spawnTUI(ids[0], tag: "A")
        try await spawnTUI(ids[1], tag: "B")
        let probe = TerminalDropProbe()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalsView(model: model, selected: ids[0], tentacld: client, dropProbe: probe).frame(width: 1440, height: 872).background(Tok.bg))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil("A drew", timeout: 20) { self.view(tag: "A", in: host) != nil }
        let tags = ["A": ids[0], "B": ids[1]]
        try await expectSame(["A": ids[0]], in: host, "one pane")
        probe.drop(ids[1], on: 1, zone: .right)
        try await waitUntil("B drew") { self.view(tag: "B", in: host) != nil }
        try await expectSame(tags, in: host, "after the drop split")
        probe.drop(ids[0], on: 2, zone: .center)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await expectSame(tags, in: host, "after the swap")
        probe.drop(ids[1], on: 2, zone: .bottom)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await expectSame(tags, in: host, "after a second split")
        probe.divide([], at: 0.3)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await expectSame(tags, in: host, "after the divider moved")
        host.layoutSubtreeIfNeeded()
        try save(png(host), "N237-after-split-swap-divider")
        model.terminalAppearance.appearance.size = 16
        try await Task.sleep(nanoseconds: 500_000_000)
        try await expectSame(tags, in: host, "after a bigger font")
        model.terminalAppearance.appearance.size = 12
        try await Task.sleep(nanoseconds: 500_000_000)
        try await expectSame(tags, in: host, "after the font is back")
    }

    /// `png`, flattened onto the current theme's background: the terminal cells are the only transparent part of the capture.
    private func themedPNG(_ view: NSView, _ store: TerminalAppearanceStore) -> Data? {
        view.layoutSubtreeIfNeeded()
        return png(view, background: store.appearance.palette.background)
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 1_500_000_000)
    }

    private static func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { findAll(type, in: $0) }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    private let sample = """
    import SwiftUI

    /// The widget's timeline: reloads every 15 minutes.
    struct Widget: View {
        let entries: [Entry]
        @State private var selected = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    Text(entry.title).font(.headline)
                }
            }
            .padding(12)
        }
    }

    """

    /// One shell agent in the project's own folder; its pane id is the tentacld session id.
    private func terminalsModel(shells: [String]? = nil) async -> PanelModel {
        let repo = "/Users/you/Projects/demo"
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-live-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let project = """
        {"id":"demo","name":"Demo App","repoPath":"\(repo)","dataDir":"\(DemoSupport.demoDir.appendingPathComponent("data").path)","maxParallel":4,"sharedFiles":[]}
        """
        try? project.write(to: base.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try? "{\"projects\":[\"\(base.appendingPathComponent("project.json").path)\"]}".write(to: base.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        var shell = AgentStatus(paneID: "w6:p1", workspaceID: "w", state: .idle, cwd: repo, title: "vim Demo.swift", sessionID: nil)
        shell.changeSeq = 1
        let agents = shells.map { $0.map { AgentStatus(paneID: $0, workspaceID: "w", state: .idle, cwd: repo, title: "zsh \($0)", sessionID: nil) } } ?? [shell]
        let model = PanelModel(settingsURL: base.appendingPathComponent("settings.json"), makeTerminal: { FakeTerminal(agentsResult: .success(agents)) }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() }, log: ActionLog(fileURL: base.appendingPathComponent("actions.log")),
                               writer: DemoCardWriter(), defaults: makeTestDefaults(), roleStore: RoleStore(baseDir: base.appendingPathComponent("roles")))
        await model.reload()
        return model
    }

    // MARK: N244 lifecycle

    private func startDaemon() async throws {
        daemon = Process()
        daemon.executableURL = client.helper
        daemon.arguments = ["--socket", socket]
        try daemon.run()
        try await waitUntil("daemon answers") { await self.client.ping() }
    }

    /// The program ends, and a new one starts under the same id (an agent restart): the pane attaches again and takes keys.
    func testPaneReattachesWhenTheIdStartsAgain() async throws {
        try await client.spawn(id: "re", argv: ["/bin/sh"], cwd: dir)
        let s = session("re")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.view.send(txt: "exit 3\r")
        try await waitUntil("exited 3") { s.phase == .exited(3) }
        let old = try await client.list().first?.pid
        try await client.spawn(id: "re", argv: ["/bin/sh"], cwd: dir)
        try await waitUntil("live again") { s.phase == .live }
        let now = try await client.list().first?.pid
        XCTAssertNotEqual(old, now)
        s.view.send(txt: "echo again-$((40+2))\r")
        try await waitUntil("again-42") { try await screen("re").contains("again-42") }
    }

    /// tentacld restarts (its sessions are gone) and the id is started again: the pane comes back.
    func testPaneReattachesAfterDaemonRestart() async throws {
        try await client.spawn(id: "dr", argv: ["/bin/sh"], cwd: dir)
        let s = session("dr")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        stopDaemon(daemon)
        try await waitUntil("failed") { if case .failed = s.phase { true } else { false } }
        try await startDaemon()
        try await client.spawn(id: "dr", argv: ["/bin/sh"], cwd: dir)
        try await waitUntil("live again") { s.phase == .live }
        s.view.send(txt: "echo back-$((40+2))\r")
        try await waitUntil("back-42") { try await screen("dr").contains("back-42") }
    }

    /// Two size changes in a row: the daemon ends at the latest.
    /// N324: a live chunk fed right after an attach registered must not reach the socket before the header line ("bad reply from tentacld").
    func testAttachDuringHeavyOutputGetsItsHeader() async throws {
        try await client.spawn(id: "hv", argv: ["/bin/sh", "-c", "while :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done"], cwd: dir)
        for snapshot in [true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false] {
            let a = try await client.attach(id: "hv", snapshot: snapshot)
            a.close()
        }
    }

    func testTwoQuickResizesEndAtTheLatest() async throws {
        try await client.spawn(id: "rs", argv: ["/bin/sh"], cwd: dir, cols: 100, rows: 30)
        let s = session("rs")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.view.setFrameSize(NSSize(width: 520, height: 260))
        s.view.setFrameSize(NSSize(width: 700, height: 340))
        let dims = s.view.terminalDimensions
        try await waitUntil("the daemon at the latest size") {
            let i = try await client.list().first
            return i?.cols == dims.cols && i?.rows == dims.rows
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let i = try await client.list().first
        XCTAssertEqual(i?.cols, dims.cols); XCTAssertEqual(i?.rows, dims.rows)
    }

    /// A socket that accepts and never answers.
    private func silentServer() throws -> (path: String, fd: Int32) {
        let path = dir + "/hung.sock"
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(ok, 0)
        XCTAssertEqual(Darwin.listen(fd, 8), 0)
        return (path, fd)
    }

    func testHungDaemonRequestTimesOut() async throws {
        let hung = try silentServer()
        defer { Darwin.close(hung.fd) }
        let c = TentacldClient(socketPath: hung.path, requestTimeout: 0.4)
        let start = Date()
        do { _ = try await c.list(); XCTFail("a hung daemon must not answer") } catch {}
        do { _ = try await c.attach(id: "x"); XCTFail("a hung daemon must not attach") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    private func restartDaemon(env: [String: String]) async throws {
        stopDaemon(daemon)
        daemon = Process()
        daemon.executableURL = client.helper
        daemon.arguments = ["--socket", socket]
        daemon.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        try daemon.run()
        try await waitUntil("daemon answers") { await self.client.ping() }
    }

    /// A client that never reads fills its buffer; the daemon's write times out and the client is dropped for good: its socket is shut,
    /// so the client's side of the stream ends (before the fix the daemon only forgot it and kept the socket, and its read loop, open).
    func testFailedPushShutsTheClientSocket() async throws {
        try await restartDaemon(env: ["TENTACLD_SEND_TIMEOUT": "1"])
        try await client.spawn(id: "pf", argv: ["/bin/sh", "-c", "yes tick"], cwd: dir)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(socket.utf8)) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var small: Int32 = 4096
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(r, 0)
        let req = Array("{\"verb\":\"attach\",\"id\":\"pf\"}\n".utf8)
        _ = Darwin.write(fd, req, req.count)
        try await Task.sleep(nanoseconds: 3_000_000_000)   // not reading: the daemon's write blocks, times out, fails
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 65536)
        var ended = false
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            let n = Darwin.read(fd, &buf, buf.count)
            if n == 0 { ended = true; break }
            if n < 0 && errno != EINTR { break }   // timed out with the stream still open
        }
        XCTAssertTrue(ended, "the stream of a client that could not be written to ends")
    }

    /// An exited session goes from the list after the grace period.
    func testExitedSessionIsDroppedAfterGrace() async throws {
        try await restartDaemon(env: ["TENTACLD_EXIT_GRACE": "1"])
        try await client.spawn(id: "gone", argv: ["/bin/sh", "-c", "exit 0"], cwd: dir)
        try await waitUntil("exited") { try await client.list().first?.alive == false }
        try await waitUntil("dropped") { try await client.list().isEmpty }
    }

    /// A burst of size changes (a divider drag) re-attaches at most twice; the last size wins.
    func testResizeBurstReattachesAtMostTwice() async throws {
        try await client.spawn(id: "rb", argv: ["/bin/sh"], cwd: dir, cols: 100, rows: 30)
        let s = LiveTerminalSession(id: "rb", client: client, appearance: appearance, recheck: .milliseconds(100), resizeDelay: .milliseconds(300))
        sessions.append(s)
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = s.attachCount
        for i in 0..<20 {
            s.view.setFrameSize(NSSize(width: 500 + CGFloat(i) * 10, height: 260))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let dims = s.view.terminalDimensions
        try await waitUntil("the daemon at the last size") { try await client.list().first?.cols == dims.cols }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertLessThanOrEqual(s.attachCount - before, 2, "attaches for 20 size changes")
        let last = try await client.list().first?.cols
        XCTAssertEqual(last, dims.cols)
    }

    /// N324: the program follows a drag step by step, in order, without waiting for the (here very late) re-attach; the last size wins.
    func testDragStepsReachThePtyBeforeTheReattach() async throws {
        try await client.spawn(id: "ds", argv: ["/bin/sh"], cwd: dir, cols: 100, rows: 30)
        let s = LiveTerminalSession(id: "ds", client: client, appearance: appearance, recheck: .milliseconds(100), resizeDelay: .seconds(5))
        sessions.append(s)
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        // The first change after a quiet period re-attaches at once. Let that one settle, so the drag below is a burst on a live attachment.
        try await Task.sleep(nanoseconds: 5_500_000_000)
        let attached = s.attachCount
        s.view.setFrameSize(NSSize(width: 480, height: 260))
        try await waitUntil("settled") { let c = try await client.list().first?.cols; return s.attachCount > attached && c == s.view.terminalDimensions.cols }
        var seen: [Int] = []
        for i in 0..<8 {
            s.view.setFrameSize(NSSize(width: 500 + CGFloat(i) * 20, height: 260))
            let cols = s.view.terminalDimensions.cols
            if seen.last != cols { seen.append(cols) }
            try await waitUntil("daemon at \(cols)", timeout: 1.5) { try await client.list().first?.cols == cols }
        }
        XCTAssertGreaterThan(seen.count, 2, "the drag changed the column count several times")
        let last = try await client.list().first?.cols
        XCTAssertEqual(last, s.view.terminalDimensions.cols)
    }

    /// One change after a quiet period is not delayed.
    func testIsolatedResizeReattachesAtOnce() async throws {
        try await client.spawn(id: "ri", argv: ["/bin/sh"], cwd: dir, cols: 100, rows: 30)
        let s = LiveTerminalSession(id: "ri", client: client, appearance: appearance, recheck: .milliseconds(100), resizeDelay: .seconds(3))
        sessions.append(s)
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        try await Task.sleep(nanoseconds: 3_500_000_000)
        s.view.setFrameSize(NSSize(width: 520, height: 260))
        let dims = s.view.terminalDimensions
        try await waitUntil("re-attached well before the delay", timeout: 1.5) { try await client.list().first?.cols == dims.cols }
    }

    // MARK: N247

    /// A wide character (CJK, emoji) takes two cells; the second one is a NUL that must not turn into a space. Both reads, and the
    /// margin of an indented line stays in the scrollback read.
    func testWideCharactersGetNoSpaceAfterThemAndTheMarginStays() async throws {
        let script = "printf 'a\\346\\227\\245\\346\\234\\254b \\360\\237\\230\\200c\\n    indented\\n'; sleep 30"
        try await client.spawn(id: "wide", argv: ["/bin/sh", "-c", script], cwd: dir)
        try await waitUntil("printed") { try await client.read(id: "wide").contains("indented") }
        let expected = "a日本b 😀c\n    indented"
        let screen = try await client.read(id: "wide")
        let history = try await client.read(id: "wide", lines: 10)
        XCTAssertEqual(screen, expected, "screen read")
        XCTAssertEqual(history, expected, "scrollback read")
        let s = session("wide")
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        try await waitUntil("view shows it") { s.view.screenLines().contains("a日本b 😀c") }
    }

    /// The screen appears after the Terminals screen: tentacld's socket is not there when the view is built, and the pane switches to the
    /// live terminal when it is.
    func testPaneSwitchesToTheLiveTerminalWhenTentacldAppearsLater() async throws {
        let lateSocket = dir + "/late.sock"
        let late = TentacldClient(socketPath: lateSocket)
        let model = await terminalsModel(shells: ["late-1"])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalsView(model: model, selected: "late-1", socket: lateSocket, lookupEvery: .milliseconds(100)).frame(width: 1200, height: 800))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let laterDaemon = Process()
        defer { window.orderOut(nil); model.liveTerminals.removeAll(); stopDaemon(laterDaemon) }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(Self.findAll(LiveTerminalNSView.self, in: host).isEmpty, "no daemon yet: polled text")
        laterDaemon.executableURL = late.helper
        laterDaemon.arguments = ["--socket", lateSocket]
        try laterDaemon.run()
        try await waitUntil("late daemon answers") { await late.ping() }
        try await late.spawn(id: "late-1", argv: ["/bin/sh"], cwd: dir)
        try await waitUntil("the pane is live by itself", timeout: 10) { Self.findAll(LiveTerminalNSView.self, in: host).count == 1 }
    }

    // MARK: closing the user's shell (N247)

    /// `exit` or Ctrl-D: the shell leaves the list at once (no 30 minutes as "Exited"); another session stays listed with its code.
    func testAUserShellThatEndsLeavesTheListAtOnce() async throws {
        try await client.spawn(id: "my-shell-1", argv: ["/bin/sh", "-c", "exit 0"], cwd: dir)
        try await client.spawn(id: "dev-n1", argv: ["/bin/sh", "-c", "exit 3"], cwd: dir)
        try await waitUntil("the agent exited") { try await client.list().first { $0.id == "dev-n1" }?.alive == false }
        let ids = try await client.list().map(\.id)
        XCTAssertEqual(ids, ["dev-n1"], "the shell is gone, the agent session stays with its code")
        // The same id can start again at once.
        try await client.spawn(id: "my-shell-1", argv: ["/bin/sh"], cwd: dir)
        try await client.kill(id: "my-shell-1")
    }

    /// Close shell: an interactive shell ignores SIGTERM, so it is hung up; the call returns when tentacld no longer lists it.
    func testClosingAUserShellEndsAnInteractiveShellAtOnce() async throws {
        try await client.spawn(id: "my-shell-2", argv: ["/bin/zsh", "-f", "-i"], cwd: dir, env: ["TERM": "xterm-256color"])
        try await waitUntil("alive") { try await client.list().first?.alive == true }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        try await TerminalShells.close(client: client, id: "my-shell-2", wait: .seconds(5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "hung up, not killed after the 2 s grace")
        let listed = try await client.list()
        XCTAssertTrue(listed.isEmpty)
        // A shell that is already gone is closed without an error.
        try await TerminalShells.close(client: client, id: "my-shell-2")
    }

    /// The pane of a shell that ended: the live session says it is gone, which refreshes the terminal list.
    func testAShownShellThatEndsTellsTheStoreItIsGone() async throws {
        try await client.spawn(id: "my-shell-3", argv: ["/bin/sh"], cwd: dir)
        let store = LiveTerminalStore(appearance: appearance)
        var gone: [String] = []
        store.onGone = { gone.append($0) }
        let s = store.session(id: "my-shell-3", client: client)
        s.appear()
        try await waitUntil("live") { s.phase == .live }
        s.view.send(txt: "exit\r")
        try await waitUntil("told it is gone") { gone == ["my-shell-3"] }
        store.removeAll()
    }


    // MARK: Restored shell history (N273)

    func testHistoryIsCappedAndAgentSessionsAreNotSaved() async throws {
        try await client.spawn(id: "my-shell-1", argv: ["/bin/sh", "-c", "i=0; while [ $i -lt 2500 ]; do echo line$i; i=$((i+1)); done; sleep 30"], cwd: dir)
        try await client.spawn(id: "w1:p1", argv: ["/bin/sh", "-c", "echo agent; sleep 30"], cwd: dir)
        try await waitUntil("saved to the end") { await TerminalHistory.saved(client: self.client, id: "my-shell-1")?.text.hasSuffix("line2499") == true }
        let saved = await TerminalHistory.saved(client: client, id: "my-shell-1")
        let text = try XCTUnwrap(saved).text
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 2000)
        XCTAssertFalse(text.contains("line0\n"))
        let none = await TerminalHistory.saved(client: client, id: "w1:p1")
        XCTAssertNil(none)
        let r = try await client.request(["verb": "history", "id": "../x"])
        XCTAssertEqual(r["found"] as? Bool, false)
    }

    func testGoneShellRestoresWithItsTextAndClearAndCloseRemoveIt() async throws {
        try await client.spawn(id: "my-shell-1", argv: ["/bin/sh", "-c", "echo before-restart; exit 0"], cwd: dir)
        try await waitUntil("saved on exit") { await TerminalHistory.saved(client: self.client, id: "my-shell-1")?.text.contains("before-restart") == true }
        try await waitUntil("session gone") { try await self.client.list().isEmpty }

        let restored = try await TerminalHistory.restore(client: client, id: "my-shell-1", fallbackCwd: dir, argv: ["/bin/sh"])
        XCTAssertTrue(try XCTUnwrap(restored).text.contains("before-restart"))
        let running = try await client.list().filter(\.alive).map(\.id)
        XCTAssertEqual(running, ["my-shell-1"])
        // the new shell's own output is saved below the old text
        try await client.write(id: "my-shell-1", text: "echo after-restart\n")
        try await waitUntil("old and new text") {
            let t = await TerminalHistory.saved(client: self.client, id: "my-shell-1")?.text ?? ""
            return t.contains("before-restart") && t.contains("after-restart")
        }
        // Clear drops the old text only
        await TerminalHistory.forget(client: client, id: "my-shell-1")
        let afterClear = await TerminalHistory.saved(client: client, id: "my-shell-1")
        let cleared = try XCTUnwrap(afterClear).text
        XCTAssertFalse(cleared.contains("before-restart"))
        XCTAssertTrue(cleared.contains("after-restart"))
        // closing the shell removes the file
        try await TerminalShells.close(client: client, id: "my-shell-1", wait: .seconds(5))
        let closed = await TerminalHistory.saved(client: client, id: "my-shell-1")
        XCTAssertNil(closed)
        // nothing saved: nothing restored, no shell started
        let nothing = try await TerminalHistory.restore(client: client, id: "my-shell-1", fallbackCwd: dir, argv: ["/bin/sh"])
        XCTAssertNil(nothing)
        let left = try await client.list()
        XCTAssertTrue(left.isEmpty)
    }

    func testClosingAGoneShellRemovesItsFile() async throws {
        try await client.spawn(id: "my-shell-2", argv: ["/bin/sh", "-c", "echo x; exit 0"], cwd: dir)
        try await waitUntil("saved on exit") { await TerminalHistory.saved(client: self.client, id: "my-shell-2") != nil }
        try? await client.kill(id: "my-shell-2")   // "no such session", the file goes anyway
        let after = await TerminalHistory.saved(client: client, id: "my-shell-2")
        XCTAssertNil(after)
    }
}

private extension Array {
    func asyncContains(_ test: (Element) async throws -> Bool) async throws -> Bool {
        for e in self where try await test(e) { return true }
        return false
    }
}

private extension LiveTerminalNSView {
    /// The visible screen as text.
    func getText() -> String {
        selectAll()
        defer { selectNone() }
        return getSelection() ?? ""
    }
}
