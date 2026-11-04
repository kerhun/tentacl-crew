import Foundation
import Observation

/// The floating question card under the top bar's waiting pill (N371, a card since N376): while an agent's question waits for the
/// user, every screen says so without moving anything. The Dashboard hides it while its Waiting for you tile is on the layout (the
/// row is there). Later hides it for 5 min, Esc or a pill click closes it; a new question brings it back, a pill click opens it
/// again. Nothing here answers: Answer opens the question window, "Let the PM decide" is one explicit click.
enum BlockedBanner {
    /// How long Later hides the card.
    static let snooze: TimeInterval = 5 * 60
    /// From this wait on the card offers "Let the PM decide" when the PM has a suggestion (escalation step).
    static let escalateAfter: TimeInterval = 15 * 60
    /// The card's width and its gap under the top bar.
    static let cardWidth: CGFloat = 410
    static let cardGap: CGFloat = 10

    struct Content: Equatable {
        /// The oldest open question: Answer opens it.
        let questionID: String
        /// "Question · ui_dev · N376 · 4 min": the Waiting for you row's heading.
        let heading: String
        /// The question for two lines.
        let question: String
        /// The whole question (the tooltip).
        let fullQuestion: String
        /// How many more questions wait ("+2 more"), 0 for none.
        let more: Int
        /// "Let the PM decide (it suggests 2)" from 15 min on, only with a PM suggestion.
        let pmDecide: String?
        /// The questions the PM is answering (N380), muted under the question; alone when the pill opened the card for them.
        var held: [HeldQuestion] = []
        /// False when the card shows only questions with the PM (no Answer, Later, glow).
        var hasQuestion = true

        var moreText: String? { more > 0 ? "+\(more) more" : nil }

        /// The card opened by the pill for the questions the PM has.
        static func heldOnly(_ held: [HeldQuestion]) -> Content {
            Content(questionID: "held", heading: "With the PM", question: "", fullQuestion: "", more: 0, pmDecide: nil, held: held, hasQuestion: false)
        }
    }

    /// Why the card is not shown while a question waits (the model's state, passed in so the rules stay pure).
    struct Hidden: Equatable {
        /// Later: until when.
        var until: Date?
        /// Esc or a pill click closed it.
        var closed = false
        /// The questions open when it was hidden: one not among them brings the card back.
        var known: Set<String> = []
        /// A pill click opened it: shown even on the Dashboard with its tile, and over Later.
        var opened = false
    }

    /// The questions oldest first (a question without a first-seen time counts as just asked; ties keep their order).
    static func oldestFirst(_ questions: [PendingQuestion], askedAt: [String: Date], now: Date) -> [PendingQuestion] {
        questions.enumerated().sorted { a, b in
            let ta = askedAt[a.element.id] ?? now, tb = askedAt[b.element.id] ?? now
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
    }

    /// Whether the card shows: a question waits and nothing hides it (the Dashboard's tile, Later, Esc), unless a question came that
    /// was not open when it was hidden, or the pill opened it.
    static func shown(questionIDs: [String], now: Date, onDashboard: Bool, waitingTileShown: Bool, hidden: Hidden) -> Bool {
        guard !questionIDs.isEmpty else { return false }
        if hidden.opened { return true }
        if onDashboard && waitingTileShown { return false }
        let fresh = !Set(questionIDs).isSubset(of: hidden.known)
        if fresh { return true }
        if hidden.closed { return false }
        if let until = hidden.until, now < until { return false }
        return true
    }

    /// What the card shows, or nil when it is hidden.
    static func content(questions: [PendingQuestion], askedAt: [String: Date], now: Date, onDashboard: Bool, waitingTileShown: Bool,
                        hidden: Hidden = Hidden(), role: (PendingQuestion) -> String? = { _ in nil },
                        suggestion: (PendingQuestion) -> PMSuggestion?, held: [HeldQuestion] = []) -> Content? {
        // N380: questions the PM has never bring the card up on their own (no noise); the pill opens it for them.
        if questions.isEmpty { return hidden.opened && !held.isEmpty ? .heldOnly(held) : nil }
        guard shown(questionIDs: questions.map(\.id), now: now, onDashboard: onDashboard, waitingTileShown: waitingTileShown, hidden: hidden),
              let q = oldestFirst(questions, askedAt: askedAt, now: now).first else { return nil }
        let waited = max(now.timeIntervalSince(askedAt[q.id] ?? now), 0)
        let pm: String? = waited >= escalateAfter ? suggestion(q).map(pmDecideTitle) : nil
        let row = WaitingQuestionRowText.make(q, role: role(q), askedAt: askedAt[q.id], now: now)
        return Content(questionID: q.id, heading: row.heading, question: oneLine(q.question, limit: 240), fullQuestion: fullText(q.question),
                       more: questions.count - 1, pmDecide: pm, held: held)
    }

    /// Esc closes the card only when nothing else wants it: no text field or terminal has the keys and no sheet is open.
    static func escCloses(cardShown: Bool, responderTakesText: Bool, sheetOpen: Bool) -> Bool { cardShown && !responderTakesText && !sheetOpen }

    static func pmDecideTitle(_ s: PMSuggestion) -> String {
        if let n = s.option { return "Let the PM decide (it suggests \(n))" }
        let text = s.summary.replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? "Let the PM decide" : "Let the PM decide (it suggests “\(String(text.prefix(30)))”)"
    }

    static func oneLine(_ q: AgentQuestion, limit: Int = 120) -> String {
        let raw = joined(q.title.isEmpty ? q.text : q.title)
        return raw.count > limit ? String(raw.prefix(limit - 1)) + "…" : raw
    }

    /// The title and the text, for the tooltip.
    static func fullText(_ q: AgentQuestion) -> String {
        [q.title, q.text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func joined(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "under 1 min" }
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    /// The top bar's pill: "1 agent waiting on you", "3 agents waiting on you"; nil for none.
    static func pillTitle(_ count: Int) -> String? { count > 0 ? "\(count) agent\(count == 1 ? "" : "s") waiting on you" : nil }

    /// With the questions the PM is answering (N380): "2 agents waiting on you · 1 with PM", "1 with PM"; nil when neither.
    static func pillTitle(_ count: Int, withPM: Int) -> String? {
        let parts = [pillTitle(count), HeldQuestion.pillText(withPM)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The card's state: Later, closed, opened by the pill. The clock is passed in, so a test moves it.
@MainActor @Observable
final class BlockedBannerModel {
    private(set) var hidden = BlockedBanner.Hidden()
    @ObservationIgnored let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    var hiddenUntil: Date? { hidden.until }

    /// Later: hidden for 5 min, or until a new question.
    func later(open ids: [String]) { hidden = BlockedBanner.Hidden(until: clock().addingTimeInterval(BlockedBanner.snooze), known: Set(ids)) }

    /// Esc or the pill on an open card: hidden until a new question (or the pill again).
    func close(open ids: [String]) { hidden = BlockedBanner.Hidden(closed: true, known: Set(ids)) }

    /// The pill: closes an open card, opens a hidden one.
    func togglePill(shown: Bool, open ids: [String]) { if shown { close(open: ids) } else { hidden = BlockedBanner.Hidden(opened: true) } }

    func content(questions: [PendingQuestion], askedAt: [String: Date], onDashboard: Bool, waitingTileShown: Bool,
                 role: (PendingQuestion) -> String? = { _ in nil }, suggestion: (PendingQuestion) -> PMSuggestion?, held: [HeldQuestion] = []) -> BlockedBanner.Content? {
        BlockedBanner.content(questions: questions, askedAt: askedAt, now: clock(), onDashboard: onDashboard, waitingTileShown: waitingTileShown,
                              hidden: hidden, role: role, suggestion: suggestion, held: held)
    }
}
