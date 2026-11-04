import Foundation
import Observation

/// What the panel knows when it decides who gets a question (set by the panel before every read).
struct QuestionRouting: Equatable {
    var mode: AgentQuestionMode = .user
    /// The project's PM pane; nil while no PM runs (every question then goes to the user).
    var pmPane: String?
    /// The `files:` of each card, by card id, for the scope hint.
    var cardFiles: [String: [String]] = [:]
}

/// A question the PM answered, kept so modes 1 and 2 stay auditable.
struct AnsweredByPM: Identifiable, Equatable {
    let id: String
    let agent: String
    let cardID: String
    let question: String
    let answer: String
    let time: Date
}

/// Questions held back from the user while the PM has them (N279): which ones, since when, and what the PM answered.
/// A held question returns to the user after `wait`, when the PM stops, or when the PM's answer could not be sent.
@Observable @MainActor
final class QuestionRelay {
    nonisolated static let wait: TimeInterval = 600
    static let answeredKept = 20

    struct Entry: Equatable {
        enum State: Equatable { case held(since: Date), returned, answered }
        let qid: String
        let pendingID: String
        var state: State
        let pane: String
        let question: PendingQuestion
    }
    struct Outgoing: Equatable { let pane: String; let text: String }

    @ObservationIgnored var now: () -> Date = Date.init
    private(set) var entries: [String: Entry] = [:]
    private(set) var answered: [AnsweredByPM] = []
    @ObservationIgnored private var counters: [String: Int] = [:]
    @ObservationIgnored private var outgoing: [Outgoing] = []

    func isHeld(_ pendingID: String) -> Bool {
        if case .held? = entries[pendingID]?.state { return true }
        return false
    }

    /// Since when the PM has had this question; nil when it is not held.
    func heldSince(_ pendingID: String) -> Date? {
        if case .held(let since)? = entries[pendingID]?.state { return since }
        return nil
    }

    /// Whether this question went to the PM at some point (held, returned or answered).
    func wasRelayed(_ pendingID: String) -> Bool { entries[pendingID] != nil }

    /// Whole minutes until a question held since `since` returns to the user (at least 1 while it is held).
    nonisolated static func minutesLeft(since: Date, now: Date) -> Int { max(1, Int(((wait - now.timeIntervalSince(since)) / 60).rounded(.up))) }

    /// The question id of a QUESTION line (`QUESTION N380-q2 ui_dev: …`); nil for any other text.
    static func qid(ofLine text: String) -> String? {
        let w = text.split(separator: " ", maxSplits: 2)
        guard w.count >= 2, w[0] == "QUESTION" else { return nil }
        return String(w[1])
    }

    /// The held entry the PM named.
    func held(_ qid: String) -> Entry? { entries.values.first { $0.qid == qid && isHeld($0.pendingID) } }

    /// Whether this panel ever handed out that question id (a typo is "unknown", a closed one is "no longer open").
    func knows(_ qid: String) -> Bool {
        guard let at = qid.range(of: "-q", options: .backwards), let n = Int(qid[at.upperBound...]) else { return false }
        return n >= 1 && n <= counters[String(qid[..<at.lowerBound]), default: 0]
    }

    func takeOutgoing() -> [Outgoing] { defer { outgoing = [] }; return outgoing }

    /// Decides for every open question; call it with the questions the user has not dismissed.
    func update(open: [PendingQuestion], routing: QuestionRouting) {
        let ids = Set(open.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for (id, entry) in entries {
            guard case .held(let since) = entry.state else { continue }
            if routing.mode == .user || routing.pmPane != entry.pane || now().timeIntervalSince(since) >= Self.wait { entries[id]?.state = .returned }
        }
        guard routing.mode != .user, let pane = routing.pmPane else { return }
        for pending in open where entries[pending.id] == nil && Self.relayable(pending, routing: routing) {
            let n = counters[pending.cardID, default: 0] + 1
            counters[pending.cardID] = n
            let qid = "\(pending.cardID)-q\(n)"
            entries[pending.id] = Entry(qid: qid, pendingID: pending.id, state: .held(since: now()), pane: pane, question: pending)
            outgoing.append(Outgoing(pane: pane, text: Self.line(qid: qid, pending)))
        }
    }

    /// A question the PM may answer: a menu or plain question of a card, not critical (mode 1 only counts the hard rules).
    static func relayable(_ p: PendingQuestion, routing: QuestionRouting) -> Bool {
        let q = p.question
        guard !p.isPM, !p.cardID.isEmpty, !q.terminalOnly, !q.isCall, q.kind == .choice || q.kind == .freeText else { return false }
        if q.kind == .choice, q.options.allSatisfy(\.isSpecial) { return false }
        return AutopilotRules.criticalReason(q, cardFiles: routing.cardFiles[p.cardID] ?? [], hardOnly: routing.mode == .pmAll) == nil
    }

    /// `QUESTION <ID>-q<n> <agent>: <question> · options: 1) … 2) … · recommended: <n>` on one line.
    static func line(qid: String, _ p: PendingQuestion) -> String {
        let q = p.question
        let ask = String(q.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(1200))
        let options = q.options.filter { !$0.isSpecial }
        let list = options.map { "\($0.number)) \(ReadableQuestion.stripRecommended($0.label))" }.joined(separator: " ")
        let best = options.first { ReadableQuestion.isRecommended($0.label) }.map { String($0.number) } ?? "none"
        return "QUESTION \(qid) \(p.agentLabel): \(ask)" + (options.isEmpty ? "" : " · options: \(list) · recommended: \(best)")
    }

    func release(_ entry: Entry) { entries[entry.pendingID]?.state = .returned }

    /// The QUESTION line for `qid` could not be written into the PM's pane: the question goes back to the user now (N380).
    /// Returns the entry that was released, nil when `qid` was not held.
    @discardableResult func undelivered(_ qid: String) -> Entry? {
        guard let entry = held(qid) else { return nil }
        release(entry)
        return entry
    }

    func markAnswered(_ entry: Entry, answer: String) {
        entries[entry.pendingID]?.state = .answered   // stays until the question leaves the screen, so it is not relayed twice
        let q = entry.question
        answered.insert(AnsweredByPM(id: entry.qid, agent: entry.question.agentLabel, cardID: q.cardID, question: ReadableQuestion(q).title, answer: answer, time: now()), at: 0)
        if answered.count > Self.answeredKept { answered.removeLast(answered.count - Self.answeredKept) }
    }
}
