import Foundation

enum ActionState: Equatable {
    case idle
    case running(String)
    case failed(String)
    case done(String)
}

/// What an action that the panel runs for a request came to: done, refused because another action is running, or failed with a reason.
enum ActionResult: Equatable {
    case ok
    case busy
    case failed(String)

    static let busyReason = "the panel is busy with another action; try again when it is done"

    /// nil for success, else the reason (what a PM request reports).
    var failure: String? {
        switch self {
        case .ok: nil
        case .busy: Self.busyReason
        case .failed(let message): message
        }
    }
}

/// Commands and starting tasks: the first things the panel does besides reading.
extension PanelModel {
    /// Why no card starts now, without the safe point (the PM may still be started at it).
    var startSetupReason: String? { startSetupReason(for: selectedProjectID) }

    func startSetupReason(for id: String?) -> String? {
        guard let project = config(of: id) else { return "No project selected." }
        if settings.scriptsDir == nil { return "Set \"scriptsDir\" in ~/.config/tentacl/projects.json to enable starting agents." }
        if project.sourcePath == nil { return "The location of project.json is unknown." }
        if let reason = gitSetup.startReason(projectID: project.id) { return reason }
        return nil
    }

    /// Why a card cannot start now; the one gate of Start, Plan a round, Autopilot and the PM's requests.
    var startDisabledReason: String? { startSetupReason ?? signInReason(forRole: nil) ?? usageHold }

    /// Not signed in to the tool the role runs on (the PM and no role: Claude). "Cannot tell" is nil.
    func signInReason(forRole role: String?) -> String? { signInGate.reason(for: tool(ofRole: role ?? "pm")) }

    /// Signs in through the terminal, then checks Setup again.
    func signIn(_ tool: AgentTool) async {
        await signInGate.signIn(tool)
        await setup.check()
    }

    /// The same for one card: the safe point of its tool's limit only (N219).
    func startDisabledReason(for card: TaskCard) -> String? {
        let role = card.roles.first ?? "dev"
        return startSetupReason ?? signInReason(forRole: role) ?? usageHold(forRole: role)
    }

    /// The Dependencies state of every card, for the list and the Start button.
    var dependencyGraph: DependencyGraph {
        if let dependencyGraphCache { return dependencyGraphCache }
        let graph = DependencyGraph(cards: selectedTaskCards)
        dependencyGraphCache = graph
        return graph
    }

    var canStart: Bool { startDisabledReason == nil }

    var rememberedTarget: String? {
        guard let id = selectedProjectID else { return nil }
        return defaults.string(forKey: "commandTarget.\(id)")
    }

    var isBusy: Bool { if case .running = actionState { return true } else { return false } }

    func makeFlow(project id: String? = nil, role: String? = nil) -> StartTaskFlow? {
        guard startSetupReason(for: id) == nil, usageHold(forRole: role) == nil, let project = config(of: id) else { return nil }
        let doing = taskCards(of: project.id).filter { $0.status.holdsAgent }
        let graph = project.id == selectedProjectID ? dependencyGraph : DependencyGraph(cards: taskCards(of: project.id))
        return StartTaskFlow(project: project, scripts: makeScripts(settings), commander: makeCommander(), writer: cardWriter,
                             log: actionLog, roleStore: roleStore, teamStore: TeamChartStore(), runningCards: { doing }, trust: claudeTrust,
                             dependencyState: { graph.state(of: $0.id) }, server: terminalServer)
    }

    func startPlan(for card: TaskCard, project id: String? = nil) -> Result<StartPlan, StartError> {
        let role = card.roles.first ?? "dev"
        guard let flow = makeFlow(project: id, role: role) else { return .failure(.invalid(startSetupReason(for: id) ?? usageHold(forRole: role) ?? "actions are not available")) }
        do { return .success(try flow.plan(for: card)) }
        catch let error as StartError { return .failure(error) }
        catch { return .failure(.invalid(error.localizedDescription)) }
    }

    /// Starts the planned task. Returns at once when another action is still running (double clicks, two windows).
    func confirmStart(_ plan: StartPlan, givingItMyself: Bool = false) async {
        guard !isBusy else { return }
        if let why = await signInGate.ensure(tool(ofRole: plan.roleName)) { setActionState(.failed(why)); return }
        guard !isBusy else { return } // another start went on while the sign-in check ran
        guard let flow = makeFlow(role: plan.roleName) else { setActionState(.failed(startSetupReason ?? usageHold(forRole: plan.roleName) ?? "actions are not available")); return }
        setActionState(.running("Starting \(plan.agentName)…"))
        do {
            let started = try await flow.start(plan, givingItMyself: givingItMyself, status: { [weak self] text in Task { @MainActor in self?.setActionState(.running(text)) } })
            setActionState(.done("Started \(started.agent) on \(plan.branch)."))
        } catch let error as StartError {
            setActionState(.failed(error.message))
        } catch {
            setActionState(.failed(error.localizedDescription))
        }
        await reloadCards()
        await refreshAgents()
    }

    /// Starts one planned task for a round and says why it failed (nil on success). Unlike `confirmStart` it waits for the action in progress.
    func startInRound(_ plan: StartPlan, project id: String? = nil) async -> String? {
        guard !isBusy else { return "The panel is busy with another action; the round stops here." }
        if let why = await signInGate.ensure(tool(ofRole: plan.roleName)) { return why }
        guard !isBusy else { return "The panel is busy with another action; the round stops here." }
        guard let flow = makeFlow(project: id, role: plan.roleName) else { return startSetupReason(for: id) ?? usageHold(forRole: plan.roleName) ?? "actions are not available" }
        setActionState(.running("Starting \(plan.agentName)…"))
        var failure: String?
        do {
            let started = try await flow.start(plan, status: { [weak self] text in Task { @MainActor in self?.setActionState(.running(text)) } })
            setActionState(.done("Started \(started.agent) on \(plan.branch)."))
        } catch let error as StartError {
            failure = error.message
            setActionState(.failed(error.message))
        } catch {
            failure = error.localizedDescription
            setActionState(.failed(error.localizedDescription))
        }
        await reloadCards(of: id)
        await refreshAgents()
        return failure
    }

    /// Runs `scripts/check-conflicts.sh` on two cards; nil when they can run side by side, else what the script said.
    func conflictBetween(_ a: TaskCard, _ b: TaskCard, project id: String? = nil) async -> String? {
        guard let source = config(of: id)?.sourcePath else { return "the location of project.json is unknown" }
        do {
            let result = try await makeScripts(settings).run(.checkConflicts, arguments: [a.url.path, b.url.path, source])
            if result.status == 0 { return nil }
            let detail = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "the conflict check failed" : detail
        } catch {
            return "the conflict check could not run (\(StartTaskFlow.describe(error)))"
        }
    }

    /// Sends a command to an agent. `remember`: a message of the user, which may later back a PM request when it went to the project's PM.
    @discardableResult
    func sendCommand(_ text: String, to paneID: String, session: String?, remember: Bool = true) async -> ActionResult {
        guard !isBusy else { return .busy }
        setActionState(.running("Sending the command…"))
        let center = CommandCenter(adapter: makeTerminal(), commander: makeCommander(), log: actionLog)
        var result = ActionResult.ok
        do {
            try await center.send(text, to: paneID, expectingSession: session, project: selectedProjectID)
            if remember, let id = selectedProjectID, let session, case .available(let list) = agents,
               let target = list.first(where: { $0.paneID == paneID && $0.sessionID == session }), !runsOnCard(target, project: id), isInProjectFolder(target, project: id), pmOwner(ofSession: session, except: id) == nil { setPMSession(session, forProject: id) }
            if remember, let id = selectedProjectID, pmPane(forProject: id) == paneID { startRequests.noteCommand(text, to: paneID, project: id) }
            if let id = selectedProjectID { defaults.set(session.map { "\(paneID)|\($0)" } ?? paneID, forKey: "commandTarget.\(id)") }
            setActionState(.done("Command sent."))
        } catch let error as BackendError {
            let message: String
            switch error {
            case .failed(let m): message = m == "agent is no longer running" ? "That agent is no longer running; pick another one." : m
            case .notRunning(let m): message = "the terminal is not running: \(m)"
            case .notInstalled: message = "the terminal is not installed"
            case .badOutput: message = "the terminal answered with output the panel cannot read"
            }
            setActionState(.failed(message)); result = .failed(message)
        } catch {
            setActionState(.failed(error.localizedDescription)); result = .failed(error.localizedDescription)
        }
        await refreshAgents()
        return result
    }

    static let nudgeText = "Your last turn ended before the task was finished. Re-read the card and continue from where you stopped."

    /// "Nudge to continue" on a stopped agent's card: one prompt per click (a click while it is being sent does nothing); once it is
    /// sent the warning goes away and the 5 minutes start again.
    func nudge(_ agent: AgentStatus) async {
        guard !nudging.contains(agent.paneID) else { return }
        nudging.insert(agent.paneID)
        defer { nudging.remove(agent.paneID) }
        let result = await sendCommand(Self.nudgeText, to: agent.paneID, session: agent.sessionID, remember: false)
        if result == .ok, let card = card(of: agent) { stopped.reset(Self.stoppedKey(card, agent), now: now()) }
    }

    func clearActionState() {
        if case .running = actionState { return }
        setActionState(.idle)
    }

    /// How long a done line ("Started …", "Command sent.") stays under the chat (N303).
    nonisolated static let doneLineTime: Duration = .seconds(10)

    /// Clears a done line, only that one when `message` is given; a failed line stays until the next action.
    func clearDoneLine(_ message: String? = nil) {
        guard case .done(let shown) = actionState, message == nil || message == shown else { return }
        setActionState(.idle)
    }
}
