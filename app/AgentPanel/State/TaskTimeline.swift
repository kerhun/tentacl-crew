import Foundation

struct TimelineEntry: Equatable, Identifiable {
    enum Kind: Equatable { case started, asked, answered, reviewPrepared, fixRequested, approved, closed, cardChanged, decision }
    let time: Date
    let kind: Kind
    /// For a decision: its title and the question with the answer.
    var decisionTitle: String? = nil
    var detail: String? = nil
    var id: String { "\(kind)-\(time.timeIntervalSince1970)-\(detail ?? "")" }
    var title: String {
        if let decisionTitle { return decisionTitle }
        return plainTitle
    }
    private var plainTitle: String {
        switch kind {
        case .started: "Agent started"
        case .asked: "Question asked"
        case .answered: "Question answered"
        case .reviewPrepared: "Review prepared"
        case .fixRequested: "Fix requested"
        case .approved: "Approved"
        case .closed: "Closed without merge"
        case .cardChanged: "Card last changed"
        case .decision: "Decision"
        }
    }
}

enum TaskTimeline {
    /// The steps of one card, oldest first, read from the action log lines that name it, and from the card file's last change.
    /// Lines tagged with another project are left out; older lines without a tag are matched by card id alone.
    static func build(card: TaskCard, events: [ActionLogEvent], decisions: [DecisionRecord] = []) -> [TimelineEntry] {
        var entries: [TimelineEntry] = events.filter { $0.concerns(project: card.project) }.compactMap { e in
            kind(of: e.text, cardID: card.id).map { TimelineEntry(time: e.time, kind: $0) }
        }
        entries += decisions.filter { $0.cardID == card.id }.map { d in
            let who = d.by == .pm ? "PM" : "You"
            let title: String
            switch d.result {
            case .answered: title = "\(who) answered"
            case .suggested: title = "PM suggested"
            case .escalated: title = "Escalated to you"
            }
            let detail = d.result == .escalated || d.answer.isEmpty ? d.question : "\(d.question) → \(d.answer)"
            return TimelineEntry(time: d.time, kind: .decision, decisionTitle: title, detail: detail)
        }
        entries.sort { $0.time < $1.time }
        if let modified = card.modified { entries.append(TimelineEntry(time: modified, kind: .cardChanged)) }
        return entries
    }

    private static func kind(of text: String, cardID: String) -> TimelineEntry.Kind? {
        let w = text.split(separator: " ").map(String.init)
        guard w.count >= 2 else { return nil }
        switch w[0] {
        case "start": return w[1] == cardID && w.count >= 3 && w[2].hasPrefix("agent=") ? .started : nil
        case "asked": return w[1] == cardID ? .asked : nil
        case "answered": return w[1] == cardID ? .answered : nil
        case "approved": return w[1] == cardID ? .approved : nil
        case "closed": return w[1] == cardID ? .closed : nil
        case "review": return w.count >= 5 && w[1] == "packet" && w[2] == "prepared" && w[4] == cardID ? .reviewPrepared : nil
        case "fix":
            // "fix request sent to PANE for ID" / "fix request (passed on) sent to PANE for ID"
            guard text.contains(" sent to "), w.count >= 3, w[1] == "request", w[w.count - 2] == "for", w.last == cardID else { return nil }
            return .fixRequested
        default: return nil
        }
    }
}

/// One section of a card as the Card tab shows it: the whole text, or the entries of a log-like section one by one.
struct CardOverviewSection: Equatable {
    let title: String
    let entries: [String]
}

enum CardOverview {
    static let titles = ["Goal", "Scope", "Acceptance criteria", "Dependencies", "Fix notes", "Decision"]

    static func sections(for card: TaskCard) -> [CardOverviewSection] {
        titles.map { t in
            let body = (card.sections[t] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { return CardOverviewSection(title: t, entries: []) }
            return CardOverviewSection(title: t, entries: t == "Fix notes" ? fixEntries(body) : [body])
        }
    }

    /// Entries start at a "### " heading when there are any, else they are the blank-line separated blocks.
    static func fixEntries(_ body: String) -> [String] {
        let parts: [String]
        if body.hasPrefix("### ") || body.contains("\n### ") {
            parts = ("\n" + body).components(separatedBy: "\n### ").dropFirst().map { "### " + $0 }
        } else {
            parts = body.components(separatedBy: "\n\n")
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
