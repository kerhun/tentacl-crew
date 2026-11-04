import Foundation
import Darwin

/// The socket server. Request: one JSON object per line, `{"verb":"…", …}`. Reply: one JSON line, `{"ok":true,…}` or `{"ok":false,"error":"…"}`.
///
///   spawn   id, argv[], cwd?, env{}?, cols?, rows?, history?, restore?   → ok, pid
///                                                          `my-shell-N` sessions save their screen (history: false turns it off); restore: true
///                                                          keeps the text saved for that id above the new screen in the file
///   list                                                 → ok, sessions[{id,pid,cwd,command,alive,exit?,cols,rows,status?}]
///   write   id, text | b64                               → ok
///   read    id, lines?                                   → ok, text   (no lines = the screen; lines = last N of scrollback + screen)
///   resize  id, cols, rows                               → ok
///   kill    id                                           → ok        (a session that already exited is removed from the list)
///   status  id                                           → ok, status?{id,state,kind?,app?,title?,msg?,progress?,live,seq,completion_seq}
///   attach  id, snapshot?                                → ok, ring (bytes), cols, rows, snapshot?; then the replay bytes, then raw PTY bytes
///                                                          until either side closes; bytes the client sends are written to the PTY.
///                                                          With `snapshot: true` the replay is the screen at the current size as escape
///                                                          sequences (after RIS a fresh terminal of that size shows it; N237) and the
///                                                          reply has `snapshot: true`; an old daemon ignores the key and replays the raw ring
///   history id                                           → ok, found, text?, cwd?, saved?   (a user's shell's saved last screen, N273)
///   forget  id                                           → ok        (drops the saved text of a shell that is gone, or the restored part of a live one)
///   forget  all: true                                    → ok        (drops every saved text, and the restored part of every live shell)
///   ping                                                 → ok, built, started   (the binary's modification time and the start of this daemon, seconds since 1970, N275)
final class Server {
    enum StartResult { case listening, alreadyRunning, failed(String) }

    let path: String
    private var listenFD: Int32 = -1
    private var sessions: [String: Session] = [:]
    private let lock = NSLock()
    private let history: HistoryStore

    /// When this daemon started, and when its binary was built (the file's modification time), as seconds since 1970. The app compares the
    /// second with the helper inside the app to tell an old daemon from a current one.
    static let started = Date().timeIntervalSince1970
    static let built: Double = (try? FileManager.default.attributesOfItem(atPath: Bundle.main.executablePath ?? CommandLine.arguments[0]))?[.modificationDate].flatMap { $0 as? Date }?.timeIntervalSince1970 ?? 0

    /// An exited session stays listed (its last screen and code) this long, then goes by itself; `TENTACLD_EXIT_GRACE` (seconds) sets it.
    let exitGrace: TimeInterval

    init(path: String) {
        self.path = path
        _ = Self.started; _ = Self.built   // a static is set when first used: this is the start, so both are read now
        history = HistoryStore(socketPath: path)
        exitGrace = ProcessInfo.processInfo.environment["TENTACLD_EXIT_GRACE"].flatMap(TimeInterval.init) ?? 1800
    }

    /// Removes `session` from the list if it is still the one listed under its id (a new one may have been started meanwhile).
    private func drop(_ session: Session) {
        lock.lock(); defer { lock.unlock() }
        if sessions[session.id] === session { sessions.removeValue(forKey: session.id) }
    }

    /// Drops sessions that exited more than `exitGrace` ago (their ring and terminal are memory nobody asks for any more).
    private func pruneExited() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        for (id, s) in sessions where !s.alive {
            if let at = s.exitedAt, now.timeIntervalSince(at) > exitGrace { sessions.removeValue(forKey: id) }
        }
    }

    // MARK: Endpoint

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    private static func connectFD(_ path: String) -> (fd: Int32, err: Int32) {
        guard var addr = address(path) else { return (-1, ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return (-1, errno) }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if r == 0 { return (fd, 0) }
        let e = errno; close(fd); return (-1, e)
    }

    /// Binds a private temp name, then renames it into place. A connect error other than "nobody listening" is not "dead".
    func start() -> StartResult {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let probe = Server.connectFD(path)
        if probe.fd >= 0 { close(probe.fd); return .alreadyRunning }
        if probe.err != ENOENT && probe.err != ECONNREFUSED { return .failed("endpoint \(path) is not usable (errno \(probe.err)); not touching it") }

        let tmp = "\(path).\(getpid()).tmp"
        unlink(tmp)
        guard var addr = Server.address(tmp) else { return .failed("socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket: errno \(errno)") }
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard b == 0 else { let e = errno; close(fd); return .failed("bind: errno \(e)") }
        chmod(tmp, 0o600)
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); unlink(tmp); return .failed("listen: errno \(e)") }
        // Someone may have started between the probe and now: if so, leave theirs alone.
        let again = Server.connectFD(path)
        if again.fd >= 0 { close(again.fd); close(fd); unlink(tmp); return .alreadyRunning }
        guard rename(tmp, path) == 0 else { let e = errno; close(fd); unlink(tmp); return .failed("rename: errno \(e)") }
        listenFD = fd
        return .listening
    }

    func run() -> Never {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; usleep(100_000); continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    // MARK: Connection

    private func line(_ obj: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{\"ok\":false}".utf8)
        data.append(10)
        return data
    }

    private func reply(_ fd: Int32, _ obj: [String: Any]) {
        let data = line(obj)
        data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
                off += n
            }
        }
    }

    private func fail(_ fd: Int32, _ msg: String) { reply(fd, ["ok": false, "error": msg]) }

    private func serve(_ fd: Int32) {
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 10) {
                let line = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                if line.isEmpty { continue }
                if handle(Data(line), fd: fd, leftover: &pending) { return }   // attach took the connection over
            }
        }
        close(fd)
    }

    private func session(_ req: [String: Any]) -> Session? {
        guard let id = req["id"] as? String else { return nil }
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    /// Returns true when the connection was handed to attach (and closed there).
    private func handle(_ line: Data, fd: Int32, leftover: inout Data) -> Bool {
        guard let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let verb = req["verb"] as? String else {
            fail(fd, "not a JSON object with a verb"); return false
        }
        func intArg(_ k: String) -> Int? { (req[k] as? Int) ?? (req[k] as? Double).map(Int.init) }
        switch verb {
        case "ping":
            reply(fd, ["ok": true, "built": Self.built, "started": Self.started])
        case "spawn":
            guard let id = req["id"] as? String, !id.isEmpty, let argv = req["argv"] as? [String], let first = argv.first, !first.isEmpty else {
                fail(fd, "spawn needs id and argv"); break
            }
            let cols = max(2, min(1000, intArg("cols") ?? 100)), rows = max(2, min(1000, intArg("rows") ?? 30))
            let cwd = (req["cwd"] as? String) ?? NSHomeDirectory()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { fail(fd, "cwd does not exist: \(cwd)"); break }
            let extra = (req["env"] as? [String: String]) ?? [:]
            let s = Session(id: id, command: argv, cwd: cwd, cols: cols, rows: rows)
            if HistoryStore.valid(id), req["history"] as? Bool ?? true {
                s.history = history
                if req["restore"] as? Bool == true, let old = history.load(id: id) { s.prior = old.text }
            }
            lock.lock()
            if let old = sessions[id], old.alive { lock.unlock(); fail(fd, "session \(id) is running"); break }
            sessions[id] = s
            // A user's shell that ends (`exit`, Ctrl-D, closed) leaves the list at once; it has no exit code anyone waits for.
            if id.hasPrefix("my-shell-") { s.onExit = { [weak self] s in self?.drop(s) } }
            lock.unlock()
            if let err = s.start(env: Session.childEnvironment(extra: extra)) {
                lock.lock(); sessions.removeValue(forKey: id); lock.unlock()
                fail(fd, err)
            } else {
                reply(fd, ["ok": true, "pid": Int(s.pid)])
            }
        case "list":
            pruneExited()
            lock.lock(); let all = sessions.values.sorted { $0.id < $1.id }; lock.unlock()
            reply(fd, ["ok": true, "sessions": all.map { $0.summary() }])
        case "write":
            guard let s = session(req) else { fail(fd, "no such session"); break }
            guard s.alive else { fail(fd, "session has exited"); break }
            if let t = req["text"] as? String { s.write(Array(t.utf8)) }
            else if let b = req["b64"] as? String, let d = Data(base64Encoded: b) { s.write([UInt8](d)) }
            else { fail(fd, "write needs text or b64"); break }
            reply(fd, ["ok": true])
        case "read":
            guard let s = session(req) else { fail(fd, "no such session"); break }
            reply(fd, ["ok": true, "text": s.read(lines: intArg("lines"))])
        case "resize":
            guard let s = session(req) else { fail(fd, "no such session"); break }
            guard let c = intArg("cols"), let r = intArg("rows"), c >= 2, r >= 2, c <= 1000, r <= 1000 else { fail(fd, "resize needs cols and rows"); break }
            s.resize(cols: c, rows: r)
            reply(fd, ["ok": true])
        case "history":
            guard let id = req["id"] as? String, let h = history.load(id: id) else { reply(fd, ["ok": true, "found": false]); break }
            reply(fd, ["ok": true, "found": true, "text": h.text, "cwd": h.cwd, "saved": h.saved])
        case "forget" where req["all"] as? Bool == true:
            lock.lock(); let live = sessions.values.filter { $0.alive && HistoryStore.valid($0.id) }; lock.unlock()
            history.removeAll()
            live.forEach { $0.forgetPrior() }
            reply(fd, ["ok": true])
        case "forget":
            guard let id = req["id"] as? String, HistoryStore.valid(id) else { fail(fd, "forget needs a shell id"); break }
            if let s = session(req), s.alive { s.forgetPrior() } else { history.remove(id: id) }
            reply(fd, ["ok": true])
        case "kill":
            // Closing a shell on purpose drops its saved text, also when the session is already gone.
            if let id = req["id"] as? String, HistoryStore.valid(id) { session(req)?.discardHistory(); history.remove(id: id) }
            guard let s = session(req) else { fail(fd, "no such session"); break }
            if s.alive { s.kill() } else { lock.lock(); sessions.removeValue(forKey: s.id); lock.unlock() }
            reply(fd, ["ok": true])
        case "status":
            guard let s = session(req) else { fail(fd, "no such session"); break }
            var d: [String: Any] = ["ok": true, "alive": s.alive]
            if let st = s.status() { d["status"] = st }
            reply(fd, d)
        case "attach":
            guard let s = session(req) else { fail(fd, "no such session"); break }
            let size = (s.cols, s.rows)
            // the header goes out before the ring, which the subscriber queue writes after it
            let snapshot = req["snapshot"] as? Bool ?? false
            s.attach(fd: fd, snapshot: snapshot, header: { n, isSnapshot in
                var h: [String: Any] = ["ok": true, "ring": n, "cols": size.0, "rows": size.1]
                if isSnapshot { h["snapshot"] = true }
                return [UInt8](self.line(h))
            })
            if !snapshot { s.redraw() }   // a snapshot is the screen; only the raw ring needs the program to repaint
            if !leftover.isEmpty { s.write([UInt8](leftover)); leftover = Data() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {   // what the client sends is typed input
                let n = read(fd, &buf, buf.count)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                s.write(Array(buf[0..<n]))
            }
            s.detach(fd: fd)
            close(fd)
            return true
        default:
            fail(fd, "unknown verb \(verb)")
        }
        return false
    }
}
