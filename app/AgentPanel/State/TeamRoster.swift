import Foundation

/// An agent at work for a role: on a card, or the project's PM (no card).
struct RosterAgent: Equatable {
    let role: String
    let cardID: String?
    let title: String
    let state: AgentState
    /// The card's status; nil for the PM.
    var stage: TaskStatus? = nil

    /// What the row says: the card's stage when it says more than the agent's state (never "done" for an unmerged card).
    var label: String {
        switch stage {
        case .review?: return "in review"
        case .needsFix?: return state == .working ? "fixing" : "needs fix"
        default: return RoleCardView.label(state)
        }
    }
}

/// One role on the Roster tab.
struct RosterCard: Equatable, Identifiable {
    let role: ResolvedRole
    let name: String
    let display: String
    let initial: String
    /// The role's place in the roster; the view turns it into the role's colour.
    let tint: Int
    let scope: String
    let isCodex: Bool
    let modelLabel: String
    let effort: String
    /// 1 to `effortSteps` (0 for an effort the app does not know).
    let effortStep: Int
    let effortSteps: Int
    let modeLabel: String
    let modeMeaning: String
    let reportsTo: String
    let givesTasksTo: String
    let agents: [RosterAgent]
    let done: Int
    let waiting: Int
    var id: String { name }
}

/// The Team screen's Roster tab: the summary tiles and one card per role, built from the roles, the team chart, the cards and the
/// running agents the panel already has. Pure: nothing is read or written here.
struct TeamRoster: Equatable {
    struct DoneShare: Equatable { let role: String; let count: Int; let tint: Int? }

    let title: String
    let subtitle: String
    let cards: [RosterCard]
    let runningCount: Int
    let runningByRole: String
    let claudeCount: Int
    let codexCount: Int
    let doneTotal: Int
    /// Cards done per role, largest first (the bar under the count).
    let doneSplit: [DoneShare]
    let attention: [String]

    var doneLine: String { doneSplit.map { "\($0.role) \($0.count)" }.joined(separator: " · ") }

    /// `project` holds the project's own and mapped roles; one with the name of a base role replaces it.
    @MainActor
    init(base: [ResolvedRole], project: [ResolvedRole], projectName: String?, chart: TeamChart?, cards taskCards: [TaskCard], agents: [RosterAgent]) {
        var effective: [String: ResolvedRole] = [:]
        for r in base { effective[r.config.name] = r }
        for r in project { effective[r.config.name] = r }
        let baseNames = Set(base.map(\.config.name))

        var order: [String] = []
        if let chart {
            func add(_ role: String) {
                guard !order.contains(role) else { return }
                order.append(role)
                for child in chart.members where child.reportsTo == role { add(child.role) }
            }
            for m in chart.members where m.reportsTo == nil { add(m.role) }
            for m in chart.members { add(m.role) }
        }
        let inChart = order
        order = order.filter { effective[$0] != nil } + effective.keys.filter { !order.contains($0) }.sorted()

        func cardRole(_ c: TaskCard) -> String { c.roles.first ?? "dev" }
        let done = taskCards.filter { $0.status == .done }
        let doneBy = Dictionary(grouping: done, by: cardRole).mapValues(\.count)
        let waitingBy = Dictionary(grouping: taskCards.filter { $0.status == .todo || $0.status == .awaitingStartApproval }, by: cardRole).mapValues(\.count)

        cards = order.enumerated().map { index, name in
            let role = effective[name]!
            let c = role.config
            let display = c.displayName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? c.name
            let scope: String
            switch role.source {
            case .base: scope = "Base role"
            case .mapped: scope = "From project.json (read-only)"
            case .project: scope = "Only in \(projectName ?? "this project")" + (baseNames.contains(name) ? " · overrides the base role" : "")
            }
            let codex = c.tool == "codex"
            let reportsTo: String
            if let chart, chart.member(name) != nil { reportsTo = chart.manager(of: name) ?? "You" } else { reportsTo = "Not in the chart" }
            let below = chart?.member(name) != nil ? chart!.descendants(of: name) : []
            return RosterCard(role: role, name: name, display: display, initial: String(display.prefix(1)).uppercased(), tint: index, scope: scope, isCodex: codex,
                              modelLabel: codex ? c.model : ModelCatalog.label(for: c.model), effort: c.effort,
                              effortStep: (RoleValidator.efforts.firstIndex(of: c.effort) ?? -1) + 1, effortSteps: RoleValidator.efforts.count,
                              modeLabel: Self.modeLabel(c.permissionMode), modeMeaning: Self.permissionMeaning(of: c.permissionMode, tool: c.tool),
                              reportsTo: reportsTo, givesTasksTo: below.isEmpty ? "nobody" : below.joined(separator: ", "),
                              agents: agents.filter { $0.role == name }, done: doneBy[name] ?? 0, waiting: waitingBy[name] ?? 0)
        }

        title = projectName.map { "Team · \($0)" } ?? "Team"
        subtitle = "\(cards.count) role\(cards.count == 1 ? "" : "s"). Base roles are shared by every project; a project can override one."
        runningCount = agents.count
        let runningRoles = order.filter { r in agents.contains { $0.role == r } } + Set(agents.map(\.role)).subtracting(order).sorted()
        runningByRole = runningRoles.isEmpty ? "No agent running" : runningRoles.map { r in
            let n = agents.filter { $0.role == r }.count
            return n > 1 ? "\(r) ×\(n)" : r
        }.joined(separator: " · ")
        codexCount = cards.filter(\.isCodex).count
        claudeCount = cards.count - codexCount
        doneTotal = done.count
        let tints = Dictionary(uniqueKeysWithValues: cards.map { ($0.name, $0.tint) })
        doneSplit = doneBy.map { DoneShare(role: $0.key, count: $0.value, tint: tints[$0.key]) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.role < $1.role }

        var notes: [String] = []
        let named = Set(taskCards.flatMap { $0.roles.isEmpty ? ["dev"] : $0.roles })
        for card in cards where card.name != "pm" && inChart.contains(card.name) && card.agents.isEmpty && !named.contains(card.name) {
            notes.append("\(card.name) has no agent and gets no cards")
        }
        for name in inChart where effective[name] == nil { notes.append("\(name) is in the chart but has no role file") }
        for card in cards {
            for p in RoleValidator.problems(for: card.role.config) where p.severity == .error && ["tool", "model", "effort", "permissionMode"].contains(p.field) {
                notes.append("\(card.name): \(p.message)")
            }
        }
        attention = notes
    }

    // MARK: helpers

    static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": return "Accept edits"
        case "auto": return "Auto"
        case "bypassPermissions": return "Bypass"
        case "manual": return "Manual"
        case "dontAsk": return "Don't ask"
        case "plan": return "Plan"
        default: return mode
        }
    }

    /// What a permission mode lets the agent do, in one line (for Codex, the role form's text).
    @MainActor
    static func permissionMeaning(of mode: String, tool: String) -> String {
        if tool == "codex" { return TeamModel.codexMeaning(of: mode) }
        switch mode {
        case "manual": return "Asks you before every file edit and command."
        case "plan": return "Reads and proposes; never edits files or runs commands that change them."
        case "auto": return "Edits and runs commands that a safety check approves; asks you about the rest."
        case "dontAsk": return "Never asks: anything not allowed in advance is refused."
        case "bypassPermissions": return "Never asks and is never stopped. Only for a role you fully trust."
        default: return "Edits files in its worktree without asking; asks before commands."
        }
    }

    /// A name for a copy of `name` that no role uses yet and that is still a valid role name.
    static func copyName(of name: String, taken: Set<String>) -> String {
        var n = 1
        while true {
            let suffix = n == 1 ? "_copy" : "_copy\(n)"
            let candidate = String(name.prefix(20 - suffix.count)) + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// The agents at work: each running card's agent (the card's first role) and the project's PM.
    static func agents(_ list: [AgentStatus], cards: [TaskCard], worktrees: URL, pm: AgentStatus?) -> [RosterAgent] {
        var out: [RosterAgent] = []
        for card in cards where card.status.holdsAgent {
            guard let path = AgentInboxModel.worktreePath(of: card, worktrees: worktrees),
                  let agent = list.first(where: { $0.paneID != pm?.paneID && AgentInboxModel.runs($0, inWorktreePath: path) }) else { continue }
            out.append(RosterAgent(role: card.roles.first ?? "dev", cardID: card.id, title: card.title, state: agent.state, stage: card.status))
        }
        if let pm { out.append(RosterAgent(role: "pm", cardID: nil, title: "Project manager", state: pm.state)) }
        return out
    }
}
