import Foundation

/// Tells the PM session when a card changes phase, so the PM does not have to poll the cards. Remembers what each card last was;
/// a restart starts from what the PM was last told (`told`, kept by the panel per project); with nothing told yet only cards that need the PM
/// now are mentioned. Lines wait in `pending` until the PM can take them (idle, right session) and are sent as one message.
struct PMNotice {
    private var seen: [String: String] = [:]
    private var primed: Bool
    private(set) var pending: [String] = []
    /// What the PM was last told about each card; the panel keeps it across restarts. Moves up to the current state once its lines are delivered.
    private(set) var told: [String: String]?

    init(told: [String: String]? = nil) {
        self.told = told
        seen = told ?? [:]
        primed = told != nil
    }

    /// A line the card phases do not produce (a question that waited 30 min); it goes out with the next message.
    mutating func add(_ line: String) { pending.append(line) }

    mutating func observe(cards: [TaskCard], phase: (TaskCard) -> TaskPhase?) {
        // Cards not read yet: keep what is remembered rather than treating every card as new later.
        guard !cards.isEmpty else { return }
        var now: [String: String] = [:]
        for c in cards {
            let event: String?
            switch c.status {
            case .review: event = "review"
            case .needsFix: event = "needsFix"
            case .done: event = "done"
            case .awaitingStartApproval: event = primed ? nil : "awaitingStart"
            default:
                if phase(c) == .finished { event = Self.finishedEvent(c) }
                else if let old = seen[c.id], old.hasPrefix("finished") { event = nil; now[c.id] = old } // busy again: same Report is not news
                else { event = nil }
            }
            if let event { now[c.id] = event }
            guard let event, seen[c.id] != event else { continue }
            // First run, nothing remembered: only what needs the PM now.
            if !primed && !["review", "needsFix", "awaitingStart"].contains(event) { continue }
            pending.append(Self.line(c.id, event))
        }
        seen = now
        primed = true
        if pending.isEmpty { told = seen }
    }

    /// "finished" tied to the Report text, so only a changed Report is announced again (djb2: stable across restarts, unlike hashValue).
    private static func finishedEvent(_ c: TaskCard) -> String {
        let report = c.sections["Report"] ?? ""
        return "finished:\(report.utf8.reduce(5381) { $0 &* 33 &+ Int($1) })"
    }

    private static func line(_ id: String, _ event: String) -> String {
        switch event {
        case "review": return "\(id) is ready for review"
        case "needsFix": return "\(id) needs a fix"
        case "awaitingStart": return "\(id) waits for start approval"
        case "done": return "\(id) is done"
        default: return "\(id) finished its work (Report written)"
        }
    }

    /// Whether a title names a PM: "pm" as a word anywhere ("PM", "✳ pm", "◐ Tentacl PM …"); leading glyphs are ignored.
    static func isPMTitle(_ title: String) -> Bool {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("pm")
    }

    /// The PM session of a project among all running agents, never one that runs on a card (`pm-<task>` agents do):
    /// the session the user chose is valid wherever it runs; the title fallback only looks inside the project's repository (`repo`).
    static func pmAgent(in agents: [AgentStatus], cards: [TaskCard] = [], worktrees: URL? = nil, repo: String? = nil, chosenSession: String? = nil) -> AgentStatus? {
        let paths = worktrees.map { worktrees in Set(cards.compactMap { AgentInboxModel.worktreePath(of: $0, worktrees: worktrees) }) } ?? []
        let free = agents.filter { agent in
            !paths.contains { AgentInboxModel.runs(agent, inWorktreePath: $0) }
        }
        if let chosenSession, let found = free.first(where: { $0.sessionID == chosenSession }) { return found }
        let inside = repo.map { AgentPanel.agents(free, belongingToRepo: $0) } ?? free
        return inside.first { isPMTitle($0.title) }
    }

    /// Sends the waiting lines as one message when the PM is idle. Switched off, lines are dropped (never replayed when it is turned on).
    /// A failed send keeps them for the next poll.
    mutating func deliver(enabled: Bool, agents: [AgentStatus], cards: [TaskCard] = [], worktrees: URL? = nil, repo: String? = nil, chosenSession: String? = nil, send: (_ pane: String, _ session: String?, _ text: String) async throws -> Void) async {
        guard enabled else { pending = []; told = seen; return }
        guard !pending.isEmpty, let pm = Self.pmAgent(in: agents, cards: cards, worktrees: worktrees, repo: repo, chosenSession: chosenSession), pm.state == .idle || pm.state == .done else { return }
        let text = "Panel: " + pending.joined(separator: "; ") + "."
        do { try await send(pm.paneID, pm.sessionID, text); pending = []; told = seen } catch {}
    }
}

/// Lets one run of an async action at a time; a call that arrives while one is running is skipped (the running one already covers it).
@MainActor
final class TellGate {
    private var running = false
    func run(_ action: () async -> Void) async {
        guard !running else { return }
        running = true
        defer { running = false }
        await action()
    }
}
