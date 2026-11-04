import Foundation

/// What a running task and its agent are doing right now, as one tag. Computed from the card status, the agent's terminal state, the inbox
/// (questions for the user), the autopilot (the PM is deciding) and the card's Report.
enum TaskPhase: CaseIterable, Equatable {
    case starting, working, waitingForYou, pmHandling, finished, idle, blocked, inReview, needsFix

    enum Tone: Equatable { case orange, blue, green, grey, red, yellow, work }

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .working: return "Working"
        case .waitingForYou: return "Waiting for you"
        case .pmHandling: return "PM handling"
        case .finished: return "Finished"
        case .idle: return "Idle"
        case .blocked: return "Blocked"
        case .inReview: return "In review"
        case .needsFix: return "Needs fix"
        }
    }

    var help: String {
        switch self {
        case .starting: return "The agent was just started and has not begun its turn yet; it is reading its card."
        case .working: return "The agent is working on the task."
        case .waitingForYou: return "A question, permission or plan waits for your answer."
        case .pmHandling: return "The PM is deciding for the agent; nothing to do for you yet."
        case .finished: return "The agent ended its turn and wrote its Report. Next: Prepare review."
        case .idle: return "The agent ended its turn without a Report or a question. It may need a nudge."
        case .blocked: return "The agent is blocked, but the panel cannot read a question. Look at its terminal."
        case .inReview: return "The review packet is ready. Approve it or request a fix."
        case .needsFix: return "The review asked for a fix. The agent has to change the task."
        }
    }

    var tone: Tone {
        switch self {
        case .waitingForYou: return .orange
        case .pmHandling: return .blue
        case .finished: return .green
        case .working: return .work
        case .blocked: return .red
        case .inReview, .needsFix: return .yellow
        case .starting, .idle: return .grey
        }
    }

    static func of(_ input: TaskPhaseInput) -> TaskPhase? {
        let running: Bool
        switch input.status {
        case .doing, .needsFix, .blocked: running = true
        case .review: return .inReview
        default: return nil
        }
        guard running else { return nil }
        if input.pmHandling { return .pmHandling }
        if input.waiting > 0 { return .waitingForYou }
        if input.status == .blocked { return .blocked }
        let fallback: TaskPhase? = input.status == .needsFix ? .needsFix : nil
        guard let agent = input.agent else { return fallback ?? .idle }
        switch agent {
        case .working: return .working
        case .blocked: return fallback ?? .blocked
        case .idle where !input.turnBegun: return fallback ?? .starting
        case .idle, .done, .unknown:
            // A card that needs a fix is finished again once the agent ended a new turn and changed its Report.
            if let fallback { return input.reportChangedSinceFix && input.hasReport && input.quiet == 0 ? .finished : fallback }
            return input.hasReport && input.quiet == 0 ? .finished : .idle
        }
    }
}

struct TaskPhaseInput: Equatable {
    let status: TaskStatus
    /// The terminal state of the task's agent; nil when no agent runs in its worktree.
    let agent: AgentState?
    /// The agent has had a turn since it was started (it was seen working, or its transcript has a reply).
    let turnBegun: Bool
    let hasReport: Bool
    /// Questions waiting for the user (not the ones the PM takes) and dismissed ones the agent still shows.
    let waiting: Int
    let quiet: Int
    let pmHandling: Bool
    /// The card needs a fix and its Report is no longer the one it had when the fix was asked for (see `FixReportTracker`).
    var reportChangedSinceFix = false
}

/// Remembers the Report each needs-fix card had when the panel first saw it in that state, so a Report the agent rewrote after the fix
/// request can be told from the old one.
struct FixReportTracker {
    private var baseline: [String: String] = [:]

    private static func key(_ card: TaskCard) -> String { card.url.path }
    private static func report(_ card: TaskCard) -> String { (card.sections["Report"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Call on every card load: takes the baseline of a card that now needs a fix and forgets the cards that no longer do.
    mutating func note(_ cards: [TaskCard]) {
        var live: [String: String] = [:]
        for card in cards where card.status == .needsFix {
            live[Self.key(card)] = baseline[Self.key(card)] ?? Self.report(card)
        }
        baseline = live
    }

    func changed(_ card: TaskCard) -> Bool {
        guard let old = baseline[Self.key(card)] else { return false }
        return old != Self.report(card)
    }
}

/// Remembers which agent sessions have had a turn: right after a start the terminal reports `idle` until the agent reads its card, which is
/// not the same as an agent that finished.
struct TurnTracker {
    private var begunKeys: Set<String> = []

    private static func key(_ agent: AgentStatus) -> String { "\(agent.paneID)|\(agent.sessionID ?? "")" }

    /// Call on every poll. `hasReply` is asked only for an idle agent not yet known to have begun (it reads the transcript).
    mutating func note(_ agents: [AgentStatus], hasReply: (AgentStatus) -> Bool) {
        var live: Set<String> = []
        for agent in agents {
            let k = Self.key(agent)
            live.insert(k)
            if begunKeys.contains(k) { continue }
            if [.working, .blocked, .done].contains(agent.state) || (agent.state == .idle && hasReply(agent)) { begunKeys.insert(k) }
        }
        begunKeys = begunKeys.intersection(live)
    }

    func begun(_ agent: AgentStatus) -> Bool { begunKeys.contains(Self.key(agent)) }
}

extension TurnTracker {
    /// True when the agent's session file (Claude's or, for a Codex agent, Codex's) holds a reply of the agent.
    static func transcriptHasReply(_ agent: AgentStatus, tool: AgentTool = .claude, projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"), codexRoot: URL = CodexSessionReader.defaultRoot) -> Bool {
        guard let session = agent.sessionID, !session.isEmpty,
              var reader = SessionTranscript.make(tool: tool, cwd: agent.cwd, session: session, projectsRoot: projectsRoot, codexRoot: codexRoot) else { return false }
        _ = reader.poll()
        return reader.entries.contains { $0.kind == .agent }
    }
}
