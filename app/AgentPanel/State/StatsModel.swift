import Foundation
import Observation

/// One task with what it waits for and what waits for it.
struct BacklogItem: Identifiable, Equatable {
    let card: TaskCard
    /// Every card named in the Dependencies section.
    let dependsOn: [String]
    /// The part of `dependsOn` that is not done yet (empty for a finished card).
    let blockedBy: [String]
    /// The cards that name this one in their Dependencies and are not finished themselves.
    let blocks: [String]
    var id: String { card.id }
}

struct BacklogGroup: Identifiable, Equatable {
    let title: String
    let items: [BacklogItem]
    var id: String { title }
}

/// The read-only backlog: cards grouped by status, with their dependencies. Pure.
@MainActor enum Backlog {
    static func groups(from cards: [TaskCard]) -> [BacklogGroup] {
        let known = Set(cards.map(\.id))
        let doneIDs = Set(cards.filter { $0.status == .done }.map(\.id))
        let dependsOn = Dictionary(cards.map { ($0.id, RoundModel.mentioned(in: $0.sections["Dependencies"] ?? "", known: known, except: $0.id)) }, uniquingKeysWith: { a, _ in a })
        // Who waits for each card, in card order (one pass; asking every card about every other made a big plan slow to draw).
        var waitingFor: [String: [String]] = [:]
        for other in cards where !(other.status == .done || other.status == .cancelled) {
            for id in Set(dependsOn[other.id] ?? []) { waitingFor[id, default: []].append(other.id) }
        }
        func item(_ card: TaskCard) -> BacklogItem {
            let deps = dependsOn[card.id] ?? []
            let finished = card.status == .done || card.status == .cancelled
            let waiting = waitingFor[card.id] ?? []
            return BacklogItem(card: card, dependsOn: deps, blockedBy: finished ? [] : deps.filter { !doneIDs.contains($0) }, blocks: waiting)
        }
        return TaskGrouping.sections(from: cards.map { .card($0) }).map { section in
            BacklogGroup(title: section.title, items: section.rows.compactMap { if case .card(let c) = $0 { return item(c) } else { return nil } })
        }
    }
}

/// A line of the panel's action log: when, and what was done.
struct ActionLogEvent: Equatable {
    let time: Date
    let text: String
    /// The project the line belongs to; nil for lines written before projects were recorded.
    var project: String? = nil

    /// Whether the line may be about a card of this project: untagged (old) lines match every project.
    func concerns(project id: String) -> Bool { project == nil || project == id }
}

enum ActionLogEvents {
    /// `2026-10-17T08:00:00Z` (what the log writes) without the formatter: parsing thousands of lines with it took hundreds of ms.
    /// Nil for any other shape, which the formatter then reads.
    static func utcTime(_ text: Substring) -> Date? {
        let b = Array(text.utf8)
        guard b.count == 20, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58, b[19] == 90 else { return nil }
        func num(_ from: Int, _ to: Int) -> Int? {
            var n = 0
            for i in from..<to { guard b[i] >= 48, b[i] <= 57 else { return nil }; n = n * 10 + Int(b[i] - 48) }
            return n
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let h = num(11, 13), let mi = num(14, 16), let sec = num(17, 19),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        // Days since 1970-01-01 (proleptic Gregorian).
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + sec))
    }

    /// Lines look like `2026-10-17T08:00:00Z [project] start N1 agent=… ` (older ones have no `[project]`); anything else is skipped.
    static func parse(_ log: String) -> [ActionLogEvent] {
        let formatter = ISO8601DateFormatter()
        return log.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " "), let time = utcTime(line[..<space]) ?? formatter.date(from: String(line[..<space])) else { return nil }
            var text = String(line.suffix(from: line.index(after: space)))
            var project: String?
            if text.hasPrefix("["), let close = text.firstIndex(of: "]"), text[text.index(after: close)...].hasPrefix(" "), close > text.index(after: text.startIndex) {
                project = String(text[text.index(after: text.startIndex)..<close])
                text = String(text[text.index(close, offsetBy: 2)...])
            }
            return ActionLogEvent(time: time, text: text, project: project)
        }
    }
}

struct DayCount: Equatable { let day: Date; let count: Int; var ids: [String] = [] }
/// What a finished card cost: its agent's session (nil when the session cannot be read) and the PM's decisions about it.
/// `session` is what the session files held, for the model and tokens of the Stats table.
struct CardCost: Equatable { var agent: Double?; var pm: Double; var session: SessionCost? = nil }
/// `tokensOnly`: a Codex task, which has tokens but no dollars; it is not "unknown".
struct TaskCostLine: Equatable { let cardID: String; let dollars: Double?; var tokensOnly = false }
struct DayCost: Equatable { let day: Date; let dollars: Double }

/// A step of a card's way from start to merge, from the action log.
struct FlowStep: Equatable {
    enum Kind: Equatable { case start, packet, fix, approved }
    let kind: Kind
    let time: Date

    var title: String {
        switch kind {
        case .start: return "Started"
        case .packet: return "Review packet ready"
        case .fix: return "Fix asked"
        case .approved: return "Approved"
        }
    }
}

/// A merged card's time from its first start to its approval, split into the agent's work and the wait for the user's decision.
struct CardFlow: Equatable {
    let cardID: String
    /// Start → packet prepared, and fix request → the next packet.
    var agent: TimeInterval
    /// Packet prepared → fix request or approval.
    var waiting: TimeInterval
    var fixes: Int
    var packets: Int
    /// The steps counted, in order: the start, each packet and fix request, the approval.
    var steps: [FlowStep]
    var start: Date { steps.first!.time }
    var approved: Date { steps.last!.time }
    var total: TimeInterval { approved.timeIntervalSince(start) }

    /// Walks the card's steps from its first start to its last approval; a packet while waiting or a fix while the agent works changes nothing.
    static func make(cardID: String, steps all: [FlowStep]) -> CardFlow? {
        guard let first = all.firstIndex(where: { $0.kind == .start }), let last = all.lastIndex(where: { $0.kind == .approved }), last > first else { return nil }
        var flow = CardFlow(cardID: cardID, agent: 0, waiting: 0, fixes: 0, packets: 0, steps: [all[first]])
        var mark = all[first].time, waitingNow = false
        for step in all[(first + 1)..<last] {
            switch step.kind {
            case .packet where !waitingNow:
                flow.agent += step.time.timeIntervalSince(mark); waitingNow = true; flow.packets += 1
            case .fix where waitingNow:
                flow.waiting += step.time.timeIntervalSince(mark); waitingNow = false; flow.fixes += 1
            default: continue
            }
            mark = step.time
            flow.steps.append(step)
        }
        let end = all[last].time.timeIntervalSince(mark)
        if waitingNow { flow.waiting += end } else { flow.agent += end }
        flow.steps.append(all[last])
        return flow
    }
}

/// A row of the "Cards in this range" table.
struct StatsCardRow: Equatable {
    let cardID: String
    let title: String
    /// Model, effort and tokens as the Tasks screen's Agent box shows them (N135).
    let facts: AgentFacts
    let flow: CardFlow?
    /// Agent and PM together; nil when the agent's cost is unknown.
    let dollars: Double?
    /// A Codex task: tokens, no dollars (shown as "tokens only", not "unknown").
    var tokensOnly = false
    /// The tool whose session the tokens came from: Codex when every token was Codex's, else Claude; nil without a session.
    var tool: AgentTool? = nil
}

struct Stats: Equatable {
    var days = 14
    /// Merged cards per day of the range, oldest first, with their ids.
    var merged: [DayCount] = []
    var previousMergedCount = 0
    /// Whether the action log reaches back to the start of the range before this one (else `previousMergedCount` only has file dates).
    var logCoversBefore = false
    /// The merged cards of the range that have a start, a review packet and an approval or merge in the log, newest merge first.
    var flows: [CardFlow] = []
    /// The merged cards of the range left out of `flows` (old cards merged in bulk, or with lines missing in the log).
    var flowsLeftOut = 0
    var taskCosts: [TaskCostLine] = []
    var costPerDay: [DayCost] = []
    var rows: [StatsCardRow] = []
    /// The plan's rounds with something recorded in the range, newest first.
    var rounds: [StatsRoundRow] = []

    var mergedCount: Int { merged.reduce(0) { $0 + $1.count } }
    /// The estimated cost of the tasks finished in the period; tasks with an unknown cost are left out and counted below.
    var totalCost: Double { costPerDay.reduce(0) { $0 + $1.dollars } }
    var unknownCostTasks: Int { taskCosts.filter { $0.dollars == nil && !$0.tokensOnly }.count }
    /// Codex tasks: tokens are counted, dollars are not.
    var tokensOnlyTasks: Int { taskCosts.filter(\.tokensOnly).count }
    /// Merged cards of the range per tool (cards without a readable session are in neither).
    var claudeCards: Int { rows.filter { $0.tool == .claude }.count }
    var codexCards: Int { rows.filter { $0.tool == .codex }.count }
    /// "12 Claude · 3 Codex"; nil while no merged card ran on Codex (Claude alone needs no split).
    var toolSplitText: String? { codexCards == 0 ? nil : "\(claudeCards) Claude · \(codexCards) Codex" }
    /// The total over the cards whose cost is known.
    var costPerMerged: Double? {
        let known = taskCosts.filter { $0.dollars != nil }.count
        return known == 0 ? nil : totalCost / Double(known)
    }
    var medianTotal: TimeInterval? { Self.median(flows.map(\.total)) }
    var medianAgent: TimeInterval? { Self.median(flows.map(\.agent)) }
    var medianWaiting: TimeInterval? { Self.median(flows.map(\.waiting)) }
    /// Merged cards of the range that had a review packet, and those of them that needed a fix round.
    var packetCards: Int { flows.filter { $0.packets > 0 }.count }
    var neededFix: Int { flows.filter { $0.packets > 0 && $0.fixes > 0 }.count }
    var firstPassPercent: Int? { packetCards == 0 ? nil : Int((Double(packetCards - neededFix) / Double(packetCards) * 100).rounded()) }

    /// "+137 vs the 7 days before", "−5 vs …", "same as …"; without the log for the days before, the change would only count file dates.
    static func changeText(now: Int, before: Int, days: Int, logCoversBefore: Bool) -> String {
        guard logCoversBefore else { return "no log for the \(days) days before" }
        let change = now - before
        return change == 0 ? "same as the \(days) days before" : "\(change > 0 ? "+" : "−")\(abs(change)) vs the \(days) days before"
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted(), mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }

    /// The steps of each card in the log, keyed by project and card id (start with an agent, packet prepared, fix request sent, approved or
    /// merged by `merge-task.sh`, which writes `merged <card> <commit> (script)` and no approval line).
    static func steps(_ events: [ActionLogEvent]) -> [String: [FlowStep]] {
        var result: [String: [FlowStep]] = [:]
        for e in events.sorted(by: { $0.time < $1.time }) {
            let words = e.text.split(separator: " ")
            guard let first = words.first else { continue }
            var found: (FlowStep.Kind, Substring)?
            switch first {
            case "start" where words.count >= 3 && words[2].hasPrefix("agent="): found = (.start, words[1])
            case "approved" where words.count >= 2: found = (.approved, words[1])
            case "merged" where words.count == 4 && words[3] == "(script)" && words[2].count == 40: found = (.approved, words[1])
            case "review" where words.count == 5 && words[1] == "packet" && words[2] == "prepared": found = (.packet, words[4])
            case "fix" where words.count >= 6 && words[1] == "request" && e.text.contains(" sent to ") && words[words.count - 2] == "for": found = (.fix, words[words.count - 1])
            default: break
            }
            if let (kind, id) = found { result[key(e.project, String(id)), default: []].append(FlowStep(kind: kind, time: e.time)) }
        }
        return result
    }

    private static func key(_ project: String?, _ id: String) -> String { "\(project ?? "")|\(id)" }

    /// Merged cards per day of the last `days` days (the day of the approval in the log, else the day the done card was last changed), their
    /// costs, the time from the first successful start to the last approval of each and the table rows. `roles` by name, for the effort.
    static func compute(cards: [TaskCard], events: [ActionLogEvent], costs: [String: CardCost] = [:], roles: [String: RoleConfig] = [:],
                        calendar: Calendar = .current, now: Date = Date(), days: Int = 14) -> Stats {
        var stats = Stats()
        stats.days = days
        let steps = Self.steps(events)
        // Lines with a project belong to that project's card; old lines without one are used for any project.
        func stepsOf(_ c: TaskCard) -> [FlowStep] {
            let tagged = steps[key(c.project, c.id)] ?? [], old = steps[key(nil, c.id)] ?? []
            return old.isEmpty ? tagged : (tagged + old).sorted { $0.time < $1.time }
        }
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let before = calendar.date(byAdding: .day, value: -days, to: first) ?? first
        var byDay: [Date: [String]] = [:]
        var costByDay: [Date: Double] = [:]
        var flows: [CardFlow] = []
        let beforeEnd = calendar.date(byAdding: .day, value: 1, to: before) ?? first
        stats.logCoversBefore = events.contains { $0.time < beforeEnd }
        for c in cards where c.status == .done {
            let cardSteps = stepsOf(c)
            let cost = costs[c.id].flatMap { k in k.agent.map { $0 + k.pm } }
            guard let when = cardSteps.last(where: { $0.kind == .approved })?.time ?? c.modified else { stats.taskCosts.append(TaskCostLine(cardID: c.id, dollars: cost, tokensOnly: costs[c.id]?.session?.isTokensOnly == true)); continue }
            let day = calendar.startOfDay(for: when)
            if day >= before, day < first { stats.previousMergedCount += 1 }
            guard day >= first, day <= today else { continue }
            byDay[day, default: []].append(c.id)
            stats.taskCosts.append(TaskCostLine(cardID: c.id, dollars: cost, tokensOnly: costs[c.id]?.session?.isTokensOnly == true))
            if let cost { costByDay[day, default: 0] += cost }
            // Without a review packet the time cannot be split (old cards were approved in bulk a minute after a start).
            let flow = CardFlow.make(cardID: c.id, steps: cardSteps).flatMap { $0.packets > 0 ? $0 : nil }
            if let flow { flows.append(flow) } else { stats.flowsLeftOut += 1 }
            let role = roles[c.roles.first ?? "dev"]
            let session = costs[c.id]?.session
            stats.rows.append(StatsCardRow(cardID: c.id, title: c.title, facts: AgentFacts.make(role: role, cost: session, hasAgent: session != nil), flow: flow, dollars: cost, tokensOnly: session?.isTokensOnly == true,
                                          tool: session.map { $0.isTokensOnly ? .codex : .claude }))
        }
        stats.flows = flows.sorted { $0.approved == $1.approved ? $0.cardID > $1.cardID : $0.approved > $1.approved }
        stats.rows.sort { ($0.dollars ?? -1, $1.cardID) > ($1.dollars ?? -1, $0.cardID) }
        stats.merged = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }.map { DayCount(day: $0, count: byDay[$0]?.count ?? 0, ids: byDay[$0] ?? []) }
        stats.costPerDay = stats.merged.map { DayCost(day: $0.day, dollars: costByDay[$0.day] ?? 0) }
        return stats
    }

    /// What today cost so far: the tasks approved today (agent and PM) plus the PM's decisions of today about cards that are not done.
    /// Agents still working are not counted until their task is done.
    static func todayCost(cards: [TaskCard], events: [ActionLogEvent], costs: [String: CardCost], decisions: [DecisionRecord], calendar: Calendar = .current, now: Date = Date()) -> Double {
        let stats = compute(cards: cards, events: events, costs: costs, calendar: calendar, now: now, days: 1)
        let doneIDs = Set(cards.filter { $0.status == .done }.map(\.id))
        let pm = decisions.filter { calendar.isDate($0.time, inSameDayAs: now) && !doneIDs.contains($0.cardID) }.reduce(0) { $0 + ($1.costUSD ?? 0) }
        return stats.totalCost + pm
    }

    /// Costs are estimates (see `PriceTable`); a cost that could not be worked out is "unknown", not zero.
    static func costText(_ dollars: Double?) -> String {
        guard let dollars else { return "unknown" }
        return dollars > 0 && dollars < 0.01 ? "≈ < $0.01" : "≈ " + String(format: "$%.2f", dollars)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        let hours = minutes / 60
        return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
    }

    /// The Stats screen's compact form: "41m", "1h 05m", "26h 10m".
    static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h " + String(format: "%02dm", minutes % 60)
    }
}

/// A row of the Stats screen's Rounds table: a round of plan.json and where its time went (built like the Timeline's summary).
struct StatsRoundRow: Equatable {
    let name: String
    let cards: [String]
    let start: Date
    let end: Date
    let summary: RoundSummary
}

extension Stats {
    /// The rounds whose recorded span reaches into the last `days` days, newest start first. Rounds with nothing recorded are left out.
    static func rounds(_ plan: [PlanRound], project: String, cards: [TaskCard], events: [ActionLogEvent], decisions: [DecisionRecord],
                       agentCosts: [String: Double] = [:], calendar: Calendar = .current, now: Date = Date(), days: Int = 14) -> [StatsRoundRow] {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return plan.compactMap { round -> StatsRoundRow? in
            let data = RoundTimeline.build(round: round, project: project, cards: cards, events: events, decisions: decisions, agentCosts: agentCosts)
            guard let start = data.start, let end = data.end, end >= first else { return nil }
            return StatsRoundRow(name: round.name, cards: round.cards, start: start, end: end, summary: data.summary)
        }
        .sorted { $0.start == $1.start ? $0.name > $1.name : $0.start > $1.start }
    }

    /// "1 h 20 min" with "≈ " in front when the number rests on a guess.
    static func roundText(_ seconds: TimeInterval?, _ part: RoundSummary.Part, in summary: RoundSummary) -> String {
        guard let seconds else { return "—" }
        return (summary.estimated.contains(part) ? "≈ " : "") + shortDuration(seconds)
    }

    /// "3", "3 · 1 infra" (how many of the fix turns were broken test runs, not the agent's code).
    static func fixTurnsText(_ s: RoundSummary) -> String {
        s.infrastructureTurns > 0 ? "\(s.fixTurns) · \(s.infrastructureTurns) infra" : "\(s.fixTurns)"
    }
}

/// The Stats screen's range, remembered per project.
enum StatsRange: Int, CaseIterable {
    case week = 7, twoWeeks = 14, month = 30

    var title: String { "\(rawValue) days" }

    private static func storageKey(_ project: String) -> String { "statsRange.\(project)" }

    static func load(_ defaults: UserDefaults, project: String) -> StatsRange {
        StatsRange(rawValue: defaults.integer(forKey: storageKey(project))) ?? .twoWeeks
    }

    func save(_ defaults: UserDefaults, project: String) { defaults.set(rawValue, forKey: Self.storageKey(project)) }
}

/// Holds the statistics shown on the Stats screen; reloaded whenever the screen opens.
@MainActor @Observable
final class StatsModel {
    private(set) var stats = Stats()
    /// Today's estimated cost for the autopilot's daily limit.
    private(set) var todayCost = 0.0
    /// The plan's 5-hour and weekly use that Claude Code reported; nil when nothing has been seen.
    private(set) var usage: PlanUsage?
    /// The Codex plan windows, on the top bar's rule (a role uses Codex or a Codex session wrote in the last 5 hours); nil hides the section.
    var codexUsage: PlanUsage? { model.shownCodexUsage }
    /// The top bar's Codex ring was clicked: the screen scrolls to the Codex section once, then clears it.
    var focusCodex = false
    /// How many days every number of the screen covers (per project).
    private(set) var range = StatsRange.twoWeeks
    /// Where the plan usage comes from; tests replace it.
    @ObservationIgnored var usageSource: @Sendable () -> PlanUsage? = { UsageReader.read() }
    @ObservationIgnored private let model: PanelModel
    /// What the session files cost as last read: the screen draws with it while a new read runs off the main thread.
    @ObservationIgnored private var knownCosts: [String: CardCost] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var computing: Task<Void, Never>?

    init(model: PanelModel) { self.model = model; usageSource = model.usageSource; refresh() }

    @ObservationIgnored private var refreshedAt = Date.distantPast

    /// The screen appeared: reads again unless the model was just made or refreshed (opening the screen refreshed it a moment ago).
    func refreshOnAppear() { if Date().timeIntervalSince(refreshedAt) > 1 { refresh() } }

    /// Shows what is known at once, then reads the session files and the usage off the main thread and shows the result.
    func refresh() {
        refreshedAt = Date()
        range = StatsRange.load(model.defaults, project: model.selectedProjectID ?? "")
        loading?.cancel()
        loading = Task { await reload() }
        // The rounds are built off the main thread by `reload` (each one walks the whole log); until then the last ones stay.
        let rounds = stats.rounds
        stats = Stats.compute(cards: taskCards(), events: model.actionLogEvents(), costs: knownCosts, roles: roles(), days: range.rawValue)
        stats.rounds = rounds
    }

    /// What the Rounds table needs besides the cards and the log: where plan.json is, the project and the decision log.
    struct RoundInputs: Sendable { var dataDir: URL?; var project: String; var decisions: [DecisionRecord] }

    private func roundInputs(decisions: [DecisionRecord]? = nil) -> RoundInputs {
        RoundInputs(dataDir: model.selectedProject?.dataURL, project: model.selectedProjectID ?? "", decisions: decisions ?? model.autopilot.allDecisions())
    }

    /// Reads plan.json and builds its rounds; run off the main thread.
    nonisolated static func rounds(_ inputs: RoundInputs, cards: [TaskCard], events: [ActionLogEvent], costs: [String: CardCost], days: Int) -> [StatsRoundRow] {
        guard let dir = inputs.dataDir, case .plan(let file) = PlanReader.load(dataDir: dir) else { return [] }
        return Stats.rounds(file.rounds, project: inputs.project, cards: cards, events: events, decisions: inputs.decisions,
                            agentCosts: costs.compactMapValues(\.agent), days: days)
    }

    /// Another range: remembered for the project, and the numbers computed again off the main thread from what is known.
    func setRange(_ new: StatsRange) {
        guard new != range else { return }
        range = new
        new.save(model.defaults, project: model.selectedProjectID ?? "")
        let cards = taskCards(), events = model.actionLogEvents(), costs = knownCosts, roles = roles(), days = new.rawValue, inputs = roundInputs()
        computing?.cancel()
        computing = Task {
            let result = await Task.detached(priority: .userInitiated) {
                var s = Stats.compute(cards: cards, events: events, costs: costs, roles: roles, days: days)
                s.rounds = Self.rounds(inputs, cards: cards, events: events, costs: costs, days: days)
                return s
            }.value
            guard !Task.isCancelled else { return }
            stats = result
        }
    }

    /// Today's cost at once, for the autopilot's daily limit (checked at most once a minute, only when a limit is set). Of the open project
    /// unless `id` names another one, whose cards and decisions come from its own watch.
    static func todayCost(of model: PanelModel, project id: String? = nil) -> Double {
        let cards = model.taskCards(of: id ?? model.selectedProjectID ?? "")
        let watch = id.flatMap { model.watches[$0] } ?? model.selectedWatch
        let events = model.actionLogEvents(), decisions = watch.autopilot.allDecisions()
        let costs = costs(cards: cards, events: events, decisions: decisions, project: model.config(of: id).map { (id: $0.id, worktrees: $0.worktreesURL) }, root: model.claudeProjectsRoot, codexRoot: model.codexSessionsRoot)
        return Stats.todayCost(cards: cards, events: events, costs: costs, decisions: decisions)
    }

    /// The open project's cost per day of the last `days` days, as the Stats screen counts it, and its today cost (`Stats.todayCost`, the
    /// same number the autopilot's daily limit reads) from the same read; the session files are read off the main thread.
    static func recentCost(of model: PanelModel, days: Int = 7) async -> (days: [DayCost], today: Double) {
        let cards = model.taskCards(of: model.selectedProjectID ?? "")
        let events = model.actionLogEvents(), decisions = model.selectedWatch.autopilot.allDecisions()
        let project = model.selectedProject.map { (id: $0.id, worktrees: $0.worktreesURL) }
        let root = model.claudeProjectsRoot, codexRoot = model.codexSessionsRoot
        return await Task.detached(priority: .utility) {
            let costs = Self.costs(cards: cards, events: events, decisions: decisions, project: project, root: root, codexRoot: codexRoot)
            return (Stats.compute(cards: cards, events: events, costs: costs, days: days).costPerDay,
                    Stats.todayCost(cards: cards, events: events, costs: costs, decisions: decisions))
        }.value
    }

    private func taskCards() -> [TaskCard] {
        model.cards.compactMap { result -> TaskCard? in if case .card(let c) = result { return c } else { return nil } }
    }

    /// The roles the cards ask for, as the Team screen has them (for the table's effort).
    private func roles() -> [String: RoleConfig] {
        var result: [String: RoleConfig] = [:]
        for case .card(let c) in model.cards {
            let name = c.roles.first ?? "dev"
            if result[name] == nil, let role = model.roleConfig(named: name) { result[name] = role }
        }
        return result
    }

    /// Reads the usage and the session files (off the main thread) and computes the statistics.
    func reload() async {
        let cards = taskCards()
        let events = model.actionLogEvents()
        let decisions = model.autopilot.allDecisions()
        let roles = roles()
        let days = range.rawValue
        let source = usageSource
        let project = model.selectedProject.map { (id: $0.id, worktrees: $0.worktreesURL) }
        let root = model.claudeProjectsRoot, codexRoot = model.codexSessionsRoot
        let inputs = roundInputs(decisions: decisions)
        let (usage, costs, stats, today) = await Task.detached(priority: .userInitiated) {
            let costs = Self.costs(cards: cards, events: events, decisions: decisions, project: project, root: root, codexRoot: codexRoot)
            var stats = Stats.compute(cards: cards, events: events, costs: costs, roles: roles, days: days)
            stats.rounds = Self.rounds(inputs, cards: cards, events: events, costs: costs, days: days)
            return (source(), costs, stats,
                    Stats.todayCost(cards: cards, events: events, costs: costs, decisions: decisions))
        }.value
        guard !Task.isCancelled else { return }
        self.usage = usage
        knownCosts = costs
        if days == range.rawValue { self.stats = stats }
        todayCost = today
    }

    /// Reads the session files of the finished cards and adds the PM's recorded decisions for each.
    nonisolated private static func costs(cards: [TaskCard], events: [ActionLogEvent], decisions: [DecisionRecord], project: (id: String, worktrees: URL)?, root: URL, codexRoot: URL? = nil) -> [String: CardCost] {
        guard let project else { return [:] }
        var pm: [String: Double] = [:]
        for r in decisions { pm[r.cardID, default: 0] += r.costUSD ?? 0 }
        var result: [String: CardCost] = [:]
        for c in cards where c.status == .done {
            let start = events.filter { $0.concerns(project: project.id) && $0.text.hasPrefix("start \(c.id) agent=") }.map(\.time).min()
            let session = c.branch.flatMap { branch in
                CostReader.taskCost(projectsRoot: root, codexRoot: codexRoot, worktree: project.worktrees.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).path, since: start)
            }
            result[c.id] = CardCost(agent: session?.dollars, pm: pm[c.id] ?? 0, session: session)
        }
        return result
    }
}
