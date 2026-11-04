import Foundation

/// When a running card's agent started and what it cost today (nil: unknown).
struct AgentCardFacts: Equatable {
    var startedAt: Date?
    var cost: Double?
}

/// What the Agents column needs to draw a task agent's card and act on it.
struct AgentCardSource {
    var summary: (AgentStatus) -> AgentSummary?
    /// Shows the agent's live pane on the Terminals screen.
    var select: (AgentStatus) -> Void
    var nudge: (AgentStatus) -> Void
    var isNudging: (AgentStatus) -> Bool
}

/// The agent cards of the Agents column: their summary line, the stopped-agent rule and the facts read from the log and session files.
extension PanelModel {
    var agentCards: AgentCardSource {
        AgentCardSource(summary: { [weak self] in self?.agentSummary($0) },
                        select: { [weak self] agent in self?.openTerminalTab(agent.paneID) },
                        nudge: { [weak self] agent in Task { await self?.nudge(agent) } },
                        isNudging: { [weak self] in self?.nudging.contains($0.paneID) ?? false })
    }

    /// The running card an agent works on (nil for an agent on no card, e.g. the PM).
    func card(of agent: AgentStatus) -> TaskCard? {
        guard let project = selectedProject else { return nil }
        for case .card(let card) in cards where card.status.holdsAgent && AgentInboxModel.runs(agent, in: card, worktrees: project.worktreesURL) { return card }
        return nil
    }

    /// The pane of the agent running a card (nil: none runs).
    func agentPane(of card: TaskCard) -> String? {
        guard let project = selectedProject, case .available(let list) = agents else { return nil }
        return list.first { AgentInboxModel.runs($0, in: card, worktrees: project.worktreesURL) }?.paneID
    }

    /// Which tool runs a role of the selected project (Claude when the role cannot be found; the PM follows its pm role).
    func tool(ofRole name: String) -> AgentTool {
        guard let project = selectedProject else { return .claude }
        return pmTool(of: project.id, role: name)
    }

    /// The tool of the project's resolved role `name` (default pm); Claude when it has no `tool` or cannot be found.
    func pmTool(of projectID: String, role name: String = "pm") -> AgentTool {
        guard let project = projects.first(where: { $0.id == projectID }), roleStore.resolve(name, in: project).role?.config.tool == "codex" else { return .claude }
        return .codex
    }

    /// Which tool runs an agent: its card's role (the first one, else "dev"); an agent on no card (the PM) follows the pm role.
    func tool(of agent: AgentStatus) -> AgentTool {
        guard let card = card(of: agent) else { return selectedProjectID.map { pmTool(of: $0) } ?? .claude }
        return tool(ofRole: card.roles.first ?? "dev")
    }

    /// Whether any role of any watched project runs on Codex (the shared roles and every project's own), the PM included.
    var anyRoleUsesCodex: Bool {
        var configs = roleStore.baseRoles().roles.map(\.config)
        for project in projects { configs += roleStore.projectRoles(project).roles.map(\.config) }
        return configs.contains { $0.tool == "codex" }
    }

    /// Whether any role of any watched project (the PM included) runs on Claude: a role without `tool` does.
    var anyRoleUsesClaude: Bool {
        var configs = roleStore.baseRoles().roles.map(\.config)
        for project in projects { configs += roleStore.projectRoles(project).roles.map(\.config) }
        return configs.contains { $0.tool != "codex" }
    }

    func agentSummary(_ agent: AgentStatus) -> AgentSummary? {
        guard let card = card(of: agent) else { return nil }
        let time = now()
        // The tracker is updated on the agent poll; a Report written since then must not keep the warning up.
        let since = StoppedInput.looksStopped(stoppedInput(card, agent)) ? stopped.stoppedSince(Self.stoppedKey(card, agent), now: time) : nil
        let facts = cardFacts[card.id]
        return AgentSummary.make(card: card, phase: phase(of: card), lastAction: statusLine(agent), fallback: agentSummaryLine(agent),
                                 startedAt: facts?.startedAt, cost: facts?.cost, stoppedSince: since, now: time)
    }

    /// The agent's one live line (N251): what it waits for, else its 7501 message, else its transcript's last action, else its state line.
    /// The user's own shells have none.
    func statusLine(_ agent: AgentStatus) -> String {
        guard !TerminalShells.isUserShell(agent.paneID) else { return "" }
        return AgentStatusLine.make(heldByPM: inbox.panesWithPM.contains(agent.paneID), question: inbox.questions.first { $0.paneID == agent.paneID }?.question, live: agent.liveMessage,
                                    transcript: lastActions[Self.sessionKey(agent)], state: agentSummaryLine(agent))
    }

    /// The task agents that stopped before finishing (for the "agent seems stuck" notification).
    var stuckAgents: [NotificationExtras.Stuck] {
        let f = ISO8601DateFormatter()
        return stopped.stopped(now: now()).map { NotificationExtras.Stuck(cardID: String($0.key.prefix { $0 != "|" }), since: f.string(from: $0.value)) }
            .sorted { $0.cardID < $1.cardID }
    }

    static func stoppedKey(_ card: TaskCard, _ agent: AgentStatus) -> String { "\(card.id)|\(sessionKey(agent))" }
    static func sessionKey(_ agent: AgentStatus) -> String { "\(agent.paneID)|\(agent.sessionID ?? "")" }

    private func stoppedInput(_ card: TaskCard, _ agent: AgentStatus) -> StoppedInput {
        StoppedInput(status: card.status, agent: agent.state,
                     hasReport: !(card.sections["Report"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     reportChangedSinceFix: fixReports.changed(card),
                     waiting: questionsForYou.filter { $0.cardID == card.id }.count + inbox.quietWaitingCount(forCard: card.id),
                     pmHandling: autopilot.isHandledByPM(pane: agent.paneID))
    }

    /// Called on every agent poll of the selected project: reads what each task agent added to its session, notes which ones look
    /// stopped and, at most once a minute, reads the start times and today's costs.
    func noteAgentCards() {
        guard case .available(let list) = agents else { return }
        var live: Set<String> = []
        var looking: Set<String> = []
        var running: [(TaskCard, AgentStatus)] = []
        for agent in list {
            guard !TerminalShells.isUserShell(agent.paneID) else { continue }
            let card = card(of: agent)
            if let card {
                running.append((card, agent))
                // The last session the panel saw for this card's agent: Resume continues it after the terminal session is gone.
                if let session = agent.sessionID, !session.isEmpty, let project = selectedProject {
                    let sessionKey = Self.agentSessionKey(project: project.id, card: card.id)
                    if defaults.string(forKey: sessionKey) != session { defaults.set(session, forKey: sessionKey) }
                }
            }
            let key = Self.sessionKey(agent)
            if let session = agent.sessionID, !session.isEmpty {
                live.insert(key)
                // A Codex session file appears a moment after the agent starts: no reader until then.
                var reader = transcripts[key] ?? SessionTranscript.make(tool: tool(of: agent), cwd: agent.cwd, session: session, projectsRoot: claudeProjectsRoot, codexRoot: codexSessionsRoot)
                if reader?.poll() == true, let last = reader?.entries.last(where: { $0.kind == .agent || $0.kind == .tools }) {
                    let line = AgentSummary.oneLine(last.text)
                    if lastActions[key] != line { lastActions[key] = line }
                }
                transcripts[key] = reader
            }
            if let card, StoppedInput.looksStopped(stoppedInput(card, agent)) { looking.insert(Self.stoppedKey(card, agent)) }
        }
        transcripts = transcripts.filter { live.contains($0.key) }
        if lastActions.keys.contains(where: { !live.contains($0) }) { lastActions = lastActions.filter { live.contains($0.key) } }
        stopped.note(looking, now: now())
        readCardFacts(running)
        autoSleepTick()
    }

    /// Start times come from the action log; the cost is the estimate of the worktree's session files touched today since the start
    /// (whole files, see `CostReader.taskCost`). Read off the main thread, once a minute, or sooner when a running card has none yet.
    private func readCardFacts(_ running: [(TaskCard, AgentStatus)]) {
        guard let project = selectedProject, !cardFactsLoading else { return }
        let time = now()
        let missing = running.contains { cardFacts[$0.0.id] == nil }
        if let at = cardFactsReadAt, time.timeIntervalSince(at) < 60, !missing { return }
        cardFactsReadAt = time
        guard !running.isEmpty else { if !cardFacts.isEmpty { cardFacts = [:] }; return }
        let events = actionLogEvents()
        let today = Calendar.current.startOfDay(for: time)
        let jobs = running.map { card, _ in
            (id: card.id, tool: tool(ofRole: card.roles.first ?? "dev"), start: AgentSummary.startTime(of: card.id, project: project.id, events: events),
             worktree: card.branch.map { project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: $0)).path })
        }
        let root = claudeProjectsRoot, codexRoot = codexSessionsRoot
        cardFactsLoading = true
        Task { [weak self] in
            let facts = await Task.detached { () -> [String: AgentCardFacts] in
                var result: [String: AgentCardFacts] = [:]
                for job in jobs {
                    let since = max(job.start ?? today, today)
                    let cost = job.worktree.flatMap { CostReader.taskCost(projectsRoot: root, codexRoot: codexRoot, tool: job.tool, worktree: $0, since: since)?.dollars }
                    result[job.id] = AgentCardFacts(startedAt: job.start, cost: cost)
                }
                return result
            }.value
            guard let self else { return }
            self.cardFactsLoading = false
            if self.selectedProjectID == project.id, self.cardFacts != facts { self.cardFacts = facts }
        }
    }
}
