import Foundation

/// A local page address found in a terminal, and the command that started it when a line above names one.
struct LocalPage: Equatable {
    let url: URL
    let command: String?
}

/// Finds the local page an agent's dev server prints (N225): `http://localhost:5173/`, Vite's and Next's "Local:" lines, Expo's
/// "Web is waiting on …", `127.0.0.1`, `0.0.0.0` (read as localhost) and a bare `localhost:3000`. ANSI codes are stripped first.
/// The newest (lowest) address wins; nil when the text has none. Pure.
enum LocalPageFinder {
    private static let address = try! NSRegularExpression(
        pattern: #"(?<![\w.@-])(?:(https?)://)?(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:\d{1,5})?(/[^\s'"<>`)\]}|]*)?"#,
        options: [.caseInsensitive])
    private static let ansi = try! NSRegularExpression(pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])"#)
    private static let commandPattern = try! NSRegularExpression(
        pattern: #"\b((?:npm|pnpm|yarn|bun)\s+(?:run\s+)?[A-Za-z][\w:.-]*|npx\s+[A-Za-z@][\w@/.-]*(?:\s+[a-z][\w-]*)?)"#)

    static func find(in text: String) -> LocalPage? {
        let lines = stripANSI(text).components(separatedBy: .newlines)
        for (i, line) in lines.enumerated().reversed() {
            guard let url = urls(in: line).last else { continue }
            return LocalPage(url: url, command: command(in: lines[...i]))
        }
        return nil
    }

    static func stripANSI(_ text: String) -> String {
        ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The local addresses in one line, in order. A bare host needs a port (`localhost` alone is a word, not a page).
    static func urls(in line: String) -> [URL] {
        address.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: line).map { String(line[$0]) } }
            let scheme = group(1)?.lowercased(), port = group(3)
            guard scheme != nil || port != nil else { return nil }
            var host = group(2)!.lowercased()
            if host == "0.0.0.0" { host = "localhost" }
            var path = group(4) ?? "/"
            while let last = path.last, ".,;:!?'\"".contains(last) { path.removeLast() }
            return URL(string: "\(scheme ?? "http")://\(host)\(port ?? "")\(path.isEmpty ? "/" : path)")
        }
    }

    /// The nearest dev command at or above the address line (`npm run dev`, `pnpm dev`, `npx expo start`).
    private static func command(in lines: ArraySlice<String>) -> String? {
        for line in lines.reversed() {
            let ns = NSRange(line.startIndex..., in: line)
            if let m = commandPattern.matches(in: line, range: ns).last, let r = Range(m.range(at: 1), in: line) { return String(line[r]) }
        }
        return nil
    }
}

/// What the preview does with a page it is asked to open (N225, not configurable): local pages load in the pane, every other link
/// opens in the default browser.
enum PreviewRoute: Equatable {
    case load, openOutside, ignore

    static func of(_ url: URL, mainFrame: Bool = true, session: PreviewSession = .local) -> PreviewRoute {
        if PreviewLink.isArtifact(url) { return .load }
        // The claude.ai view follows claude.ai (sign-in included) and Google's sign-in page; its frames (the artifact itself) load freely.
        if session == .claude, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            if !mainFrame { return .load }
            if PreviewLink.isClaudeHost(url.host) || url.host?.lowercased() == "accounts.google.com" { return .load }
            return .openOutside
        }
        switch url.scheme?.lowercased() {
        case "file", "about", "data", "blob": return .load
        case "javascript": return .ignore
        case "http", "https":
            if isLocalHost(url.host) { return .load }
            return mainFrame ? .openOutside : .ignore
        case nil: return .ignore
        default: return mainFrame ? .openOutside : .ignore
        }
    }

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) || host.hasSuffix(".localhost")
    }

    /// What the user typed in the address field as a URL: `localhost:5173/x` gets `http://`, a path gets `file://`.
    static func typed(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("/") || t.hasPrefix("~") { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath) }
        if t.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil || t.hasPrefix("about:") { return URL(string: t) }
        return URL(string: "http://" + t)
    }
}

/// The line a picked element leaves in the card's `## Fix notes` (and in the message box): `- <url> <selector>: <note>`.
enum PreviewNote {
    static func line(url: URL, selector: String, note: String) -> String {
        let one = note.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return "- \(url.absoluteString) \(selector): \(one)"
    }

    /// Appends `line` to the card's `## Fix notes`, read fresh from disk (the note only adds a line, so a body changed since the panel
    /// read it is not a reason to refuse).
    static func append(_ line: String, toCardAt url: URL, writer: CardWriting = CardWriter()) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw CardWriteError.unreadable(url.path) }
        let card = try CardParser.parse(text.replacingOccurrences(of: "\r\n", with: "\n"), url: url)
        try writer.update(card, set: [:], section: SectionEdit(.fixNotes, line), expectingStatus: card.status)
    }
}

/// Whether something listens on a local page's port (N242): a TCP connect to loopback only (127.0.0.1, ::1), short timeout, run off
/// the calling actor. A host that is not loopback is never connected to.
enum LoopbackPort {
    static func isOpen(_ url: URL, timeout: Duration = .milliseconds(300)) async -> Bool {
        guard let host = url.host?.lowercased(), let port = url.port ?? defaultPort(url.scheme), (1...65535).contains(port) else { return false }
        let targets: [String]
        switch host {
        case "localhost": targets = ["127.0.0.1", "::1"]
        case "127.0.0.1": targets = ["127.0.0.1"]
        case "::1", "[::1]": targets = ["::1"]
        default: return false
        }
        let ms = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return await Task.detached(priority: .utility) { targets.contains { connect($0, port: UInt16(port), timeoutMs: ms) } }.value
    }

    private static func defaultPort(_ scheme: String?) -> Int? { scheme == "https" ? 443 : scheme == "http" ? 80 : nil }

    private static func connect(_ address: String, port: UInt16, timeoutMs: Int32) -> Bool {
        let v6 = address.contains(":")
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var result: Int32
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, address, &a.sin6_addr) == 1 else { return false }
            result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
            guard inet_pton(AF_INET, address, &a.sin_addr) == 1 else { return false }
            result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, timeoutMs) == 1 else { return false }
        var err: Int32 = 0, len = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0
    }
}
