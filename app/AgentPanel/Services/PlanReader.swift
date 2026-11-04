import Foundation

/// One round of the PM's plan, as written in `plan.json`.
struct PlanRound: Equatable, Identifiable {
    let name: String
    let cards: [String]
    let reason: String
    /// Free text from the PM; "waiting" means the round waits for the user to start it.
    let status: String
    var id: String { name }
}

/// The PM's plan: its rounds and the questions it needs the user to answer.
struct PlanFile: Equatable {
    var rounds: [PlanRound]
    var questions: [String]
}

enum PlanLoad: Equatable {
    case missing
    case broken(String)
    case plan(PlanFile)
}

/// Reads `<data folder>/plan.json` (format in the README). Never throws: a missing or broken file is a state to show.
enum PlanReader {
    static let fileName = "plan.json"

    static func load(dataDir: URL) -> PlanLoad {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent(fileName)) else { return .missing }
        return parse(data)
    }

    static func parse(_ data: Data) -> PlanLoad {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .broken("not valid JSON") }
        guard let root = object as? [String: Any] else { return .broken("the top level must be an object") }
        var rounds: [PlanRound] = []
        if let raw = root["rounds"] {
            guard let list = raw as? [Any] else { return .broken("\"rounds\" must be a list") }
            rounds = list.compactMap { item in
                guard let r = item as? [String: Any], let name = r["name"] as? String, !name.isEmpty else { return nil }
                return PlanRound(name: name, cards: (r["cards"] as? [Any])?.compactMap { $0 as? String } ?? [],
                                 reason: r["reason"] as? String ?? "", status: r["status"] as? String ?? "")
            }
        }
        let questions = (root["questions"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        return .plan(PlanFile(rounds: rounds, questions: questions))
    }

    /// Finished cards of the round out of its cards; cancelled cards leave the total, a card the panel does not know counts as not done.
    static func progress(of round: PlanRound, cards: [TaskCard]) -> (done: Int, total: Int) {
        let status = Dictionary(cards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        let live = round.cards.filter { status[$0] != .cancelled }
        return (live.filter { status[$0] == .done }.count, live.count)
    }

    /// What in the plan needs the user: rounds waiting to start, then the PM's open questions.
    static func waiting(in plan: PlanFile) -> [String] {
        plan.rounds.filter { $0.status.lowercased() == "waiting" }.map { "Round \($0.name) is waiting for you to start it." } + plan.questions
    }
}

/// The Plan screen's sections (N223): what needs the user, the running rounds, the next one, the later ones and the finished ones.
struct PlanGroups: Equatable {
    /// The round waiting for "Approve plan & start round" (`RoundModel.waitingRound`).
    var waiting: PlanRound?
    var questions: [String] = []
    /// Rounds with a started card that is not finished yet, or that the PM marks running; in plan order.
    var now: [PlanRound] = []
    /// The waiting round, else the first planned round with cards that has not started.
    var next: PlanRound?
    /// Rounds marked `later`, rounds with no cards, and planned rounds after `next`; in plan order.
    var later: [PlanRound] = []
    /// Finished rounds, newest first (plan.json lists them oldest first).
    var history: [PlanRound] = []
    /// The cards of the finished rounds, cancelled ones left out.
    var historyCards = 0

    var needsYouCount: Int { (waiting == nil ? 0 : 1) + questions.count }

    /// How many history rows show before "Show all".
    static let historyShown = 4

    static func group(_ plan: PlanFile, cards: [TaskCard], waiting: PlanRound?) -> PlanGroups {
        let status = Dictionary(cards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        var g = PlanGroups(waiting: waiting, questions: plan.questions)
        var upcoming: [PlanRound] = []
        for round in plan.rounds {
            let mark = round.status.lowercased()
            let live = round.cards.filter { status[$0] != .cancelled }
            let finished = !round.cards.isEmpty && live.allSatisfy { status[$0] == .done }
            let started = live.contains { s in status[s].map { ![.todo, .awaitingStartApproval].contains($0) && !$0.isUnknown } ?? false }
            if finished || (round.cards.isEmpty && mark == "done") { g.history.insert(round, at: 0); g.historyCards += live.count }
            else if started || mark == "running" { g.now.append(round) }
            else if round.cards.isEmpty || mark == "later" { g.later.append(round) }
            else { upcoming.append(round) }
        }
        if let waiting, let i = upcoming.firstIndex(of: waiting) { g.next = upcoming.remove(at: i) }
        else if !upcoming.isEmpty { g.next = upcoming.removeFirst() }
        // Planned rounds after the next one join the later ones, keeping plan order.
        let order = Dictionary(plan.rounds.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        g.later = (g.later + upcoming).sorted { order[$0.name, default: 0] < order[$1.name, default: 0] }
        return g
    }
}

private extension TaskStatus {
    var isUnknown: Bool { if case .unknown = self { true } else { false } }
}

/// What the action log knows about a plan's cards (N223): when each first started and when it was last merged.
struct PlanTimes: Equatable {
    var started: [String: Date] = [:]
    var merged: [String: Date] = [:]

    /// Reads "start ID agent=…" and "merged ID SHA …" / "approved ID …" lines; only `ids` are kept.
    init(events: [ActionLogEvent] = [], ids: Set<String> = []) {
        for e in events {
            let w = e.text.split(separator: " ", maxSplits: 2)
            guard w.count >= 2 else { continue }
            let id = String(w[1])
            guard ids.contains(id) else { continue }
            switch w[0] {
            case "start" where w.count == 3 && w[2].hasPrefix("agent="): if started[id] == nil || e.time < started[id]! { started[id] = e.time }
            case "merged", "approved": if merged[id] == nil || e.time > merged[id]! { merged[id] = e.time }
            default: break
            }
        }
    }

    /// The first start among the round's cards.
    func started(_ round: PlanRound) -> Date? { round.cards.compactMap { started[$0] }.min() }
    /// The last merge among the round's cards.
    func lastMerge(_ round: PlanRound) -> Date? { round.cards.compactMap { merged[$0] }.max() }
}

/// The project's goal: one text the user writes, kept in `<data folder>/goal.md`.
enum GoalStore {
    static let fileName = "goal.md"

    static func read(dataDir: URL) -> String {
        ((try? String(contentsOf: dataDir.appendingPathComponent(fileName), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ goal: String, dataDir: URL) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try goal.trimmingCharacters(in: .whitespacesAndNewlines).write(to: dataDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    static func pmMessage(goal: String) -> String {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The project goal was cleared in the panel (goal.md)."
            : "The project goal changed in the panel (goal.md). New goal: \(text)\nPlan against it, and update plan.json if the rounds change."
    }

    /// The Plan screen's "Save and ask the PM to plan" when there is no plan yet (N223).
    static func planRequest(goal: String) -> String {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return "The project has no plan yet. Goal (goal.md): \(text)\nWrite plan.json in the project's data folder (format in the README): rounds of task cards, each waiting for my approval before it starts."
    }
}

/// The PM's project summary, `<data folder>/summary.md`, and when it was written.
struct ProjectSummary: Equatable {
    let text: String
    let modified: Date?
}

/// Reads `<data folder>/summary.md`. Never throws: a missing or blank file is no summary.
enum SummaryReader {
    static let fileName = "summary.md"
    static let emptyText = "The PM writes a summary when the project is added."

    static func load(dataDir: URL) -> ProjectSummary? {
        let url = dataDir.appendingPathComponent(fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : ProjectSummary(text: text, modified: modified(url))
    }

    /// The summary again, read only when the file's date differs from the previous one's.
    static func reload(dataDir: URL, previous: ProjectSummary?) -> ProjectSummary? {
        let url = dataDir.appendingPathComponent(fileName)
        guard let date = modified(url) else { return nil }
        if let previous, previous.modified == date { return previous }
        return load(dataDir: dataDir)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
