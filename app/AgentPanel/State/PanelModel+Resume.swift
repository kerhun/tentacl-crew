import Foundation

/// Resume: start a task agent or the PM again, continuing its last conversation after its terminal session ended.
extension PanelModel {
    static func agentSessionKey(project: String, card: String) -> String { "agentSession.\(project).\(card)" }

    /// The agent's worktree folder (nil when the card has no valid branch).
    func worktreePath(of card: TaskCard) -> String? {
        guard let project = selectedProject, let branch = card.branch, TaskInput.validBranch(branch) else { return nil }
        return project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).path
    }

    /// Whether a terminal session runs in the card's worktree. An unreadable terminal list counts as none (the terminal may be down).
    func hasLiveAgent(_ card: TaskCard) -> Bool {
        guard let project = selectedProject, case .available(let list) = agents else { return false }
        return list.contains { AgentInboxModel.runs($0, in: card, worktrees: project.worktreesURL) }
    }

    /// The session to resume for this card: the last one the panel saw, else the newest session file of the worktree. Nil when there is none.
    func resumeSession(for card: TaskCard) -> String? {
        guard let project = selectedProject, let worktree = worktreePath(of: card) else { return nil }
        return ResumeSession.pick(known: defaults.string(forKey: Self.agentSessionKey(project: project.id, card: card.id)), tool: tool(ofRole: card.roles.first ?? "dev"),
                                  cwd: worktree, claudeRoot: claudeProjectsRoot, codexRoot: codexSessionsRoot)
    }

    /// The state of Resume agent for the card; nil when it does not apply.
    func resumeState(for card: TaskCard) -> StartButtonState? {
        let reason = startSetupReason(for: nil)
        return ResumeSession.buttonState(card: card, agentLive: hasLiveAgent(card),
                                         worktreeExists: worktreePath(of: card).map { FileManager.default.fileExists(atPath: $0) } ?? false,
                                         canAct: reason == nil, reason: reason, busy: isBusy)
    }

    /// Starts the card's agent again in its worktree, continuing its last conversation.
    /// `nudge: false` leaves the agent without the "carry on" line (a message follows right away). Returns whether the agent runs again.
    @discardableResult
    func resumeAgent(_ card: TaskCard, nudge: Bool = true) async -> Bool {
        guard !isBusy, resumeState(for: card)?.enabled == true else { return false }
        guard let session = resumeSession(for: card) else { setActionState(.failed(ResumeSession.noneFound("\(card.id)'s agent"))); return false }
        let role = card.roles.first ?? "dev"
        if let why = await signInGate.ensure(tool(ofRole: role)) { setActionState(.failed(why)); return false }
        guard !isBusy else { return false }
        guard let flow = makeFlow(role: role) else { setActionState(.failed(startSetupReason ?? usageHold(forRole: role) ?? "actions are not available")); return false }
        setActionState(.running("Resuming \(card.id)'s agent…"))
        var resumed = false
        do {
            let started = try await flow.resume(card, session: session, nudge: nudge, status: { [weak self] text in Task { @MainActor in self?.setActionState(.running(text)) } })
            AgentSleep.remove(agent: started.agent, cache: agentCache)
            setActionState(.done("Resumed \(started.agent)."))
            resumed = true
        } catch let error as StartError {
            setActionState(.failed(error.message))
        } catch {
            setActionState(.failed(error.localizedDescription))
        }
        await reloadCards()
        await refreshAgents()
        return resumed
    }

    /// The PM's last conversation in the project folder: the session the panel last chose for the PM, else the newest session file there.
    var pmResumeSession: String? {
        guard let project = selectedProject else { return nil }
        return ResumeSession.pick(known: pmSession(forProject: project.id), tool: pmTool(of: project.id), cwd: project.repoPath, claudeRoot: claudeProjectsRoot, codexRoot: codexSessionsRoot)
    }

    /// Starts the PM again, continuing its last conversation. Does nothing while a PM runs or another action is in progress.
    func resumePM() async {
        guard pmStatus == .missing, !isBusy else { return }
        guard let session = pmResumeSession else { setActionState(.failed(ResumeSession.noneFound("the PM"))); return }
        await spawnPM(resume: session)
    }
}

/// Sleep and Wake (N261): an idle agent's process stops, its worktree, branch and session stay; Wake resumes the same session.
extension PanelModel {
    /// Where the sleep markers live (the agents' cache folder; tests point `AGENT_PANEL_CACHE` elsewhere).
    var agentCache: URL { AgentCache.defaultURL() }

    /// The selected project's sleeping agents' cards, from the marker files.
    var sleepingAgents: [SleepingAgent] {
        guard let project = selectedProject else { return [] }
        let markers = AgentSleep.markers(cache: agentCache).filter { $0.project == project.id }
        return markers.compactMap { marker in
            for case .card(let card) in cards where card.url.path == marker.cardPath { return SleepingAgent(cardID: card.id, title: card.title, agent: marker.agent) }
            return nil
        }
    }

    func isSleeping(_ card: TaskCard) -> Bool { AgentSleep.isSleeping(card, cache: agentCache) }

    private func sleepWaiting(_ card: TaskCard) -> Int { questionsForYou.filter { $0.cardID == card.id }.count + inbox.quietWaitingCount(forCard: card.id) }

    /// Why this agent cannot sleep now (nil: it can).
    func sleepRefusal(of agent: AgentStatus) -> String? {
        guard let card = card(of: agent) else { return "Only a task's agent can sleep." }
        return AgentSleep.refusal(status: card.status, agent: agent.state, waiting: sleepWaiting(card), hasSession: resumeSession(for: card) != nil, busy: isBusy)
    }

    func canSleep(_ agent: AgentStatus) -> Bool { sleepRefusal(of: agent) == nil }

    /// Stops the agent's terminal session (`stop-agent.sh`, worktree and branch stay) and leaves a marker; Wake resumes the same session.
    @discardableResult
    func sleepAgent(_ agent: AgentStatus, auto: Bool = false) async -> Bool {
        guard let project = selectedProject, let card = card(of: agent) else { return false }
        if let reason = sleepRefusal(of: agent) { if !auto { setActionState(.failed(reason)) }; return false }
        guard let session = resumeSession(for: card), let source = project.sourcePath, let branch = card.branch, let worktree = worktreePath(of: card),
              let role = roleStore.resolve(card.roles.first ?? "dev", in: project).role else {
            if !auto { setActionState(.failed("The agent's session, role or worktree could not be found, so it cannot be woken later.")) }
            return false
        }
        let name = card.agent ?? agent.name ?? agent.title
        let marker = SleepMarker(agent: name, project: project.id, card: card.id, cardPath: card.url.path, branch: branch, session: session,
                                 source: source, role: role.fileURL.path, since: ISO8601DateFormatter().string(from: now()), worktree: worktree)
        setActionState(.running("Putting \(card.id)'s agent to sleep…"))
        var slept = false
        do {
            try AgentSleep.write(marker, cache: agentCache)
            let result = try await makeScripts(settings).run(.stop, arguments: [name, worktree, "--expect-branch", branch, "--no-sim"])
            if result.status == 0 || result.status == 4 {
                actionLog.append(auto ? "auto-sleep \(card.id)" : "sleep \(card.id)", project: project.id)
                setActionState(.done("\(card.id)'s agent is sleeping."))
                slept = true
            } else {
                AgentSleep.remove(agent: name, cache: agentCache)
                setActionState(.failed(Self.sleepFailure(result)))
            }
        } catch {
            AgentSleep.remove(agent: name, cache: agentCache)
            setActionState(.failed(StartTaskFlow.describe(error)))
        }
        await refreshAgents()
        return slept
    }

    private static func sleepFailure(_ result: ScriptResult) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "stop-agent.sh exited with status \(result.status)" : text
    }

    /// Wake: the same session again. `nudge: false` when a message is delivered right after.
    @discardableResult
    func wakeAgent(_ card: TaskCard, nudge: Bool = true) async -> Bool {
        guard isSleeping(card) else { return true }
        if hasLiveAgent(card) { if let marker = AgentSleep.marker(for: card, in: AgentSleep.markers(cache: agentCache)) { AgentSleep.remove(agent: marker.agent, cache: agentCache) }; return true }
        return await resumeAgent(card, nudge: nudge)
    }

    /// Wakes a sleeping agent first when something is about to be sent to it (Fix notes). True when the agent runs or was never asleep.
    func wakeBeforeSending(_ card: TaskCard) async -> Bool { await wakeAgent(card, nudge: false) }

    /// Called on every agent poll: puts the agents that were idle for the chosen time to sleep, one at a time (off by default).
    func autoSleepTick() {
        guard case .available(let list) = agents, let project = selectedProject else { return }
        let all = cards.compactMap { result -> TaskCard? in if case .card(let card) = result { return card } else { return nil } }
        for marker in AgentSleep.stale(AgentSleep.markers(cache: agentCache), project: project.id, cards: all) { AgentSleep.remove(agent: marker.agent, cache: agentCache) }
        let time = now()
        var idle: [String: AgentStatus] = [:]
        for agent in list where !TerminalShells.isUserShell(agent.paneID) && (agent.state == .idle || agent.state == .done) {
            guard let card = card(of: agent) else { continue }
            idle["\(project.id)|\(card.id)|\(Self.sessionKey(agent))"] = agent
        }
        Self.idleTracker.note(idle: Set(idle.keys), now: time)
        let minutes = defaults.integer(forKey: AgentSleep.minutesKey)
        guard minutes > 0, !isBusy else { return }
        for key in Self.idleTracker.due(minutes: minutes, now: time) {
            guard let agent = idle[key], let card = card(of: agent) else { continue }
            let report = !(card.sections["Report"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard AgentSleep.autoRefusal(status: card.status, agent: agent.state, waiting: sleepWaiting(card), hasSession: resumeSession(for: card) != nil, hasReport: report) == nil else { continue }
            Task { await sleepAgent(agent, auto: true) }
            return
        }
    }

    static var idleTracker = AgentSleep.IdleTracker()
}
