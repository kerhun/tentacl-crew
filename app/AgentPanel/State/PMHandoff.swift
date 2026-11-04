import Foundation

enum RestartMode: CaseIterable, Equatable {
    case handoff, clear, compact

    var title: String {
        switch self {
        case .handoff: "With hand-off (recommended)"
        case .clear: "Without hand-off"
        case .compact: "Compact"
        }
    }

    var detail: String {
        switch self {
        case .handoff: "The agent writes a short note first (what it is doing, open decisions, next steps, who waits for what), then the conversation is cleared and the new one reads the note."
        case .clear: "Clears the conversation (/clear). The agent starts empty and remembers nothing."
        case .compact: "Keeps one summarised conversation (/compact). The thread stays as it is."
        }
    }
}

/// Starts an agent on a fresh Claude conversation (or compacts the current one) from the Chat tab. Every step is an actions.log line.
/// The agent is checked the same way as for a command: it must be there, the same session, and idle (not working, not on a menu).
struct ConversationRestart {
    struct Timing {
        var poll: Duration = .milliseconds(500)
        /// How long the agent may take to write the hand-off.
        var handoff: Duration = .seconds(300)
        /// How long the pane may take to show the new session after /clear.
        var session: Duration = .seconds(30)
    }

    struct Failure: Error, Equatable { let message: String }

    let adapter: TerminalListing
    let commander: TerminalCommanding
    let log: ActionLog
    /// `<data folder>/pm-handoff.md`.
    let handoffFile: URL
    let project: String
    var timing = Timing()

    var handoffRequest: String {
        "Please write a short hand-off note to \(handoffFile.path) so a fresh conversation can take over: what you are doing, open decisions, the next steps, and who is waiting for what. Write the file, then stop."
    }
    var firstPrompt: String { "Read \(handoffFile.path) and your project's roadmap, then continue as the PM." }

    /// Returns the pane's new session id after /clear (nil for Compact: the session stays).
    func run(_ mode: RestartMode, pane: String, session: String?, progress: (String) -> Void) async throws -> String? {
        try await requireIdle(pane: pane, session: session)
        switch mode {
        case .compact:
            progress("Compacting the conversation…")
            try await send("/compact", to: pane)
            log.append("conversation compacted pane=\(pane)", project: project)
            return nil
        case .clear:
            return try await clearAndWait(pane: pane, session: session, progress: progress)
        case .handoff:
            try await writeHandoff(pane: pane, session: session, progress: progress)
            let new = try await clearAndWait(pane: pane, session: session, progress: progress)
            if let new { try await requireIdle(pane: pane, session: new, wait: timing.session) }
            progress("Starting the new conversation…")
            try await send(firstPrompt, to: pane)
            log.append("new conversation started pane=\(pane) session=\(new ?? "?")", project: project)
            return new
        }
    }

    /// Asks the agent for the hand-off note and waits until it is written and the agent is idle again.
    func writeHandoff(pane: String, session: String?, progress: (String) -> Void) async throws {
        progress("Asking the agent for a hand-off note…")
        let before = Self.stamp(handoffFile)
        try await send(handoffRequest, to: pane)
        log.append("hand-off requested pane=\(pane) file=\(handoffFile.path)", project: project)
        try await waitForHandoff(pane: pane, session: session, before: before)
        log.append("hand-off written \(handoffFile.path)", project: project)
    }

    private func clearAndWait(pane: String, session: String?, progress: (String) -> Void) async throws -> String? {
        progress("Clearing the conversation…")
        try await send("/clear", to: pane)
        log.append("conversation cleared pane=\(pane)", project: project)
        progress("Waiting for the new conversation…")
        let deadline = ContinuousClock.now + timing.session
        while ContinuousClock.now < deadline {
            if let found = try await adapter.agents().first(where: { $0.paneID == pane }), let now = found.sessionID, !now.isEmpty, now != session {
                return now
            }
            try await Task.sleep(for: timing.poll)
        }
        throw Failure(message: "The new conversation did not start in time; check the agent's pane.")
    }

    private func waitForHandoff(pane: String, session: String?, before: Stamp?) async throws {
        let deadline = ContinuousClock.now + timing.handoff
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: timing.poll)
            guard let agent = try await adapter.agents().first(where: { $0.paneID == pane && ($0.sessionID == session || session == nil) }) else {
                throw Failure(message: "The agent is no longer running.")
            }
            if Self.stamp(handoffFile) != before, agent.state == .idle || agent.state == .done { return }
        }
        throw Failure(message: "The agent did not write the hand-off note in time; nothing was cleared.")
    }

    func requireIdle(pane: String, session: String?, wait: Duration? = nil) async throws {
        let deadline = ContinuousClock.now + (wait ?? .zero)
        while true {
            guard let agent = try await adapter.agents().first(where: { $0.paneID == pane && (session == nil || $0.sessionID == session) }) else {
                throw Failure(message: "The agent is no longer running.")
            }
            switch agent.state {
            case .idle, .done: return
            case .working, .unknown:
                if ContinuousClock.now >= deadline { throw Failure(message: "The agent is working; try again when it is idle.") }
            case .blocked:
                if ContinuousClock.now >= deadline { throw Failure(message: "The agent is waiting on a prompt; answer it first.") }
            }
            try await Task.sleep(for: timing.poll)
        }
    }

    func send(_ text: String, to pane: String) async throws {
        do { try await commander.prompt(target: pane, text: text) }
        catch let error as BackendError {
            if case .failed(let m) = error { throw Failure(message: m) }
            throw Failure(message: "the terminal could not be reached")
        }
    }

    struct Stamp: Equatable { let modified: Date?; let size: Int }
    static func stamp(_ url: URL) -> Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(modified: a[.modificationDate] as? Date, size: (a[.size] as? Int) ?? 0)
    }
}

extension PanelModel {
    /// The agent can be restarted from the Chat tab when it runs on no card (the PM, or another agent the user started by hand).
    func canRestartConversation(_ agent: AgentStatus, project id: String? = nil) -> Bool {
        guard let id = id ?? selectedProjectID else { return false }
        return !runsOnCard(agent, project: id)
    }

    /// Hand-off, clear or compact for one agent. After /clear the PM session and the Command box target move to the pane's new session,
    /// and the old thread is kept as the previous conversation.
    @discardableResult
    func restartConversation(_ mode: RestartMode, agent: AgentStatus, project projectID: String? = nil) async -> ActionResult {
        guard !isBusy else { return .busy }
        guard let project = config(of: projectID) else { return .failed("No project selected.") }
        let id = project.id
        guard canRestartConversation(agent, project: id) else { return .failed("An agent on a task card is restarted with its card.") }
        restartedSession = nil
        let flow = ConversationRestart(adapter: makeTerminal(), commander: makeCommander(), log: actionLog,
                                       handoffFile: project.dataURL.appendingPathComponent("pm-handoff.md"), project: id, timing: restartTiming)
        let thread = chats.session(project: id, pane: agent.paneID)
        let oldThread = thread.chat.entries
        let wasPM = pmSession(forProject: id) == agent.sessionID || pmPane(forProject: id) == agent.paneID
        restartingPane = agent.paneID
        defer { restartingPane = nil }
        if wasPM, pmTool(of: id) == .codex { return await restartCodexPM(mode, agent: agent, project: id, flow: flow, thread: thread, oldThread: oldThread) }
        var result = ActionResult.ok
        do {
            let new = try await flow.run(mode, pane: agent.paneID, session: agent.sessionID) { [self] in setActionState(.running($0)) }
            if let new {
                if wasPM { setPMSession(new, forProject: id) }
                defaults.set("\(agent.paneID)|\(new)", forKey: "commandTarget.\(id)")
                thread.startNewThread(keeping: oldThread)
                restartedSession = new
            }
            setActionState(.done(mode == .compact ? "Conversation compacted." : "Started a new conversation."))
        } catch let failure as ConversationRestart.Failure {
            setActionState(.failed(failure.message)); result = .failed(failure.message)
        } catch {
            setActionState(.failed(error.localizedDescription)); result = .failed(error.localizedDescription)
        }
        await refreshAgents()
        return result
    }
}

extension PanelModel {
    /// The ways to restart this agent: a Codex PM has no Compact (first release).
    func restartModes(for agent: AgentStatus) -> [RestartMode] {
        let codexPM = selectedProjectID.map { pmTool(of: $0) == .codex && (pmSession(forProject: $0) == agent.sessionID || pmPane(forProject: $0) == agent.paneID) } ?? false
        return codexPM ? RestartMode.allCases.filter { $0 != .compact } : RestartMode.allCases
    }

    /// A Codex PM is restarted, not typed at: its hand-off is written, the PM is stopped and spawned again (`--no-card`), and the new one
    /// gets the hand-off file as its first prompt. The new session id is the newest rollout of the PM's folder.
    private func restartCodexPM(_ mode: RestartMode, agent: AgentStatus, project id: String, flow: ConversationRestart, thread: ChatSession, oldThread: [ChatEntry]) async -> ActionResult {
        func fail(_ message: String) async -> ActionResult { setActionState(.failed(message)); await refreshAgents(); return .failed(message) }
        guard mode != .compact else { return await fail("A Codex PM cannot be compacted; start a new conversation instead.") }
        do {
            setActionState(.running("Restarting the PM…"))
            try await flow.requireIdle(pane: agent.paneID, session: agent.sessionID)
            if mode == .handoff { try await flow.writeHandoff(pane: agent.paneID, session: agent.sessionID) { [self] in setActionState(.running($0)) } }
            setActionState(.idle)   // stop and spawn refuse to start while an action runs
            await stop(agent)
            guard case .done = actionState else { return await fail("The PM could not be stopped: \(actionStateMessage)") }
            await spawnPM()
            guard case .done = actionState else { return await fail("The new PM did not start: \(actionStateMessage)") }
            guard let pm = pmAgent(forProject: id) else { return await fail("The new PM was not found.") }
            if mode == .handoff {
                try await flow.requireIdle(pane: pm.paneID, session: nil, wait: flow.timing.session)
                try await flow.send(flow.firstPrompt, to: pm.paneID)
            }
            let deadline = ContinuousClock.now + flow.timing.session
            var new = pm.sessionID.flatMap { $0 == agent.sessionID ? nil : $0 }
            while new == nil, ContinuousClock.now < deadline {
                let id = CodexSessionReader.sessions(root: codexSessionsRoot, cwd: pm.cwd).first.flatMap { CodexSessionReader.meta($0)?.id }
                if let id, id != agent.sessionID { new = id } else { try await Task.sleep(for: flow.timing.poll) }
            }
            if let new { setPMSession(new, forProject: id) }
            defaults.set("\(pm.paneID)|\(new ?? "")", forKey: "commandTarget.\(id)")
            thread.startNewThread(keeping: oldThread)
            restartedSession = new
            flow.log.append("new codex PM conversation pane=\(pm.paneID) session=\(new ?? "?")", project: id)
            setActionState(.done("Started a new conversation."))
        } catch let failure as ConversationRestart.Failure {
            return await fail(failure.message)
        } catch {
            return await fail(error.localizedDescription)
        }
        await refreshAgents()
        return .ok
    }

    private var actionStateMessage: String {
        switch actionState { case .failed(let m), .done(let m), .running(let m): m; case .idle: "unknown error" }
    }
}

// MARK: fresh conversation with hand-off (N171)

/// Why the PM is due a fresh conversation.
enum FreshStartTrigger: String, Equatable {
    case roundStart, roundFinished, safePoint

    var text: String {
        switch self {
        case .roundStart: "a new round started"
        case .roundFinished: "a round is finished"
        case .safePoint: "the safe point is reached"
        }
    }
}

/// The rules for restarting the PM by itself (pure, so they can be tested without a PM).
enum FreshStart {
    enum Block: Equatable {
        /// Not now: keep the trigger and ask again at the next poll.
        case wait
        /// Never (rule off, no PM): forget the trigger.
        case never
    }

    /// Why the PM may not be restarted now; nil when it may. The PM is idle while a merge it started (pm-chain.sh → pm-serial-merge.sh) runs
    /// in the background, so a running merge process blocks too: /clear would drop its result.
    static func blocker(ruleOn: Bool, pm: AgentStatus?, hasQuestion: Bool, busy: Bool, mergeRunning: Bool) -> Block? {
        guard ruleOn, let pm else { return .never }
        guard pm.state == .idle || pm.state == .done, !hasQuestion, !busy, !mergeRunning else { return .wait }
        return nil
    }

    /// Plan rounds whose every card is done (cancelled cards do not count; a round with no done card, or with a card the panel does not know, is not finished).
    static func finishedRounds(plan: PlanFile?, cards: [TaskCard]) -> Set<String> {
        guard let plan else { return [] }
        let status = Dictionary(cards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        return Set(plan.rounds.filter { round in
            let live = round.cards.filter { status[$0] != .cancelled }
            return !live.isEmpty && live.allSatisfy { status[$0] == .done }
        }.map(\.name))
    }

    /// Whether `pgrep -fl pm-serial-merge.sh` output names a merge of this project: a line with the project's data folder or repo,
    /// or a line that names no known project at all (it could be this one, so waiting is the safe answer).
    static func mergeRunning(output: String, ownPaths: [String], allPaths: [String]) -> Bool {
        output.split(separator: "\n").contains { line in
            let l = String(line)
            return ownPaths.contains { l.contains($0) } || !allPaths.contains { l.contains($0) }
        }
    }

    /// 1M tokens for the 5.x Opus and Sonnet (and any `[1m]` model), 200k for the rest.
    static func contextWindow(model: String) -> Int {
        let m = model.lowercased()
        if m.contains("[1m]") || m.contains("opus-5") || m.contains("sonnet-5") || m.contains("fable-5") { return 1_000_000 }
        return 200_000
    }

    /// How full a Codex session is: the last `token_count`'s last-turn tokens over its `model_context_window`; nil when unknown.
    static func codexContextFraction(_ url: URL, tail: Int = 1_000_000) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let p = obj["payload"] as? [String: Any],
                  p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any], let tokens = last["total_tokens"] as? Int ?? last["input_tokens"] as? Int,
                  let window = info["model_context_window"] as? Int, window > 0 else { continue }
            return Double(tokens) / Double(window)
        }
        return nil
    }

    /// The share of the context window at which the chat reminds the user. 70%: the conversation is re-read on every turn, and the
    /// hand-off still has room to be written; nothing restarts by itself because of size.
    static let reminderThreshold = 0.7
    static func shouldRemind(fraction: Double?) -> Bool { fraction.map { $0 >= reminderThreshold } ?? false }
}

extension PanelModel {
    var pmContextLarge: Bool { FreshStart.shouldRemind(fraction: pmContextFraction) }

    /// A moment that is due a fresh PM conversation of a project (the open one when `id` is nil); it happens at once when the PM may be
    /// restarted, else at the first poll when it may.
    func freshStartRequested(_ trigger: FreshStartTrigger, project id: String? = nil) {
        let watch = id.flatMap { watches[$0] } ?? selectedWatch
        guard watch.autopilot.policy.freshConversation else { return }
        if watch.freshPending == nil { watch.freshPending = trigger }
        Task { await evaluateFreshStart() }
    }

    /// For every project: notices round-finished and safe-point moments, then restarts its PM with hand-off if one is pending and the PM may be restarted.
    func evaluateFreshStart() async {
        for project in projects {
            guard !freshStartRunning, let watch = watches[project.id] else { return }
            await evaluateFreshStart(project, watch)
        }
    }

    private func evaluateFreshStart(_ project: ProjectConfig, _ watch: ProjectWatch) async {
        let id = project.id
        noteFreshStartTriggers(project: id, watch)
        guard let trigger = watch.freshPending else { return }
        let pm = pmAgent(forProject: id)
        let question = watch.inbox.questions.contains { $0.isPM && ($0.paneID == pm?.paneID) }
        let rule = watch.autopilot.policy.freshConversation
        let merging = rule && pm != nil ? await mergeIsRunning(project: id, pending: watch.freshPending != nil) : false
        switch FreshStart.blocker(ruleOn: rule, pm: pm, hasQuestion: question, busy: isBusy, mergeRunning: merging) {
        case .never: watch.freshPending = nil
        case .wait: break
        case nil:
            guard let pm else { return }
            watch.freshPending = nil
            freshStartRunning = true
            defer { freshStartRunning = false }
            actionLog.append("fresh PM conversation with hand-off: \(trigger.text)", project: id)
            await restartConversation(.handoff, agent: pm, project: id)
        }
    }

    /// A `pm-serial-merge.sh` process of this project runs (`pgrep -fl`; no match makes pgrep fail, which means none).
    private func mergeIsRunning(project id: String, pending: Bool) async -> Bool {
        guard pending else { return false }
        if mergeQueue.isRunning(project: id) || (!Self.runsUnderXCTest && MergeQueue.scriptLockHeld()) { return true }
        guard let out = try? await mergeRunner.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-fl", "pm-serial-merge.sh"]) else { return false }
        let own = projects.filter { $0.id == id }.flatMap { [$0.dataDir, $0.repoPath] }
        let all = projects.flatMap { [$0.dataDir, $0.repoPath] }
        return FreshStart.mergeRunning(output: String(decoding: out, as: UTF8.self), ownPaths: own, allPaths: all)
    }

    private func noteFreshStartTriggers(project id: String, _ watch: ProjectWatch) {
        let all = taskCards(of: id)
        // The open project's plan is read with its cards; a closed project's is read here, only while its rule is on.
        let plan: PlanFile?
        if id == selectedProjectID { plan = round.currentPlan }
        else if watch.autopilot.policy.freshConversation, let project = config(of: id), case .plan(let file) = PlanReader.load(dataDir: project.dataURL) { plan = file; watch.plan = file }
        else { plan = watch.plan }
        guard !all.isEmpty, let plan else { return }
        // A card in review has no agent working any more; only doing and needs-fix cards run.
        let running = all.contains { $0.status == .doing || $0.status == .needsFix }
        let rule = watch.autopilot.policy.freshConversation
        let finished = FreshStart.finishedRounds(plan: plan, cards: all)
        // The first look only records what is finished already, so opening the app never restarts the PM.
        if let seen = freshFinishedSeen[id] {
            let new = finished.subtracting(seen)
            if !new.isEmpty, !running {
                freshFinishedSeen[id] = seen.union(new)
                if rule, watch.freshPending == nil { watch.freshPending = .roundFinished }
            }
        } else {
            freshFinishedSeen[id] = finished
        }
        if safePointReached {
            if !watch.freshSafePointFired, !running {
                watch.freshSafePointFired = true
                if rule, watch.freshPending == nil { watch.freshPending = .safePoint }
            }
        } else {
            watch.freshSafePointFired = false
        }
    }

    /// Reads how full the PM's conversation is from its session file (the end of the file only).
    func refreshPMContext() async {
        var fraction: Double?
        if let id = selectedProjectID, pmTool(of: id) == .codex, let pm = pmAgent(forProject: id) {
            let root = codexSessionsRoot
            fraction = await Task.detached(priority: .utility) { CodexSessionReader.find(root: root, sessionID: pm.sessionID, cwd: pm.cwd).flatMap { FreshStart.codexContextFraction($0) } }.value
        } else if let id = selectedProjectID, let pm = pmAgent(forProject: id), let session = pm.sessionID {
            let url = TranscriptReader.path(projectsRoot: claudeProjectsRoot, cwd: pm.cwd, session: session)
            fraction = await Task.detached(priority: .utility) { CostReader.contextUse(url)?.fraction }.value
        }
        if fraction != pmContextFraction { pmContextFraction = fraction }
    }
}

/// The Command box's chosen agent across session changes (N292). A /clear typed in the terminal gives the pane a new session,
/// and an agent chosen before its first hook ran has no session yet: both are still the same agent, and the header's
/// "New conversation…" and the PM context reminder need it resolved.
enum ChosenAgent {
    /// The chosen agent among the polled ones: same pane, and the same session when one was known.
    static func resolve(_ chosen: ChosenTarget?, in agents: [AgentStatus]) -> AgentStatus? {
        guard let chosen else { return nil }
        return agents.first { $0.paneID == chosen.paneID && (chosen.sessionID == nil || $0.sessionID == chosen.sessionID) }
    }

    /// The target to keep after a poll when its pane now shows another (or a first) session: a first session is always taken;
    /// a changed one only when `follows` says it is the same agent (one on no card, or one the panel is restarting). nil: nothing to follow.
    static func followed(_ chosen: ChosenTarget, in agents: [AgentStatus], follows: (AgentStatus) -> Bool) -> ChosenTarget? {
        guard let now = agents.first(where: { $0.paneID == chosen.paneID }), let session = now.sessionID, session != chosen.sessionID,
              chosen.sessionID == nil || follows(now) else { return nil }
        return ChosenTarget(paneID: chosen.paneID, sessionID: session, label: chosen.label)
    }
}
