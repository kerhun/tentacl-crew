import Foundation

/// The six steps of a task, as the agent card's bar shows them.
enum TaskStep: Int, CaseIterable, Equatable {
    case start, work, report, packet, review, merge

    var label: String {
        switch self {
        case .start: "start"
        case .work: "work"
        case .report: "report"
        case .packet: "packet"
        case .review: "review"
        case .merge: "merge"
        }
    }
}

/// Where a running task is on the step bar and what its current step is doing.
struct StepProgress: Equatable {
    enum State: Equatable { case working, fixing, waiting }
    let current: TaskStep
    let state: State

    /// From the card status and its phase (see `TaskPhase`); nil for a card that is not running.
    static func of(status: TaskStatus, phase: TaskPhase?) -> StepProgress? {
        guard let phase else { return nil }
        let waits = [TaskPhase.waitingForYou, .pmHandling, .blocked, .idle, .finished].contains(phase)
        switch status {
        case .review: return StepProgress(current: .review, state: .waiting)
        // A fix request comes back from the packet or the review: the agent reworks at the packet step.
        case .needsFix: return StepProgress(current: .packet, state: waits ? .waiting : .fixing)
        case .doing, .blocked:
            switch phase {
            case .starting: return StepProgress(current: .start, state: .working)
            case .finished: return StepProgress(current: .report, state: .waiting)
            default: return StepProgress(current: .work, state: waits ? .waiting : .working)
            }
        default: return nil
        }
    }
}

/// What the stopped-agent rule looks at for one running task.
struct StoppedInput: Equatable {
    let status: TaskStatus
    let agent: AgentState
    let hasReport: Bool
    let reportChangedSinceFix: Bool
    /// Questions waiting for the user, including dismissed ones still on screen.
    let waiting: Int
    let pmHandling: Bool

    /// The agent ended its turn before the task was finished: the card is doing (or needs a fix), the agent is idle or done, nothing
    /// waits on a menu or the PM, and the Report is empty (or unchanged since the fix request). `StoppedTracker` adds the 5 minutes.
    static func looksStopped(_ i: StoppedInput) -> Bool {
        guard i.status == .doing || i.status == .needsFix, i.agent == .idle || i.agent == .done, i.waiting == 0, !i.pmHandling else { return false }
        return i.status == .doing ? !i.hasReport : !i.reportChangedSinceFix
    }
}

/// Remembers since when each task has looked stopped; it counts as stopped once that lasted `delay` without a break.
struct StoppedTracker {
    static let delay: TimeInterval = 5 * 60
    private var since: [String: Date] = [:]
    /// Keys the user nudged: the clock restarts at the nudge, not when the agent is next seen idle.
    private var nudged: [String: Date] = [:]

    /// Call on every poll with the keys that look stopped now; the others are forgotten.
    mutating func note(_ keys: Set<String>, now: Date) {
        var live: [String: Date] = [:]
        for key in keys { live[key] = since[key] ?? nudged[key] ?? now }
        since = live
        nudged = nudged.filter { keys.contains($0.key) }
    }

    /// After a nudge the warning goes away and a new 5 minutes start.
    mutating func reset(_ key: String, now: Date) {
        since[key] = nil
        nudged[key] = now
    }

    func stoppedSince(_ key: String, now: Date) -> Date? {
        guard let start = since[key], now.timeIntervalSince(start) >= Self.delay else { return nil }
        return start
    }

    func stopped(now: Date) -> [String: Date] { since.filter { now.timeIntervalSince($0.value) >= Self.delay } }
}

/// One agent card in the Agents column: the task, its step, the agent's last action, how long it has run and what it cost today.
struct AgentSummary: Equatable {
    let cardID: String
    let title: String
    let phase: TaskPhase?
    let progress: StepProgress?
    let lastAction: String
    let elapsed: TimeInterval?
    let cost: Double?
    /// Set when the agent stopped before finishing (see `StoppedInput`).
    let warning: String?
    /// The role of the card's agent (`dev` for `dev-n280-agent-panel`), else the card's first role; nil when neither is known.
    var role: String? = nil

    static func make(card: TaskCard, phase: TaskPhase?, lastAction: String?, fallback: String, startedAt: Date?, cost: Double?, stoppedSince: Date?, now: Date) -> AgentSummary {
        let line = lastAction.map(oneLine) ?? ""
        let warning = stoppedSince.map { since -> String in
            let ago = Stats.durationText(now.timeIntervalSince(since))
            return card.status == .needsFix ? "Stopped \(ago) ago; the Report is unchanged since the fix request." : "Stopped \(ago) ago with an empty Report."
        }
        return AgentSummary(cardID: card.id, title: plainTitle(card.title, id: card.id), phase: phase, progress: StepProgress.of(status: card.status, phase: phase),
                            lastAction: line.isEmpty ? oneLine(fallback) : line, elapsed: startedAt.map { max(0, now.timeIntervalSince($0)) }, cost: cost, warning: warning,
                            role: card.agent.flatMap(AgentRowName.role(ofAgent:)) ?? card.roles.first)
    }

    /// The phase ("Fixing" while a needs-fix card is worked on), the time since start and the cost; the ones that are unknown are left out.
    var metaParts: [String] {
        [progress?.state == .fixing ? "Fixing" : phase?.label, elapsed.map(Stats.durationText), cost.map { Stats.costText($0) }].compactMap { $0 }
    }

    /// A card's heading usually reads "N98 · Title"; the card shows the id on its own.
    static func plainTitle(_ title: String, id: String) -> String {
        for separator in [" · ", " - ", ": "] where title.hasPrefix(id + separator) {
            let rest = title.dropFirst(id.count + separator.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return title
    }

    /// The last non-empty line, with runs of spaces folded.
    static func oneLine(_ text: String) -> String {
        let last = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return last.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// When the card's current run started: its latest successful `start` line in the action log.
    static func startTime(of cardID: String, project: String, events: [ActionLogEvent]) -> Date? {
        events.filter { $0.concerns(project: project) && $0.text.hasPrefix("start \(cardID) agent=") }.map(\.time).max()
    }
}

/// How an agent's row names it (N283): the role's display name (else the role, capitalised) and the role muted next to it.
struct AgentRowName: Equatable {
    let name: String
    let role: String

    var initial: String { String(name.prefix(1)).uppercased() }

    static func make(role: String, displayNames: [String: String]) -> AgentRowName {
        let display = displayNames[role]?.trimmingCharacters(in: .whitespaces) ?? ""
        return AgentRowName(name: display.isEmpty ? role.prefix(1).uppercased() + role.dropFirst() : display, role: role)
    }

    /// Agent names are `<role>-<task>…` and role names have no "-": the text before the first "-".
    static func role(ofAgent agent: String) -> String? {
        guard let dash = agent.firstIndex(of: "-"), dash != agent.startIndex else { return nil }
        return String(agent[..<dash])
    }
}

/// The status chip on the right of an agent's row (N283).
enum AgentRowStatus: Equatable, CaseIterable {
    case working, waitingForYou, fixing, idle, asleep, stopped

    var label: String {
        switch self {
        case .working: "Working"
        case .waitingForYou: "Waiting for you"
        case .fixing: "Fixing"
        case .idle: "Idle"
        case .asleep: "Asleep"
        case .stopped: "Stopped"
        }
    }

    /// A card agent: stopped before finishing, fixing a needs-fix card, waiting on you (or blocked), working; everything else idle.
    static func of(_ summary: AgentSummary) -> AgentRowStatus {
        if summary.warning != nil { return .stopped }
        if summary.progress?.state == .fixing { return .fixing }
        switch summary.phase {
        case .waitingForYou, .blocked: return .waitingForYou
        case .starting, .working: return .working
        default: return .idle
        }
    }

    /// An agent on no card (the PM): from the terminal's state.
    static func of(_ state: AgentState) -> AgentRowStatus {
        switch state {
        case .working: .working
        case .blocked: .waitingForYou
        case .idle, .done, .unknown: .idle
        }
    }

    /// How far the 3 pt line under a card agent's row is filled: the current step of six counts as reached.
    static func fraction(_ progress: StepProgress) -> Double { Double(progress.current.rawValue + 1) / Double(TaskStep.allCases.count) }
}
