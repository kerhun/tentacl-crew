import Foundation
import Observation

/// What a round did, for the decision feed.
struct RoundOutcome: Equatable {
    /// The cards that were started, in order.
    let started: [String]
    /// Which card failed and why; nil when every ticked card started.
    let failure: String?
    /// The PM's reason per card id.
    let reasons: [String: String]
    let cost: Double?
    /// The user's note for the round (empty when none).
    var note: String = ""
}

/// "Plan a round": the PM proposes 2 to 4 todo cards, the panel checks the proposal itself, the user ticks the cards and one approval
/// starts them one after another through the normal start flow. Whatever the PM says, only the panel's own checks decide what is listed.
@Observable @MainActor
final class RoundModel {
    struct Item: Identifiable, Equatable {
        enum Outcome: Equatable { case pending, started, failed(String) }

        let card: TaskCard
        let why: String
        let plan: StartPlan
        var ticked = true
        var outcome: Outcome = .pending
        var id: String { card.id }
    }

    struct Dropped: Equatable {
        let id: String
        let reason: String
    }

    struct Round: Equatable {
        var items: [Item]
        var dropped: [Dropped]
        var cost: Double? = nil
        var note: String = ""

        /// The sentence for a round that stopped on a failed start; nil when nothing failed.
        var failureText: String? {
            guard let failed = items.first(where: { if case .failed = $0.outcome { true } else { false } }), case .failed(let message) = failed.outcome else { return nil }
            let left = items.filter { $0.ticked && $0.outcome == .pending }.map(\.card.id)
            return "\(failed.card.id) failed to start: \(message)" + (left.isEmpty ? "" : " Not started: \(left.joined(separator: ", ")).")
        }
    }

    enum State: Equatable {
        case idle
        /// The sheet asks "What matters for this round?" before the PM is called.
        case asking
        /// The PM call is running.
        case planning
        case ready(Round)
        /// The ticked cards are being started.
        case starting(Round)
        /// The run is over and a start failed; the sheet says which.
        case finished(Round)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// "What matters for this round?": kept between rounds until the user changes it.
    var note = ""

    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored private let cards: () -> [TaskCard]
    @ObservationIgnored private let maxParallel: () -> Int
    @ObservationIgnored private let projectName: () -> String
    @ObservationIgnored private let propose: (RoundRequest) async throws -> RoundReply
    @ObservationIgnored private let planStart: (TaskCard) -> Result<StartPlan, StartError>
    @ObservationIgnored private let conflict: (TaskCard, TaskCard) async -> String?
    @ObservationIgnored private let start: (StartPlan) async -> String?
    @ObservationIgnored private let record: (RoundOutcome) -> Void
    /// The id of the project the closures above work on now; a request bound to another project stops when it differs.
    @ObservationIgnored private let projectID: () -> String?
    /// Where "Not now" and "the user started the first round" are kept; nil (tests) keeps nothing and counts the first round as done.
    @ObservationIgnored private let defaults: UserDefaults?
    /// The user's safe point and the 5-hour usage now (told to the PM), and why nothing may start now (nil when something may).
    @ObservationIgnored private let safePoint: () -> (SafePoint, PlanUsage?)
    @ObservationIgnored private let safePointReason: () -> String?
    /// The Codex 5-hour usage now when some role uses Codex (told to the PM next to Claude's).
    @ObservationIgnored private let codexUsage: () -> PlanUsage?

    init(enabled: @escaping () -> Bool, cards: @escaping () -> [TaskCard], maxParallel: @escaping () -> Int, projectName: @escaping () -> String,
         propose: @escaping (RoundRequest) async throws -> RoundReply, planStart: @escaping (TaskCard) -> Result<StartPlan, StartError>,
         conflict: @escaping (TaskCard, TaskCard) async -> String?, start: @escaping (StartPlan) async -> String?, record: @escaping (RoundOutcome) -> Void,
         projectID: @escaping () -> String? = { nil }, defaults: UserDefaults? = nil,
         safePoint: @escaping () -> (SafePoint, PlanUsage?) = { (SafePoint(percent: nil), nil) }, safePointReason: @escaping () -> String? = { nil },
         codexUsage: @escaping () -> PlanUsage? = { nil }) {
        self.safePoint = safePoint; self.safePointReason = safePointReason; self.codexUsage = codexUsage
        self.enabled = enabled; self.cards = cards; self.maxParallel = maxParallel; self.projectName = projectName; self.propose = propose
        self.planStart = planStart; self.conflict = conflict; self.start = start; self.record = record; self.projectID = projectID; self.defaults = defaults
    }

    /// Opens the sheet on the note field; "Plan" there calls `plan()`.
    func begin() {
        guard enabled() else { return }
        if case .ready = state { hidden = false; return }   // a hidden proposal comes back instead of a second round
        guard state == .idle else { return }
        state = .asking
    }

    var isOpen: Bool { state != .idle }

    /// Cancel on a ready round only hides the sheet; the proposal stays (and the pinned card reopens it).
    private(set) var hidden = false
    var showsSheet: Bool { isOpen && !hidden }

    func cancel() {
        if case .ready = state { hidden = true } else { close() }
    }

    func reopen() { if case .ready = state { hidden = false } }

    /// The cards of a round that waits for "Start round" (ticked ones); empty in every other state.
    var waitingIDs: [String] {
        if case .ready(let round) = state { return round.items.filter(\.ticked).map(\.card.id) }
        return []
    }

    var canStart: Bool {
        if case .ready(let round) = state { return round.items.contains(where: \.ticked) }
        return false
    }

    // MARK: plan

    func plan() async {
        guard enabled() else { return }
        switch state { case .planning, .starting: return; default: break }
        if let reason = safePointReason() { state = .failed(reason); return }
        let said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = cards()
        let slots = maxParallel() - AgentSleep.slotsHeld(all)
        guard slots > 0 else { state = .failed("No free slot: \(maxParallel()) tasks are already running (the project's limit)."); return }
        let todo = all.filter { $0.status == .todo }
        guard !todo.isEmpty else { state = .failed("No todo cards to plan a round from."); return }
        let doneIDs = Set(all.filter { $0.status == .done }.map(\.id))
        let known = Set(all.map(\.id))
        // Cards the panel would refuse anyway are not worth the PM's time: list them as left out, ask about the rest.
        var leftOut: [Dropped] = []
        var startable: [TaskCard] = []
        for c in todo {
            if let reason = startBlocker(c, known: known, doneIDs: doneIDs).reason { leftOut.append(Dropped(id: c.id, reason: reason)) } else { startable.append(c) }
        }
        guard !startable.isEmpty else {
            state = .failed("No todo card can start: " + leftOut.map { "\($0.id): \($0.reason)" }.joined(separator: " "))
            return
        }
        state = .planning
        let request = RoundRequest(projectName: projectName(), slots: slots, candidates: startable.map { c in
            let deps = c.sections["Dependencies"] ?? ""
            let unmet = Self.mentioned(in: deps, known: known, except: c.id).filter { !doneIDs.contains($0) }
            return RoundCandidate(id: c.id, title: c.title, goal: c.sections["Goal"] ?? "", dependencies: deps, unmet: unmet, files: c.files, priority: c.priority)
        }, note: said, safePoint: safePoint().0, usage: safePoint().1, codexUsage: codexUsage())
        let reply: RoundReply
        do { reply = try await propose(request) }
        catch {
            guard state == .planning else { return }
            state = .failed("The PM could not plan a round: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return
        }
        guard state == .planning else { return }   // closed while the PM was thinking
        var round = await check(reply.proposal, cards: all, slots: slots, doneIDs: doneIDs)
        round.cost = reply.costUSD
        round.note = said
        round.dropped = leftOut + round.dropped.filter { d in !leftOut.contains(where: { $0.id == d.id }) }
        guard state == .planning else { return }
        state = round.items.isEmpty ? .failed("None of the PM's picks can start now. " + round.dropped.map { "\($0.id): \($0.reason)" }.joined(separator: " ")) : .ready(round)
    }

    /// The panel's own check of a proposal: existing todo cards, dependencies done, no shared files, a start plan, and the free slots.
    private func check(_ proposal: RoundProposal, cards all: [TaskCard], slots: Int, doneIDs: Set<String>, allowing statuses: [TaskStatus] = [.todo]) async -> Round {
        let known = Set(all.map(\.id))
        var items: [Item] = []
        var dropped: [Dropped] = []
        var seen: Set<String> = []
        for pick in proposal.cards {
            func drop(_ reason: String) { dropped.append(Dropped(id: pick.id, reason: reason)) }
            guard seen.insert(pick.id).inserted else { drop("the PM listed it twice"); continue }
            guard let card = all.first(where: { $0.id == pick.id }) else { drop("no such card"); continue }
            guard statuses.contains(card.status) else {
                drop(statuses == [.todo] ? "not a todo card (it is \"\(card.status.label)\")" : "its status is \"\(card.status.label)\"; only todo and awaiting-start-approval cards can start")
                continue
            }
            let (reason, found) = startBlocker(card, known: known, doneIDs: doneIDs)
            if let reason { drop(reason); continue }
            guard let plan = found else { continue }
            var overlap: String?
            for other in items {
                if let found = await conflict(card, other.card) { overlap = "shares files with \(other.card.id): \(Self.firstLine(found))"; break }
            }
            if let overlap { drop(overlap); continue }
            guard items.count < slots, items.count < RoundPrompt.maxCards else { drop("over the limit: only \(min(slots, RoundPrompt.maxCards)) can run in this round"); continue }
            items.append(Item(card: card, why: pick.why, plan: plan))
        }
        return Round(items: items, dropped: dropped)
    }

    /// Why a todo card cannot start (dependencies not done, no start plan, the team chart refuses), or its start plan.
    private func startBlocker(_ card: TaskCard, known: Set<String>, doneIDs: Set<String>) -> (reason: String?, plan: StartPlan?) {
        let unmet = Self.mentioned(in: card.sections["Dependencies"] ?? "", known: known, except: card.id).filter { !doneIDs.contains($0) }
        if !unmet.isEmpty { return ("blocked: \(unmet.joined(separator: ", ")) is not done", nil) }
        switch planStart(card) {
        case .failure(let error): return (error.message.replacingOccurrences(of: "Cannot start: ", with: ""), nil)
        case .success(let plan):
            if case .denied(let why) = plan.authority { return ("the team chart does not allow it: \(why)", nil) }
            return (nil, plan)
        }
    }

    /// The card ids named in a Dependencies text, in order.
    static func mentioned(in text: String, known: Set<String>, except own: String) -> [String] {
        DependencyGraph.mentioned(in: text, known: known, except: own)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    // MARK: ticks and start

    func toggle(_ id: String) {
        guard case .ready(var round) = state, let i = round.items.firstIndex(where: { $0.id == id }) else { return }
        round.items[i].ticked.toggle()
        state = .ready(round)
    }

    /// Called after the user's "Start round" started at least one card (N171: the PM begins a fresh conversation).
    @ObservationIgnored var onRoundStarted: (() -> Void)?

    /// Starts the ticked cards one after another; the first failure stops the rest.
    func start() async {
        guard canStart, case .ready(var round) = state else { return }
        state = .starting(round)
        let (started, failure) = await execute(&round, publish: true)
        if !started.isEmpty, let defaults { defaults.set(true, forKey: Self.firstRoundKey + (projectID() ?? "")) }
        record(RoundOutcome(started: started, failure: failure, reasons: Dictionary(round.items.map { ($0.id, $0.why) }, uniquingKeysWith: { a, _ in a }), cost: round.cost, note: round.note))
        state = failure == nil ? .idle : .finished(round)
        if !started.isEmpty { onRoundStarted?() }
    }

    /// Starts the ticked items in order and stops at the first failure. `publish`: show the progress in the sheet.
    /// `project`: the project the request belongs to; a start is not made once another project is open.
    private func execute(_ round: inout Round, publish: Bool, project: String? = nil) async -> (started: [String], failure: String?) {
        var started: [String] = []
        var failure: String?
        for i in round.items.indices where round.items[i].ticked {
            let message: String?
            if let project, projectID() != project { message = Self.projectChanged } else { message = await start(round.items[i].plan) }
            if let message {
                round.items[i].outcome = .failed(message)
                failure = round.failureText
                if publish { state = .starting(round) }
                break
            }
            round.items[i].outcome = .started
            started.append(round.items[i].id)
            if publish { state = .starting(round) }
        }
        return (started, failure)
    }

    // MARK: starts the user asked the PM for

    /// What became of a start the PM asked for in the chat.
    struct RequestResult: Equatable {
        var started: [String] = []
        var refused: [Dropped] = []
        /// A start failed (the rest were not tried); nil when every accepted card started or none was tried.
        var failure: String?
        /// The accepted cards wait in the Round sheet, ticked, for the user's one click.
        var sheet = false
        /// The start would have needed no sheet, but this is the project's first round, which only the user's click starts.
        var firstRound = false
    }

    static let projectChanged = "the project changed while the request ran, so nothing more was started"

    /// Cards the user can start by hand: the same ones a requested start may name.
    private static let requestable: [TaskStatus] = [.todo, .awaitingStartApproval]

    /// Checks the named cards with the panel's own rules (status, role, team chart, dependencies, shared files, free slots) and either starts
    /// the accepted ones (`startNow`, no sheet) or opens the Round sheet with them ticked. Nil when the sheet is in use: try again later.
    /// The project's first round always opens the sheet, whatever `startNow` says. `why`: the reason shown per card (default: the user's words).
    func fulfil(ids: [String], words: String, startNow: Bool, project: String? = nil, why: String? = nil) async -> RequestResult? {
        guard state == .idle else { return nil }
        let firstRound = startNow && !firstRoundStarted
        let startNow = startNow && !firstRound
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        let all = cards()
        let slots = maxParallel() - AgentSleep.slotsHeld(all)
        var round: Round
        if slots <= 0 {
            let why = "no free slot: \(maxParallel()) tasks are already running (the project's limit)"
            round = Round(items: [], dropped: unique.map { Dropped(id: $0, reason: why) })
        } else {
            let said = why ?? "You asked the PM: \"\(String(words.prefix(200)))\""
            round = await check(RoundProposal(cards: unique.map { RoundPick(id: $0, why: said) }), cards: all, slots: slots,
                                doneIDs: Set(all.filter { $0.status == .done }.map(\.id)), allowing: Self.requestable)
        }
        guard state == .idle else { return nil }
        if let project, projectID() != project { return RequestResult(refused: [], failure: Self.projectChanged) }
        guard !round.items.isEmpty else { return RequestResult(refused: round.dropped) }
        guard startNow else {
            state = .ready(round); hidden = false
            return RequestResult(refused: round.dropped, sheet: true, firstRound: firstRound)
        }
        let (started, failure) = await execute(&round, publish: false, project: project)
        return RequestResult(started: started, refused: round.dropped, failure: failure)
    }

    // MARK: the PM's plan (plan.json): Approve plan & start round (N167)

    /// The open project's plan.json, as last read (when the cards reload), and whose it is.
    private(set) var plan: PlanFile?
    private var planProject: String?
    /// "Not now": the name of the waiting round the user put off, per project.
    private var putOff: [String: String] = [:]
    /// What the last "Approve plan & start round" could not do (nothing could start); nil when the sheet opened.
    private(set) var approveMessage: String?

    static let firstRoundKey = "planFirstRoundStarted."
    static let notNowKey = "planRoundNotNow."

    func notePlan(_ load: PlanLoad, project: String?) {
        let file: PlanFile? = if case .plan(let f) = load { f } else { nil }
        if file != plan { plan = file }
        if planProject != project {
            planProject = project
            approveMessage = nil
            if let project, putOff[project] == nil, let name = defaults?.string(forKey: Self.notNowKey + project) { putOff[project] = name }
        }
    }

    /// The first round in the plan that waits for the user and none of whose cards has started yet.
    static func waitingRound(in plan: PlanFile, cards: [TaskCard]) -> PlanRound? {
        let status = Dictionary(cards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        return plan.rounds.first { round in
            round.status.lowercased() == "waiting" && round.cards.allSatisfy { status[$0].map { requestable.contains($0) || $0 == .cancelled } ?? true }
        }
    }

    /// The open project's plan once it has been read; nil before that or for another project's.
    var currentPlan: PlanFile? {
        guard let plan, planProject == nil || projectID() == nil || planProject == projectID() else { return nil }
        return plan
    }

    /// The waiting round of the open project's plan (the Plan screen offers it even after "Not now").
    var waitingPlanRound: PlanRound? {
        guard let plan, planProject == nil || projectID() == nil || planProject == projectID() else { return nil }
        return Self.waitingRound(in: plan, cards: cards())
    }

    /// The waiting round for the Dashboard's "Waiting for you": not once the user said "Not now" to it.
    var waitingForYouPlanRound: PlanRound? {
        guard let round = waitingPlanRound, putOff[planProject ?? ""] != round.name else { return nil }
        return round
    }

    func notNow(_ round: PlanRound) {
        let key = planProject ?? ""
        putOff[key] = round.name
        defaults?.set(round.name, forKey: Self.notNowKey + key)
    }

    /// No card has started yet (a setup card such as G1 is not a round): the next round is the project's first.
    static func isFirstRound(_ cards: [TaskCard]) -> Bool {
        !cards.contains { $0.kind != "setup" && !requestable.contains($0.status) && $0.status != .cancelled }
    }

    /// The user has started a round of this project (or cards ran before this rule): starts may skip the sheet again.
    private var firstRoundStarted: Bool {
        guard let defaults else { return true }
        return defaults.bool(forKey: Self.firstRoundKey + (projectID() ?? "")) || !Self.isFirstRound(cards())
    }

    /// Why "Approve plan & start round" cannot be clicked: the project cannot start agents (git not initialized…), the round is empty,
    /// or a card's role runs on a tool the Setup check found missing. Nil when it can.
    static func approveBlocker(_ round: PlanRound, cards: [TaskCard], startReason: String?, setup: [SetupItem], toolOf: (String) -> AgentTool) -> String? {
        if let startReason { return startReason }
        if round.cards.isEmpty { return "Round \(round.name) lists no cards." }
        for id in round.cards {
            guard let card = cards.first(where: { $0.id == id }) else { continue }
            let tool = toolOf(card.roles.first ?? "dev")
            let ids: [SetupItemID] = tool == .codex ? [.codex, .codexSignIn] : [.claude, .claudeSignIn]
            if let item = setup.first(where: { ids.contains($0.id) && $0.state == .missing }) {
                return "\(id) needs \(tool == .codex ? "Codex" : "Claude Code"): \(item.detail) See Setup."
            }
        }
        return nil
    }

    /// "Approve plan & start round": the Round sheet opens with the round's cards ticked, after the usual checks; "Start round" there starts them.
    func approvePlan(_ round: PlanRound) async -> RequestResult? {
        approveMessage = nil
        let why = "Round \(round.name) of the PM's plan" + (round.reason.isEmpty ? "." : ": \(round.reason)")
        let result = await fulfil(ids: round.cards, words: "Plan approved", startNow: false, project: projectID(), why: why)
        if let result, !result.sheet {
            approveMessage = result.failure ?? ("Nothing in round \(round.name) can start now: " + result.refused.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ") + ".")
        }
        return result
    }

    /// Quit: the sheet goes away even while cards are starting (the app is leaving; the start loop dies with it).
    func forceClose() { state = .idle; hidden = false }

    /// Throws the round away (the sheet's "Discard round", or Close once it is over).
    func close() {
        if case .starting = state { return }
        state = .idle
        hidden = false
    }
}
