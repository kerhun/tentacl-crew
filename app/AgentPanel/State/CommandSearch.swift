import Foundation

/// The ⌘K field's search (N134): cards, rail screens, projects and notes matching what is typed, then "Ask the PM". A pure function
/// of what the window already holds, so nothing is read from disk while the user types.
enum CommandSearch {
    /// The groups, in the order the list shows them.
    enum Kind: Int, Comparable {
        case card, screen, project, note, tour, askPM
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var heading: String? {
            switch self {
            case .card: "Cards"
            case .screen: "Screens"
            case .project: "Projects"
            case .note: "Notes"
            case .tour: "Tours"
            case .askPM: nil
            }
        }
    }

    enum Target: Equatable {
        case card(String)
        case screen(ShellScreen)
        case project(String)
        case note(UUID)
        case askPM(String)
        /// Tours (N311): start or resume one, or open the `?` popover.
        case tour(TutorialTourID)
        case allTours
    }

    struct Row: Identifiable, Equatable {
        let kind: Kind
        let id: String
        /// The card's id, shown on its own before the title.
        var badge: String?
        let title: String
        /// The card's status, "current" for the selected project, "done" for a checked note.
        var detail: String?
        /// A card's status, for its dot.
        var status: TaskStatus?
        let target: Target
        /// Why the row cannot run (Ask the PM without a PM); nil: it can.
        var disabledReason: String?
    }

    struct Project: Equatable { let id: String; let name: String }
    struct Note: Equatable { let id: UUID; let text: String; var done = false }
    /// The tours ⌘K can open: the one of the screen shown, and the one in progress with its step.
    struct Tours: Equatable { var here: TutorialTourID?; var screen = ""; var resume: (id: TutorialTourID, step: Int, of: Int)?
        static func == (a: Tours, b: Tours) -> Bool { a.here == b.here && a.screen == b.screen && a.resume?.id == b.resume?.id && a.resume?.step == b.resume?.step }
    }

    /// The most rows the list shows, "Ask the PM" included.
    static let maxRows = 8

    /// `pmMissing`: why the selected project's PM cannot be asked (nil: it can).
    static func rows(query: String, cards: [TaskCard], screens: [ShellScreen] = ShellScreen.railOrder, projects: [Project], selectedProject: String? = nil,
                     notes: [Note], tours: Tours? = nil, pmMissing: String?) -> [Row] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var found: [(rank: Int, order: Int, row: Row)] = []
        let sortedCards = cards.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        for (i, card) in sortedCards.enumerated() {
            let title = AgentSummary.plainTitle(card.title, id: card.id)
            guard let r = rank(text, id: card.id, title: title) else { continue }
            found.append((r, i, Row(kind: .card, id: "card:" + card.id, badge: card.id, title: title, detail: card.status.label, status: card.status, target: .card(card.id))))
        }
        for (i, screen) in screens.enumerated() {
            guard let r = rank(text, title: screen.railTitle) else { continue }
            found.append((r, i, Row(kind: .screen, id: "screen:" + screen.rawValue, title: screen.railTitle, target: .screen(screen))))
        }
        for (i, project) in projects.enumerated() {
            guard let r = rank(text, title: project.name) else { continue }
            found.append((r, i, Row(kind: .project, id: "project:" + project.id, title: project.name, detail: project.id == selectedProject ? "current" : nil,
                                    target: .project(project.id))))
        }
        for (i, note) in notes.enumerated() {
            guard let r = rank(text, title: note.text) else { continue }
            found.append((r, i, Row(kind: .note, id: "note:" + note.id.uuidString, title: note.text, detail: note.done ? "done" : nil, target: .note(note.id))))
        }
        if let tours {
            // "tour", "help" or "tutorial" (or the start of one) lists them all; otherwise a row matches by its title.
            let keyword = fold(text).count >= 2 && ["tour", "tours", "help", "tutorial"].contains { $0.hasPrefix(fold(text)) }
            var list: [Row] = []
            if let here = tours.here {
                list.append(Row(kind: .tour, id: "tour:here", title: "Tour this screen", detail: tours.screen, target: .tour(here)))
            }
            if let r = tours.resume {
                list.append(Row(kind: .tour, id: "tour:resume", title: "Resume \(r.id.title) tour", detail: "step \(r.step) of \(r.of)", target: .tour(r.id)))
            }
            list.append(Row(kind: .tour, id: "tour:all", title: "All tours…", target: .allTours))
            for (i, row) in list.enumerated() {
                guard let r = keyword ? 1 : rank(text, title: row.title) else { continue }
                found.append((r, i, row))
            }
        }
        // The best matches across the kinds, then shown grouped by kind.
        let best = found.sorted { ($0.rank, $0.row.kind, $0.order) < ($1.rank, $1.row.kind, $1.order) }.prefix(maxRows - 1)
        let grouped = best.sorted { ($0.row.kind, $0.rank, $0.order) < ($1.row.kind, $1.rank, $1.order) }.map(\.row)
        return grouped + [Row(kind: .askPM, id: "ask", title: "Ask the PM: \(text)", target: .askPM(text), disabledReason: pmMissing)]
    }

    /// 0: the id is what was typed (or the name, for a thing without an id); 1: the id or the title starts with it; 2: every typed word is in
    /// the id or the title; nil: no match. Case and accents do not count.
    static func rank(_ query: String, id: String? = nil, title: String) -> Int? {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines)), t = fold(title), i = id.map(fold)
        guard !q.isEmpty else { return nil }
        if let i { if i == q { return 0 } } else if t == q { return 0 }
        if i?.hasPrefix(q) == true || t.hasPrefix(q) { return 1 }
        let haystack = [i, t].compactMap { $0 }.joined(separator: " ")
        let words = q.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { haystack.contains($0) } ? 2 : nil
    }

    /// ↑/↓ in the list: the highlight stops at the first and the last row.
    static func moved(_ selection: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selection + step, 0), count - 1)
    }

    /// What "Ask the PM" says when the selected project has no PM to ask.
    static func pmMissingReason(project: String?) -> String {
        project.map { "No PM is running in \($0). Start one or choose one on the Dashboard." } ?? "Choose a project first."
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}
