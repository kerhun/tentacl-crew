import Foundation

/// One line of the conversation thread.
struct ChatEntry: Identifiable, Equatable {
    /// `panel`: a message the panel itself typed into the agent's session (it arrives there as a user turn).
    /// `summary`: the compaction summary Claude Code writes as a user line; its text is kept for a later "View summary".
    enum Kind: Equatable { case user, agent, tools, panel, summary }
    /// A message the panel sent (or tried to send) that the transcript does not show yet.
    enum Pending: Equatable {
        case queued
        case failed(String)
        /// Unmatched for a while after the agent was idle: it may never have arrived. The user can Retry or Remove it.
        case notSeen
    }
    let id: String
    var kind: Kind
    var text: String
    let time: Date?
    /// Images the user attached to this message.
    var images: [ChatImage] = []
    /// Files and folders the user attached (`[File: path]`, `[Folder: path]` lines), shown as chips.
    var files: [ChatFile] = []
    /// Nil for every line read from the transcript.
    var pending: Pending? = nil
    /// The agent turn's tool uses, one short line each ("Bash · git log --oneline -1").
    var tools: [String] = []
    /// "ran 3 commands, read 2 files" for the tool uses of an `.agent` entry (a `.tools` entry has it as its text).
    var toolSummary = ""
}

/// The fixed openings of the messages the panel types into an agent's session on its own (PM notices, start and approve answers,
/// task starts, fix requests, the hand-off, the commit request, the skip answer). The user's own messages never get these.
enum PanelMessage {
    static let prefixes = [
        "Panel: ", "Your task card: ", "Fix request for your task card ", "Please write a short hand-off note to ",
        "Your worktree has uncommitted work, so the review cannot be prepared.", "Skip this question and carry on with your best judgment.",
    ]
    /// `PMHandoff.firstPrompt`: "Read <file> and your project's roadmap, then continue as the PM."
    private static let handoffEnd = " and your project's roadmap, then continue as the PM."

    static func isPanel(_ text: String) -> Bool {
        prefixes.contains { text.hasPrefix($0) } || (text.hasPrefix("Read /") && text.hasSuffix(handoffEnd))
    }
}

/// An image shown in the thread: a file in the panel's attachments folder, or the bytes of one of Claude Code's own image blocks.
enum ChatImage: Equatable {
    case file(String)
    case inline(Data)
}

/// A file or folder named in the user's message. `copied`: the panel's own copy in its attachments folder; else the original path.
struct ChatFile: Equatable {
    let path: String
    let folder: Bool
    let copied: Bool
    var name: String { (path as NSString).lastPathComponent }
}

/// Reads one Claude Code session file (`~/.claude/projects/<cwd>/<session>.jsonl`) and turns it into chat entries: the user's prompts,
/// the agent's text replies and its tool use folded into one line. Read-only; each `poll` reads only the bytes added since the last one,
/// and a last line that is still being written waits for its end.
struct TranscriptReader {
    let url: URL
    /// `[Image: path]` lines become thumbnails only when the path is inside this folder (the panel's own); `[File: path]` inside it
    /// is a copy, elsewhere a link.
    let attachmentsRoot: URL
    private(set) var entries: [ChatEntry] = []
    private var offset: UInt64 = 0
    private var tail = Data()
    private var tally: ToolTally?
    /// True while the last entry is an agent turn that more assistant blocks may still join (until the next user or panel entry).
    private var turnOpen = false
    /// A dropped key notice is followed by the PM's bare ✓ (and maybe tool use); those are dropped too until other text arrives.
    private var dropAck = false
    private static let keyNotice = "Panel: new authority key"
    /// The first read of a long session starts near the end instead of parsing megabytes.
    private static let firstReadLimit: UInt64 = 2_000_000
    private var entryCap = 300
    /// Where the first entry's line starts in the file (every entry before this offset is not in `entries`); 0 once the start is reached.
    private var windowStart: UInt64 = 0
    /// The file offset of the line that began each entry, parallel to `entries`.
    private var starts: [UInt64] = []
    var hasEarlier: Bool { windowStart > 0 }

    init(url: URL, attachmentsRoot: URL = Attachments.defaultRoot) { self.url = url; self.attachmentsRoot = attachmentsRoot }

    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Claude Code names the folder after the working directory with every character that is not a letter or digit (and not "-") turned into "-".
    static func path(projectsRoot: URL, cwd: String, session: String) -> URL {
        let folder = String(cwd.unicodeScalars.map { s -> Character in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "-")) ? Character(s) : "-"
        })
        return projectsRoot.appendingPathComponent(folder).appendingPathComponent("\(session).jsonl")
    }

    /// Reads what was added; true when the entries changed.
    mutating func poll() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var skipFirstLine = false
        if size < offset { offset = 0; windowStart = 0; starts = []; entryCap = 300; tail = Data(); entries = []; tally = nil; turnOpen = false; dropAck = false }
        if offset == 0 && entries.isEmpty && size > Self.firstReadLimit { offset = size - Self.firstReadLimit; skipFirstLine = true }
        let base = offset
        guard size > offset else { return false }
        try? handle.seek(toOffset: offset)
        guard let fresh = try? handle.readToEnd(), !fresh.isEmpty else { return false }
        offset += UInt64(fresh.count)
        let tailCount = UInt64(tail.count)
        var data = tail + fresh
        var changed = false
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(data[data.startIndex..<nl])
            data = Data(data[data.index(after: nl)...])
        }
        tail = data
        // `data` began at `base - tail`; the first read has no tail.
        var lineStart = base - tailCount
        if skipFirstLine {
            lineStart += (lines.first.map { UInt64($0.count) + 1 } ?? UInt64(fresh.count))
            windowStart = lineStart
            if !lines.isEmpty { lines.removeFirst() }
        }
        if ingest(lines, from: lineStart) { changed = true }
        if entries.count > entryCap {
            let cut = entries.count - entryCap
            entries.removeFirst(cut); starts.removeFirst(cut)
            windowStart = starts[0]
        }
        return changed
    }

    /// Applies whole lines that began at `start`, noting where each new entry's line began.
    private mutating func ingest(_ lines: [Data], from start: UInt64) -> Bool {
        var changed = false, at = start
        for line in lines {
            let before = entries.count
            if !line.isEmpty, apply(line) { changed = true }
            if entries.count > before { starts.append(at) }
            at += UInt64(line.count) + 1
        }
        return changed
    }

    /// Reads the 2 MB before the first read's start and puts its entries before the others (those already known are skipped).
    /// A turn cut by the window's end is shown as two turns.
    @discardableResult
    mutating func loadEarlier() -> Bool {
        guard windowStart > 0, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let end = windowStart
        let from = end > Self.firstReadLimit ? end - Self.firstReadLimit : 0
        guard (try? handle.seek(toOffset: from)) != nil, let data = try? handle.read(upToCount: Int(end - from)) else { return false }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        var newStart = from
        if from > 0, !lines.isEmpty { newStart = from + UInt64(lines[0].count) + 1; lines.removeFirst() }
        var older = TranscriptReader(url: url, attachmentsRoot: attachmentsRoot)
        _ = older.ingest(lines, from: newStart)
        let known = Set(entries.map(\.id))
        let keep = older.entries.indices.filter { !known.contains(older.entries[$0].id) }
        entries = keep.map { older.entries[$0] } + entries
        starts = keep.map { older.starts[$0] } + starts
        entryCap = .max
        windowStart = newStart
        return true
    }

    private mutating func apply(_ line: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String, type == "user" || type == "assistant" || type == "attachment",
              obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true else { return false }
        let id = obj["uuid"] as? String ?? UUID().uuidString
        let time = (obj["timestamp"] as? String).flatMap { Self.parseTime($0) }
        if type == "attachment" { return applyQueuedPrompt(obj["attachment"] as? [String: Any], id: id, time: time) }
        guard let message = obj["message"] as? [String: Any] else { return false }
        if type == "user" {
            guard let (text, images, files) = userContent(message["content"]) else { return false }
            dropAck = text.hasPrefix(Self.keyNotice)
            if dropAck { return false }
            tally = nil; turnOpen = false
            let compact = obj["isCompactSummary"] as? Bool == true || obj["isVisibleInTranscriptOnly"] as? Bool == true
            entries.append(ChatEntry(id: id, kind: compact ? .summary : PanelMessage.isPanel(text) ? .panel : .user, text: text, time: time, images: images, files: files))
            return true
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        var changed = false
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                if dropAck {
                    if ["✓", "✓."].contains(text) { dropAck = false; continue }
                    dropAck = false
                }
                if turnOpen {
                    let i = entries.count - 1
                    entries[i].text = entries[i].kind == .agent ? entries[i].text + "\n\n" + text : text
                    entries[i].kind = .agent
                } else {
                    entries.append(ChatEntry(id: id, kind: .agent, text: text, time: time))
                    turnOpen = true
                }
                changed = true
            case "tool_use":
                if dropAck { continue }
                var t = tally ?? ToolTally()
                let name = block["name"] as? String ?? "", input = block["input"] as? [String: Any] ?? [:]
                t.add(name: name, input: input)
                tally = t
                if turnOpen {
                    let i = entries.count - 1
                    entries[i].tools.append(ToolTally.line(name: name, input: input))
                    entries[i].toolSummary = t.summary
                    if entries[i].kind == .tools { entries[i].text = t.summary }
                } else {
                    entries.append(ChatEntry(id: id, kind: .tools, text: t.summary, time: time, tools: [ToolTally.line(name: name, input: input)], toolSummary: t.summary))
                    turnOpen = true
                }
                changed = true
            default: continue
            }
        }
        return changed
    }

    /// A message sent while the agent was working is not written as a `user` line: Claude Code injects it into the running turn as a
    /// `queued_command` attachment with `commandMode: "prompt"` (task notifications use another mode).
    private mutating func applyQueuedPrompt(_ attachment: [String: Any]?, id: String, time: Date?) -> Bool {
        guard let attachment, attachment["type"] as? String == "queued_command", attachment["commandMode"] as? String == "prompt",
              let (text, images, files) = userContent(attachment["prompt"]) else { return false }
        dropAck = text.hasPrefix(Self.keyNotice)
        if dropAck { return false }
        tally = nil; turnOpen = false
        entries.append(ChatEntry(id: id, kind: PanelMessage.isPanel(text) ? .panel : .user, text: text, time: time, images: images, files: files))
        return true
    }

    /// The prompt text, images and files of a user line, or nil for tool results and the harness's own wrappers.
    private func userContent(_ content: Any?) -> (String, [ChatImage], [ChatFile])? {
        var text = ""
        var images: [ChatImage] = []
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            for block in blocks where block["type"] as? String == "image" {
                if let source = block["source"] as? [String: Any], let b64 = source["data"] as? String, let data = Data(base64Encoded: b64) { images.append(.inline(data)) }
            }
            // Claude Code writes "[Image #1]" next to its own image blocks.
            if !images.isEmpty { text = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.firstMatch(of: /^\[Image #\d+\]$/) == nil }.joined(separator: "\n") }
        }
        text = PastedContent.unwrap(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = ["<system-reminder>", "<command-", "<local-command", "<task-notification", "Caveat:"]
        if wrappers.contains(where: { text.hasPrefix($0) }) { return nil }
        let split = AttachmentLines.split(text, root: attachmentsRoot)
        text = split.text; images += split.images
        let files = split.files
        if text.isEmpty && images.isEmpty && files.isEmpty { return nil }
        return (text, images, files)
    }

    private static func parseTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Splits a user message into its text and the `[Image: path]`, `[File: path]` and `[Folder: path]` lines the panel adds (shared by Claude and Codex chats).
/// Images become thumbnails only inside the panel's attachments folder `root`.
enum AttachmentLines {
    static func split(_ text: String, root: URL) -> (text: String, images: [ChatImage], files: [ChatFile]) {
        var images: [ChatImage] = []
        var files: [ChatFile] = []
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let m = line.firstMatch(of: /^\[Image: (\/.+)\]$/), Attachments.isInside(String(m.1), root: root) { images.append(.file(String(m.1))) }
            else if let m = line.firstMatch(of: /^\[(File|Folder): (\/.+)\]$/) {
                let path = String(m.2)
                files.append(ChatFile(path: path, folder: m.1 == "Folder", copied: m.1 == "File" && Attachments.isInside(path, root: root)))
            } else { kept.append(line) }
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), images, files)
    }
}

/// The session file of an agent, read as its tool's format: Claude's `TranscriptReader` or Codex's `CodexSessionReader`.
enum SessionTranscript {
    case claude(TranscriptReader)
    case codex(CodexSessionReader)

    /// The reader for an agent of `tool`. Codex sessions are found by id, else by the worktree as `cwd`; before the file exists
    /// (`find` is nil) the reader is nil and the caller tries again on the next poll.
    static func make(tool: AgentTool, cwd: String, session: String, projectsRoot: URL, codexRoot: URL, attachmentsRoot: URL = Attachments.defaultRoot) -> SessionTranscript? {
        switch tool {
        case .claude: return .claude(TranscriptReader(url: TranscriptReader.path(projectsRoot: projectsRoot, cwd: cwd, session: session), attachmentsRoot: attachmentsRoot))
        case .codex: return CodexSessionReader.find(root: codexRoot, sessionID: session, cwd: cwd).map { .codex(CodexSessionReader(url: $0, attachmentsRoot: attachmentsRoot)) }
        }
    }

    var entries: [ChatEntry] {
        switch self { case .claude(let r): r.entries; case .codex(let r): r.entries }
    }

    /// Only a Claude session read from a later start has earlier entries to load.
    var hasEarlier: Bool {
        if case .claude(let r) = self { return r.hasEarlier }
        return false
    }

    mutating func loadEarlier() {
        if case .claude(var r) = self { r.loadEarlier(); self = .claude(r) }
    }

    mutating func poll() -> Bool {
        switch self {
        case .claude(var r): let changed = r.poll(); self = .claude(r); return changed
        case .codex(var r): let changed = r.poll(); self = .codex(r); return changed
        }
    }
}

/// Counts the tool calls between two messages for the one-line summary ("ran 4 commands, edited 2 files").
private struct ToolTally {
    var commands = 0
    var edited = Set<String>()
    var editCalls = 0
    var reads = 0
    var others = 0

    mutating func add(name: String, input: [String: Any]) {
        switch name {
        case "Bash": commands += 1
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            editCalls += 1
            if let p = input["file_path"] as? String ?? input["notebook_path"] as? String { edited.insert(p) }
        case "Read", "Grep", "Glob": reads += 1
        default: others += 1
        }
    }

    /// "Bash · git log --oneline -1", "Read · pm-handoff.md": the tool and what it works on.
    static func line(name: String, input: [String: Any]) -> String {
        let what: String
        switch name {
        case "Bash": what = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
        case "Read", "Edit", "Write", "MultiEdit": what = ((input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        case "NotebookEdit": what = ((input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        case "Grep", "Glob": what = input["pattern"] as? String ?? ""
        default: what = ""
        }
        let short = what.count > 80 ? String(what.prefix(80)) + "…" : what
        return short.isEmpty ? name : "\(name) · \(short)"
    }

    var summary: String {
        var parts: [String] = []
        if commands > 0 { parts.append("ran \(commands) command\(commands == 1 ? "" : "s")") }
        let files = edited.isEmpty ? editCalls : edited.count
        if files > 0 { parts.append("edited \(files) file\(files == 1 ? "" : "s")") }
        if reads > 0 { parts.append("read \(reads) file\(reads == 1 ? "" : "s")") }
        if others > 0 { parts.append("used \(others) other tool\(others == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// Claude Code stores a long pasted message as `<pasted_content id="…">…</pasted_content id="…">`. The thread shows only the text inside.
enum PastedContent {
    static func unwrap(_ text: String) -> String {
        guard text.contains("<pasted_content") else { return text }
        return text.replacing(/(?s)<pasted_content\b[^>]*>(.*?)<\/pasted_content\b[^>]*>/) { String($0.1) }
    }
}
