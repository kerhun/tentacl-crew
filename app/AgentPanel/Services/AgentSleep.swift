import Foundation

/// A sleeping agent: its process is stopped, its worktree, branch and session stay. One JSON file per agent in `<cache>/sleeping/`, which is
/// also what `term.sh` reads (list-agents shows it as "sleeping", `prompt` wakes it with `spawn-agent.sh --resume`).
struct SleepMarker: Codable, Equatable {
    var agent: String
    var project: String
    var card: String
    var cardPath: String
    var branch: String
    var session: String
    /// The arguments `spawn-agent.sh --resume` needs.
    var source: String
    var role: String
    var since: String
    /// The worktree Sleep left in place; a marker whose worktree is gone is stale. Nil in markers written before this field existed.
    var worktree: String? = nil
}

/// Sleep and Wake for idle agents: what may sleep, the idle timer of the optional auto-sleep, and the marker files.
enum AgentSleep {
    /// UserDefaults key of "Put idle agents to sleep after __ min"; 0 or missing is off.
    static let minutesKey = "autoSleepMinutes"
    static let minutesRange = 1...240
    static let defaultMinutes = 20

    // MARK: marker files

    static func directory(cache: URL = AgentCache.defaultURL()) -> URL { cache.appendingPathComponent("sleeping") }

    static func markers(cache: URL = AgentCache.defaultURL()) -> [SleepMarker] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(cache: cache), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(SleepMarker.self, from: Data(contentsOf: $0)) }
            .sorted { $0.card < $1.card }
    }

    static func write(_ marker: SleepMarker, cache: URL = AgentCache.defaultURL()) throws {
        try FileManager.default.createDirectory(at: directory(cache: cache), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: directory(cache: cache).appendingPathComponent("\(marker.agent).json"), options: .atomic)
    }

    static func remove(agent: String, cache: URL = AgentCache.defaultURL()) {
        try? FileManager.default.removeItem(at: directory(cache: cache).appendingPathComponent("\(agent).json"))
    }

    static func marker(for card: TaskCard, in markers: [SleepMarker]) -> SleepMarker? {
        markers.first { $0.cardPath == card.url.path }
    }

    static func isSleeping(_ card: TaskCard, cache: URL = AgentCache.defaultURL()) -> Bool {
        marker(for: card, in: markers(cache: cache)) != nil
    }

    /// The markers that point at nothing any more: their card is gone, done or cancelled. `cards` are the project's cards; with none loaded nothing is stale.
    static func stale(_ markers: [SleepMarker], project: String, cards: [TaskCard]) -> [SleepMarker] {
        guard !cards.isEmpty else { return [] }
        return markers.filter { marker in
            guard marker.project == project else { return false }
            guard let card = cards.first(where: { $0.url.path == marker.cardPath }) else { return true }
            return card.status == .done || card.status == .cancelled
        }
    }

    // MARK: slots

    /// How many cards hold a slot of the project's `maxParallel`: the ones with an agent, minus the sleeping ones.
    static func slotsHeld(_ cards: [TaskCard], markers: [SleepMarker]) -> Int {
        cards.filter { $0.status.holdsAgent && marker(for: $0, in: markers) == nil }.count
    }

    static func slotsHeld(_ cards: [TaskCard], cache: URL = AgentCache.defaultURL()) -> Int {
        slotsHeld(cards, markers: markers(cache: cache))
    }

    // MARK: what may sleep

    /// Why the agent may not sleep now; nil when it may. Never: working or blocked (a running command, a menu), an open question, a card that is
    /// not being worked on (review is being packed, merged or closed), no session to wake it with.
    static func refusal(status: TaskStatus, agent: AgentState, waiting: Int, hasSession: Bool, busy: Bool = false) -> String? {
        if busy { return "Another action is running; wait until it finishes." }
        guard status == .doing || status == .needsFix else { return "Only a task being worked on can sleep (its status is \"\(status.label)\")." }
        switch agent {
        case .idle, .done: break
        case .working: return "The agent is working; it can sleep once it waits."
        case .blocked: return "The agent is waiting on a prompt; answer it first."
        case .unknown: return "The agent's state is not known yet."
        }
        if waiting > 0 { return "The agent has an open question; answer it first." }
        if !hasSession { return "No conversation was found to wake the agent with." }
        return nil
    }

    /// Auto-sleep is stricter: the agent also has its Report written (it finished, it is not stuck) and the card is being worked on, not fixed.
    static func autoRefusal(status: TaskStatus, agent: AgentState, waiting: Int, hasSession: Bool, hasReport: Bool, busy: Bool = false) -> String? {
        if let reason = refusal(status: status, agent: agent, waiting: waiting, hasSession: hasSession, busy: busy) { return reason }
        if status != .doing { return "Only a task being worked on sleeps by itself." }
        return hasReport ? nil : "The agent has not written its Report yet."
    }

    // MARK: idle timer

    /// Since when each agent has been idle; an agent that is seen working again starts over.
    struct IdleTracker {
        private(set) var since: [String: Date] = [:]

        mutating func note(idle keys: Set<String>, now: Date) {
            since = since.filter { keys.contains($0.key) }
            for key in keys where since[key] == nil { since[key] = now }
        }

        func idleFor(_ key: String, now: Date) -> TimeInterval? { since[key].map { now.timeIntervalSince($0) } }

        /// The keys idle for at least `minutes` (none when off), longest first.
        func due(minutes: Int, now: Date) -> [String] {
            guard minutes > 0 else { return [] }
            return since.filter { now.timeIntervalSince($0.value) >= Double(minutes) * 60 }.sorted { $0.value < $1.value }.map(\.key)
        }
    }
}

/// The shell of a sleeping agent's row on the Agents pane.
struct SleepingAgent: Identifiable, Equatable {
    let cardID: String
    let title: String
    let agent: String
    var id: String { cardID }
}
