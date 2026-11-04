import Foundation
import Darwin

/// Async client for tentacld, the PTY daemon (N228). One JSON object per line over a unix socket; the protocol is described in
/// `app/tentacld/Server.swift`. Every call opens its own short connection, except `attach`, which keeps one open for the byte stream.
final class TentacldClient {
    struct TentacldError: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    struct SessionInfo: Equatable {
        let id: String
        let pid: Int
        let cwd: String
        let command: [String]
        let alive: Bool
        let exitCode: Int?
        let cols: Int
        let rows: Int
        let status: ProgramStatus?
    }

    /// The last OSC 7501 record of a session (`live` is false once the program cleared it, e.g. on exit).
    struct ProgramStatus: Equatable {
        let state: String
        let kind: String?
        let app: String?
        let title: String?
        let message: String?
        let progress: Int?
        let live: Bool
        /// Daemon-side counters: changes of state, and finished turns.
        var seq: Int = 0
        var completionSeq: Int = 0
    }

    /// An attached session: `ring` is the replay, `output` the live bytes after it. With `isSnapshot` the replay is the screen at
    /// `cols` x `rows` as escape sequences (feed it to a fresh terminal of that size, N237); without (an older daemon) it is the raw
    /// output ring, which was drawn at other sizes and must not be replayed into a view.
    final class Attachment {
        let ring: Data
        let cols: Int
        let rows: Int
        let isSnapshot: Bool
        let output: AsyncStream<Data>
        fileprivate let handle: SocketHandle
        /// Typed input is written here, in order, off the caller's thread (a stuck daemon must not block the main thread).
        private let writes = DispatchQueue(label: "tentacl.attach.write")
        fileprivate init(handle: SocketHandle, ring: Data, cols: Int, rows: Int, isSnapshot: Bool, output: AsyncStream<Data>) {
            self.handle = handle; self.ring = ring; self.cols = cols; self.rows = rows; self.isSnapshot = isSnapshot; self.output = output
        }
        /// Typed input for the PTY.
        func send(_ data: Data) {
            let h = handle
            writes.async { h.use { TentacldClient.writeAll($0, data) } }
        }
        /// Closing only drops this connection; the session keeps running.
        func close() { handle.shutdownNow() }
    }

    /// The owner of an attach socket: the reader thread is the only one that closes the fd (`finish`), and not while a write is
    /// running; everybody else only shuts it down while it is still open. The fd number is never touched after it was closed.
    final class SocketHandle {
        private let fd: Int32
        private let lock = NSLock()
        private var finished = false
        private var busy = 0
        init(fd: Int32) { self.fd = fd }

        func shutdownNow() {
            lock.lock(); defer { lock.unlock() }
            if !finished { shutdown(fd, SHUT_RDWR) }
        }

        /// Runs `body` with the fd unless it is already closed.
        @discardableResult
        func use(_ body: (Int32) -> Void) -> Bool {
            lock.lock()
            if finished { lock.unlock(); return false }
            busy += 1
            lock.unlock()
            body(fd)
            lock.lock(); busy -= 1; closeIfIdle(); lock.unlock()
            return true
        }

        /// The reader is done: the fd is closed now, or by the last writer.
        func finish() {
            lock.lock(); finished = true; closeIfIdle(); lock.unlock()
        }

        private var closed = false
        private func closeIfIdle() {
            if finished, busy == 0, !closed { closed = true; Darwin.close(fd) }
        }
    }

    static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tentacl/term.sock").path
    }
    static var bundledHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tentacld") }

    let socketPath: String
    let helper: URL
    /// How long a request (connect to reply) or the attach handshake may take; a hung daemon ends in an error, not a stuck call.
    /// Generous: the first spawn resolves the login shell's PATH (up to 5 s).
    let requestTimeout: TimeInterval
    /// Blocking socket calls run here, never on the cooperative pool; concurrent, so one stuck call does not hold up another.
    private static let blocking = DispatchQueue(label: "tentacl.tentacld.client", qos: .userInitiated, attributes: .concurrent)

    init(socketPath: String = TentacldClient.defaultSocketPath, helper: URL = TentacldClient.bundledHelper, requestTimeout: TimeInterval = 15) {
        self.socketPath = socketPath
        self.helper = helper
        self.requestTimeout = requestTimeout
    }

    private static func onBlockingQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            blocking.async { cont.resume(with: Result { try work() }) }
        }
    }

    // MARK: Verbs

    func ping() async -> Bool {
        (try? await request(["verb": "ping"])) != nil
    }

    /// Starts the bundled helper when nothing answers on the socket. A second helper exits by itself when one is already there.
    func ensureRunning(timeout: TimeInterval = 5) async throws {
        if await ping() { return }
        let p = Process()
        p.executableURL = helper
        p.arguments = ["--socket", socketPath]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw TentacldError(message: "could not start \(helper.path): \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await ping() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TentacldError(message: "tentacld did not answer on \(socketPath)")
    }

    /// What the running daemon says about itself (N275). nil when nothing answers. An older daemon answers without the times.
    func helperInfo() async -> HelperInfo? {
        guard let r = try? await request(["verb": "ping"]) else { return nil }
        func date(_ k: String) -> Date? { (r[k] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        return HelperInfo(built: date("built"), started: date("started"))
    }

    /// Drops every saved shell text the daemon keeps (Settings → Terminals, "Delete saved history"). An old daemon keeps none.
    func forgetAllHistory() async { _ = try? await request(["verb": "forget", "all": true]) }

    /// The process behind the socket (found as the socket's peer), only when it is a `tentacld`.
    func helperPID() async throws -> pid_t {
        let socketPath = socketPath
        return try await Self.onBlockingQueue { () throws -> pid_t in
            let fd = try Self.connect(socketPath, timeout: 3)
            defer { close(fd) }
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, 0 /* SOL_LOCAL */, 2 /* LOCAL_PEERPID */, &pid, &size) == 0, pid > 0 else { throw TentacldError(message: "could not find the helper process") }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, (String(cString: buf) as NSString).lastPathComponent == "tentacld" else {
                throw TentacldError(message: "the process behind the terminal socket is not tentacld")
            }
            return pid
        }
    }

    /// Ends the running daemon (every shell in it closes) and starts the bundled one.
    func restartHelper(timeout: TimeInterval = 5) async throws {
        let pid = try await helperPID()
        Darwin.kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while await ping(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if await ping() { throw TentacldError(message: "the helper did not end") }
        try await ensureRunning(timeout: timeout)
    }

    @discardableResult
    func spawn(id: String, argv: [String], cwd: String? = nil, env: [String: String] = [:], cols: Int = 100, rows: Int = 30, history: Bool = true) async throws -> Int {
        var req: [String: Any] = ["verb": "spawn", "id": id, "argv": argv, "cols": cols, "rows": rows]
        if !history { req["history"] = false }
        if let cwd { req["cwd"] = cwd }
        if !env.isEmpty { req["env"] = env }
        return try await request(req)["pid"] as? Int ?? 0
    }

    func list() async throws -> [SessionInfo] {
        let r = try await request(["verb": "list"])
        return (r["sessions"] as? [[String: Any]] ?? []).map { d in
            SessionInfo(id: d["id"] as? String ?? "", pid: d["pid"] as? Int ?? 0, cwd: d["cwd"] as? String ?? "",
                        command: d["command"] as? [String] ?? [], alive: d["alive"] as? Bool ?? false, exitCode: d["exit"] as? Int,
                        cols: d["cols"] as? Int ?? 0, rows: d["rows"] as? Int ?? 0, status: Self.parseStatus(d["status"]))
        }
    }

    func write(id: String, text: String) async throws {
        _ = try await request(["verb": "write", "id": id, "text": text])
    }

    func write(id: String, data: Data) async throws {
        _ = try await request(["verb": "write", "id": id, "b64": data.base64EncodedString()])
    }

    /// The visible screen, or with `lines` the last N lines of scrollback plus screen.
    func read(id: String, lines: Int? = nil) async throws -> String {
        var req: [String: Any] = ["verb": "read", "id": id]
        if let lines { req["lines"] = lines }
        return try await request(req)["text"] as? String ?? ""
    }

    func resize(id: String, cols: Int, rows: Int) async throws {
        _ = try await request(["verb": "resize", "id": id, "cols": cols, "rows": rows])
    }

    /// Ends a running session; on a session that already exited it removes it from the list.
    func kill(id: String) async throws {
        _ = try await request(["verb": "kill", "id": id])
    }

    func status(id: String) async throws -> ProgramStatus? {
        Self.parseStatus(try await request(["verb": "status", "id": id])["status"])
    }

    func attach(id: String, snapshot: Bool = false) async throws -> Attachment {
        let timeout = requestTimeout
        return try await Self.onBlockingQueue { [socketPath] () throws -> Attachment in
            let fd = try Self.connect(socketPath, timeout: timeout)
            Self.writeAll(fd, Self.line(snapshot ? ["verb": "attach", "id": id, "snapshot": true] : ["verb": "attach", "id": id]))
            let header: Data
            do { header = try Self.readLine(fd) } catch { close(fd); throw error }
            guard let obj = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] else { close(fd); throw TentacldError(message: "bad reply from tentacld") }
            guard obj["ok"] as? Bool == true else { close(fd); throw TentacldError(message: obj["error"] as? String ?? "attach failed") }
            let ringCount = obj["ring"] as? Int ?? 0
            var ring = Data()
            while ring.count < ringCount {
                var buf = [UInt8](repeating: 0, count: min(65536, ringCount - ring.count))
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                ring.append(contentsOf: buf[0..<n])
            }
            Self.setTimeout(fd, receive: 0)   // the live stream may be quiet for as long as it likes
            let handle = SocketHandle(fd: fd)
            let stream = AsyncStream<Data> { cont in
                let t = Thread {
                    var buf = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let n = Darwin.read(fd, &buf, buf.count)
                        if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                        cont.yield(Data(buf[0..<n]))
                    }
                    cont.finish()
                    handle.finish()
                }
                t.start()
                cont.onTermination = { _ in handle.shutdownNow() }
            }
            return Attachment(handle: handle, ring: ring, cols: obj["cols"] as? Int ?? 0, rows: obj["rows"] as? Int ?? 0,
                              isSnapshot: obj["snapshot"] as? Bool ?? false, output: stream)
        }
    }

    // MARK: Plumbing

    private static func parseStatus(_ v: Any?) -> ProgramStatus? {
        guard let d = v as? [String: Any], let state = d["state"] as? String else { return nil }
        return ProgramStatus(state: state, kind: d["kind"] as? String, app: d["app"] as? String, title: d["title"] as? String,
                             message: d["msg"] as? String, progress: d["progress"] as? Int, live: d["live"] as? Bool ?? false,
                             seq: d["seq"] as? Int ?? 0, completionSeq: d["completion_seq"] as? Int ?? 0)
    }

    func request(_ req: [String: Any]) async throws -> [String: Any] {
        let timeout = requestTimeout
        return try await Self.onBlockingQueue { [socketPath] () throws -> [String: Any] in
            let fd = try Self.connect(socketPath, timeout: timeout)
            defer { close(fd) }
            Self.writeAll(fd, Self.line(req))
            let reply = try Self.readLine(fd)
            guard let obj = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { throw TentacldError(message: "bad reply from tentacld") }
            guard obj["ok"] as? Bool == true else { throw TentacldError(message: obj["error"] as? String ?? "tentacld error") }
            return obj
        }
    }

    fileprivate static func line(_ obj: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        d.append(10)
        return d
    }

    fileprivate static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw TentacldError(message: "socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TentacldError(message: "socket: errno \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, receive: timeout, send: timeout)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { let e = errno; close(fd); throw TentacldError(message: "tentacld is not reachable (errno \(e))") }
        return fd
    }

    /// Receive/send timeouts of a socket (0 = none): a read or write that waits longer fails with EAGAIN.
    fileprivate static func setTimeout(_ fd: Int32, receive: TimeInterval? = nil, send: TimeInterval? = nil) {
        func tv(_ t: TimeInterval) -> timeval { timeval(tv_sec: Int(t), tv_usec: Int32((t - Double(Int(t))) * 1_000_000)) }
        if var r = receive.map(tv) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size)) }
        if var w = send.map(tv) { setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &w, socklen_t(MemoryLayout<timeval>.size)) }
    }

    fileprivate static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
                off += n
            }
        }
    }

    /// One byte at a time, so nothing after the newline (the ring of an attach) is consumed.
    fileprivate static func readLine(_ fd: Int32) throws -> Data {
        var out = Data()
        var b: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &b, 1)
            if n == 0 { throw TentacldError(message: "tentacld closed the connection") }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw TentacldError(message: "tentacld did not answer in time") }
                throw TentacldError(message: "read: errno \(errno)")
            }
            if b == 10 { return out }
            out.append(b)
        }
    }
}
