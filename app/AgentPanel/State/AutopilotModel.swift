import Foundation
import Observation

extension DecisionOutcome {
    var suggestion: PMSuggestion? {
        switch self {
        case .sendOption(_, let s), .sendText(_, let s), .sendCall(_, let s): s
        case .escalate(_, let s): s
        }
    }
}

/// What Prepare review came to when the autopilot ran it.
enum PacketOutcome: Equatable {
    case ready
    /// The packet is incomplete or the build failed; the text is what the script said.
    case failed(String)
    /// Nothing to do (the card changed, or another action is already working on it).
    case skipped
}

/// A reviewer's new Fix notes entry the PM is looking at, or has handed to the user.
struct PendingFix: Identifiable, Equatable {
    enum State: Equatable {
        /// The PM call is running.
        case thinking(since: Date)
        /// The fix request is being sent.
        case applying
        /// Shadow mode: the user sees "PM suggests passing this fix on".
        case suggested(why: String)
        /// The user decides; the reason is shown on the card.
        case escalated(reason: String)
    }

    let card: TaskCard
    let entry: String
    var state: State
    /// "Packet failed" when the panel's own Prepare review failed; the card heading otherwise.
    var headline = "Fix notes need you"
    var isPacket: Bool { headline == PendingFix.packetFailed || headline == PendingFix.packetCouldNotRun || headline == PendingFix.failsOnMain }
    static let packetFailed = "Packet failed"
    /// The run itself broke (test host crash, timeout, xcodebuild error) twice; nothing is wrong with the agent's work that is known (N202).
    static let packetCouldNotRun = "Packet could not run"
    /// Every failing test also fails on main, so it is not the agent's doing and nothing was sent to it (N214).
    static let failsOnMain = "Fails on main too"
    var isRetryablePacket: Bool { headline == PendingFix.packetCouldNotRun || headline == PendingFix.failsOnMain }
    static let behindMain = "Behind main"
    var id: String { card.id }
}

/// The PM autopilot: questions the policy gives to the PM are sent to a short PM decision call instead of the user. The PM's answer
/// is checked by `AutopilotRules` and sent through the inbox's own narrow write path (same session, same question on screen), or,
/// in shadow mode, only shown. Whatever the PM cannot or may not decide goes to the user with the PM's suggestion attached.
@Observable @MainActor
final class AutopilotModel {
    enum Handling: Equatable {
        /// The PM call is running; the user does not see the question yet.
        case thinking(since: Date)
        /// The PM's answer is being sent.
        case applying
        /// Shadow mode: the user sees the question with the PM's answer marked.
        case suggested(PMSuggestion)
        /// The user decides; the reason is shown on the card.
        case escalated(reason: String, suggestion: PMSuggestion?)
    }

    private(set) var policy = AutopilotPolicy()
    private(set) var handling: [String: Handling] = [:]
    /// The commands the user said may always run in this project (N213).
    private(set) var permissionRules: [PermissionRule] = []
    /// The project's decisions, newest last.
    private(set) var records: [DecisionRecord] = []
    private(set) var projectID: String?
    private(set) var saveError: String?
    /// The questions the PM is working on, for the "PM is deciding" rows.
    private(set) var active: [String: PendingQuestion] = [:]

    /// Reviewers' new Fix notes by card id: the PM's work and the user's open cards.
    private(set) var fixes: [String: PendingFix] = [:]
    /// At most this many fix requests per card are sent by the PM; the next one comes to the user.
    static let maxFixRounds = 2
    /// Sends the newest Fix notes entry of a card to its agent (the panel's fix request path); nil on success, else the reason it failed.
    @ObservationIgnored var sendFix: (TaskCard) async -> String? = { _ in "Sending fix requests is not set up." }

    /// Today's estimated cost of the project (agents and PM decisions); nil when it cannot be told. Read at most once a minute.
    @ObservationIgnored var costToday: () -> Double? = { nil }
    /// True while today's cost has reached the policy's daily limit: the PM decides nothing then.
    private(set) var limitReached = false
    /// The last cost read, for the rules sheet.
    private(set) var lastCostToday: Double?
    @ObservationIgnored private var costReadAt: Date?
    static let costCheckSeconds: TimeInterval = 60

    /// Whether the card's agent finished its turn without a question.
    @ObservationIgnored var isFinished: (TaskCard) -> Bool = { _ in false }
    /// Whether the card's agent is working right now (seen working): only that makes the next finished turn a new one to pack.
    @ObservationIgnored var isWorking: (TaskCard) -> Bool = { _ in false }
    /// Runs Prepare review for a card.
    @ObservationIgnored var preparePacket: (TaskCard) async -> PacketOutcome = { _ in .skipped }
    /// Writes the notes into the card's Fix notes and sends the fix request; nil on success, else the reason it failed.
    @ObservationIgnored var requestFix: (TaskCard, String) async -> String? = { _, _ in "Sending fix requests is not set up." }
    /// Runs only the named tests on main once (a throwaway checkout of it); nil: not set up, the fix goes to the agent as before (N214).
    @ObservationIgnored var checkOnMain: ((TaskCard, [String]) async -> MainCheck)?
    /// How many commits the main branch has that the card's branch lacks (0 when it is up to date); nil when it cannot be told.
    @ObservationIgnored var behindMain: (TaskCard) async -> Int? = { _ in nil }
    /// Rebases the card's branch onto main in its worktree (N207); `.skipped` when it must not run now (agent working, a merge running) or cannot.
    @ObservationIgnored var rebaseNow: (TaskCard) async -> AutoRebaseResult = { _ in .skipped }

    @ObservationIgnored private let inbox: AgentInboxModel
    /// Nil turns the autopilot off for good (tests, demo mode).
    @ObservationIgnored private let store: AutopilotStore?
    @ObservationIgnored private let makeDecider: (AutopilotPolicy) -> PMDeciding
    /// True only when Claude is not signed in and Codex is: then decisions go to `codex exec`; otherwise they stay on Claude, whatever the PM runs on.
    @ObservationIgnored var codexDecides: () -> Bool = { false }
    /// The first model Codex lists, for a policy that names none.
    @ObservationIgnored var codexDefaultModel: () -> String = { "" }
    @ObservationIgnored private let makePlanner: (AutopilotPolicy) -> RoundProposing
    @ObservationIgnored private let readCard: (URL) -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let maxConcurrent: Int
    @ObservationIgnored private var projectName = ""
    @ObservationIgnored private var baseBranch = "main"
    @ObservationIgnored private var log: DecisionLog?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fixTasks: [String: Task<Void, Never>] = [:]
    /// The Fix notes text of each card as last read, to tell what was added since.
    @ObservationIgnored private var fixSeen: [String: String] = [:]
    /// Notes the panel itself is about to write (the user's own Request fix), by card id: they are not the reviewer's.
    @ObservationIgnored private var ownFix: [String: String] = [:]
    /// The Report text each card was packed for: one packet per agent turn. Forgotten while the agent works.
    @ObservationIgnored private var packed: [String: String] = [:]
    @ObservationIgnored private var packTasks: [String: Task<Void, Never>] = [:]
    /// How far behind main each card was when its agent was last asked (or, in shadow, offered) to rebase: one request per main state.
    @ObservationIgnored private var rebaseAsked: [String: Int] = [:]  // cleared whenever the branch is seen up to date
    @ObservationIgnored private var rebaseChecked: [String: Date] = [:]
    @ObservationIgnored private var rebaseTasks: [String: Task<Void, Never>] = [:]
    /// The least time between two looks at whether a card's branch is behind main.
    static let rebaseCheckSeconds: TimeInterval = 30

    init(inbox: AgentInboxModel, store: AutopilotStore?,
         makeDecider: @escaping (AutopilotPolicy) -> PMDeciding = { ClaudePMDecider(model: $0.model, budgetUSD: $0.budgetUSD, timeout: TimeInterval($0.timeoutSeconds + 15)) },
         makePlanner: @escaping (AutopilotPolicy) -> RoundProposing = { ClaudePMDecider(model: $0.model, budgetUSD: $0.budgetUSD, timeout: TimeInterval($0.timeoutSeconds + 15)) },
         readCard: @escaping (URL) -> String = { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" },
         now: @escaping () -> Date = Date.init, maxConcurrent: Int = 3) {
        self.inbox = inbox; self.store = store; self.makeDecider = makeDecider; self.makePlanner = makePlanner; self.readCard = readCard; self.now = now; self.maxConcurrent = maxConcurrent
        inbox.onAnswered = { [weak self] question, sent in self?.userAnswered(question, sent: sent) }
        // N380: the PM's answer to a relayed question goes to the card's timeline ("PM answered") and the decision log.
        inbox.onAnsweredByPM = { [weak self] question, sent in self?.record(question, by: .pm, result: .answered, answer: sent, why: "Relayed question answered by the PM.") }
    }

    /// Every decision of the project (for the cost per task in Stats).
    func allDecisions() -> [DecisionRecord] { log?.recent(limit: .max) ?? [] }

    // MARK: project and policy

    func setProject(_ project: ProjectConfig?) {
        guard project?.id != projectID else { return }
        stopAll()
        handling = [:]
        fixes = [:]; fixSeen = [:]; ownFix = [:]; packed = [:]; rebaseAsked = [:]; rebaseChecked = [:]
        limitReached = false; lastCostToday = nil; costReadAt = nil
        projectID = project?.id
        projectName = project?.name ?? ""
        baseBranch = project?.baseBranch ?? "main"
        if let store, let project {
            policy = store.load(project.id)
            log = store.decisionsURL(project.id).map { DecisionLog(fileURL: $0) }
            permissionRules = store.loadRules(project.id)
        } else {
            policy = AutopilotPolicy()
            policy.mode = .off
            log = nil
            permissionRules = []
        }
        records = log?.recent(limit: 60) ?? []
        saveError = nil
    }

    /// Every record of the project's decisions.jsonl, newest last (the in-memory list keeps only the last 60).
    func allRecords() -> [DecisionRecord] { log?.recent(limit: .max) ?? [] }

    // MARK: permission rules (N213)

    /// Saves the rule for this prompt's command and answers the prompt once with "Yes". False when there is no rule to make or it could not be saved or sent.
    func alwaysAllow(_ q: PendingQuestion) async -> Bool {
        guard let id = projectID, let store, let pattern = PermissionRules.pattern(for: q.question), PermissionRules.answer(for: q.question) != nil else { return false }
        if !permissionRules.contains(where: { $0.pattern == pattern }) {
            let next = permissionRules + [PermissionRule(pattern: pattern, added: now())]
            do { try store.saveRules(next, for: id); saveError = nil }
            catch { saveError = "The rule could not be saved: \(error.localizedDescription)"; return false }
            permissionRules = next
        }
        guard let yes = PermissionRules.answer(for: q.question) else { return false }
        return await inbox.answer(q, option: yes)
    }

    /// Removes a rule; the next matching prompt goes to the PM or the user again at once.
    func removeRule(_ rule: PermissionRule) {
        guard let id = projectID, let store else { return }
        let next = permissionRules.filter { $0 != rule }
        do { try store.saveRules(next, for: id); saveError = nil }
        catch { saveError = "The rule could not be removed: \(error.localizedDescription)"; return }
        permissionRules = next
        // A prompt a rule was already answering is not taken back, but one only suggested by it is.
        for (qid, h) in handling { if case .suggested(let s) = h, s.why.hasPrefix(Self.ruleWhy(rule)) { handling[qid] = nil } }
    }

    static func ruleWhy(_ rule: PermissionRule) -> String { "Allowed by rule \(rule.pattern)" }

    /// A prompt a saved rule covers is answered with the one-time "Yes" (On) or only suggested (Shadow), whoever owns permissions.
    private func applyRule(_ rule: PermissionRule, to q: PendingQuestion, yes: QuestionOption) {
        let why = Self.ruleWhy(rule) + "."
        active[q.id] = q
        guard policy.mode == .on else {
            let s = PMSuggestion(option: yes.number, text: nil, why: why, optionLabel: yes.label)
            handling[q.id] = .suggested(s)
            record(q, by: .pm, result: .suggested, answer: yes.label, why: why)
            return
        }
        handling[q.id] = .applying
        Task { [weak self] in
            guard let self else { return }
            let busy = inbox.sending
            if await inbox.answer(q, option: yes) {
                handling[q.id] = nil; active[q.id] = nil
                record(q, by: .pm, result: .answered, answer: yes.label, why: why)
            } else {
                let reason = "The rule's answer could not be sent: \(busy ? "another answer was being sent" : (inbox.error ?? "another answer was being sent"))"
                handling[q.id] = .escalated(reason: reason, suggestion: nil)
                record(q, by: .pm, result: .escalated, answer: yes.label, why: reason)
            }
        }
    }

    func update(_ new: AutopilotPolicy) {
        guard let id = projectID, let store else { return }
        do { try store.save(new, for: id); saveError = nil }
        catch { saveError = "The autopilot settings could not be saved: \(error.localizedDescription)"; return }
        policy = new
        costReadAt = nil
        // Questions the PM no longer owns go back to the user at once.
        for (qid, h) in handling {
            guard case .thinking = h, let q = active[qid], new.handler(for: q.question.kind) == .you else { continue }
            tasks[qid]?.cancel(); tasks[qid] = nil
            handling[qid] = nil
        }
        // Off: the PM decides nothing any more, so what it was still thinking about is cancelled and shown to the user.
        if new.mode == .off {
            for (qid, h) in handling { if case .thinking = h { tasks[qid]?.cancel(); tasks[qid] = nil; handling[qid] = nil; active[qid] = nil } }
            for (id, fix) in fixes { if case .thinking = fix.state { fixTasks[id]?.cancel(); fixTasks[id] = nil; fixes[id] = nil } }
        }
        if new.fixHandler == .you {
            for (id, fix) in fixes { if case .thinking = fix.state { fixTasks[id]?.cancel(); fixTasks[id] = nil; fixes[id] = nil } }
        }
    }

    /// False when the autopilot cannot be used at all (no project, or no settings folder in tests and demo mode).
    var isAvailable: Bool { store != nil && projectID != nil }

    /// True while the "Switch to On?" confirmation is open.
    var confirmingOn = false
    /// What the confirmation lists: everything the PM may do once the mode is On.
    static let onWarning = "With the autopilot On the PM may, without asking you: answer agent questions, allow a permission once, approve plans, "
        + "and start or merge a task when you ask for it in the PM chat. Merging cannot be undone by the panel."

    /// The menu's entry point: On asks first; Off and Shadow switch at once.
    func requestMode(_ mode: AutopilotMode) {
        if mode == .on, policy.mode != .on { confirmingOn = true } else { confirmingOn = false; setMode(mode) }
    }

    func confirmOn() { confirmingOn = false; setMode(.on) }
    func cancelOn() { confirmingOn = false }

    /// The rules sheet; kept here so quitting can close it.
    var rulesOpen = false

    func setMode(_ mode: AutopilotMode) {
        var p = policy
        p.mode = mode
        update(p)
    }

    // MARK: what the user sees

    /// The questions waiting for the user: all except the ones the PM is still deciding or sending.
    func forUser(_ questions: [PendingQuestion]) -> [PendingQuestion] {
        questions.filter { q in
            switch handling[q.id] {
            case .thinking, .applying: false
            default: true
            }
        }
    }

    func suggestion(for q: PendingQuestion) -> PMSuggestion? {
        switch handling[q.id] {
        case .suggested(let s): s
        case .escalated(_, let s): s
        default: nil
        }
    }

    func escalation(for q: PendingQuestion) -> String? {
        if case .escalated(let reason, _) = handling[q.id] { return reason }
        return nil
    }

    /// The questions the PM is working on right now, oldest first.
    var deciding: [PendingQuestion] {
        handling.compactMap { id, h -> (Date, PendingQuestion)? in
            guard case .thinking(let since) = h, let q = active[id] else { return nil }
            return (since, q)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The fix notes waiting for the user: the PM's suggestions (shadow) and the ones it escalated.
    var fixesForYou: [PendingFix] {
        fixes.values.filter { fix in
            switch fix.state { case .suggested, .escalated: true; default: false }
        }.sorted { $0.id < $1.id }
    }

    /// The fix notes the PM is reading now.
    var decidingFixes: [PendingFix] {
        fixes.values.filter { if case .thinking = $0.state { true } else { false } }.sorted { $0.id < $1.id }
    }

    func fix(for cardID: String) -> PendingFix? { fixes[cardID] }

    func isHandledByPM(pane: String) -> Bool {
        handling.contains { id, h in
            guard id.hasPrefix(pane + "|") else { return false }
            switch h { case .thinking, .applying: return true; default: return false }
        }
    }

    // MARK: the loop

    /// Called after every inbox refresh: forgets questions that are gone, escalates PM calls that ran out of time and asks the PM
    /// about new questions it owns.
    func process(_ questions: [PendingQuestion], cards: [TaskCard]) {
        scanFixNotes(cards)
        let live = Set(questions.map(\.id))
        for (id, task) in tasks where !live.contains(id) { task.cancel(); tasks[id] = nil }
        handling = handling.filter { live.contains($0.key) }
        active = active.filter { live.contains($0.key) }
        guard policy.mode != .off, projectID != nil else { limitReached = false; return }
        checkLimit()
        scanFinished(cards)
        scanBehind(cards)

        for (id, h) in handling {
            guard case .thinking(let since) = h, now().timeIntervalSince(since) >= Double(policy.timeoutSeconds), let q = active[id] else { continue }
            let reason = "PM did not decide within \(Self.duration(policy.timeoutSeconds))."
            handling[id] = .escalated(reason: reason, suggestion: nil)
            record(q, by: .pm, result: .escalated, answer: "", why: reason)
        }

        for (id, fix) in fixes {
            guard case .thinking(let since) = fix.state, now().timeIntervalSince(since) >= Double(policy.timeoutSeconds) else { continue }
            fixTasks[id]?.cancel(); fixTasks[id] = nil
            escalateFix(id, "PM did not decide within \(Self.duration(policy.timeoutSeconds)).")
        }

        for q in questions where !q.isPM && handling[q.id] == nil {
            // A saved rule answers first (it costs nothing, so the daily limit does not stop it); the always-yours never match one.
            if let rule = PermissionRules.rule(for: q.question, in: permissionRules), let yes = PermissionRules.answer(for: q.question) {
                applyRule(rule, to: q, yes: yes)
                continue
            }
            guard policy.handler(for: q.question.kind) == .pm else { continue }
            if limitReached, let reason = limitReason {
                handling[q.id] = .escalated(reason: reason, suggestion: nil)
                record(q, by: .pm, result: .escalated, answer: "", why: reason)
                continue
            }
            if let reason = AutopilotRules.mustEscalate(q.question) {
                handling[q.id] = .escalated(reason: reason, suggestion: nil)
                record(q, by: .pm, result: .escalated, answer: "", why: reason)
                continue
            }
            guard tasks.count < maxConcurrent else { break }
            guard let card = cards.first(where: { $0.id == q.cardID }) else { continue }
            let request = DecisionRequest(projectName: projectName, cardID: card.id, cardText: readCard(card.url), agentLabel: q.agentLabel,
                                          question: q.question, earlier: (log?.recent(limit: 10, cardID: card.id) ?? []).map(\.promptLine))
            let decider = pickDecider()
            handling[q.id] = .thinking(since: now())
            active[q.id] = q
            tasks[q.id] = Task { [weak self] in
                let result: Result<PMReply, Error>
                do { result = .success(try await decider.decide(request)) } catch { result = .failure(error) }
                await self?.finish(q, result)
            }
        }
    }

    func pickDecider() -> PMDeciding {
        guard codexDecides() else { return makeDecider(policy) }
        return CodexPMDecider(model: policy.codexModel.isEmpty ? codexDefaultModel() : policy.codexModel, timeout: TimeInterval(policy.timeoutSeconds + 15))
    }

    /// Reads today's cost (at most once a minute) and sets `limitReached`; without a limit nothing is read.
    private func checkLimit() {
        guard policy.dailyLimitUSD != nil else { limitReached = false; return }
        if costReadAt == nil || now().timeIntervalSince(costReadAt!) >= Self.costCheckSeconds || now() < costReadAt! {
            lastCostToday = costToday(); costReadAt = now()
        }
        limitReached = policy.dailyLimitUSD.flatMap { limit in lastCostToday.map { $0 >= limit } } ?? false
    }

    private var limitReason: String? {
        guard let limit = policy.dailyLimitUSD else { return nil }
        return String(format: "Daily cost limit of $%.2f reached (today ≈ $%.2f); the PM has stopped deciding.", limit, lastCostToday ?? limit)
    }

    private func finish(_ q: PendingQuestion, _ result: Result<PMReply, Error>) async {
        tasks[q.id] = nil
        let current = handling[q.id]
        switch result {
        case .failure(let error):
            guard case .thinking = current else { return }
            let reason = "PM could not decide: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            handling[q.id] = .escalated(reason: reason, suggestion: nil)
            record(q, by: .pm, result: .escalated, answer: "", why: reason)
        case .success(let reply):
            let outcome = AutopilotRules.outcome(of: reply.decision, for: q.question)
            guard case .thinking = current else {
                // The question already went to the user (time ran out): a late answer is still worth showing.
                if case .escalated(let reason, nil) = current, let s = outcome.suggestion { handling[q.id] = .escalated(reason: reason, suggestion: s) }
                return
            }
            switch outcome {
            case .escalate(let reason, let s):
                handling[q.id] = .escalated(reason: reason, suggestion: s)
                record(q, by: .pm, result: .escalated, answer: s?.summary ?? "", why: reason, cost: reply.costUSD)
            case .sendOption(_, let s), .sendText(_, let s), .sendCall(_, let s):
                guard policy.mode == .on else {
                    handling[q.id] = .suggested(s)
                    record(q, by: .pm, result: .suggested, answer: s.summary, why: s.why, cost: reply.costUSD)
                    return
                }
                handling[q.id] = .applying
                // A refusal because another answer is in flight sets no error of its own; the inbox's old one must not be shown.
                let busy = inbox.sending
                let sent: Bool
                if case .sendOption(let option, _) = outcome { sent = await inbox.answer(q, option: option) }
                else if case .sendCall(let picks, _) = outcome { sent = await inbox.answerCall(q, answers: picks.map { .option($0) }) }
                else { sent = await inbox.answer(q, text: s.text ?? "") }
                if sent {
                    handling[q.id] = nil
                    active[q.id] = nil
                    record(q, by: .pm, result: .answered, answer: s.summary, why: s.why, cost: reply.costUSD)
                } else {
                    let reason = "PM's answer could not be sent: \(busy ? "another answer was being sent" : (inbox.error ?? "another answer was being sent"))"
                    handling[q.id] = .escalated(reason: reason, suggestion: s)
                    record(q, by: .pm, result: .escalated, answer: s.summary, why: reason, cost: reply.costUSD)
                }
            }
        }
    }

    /// The user answered on a card (the PM's own answers pass through here too and are skipped).
    private func userAnswered(_ q: PendingQuestion, sent: String) {
        if q.isPM { return }
        if case .applying = handling[q.id] { return }
        let used = suggestion(for: q).map { $0.summary == sent } ?? false
        handling[q.id] = nil
        active[q.id] = nil
        record(q, by: .you, result: .answered, answer: sent, why: used ? "Used PM's suggestion." : "")
    }

    private func record(_ q: PendingQuestion, by: DecisionRecord.By, result: DecisionRecord.Result, answer: String, why: String, cost: Double? = nil) {
        guard let log else { return }
        let asked = ((q.question.title.isEmpty ? q.question.text : q.question.title + ": " + q.question.text) + (q.question.code.map { " " + $0 } ?? ""))
            .replacingOccurrences(of: "\n", with: " ")
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: q.cardID, agent: q.agentLabel, kind: DecisionCategory(q.question.kind).rawValue,
                               question: String(asked.prefix(160)), by: by, result: result, answer: String(answer.prefix(300)), why: why, costUSD: cost)
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    // MARK: rounds

    /// Whether "Plan a round" is offered: the autopilot is on or in shadow mode.
    var canPlanRound: Bool { isAvailable && policy.mode != .off }

    func proposeRound(_ request: RoundRequest) async throws -> RoundReply {
        try await makePlanner(policy).proposeRound(request)
    }

    /// A round the user approved: one decision in the feed, whatever the PM suggested.
    func recordRound(_ outcome: RoundOutcome) {
        guard let log else { return }
        let ids = outcome.started.joined(separator: ", ")
        let why = (outcome.note.isEmpty ? "" : "You said: \(outcome.note) ") + outcome.started.compactMap { id in outcome.reasons[id].map { "\(id): \($0)" } }.joined(separator: " ")
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: ids.isEmpty ? "round" : ids, agent: "PM", kind: Self.roundKind,
                               question: outcome.failure.map { String("Round stopped: \($0)".prefix(160)) } ?? "Round of \(outcome.started.count) tasks",
                               by: .you, result: outcome.started.isEmpty ? .escalated : .answered, answer: ids,
                               why: String(((outcome.failure.map { $0 + " " } ?? "") + why).prefix(300)), costUSD: outcome.cost)
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    static let roundKind = "round"
    static let startKind = "start"

    /// A start the PM asked for after the user's chat message: one decision in the feed, whatever came of it.
    func recordStart(_ outcome: StartRequestOutcome) {
        guard let log else { return }
        let ids = outcome.requested.joined(separator: ", ")
        let result: DecisionRecord.Result = switch outcome.result { case .started: .answered; case .sheet: .suggested; case .refused: .escalated }
        let problems = outcome.refused.map { "\($0.id): \($0.reason)" } + (outcome.failure.map { [$0] } ?? [])
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: ids.isEmpty ? "start" : ids, agent: "PM", kind: Self.startKind,
                               question: String(Self.said(outcome.words, authority: outcome.authority).prefix(160)), by: .pm, result: result,
                               answer: outcome.started.joined(separator: ", "), why: String(problems.joined(separator: " ").prefix(300)))
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    static let approveKind = "approve"

    /// The feed line for a request: the user's words, or the authority tag when the PM acted on its standing authority.
    private static func said(_ words: String, authority: Bool) -> String {
        let quoted = words.isEmpty ? "(no words)" : words
        return authority ? "\(PMAuthority.tag): \(quoted)" : "You said: \(quoted)"
    }

    /// Cards the PM started today under its standing authority, after the user's last reset of the count (from the decision log, so a restart keeps both).
    func authorityStartsToday() -> Int {
        _ = records.count  // read so a view showing the count redraws when a start or reset is recorded
        guard let log else { return 0 }
        let calendar = Calendar.current
        let recent = log.recent(limit: 500)
        let resetAt = recent.last { $0.kind == Self.authorityResetKind }?.time ?? .distantPast
        return recent.filter {
            $0.kind == Self.startKind && $0.result == .answered && $0.question.hasPrefix(PMAuthority.tag) && calendar.isDate($0.time, inSameDayAs: now()) && $0.time > resetAt
        }.reduce(0) { $0 + $1.answer.split(separator: ",").count }
    }

    static let authorityResetKind = "authority-reset"

    /// The user sets the PM's start count back to zero: only starts after now count. Cards already started keep running.
    func resetAuthorityCount() {
        guard let log else { return }
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: PMAuthority.tag, agent: "PM", kind: Self.authorityResetKind,
                               question: "PM start count reset", by: .you, result: .answered, answer: "0", why: "count reset by the user")
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    /// The standing authority as the request handlers judge it now.
    func authority() -> PMAuthority {
        checkLimit()
        return PMAuthority(enabled: policy.pmAuthority, startsPerDay: policy.pmStartsPerDay, startedToday: policy.pmAuthority ? authorityStartsToday() : 0, costLimitReached: limitReached)
    }

    /// An approval the PM asked for after the user's chat message: one decision in the feed, whatever came of it.
    func recordApprove(_ outcome: ApproveRequestOutcome) {
        guard let log else { return }
        let ids = outcome.requested.joined(separator: ", ")
        let result: DecisionRecord.Result = switch outcome.result { case .approved: .answered; case .sheet: .suggested; case .refused: .escalated }
        let problems = outcome.refused.map { "\($0.id): \($0.reason)" } + (outcome.failure.map { [$0] } ?? [])
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: ids.isEmpty ? "approve" : ids, agent: "PM", kind: Self.approveKind,
                               question: String(Self.said(outcome.words, authority: outcome.authority).prefix(160)), by: .pm, result: result,
                               answer: outcome.approved.joined(separator: ", "), why: String(problems.joined(separator: " ").prefix(300)))
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    // MARK: fix notes from a reviewer

    /// The panel is about to write this quoted note into a card's Fix notes itself (the user's own Request fix): it is not a reviewer's.
    func expectOwnFixNote(cardID: String, quoted: String) {
        ownFix[cardID] = quoted
        fixTasks[cardID]?.cancel(); fixTasks[cardID] = nil
        fixes[cardID] = nil
    }

    func dismissFix(cardID: String) {
        guard let fix = fixes[cardID] else { return }
        switch fix.state { case .suggested, .escalated: fixes[cardID] = nil; default: break }
    }

    /// The user presses *Send fix request* on the PM's suggestion (shadow) or on a note the PM escalated; the existing entry goes out as it is.
    func sendSuggestedFix(cardID: String) async {
        guard var fix = fixes[cardID] else { return }
        let why: String
        switch fix.state { case .suggested: why = "Used PM's suggestion."; case .escalated: why = "Sent by you after PM escalated it."; default: return }
        fix.state = .applying
        fixes[cardID] = fix
        if fix.headline == PendingFix.behindMain {
            let failure = await requestFix(fix.card, fix.entry)
            guard fixes[cardID]?.entry == fix.entry else { return }
            if let failure { fixes[cardID]?.state = .escalated(reason: "The rebase request could not be sent: \(failure)") }
            else { fixes[cardID] = nil; recordRebase(fix.card, by: .you, result: .answered, why: why) }
            return
        }
        let failure = await sendFix(fix.card)
        guard fixes[cardID]?.entry == fix.entry else { return }
        if let failure {
            fixes[cardID]?.state = .escalated(reason: "The fix request could not be sent: \(failure)")
        } else {
            fixes[cardID] = nil
            recordFix(fix, by: .you, result: .answered, why: why)
        }
    }

    /// Compares each card's Fix notes with what was read last time; a new entry on a running card that the reviewer (not the panel) wrote goes to the PM.
    private func scanFixNotes(_ cards: [TaskCard]) {
        guard projectID != nil else { return }
        let running = Dictionary(cards.filter { $0.status.holdsAgent }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in fixes.keys where running[id] == nil { fixTasks[id]?.cancel(); fixTasks[id] = nil; fixes[id] = nil }
        for card in cards {
            let notes = card.sections["Fix notes"] ?? ""
            guard let seen = fixSeen[card.id] else { fixSeen[card.id] = notes; continue }
            guard notes != seen else { continue }
            fixSeen[card.id] = notes
            guard let added = AutopilotRules.newFixEntry(old: seen, new: notes), let entry = Self.stampedEntries(added) else { continue }
            if let own = ownFix[card.id], entry.contains(own) { ownFix[card.id] = nil; continue }
            guard card.status.holdsAgent, policy.mode != .off, policy.fixHandler == .pm else { continue }
            if limitReached, let reason = limitReason {
                fixes[card.id] = PendingFix(card: card, entry: entry, state: .thinking(since: now()))
                escalateFix(card.id, reason)
                continue
            }
            startFix(card, entry)
        }
    }

    /// Only entries the panel or a reviewer stamped (`### <date> ...`) are notes; a heading without a date is the card's agent answering in the wrong section.
    private static func stampedEntries(_ added: String) -> String? {
        let parts = ("\n" + added).components(separatedBy: "\n### ").dropFirst()
        let kept = parts.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
        guard !kept.isEmpty else { return nil }
        return kept.map { "### " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private func startFix(_ card: TaskCard, _ entry: String) {
        fixTasks[card.id]?.cancel(); fixTasks[card.id] = nil
        let earlier = log?.recent(limit: 200, cardID: card.id) ?? []
        let rounds = earlier.filter { $0.kind == DecisionCategory.fix.rawValue && $0.by == .pm && $0.result == .answered }.count
        guard rounds < Self.maxFixRounds else {
            fixes[card.id] = PendingFix(card: card, entry: entry, state: .thinking(since: now()))
            escalateFix(card.id, "PM has already passed on \(Self.maxFixRounds) fix rounds for this card; this one is yours.")
            return
        }
        let request = FixRequest(projectName: projectName, cardID: card.id, cardText: readCard(card.url), entry: entry, earlier: earlier.suffix(10).map(\.promptLine))
        let decider = pickDecider()
        fixes[card.id] = PendingFix(card: card, entry: entry, state: .thinking(since: now()))
        fixTasks[card.id] = Task { [weak self] in
            let result: Result<PMReply, Error>
            do { result = .success(try await decider.decide(request)) } catch { result = .failure(error) }
            await self?.finishFix(card.id, entry, result)
        }
    }

    private func finishFix(_ id: String, _ entry: String, _ result: Result<PMReply, Error>) async {
        fixTasks[id] = nil
        // Time ran out, the user acted or a newer note came in meanwhile: this answer is stale.
        guard let fix = fixes[id], fix.entry == entry, case .thinking = fix.state else { return }
        switch result {
        case .failure(let error):
            escalateFix(id, "PM could not decide: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        case .success(let reply):
            switch AutopilotRules.fixOutcome(of: reply.decision) {
            case .escalate(let reason):
                escalateFix(id, reason, cost: reply.costUSD)
            case .passOn(let why):
                guard policy.mode == .on else {
                    fixes[id]?.state = .suggested(why: why)
                    recordFix(fix, by: .pm, result: .suggested, why: why, cost: reply.costUSD)
                    return
                }
                fixes[id]?.state = .applying
                let failure = await sendFix(fix.card)
                guard fixes[id]?.entry == entry else { return }
                if let failure { escalateFix(id, "The fix request could not be sent: \(failure)", cost: reply.costUSD) }
                else {
                    fixes[id] = nil
                    recordFix(fix, by: .pm, result: .answered, why: why, cost: reply.costUSD)
                }
            }
        }
    }

    private func escalateFix(_ id: String, _ reason: String, cost: Double? = nil) {
        guard var fix = fixes[id] else { return }
        fix.state = .escalated(reason: reason)
        fixes[id] = fix
        recordFix(fix, by: .pm, result: .escalated, why: reason, cost: cost)
    }

    private func recordFix(_ fix: PendingFix, by: DecisionRecord.By, result: DecisionRecord.Result, why: String, cost: Double? = nil) {
        guard let log else { return }
        let text = fix.entry.components(separatedBy: "\n").filter { !$0.hasPrefix("###") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "> ")) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let answer = result == .escalated ? "" : "Passed on to the developer"
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: fix.card.id, agent: fix.card.agent ?? fix.card.id, kind: DecisionCategory.fix.rawValue,
                               question: String("\(fix.isPacket ? fix.headline : "Fix notes"): \(text)".prefix(160)), by: by, result: result, answer: answer, why: why, costUSD: cost)
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    // MARK: review when an agent finishes

    /// A running card whose agent finished its turn with the Report filled gets Prepare review once per turn.
    private func scanFinished(_ cards: [TaskCard]) {
        guard policy.reviewHandler == .pm else { return }
        for card in cards where card.status == .doing || card.status == .needsFix {
            // Forgotten only when the agent is seen working: a project switch or a terminal hiccup is not a new turn.
            guard isFinished(card) else { if isWorking(card) { packed[card.id] = nil }; continue }
            let report = (card.sections["Report"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !report.isEmpty, packed[card.id] != report, packTasks[card.id] == nil, fixes[card.id] == nil else { continue }
            packed[card.id] = report
            packTasks[card.id] = Task { [weak self] in
                guard let self else { return }
                await self.runPacket(card)
            }
        }
    }

    /// What the packet script prints when it only met a passing condition (the branch or card moved, or another packet is running), not a failure.
    static let passingPacketMarkers = ["the branch changed while the packet was being built", "the card changed while the packet was being built", "is already being prepared"]
    /// The script's wording when another run holds the lock and is alive (it names the pid): that run's result is what counts.
    static let lockHeldMarker = "is already being prepared (pid"
    /// How long to wait between looks while a live run holds the lock; waiting does not count as a try.
    @ObservationIgnored var packetLockPollDelay: Duration = .seconds(30)
    /// How long in all a live lock is waited out before the user hears about it.
    @ObservationIgnored var packetLockTimeout: Duration = .seconds(20 * 60)
    /// The packet runs this many times in all before a passing failure goes to the user.
    static let maxPacketRuns = 3
    /// How long to wait before running the packet again after a passing failure.
    @ObservationIgnored var packetRetryDelay: Duration = .seconds(60)

    /// How long to wait before the one retry of a packet whose run broke (host crash, timeout); no agent turn is used.
    @ObservationIgnored var infrastructureRetryDelay: Duration = .seconds(5)

    /// Runs the packet; a passing failure is waited out and run again, never a fix round and never sent to the agent.
    /// A run that broke for a reason that is not the agent's (N202) is run once more by itself; `retried` is that second time.
    private func runPacket(_ card: TaskCard, first: PacketOutcome? = nil, retried: Bool = false) async {
        var runs = 1
        var waited = Duration.zero
        var outcome: PacketOutcome
        if let first { outcome = first } else { outcome = await preparePacket(card) }
        while case .failed(let text) = outcome, Self.passingPacketMarkers.contains(where: text.contains) {
            if text.contains(Self.lockHeldMarker) {
                guard waited < packetLockTimeout else {
                    var fix = PendingFix(card: card, entry: String(text.prefix(800)), state: .applying, headline: PendingFix.packetFailed)
                    fix.state = .escalated(reason: "Another packet run kept holding the lock for over \(packetLockTimeout.formatted(.units(allowed: [.minutes, .seconds]))) (\(text.prefix(160))); run Prepare review yourself.")
                    fixes[card.id] = fix
                    packTasks[card.id] = nil
                    recordFix(fix, by: .pm, result: .escalated, why: "Another packet run held the lock past the timeout.")
                    return
                }
                if waited == .zero { recordReview(card, "Another packet run is still going; waiting for its result.", answer: "Retry") }
                try? await Task.sleep(for: packetLockPollDelay)
                guard !Task.isCancelled else { packTasks[card.id] = nil; return }
                waited += packetLockPollDelay
                outcome = await preparePacket(card)
                continue
            }
            guard runs < Self.maxPacketRuns else {
                var fix = PendingFix(card: card, entry: String(text.prefix(800)), state: .applying, headline: PendingFix.packetFailed)
                fix.state = .escalated(reason: "The review packet could not be prepared after \(runs) tries (\(text.prefix(160))); run Prepare review yourself.")
                fixes[card.id] = fix
                packTasks[card.id] = nil
                recordFix(fix, by: .pm, result: .escalated, why: "Packet kept failing for a passing reason after \(runs) tries.")
                return
            }
            recordReview(card, "Packet not ready (\(text.prefix(120))); trying again in a minute.", answer: "Retry")
            try? await Task.sleep(for: packetRetryDelay)
            guard !Task.isCancelled else { packTasks[card.id] = nil; return }
            runs += 1
            outcome = await preparePacket(card)
        }
        if !retried, case .failed(let text) = outcome, case .infrastructure(let reason) = PacketFailure.classify(text) {
            recordReview(card, "Packet could not run (\(reason.prefix(120))); trying once more.", answer: "Retry")
            try? await Task.sleep(for: infrastructureRetryDelay)
            guard !Task.isCancelled else { packTasks[card.id] = nil; return }
            await runPacket(card, first: await preparePacket(card), retried: true)
            return
        }
        await finishPacket(card, outcome)
    }

    /// The user presses Retry on "Packet could not run": the packet is prepared again from the start.
    func retryPacket(cardID: String) {
        guard let fix = fixes[cardID], fix.isRetryablePacket, packTasks[cardID] == nil else { return }
        fixes[cardID] = nil
        let card = fix.card
        packTasks[cardID] = Task { [weak self] in
            guard let self else { return }
            await self.runPacket(card)
        }
    }

    private func finishPacket(_ card: TaskCard, _ outcome: PacketOutcome) async {
        packTasks[card.id] = nil
        switch outcome {
        case .skipped: return
        case .ready: recordReview(card, "Review packet prepared.")
        case .failed(let text):
            let quote: String, notes: String
            var fixWhy = "Packet failed; fix request sent to the agent."
            switch PacketFailure.classify(text) {
            case .infrastructure(let reason):
                let log = PacketFailure.logPath(in: text).map { "\nLog: \($0)" } ?? ""
                var fix = PendingFix(card: card, entry: String(reason.prefix(300)) + log, state: .applying, headline: PendingFix.packetCouldNotRun)
                fix.state = .escalated(reason: "The test run broke twice in a row (\(reason.prefix(160))). That is not a test that fails, so nothing was sent to the agent. Retry runs the packet again.")
                fixes[card.id] = fix
                recordFix(fix, by: .pm, result: .escalated, why: "Packet could not run after a retry: \(reason.prefix(160))")
                return
            case .tests(let tests, let log):
                var own = tests, leftOut: [PacketFailure.FailedTest] = []
                if let checkOnMain {
                    switch await checkOnMain(card, tests.map(\.name)) {
                    case .failing(let names):
                        (own, leftOut) = PacketFailure.split(tests, failingOnMain: names)
                        if !leftOut.isEmpty { fixWhy += " Left out, they fail on \(baseBranch) too: \(leftOut.map(\.name).joined(separator: ", "))." }
                    case .unavailable(let reason):
                        fixWhy += " The tests could not be run on \(baseBranch) (\(reason.prefix(120))), so none was left out."
                    }
                }
                if own.isEmpty {
                    let list = tests.map(\.line).joined(separator: "\n") + (log.map { "\nLog: \($0)" } ?? "")
                    var fix = PendingFix(card: card, entry: list, state: .applying, headline: PendingFix.failsOnMain)
                    fix.state = .escalated(reason: "\(tests.count == 1 ? "This test also fails" : "These \(tests.count) tests also fail") on \(baseBranch), so the branch did not break \(tests.count == 1 ? "it" : "them"). Nothing was sent to the agent. Retry runs the packet again.")
                    fixes[card.id] = fix
                    recordFix(fix, by: .pm, result: .escalated, why: "Every failing test also fails on \(baseBranch): \(tests.map(\.name).joined(separator: ", ")).")
                    return
                }
                (notes, quote) = PacketFailure.fixNotes(own, log: log, leftOut: leftOut)
            case .workLeft(let lines):
                quote = String(lines.suffix(6).joined(separator: "\n").prefix(800))
                notes = "The review packet could not be prepared when you finished. Fix this, commit, redo the build and screenshots, and update the Report:\n\n\(quote)"
            }
            let rounds = (log?.recent(limit: 200, cardID: card.id) ?? []).filter { $0.kind == DecisionCategory.fix.rawValue && $0.by == .pm && $0.result == .answered }.count
            var fix = PendingFix(card: card, entry: quote, state: .applying, headline: PendingFix.packetFailed)
            guard policy.mode == .on else {
                fix.state = .escalated(reason: "The review packet could not be prepared; PM does not send fixes in Shadow mode.")
                fixes[card.id] = fix
                recordFix(fix, by: .pm, result: .escalated, why: "Packet failed.")
                return
            }
            guard rounds < Self.maxFixRounds else {
                fix.state = .escalated(reason: "The review packet failed again after \(Self.maxFixRounds) fix rounds; this one is yours.")
                fixes[card.id] = fix
                recordFix(fix, by: .pm, result: .escalated, why: "Packet failed after \(Self.maxFixRounds) fix rounds.")
                return
            }
            expectOwnFixNote(cardID: card.id, quoted: ReviewFlow.quoted(notes))
            fixes[card.id] = fix
            if let failure = await requestFix(card, notes) {
                fix.state = .escalated(reason: "The review packet failed and the fix request could not be sent: \(failure)")
                fixes[card.id] = fix
                recordFix(fix, by: .pm, result: .escalated, why: "Fix request not sent: \(failure)")
            } else {
                fixes[card.id] = nil
                recordFix(fix, by: .pm, result: .answered, why: fixWhy)
            }
        }
    }

    // MARK: rebase when main moved on

    static let rebaseKind = "rebase"

    static func rebaseNotes(behind: Int, base: String = "main") -> String {
        "Your branch is \(behind) commit\(behind == 1 ? "" : "s") behind \(base), so it can no longer be merged (fast-forward only). Rebase it onto \(base), resolve any conflicts, rerun both test suites (scripts/app-test.sh and bash tests/run.sh), and update the Report. Always answer in the Report, not in Fix notes: never write in Fix notes."
    }

    /// A card whose agent finished its turn (or a card in review without a packet) whose branch is behind main: its agent is asked once per
    /// main state to rebase (shadow: the user is offered the request). A card in review with a packet is left alone: Approve rebases it
    /// itself when that applies cleanly (N66) and asks the agent only on a conflict.
    private func scanBehind(_ cards: [TaskCard]) {
        // An analysis card is never merged, so main moving on does not matter to it.
        for card in cards where card.status.holdsAgent && card.kind != "analysis" {
            let hasPacket = !(card.sections["Review packet"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if card.status == .review && hasPacket { continue }
            let waiting = card.status == .review || isFinished(card)
            guard waiting, fixes[card.id] == nil, rebaseTasks[card.id] == nil, packTasks[card.id] == nil else { continue }
            if let last = rebaseChecked[card.id], now().timeIntervalSince(last) < Self.rebaseCheckSeconds { continue }
            rebaseChecked[card.id] = now()
            rebaseTasks[card.id] = Task { [weak self] in
                guard let self else { return }
                let behind = await self.behindMain(card)
                await self.finishBehind(card, behind)
            }
        }
    }

    private func finishBehind(_ card: TaskCard, _ behind: Int?) async {
        rebaseTasks[card.id] = nil
        // Up to date: the next time it is behind, main has moved on, even by the same number of commits.
        if behind == 0 { rebaseAsked[card.id] = nil }
        guard policy.mode != .off, let behind, behind > 0, rebaseAsked[card.id] != behind, fixes[card.id] == nil else { return }
        rebaseAsked[card.id] = behind
        var notes = Self.rebaseNotes(behind: behind, base: baseBranch)
        var why = "\(baseBranch) is \(behind) commit\(behind == 1 ? "" : "s") ahead of the branch."
        guard policy.mode == .on else {
            fixes[card.id] = PendingFix(card: card, entry: notes, state: .suggested(why: why), headline: PendingFix.behindMain)
            recordRebase(card, by: .pm, result: .suggested, why: why)
            return
        }
        // The panel rebases itself; the agent is asked only when that cannot be done cleanly (a conflict or unsaved work in its worktree).
        switch await rebaseNow(card) {
        case .rebased(let head):
            packed[card.id] = nil  // the branch changed: the review is prepared again on the new head
            rebaseAsked[card.id] = nil
            recordRebase(card, by: .pm, result: .answered, why: "Rebased onto \(baseBranch) by the panel; head is \(head.prefix(7)).", answer: "Rebased onto \(baseBranch)")
            return
        case .skipped:
            rebaseAsked[card.id] = nil  // not decided: look again later
            return
        case .conflict(let files):
            notes = ReviewFlow.conflictNotes(files: files, base: baseBranch)
            why = "Rebasing onto \(baseBranch) conflicts in \(files.joined(separator: ", ")); nothing was changed."
        case .dirty:
            notes = Self.dirtyRebaseNotes(base: baseBranch)
            why = "Rebasing onto \(baseBranch) needs a clean worktree; the agent's has unsaved work."
        }
        expectOwnFixNote(cardID: card.id, quoted: ReviewFlow.quoted(notes))
        if let failure = await requestFix(card, notes) {
            rebaseAsked[card.id] = nil
            let fix = PendingFix(card: card, entry: notes, state: .escalated(reason: "The rebase request could not be sent: \(failure)"), headline: PendingFix.behindMain)
            fixes[card.id] = fix
            recordRebase(card, by: .pm, result: .escalated, why: "Rebase request not sent: \(failure)")
        } else {
            recordRebase(card, by: .pm, result: .answered, why: why)
        }
    }

    static func dirtyRebaseNotes(base: String) -> String {
        "Your branch is behind \(base) and the panel could not rebase it because your worktree has unsaved changes. Commit them (or remove them), rebase onto \(base) yourself, resolve any conflicts, rerun both test suites (scripts/app-test.sh and bash tests/run.sh), and update the Report. Always answer in the Report, not in Fix notes: never write in Fix notes."
    }

    private func recordRebase(_ card: TaskCard, by: DecisionRecord.By, result: DecisionRecord.Result, why: String, answer: String? = nil) {
        guard let log else { return }
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: card.id, agent: card.agent ?? card.id, kind: Self.rebaseKind,
                               question: "Branch is behind \(baseBranch)", by: by, result: result, answer: result == .escalated ? "" : (answer ?? "Asked to rebase onto \(baseBranch)"),
                               why: String(why.prefix(300)), costUSD: nil)
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    private func recordReview(_ card: TaskCard, _ why: String, answer: String = "Review prepared") {
        guard let log else { return }
        let r = DecisionRecord(id: UUID().uuidString, time: now(), cardID: card.id, agent: card.agent ?? card.id, kind: DecisionCategory.review.rawValue,
                               question: "Agent finished: prepare the review", by: .pm, result: .answered, answer: answer, why: why, costUSD: nil)
        log.append(r)
        records.append(r)
        if records.count > 60 { records.removeFirst(records.count - 60) }
    }

    private func stopAll() {
        for task in packTasks.values { task.cancel() }
        packTasks = [:]
        for task in rebaseTasks.values { task.cancel() }
        rebaseTasks = [:]
        for task in tasks.values { task.cancel() }
        for task in fixTasks.values { task.cancel() }
        fixTasks = [:]
        tasks = [:]
        active = [:]
    }

    static func duration(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}

/// What the panel's own rebase of a card's branch came to (N207).
enum AutoRebaseResult: Equatable {
    case rebased(head: String)
    case conflict([String])
    case dirty
    case skipped
}
