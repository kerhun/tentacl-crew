import Foundation

/// Sends a typed command to one agent. The target is checked against the terminal's current agent list right before sending,
/// so a command never reaches a pane that has closed (or been reused by something else) since it was selected.
/// The agent the user picked in the command bar: its pane and the session running there.
struct ChosenTarget: Equatable {
    let paneID: String
    let sessionID: String?
    let label: String
}

enum TargetResolution: Equatable {
    case keep(String)
    /// The chosen agent is gone (or its pane now runs something else): the label to show; do not retarget quietly.
    case gone(String)
    case choose(String?)
}

struct CommandCenter {
    let adapter: TerminalListing
    let commander: TerminalCommanding
    let log: ActionLog

    /// `expectingSession`: the session of the agent the user picked; when the pane now runs a different session the command is not sent.
    func send(_ text: String, to paneID: String, expectingSession: String? = nil, requireReady: Bool = false, project: String? = nil) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !paneID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BackendError.failed("empty command")
        }
        let agents = try await adapter.agents()
        guard let target = agents.first(where: { Self.matches($0, paneID: paneID, session: expectingSession) }) else { throw BackendError.failed("agent is no longer running") }
        // A blocked agent shows a menu: Enter could accept it. A working one would queue the text behind its turn.
        if requireReady, target.state != .idle, target.state != .done { throw BackendError.failed("agent is busy") }
        try await commander.prompt(target: paneID, text: text)
        // A notice of the panel is logged whole (the round timeline reads what it says); a user's message is cut.
        let shown = text.hasPrefix("Panel:") ? text : String(text.prefix(80))
        log.append("command to \(paneID): \(shown)", project: project)
    }

    private static func matches(_ agent: AgentStatus, paneID: String, session: String?) -> Bool {
        agent.paneID == paneID && (session == nil || agent.sessionID == session)
    }

    /// The remembered target ("pane" or "pane|session") when that agent is still running, otherwise an agent titled "PM…",
    /// otherwise the first agent. A remembered session must match: a reused pane is not the same agent.
    static func defaultTarget(in agents: [AgentStatus], remembered: String?, preferred: String? = nil) -> String? {
        if let remembered {
            let parts = remembered.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if let found = agents.first(where: { matches($0, paneID: parts[0], session: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil) }) { return found.paneID }
        }
        if let preferred, agents.contains(where: { $0.paneID == preferred }) { return preferred }
        return (agents.first { PMNotice.isPMTitle($0.title) } ?? agents.first)?.paneID
    }

    /// What the command bar should do after the agent list changed: keep the chosen agent, say it is gone, or pick a default
    /// (only when nothing was chosen yet).
    static func resolveTarget(chosen: ChosenTarget?, agents: [AgentStatus], remembered: String?, preferred: String? = nil) -> TargetResolution {
        if let chosen {
            if agents.contains(where: { matches($0, paneID: chosen.paneID, session: chosen.sessionID) }) { return .keep(chosen.paneID) }
            return .gone(chosen.label)
        }
        return .choose(defaultTarget(in: agents, remembered: remembered, preferred: preferred))
    }
}
