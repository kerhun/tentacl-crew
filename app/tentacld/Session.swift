import Foundation
import SwiftTerm

/// One PTY session: the child, a headless terminal fed with every byte, a raw output ring for replay, and the attached clients.
final class Session: TerminalDelegate, LocalProcessDelegate {
    static let ringLimit = 2 * 1024 * 1024
    /// How long a write to an attached client may block before the client is dropped; `TENTACLD_SEND_TIMEOUT` (seconds) sets it.
    static let sendTimeout = ProcessInfo.processInfo.environment["TENTACLD_SEND_TIMEOUT"].flatMap { Int($0) } ?? 10

    /// The ring was cut at an arbitrary byte: start it after the next line break (within the first 4 KB), or at least on a character
    /// boundary, so a replay never begins inside an escape sequence or a UTF-8 sequence.
    static func startAtBoundary(_ ring: inout [UInt8]) {
        if let nl = ring.prefix(4096).firstIndex(of: 10) { ring.removeFirst(nl + 1); return }
        var skip = 0
        while skip < min(4, ring.count), ring[skip] & 0xC0 == 0x80 { skip += 1 }
        if skip > 0 { ring.removeFirst(skip) }
    }

    let id: String
    let command: [String]
    let cwd: String
    private(set) var terminal: Terminal!
    private var process: LocalProcess!
    private let lock = NSLock()
    /// Held while a chunk goes into the terminal, the ring and the subscribers' queues, and while an attach takes its snapshot and
    /// subscribes: a chunk is in the snapshot or comes live afterwards, never both and never neither.
    private let feedLock = NSLock()
    private var ring: [UInt8] = []
    private var subscribers: [Int32: Subscriber] = [:]
    private(set) var alive = true
    private(set) var exitCode: Int32?
    /// When the program ended (the server drops the session after a grace period).
    private(set) var exitedAt: Date?
    /// Called once when the program ended, after the session is marked exited (the server drops a user's shell at once).
    var onExit: ((Session) -> Void)?
    private var lastStatus: TerminalProgramStatus?
    /// Counters over the OSC 7501 records (for wait-agent.sh and the app): `seq` goes up on every change of state/kind/message,
    /// `completionSeq` when a turn ends (state becomes done, or idle after working).
    private var statusSeq = 0
    private var completionSeq = 0
    /// A user's shell saves its last screen here (N273); nil for an agent's session.
    var history: HistoryStore?
    /// The text of the shell this one replaced after a restart; kept above the new screen in the saved file until the user clears it.
    var prior = ""
    private var historyPending = false
    private var historyDiscarded = false
    static let historyDelay = ProcessInfo.processInfo.environment["TENTACLD_HISTORY_DELAY"].flatMap(TimeInterval.init) ?? 2

    final class Subscriber {
        let fd: Int32
        let queue = DispatchQueue(label: "tentacld.subscriber")
        init(fd: Int32) { self.fd = fd }
    }

    init(id: String, command: [String], cwd: String, cols: Int, rows: Int) {
        self.id = id
        self.command = command
        self.cwd = cwd
        var o = TerminalOptions.default
        o.cols = cols; o.rows = rows; o.scrollback = 10_000
        terminal = Terminal(delegate: self, options: o)
        process = LocalProcess(delegate: self, dispatchQueue: DispatchQueue(label: "tentacld.pty.\(id)"))
    }

    /// Environment for the child: the daemon's own (full user PATH etc.) minus what would confuse nested tools, plus `extra`.
    static func childEnvironment(extra: [String: String]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("HERDR_") || key == "TMUX" || key == "TMUX_PANE" || key == "TERM_PROGRAM" || key == "TERM_PROGRAM_VERSION" {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if let p = loginPath { env["PATH"] = p }
        // an app started from Finder has no locale; without UTF-8 the shell's line editor mangles non-ASCII input
        let loc = (env["LC_ALL"] ?? env["LC_CTYPE"] ?? env["LANG"] ?? "").uppercased()
        if !loc.contains("UTF-8") && !loc.contains("UTF8") { env["LANG"] = "en_US.UTF-8"; env.removeValue(forKey: "LC_ALL"); env.removeValue(forKey: "LC_CTYPE") }
        for (k, v) in extra { env[k] = v }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// The PATH of the user's login shell (the daemon is started by an app that has only /usr/bin:/bin:…), resolved once on first use.
    static let loginPath: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '%s' \"__PATH__$PATH\""]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "__PATH__", options: .backwards) else { return nil }
        let path = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }()

    func start(env: [String]) -> String? {
        var exe = command[0]
        if !exe.contains("/") {
            let path = env.first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) } ?? "/usr/bin:/bin"
            exe = path.split(separator: ":").map { "\($0)/\(command[0])" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? exe
        }
        guard FileManager.default.isExecutableFile(atPath: exe) else { return "not an executable: \(command[0])" }
        if case .failure(let e) = process.startProcessChecked(executable: exe, args: Array(command.dropFirst()), environment: env, currentDirectory: cwd) {
            return "could not start \(command[0]): \(e)"
        }
        return nil
    }

    var pid: Int32 { process.shellPid }
    var cols: Int { terminal.terminalLock.withLock { terminal.cols } }
    var rows: Int { terminal.terminalLock.withLock { terminal.rows } }

    // MARK: PTY callbacks

    func getWindowSize() -> winsize {
        terminal.terminalLock.withLock { winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: 0, ws_ypixel: 0) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        feedLock.lock(); defer { feedLock.unlock() }
        terminal.terminalLock.withLock { terminal.feed(buffer: slice) }
        let chunk = Array(slice)
        lock.lock()
        ring.append(contentsOf: chunk)
        if ring.count > Session.ringLimit + 256 * 1024 { ring.removeFirst(ring.count - Session.ringLimit); Session.startAtBoundary(&ring) }
        let subs = Array(subscribers.values)
        let schedule = history != nil && !historyPending
        if schedule { historyPending = true }
        lock.unlock()
        for s in subs { push(chunk, to: s) }
        if schedule {
            DispatchQueue.global().asyncAfter(deadline: .now() + Session.historyDelay) { [self] in
                lock.lock(); historyPending = false; lock.unlock()
                saveHistory()
            }
        }
    }

    /// Writes the screen and scrollback (capped) to the history file, unless the shell was closed on purpose.
    func saveHistory() {
        guard let history else { return }
        let now = read(lines: HistoryStore.maxLines)
        lock.lock(); defer { lock.unlock() }
        guard !historyDiscarded else { return }
        history.save(id: id, cwd: cwd, text: prior.isEmpty ? now : prior + "\n" + now)
    }

    /// The shell is closed: its file goes (also a save that is still pending).
    func discardHistory() {
        lock.lock(); historyDiscarded = true; prior = ""; lock.unlock()
        history?.remove(id: id)
    }

    /// "Clear" on the restored text: only the new screen stays in the file.
    func forgetPrior() {
        lock.lock(); prior = ""; lock.unlock()
        saveHistory()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        terminal.terminalLock.withLock { terminal.programStatusProcessExited() }
        saveHistory()
        lock.lock()
        self.exitCode = exitCode ?? -1
        alive = false
        exitedAt = Date()
        let subs = Array(subscribers.values)
        subscribers = [:]
        lock.unlock()
        for s in subs { s.queue.async { shutdown(s.fd, SHUT_RDWR) } }
        onExit?(self)
    }

    /// The terminal's own answers (device attributes, cursor position, OSC 7501 query) go back to the child.
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func programStatusChanged(source: Terminal, records: [TerminalProgramStatus]) {
        guard let last = records.last else { return }
        lock.lock()
        let prev = lastStatus
        lastStatus = last
        if prev?.state != last.state || prev?.kind != last.kind || prev?.message != last.message { statusSeq += 1 }
        if prev?.state != last.state, last.state == .done || (last.state == .idle && prev?.state == .working) { completionSeq += 1 }
        lock.unlock()
    }

    // MARK: Verbs

    func write(_ bytes: [UInt8]) {
        guard alive, !bytes.isEmpty else { return }
        process.send(data: bytes[...])
    }

    func resize(cols: Int, rows: Int) {
        terminal.terminalLock.withLock { terminal.resize(cols: cols, rows: rows) }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = process.updateWindowSize(&ws)
    }

    func kill() {
        guard alive else { return }
        let pid = process.shellPid
        // An interactive shell ignores SIGTERM but ends on SIGHUP, as when its terminal window closes.
        if pid > 0 { Darwin.kill(pid, SIGHUP) }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if let self, self.alive { Darwin.kill(pid, SIGKILL) }
        }
    }

    /// The screen, or (with `lines`) the last N lines of scrollback plus screen, as text. The screen: only the cells inside the terminal's
    /// width (after a resize a line can still hold cells from when it was wider (an erase stops at the edge), which nobody sees).
    func read(lines: Int?) -> String {
        terminal.terminalLock.withLock {
            let cols = terminal.cols
            // An erased cell that keeps a color is a NUL, not a blank one, and is not trimmed. The NUL cell after a wide character
            // (CJK, emoji) is skipped, so no space follows it.
            func text(_ line: BufferLine?) -> String {
                blanked(line?.translateToString(trimRight: true, startCol: 0, endCol: cols, skipNullCellsFollowingWide: true, textProvider: { self.terminal.getText(for: $0) }) ?? "")
            }
            var out: [String]
            if lines == nil {
                out = (0..<terminal.rows).map { text(terminal.getLine(row: $0)) }
            } else {
                // Scrollback and screen, every line cut at the width like the screen read, with its margin.
                out = []
                var row = terminal.buffer.totalLinesTrimmed
                while let line = terminal.getScrollInvariantLine(row: row) { out.append(text(line)); row += 1 }
            }
            while out.last == "" { out.removeLast() }
            if let n = lines, out.count > n { out = Array(out.suffix(n)) }
            return out.joined(separator: "\n")
        }
    }

    private func blanked(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{0}", with: " ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    func status() -> [String: Any]? {
        let current: TerminalProgramStatus? = terminal.terminalLock.withLock { terminal.programStatusRecords.last }
        lock.lock(); let seen = lastStatus; let seq = statusSeq; let completions = completionSeq; lock.unlock()
        guard let r = current ?? seen else { return nil }
        var d: [String: Any] = ["id": r.id, "state": r.state.rawValue, "live": current != nil, "seq": seq, "completion_seq": completions]
        if let k = r.kind { d["kind"] = k.rawValue }
        if let a = r.effectiveApp { d["app"] = a }
        if let t = r.title { d["title"] = t }
        if let m = r.message { d["msg"] = m }
        if let p = r.progress { d["progress"] = p }
        return d
    }

    func summary() -> [String: Any] {
        lock.lock(); let code = exitCode; lock.unlock()
        var d: [String: Any] = ["id": id, "pid": pid, "cwd": cwd, "command": command, "alive": alive, "cols": cols, "rows": rows]
        if let code { d["exit"] = Int(code) }
        if let s = status() { d["status"] = s }
        return d
    }

    // MARK: Attach

    /// Registers `fd`: the header line (given the replay length and whether it is a snapshot) and the replay are queued first, live bytes
    /// follow. The replay is the screen as bytes for the current size (`snapshot`), or the raw ring (an old client).
    func attach(fd: Int32, snapshot wantsSnapshot: Bool, header: (Int, Bool) -> [UInt8]) {
        var tv = timeval(tv_sec: Session.sendTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let sub = Subscriber(fd: fd)
        feedLock.lock()
        let replay: [UInt8]
        if wantsSnapshot { replay = ScreenSnapshot.bytes(of: terminal) } else { lock.lock(); replay = ring; lock.unlock() }
        lock.lock()
        let live = alive
        if live { subscribers[fd] = sub }
        lock.unlock()
        // queued under feedLock: a live chunk fed right after the unlock must not reach the socket before the header line
        push(header(replay.count, wantsSnapshot), to: sub)
        push(replay, to: sub)
        feedLock.unlock()
        if !live { sub.queue.async { shutdown(fd, SHUT_RDWR) } }
    }

    func detach(fd: Int32) {
        lock.lock(); subscribers.removeValue(forKey: fd); lock.unlock()
    }

    /// After attach the TUI redraws: SIGWINCH to the foreground process group (a resize to the same size sends none).
    func redraw() {
        guard alive else { return }
        let pgid = tcgetpgrp(process.childfd)
        if pgid > 0 { killpg(pgid, SIGWINCH) } else { Darwin.kill(process.shellPid, SIGWINCH) }
    }

    private func push(_ bytes: [UInt8], to s: Subscriber) {
        s.queue.async { [weak self] in
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { Darwin.write(s.fd, $0.baseAddress, $0.count) }
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    // A client that cannot be written to is dropped for good: shut the socket, so its read loop ends and the client sees the stream end.
                    self?.detach(fd: s.fd); shutdown(s.fd, SHUT_RDWR); return
                }
                off += n
            }
        }
    }
}
