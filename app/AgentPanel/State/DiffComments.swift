import Foundation

/// A comment on one diff line or a range of them (N249), not yet sent to the agent.
struct DiffComment: Codable, Equatable, Identifiable {
    /// One commented line: its old and new line numbers (as the diff row shows them) and its text.
    struct LineRef: Codable, Equatable, Hashable {
        let old: Int?
        let new: Int?
        let text: String

        init(old: Int?, new: Int?, text: String) { self.old = old; self.new = new; self.text = text }
        init(_ line: FileDiff.Line) { self.init(old: line.old, new: line.new, text: line.text) }

        func matches(_ line: FileDiff.Line) -> Bool { line.old == old && line.new == new }
    }

    var id = UUID()
    let path: String
    /// The commented lines in diff order; the comment shows under the last one.
    let lines: [LineRef]
    var text: String

    /// `path:line` or `path:first-last`: new-side numbers, or the old side when every line is a removed one.
    var location: String {
        let news = lines.compactMap(\.new)
        let numbers = news.isEmpty ? lines.compactMap(\.old) : news
        guard let first = numbers.first, let last = numbers.last else { return path }
        let place = first == last ? "\(path):\(first)" : "\(path):\(first)-\(last)"
        return news.isEmpty ? place + " (removed)" : place
    }
}

/// The unsent comments of one card, on the commit they were made on.
struct DiffCommentDraft: Codable, Equatable {
    var head: String
    var comments: [DiffComment] = []
}

/// Every card's unsent diff comments (N249), kept in the defaults so they survive tab and card switches and a restart. A card's comments
/// belong to its head commit: when the card shows a new head they are dropped and the count is kept for the "older commit" note.
/// Nothing leaves this store but through `send`, which the Send button calls.
@Observable @MainActor
final class DiffCommentStore {
    static let defaultsKey = "diffComments"

    private(set) var drafts: [String: DiffCommentDraft]
    /// Cards whose comments were dropped for a new head: how many.
    private(set) var dropped: [String: Int] = [:]
    private(set) var sending: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: DiffCommentDraft].self, from: $0) } ?? [:]
    }

    /// The store key of a card: its project and id.
    static func key(project: String, card: String) -> String { "\(project)/\(card)" }

    func comments(_ key: String) -> [DiffComment] { drafts[key]?.comments ?? [] }

    /// The card shows `head` now: comments made on another commit are dropped (and counted for the note).
    func sync(_ key: String, head: String) {
        guard let draft = drafts[key], draft.head != head else { return }
        if !draft.comments.isEmpty { dropped[key] = draft.comments.count }
        drafts[key] = nil
        save()
    }

    func dismissDropped(_ key: String) { dropped[key] = nil }

    @discardableResult
    func add(_ key: String, head: String, path: String, lines: [DiffComment.LineRef], text: String) -> DiffComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !lines.isEmpty else { return nil }
        sync(key, head: head)
        let comment = DiffComment(path: path, lines: lines, text: trimmed)
        drafts[key, default: DiffCommentDraft(head: head)].comments.append(comment)
        save()
        return comment
    }

    /// New text for a comment; an empty text removes it.
    func edit(_ key: String, id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { remove(key, id: id); return }
        guard let i = drafts[key]?.comments.firstIndex(where: { $0.id == id }) else { return }
        drafts[key]?.comments[i].text = trimmed
        save()
    }

    func remove(_ key: String, id: UUID) {
        drafts[key]?.comments.removeAll { $0.id == id }
        if drafts[key]?.comments.isEmpty == true { drafts[key] = nil }
        save()
    }

    /// Sends the card's comments as one fix request through `fix` (the review flow's path); they are cleared when it reached the agent.
    @discardableResult
    func send(_ key: String, using fix: (String) async -> Bool) async -> Bool {
        let list = comments(key)
        guard !list.isEmpty, !sending.contains(key) else { return false }
        sending.insert(key)
        defer { sending.remove(key) }
        guard await fix(Self.fixNotes(list)) else { return false }
        // Keep comments written while the request was on its way.
        drafts[key]?.comments.removeAll { c in list.contains { $0.id == c.id } }
        if drafts[key]?.comments.isEmpty == true { drafts[key] = nil }
        save()
        return true
    }

    /// The fix request text: one item per comment, `path:line`, the quoted code lines, then the comment.
    static func fixNotes(_ comments: [DiffComment]) -> String {
        let items = comments.map { c in
            let code = c.lines.map { "  > " + $0.text.replacingOccurrences(of: "\t", with: "    ") }
            let text = c.text.components(separatedBy: "\n").map { "  " + $0 }
            return (["- `\(c.location)`"] + code + text).joined(separator: "\n")
        }
        let count = comments.count == 1 ? "1 comment" : "\(comments.count) comments"
        return "Comments on the diff (\(count)):\n\n" + items.joined(separator: "\n")
    }

    private func save() {
        if drafts.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else if let data = try? JSONEncoder().encode(drafts) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Where comments go among a file's diff rows.
enum DiffCommentLayout {
    /// Each comment under the row of its last line; comments whose line is not shown (folded away again) are `unplaced`.
    static func anchors(rows: [FileDiff.Row], comments: [DiffComment]) -> (under: [Int: [DiffComment]], unplaced: [DiffComment]) {
        var under: [Int: [DiffComment]] = [:], unplaced: [DiffComment] = []
        for c in comments {
            let i = c.lines.last.flatMap { ref in rows.firstIndex { if case .line(let l) = $0 { return ref.matches(l) } else { return false } } }
            if let i { under[i, default: []].append(c) } else { unplaced.append(c) }
        }
        return (under, unplaced)
    }

    /// The code lines of the rows from `a` to `b` (either way round), hunk headers and gaps left out.
    static func lines(rows: [FileDiff.Row], from a: Int, to b: Int) -> [DiffComment.LineRef] {
        let lo = max(min(a, b), 0), hi = min(max(a, b), rows.count - 1)
        guard lo <= hi else { return [] }
        return rows[lo...hi].compactMap { if case .line(let l) = $0 { return DiffComment.LineRef(l) } else { return nil } }
    }
}

extension TaskDiffReader {
    /// The branch's head commit: the commit the card's comments belong to.
    func head() async -> String? {
        let r = await runner.run(git, ["-C", repoPath, "rev-parse", "--verify", "--quiet", "\(branch)^{commit}"])
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !sha.isEmpty ? sha : nil
    }
}
