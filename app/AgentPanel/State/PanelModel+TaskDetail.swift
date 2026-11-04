import Foundation

extension PanelModel {
    /// The role's settings as the Team screen has them (a project's role replaces a shared role of the same name).
    func roleConfig(named name: String) -> RoleConfig? {
        var found: RoleConfig?
        for group in team.groups { for role in group.roles where role.config.name == name { found = role.config } }
        return found
    }

    /// The Agent box before any session file is read: the role's configured model and effort.
    func configuredAgentFacts(_ card: TaskCard) -> AgentFacts {
        AgentFacts.make(role: roleConfig(named: card.roles.first ?? "dev"), cost: nil, hasAgent: card.agent != nil)
    }

    /// The Agent box with tokens, cost and the model really used, from the session files of the card's worktree since its start
    /// (`CostReader.taskCost`, cached by path, size and time). The files are read off the main thread.
    func agentFacts(for card: TaskCard) async -> AgentFacts? {
        let role = roleConfig(named: card.roles.first ?? "dev")
        guard let project = selectedProject, card.agent != nil, let branch = card.branch, TaskInput.validBranch(branch) else {
            return AgentFacts.make(role: role, cost: nil, hasAgent: card.agent != nil)
        }
        let worktree = project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).path
        let start = AgentSummary.startTime(of: card.id, project: project.id, events: actionLogEvents())
        let root = claudeProjectsRoot, codexRoot = codexSessionsRoot, tool = tool(ofRole: card.roles.first ?? "dev")
        let cost = await Task.detached { CostReader.taskCost(projectsRoot: root, codexRoot: codexRoot, tool: tool, worktree: worktree, since: start) }.value
        return AgentFacts.make(role: role, cost: cost, hasAgent: true)
    }
}
