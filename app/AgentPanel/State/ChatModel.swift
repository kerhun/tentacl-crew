import Foundation
import Observation

/// The conversation with the agent chosen in the Command box: read from that agent's Claude session file, never written.
/// Messages sent but not in the file yet are drawn after it as pending entries (kept in memory only).
@MainActor @Observable
final class ChatModel {
    private(set) var entries: [ChatEntry] = []
    /// The agent is in the middle of a turn: its reply is still being written.
    private(set) var working = false
    /// The agent replied while the user was looking elsewhere.
    private(set) var unread = false
    private(set) var hasConversation = false
    /// The first read started past the file's start: Load earlier reads more. `earlierFrom` is the time of the first entry shown.
    private(set) var canLoadEarlier = false
    private(set) var earlierFrom: Date?

    @ObservationIgnored private let projectsRoot: URL
    @ObservationIgnored private let codexRoot: URL
    @ObservationIgnored private var reader: SessionTranscript?
    @ObservationIgnored private var key: String?
    /// A read is running off the main thread; `generation` changes with the chosen agent, so an old read's result is dropped.
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var firstReadDone = false

    @ObservationIgnored private let attachmentsRoot: URL
    /// Sent messages waiting for their transcript line, oldest first, each with the transcript lines that were already there
    /// when it was sent (an older identical message must not count as its delivery).
    @ObservationIgnored private var pending: [(entry: ChatEntry, before: Set<String>)] = []

    init(projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"), codexRoot: URL = CodexSessionReader.defaultRoot, attachmentsRoot: URL = Attachments.defaultRoot) {
        self.projectsRoot = projectsRoot
        self.codexRoot = codexRoot
        self.attachmentsRoot = attachmentsRoot
    }

    /// Call on every poll. `viewing`: the panel is in front, so a new reply is seen at once.
    /// The file is read and parsed off the main thread (N131); a read still running when the next poll comes is not started twice,
    /// and the result of a read for an agent that is no longer the chosen one is dropped.
    /// `tool`: which agent wrote the session (Claude unless the role says Codex).
    /// `now`: the clock, for the not-seen timeout.
    func refresh(agent: AgentStatus?, tool: AgentTool = .claude, viewing: Bool, now: Date = Date()) async {
        guard let agent else { reset(key: nil); return }
        defer { expire(now: now) }
        let newKey = "\(agent.paneID)|\(agent.sessionID ?? "")|\(tool.rawValue)"
        working = agent.state == .working
        if newKey != key {
            reset(key: newKey)
            working = agent.state == .working
            guard let session = agent.sessionID, !session.isEmpty else { trackIdle(now); return }
            reader = SessionTranscript.make(tool: tool, cwd: agent.cwd, session: session, projectsRoot: projectsRoot, codexRoot: codexRoot, attachmentsRoot: attachmentsRoot)
        }
        trackIdle(now)
        // A Codex session file appears a moment after the agent starts: look again until it is there.
        if reader == nil, tool == .codex, let session = agent.sessionID, !session.isEmpty {
            reader = SessionTranscript.make(tool: tool, cwd: agent.cwd, session: session, projectsRoot: projectsRoot, codexRoot: codexRoot, attachmentsRoot: attachmentsRoot)
        }
        guard let current = reader, !reading else { return }
        reading = true
        let generation = self.generation
        let before = lastReplyID
        let (next, changed) = await Task.detached(priority: .userInitiated) { () -> (SessionTranscript, Bool) in
            var copy = current
            let changed = copy.poll()
            return (copy, changed)
        }.value
        reading = false
        guard generation == self.generation else { return }
        reader = next
        let first = !firstReadDone
        if changed || first {
            firstReadDone = true
            publish()
            // History read for the first time is not new.
            if changed, !first, !viewing, lastReplyID != before { unread = true }
        }
    }

    /// Reads the 2 MB before what is shown, off the main thread.
    func loadEarlier() async {
        guard let current = reader, current.hasEarlier, !reading else { return }
        reading = true
        let generation = self.generation
        let next = await Task.detached(priority: .userInitiated) { () -> SessionTranscript in
            var copy = current
            copy.loadEarlier()
            return copy
        }.value
        reading = false
        guard generation == self.generation else { return }
        reader = next
        publish()
    }

    /// How long a message may stay unmatched once the agent is idle before it shows "not seen": a message sent mid-turn is picked up
    /// within the turn, and an idle agent reads its input at once, so two minutes is far past any normal delay yet short enough to act on.
    static let notSeenAfter: TimeInterval = 120
    @ObservationIgnored private var idleSince: Date?

    private func trackIdle(_ now: Date) {
        if working { idleSince = nil } else if idleSince == nil { idleSince = now }
    }

    /// Queued messages the transcript still does not show turn to `.notSeen`; the clock only runs while the agent is idle.
    private func expire(now: Date) {
        guard !working, let idleSince else { return }
        var changed = false
        for i in pending.indices where pending[i].entry.pending == .queued {
            let start = max(pending[i].entry.time ?? idleSince, idleSince)
            if now.timeIntervalSince(start) >= Self.notSeenAfter { pending[i].entry.pending = .notSeen; changed = true }
        }
        if changed { publish() }
    }

    /// Remove: drops a pending message of any state; nothing is sent.
    func remove(_ id: String) {
        guard let i = pending.firstIndex(where: { $0.entry.id == id }) else { return }
        pending.remove(at: i)
        publish()
    }

    /// Retry: takes the message out and returns it; the caller sends it again, which draws a fresh queued copy.
    func retry(_ id: String) -> ChatEntry? {
        guard let i = pending.firstIndex(where: { $0.entry.id == id }) else { return nil }
        let entry = pending.remove(at: i).entry
        publish()
        return entry
    }

    /// Shows a sent message at once with the queued mark; it goes when its line appears in the transcript.
    @discardableResult
    func addPending(_ text: String, kind: ChatEntry.Kind, images: [ChatImage] = [], files: [ChatFile] = [], id: String = "pending-" + UUID().uuidString) -> String {
        let entry = ChatEntry(id: id, kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), time: Date(), images: images, files: files, pending: .queued)
        pending.removeAll { $0.entry.pending != .queued && Self.same($0.entry.text, entry.text) }
        pending.append((entry, Set((reader?.entries ?? []).map(\.id))))
        publish()
        return id
    }

    /// The message waiting out its hold (one per chat); drawn after the thread with Edit and Undo.
    private(set) var held: HeldMessage?
    /// The user pressed Edit: the composer says so until the next send.
    private(set) var editing = false
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var deliverHeld: ((HeldMessage) -> Void)?

    /// Holds a message the user sent; `deliver` runs once, when the time runs out or on `release`.
    /// A message already held is delivered first, so the order is kept.
    func hold(text: String, images: [PendingImage], stored: [URL], delay: Duration = ChatSendDelay.hold, deliver: @escaping (HeldMessage) -> Void) {
        release()
        editing = false
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let message = HeldMessage(text: text, images: images, stored: stored, deadline: Date().addingTimeInterval(seconds))
        held = message
        deliverHeld = deliver
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.held?.id == message.id else { return }
            self?.release()
        }
    }

    /// Sends the held message now (agent switch, leaving the screen, another send); nothing happens when none is held.
    func release() {
        guard let message = held, let deliver = deliverHeld else { return }
        clearHold()
        deliver(message)
    }

    /// Undo or Edit: the held message is not sent; the caller puts it back into the input.
    @discardableResult
    func takeBack(editing: Bool) -> HeldMessage? {
        let message = held
        clearHold()
        self.editing = editing && message != nil
        return message
    }

    private func clearHold() {
        holdTask?.cancel(); holdTask = nil
        held = nil; deliverHeld = nil
    }

    /// The send failed: the bubble shows why instead of the mark, and is never matched away.
    func markFailed(_ id: String, reason: String) {
        guard let i = pending.firstIndex(where: { $0.entry.id == id }) else { return }
        pending[i].entry.pending = .failed(reason)
        publish()
    }

    func markSeen() { unread = false }
    func setUnreadForTest(_ value: Bool) { unread = value }

    /// The last reply's id with its size: a turn grows under a stable id, and new text in it is new.
    private var lastReplyID: String? { entries.last { $0.kind == .agent }.map { "\($0.id)/\($0.text.count)/\($0.tools.count)" } }

    private func publish() {
        let read = reader?.entries ?? []
        var used = Set<String>()
        pending.removeAll { item in
            // Any pending state matches: a failed or not-seen send may have arrived anyway.
            guard let found = read.first(where: { ($0.kind == .user || $0.kind == .panel) && !item.before.contains($0.id) && !used.contains($0.id) && Self.same($0.text, item.entry.text) })
            else { return false }
            used.insert(found.id)
            return true
        }
        entries = read + pending.map(\.entry)
        hasConversation = !read.isEmpty
        canLoadEarlier = reader?.hasEarlier == true
        earlierFrom = canLoadEarlier ? read.first?.time : nil
    }

    /// The same message, apart from whitespace at the ends of its lines.
    static func same(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }
    private static func normalized(_ s: String) -> String {
        PastedContent.unwrap(s).split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacing(/\s+$/, with: "") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pending messages stay through a session change of the same pane (the store keeps one model per pane).
    private func reset(key newKey: String?) {
        key = newKey; idleSince = nil; reader = nil; generation += 1; reading = false; firstReadDone = false; entries = pending.map(\.entry); hasConversation = false; canLoadEarlier = false; earlierFrom = nil; unread = false; working = false
    }
}

/// Splits a reply into the pieces the thread draws: headings, paragraphs, bullets, code and tables.
/// Pipe lines with an alignment row are a `.table` (drawn as a grid); pipe lines without one and runs of box-drawing lines are `.code`.
enum ChatText {
    struct Block: Equatable {
        enum Kind: Equatable { case heading, paragraph, bullet, numbered, code, table }
        let kind: Kind
        let text: String
        /// List nesting: 0, 1 or 2 (N288).
        var level = 0
        /// The number a `.numbered` item was written with.
        var number: Int?
        /// A fenced code block's language (the word after the opening fence).
        var language: String?
    }

    static func preview(_ text: String, maxLines: Int) -> (text: String, cut: Bool) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return (text, false) }
        return (lines.prefix(maxLines).joined(separator: "\n"), true)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var table: [String] = []
        var box: [String] = []
        var code: [String]?
        var language: String?
        // Indents of the list items above the current one, for their nesting level.
        var indents: [Int] = []
        func flush() {
            if !para.isEmpty { out.append(Block(kind: .paragraph, text: para.joined(separator: "\n"))); para = [] }
            if !table.isEmpty {
                let text = table.joined(separator: "\n")
                out.append(Block(kind: MarkdownTable.parse(text) == nil ? .code : .table, text: text)); table = []
            }
            if !box.isEmpty { out.append(Block(kind: .code, text: box.joined(separator: "\n"))); box = [] }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if code != nil {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { out.append(Block(kind: .code, text: code!.joined(separator: "\n"), language: language)); code = nil }
                else { code!.append(raw) }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush(); indents = []; code = []
                language = line.dropFirst(3).split(whereSeparator: \.isWhitespace).first.map(String.init)
                continue
            }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") { if table.isEmpty { flush() }; table.append(raw); continue }
            if !table.isEmpty { flush() }
            // A diagram: box-drawing lines, and the arrow-only lines between them, kept as drawn.
            if isBoxLine(line) || (!box.isEmpty && line.unicodeScalars.contains(where: arrows.contains)) { if box.isEmpty { flush() }; box.append(raw); continue }
            if !box.isEmpty { flush() }
            if let h = line.firstMatch(of: /^#{1,6}\s+(.*)$/) { flush(); out.append(Block(kind: .heading, text: String(h.1))); continue }
            if let b = line.firstMatch(of: /^[-*•]\s+(.*)$/) {
                flush(); out.append(Block(kind: .bullet, text: String(b.1), level: level(raw, &indents))); continue
            }
            if let n = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                flush(); out.append(Block(kind: .numbered, text: String(n.2), level: level(raw, &indents), number: Int(n.1))); continue
            }
            indents = []
            para.append(raw)
        }
        if let code { out.append(Block(kind: .code, text: code.joined(separator: "\n"), language: language)) }
        flush()
        return out
    }

    /// A list item's nesting level from its leading spaces (a tab counts 4): one level deeper for each item above it indented at least 2 less, at most 2.
    private static func level(_ raw: String, _ indents: inout [Int]) -> Int {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        while let last = indents.last, indent < last + 2 { indents.removeLast() }
        indents.append(indent)
        return min(indents.count - 1, 2)
    }

    private static let arrows = Set("▲▼◀▶►◄↑↓←→".unicodeScalars)

    /// True for a line with a box-drawing character (┌─┐│└┘├┤┬┴┼═║╔╗╚╝ and the rest of U+2500–U+257F).
    static func isBoxLine(_ line: String) -> Bool {
        line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
    }
}
