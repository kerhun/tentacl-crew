import Foundation

struct TaskSection: Identifiable {
    let title: String
    let rows: [CardLoadResult]
    var id: String { title }
}

/// Groups cards into the sections shown in the task list. Pure and testable.
enum TaskGrouping {
    static func sections(from results: [CardLoadResult], finishedSort: FinishedSort = .default, calendar: Calendar = .current) -> [TaskSection] {
        func cards(where predicate: (TaskStatus) -> Bool) -> [CardLoadResult] {
            results.filter { if case .card(let c) = $0 { return predicate(c.status) } else { return false } }
        }
        let unreadable = results.filter { if case .unreadable = $0 { return true } else { return false } }
        let sections: [(String, [CardLoadResult])] = [
            ("Needs your decision", cards { $0 == .review || $0 == .awaitingStartApproval }),
            ("Doing", cards { $0 == .doing || $0 == .needsFix }),
            ("Backlog", cards { $0 == .todo }),
            ("Blocked", cards { $0 == .blocked }),
            ("Other", cards { if case .unknown = $0 { return true } else { return false } }),
            ("Done", sortFinished(cards { $0 == .done }, finishedSort, calendar: calendar)),
            ("Cancelled", sortFinished(cards { $0 == .cancelled }, finishedSort, calendar: calendar)),
            ("Unreadable cards", unreadable),
        ]
        return sections.filter { !$0.1.isEmpty }.map { TaskSection(title: $0.0, rows: $0.1) }
    }
}


/// How the Done and Cancelled sections are ordered; kept per project.
struct FinishedSort: Equatable {
    enum Key: String, CaseIterable {
        case finished, created, updated, id
        var label: String {
            switch self {
            case .finished: return "Finished"
            case .created: return "Created"
            case .updated: return "Last updated"
            case .id: return "ID"
            }
        }
    }

    var key: Key
    /// Newest first; for the ID key: descending.
    var newestFirst: Bool

    static let `default` = FinishedSort(key: .finished, newestFirst: true)

    /// The label of the two directions for this key.
    var directionLabels: (first: String, second: String) { key == .id ? ("Descending", "Ascending") : ("Newest first", "Oldest first") }

    private static func storageKey(_ project: String) -> String { "finishedSort.\(project)" }

    static func load(_ defaults: UserDefaults, project: String) -> FinishedSort {
        guard let raw = defaults.string(forKey: storageKey(project)) else { return .default }
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 2, let key = Key(rawValue: parts[0]) else { return .default }
        return FinishedSort(key: key, newestFirst: parts[1] == "newest")
    }

    func save(_ defaults: UserDefaults, project: String) {
        defaults.set("\(key.rawValue)|\(newestFirst ? "newest" : "oldest")", forKey: Self.storageKey(project))
    }
}

extension TaskGrouping {
    /// The Decision section's date, with its time when it has one (midnight otherwise); the file's modification date when it records none.
    static func finishedDate(_ card: TaskCard, calendar: Calendar = .current) -> Date? {
        AgentTagInfo.decisionDateTime(card, calendar: calendar) ?? card.modified
    }

    /// The date a finished row shows in its time column: the one that sorts it (finished, created), else the last update.
    static func rowDate(_ card: TaskCard, _ sort: FinishedSort, calendar: Calendar = .current) -> Date? {
        switch sort.key {
        case .finished: return finishedDate(card, calendar: calendar)
        case .created: return card.created
        case .updated, .id: return card.modified
        }
    }

    /// Orders finished cards by the chosen key; ties and cards without a date fall back to the id (undated cards last).
    static func sortFinished(_ rows: [CardLoadResult], _ sort: FinishedSort, calendar: Calendar = .current) -> [CardLoadResult] {
        func card(_ r: CardLoadResult) -> TaskCard? { if case .card(let c) = r { return c } else { return nil } }
        func byID(_ a: TaskCard, _ b: TaskCard) -> Bool { a.id.localizedStandardCompare(b.id) == .orderedAscending }
        // The sort date (a regex and a date parse per card) is worked out once per card, not in every comparison.
        let dates: [String: Date?] = sort.key == .id ? [:] : Dictionary(rows.compactMap(card).map { ($0.id, rowDate($0, sort, calendar: calendar)) }, uniquingKeysWith: { a, _ in a })
        return rows.sorted { l, r in
            guard let a = card(l), let b = card(r) else { return card(l) != nil }
            if sort.key == .id {
                let order = a.id.localizedStandardCompare(b.id)
                return sort.newestFirst ? order == .orderedDescending : order == .orderedAscending
            }
            let da = dates[a.id] ?? nil, db = dates[b.id] ?? nil
            switch (da, db) {
            case (nil, nil): return byID(a, b)
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                if x == y { return byID(a, b) }
                return sort.newestFirst ? x > y : x < y
            }
        }
    }
}

/// The three views of the task list (N135); kept per project like `FinishedSort`.
enum TaskListMode: String, CaseIterable {
    case byRound, byStatus, done

    var label: String {
        switch self {
        case .byRound: return "By round"
        case .byStatus: return "By status"
        case .done: return "Done"
        }
    }

    private static func storageKey(_ project: String) -> String { "taskListMode.\(project)" }

    static func load(_ defaults: UserDefaults, project: String) -> TaskListMode {
        defaults.string(forKey: storageKey(project)).flatMap(TaskListMode.init(rawValue:)) ?? .byRound
    }

    func save(_ defaults: UserDefaults, project: String) { defaults.set(rawValue, forKey: Self.storageKey(project)) }
}

/// One segment of a round's progress bar: one per card that counts (cancelled cards leave it, as in `PlanReader.progress`).
enum SegmentTone: Equatable { case done, doing, needsYou, todo }

/// A group of the "By round" list: a round of plan.json, or the open cards in no round.
struct RoundGroup: Identifiable, Equatable {
    static let notInARound = "Not in a round"

    let name: String
    let inPlan: Bool
    let cards: [TaskCard]
    let segments: [SegmentTone]
    let done: Int
    let total: Int
    var id: String { (inPlan ? "round:" : "rest:") + name }
    /// "3 of 4 merged" for a round; the number of cards for the rest.
    var progressText: String { inPlan ? "\(done) of \(total) merged" : "\(cards.count)" }
}

/// The short state at the right of a one-line row.
struct RowState: Equatable {
    enum Tone: Equatable { case ask, wait, normal, quiet, problem }
    let text: String
    let tone: Tone
}

extension TaskGrouping {
    /// A card that waits for the user: a review, a start to approve, or a question (`needsYou`, from the inbox).
    static func defaultNeedsYou(_ card: TaskCard) -> Bool { card.status == .review || card.status == .awaitingStartApproval }

    static func segment(_ card: TaskCard, needsYou: Bool) -> SegmentTone {
        if card.status == .done { return .done }
        if needsYou || defaultNeedsYou(card) { return .needsYou }
        switch card.status {
        case .doing, .needsFix, .blocked: return .doing
        default: return .todo
        }
    }

    /// Rounds in plan order, unfinished ones first (`open`), then "Not in a round" for the open cards in no round. A round whose counted
    /// cards are all done goes to `finished`. A card in two rounds belongs to the first; ids the panel does not know are left out.
    static func rounds(cards: [TaskCard], plan: PlanFile?, needsYou: (TaskCard) -> Bool = { _ in false }) -> (open: [RoundGroup], finished: [RoundGroup]) {
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var placed: Set<String> = []
        var open: [RoundGroup] = [], finished: [RoundGroup] = []
        for round in plan?.rounds ?? [] {
            let members = round.cards.compactMap { id -> TaskCard? in
                guard let c = byID[id], !placed.contains(id) else { return nil }
                placed.insert(id)
                return c
            }
            guard !members.isEmpty else { continue }
            let live = members.filter { $0.status != .cancelled }
            let done = live.filter { $0.status == .done }.count
            let group = RoundGroup(name: round.name, inPlan: true, cards: members, segments: live.map { segment($0, needsYou: needsYou($0)) },
                                   done: done, total: live.count)
            if done == live.count { finished.append(group) } else { open.append(group) }
        }
        let rest = cards.filter { !placed.contains($0.id) && $0.status != .done && $0.status != .cancelled }
        if !rest.isEmpty {
            open.append(RoundGroup(name: RoundGroup.notInARound, inPlan: false, cards: rest, segments: rest.map { segment($0, needsYou: needsYou($0)) },
                                   done: 0, total: rest.count))
        }
        return (open, finished)
    }

    /// The Done tab (N181): each finished round, newest (last in the plan) first, with its cards in plan order; then "Not in a round" for
    /// the done and cancelled cards that are in no round of the plan, in the Done sort. A done card of an unfinished round stays under By round.
    /// `matching` (a search) keeps only those cards and drops the groups left empty; whether a round is finished is judged on all its cards.
    static func doneGroups(cards: [TaskCard], plan: PlanFile?, finishedSort: FinishedSort = .default, matching: Set<String>? = nil,
                           calendar: Calendar = .current) -> [RoundGroup] {
        let inRound = Set(plan?.rounds.flatMap(\.cards) ?? [])
        let rest = cards.filter { !inRound.contains($0.id) && ($0.status == .done || $0.status == .cancelled) }
        let sorted = sortFinished(rest.map { .card($0) }, finishedSort, calendar: calendar).compactMap { if case .card(let c) = $0 { c } else { nil } }
        var groups = Array(rounds(cards: cards, plan: plan).finished.reversed())
        if !sorted.isEmpty { groups.append(RoundGroup(name: RoundGroup.notInARound, inPlan: false, cards: sorted, segments: [], done: 0, total: sorted.count)) }
        guard let matching else { return groups }
        return groups.compactMap { g in
            let kept = g.cards.filter { matching.contains($0.id) }
            if kept.isEmpty { return nil }
            return RoundGroup(name: g.name, inPlan: g.inPlan, cards: kept, segments: g.segments, done: g.done, total: g.total)
        }
    }

    /// The Done groups shown open: the first (newest) one unless the user closed it, another one when the user opened it (`toggled`
    /// holds the groups the user flipped). A search opens every group: the groups then hold only matches.
    static func openDoneGroups(_ groups: [RoundGroup], toggled: Set<String>, searching: Bool) -> Set<String> {
        if searching { return Set(groups.map(\.id)) }
        return Set(groups.enumerated().filter { ($0.offset == 0) != toggled.contains($0.element.id) }.map(\.element.id))
    }

    /// Card ids of the open Done groups in the order the list shows them, for the arrow keys.
    static func visibleDoneCardIDs(_ groups: [RoundGroup], open: Set<String>) -> [String] {
        groups.filter { open.contains($0.id) }.flatMap(\.cards).map(\.id)
    }

    /// "review", "doing 1h", "waits N133", "your call": what a one-line row says at its right. A finished card shows when it finished
    /// ("14:32", "Oct 17"), or the date its Done sort key names; the version stays in the card's detail (N139).
    static func rowState(_ card: TaskCard, phase: TaskPhase?, dependency: DependencyState, startedAt: Date?, now: Date,
                         finishedSort: FinishedSort = .default, calendar: Calendar = .current) -> RowState {
        if phase == .waitingForYou { return RowState(text: "your call", tone: .wait) }
        switch card.status {
        case .review: return RowState(text: "review", tone: .ask)
        case .awaitingStartApproval: return RowState(text: "your call", tone: .wait)
        case .doing:
            guard let startedAt else { return RowState(text: "doing", tone: .normal) }
            return RowState(text: "doing \(shortDuration(now.timeIntervalSince(startedAt)))", tone: .normal)
        case .needsFix: return RowState(text: "fixing", tone: .normal)
        case .blocked: return RowState(text: "blocked", tone: .problem)
        case .todo:
            switch dependency {
            case .waiting(let ids): return RowState(text: ids.first.map { "waits \($0)" } ?? "waits", tone: .wait)
            case .problem: return RowState(text: "check deps", tone: .problem)
            default: return RowState(text: "todo", tone: .quiet)
            }
        case .done, .cancelled:
            let date = rowDate(card, finishedSort, calendar: calendar)
            return RowState(text: date.map { finishTimeText($0, now: now, calendar: calendar) } ?? (card.status == .done ? "merged" : "cancelled"), tone: .quiet)
        case .unknown(let raw): return RowState(text: raw, tone: .quiet)
        }
    }

    /// "14:32" today, "Oct 17" another day this year, "Oct 17, 2025" another year.
    static func finishTimeText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { f.dateFormat = "HH:mm" }
        else { f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d, yyyy" }
        return f.string(from: date)
    }

    /// The title in a list row, without a leading "N123 · ": the id has its own column.
    static func rowTitle(_ card: TaskCard) -> String { AgentSummary.plainTitle(card.title, id: card.id) }

    /// "48m", "1h", "3d": whole units, for a narrow column.
    static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }
}
