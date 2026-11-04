import Foundation

/// One agent running with a role: its card (nil for an agent on no card, like the PM) and when it started (nil: unknown).
struct RoleRunningAgent: Equatable, Identifiable {
    let cardID: String?
    let title: String
    let startedAt: Date?
    var id: String { cardID ?? title }
}

/// The role editor's side column in plain words: what the draft does, and which agents run with the role now.
enum RoleSummary {
    /// 3–5 short sentences built from the draft: tool, model and effort; what it edits without asking; what it asks first;
    /// who it reports to and gives tasks to (from the team chart); and, for a headless role, that the panel does not start it.
    static func lines(draft: RoleDraft, modelLabel: String, chart: TeamChart?, names: [String: String]) -> [String] {
        let tool = draft.tool == "codex" ? "Codex" : "Claude Code"
        let label = modelLabel.replacingOccurrences(of: " (latest)", with: "")
        let model = label.isEmpty ? "its default model" : label
        var out = ["Runs \(tool) with \(model) at \(draft.effort) effort."]
        out += permissionLines(draft)
        out.append(chartLine(role: draft.name, chart: chart, names: names))
        if draft.kind == "headless" { out.append("Runs headless, without a terminal; the panel does not start it.") }
        return out
    }

    private static func permissionLines(_ draft: RoleDraft) -> [String] {
        switch draft.permissionMode {
        case "plan": return ["Reads and proposes; never edits files.", "Asks you before it changes anything."]
        case "manual": return ["Edits nothing without asking.", "Asks you before every edit and command."]
        case "auto": return ["Edits and runs commands on its own; a safety check stops risky steps.", "Asks you only when that check flags a step."]
        case "dontAsk": return ["Edits and runs only what the allowed list permits.", "Never asks you; anything else is refused."]
        case "bypassPermissions": return ["Edits and runs anything without asking.", "Never asks you; only for throwaway sandboxes."]
        default:
            let edits = "Edits files in its own worktree without asking."
            if draft.tool == "codex" { return [edits, "Asks you when it needs more than its sandbox allows."] }
            if draft.allowedTools.contains("Bash") { return [edits, "Runs shell commands without asking."] }
            if draft.allowedTools.contains(where: { $0.hasPrefix("Bash(") }) { return [edits, "Asks you before any shell command not on the list."] }
            return [edits, "Asks you before any shell command."]
        }
    }

    private static func chartLine(role: String, chart: TeamChart?, names: [String: String]) -> String {
        func name(_ r: String) -> String { names[r].map { $0.isEmpty || $0 == r ? r : "\($0) (\(r))" } ?? r }
        guard let chart, chart.member(role) != nil else { return "Not in the team chart: reports to you; gives tasks to nobody." }
        let boss = chart.manager(of: role).map(name) ?? "you"
        let below = chart.descendants(of: role).map(name)
        let gives: String
        switch below.count {
        case 0: gives = "nobody"
        case 1: gives = below[0]
        default: gives = below.dropLast().joined(separator: ", ") + " and " + below.last!
        }
        return "Reports to \(boss); gives tasks to \(gives)."
    }

    /// The live agents by role (the text before the first "-" of the agent's name), each with its card and start time.
    static func running(_ agents: [(agent: AgentStatus, card: TaskCard?)], facts: [String: AgentCardFacts]) -> [String: [RoleRunningAgent]] {
        var out: [String: [RoleRunningAgent]] = [:]
        for (agent, card) in agents {
            guard let name = agent.name, let dash = name.firstIndex(of: "-") else { continue }
            let entry = card.map { RoleRunningAgent(cardID: $0.id, title: $0.title, startedAt: facts[$0.id]?.startedAt) } ?? RoleRunningAgent(cardID: nil, title: name, startedAt: nil)
            out[String(name[..<dash]), default: []].append(entry)
        }
        return out
    }

    /// An agent runs with old settings when its role was saved after it started; unknown times never claim that.
    static func hasOldSettings(startedAt: Date?, savedAt: Date?) -> Bool {
        guard let startedAt, let savedAt else { return false }
        return savedAt > startedAt
    }

    /// The side column sits beside the sections when the form is this wide (sections ≥ 520, column 340, gaps and padding); under them otherwise.
    static func sideBySide(width: CGFloat) -> Bool { width >= 940 }

    /// When the role file was last saved.
    static func savedAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
