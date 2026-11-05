import Foundation
import Observation
import AppKit

enum AgentsState: Equatable {
    case loading
    case available([AgentStatus])
    case unavailable(String)
}

/// The panel's state: projects, the selected project's cards and the live agents. Read-only in phase 1.
@Observable @MainActor
final class PanelModel {
    private(set) var projects: [ProjectConfig] = []
    private(set) var problems: [String] = []
    private(set) var selectedProjectID: String?
    private(set) var cards: [CardLoadResult] = [] {
        didSet { taskCardsCache = nil; dependencyGraphCache = nil }
    }
    /// The cards that loaded, in order: views and lookups ask for them many times per draw, so they are filtered out of `cards` once per load.
    @ObservationIgnored private var taskCardsCache: [TaskCard]?
    @ObservationIgnored var dependencyGraphCache: DependencyGraph?
    var selectedTaskCards: [TaskCard] {
        if let taskCardsCache { return taskCardsCache }
        let loaded = cards.compactMap { result -> TaskCard? in if case .card(let c) = result { return c } else { return nil } }
        taskCardsCache = loaded
        return loaded
    }
    var selectedCardID: String? {
        didSet { if selectedCardID != oldValue { saveOpenCard() } }
    }
    /// The project whose saved open card is put back once its cards are loaded (N260); nothing is saved for it until then.
    @ObservationIgnored var cardRestore: String?
    /// The Command box's threads and drafts, per project and target agent; they live here so leaving the box does not lose them.
    let chats = ChatStore()
    /// The quote waiting in each chat's input (N292), by "project|pane".
    var chatQuotes = ChatQuotes()
    private(set) var agents: AgentsState = .loading
    /// Which agents have had a turn since they were started (see `TaskPhase`).
    private(set) var turns = TurnTracker()
    /// The Report each needs-fix card of the selected project had when it was first seen in that state (see `TaskPhase`); every project keeps its own.
    var fixReports: FixReportTracker { selectedWatch.fixReports }
    /// Since when each running task's agent has looked stopped (see `StoppedInput`).
    var stopped = StoppedTracker()
    /// The last line each task agent wrote in its session, by `pane|session` (see `PanelModel+AgentCards`).
    var lastActions: [String: String] = [:]
    /// When each running card's agent started and what it cost today, by card id; read at most once a minute.
    var cardFacts: [String: AgentCardFacts] = [:]
    @ObservationIgnored var cardFactsReadAt: Date?
    @ObservationIgnored var cardFactsLoading = false
    @ObservationIgnored var transcripts: [String: SessionTranscript] = [:]
    /// The panes a nudge is being sent to, so a double click sends it once.
    var nudging: Set<String> = []
    /// Claude Code's session files; tests point it at a temporary folder.
    @ObservationIgnored var pmAgentCache: (key: PMAgentKey, agent: AgentStatus?)?
    @ObservationIgnored var logEventsCache: (stamp: LogStamp, events: [ActionLogEvent])?
    @ObservationIgnored var claudeProjectsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    @ObservationIgnored var codexSessionsRoot = CodexSessionReader.defaultRoot
    @ObservationIgnored var now: () -> Date = { Date() }
    private(set) var settings = AppSettings(scriptsDir: nil, problems: [])
    private(set) var actionState: ActionState = .idle
    /// The agent the user asked to stop and has not yet confirmed (see `requestStop`).
    var pendingStop: AgentStatus?
    /// Per project: the onboarding prompt the PM did not take in time; the Chat offers to send it.
    var pendingOnboarding: [String: String] = [:]
    /// A "use this agent as the PM" choice that takes the agent from another project; waits for the user's confirmation.
    var pendingPMChoice: PMChoice?
    /// The pane whose conversation is being restarted: the Command box follows it to its new session instead of calling it gone.
    var restartingPane: String?
    /// The session the last restart ended on (nil after Compact or a failure).
    var restartedSession: String?
    @ObservationIgnored var restartTiming = ConversationRestart.Timing()
    /// Why the selected project's PM is due a fresh conversation with hand-off; kept until the PM may be restarted (idle, no open question) or the rule is off (N171).
    /// Every project keeps its own (`ProjectWatch.freshPending`).
    var freshStartPending: FreshStartTrigger? {
        get { selectedWatch.freshPending }
        set { selectedWatch.freshPending = newValue }
    }
    /// Share of the PM's context window in use (nil: unknown, or no PM).
    var pmContextFraction: Double?
    /// The Codex models, for the Codex decider's default (only read while Claude is not signed in).
    @ObservationIgnored let decisionCodexCatalog = CodexModelCatalog()
    @ObservationIgnored var freshFinishedSeen: [String: Set<String>] = [:]
    @ObservationIgnored var freshStartRunning = false
    /// The fresh-start check the agent poll started; the poll does not wait for it (a hand-off waits for the PM for minutes).
    @ObservationIgnored private var freshStartCheck: Task<Void, Never>?
    /// Runs `pgrep` to see whether a PM merge (pm-serial-merge.sh) is running.
    @ObservationIgnored var mergeRunner: CommandRunner = ProcessRunner(timeout: 5)
    /// Every merge the panel does goes through this queue: one at a time (N209).
    let mergeQueue = MergeQueue(lockRoot: PanelModel.runsUnderXCTest ? nil : MergeQueue.defaultBuildRoot)
    /// Set when Prepare review failed because the agent left uncommitted work: who to ask, and the session that was there then.
    private(set) var commitAsk: CommitAsk?

    /// Claude Code's trust list; nil in tests so they do not depend on the user's own configuration.
    @ObservationIgnored let claudeTrust: ClaudeTrust?
    @ObservationIgnored private let setupProbes: SetupProbes
    @ObservationIgnored private let signInGateOverride: SignInGate?
    /// Claude / Codex signed in or not, for the start gate and the Sign in buttons (N329). Tests see "cannot tell" unless they pass a gate.
    @ObservationIgnored lazy var signInGate: SignInGate = signInGateOverride
        ?? (Self.runsUnderXCTest ? SignInGate(check: { _ in nil }, findTool: { _ in nil }, spawn: { _, _ in }, exitCode: { _ in nil }, open: { _ in })
                                 : .live(probes: setupProbes, open: { [unowned self] in openTerminalTab($0) }))
    /// "Initialize git" and "Push to GitHub" in Waiting for you (N163).
    @ObservationIgnored lazy var gitSetup: GitSuggestionModel = makeGitSetup()
    /// The first-run guide: checks what Tentacl needs on this Mac.
    @ObservationIgnored lazy var setup: SetupModel = SetupModel(
        probes: setupProbes,
        inputs: { [unowned self] in setupInputs },
        settingsURL: settingsURL, picker: OpenPanelFolderPicker(), roleBaseDir: roleStore.baseDir, defaults: defaults,
        onSettingsChanged: { [unowned self] in reloadProjects() })
    /// What the Setup checks need: Codex lines are required when some role (a project's PM included) uses Codex; the decider keeps Claude in the list.
    var setupInputs: SetupInputs {
        SetupInputs(scriptsDir: settings.scriptsDir, scriptsProblem: settings.problems.first, projects: projects, usesClaude: anyRoleUsesClaude, usesCodex: anyRoleUsesCodex)
    }
    @ObservationIgnored private let settingsURL: URL
    @ObservationIgnored let makeTerminal: @Sendable () -> TerminalListing
    @ObservationIgnored private let opener: URLOpening
    @ObservationIgnored private let loadCards: @Sendable (URL) async -> [CardLoadResult]
    @ObservationIgnored let makeScripts: (AppSettings) -> ScriptRunning
    /// Starts tentacld when it is not running, before a start runs the spawn script. The default never touches the real daemon (tests).
    @ObservationIgnored let terminalServer: TerminalServerEnsuring
    @ObservationIgnored let makeCommander: @Sendable () -> TerminalCommanding
    @ObservationIgnored let actionLog: ActionLog
    @ObservationIgnored let cardWriter: CardWriting
    @ObservationIgnored let defaults: UserDefaults
    /// The GitHub release check and in-app update (Settings → Version and updates).
    @ObservationIgnored lazy var update = UpdateModel.live(defaults: defaults)
    /// The look of every terminal (N235/N236), saved in `defaults`.
    @ObservationIgnored lazy var terminalAppearance = TerminalAppearanceStore(defaults: defaults)
    /// Unsent comments on the Changes tab's diff lines (N249), saved in `defaults`.
    @ObservationIgnored lazy var diffComments = DiffCommentStore(defaults: defaults)
    /// The Terminals screen's live sessions (N237): they outlive the screen's panes and tab switches.
    @ObservationIgnored lazy var liveTerminals: LiveTerminalStore = {
        let store = LiveTerminalStore(appearance: terminalAppearance)
        // A shell that ended is gone from tentacld at once: its tab goes with the next list, not five seconds later.
        store.onGone = { [weak self] _ in Task { await self?.refreshAgents() } }
        return store
    }()
    @ObservationIgnored let roleStore: RoleStore
    @ObservationIgnored private let seedsRoles: Bool
    @ObservationIgnored private let makePreviewScripts: (AppSettings, URL) -> ScriptRunning
    @ObservationIgnored let makeReader: @Sendable () -> TerminalReading
    @ObservationIgnored let makeKeySender: @Sendable () -> TerminalKeySending
    @ObservationIgnored private let autopilotStore: AutopilotStore?
    @ObservationIgnored private let makeDecider: ((AutopilotPolicy) -> PMDeciding)?
    /// One inbox and one autopilot per project, so every project is watched, not only the selected one.
    private(set) var watches: [String: ProjectWatch] = [:]
    /// Stands in while no project is selected.
    @ObservationIgnored private lazy var idleWatch: ProjectWatch = makeWatch(for: nil)
    var selectedWatch: ProjectWatch { selectedProjectID.flatMap { watches[$0] } ?? idleWatch }
    /// The agents that wait for an answer from the user (the selected project's).
    var inbox: AgentInboxModel { selectedWatch.inbox }
    /// The PM autopilot of the selected project: answers the questions its policy gives to the PM. Off without a settings folder (tests, demo).
    var autopilot: AutopilotModel { selectedWatch.autopilot }

    /// The project's config, or the selected project's when `id` is nil.
    func config(of id: String?) -> ProjectConfig? { id.map { id in projects.first { $0.id == id } } ?? selectedProject }
    /// The cards the project last loaded: the selected project's live list, the others' from their last poll.
    func taskCards(of id: String) -> [TaskCard] { id == selectedProjectID ? selectedTaskCards : (watches[id]?.taskCards ?? []) }
    func card(id: String, in project: String) -> TaskCard? { taskCards(of: project).first { $0.id == id } }

    /// Every project runs on its own: packets, fixes, rebases, the cost limit, PM notices and the PM hand-off do not wait for the project to be open.
    private func makeWatch(for project: ProjectConfig?) -> ProjectWatch {
        let inbox = AgentInboxModel(reader: makeReader(), keys: makeKeySender(), commander: makeCommander(), adapter: makeTerminal(), log: actionLog)
        inbox.openTerminal = { [weak self] pane in self?.openTerminalTab(pane) }
        inbox.signIn = { [weak self] tool in await self?.signIn(tool) }
        let m = makeDecider.map { AutopilotModel(inbox: inbox, store: autopilotStore, makeDecider: $0) } ?? AutopilotModel(inbox: inbox, store: autopilotStore)
        m.setProject(project)
        let id = project?.id
        m.sendFix = { [weak self] card in await PanelModel.failure(of: self) { await $0.passOnFix(card, project: id) } }
        m.isFinished = { [weak self] in self?.phase(of: $0, in: id) == .finished }
        m.isWorking = { [weak self] in self?.phase(of: $0, in: id) == .working }
        m.preparePacket = { [weak self] card in
            guard let self else { return .skipped }
            return await self.autoPrepareReview(card, project: id)
        }
        m.codexDecides = { [weak self] in
            // Claude known signed out or not installed AND Codex known signed in; anything unknown stays on Claude, as before. Codex is looked at only now.
            guard let gate = self?.signInGate, (gate.missing.contains(.claude) || gate.notInstalled.contains(.claude)) else { return false }
            guard gate.signedIn.contains(.codex) else { if !gate.missing.contains(.codex) { Task { await gate.refresh(.codex) } }; return false }
            if let catalog = self?.decisionCodexCatalog { Task { _ = await catalog.load() } }   // warms the default model for the next decision
            return true
        }
        m.codexDefaultModel = { [weak self] in self?.decisionCodexCatalog.cached?.models.first?.id ?? "" }
        m.requestFix = { [weak self] card, notes in await PanelModel.failure(of: self) { await $0.autoRequestFix(card, notes: notes, project: id) } }
        m.costToday = { [weak self] in
            guard let self, let id else { return nil }
            return StatsModel.todayCost(of: self, project: id)
        }
        m.behindMain = { [weak self] card in await self?.commitsBehindMain(card, project: id) }
        m.checkOnMain = { [weak self] card, tests in await self?.checkTestsOnMain(card, tests: tests, project: id) ?? .unavailable(reason: "the panel is gone") }
        m.rebaseNow = { [weak self] card in
            guard let self else { return .skipped }
            return await self.autoRebase(card, project: id)
        }
        return ProjectWatch(project: project ?? ProjectConfig(id: "", name: "", repoPath: "", dataDir: "", maxParallel: 0, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil), inbox: inbox, autopilot: m, pmNotice: PMNotice(told: project.flatMap { toldPM(project: $0.id) }))
    }

    /// What the PM was last told about each card of a project, kept across restarts (nil when nothing was told yet).
    private func toldPM(project id: String) -> [String: String]? {
        defaults.dictionary(forKey: "pmNoticeTold.\(id)") as? [String: String]
    }

    /// "Plan a round": the PM picks the next todo cards and one approval starts them.
    @ObservationIgnored lazy var round: RoundModel = makeRound(project: nil)

    /// A round model for a project: the one the Round sheet shows follows the selected project (`id` nil); a PM request for a project that is
    /// not open gets its own, bound to that project, which never shows a sheet.
    private func makeRound(project id: String?) -> RoundModel {
        let model = RoundModel(
        enabled: { [weak self] in self?.watch(of: id).autopilot.canPlanRound ?? false },
        cards: { [weak self] in self.map { $0.taskCards(of: id ?? $0.selectedProjectID ?? "") } ?? [] },
        maxParallel: { [weak self] in self?.config(of: id)?.maxParallel ?? 0 },
        projectName: { [weak self] in self?.config(of: id)?.name ?? "" },
        propose: { [weak self] request in
            guard let self else { throw PMDecisionError.failed("The panel is closing.") }
            return try await self.watch(of: id).autopilot.proposeRound(request)
        },
        planStart: { [weak self] card in self?.startPlan(for: card, project: id) ?? .failure(.invalid("the panel is closing")) },
        conflict: { [weak self] a, b in await self?.conflictBetween(a, b, project: id) },
        start: { [weak self] plan in await PanelModel.failure(of: self) { await $0.startInRound(plan, project: id) } },
        record: { [weak self] outcome in self?.watch(of: id).autopilot.recordRound(outcome) },
        projectID: { [weak self] in id ?? self?.selectedProjectID }, defaults: defaults,
        safePoint: { [weak self] in (self?.safePoint ?? SafePoint(percent: nil), self?.planUsage) }, safePointReason: { [weak self] in self?.safePointReason },
        codexUsage: { [weak self] in self.flatMap { $0.anyRoleUsesCodex ? $0.codexPlanUsage : nil } })
        model.onRoundStarted = { [weak self] in self?.freshStartRequested(.roundStart, project: id) }
        return model
    }
    func watch(of id: String?) -> ProjectWatch { id.flatMap { watches[$0] } ?? selectedWatch }
    /// The round model a PM request for `id` is carried out with: the Round sheet's own for the open project, a throwaway one for another.
    private func requestRound(for id: String) -> RoundModel { id == selectedProjectID ? round : makeRound(project: id) }
    /// The PM's requests to start tasks the user asked for in the Command box (`scripts/request-start.sh`).
    @ObservationIgnored lazy var startRequests: StartRequestHandler = StartRequestHandler(
        projects: { [weak self] in self?.projects.map(\.id) ?? [] }, selected: { [weak self] in self?.selectedProjectID },
        store: { [weak self] id in self?.projects.first { $0.id == id }.map { StartRequestStore(dataDir: $0.dataURL) } },
        mode: { [weak self] id in self?.watches[id]?.autopilot.policy.mode ?? .off },
        round: { [weak self] id in self?.requestRound(for: id) },
        pmPane: { [weak self] id in self?.pmPane(forProject: id) },
        tell: { [weak self] pane, text in await self?.tellPM(pane: pane, text) },
        record: { [weak self] id, outcome in self?.watches[id]?.autopilot.recordStart(outcome) },
        log: actionLog, memory: commandMemory,
        authority: { [weak self] id in self?.watches[id]?.autopilot.authority() ?? PMAuthority() }, card: { [weak self] project, id in self?.card(id: id, in: project) })
    /// The user's Command box messages to each project's PM, shared by start and approve requests.
    @ObservationIgnored let commandMemory = CommandMemory()
    /// The PM's requests to review and approve tasks (`scripts/request-approve.sh`).
    @ObservationIgnored lazy var approveRequests: ApproveRequestHandler = ApproveRequestHandler(
        projects: { [weak self] in self?.projects.map(\.id) ?? [] }, selected: { [weak self] in self?.selectedProjectID },
        store: { [weak self] id in self?.projects.first { $0.id == id }.map { StartRequestStore(approveDataDir: $0.dataURL) } },
        mode: { [weak self] id in self?.watches[id]?.autopilot.policy.mode ?? .off }, memory: commandMemory,
        card: { [weak self] project, id in self?.card(id: id, in: project) },
        phase: { [weak self] project, card in self?.phase(of: card, in: project) },
        ready: { [weak self] project in self.map { !$0.isBusy && (project != $0.selectedProjectID || (!$0.approvalSheetOpen && $0.approveSheetRequest == nil)) } ?? false },
        prepare: { [weak self] project, card in await PanelModel.failure(of: self) { await $0.prepareForRequest(card, project: project) } },
        plan: { [weak self] project, card in await self?.approvalPlan(for: card, project: project) ?? .failure(.invalid("The panel is closing.")) },
        approve: { [weak self] project, plan in await PanelModel.failure(of: self) { await $0.approveForRequest(plan, project: project) } },
        openSheet: { [weak self] card in self?.approveSheetRequest = card.id },
        pmPane: { [weak self] id in self?.pmPane(forProject: id) },
        tell: { [weak self] pane, text in await self?.tellPM(pane: pane, text) },
        record: { [weak self] id, outcome in self?.watches[id]?.autopilot.recordApprove(outcome) },
        log: actionLog, authority: { [weak self] id in self?.watches[id]?.autopilot.authority() ?? PMAuthority() })
    /// The PM's answers to agent questions the panel relayed (`scripts/answer-question.sh`, N279), and the QUESTION lines it sends the PM.
    @ObservationIgnored lazy var answerRequests: AnswerRequestHandler = AnswerRequestHandler(
        projects: { [weak self] in self?.projects.map(\.id) ?? [] },
        store: { [weak self] id in self?.projects.first { $0.id == id }.map { AnswerRequestStore(dataDir: $0.dataURL) } },
        inbox: { [weak self] id in self?.watches[id]?.inbox },
        pmPane: { [weak self] id in self?.pmPane(forProject: id) },
        tell: { [weak self] pane, text in await self?.tellPM(pane: pane, text) },
        memory: commandMemory, log: actionLog)
    /// The PM session of a project: among the project's agents that run on no card, the one chosen by the user (remembered by session),
    /// else the first titled "pm…" inside the project's repo. A session chosen as another project's PM is never this project's.
    func pmAgent(forProject id: String) -> AgentStatus? {
        guard let project = projects.first(where: { $0.id == id }), case .available(let list) = agents else { return nil }
        let cards = taskCards(of: id)
        let others = Set(projects.filter { $0.id != id }.compactMap { pmSession(forProject: $0.id) })
        // The Command box asks once per agent per draw, and the answer only changes with these inputs: remember the last one.
        let key = PMAgentKey(project: id, repo: project.repoPath, worktrees: project.worktreesURL.path, agents: list, branches: cards.map(\.branch),
                             others: others, chosen: pmSession(forProject: id))
        if let cached = pmAgentCache, cached.key == key { return cached.agent }
        let mine = TerminalShells.withoutUserShells(list).filter { $0.sessionID.map { !others.contains($0) } ?? true }
        let found = PMNotice.pmAgent(in: mine, cards: cards, worktrees: project.worktreesURL, repo: project.repoPath, chosenSession: key.chosen)
        pmAgentCache = (key, found)
        return found
    }
    struct PMAgentKey: Equatable {
        let project: String, repo: String, worktrees: String
        let agents: [AgentStatus]
        let branches: [String?]
        let others: Set<String>
        let chosen: String?
    }
    /// Whether an agent works in a worktree of one of the project's cards (so it is a task agent, never the PM).
    func runsOnCard(_ agent: AgentStatus, project id: String) -> Bool {
        guard let project = projects.first(where: { $0.id == id }) else { return false }
        return taskCards(of: id).contains { AgentInboxModel.runs(agent, in: $0, worktrees: project.worktreesURL) }
    }
    /// The project's PM session: the one the user chose (or the first message to a free agent made), nothing else.
    func pmSession(forProject id: String) -> String? { defaults.string(forKey: "pmSession.\(id)") }
    func pmPane(forProject id: String) -> String? { pmAgent(forProject: id)?.paneID }
    /// The "PM pane" choice of a project, remembered by session (nil forgets it).
    /// A PM session belongs to one project: remembering it for `id` takes it from every other project.
    func setPMSession(_ session: String?, forProject id: String) {
        if let session { for other in projects where other.id != id && pmSession(forProject: other.id) == session { defaults.removeObject(forKey: "pmSession.\(other.id)") } }
        defaults.set(session, forKey: "pmSession.\(id)")
    }
    /// The project another one's PM choice would take `session` from.
    func pmOwner(ofSession session: String?, except id: String) -> ProjectConfig? {
        guard let session else { return nil }
        return projects.first { $0.id != id && pmSession(forProject: $0.id) == session }
    }
    /// "Choose a running agent as PM…": at once when no other project uses it, else after the user confirms.
    func choosePM(_ agent: AgentStatus, forProject id: String) {
        guard !runsOnCard(agent, project: id), isInProjectFolder(agent, project: id) else { return }
        if let owner = pmOwner(ofSession: agent.sessionID, except: id) { pendingPMChoice = PMChoice(agent: agent, projectID: id, fromName: owner.name) }
        else { setPMSession(agent.sessionID, forProject: id) }
    }
    func confirmPMChoice() {
        guard let choice = pendingPMChoice else { return }
        pendingPMChoice = nil
        setPMSession(choice.agent.sessionID, forProject: choice.projectID)
    }
    func cancelPMChoice() { pendingPMChoice = nil }
    /// Whether the agent works in the project's folder (`repoPath` or inside it; paths standardized, symlinks resolved).
    func isInProjectFolder(_ agent: AgentStatus, project id: String) -> Bool {
        guard let project = projects.first(where: { $0.id == id }) else { return false }
        return !AgentPanel.agents([agent], belongingToRepo: project.repoPath).isEmpty
    }
    /// The running agents of the selected project that could be its PM: free of cards and inside the project's folder, so a PM's
    /// history and memory stay in its own project.
    var pmCandidates: [AgentStatus] {
        guard let id = selectedProjectID, case .available(let list) = agents else { return [] }
        return TerminalShells.withoutUserShells(list).filter { $0.sessionID != nil && isInProjectFolder($0, project: id) && !runsOnCard($0, project: id) }
    }
    /// The folder the selected project's PM runs in when that is not the project's folder (nil: it runs inside, or there is no PM).
    var pmOutsideFolder: String? {
        guard let id = selectedProjectID, let pm = pmAgent(forProject: id), !isInProjectFolder(pm, project: id) else { return nil }
        return ResolvedPaths.shared.resolved(pm.cwd)
    }

    /// The panel's lines to a busy PM, delivered in order when it is idle or done again.
    @ObservationIgnored let outbox = PanelOutbox()

    /// A panel line to a PM: queued in the outbox and shown in that PM's chat as pending; sent through the same checked send
    /// as the Command box, and only when that PM is idle or done.
    func tellPM(pane: String, _ text: String) async {
        let project = projects.first { pmPane(forProject: $0.id) == pane }?.id
        let item = outbox.add(text, pane: pane, project: project)
        if let project { chats.session(project: project, pane: pane).chat.addPending(text, kind: .panel, id: item.id) }
        await deliverOutbox()
    }

    /// Sends what the outbox holds to the agents that can take it now; a line still waiting after half an hour is dropped and logged.
    func deliverOutbox() async {
        guard !outbox.items.isEmpty, case .available(let all) = agents else { return }
        let list = TerminalShells.withoutUserShells(all)
        let center = CommandCenter(adapter: makeTerminal(), commander: makeCommander(), log: actionLog)
        await outbox.deliver(agents: list, send: { item, agent in
            try await center.send(item.text, to: item.pane, expectingSession: agent.sessionID, requireReady: true, project: item.project)
        }, dropped: { [self] item in
            actionLog.append("panel message to \(item.pane) dropped, still undelivered after 30 minutes: \(String(item.text.prefix(80)))", project: item.project)
            if let project = item.project { chats.existingSession(project: project, pane: item.pane)?.chat.markFailed(item.id, reason: "the agent stayed busy for 30 minutes") }
        }, failed: { [self] item in
            // N380: a QUESTION line that cannot be written into the PM's pane sends the question back to the user at once.
            guard let qid = QuestionRelay.qid(ofLine: item.text), let watch = watches.values.first(where: { $0.inbox.relay.held(qid) != nil }) else { return false }
            watch.inbox.questionUndelivered(qid)
            if let project = item.project { chats.existingSession(project: project, pane: item.pane)?.chat.markFailed(item.id, reason: "it could not be sent; the question went to you") }
            return true
        })
    }

    /// QUESTION lines still queued for a PM whose question is no longer held (the user took it, it timed out, the PM changed): the PM never gets them.
    func dropStaleQuestionLines() {
        let gone = outbox.remove { item in
            guard let qid = QuestionRelay.qid(ofLine: item.text) else { return false }
            return !watches.values.contains { $0.inbox.relay.held(qid) != nil }
        }
        for item in gone { if let project = item.project { chats.existingSession(project: project, pane: item.pane)?.chat.markFailed(item.id, reason: "the question went to you") } }
    }
    /// An Approve sheet the panel should open for this card (the PM asked, the user decides); the window clears it.
    var approveSheetRequest: String?
    /// An agent's tab the Terminals screen should show (the Open terminal buttons): the window opens the screen, the screen picks the tab and clears it.
    var terminalFocus: TerminalFocusRequest?
    func openTerminalTab(_ pane: String) { terminalFocus = TerminalFocusRequest(pane: pane) }
    /// Whether an Approve sheet is open (set by the window), so a second one is not opened over it.
    var approvalSheetOpen = false
    /// Runs an action that returns nil on success and a reason on failure. `self?.action() ?? "closing"` would turn every success
    /// into "closing" (the optional chain flattens both nils into one), so the missing panel is checked on its own.
    static func failure(of panel: PanelModel?, _ action: (PanelModel) async -> String?) async -> String? {
        guard let panel else { return "The panel is closing." }
        return await action(panel)
    }
    /// The Team screen's state; it follows the selected project.
    @ObservationIgnored lazy var team: TeamModel = TeamModel(store: roleStore, makeScripts: { [weak self] state in self?.previewScripts(state) }, project: nil)
    /// Notifications for questions and finished work (N14). Off until the user turns them on in Settings.
    @ObservationIgnored let notifications: NotificationSending
    @ObservationIgnored let isWindowFocused: @MainActor () -> Bool
    private(set) var notificationsEnabled: Bool
    /// Which events notify and whether they play a sound (Settings → Notifications).
    private(set) var notificationPrefs: NotificationPrefs
    @ObservationIgnored private var cardPoll: Task<Void, Never>?
    @ObservationIgnored private var agentPoll: Task<Void, Never>?

    /// Reads the cards of one data folder off the main thread.
    static let loadFromDisk: @Sendable (URL) async -> [CardLoadResult] = { url in
        await Task.detached { CardRepository(dataDir: url).loadAll() }.value
    }

    init(settingsURL: URL, makeTerminal: @escaping @Sendable () -> TerminalListing, opener: URLOpening,
         loadCards: @escaping @Sendable (URL) async -> [CardLoadResult] = PanelModel.loadFromDisk,
         makeScripts: @escaping (AppSettings) -> ScriptRunning = { var r = ProcessScriptRunner(settings: $0); r.spawnTimeout = 720; return r },
         makeCommander: @escaping @Sendable () -> TerminalCommanding = { PanelModel.inertTerminal },
         log: ActionLog = PanelModel.realLog(),
         writer: CardWriting = CardWriter(),
         defaults: UserDefaults = PanelModel.realDefaults(),
         roleStore: RoleStore = PanelModel.realRoleStore(),
         seedsRoles: Bool = false,
         makePreviewScripts: @escaping (AppSettings, URL) -> ScriptRunning = { ProcessScriptRunner(settings: $0, timeout: 60, extraEnvironment: ["AGENT_PANEL_STATE": $1.path]) },
         makeReader: @escaping @Sendable () -> TerminalReading = { PanelModel.inertTerminal },
         makeKeySender: @escaping @Sendable () -> TerminalKeySending = { PanelModel.inertTerminal },
         claudeTrust: ClaudeTrust? = nil,
         setupProbes: SetupProbes? = nil,
         signInGate: SignInGate? = nil,
         autopilotStore: AutopilotStore? = nil,
         makeDecider: ((AutopilotPolicy) -> PMDeciding)? = nil,
         notifications: NotificationSending = SystemNotificationSender(),
         isWindowFocused: @escaping @MainActor () -> Bool = { NSApp.isActive && NSApp.keyWindow != nil },
         terminalServer: TerminalServerEnsuring = NoTerminalServerCheck()) {
        self.terminalServer = terminalServer
        self.settingsURL = settingsURL
        self.makeTerminal = makeTerminal
        self.opener = opener
        self.loadCards = loadCards
        self.makeScripts = makeScripts
        self.makeCommander = makeCommander
        self.actionLog = log
        self.cardWriter = writer
        self.defaults = defaults
        self.roleStore = roleStore
        self.seedsRoles = seedsRoles
        self.makePreviewScripts = makePreviewScripts
        self.makeReader = makeReader
        self.makeKeySender = makeKeySender
        self.claudeTrust = claudeTrust
        self.setupProbes = setupProbes ?? .live(roleBaseDir: roleStore.baseDir)
        self.signInGateOverride = signInGate
        self.autopilotStore = autopilotStore
        self.makeDecider = makeDecider
        self.notifications = notifications
        self.isWindowFocused = isWindowFocused
        notificationsEnabled = defaults.bool(forKey: Self.notificationsKey)
        notificationPrefs = NotificationPrefs.load(defaults)
        (notifications as? SystemNotificationSender)?.onAction = { [weak self] project, question, action, text in
            Task { await self?.answerFromNotification(project: project, question: question, action: action, text: text) }
        }
        (notifications as? SystemNotificationSender)?.onClick = { [weak self] project, id in Task { await self?.open(projectID: project, cardID: id) } }
    }

    static let notificationsKey = "notificationsEnabled"

    /// Under XCTest the real action log, defaults and roles folder belong to the user: a test that forgets to pass its own
    /// reaches this and stops loudly (tests of the guard replace the handler).
    nonisolated(unsafe) static var onRealDefaultUnderTest: (String) -> Void = { what in
        fatalError("A test built a PanelModel with the user's real \(what). Pass a temporary one (see PanelModel.isolatedForTests).")
    }
    nonisolated static var runsUnderXCTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || uiTestFolder != nil }
    /// `--ui-test <folder>`: the UI test (AgentPanelUITests) launched the app. The folder holds settings.json and the fixture project; the app
    /// is isolated the same way as under the unit tests (every `runsUnderXCTest` guard applies).
    nonisolated static var uiTestFolder: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--ui-test"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }
    nonisolated private static func checkReal(_ what: String) { if runsUnderXCTest { onRealDefaultUnderTest(what) } }
    nonisolated static func realLog() -> ActionLog { checkReal("action log"); return ActionLog(fileURL: ActionLog.defaultURL) }
    nonisolated static func realDefaults() -> UserDefaults { checkReal("UserDefaults"); return .standard }
    nonisolated static func realRoleStore() -> RoleStore { checkReal("roles folder"); return RoleStore() }

    /// A terminal on a socket nobody listens on: the default where a real daemon must never be touched (tests).
    static let inertTerminal = TentaclBackend(client: TentacldClient(socketPath: "/nonexistent/tentacl-test.sock"))

    /// A model whose log, defaults and roles live in a throwaway folder: what the app builds when XCTest hosts it.
    static func isolatedForTests() -> PanelModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-host-\(UUID().uuidString)")
        // A suite named by a path in the model's own temporary folder: nothing lands in ~/Library/Preferences (N190; N116 had one fixed name).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostDefaults = UserDefaults(suiteName: dir.appendingPathComponent("agent-panel-tests-host").path) ?? UserDefaults()
        return PanelModel(settingsURL: dir.appendingPathComponent("settings.json"), makeTerminal: { PanelModel.inertTerminal }, opener: WorkspaceURLOpener(),
                          log: ActionLog(fileURL: dir.appendingPathComponent("actions.log")),
                          defaults: hostDefaults,
                          roleStore: RoleStore(baseDir: dir.appendingPathComponent("roles")))
    }

    /// The model of a UI-test launch: settings, log, defaults and roles inside the test's folder, and no terminal (no agents, nothing to ask).
    static func isolatedForUITest(folder dir: URL) -> PanelModel {
        let hostDefaults = UserDefaults(suiteName: dir.appendingPathComponent("agent-panel-tests-ui").path) ?? UserDefaults()
        let m = PanelModel(settingsURL: dir.appendingPathComponent("settings.json"), makeTerminal: { NoTerminal() }, opener: WorkspaceURLOpener(),
                           log: ActionLog(fileURL: dir.appendingPathComponent("actions.log")),
                           defaults: hostDefaults,
                           roleStore: RoleStore(baseDir: dir.appendingPathComponent("roles")))
        // Session costs come from the test's folder, never from ~/.claude or ~/.codex (N353).
        m.claudeProjectsRoot = dir.appendingPathComponent("claude-projects")
        m.codexSessionsRoot = dir.appendingPathComponent("codex-sessions")
        return m
    }

    /// The Settings switch. Turning it on asks macOS for permission; if that is refused the switch stays off.
    func setNotifications(_ on: Bool) async {
        let granted = on ? await Notifier.enable(notifications) : false
        notificationsEnabled = granted
        defaults.set(granted, forKey: Self.notificationsKey)
    }

    func setNotificationEvent(_ event: NotificationEvent, _ on: Bool) {
        if on { notificationPrefs.events.insert(event) } else { notificationPrefs.events.remove(event) }
        notificationPrefs.save(defaults)
    }

    /// The global mute: off silences every event.
    func setNotificationSound(_ on: Bool) {
        notificationPrefs.sound = on
        notificationPrefs.save(defaults)
    }

    func setNotificationSound(_ sound: NotificationSound, for event: NotificationEvent) {
        notificationPrefs.sounds[event] = sound
        notificationPrefs.save(defaults)
    }

    func setDockBadge(_ on: Bool) {
        notificationPrefs.dockBadge = on
        notificationPrefs.save(defaults)
        updateDockBadge()
    }

    func setDockBounce(_ on: Bool) {
        notificationPrefs.dockBounce = on
        notificationPrefs.save(defaults)
    }

    /// Puts the number of waiting things (the top bar Inbox count) on the Dock icon; not under XCTest.
    func updateDockBadge() {
        guard !Self.runsUnderXCTest else { return }
        DockBadge.apply(DockBadge.label(count: topBarInbox().count, enabled: notificationPrefs.dockBadge))
    }

    /// The events a project's planner gets as data: the proposed round (only the selected project has one), the escalated fixes,
    /// the daily cost limit and the PM's latest chat reply.
    private func notificationExtras(_ watch: ProjectWatch) -> NotificationExtras {
        var extras = NotificationExtras()
        if watch.project.id == selectedProjectID, case .ready(let proposed) = round.state { extras.roundCardIDs = proposed.items.map(\.card.id) }
        extras.escalatedFixes = watch.autopilot.fixesForYou.compactMap { fix in
            if case .escalated(let reason) = fix.state { NotificationExtras.Fix(cardID: fix.card.id, reason: reason) } else { nil }
        }
        if watch.autopilot.limitReached {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            extras.costLimitDay = watch.project.id + "|" + f.string(from: Date())
        }
        if watch.project.id == selectedProjectID { extras.stuckAgents = stuckAgents }
        if let pane = pmPane(forProject: watch.project.id),
           let reply = chats.existingSession(project: watch.project.id, pane: pane)?.chat.entries.last(where: { $0.kind == .agent }) {
            extras.pmReply = NotificationExtras.Reply(id: reply.id, text: reply.text)
        }
        return extras
    }

    /// One notification per new version (the model remembers the last announced tag).
    func notifyUpdate(_ release: ReleaseInfo) async {
        guard notificationsEnabled, notificationPrefs.events.contains(.updateAvailable) else { return }
        let name = SettingsFlow.tagName(release.tag)
        await notifications.send(AppNotification(id: "update|" + release.tag, title: name + " is available", body: release.summary, cardID: "",
                                                 sound: notificationPrefs.sound(for: .updateAvailable)))
    }

    /// True while the Dashboard is on screen (set by the view); a PM question is then visible in Waiting for you.
    @ObservationIgnored var dashboardVisible = false

    private func notify(_ watch: ProjectWatch, cards: [TaskCard]) async {
        let review = cards.filter { $0.status == .review }
        let notes = watch.planner.plan(questions: watch.autopilot.forUser(watch.inbox.questions), reviewCards: review, extras: notificationExtras(watch),
                                       prefs: notificationPrefs, enabled: notificationsEnabled,
                                       focused: isWindowFocused(), onDashboard: dashboardVisible, project: (watch.project.id, watch.project.name))
        for note in notes { await notifications.send(note) }
        if notes.contains(where: \.bounce) { DockBadge.bounce() }
        await remindAboutQuestions(watch)
    }

    /// Reminders at 5 and 15 min (the per-event switch for questions applies), the 30-min line for the PM, and cleaning up what was answered.
    private func remindAboutQuestions(_ watch: ProjectWatch) async {
        let result = watch.reminders.step(questions: watch.autopilot.forUser(watch.inbox.questions), now: Date())
        await notifications.remove(ids: result.cancelled.flatMap(QuestionReminders.notificationIDs))
        let hidden = isWindowFocused() && dashboardVisible
        for due in result.due {
            if due.stage == .thirty {
                if !due.question.isPM { watch.noticeLines.append(QuestionReminders.pmLine(due.question)) }
                continue
            }
            guard notificationsEnabled, notificationPrefs.events.contains(.agentAsks), !hidden else { continue }
            let letPM = watch.autopilot.suggestion(for: due.question) != nil && pmPane(forProject: watch.project.id) != nil
            await notifications.send(QuestionReminders.notification(for: due, prefix: watch.project.name + " · ", sound: notificationPrefs.sound(for: .agentAsks),
                                                                    bounce: notificationPrefs.dockBounce, letPM: letPM))
            if due.stage == .five && notificationPrefs.dockBounce { DockBadge.bounce() }
        }
    }

    /// A button of a question notification: the same path as the in-app answer. If the question is gone, or the pane was closed or reused
    /// (the inbox checks the agent session), nothing is sent and a notification says so.
    func answerFromNotification(project: String?, question qid: String, action: String, text: String) async {
        let watch = project.flatMap { watches[$0] } ?? watches.values.first { $0.inbox.questions.contains { $0.id == qid } }
        func nothingSent(_ why: String) async {
            await notifications.send(AppNotification(id: "not-sent|" + qid, title: "Nothing was sent", body: why, cardID: "", sound: notificationPrefs.sound(for: .agentAsks)))
        }
        guard let watch, let q = watch.inbox.questions.first(where: { $0.id == qid }) else { return await nothingSent("That question is not open any more: the agent moved on or its pane was closed.") }
        guard let answer = QuestionNotice.answer(action: action, text: text, for: q.question) else { return await nothingSent("That answer does not fit the question. Open the panel to answer it.") }
        let sent: Bool
        switch answer {
        case .option(let option): sent = await watch.inbox.answer(q, option: option)
        case .text(let words): sent = await watch.inbox.answer(q, text: words)
        case .typed(let words): sent = await watch.inbox.answerTyped(q, text: words)
        case .passToPM:
            guard let pane = pmPane(forProject: watch.project.id) else { return await nothingSent("There is no PM session to pass it to.") }
            await tellPM(pane: pane, passOnToPMText(q))
            sent = true
        }
        if !sent { await nothingSent(watch.inbox.error ?? "The answer could not be sent.") }
    }

    /// What a notification click opens: the project, then the card.
    func open(projectID: String?, cardID: String) async {
        if let projectID, projectID != selectedProjectID { await selectProject(projectID) }
        selectedCardID = cardID
    }

    /// Decisions waiting in one project: finished work, tasks to approve, questions and fix notes. This is the count in the project menu.
    func waitingCount(forProject id: String) -> Int {
        guard let watch = watches[id] else { return 0 }
        let list = id == selectedProjectID ? selectedTaskCards : watch.taskCards
        return watch.waitingCount(cards: list) + outbox.undelivered.filter { $0.item.project == id }.count
    }

    var selectedProject: ProjectConfig? { projects.first { $0.id == selectedProjectID } }

    var workspaceOpener: WorkspaceOpener? { selectedProject.map { WorkspaceOpener(project: $0, opener: opener) } }

    var selectedCard: TaskCard? {
        for case .card(let card) in cards where card.id == selectedCardID { return card }
        return nil
    }

    /// Role name to display name, for the roles that have one (a project's role replaces a shared role of the same name).
    var roleDisplayNames: [String: String] {
        var names: [String: String] = [:]
        for group in team.groups {
            for role in group.roles {
                if let name = role.config.displayName, !name.isEmpty { names[role.config.name] = name } else { names[role.config.name] = nil }
            }
        }
        return names
    }

    /// Each role's live agents and done cards in the selected project (the Team screen's header and list dots).
    var roleActivity: [String: RoleActivity] {
        guard case .available(let list) = visibleAgents else { return AgentPanel.roleActivity(cards: selectedTaskCards, agents: []) }
        return AgentPanel.roleActivity(cards: selectedTaskCards, agents: list)
    }

    /// Each role's live agents with their card and start time (the role editor's "Running with this role").
    var roleRunning: [String: [RoleRunningAgent]] {
        guard case .available(let list) = visibleAgents else { return [:] }
        return RoleSummary.running(list.map { ($0, card(of: $0)) }, facts: cardFacts)
    }

    func agentLabel(_ agent: AgentStatus) -> String {
        guard let project = selectedProject else { return agent.title.isEmpty ? agent.paneID : agent.title }
        let all = selectedTaskCards
        return AgentPanel.agentLabel(agent: agent, cards: all, displayNames: roleDisplayNames, projectWorktrees: project.worktreesURL)
    }

    /// The agents of the selected project only (all of them while no project is selected).
    var visibleAgents: AgentsState {
        guard let project = selectedProject, case .available(let list) = agents else { return agents }
        var shown = AgentPanel.agents(list, belongingToRepo: project.repoPath)
        // The PM the user chose may run outside the repository; it still belongs in the list.
        if let pm = pmAgent(forProject: project.id), !shown.contains(where: { $0.paneID == pm.paneID }) { shown.append(pm) }
        return .available(shown)
    }

    /// The one status tag of a running task (nil when its card is not running): see `TaskPhase`.
    func phase(of card: TaskCard) -> TaskPhase? { phase(of: card, in: selectedProjectID) }

    /// The same for a card of any project, read from that project's own inbox and autopilot.
    func phase(of card: TaskCard, in projectID: String?) -> TaskPhase? {
        guard let project = config(of: projectID) else { return nil }
        let watch = watch(of: project.id)
        let agent: AgentStatus? = { if case .available(let list) = agents { return list.first { AgentInboxModel.runs($0, in: card, worktrees: project.worktreesURL) } } else { return nil } }()
        return TaskPhase.of(TaskPhaseInput(status: card.status, agent: agent?.state, turnBegun: agent.map { turns.begun($0) } ?? false,
                                           hasReport: !(card.sections["Report"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                           waiting: watch.autopilot.forUser(watch.inbox.questions).filter { $0.cardID == card.id }.count,
                                           quiet: watch.inbox.quietWaitingCount(forCard: card.id),
                                           pmHandling: agent.map { watch.autopilot.isHandledByPM(pane: $0.paneID) } ?? false,
                                           reportChangedSinceFix: watch.fixReports.changed(card)))
    }

    /// The tag of the task an agent works on, for the Agents column (nil for an agent that is on no card, e.g. your own PM session).
    func phase(ofAgent agent: AgentStatus) -> TaskPhase? {
        guard let project = selectedProject else { return nil }
        for case .card(let card) in cards where card.status.holdsAgent && AgentInboxModel.runs(agent, in: card, worktrees: project.worktreesURL) {
            return phase(of: card)
        }
        return nil
    }

    func card(id: String) -> TaskCard? {
        for case .card(let card) in cards where card.id == id { return card }
        return nil
    }

    /// Cards grouped by status, in the order a person needs them: review first, done last. Empty groups are left out.
    var cardsByStatus: [(TaskStatus, [TaskCard])] {
        let order: [TaskStatus] = [.review, .needsFix, .doing, .awaitingStartApproval, .todo, .blocked, .done, .cancelled]
        let all = cards.compactMap { result -> TaskCard? in if case .card(let c) = result { return c } else { return nil } }
        var groups: [(TaskStatus, [TaskCard])] = order.compactMap { status in
            let match = all.filter { $0.status == status }
            return match.isEmpty ? nil : (status, match)
        }
        let unknown = all.filter { if case .unknown = $0.status { return true } else { return false } }
        if !unknown.isEmpty { groups.append((.unknown(""), unknown)) }
        return groups
    }

    /// Things waiting for the user: finished work to review and tasks proposed but not yet approved to start.
    var pendingApprovalCount: Int {
        cards.reduce(0) { count, result in
            guard case .card(let c) = result else { return count }
            return count + ((c.status == .review || c.status == .awaitingStartApproval) ? 1 : 0)
        }
    }

    func reloadProjects() {
        let loaded = ProjectStore.load(settingsURL: settingsURL)
        settings = AppSettingsStore.load(settingsURL: settingsURL)
        projects = loaded.projects
        problems = loaded.problems + settings.problems
        if !projects.contains(where: { $0.id == selectedProjectID }) {
            // The project that was open when the app last quit, while it is still on the list; otherwise the first.
            let saved = defaults.string(forKey: Self.selectedProjectKey)
            selectedProjectID = projects.contains(where: { $0.id == saved }) ? saved : projects.first?.id
            cardRestore = selectedProjectID
        }
        for project in projects {
            if let watch = watches[project.id] { watch.project = project } else { watches[project.id] = makeWatch(for: project) }
        }
        for (id, watch) in watches where !projects.contains(where: { $0.id == id }) { watch.autopilot.setProject(nil); watches[id] = nil }
        syncTeam()
    }

    /// The "Add project" form, starting in the folders of the first project (the usual place for the next one). Nil without a scripts folder,
    /// because creating a project runs `create-project.sh`.
    /// The form for a new task card in the selected project; nil without a project.
    func makeNewTaskFlow() -> NewTaskFlow? { makeFlow(editing: nil) }

    /// The same form opened on `card` as "Edit card".
    func makeEditFlow(_ card: TaskCard) -> NewTaskFlow? { makeFlow(editing: card) }

    private func makeFlow(editing card: TaskCard?) -> NewTaskFlow? {
        guard let project = selectedProject else { return nil }
        var ids = Set<String>()
        for result in cards {
            switch result {
            case .card(let c): ids.insert(c.id)
            case .unreadable(let url, _): ids.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        var names: [String] = []
        for group in team.groups { for role in group.roles where !names.contains(role.config.name) { names.append(role.config.name) } }
        let tasksDir = project.dataURL.appendingPathComponent("tasks")
        if let card { return NewTaskFlow(editing: card, tasksDir: tasksDir, roles: names, existingIDs: { ids }) }
        return NewTaskFlow(projectID: project.id, tasksDir: tasksDir, roles: names, existingIDs: { ids })
    }

    func makeAddProjectFlow() -> AddProjectFlow? {
        guard settings.scriptsDir != nil else { return nil }
        let scripts = makeScripts(settings)
        let first = projects.first
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inspector = RepoInspector(runner: ProcessRunner(timeout: 30))
        let ids = Set(projects.map(\.id))
        let repos = Set(projects.map { ProjectRegistry.resolved($0.repoPath) })
        let flow = AddProjectFlow(scripts: scripts, registry: ProjectRegistry(settingsURL: settingsURL, scripts: scripts),
                              probe: { await inspector.probe($0) }, listSimulators: { await inspector.simulators() }, existingIDs: { ids }, registeredRepoPaths: { repos },
                              repoParent: first.map { URL(fileURLWithPath: $0.repoPath).deletingLastPathComponent().path } ?? home + "/Documents/GitHub",
                              dataRoot: first.map { URL(fileURLWithPath: $0.dataDir).deletingLastPathComponent().path } ?? home + "/Documents")
        let probes = setupProbes
        flow.pmTool = PMToolPicker(current: .claude, followsDefault: true, status: { await PMToolStatus.live(probes: probes) })
        flow.roleStore = roleStore
        return flow
    }

    /// The "Edit project" form for the selected project; nil without a scripts folder (saving runs `validate-config.sh`).
    func makeEditProjectFlow() -> EditProjectFlow? {
        guard let project = selectedProject, project.sourcePath != nil, settings.scriptsDir != nil else { return nil }
        let probes = setupProbes
        let picker = PMToolPicker(current: PMToolChoice.current(project: project, store: roleStore), followsDefault: false,
                                  pmRunning: pmAgent(forProject: project.id) != nil, status: { await PMToolStatus.live(probes: probes) })
        return EditProjectFlow(project: project, registry: ProjectRegistry(settingsURL: settingsURL, scripts: makeScripts(settings)), pmTool: picker, roleStore: roleStore)
    }

    /// The Settings screen. The stable checkout is where `release-stable.sh` puts it by default; the signing file is looked for in the
    /// checkout the scripts are in.
    func makeSettingsFlow() -> SettingsFlow {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let signing = settings.scriptsDir?.deletingLastPathComponent().appendingPathComponent("app/Signing.local.xcconfig").path
        let runner = ProcessScriptRunner(settings: settings)
        return SettingsFlow(settings: settings, settingsURL: settingsURL, stableDir: home.appendingPathComponent("Documents/GitHub/agent-panel-stable"),
                            signingConfigured: signing.map { FileManager.default.fileExists(atPath: $0) } ?? false, git: ProcessRunner(timeout: 30),
                            release: { url, args in try await runner.run(file: url, arguments: args, timeout: 1800) },
                            appURL: home.appendingPathComponent("Applications/Tentacl.app"), processID: ProcessInfo.processInfo.processIdentifier,
                            launch: { script, args in
                                let process = Process()
                                process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [script.path] + args
                                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                                try process.run()
                            },
                            extras: SettingsExtras(update: update, autopilotStore: autopilotStore, actionLogURL: actionLog.fileURL, rolesDir: roleStore.baseDir,
                                                   terminal: { LiveTerminalSession.appClient }))
    }

    /// "Clean up…" in Settings; nil without a scripts folder (closing agents runs `stop-agent.sh`).
    func makeCleanupFlow() -> CleanupFlow? {
        guard settings.scriptsDir != nil else { return nil }
        let git = GitInspector()
        return CleanupFlow(
            projects: projects,
            cards: { project in CardRepository(dataDir: project.dataURL).loadAll().compactMap { if case .card(let c) = $0 { return c } else { return nil } } },
            folders: { project in
                let urls = (try? FileManager.default.contentsOfDirectory(at: project.worktreesURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.lastPathComponent)
            },
            adapter: makeTerminal(),
            inspect: { project, folder in await git.state(repo: project.repoPath, worktree: project.worktreesURL.appendingPathComponent(folder).path, base: project.baseBranch) },
            scripts: makeScripts(settings))
    }

    /// A project's settings were saved, or the project was taken off the list: read the list again.
    func projectsChanged() async { await reload() }

    /// A project was added to the list (by the form): read the list again and show the new project.
    func projectAdded(_ id: String) async {
        reloadProjects()
        await selectProject(id)
    }

    /// The preview runs the real script on a temporary state folder; without `scriptsDir` there is nothing to run.
    private func previewScripts(_ state: URL) -> ScriptRunning? {
        settings.scriptsDir == nil ? nil : makePreviewScripts(settings, state)
    }

    private func syncTeam() {
        team.project = selectedProject
        team.load(seed: seedsRoles)
    }

    func reload() async {
        reloadProjects()
        await reloadCards()
        await refreshAgents()
    }

    func selectProject(_ id: String) async {
        guard projects.contains(where: { $0.id == id }) else { return }
        // The project being left keeps what it showed (it is watched on from here), and the one opened starts from what was last read of it.
        if let old = selectedProjectID, old != id { watches[old]?.cards = cards }
        if selectedProjectID != id { cards = watches[id]?.cards ?? [] }
        let switching = selectedProjectID != id
        if switching { cardRestore = id }
        selectedProjectID = id
        defaults.set(id, forKey: Self.selectedProjectKey)
        selectedCardID = nil
        syncTeam()
        await reloadCards()
    }

    /// The project the user picked last; the app opens on it again.
    static let selectedProjectKey = "selectedProject"

    /// The open card of the selected project, kept for the next launch (N260). The tab is kept only while the same card stays open.
    private func saveOpenCard() {
        guard let project = selectedProjectID, cardRestore != project else { return }
        let old = LayoutRestore.record(defaults, project: project)
        LayoutRestore.save(defaults, project: project, LayoutRestore.ProjectRecord(card: selectedCardID, tab: old?.card == selectedCardID ? old?.tab : nil))
    }

    /// The detail's tab the user picked for the open card.
    func saveOpenTab(_ tab: TaskDetailView.Tab, card: String) {
        guard let project = selectedProjectID, selectedCardID == card else { return }
        LayoutRestore.save(defaults, project: project, LayoutRestore.ProjectRecord(card: card, tab: tab.rawValue))
    }

    /// The tab the open card was last shown on, while the card still has it.
    func savedTab(for card: TaskCard, shots: Int) -> TaskDetailView.Tab? {
        guard let project = selectedProjectID else { return nil }
        return LayoutRestore.tab(LayoutRestore.record(defaults, project: project), card: card, shots: shots)
    }

    /// The first load of a project just opened: its saved card again while it still exists (a gone one opens nothing, quietly). A card
    /// the user (or a notification) opened in the meantime wins, and is saved.
    private func restoreOpenCard(_ project: String) {
        guard cardRestore == project else { return }
        cardRestore = nil
        if selectedCardID == nil { selectedCardID = LayoutRestore.card(LayoutRestore.record(defaults, project: project), in: selectedTaskCards) }
        else { saveOpenCard() }
    }

    /// Moves a project to `index` in the list (a drag in the switcher's order list, Move up / Move down) and writes the order to
    /// `projects.json`; the menu and every list of projects follow it.
    func moveProject(_ id: String, to index: Int) {
        guard let from = projects.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(index, projects.count - 1))
        guard from != to else { return }
        var order = projects
        order.insert(order.remove(at: from), at: to)
        let files = order.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0) }
        do { try ProjectRegistry(settingsURL: settingsURL, scripts: makeScripts(settings)).reorder(projectFiles: files) }
        catch { setActionState(.failed("The project order could not be saved: \(error)")); return }
        reloadProjects()
    }

    func setActionState(_ state: ActionState) { actionState = state }
    func setCommitAsk(_ ask: CommitAsk?) { commitAsk = ask }

    func reloadCards() async {
        guard let project = selectedProject else { cards = []; return }
        let loaded = await loadCards(project.dataURL)
        // The user may have switched projects while this load was running; a late answer must not replace the new cards.
        guard selectedProjectID == project.id else { return }
        // Same cards as a moment ago: publish nothing (every screen watching them would redraw, and the caches built from them would go).
        if cards != loaded { cards = loaded }
        restoreOpenCard(project.id)
        round.notePlan(PlanReader.load(dataDir: project.dataURL), project: project.id)
        let work = ChartWork(cards: selectedTaskCards)   // the chart's running counts and "no work yet" warnings
        if team.chart.work != work { team.chart.work = work }
        watches[project.id]?.fixReports.note(selectedTaskCards)
        refreshExtras()
        // Off the load: the probe runs git (and xcodebuild -list) and must not hold back the cards.
        Task { await refreshGitState() }
        updateDockBadge()
    }

    /// Reads one project's cards again after the panel changed them (a packet, a rebase, a fix request): the open project's list, or a
    /// closed project's last poll.
    func reloadCards(of id: String?) async {
        guard let id, id != selectedProjectID else { return await reloadCards() }
        guard let project = projects.first(where: { $0.id == id }), let watch = watches[id] else { return }
        let loaded = await loadCards(project.dataURL)
        guard selectedProjectID != id else { return }
        watch.cards = loaded
        watch.fixReports.note(watch.taskCards)
        updateDockBadge()
    }

    /// The coffee button's guard, and the plan usage chip next to it.
    @ObservationIgnored lazy var sleepGuard: SleepGuard = {
        // Under XCTest no real IOKit / NSWorkspace observers: a callback into a freed model crashed the test runner (N116).
        let guardModel = Self.runsUnderXCTest ? SleepGuard(power: InertPowerAssertions(), environment: InertPowerEnvironment(), defaults: defaults) : SleepGuard(defaults: defaults)
        guardModel.onNotice = { [weak self] title, body in
            guard let self, self.notificationsEnabled else { return }
            let note = AppNotification(id: "sleep-on-battery", title: title, body: body, cardID: "", sound: self.notificationPrefs.sound ? .crew : .silent)
            Task { await self.notifications.send(note) }
        }
        return guardModel
    }()
    private(set) var planUsage: PlanUsage?
    /// The user's safe point (Settings → Keep awake), kept in the app's defaults, not per project.
    var safePoint: SafePoint {
        get { access(keyPath: \.safePoint); return SafePoint(stored: defaults.object(forKey: SafePoint.key) as? Int) }
        set { withMutation(keyPath: \.safePoint) { defaults.set(newValue.stored, forKey: SafePoint.key) } }
    }
    /// Why no card starts now (the 5-hour usage is at or above the safe point); nil when cards may start. Without a card it is Claude's
    /// reason, and only while no Codex role could still start (N219). N171 reads `safePointReached`, which follows the PM's tool.
    var safePointReason: String? {
        guard let reason = safePoint.reason(planUsage) else { return nil }
        return anyRoleUsesCodex && !safePoint.reached(codexPlanUsage) ? nil : reason
    }
    /// The same for a role's card: only the 5-hour limit of the tool the role runs on holds it. A tool without usage data holds nothing.
    func safePointReason(forRole role: String?) -> String? {
        guard let role else { return safePointReason }
        if tool(ofRole: role) == .codex { return safePoint.reason(codexPlanUsage, limit: "Codex 5-hour limit") }
        return safePoint.reason(planUsage)
    }
    func safePointReason(for card: TaskCard) -> String? { safePointReason(forRole: card.roles.first ?? "dev") }
    var safePointReached: Bool {
        guard let id = selectedProjectID, pmTool(of: id) == .codex else { return safePoint.reached(planUsage) }
        return safePoint.reached(codexPlanUsage)
    }
    @ObservationIgnored var usageSource: @Sendable () -> PlanUsage? = { UsageReader.read(tool: .claude) }
    /// The Codex plan windows (every refresh while some role uses Codex, else at most every 5 minutes). The top bar shows them (N205).
    private(set) var codexPlanUsage: PlanUsage?
    /// Some role of a watched project runs on Codex, as of the last refresh.
    private(set) var codexRoleInUse = false
    /// The Codex windows the top bar shows: a role uses Codex or a Codex session wrote in the last 5 hours; nil otherwise.
    var shownCodexUsage: PlanUsage? { TopBarExtras.codexShown(codexPlanUsage, roleUsesCodex: codexRoleInUse, now: now()) }
    /// Nothing under XCTest: the user's real Codex files must not put a ring into a snapshot (a test sets its own source).
    @ObservationIgnored var codexUsageSource: @Sendable () -> PlanUsage? = { PanelModel.runsUnderXCTest ? nil : UsageReader.read(tool: .codex) }

    /// A task runs when a card of the open project is being worked or fixed, or any agent (of any project) is working.
    var anyTaskRunning: Bool {
        if case .available(let list) = agents, TerminalShells.withoutUserShells(list).contains(where: { $0.state == .working }) { return true }
        return cards.contains { if case .card(let c) = $0 { c.status == .doing || c.status == .needsFix } else { false } }
    }

    private func refreshExtras() {
        var working = 0
        if case .available(let list) = agents { working = TerminalShells.withoutUserShells(list).filter { $0.state == .working }.count }
        sleepGuard.update(running: anyTaskRunning, agents: working)
        // The usage files are read off the main thread; the chip keeps its last value until the read is done.
        let source = usageSource
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            let usage = await Task.detached(priority: .utility) { source() }.value
            guard !Task.isCancelled, let self, self.planUsage != usage else { return }
            self.planUsage = usage
        }
        // Without a Codex role the Codex files are still read, at most every 5 minutes, so a Codex run of the last 5 hours shows (N205).
        let roleUsesCodex = anyRoleUsesCodex
        if codexRoleInUse != roleUsesCodex { codexRoleInUse = roleUsesCodex }
        let time = now()
        guard roleUsesCodex || codexReadAt.map({ time.timeIntervalSince($0) >= 300 }) ?? true else { return }
        codexReadAt = time
        codexUsageTask?.cancel()
        let codexSource = codexUsageSource
        codexUsageTask = Task { [weak self] in
            let usage = await Task.detached(priority: .utility) { codexSource() }.value
            guard !Task.isCancelled, let self, self.codexPlanUsage != usage else { return }
            self.codexPlanUsage = usage
        }
    }
    @ObservationIgnored private var codexReadAt: Date?
    @ObservationIgnored private var codexUsageTask: Task<Void, Never>?
    @ObservationIgnored private var usageTask: Task<Void, Never>?

    /// `waitForFreshStart` false (the agent poll): a due PM hand-off runs on its own, so the next polls keep reading questions while
    /// it waits for the PM; the PM may be stopped at a permission menu for the hand-off file itself (N289).
    func refreshAgents(waitForFreshStart: Bool = true) async {
        defer { refreshExtras() }
        let read: AgentsState
        do { read = .available(try await makeTerminal().agents()) }
        catch let error as BackendError { read = .unavailable(Self.message(for: error)) }
        catch { read = .unavailable(error.localizedDescription) }
        if agents != read { agents = read }
        if case .available(let list) = agents { turns.note(TerminalShells.withoutUserShells(list), hasReply: { TurnTracker.transcriptHasReply($0, tool: self.tool(of: $0), codexRoot: self.codexSessionsRoot) }) }
        await refreshQuestions()
        await tellPM()
        await deliverOutbox()
        if waitForFreshStart { await evaluateFreshStart() }
        else if freshStartCheck == nil {
            freshStartCheck = Task { [weak self] in await self?.evaluateFreshStart(); self?.freshStartCheck = nil }
        }
        await refreshPMContext()
        Task { [weak self] in await self?.refreshSignIn() }
    }

    /// Asks Claude (and Codex when a role uses it) whether it is signed in; an answer younger than 30 s is kept.
    func refreshSignIn() async {
        _ = await signInGate.ensure(.claude)
        if anyRoleUsesCodex { _ = await signInGate.ensure(.codex) }
    }

    @ObservationIgnored private let tellGate = TellGate()

    /// Writes each project's card changes into that project's PM pane, open or not. One run at a time: a refresh that comes while
    /// another is sending is skipped, so a notice is never sent twice or written back after it was sent.
    private func tellPM() async {
        await tellGate.run {
            guard case .available(let all) = agents else { return }
            let list = TerminalShells.withoutUserShells(all)
            for project in projects {
                guard let watch = watches[project.id] else { continue }
                let id = project.id
                let all = taskCards(of: id)
                for line in watch.noticeLines { watch.pmNotice.add(line) }
                watch.noticeLines = []
                watch.pmNotice.observe(cards: all, phase: { [self] in phase(of: $0, in: id) })
                let center = CommandCenter(adapter: makeTerminal(), commander: makeCommander(), log: actionLog)
                var notice = watch.pmNotice
                await notice.deliver(enabled: watch.autopilot.policy.tellPM, agents: list,
                                     cards: all, worktrees: project.worktreesURL, repo: project.repoPath, chosenSession: pmSession(forProject: id)) { pane, session, text in
                    try await center.send(text, to: pane, expectingSession: session, requireReady: true, project: id)
                }
                watch.pmNotice = notice
                if let told = notice.told, told != toldPM(project: id) { defaults.set(told, forKey: "pmNoticeTold.\(id)") }
            }
        }
    }

    /// Looks at what the agents of running tasks ask in every project (reads a screen only when an agent's state changed).
    private func refreshQuestions() async {
        guard case .available(let all) = agents else { return }
        let list = TerminalShells.withoutUserShells(all)
        for project in projects {
            guard let watch = watches[project.id] else { continue }
            let all: [TaskCard]
            if project.id == selectedProjectID { all = cards.compactMap { if case .card(let c) = $0 { c } else { nil } }; watch.cards = cards }
            else { watch.cards = await loadCards(project.dataURL); all = watch.taskCards; watch.fixReports.note(all) }
            let label: (AgentStatus) -> String = { [self] in
                project.id == selectedProjectID ? agentLabel($0) : AgentPanel.agentLabel(agent: $0, cards: all, displayNames: [:], projectWorktrees: project.worktreesURL)
            }
            watch.inbox.claudeProjectsRoot = claudeProjectsRoot
            watch.inbox.routing = QuestionRouting(mode: QuestionSettings.mode(defaults), pmPane: pmPane(forProject: project.id),
                                                  cardFiles: Dictionary(all.map { ($0.id, $0.files) }, uniquingKeysWith: { a, _ in a }))
            await watch.inbox.refresh(agents: list, cards: all, projectWorktrees: project.worktreesURL, pm: pmAgent(forProject: project.id), pmProject: project.id, label: label)
            watch.autopilot.process(watch.inbox.questions, cards: all)
            await answerRequests.deliver()
            dropStaleQuestionLines()
            if project.id == selectedProjectID { noteAgentCards() }
            await notify(watch, cards: all)
        }
        updateDockBadge()
    }

    /// The questions that wait for the user (the ones the PM is still deciding are not counted).
    var questionsForYou: [PendingQuestion] { autopilot.forUser(inbox.questions) }

    /// Cards and agents refresh on separate loops: a slow or hung terminal must never stop the task list from updating.
    func startPolling(interval: Duration = .seconds(5)) {
        stopPolling()
        if !Self.runsUnderXCTest { update.startSchedule { [weak self] release in Task { await self?.notifyUpdate(release) } } }
        cardPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.reloadCards()
                await self.startRequests.process()
                await self.approveRequests.process()
                await self.answerRequests.process()
            }
        }
        agentPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refreshAgents(waitForFreshStart: false)
            }
        }
    }

    func stopPolling() {
        cardPoll?.cancel(); cardPoll = nil
        agentPoll?.cancel(); agentPoll = nil
    }

    static func message(for error: BackendError, terminal: String = "the terminal") -> String {
        switch error {
        case .notInstalled: return "\(terminal) is not installed (or not on PATH)"
        case .notRunning(let message): return "\(terminal) is not running: \(message)"
        case .failed(let message): return "\(terminal) reported an error: \(message)"
        case .badOutput: return "\(terminal) answered with output the panel cannot read"
        }
    }
}

/// A pending PM choice that would take the agent from another project.
struct PMChoice: Equatable {
    let agent: AgentStatus
    let projectID: String
    let fromName: String
}

/// A power environment that reports a plugged-in Mac and never calls back: what a model hosted by XCTest gets.
@MainActor
final class InertPowerEnvironment: PowerEnvironment {
    var snapshot: PowerSnapshot { PowerSnapshot(hasBattery: false, onBattery: false, percent: nil) }
    func start(onChange: @escaping @MainActor () -> Void, willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {}
}

/// Power assertions that hold nothing: a hosted test model must not keep the Mac awake ("Tentacl: agents are working" showed in pmset).
struct InertPowerAssertions: PowerAssertions {
    func create(kind: AssertionKind, reason: String) -> UInt32? { nil }
    func release(_ id: UInt32) {}
}

/// A terminal with no agents and no workspaces (UI-test launches).
struct NoTerminal: TerminalListing {
    func agents() async throws -> [AgentStatus] { [] }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// A request to show one agent's tab on the Terminals screen; a new request is never equal to an old one for the same pane.
struct TerminalFocusRequest: Equatable {
    let pane: String
    let id = UUID()
}
