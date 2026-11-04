import Foundation

/// The project's PM session as the PM tab shows it.
enum PMStatus: Equatable {
    case running, idle, missing

    /// Working or waiting on a prompt counts as running; an idle, finished or unknown session as idle; no session as missing.
    init(agent: AgentStatus?) {
        switch agent?.state {
        case nil: self = .missing
        case .working, .blocked: self = .running
        case .idle, .done, .unknown: self = .idle
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .missing: "Not running"
        }
    }
}

/// Starting and stopping the project's PM from the app: a `pm` session on no card, in the project folder.
extension PanelModel {
    var pmStatus: PMStatus { PMStatus(agent: selectedProjectID.flatMap { pmAgent(forProject: $0) }) }

    /// Whether the panel offers Stop for this agent: only a session that runs on no card (a task agent stops with its card).
    func canStop(_ agent: AgentStatus) -> Bool {
        guard let id = selectedProjectID else { return false }
        return !runsOnCard(agent, project: id)
    }

    /// Starts the `pm` role on no card. Does nothing while a PM runs or another action is in progress.
    func startPM() async {
        guard pmStatus == .missing else { return }
        await spawnPM()
    }

    /// Start a PM here: a new `pm` session in the project folder, chosen as the project's PM in place of one that runs elsewhere.
    /// It sends no prompt.
    func startPMHere() async {
        guard pmStatus == .missing || pmOutsideFolder != nil else { return }
        await spawnPM()
    }

    /// After a project is added with "Start the PM": starts the PM and, once it is idle, sends the onboarding prompt built from the probe.
    /// A PM that is not idle within `attempts` checks leaves the prompt in `pendingOnboarding` for the Chat button.
    func startPMWithOnboarding(probe: ProjectProbe, attempts: Int = 40, pause: Duration = .milliseconds(1500)) async {
        await startPM()
        guard let project = selectedProject else { return }
        let policy = autopilot.policy
        let text = OnboardingPrompt.build(name: project.name, repoPath: project.repoPath, dataDir: project.dataDir, probe: probe, runBuildAndTest: policy.runBuildAndTest)
        pendingOnboarding[project.id] = text
        for attempt in 0..<attempts {
            if pmStatus == .idle, selectedProjectID == project.id { await sendOnboarding(); return }
            if attempt < attempts - 1 { try? await Task.sleep(for: pause); await refreshAgents() }
        }
    }

    /// Sends the waiting onboarding prompt to the selected project's PM (the Chat button, or right after the PM became idle).
    func sendOnboarding() async {
        guard let id = selectedProjectID, let text = pendingOnboarding[id], let pane = pmPane(forProject: id) else { return }
        pendingOnboarding[id] = nil
        await tellPM(pane: pane, text)
    }

    /// `resume`: the session id of the PM's last conversation; the PM then continues it (`spawn-agent.sh --resume`).
    func spawnPM(resume: String? = nil) async {
        guard !isBusy else { return }
        guard let project = selectedProject, startSetupReason == nil, let source = project.sourcePath else { setActionState(.failed(startSetupReason ?? "actions are not available")); return }
        if let why = await signInGate.ensure(pmTool(of: project.id)) { setActionState(.failed(why)); return }
        guard !isBusy else { return }
        let found = roleStore.resolve("pm", in: project)
        guard let role = found.role else { setActionState(.failed("No role called \"pm\" is defined (looked in: \(found.searched.joined(separator: "; "))).")); return }
        guard role.config.kind == "interactive" else { setActionState(.failed("The role \"pm\" is headless; the panel starts only interactive roles.")); return }
        setActionState(.running(resume == nil ? "Starting the PM…" : "Resuming the PM…"))
        do {
            try await terminalServer.ensureRunning(onStarting: { [weak self] in Task { @MainActor in self?.setActionState(.running("Starting the terminal…")) } })
            setActionState(.running(resume == nil ? "Starting the PM…" : "Resuming the PM…"))
            // The PM's session key travels in its process environment; only this spawn gets it, never a task agent's.
            let key = commandMemory.newKeyForSpawn(project: project.id)
            let result = try await makeScripts(settings).run(.spawn, arguments: (resume.map { ["--resume", $0] } ?? []) + ["--no-card", source, role.fileURL.path], environment: ["TENTACL_PM_KEY": key])
            if result.status == 0 {
                if let pane = Self.startedPane(in: result.stdout) { commandMemory.bindKey(project: project.id, pane: pane) }
                let verb = resume == nil ? "Started" : "Resumed"
                setActionState(.done("\(verb) the PM."))
                if resume != nil, let id = selectedProjectID { actionLog.append("resume pm", project: id) }
                await refreshAgents()
                chooseStartedPM(from: result.stdout)
            } else {
                commandMemory.dropPendingKey(project: project.id)
                setActionState(.failed(Self.reason(result, fallback: "spawn-agent.sh exited with status \(result.status)")))
            }
        } catch {
            commandMemory.dropPendingKey(project: project.id)
            setActionState(.failed(StartTaskFlow.describe(error)))
        }
        await refreshAgents()
    }

    private static func startedPane(in output: String) -> String? {
        output.split(separator: "\n").lazy.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["pane_id"] as? String
        }.first
    }

    /// Chooses the session spawn-agent.sh just started (its `pane_id`) as the selected project's PM; without a session id yet, forgets a
    /// choice outside the folder so the title fallback finds the new one.
    private func chooseStartedPM(from output: String) {
        guard let id = selectedProjectID, case .available(let list) = agents else { return }
        let pane = Self.startedPane(in: output)
        if let pane, let started = list.first(where: { $0.paneID == pane }), isInProjectFolder(started, project: id), let session = started.sessionID {
            setPMSession(session, forProject: id)
        } else if let pm = pmAgent(forProject: id), !isInProjectFolder(pm, project: id) {
            setPMSession(nil, forProject: id)
        }
    }

    /// Stop asks first: this only remembers which session; `confirmStop` stops it.
    func requestStop(_ agent: AgentStatus) { if canStop(agent) { pendingStop = agent } }
    func cancelStop() { pendingStop = nil }

    /// Closes the workspace of the session the user confirmed (`stop-agent.sh`; the project folder is never touched).
    func confirmStop() async { if let agent = pendingStop { await stop(agent) } }

    /// Takes the agent itself: the dialog clears `pendingStop` as it closes, before a Task started from its button would read it.
    func stop(_ agent: AgentStatus) async {
        pendingStop = nil
        guard !isBusy else { return }
        let name = agent.name ?? agent.title
        setActionState(.running("Stopping \(name)…"))
        do {
            let result = try await makeScripts(settings).run(.stop, arguments: [name, agent.cwd, "--no-sim"])
            if result.status == 0 || result.status == 4 {
                setActionState(.done("Stopped \(name)."))
            } else {
                setActionState(.failed(Self.reason(result, fallback: "stop-agent.sh exited with status \(result.status)")))
            }
        } catch {
            setActionState(.failed(StartTaskFlow.describe(error)))
        }
        await refreshAgents()
    }

    /// Open terminal: shows the agent's tab on the Terminals screen.
    func openTerminal(_ agent: AgentStatus) async { openTerminalTab(agent.paneID) }

    private static func reason(_ result: ScriptResult, fallback: String) -> String {
        [result.stderr, result.stdout].map { TerminalMessage.plain($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.first { !$0.isEmpty } ?? fallback
    }
}
