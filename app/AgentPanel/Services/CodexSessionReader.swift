import Foundation

/// Which coding agent a session belongs to. A plain enum until the role's `tool` field (N145) is merged; then it is read from there.
enum AgentTool: String, Equatable, Sendable {
    case claude, codex
}

/// The cumulative token use and plan windows Codex wrote last in a session file.
struct CodexUsage: Equatable {
    var tokens: TokenUsage
    var model: String?
    var fiveHour: PlanUsage.Window?
    var week: PlanUsage.Window?
}

/// Reads one Codex session file (`~/.codex/sessions/Y/M/D/rollout-<time>-<id>.jsonl`) and turns it into chat entries like
/// `TranscriptReader`. Read-only; each `poll` reads only the bytes added since the last one.
struct CodexSessionReader {
    let url: URL
    private(set) var entries: [ChatEntry] = []
    private var offset: UInt64 = 0
    private var tail = Data()
    private var tally = CodexToolTally()
    /// A dropped key notice is followed by the PM's bare ✓; that reply is dropped too (same rule as `TranscriptReader`).
    private var dropAck = false
    private static let keyNotice = "Panel: new authority key"
    private static let firstReadLimit: UInt64 = 2_000_000
    private static let entryLimit = 300

    let attachmentsRoot: URL

    init(url: URL, attachmentsRoot: URL = Attachments.defaultRoot) { self.url = url; self.attachmentsRoot = attachmentsRoot }

    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    /// The session file with this id (the end of its name), else the newest one whose `cwd` is the worktree. Nil when there is none.
    static func find(root: URL, sessionID: String?, cwd: String?) -> URL? {
        let files = rollouts(root: root)
        if let id = sessionID, !id.isEmpty, let hit = files.first(where: { $0.url.lastPathComponent.hasSuffix("-\(id).jsonl") }) { return hit.url }
        guard let cwd, !cwd.isEmpty else { return nil }
        return files.first { meta($0.url)?.cwd == cwd }?.url
    }

    /// Every session file whose `cwd` is the worktree, newest first.
    static func sessions(root: URL, cwd: String) -> [URL] {
        rollouts(root: root).filter { meta($0.url)?.cwd == cwd }.map(\.url)
    }

    /// All `rollout-*.jsonl` files under the root, newest first (the day folders and the time in the name sort the same way).
    static func rollouts(root: URL) -> [(url: URL, modified: Date)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            found.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.modified == $1.modified ? $0.url.path > $1.url.path : $0.modified > $1.modified }
    }

    /// The id and working directory in the first line (`session_meta`).
    static func meta(_ url: URL) -> (id: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 65_536), let nl = head.firstIndex(of: 0x0A) ?? (head.isEmpty ? nil : head.endIndex),
              let obj = try? JSONSerialization.jsonObject(with: head[head.startIndex..<nl]) as? [String: Any],
              obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any],
              let id = p["id"] as? String, let cwd = p["cwd"] as? String else { return nil }
        return (id, cwd)
    }

    /// The last cumulative token count and plan windows of a file; nil when it has no `token_count` line or cannot be read.
    /// `primary` is the 5-hour window and `secondary` the week by their `window_minutes` (under 6 hours is the short one).
    static func usage(_ url: URL) -> CodexUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var result: CodexUsage?
        var model: String?
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let p = obj["payload"] as? [String: Any] else { continue }
            if obj["type"] as? String == "turn_context", let m = p["model"] as? String { model = m }
            guard obj["type"] as? String == "event_msg", p["type"] as? String == "token_count" else { continue }
            var next = result ?? CodexUsage(tokens: TokenUsage())
            if let info = p["info"] as? [String: Any], let t = info["total_token_usage"] as? [String: Any] {
                let cached = t["cached_input_tokens"] as? Int ?? 0
                // Codex counts the cached tokens inside input_tokens; the panel's TokenUsage keeps them apart, like Claude's.
                next.tokens = TokenUsage(input: max((t["input_tokens"] as? Int ?? 0) - cached, 0), output: t["output_tokens"] as? Int ?? 0,
                                         cacheWrite: t["cache_write_input_tokens"] as? Int ?? 0, cacheRead: cached)
            }
            if let limits = p["rate_limits"] as? [String: Any] {
                next.fiveHour = nil; next.week = nil
                for key in ["primary", "secondary"] {
                    guard let w = limits[key] as? [String: Any], let pct = w["used_percent"] as? Double, let reset = w["resets_at"] as? Double else { continue }
                    let window = PlanUsage.Window(percent: pct, resetsAt: Date(timeIntervalSince1970: reset))
                    let minutes = w["window_minutes"] as? Double ?? (key == "primary" ? 300 : 10_080)
                    if minutes < 360 { next.fiveHour = window } else { next.week = window }
                }
            }
            result = next
        }
        result?.model = model
        return result
    }

    /// Reads what was added; true when the entries changed.
    mutating func poll() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var skipFirstLine = false
        if size < offset { offset = 0; tail = Data(); entries = []; tally = CodexToolTally(); dropAck = false }
        if offset == 0 && entries.isEmpty && size > Self.firstReadLimit { offset = size - Self.firstReadLimit; skipFirstLine = true }
        guard size > offset else { return false }
        try? handle.seek(toOffset: offset)
        guard let fresh = try? handle.readToEnd(), !fresh.isEmpty else { return false }
        offset += UInt64(fresh.count)
        var data = tail + fresh
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(data[data.startIndex..<nl])
            data = Data(data[data.index(after: nl)...])
        }
        tail = data
        if skipFirstLine && !lines.isEmpty { lines.removeFirst() }
        var changed = false
        for line in lines where !line.isEmpty { if apply(line) { changed = true } }
        if entries.count > Self.entryLimit { entries.removeFirst(entries.count - Self.entryLimit) }
        return changed
    }

    private mutating func apply(_ line: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["type"] as? String == "response_item",
              let p = obj["payload"] as? [String: Any], let kind = p["type"] as? String else { return false }
        let time = (obj["timestamp"] as? String).flatMap(Self.parseTime)
        let id = p["id"] as? String ?? p["call_id"] as? String ?? "\(url.lastPathComponent)-\(offset)-\(entries.count)"
        switch kind {
        case "message":
            let text = ((p["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            switch p["role"] as? String {
            case "assistant":
                if text.isEmpty { return false }
                if dropAck { dropAck = false; if ["✓", "✓."].contains(text) { return false } }
                tally = CodexToolTally()
                entries.append(ChatEntry(id: id, kind: .agent, text: text, time: time))
                return true
            case "user":
                // The session's own preamble (instructions, environment) is not a message of the user.
                let wrappers = ["<environment_context>", "<user_instructions>", "<permissions", "<system-reminder>", "# AGENTS.md", "<INSTRUCTIONS>"]
                if text.isEmpty || wrappers.contains(where: { text.hasPrefix($0) }) { return false }
                dropAck = text.hasPrefix(Self.keyNotice)
                if dropAck { return false }
                let split = AttachmentLines.split(text, root: attachmentsRoot)
                tally = CodexToolTally()
                entries.append(ChatEntry(id: id, kind: PanelMessage.isPanel(split.text) ? .panel : .user, text: split.text, time: time, images: split.images, files: split.files))
                return true
            default: return false
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            tally.add(name: p["name"] as? String ?? (kind == "local_shell_call" ? "shell" : ""))
            if let last = entries.last, last.kind == .tools { entries[entries.count - 1].text = tally.summary }
            else { entries.append(ChatEntry(id: id, kind: .tools, text: tally.summary, time: time)) }
            return true
        default: return false
        }
    }

    private static func parseTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Counts the tool calls between two messages for the one-line summary, like `ToolTally` does for Claude.
private struct CodexToolTally {
    var commands = 0, edits = 0, others = 0

    mutating func add(name: String) {
        switch name {
        case "shell", "exec_command", "container.exec", "shell_command": commands += 1
        case "apply_patch": edits += 1
        default: others += 1
        }
    }

    var summary: String {
        var parts: [String] = []
        if commands > 0 { parts.append("ran \(commands) command\(commands == 1 ? "" : "s")") }
        if edits > 0 { parts.append("edited \(edits) time\(edits == 1 ? "" : "s")") }
        if others > 0 { parts.append("used \(others) other tool\(others == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
