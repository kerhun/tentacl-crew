import AppKit

private func isDone(_ r: PlanRound, _ cards: [TaskCard]) -> Bool {
    let p = PlanReader.progress(of: r, cards: cards)
    return r.status.lowercased() == "done" || (p.total > 0 && p.done == p.total)
}
private func isLater(_ r: PlanRound) -> Bool { ["later", "archived", "dropped"].contains(r.status.lowercased()) }

/// The round the Dashboard follows: the first running one, else the first open one that is not "later", else the last done one.
func currentRound(in plan: PlanFile, cards: [TaskCard]) -> PlanRound? {
    plan.rounds.first { $0.status.lowercased() == "running" && !isDone($0, cards) }
        ?? plan.rounds.first { !isLater($0) && !isDone($0, cards) }
        ?? plan.rounds.last { !isLater($0) } ?? plan.rounds.last
}

/// The user's pick on the Goal card, and whether that round was still open when picked.
struct GoalPick: Equatable { let name: String; let wasOpen: Bool }

/// The round the Goal card shows: the pick while its round exists, except that a round picked while open falls back to the default once done.
func goalRound(in plan: PlanFile, cards: [TaskCard], pick: GoalPick?) -> PlanRound? {
    if let pick, let r = plan.rounds.first(where: { $0.name == pick.name }), !(pick.wasOpen && isDone(r, cards)) { return r }
    return currentRound(in: plan, cards: cards)
}

/// The Goal card's round picker: open rounds, then "Later", then the last 10 done ones (latest first).
func goalRoundGroups(in plan: PlanFile, cards: [TaskCard]) -> [(title: String, rounds: [PlanRound])] {
    let open = plan.rounds.filter { !isDone($0, cards) && !isLater($0) }
    let later = plan.rounds.filter { !isDone($0, cards) && isLater($0) }
    let done = Array(plan.rounds.filter { isDone($0, cards) }.reversed().prefix(10))
    return [("", open), ("Later", later), ("Done", done)].filter { !$0.1.isEmpty }.map { (title: $0.0, rounds: $0.1) }
}

extension PanelModel {
    /// The round the user picked on the Goal card (per project); nil follows the default.
    func goalRoundPick(_ project: String) -> GoalPick? {
        defaults.string(forKey: "goalRound.\(project)").map { GoalPick(name: $0, wasOpen: defaults.bool(forKey: "goalRoundOpen.\(project)")) }
    }
    func setGoalRoundPick(_ name: String?, project: String, cards: [TaskCard], plan: PlanLoad) {
        defaults.set(name, forKey: "goalRound.\(project)")
        guard let name, case .plan(let file) = plan, let r = file.rounds.first(where: { $0.name == name }) else { return }
        defaults.set(!isDone(r, cards), forKey: "goalRoundOpen.\(project)")
    }

    /// What the Dashboard's "Waiting for you" lists for the selected project.
    var dashboardWaiting: [DashboardWaitingItem] {
        dashboardWaitingItems(questions: questionsForYou.map(\.id), fixes: autopilot.fixesForYou.map(\.id),
                              cards: cards.compactMap { if case .card(let c) = $0 { c } else { nil } },
                              roundWaiting: round.waitingIDs, approveRound: approveRoundCards.count,
                              git: selectedProjectID.map { gitSetup.suggestions(for: $0, cards: selectedTaskCards) } ?? [],
                              planRound: round.waitingForYouPlanRound?.name, questionAsked: inbox.askedAt,
                              undelivered: undeliveredMessages.map(\.id))
    }

    /// The selected project's panel messages that were dropped undelivered (N211).
    var undeliveredMessages: [PanelOutbox.Undelivered] {
        outbox.undelivered.filter { $0.item.project == selectedProjectID }
    }

    /// Retry: the message goes back in the outbox and is sent now if its agent can take it.
    func retryUndelivered(_ id: String) async {
        guard let item = outbox.retry(id) else { return }
        if let project = item.project { chats.session(project: project, pane: item.pane).chat.addPending(item.text, kind: .panel, id: item.id) }
        actionLog.append("panel message to \(item.pane) retried: \(String(item.text.prefix(80)))", project: item.project)
        await deliverOutbox()
    }

    func dismissUndelivered(_ id: String) {
        guard let entry = outbox.undelivered.first(where: { $0.id == id }) else { return }
        outbox.dismiss(id)
        actionLog.append("panel message to \(entry.item.pane) dismissed undelivered: \(String(entry.item.text.prefix(80)))", project: entry.item.project)
    }

    /// Why "Approve plan & start round" is disabled for `planRound`: no agent can start (git, scripts…), a Round sheet is open, or Setup found a tool missing.
    func approvePlanBlocker(_ planRound: PlanRound) -> String? {
        if isBusy { return "Busy: wait for the current action to finish." }
        if round.isOpen { return "The Round sheet is open; finish or close it first." }
        return RoundModel.approveBlocker(planRound, cards: selectedTaskCards, startReason: canStart ? nil : (startDisabledReason ?? "Agents cannot start now."),
                                         setup: setup.items, toolOf: { [weak self] in self?.tool(ofRole: $0) ?? .claude })
    }

    func approvePlan(_ planRound: PlanRound) async {
        guard approvePlanBlocker(planRound) == nil else { return }
        _ = await round.approvePlan(planRound)
    }

    /// "Edit": a request to the PM in the conversation's message box (never sent); without a PM, plan.json opens in its editor.
    func editPlan(_ planRound: PlanRound) {
        if fillPMDraft("Change round \(planRound.name) of plan.json before I start it: ") { return }
        if let url = selectedProject?.dataURL.appendingPathComponent(PlanReader.fileName) { NSWorkspace.shared.open(url) }
    }

    /// Probes the selected project's git state again (at most once a minute unless forced), for the git suggestions.
    func refreshGitState(force: Bool = false) async {
        guard let project = selectedProject else { return }
        await gitSetup.refresh(project, force: force)
    }

    /// The live git suggestions: the probe (not under XCTest), the scripts, and a card reload after git init or a push.
    func makeGitSetup() -> GitSuggestionModel {
        let inspector = RepoInspector(runner: ProcessRunner(timeout: 30))
        let m = GitSuggestionModel(defaults: defaults, probe: Self.runsUnderXCTest ? nil : { await inspector.probe($0) },
                                   scripts: { [weak self] in self.flatMap { $0.settings.scriptsDir == nil ? nil : $0.makeScripts($0.settings) } })
        if !Self.runsUnderXCTest { m.publisher = { GitPublisher(runner: ProcessToolRunner(), gh: SetupCheck.findTool("gh")) } }
        m.onChanged = { [weak self] id in if self?.selectedProjectID == id { await self?.reloadCards() } }
        return m
    }

    /// What waits for you: the Dashboard's list header (see `waitingDecisionCount`).
    var waitingForYouCount: Int { waitingDecisionCount(dashboardWaiting) }

    /// The small count next to the project name in the top bar: what waits in the projects that are not open.
    var waitingInOtherProjects: Int {
        projects.filter { $0.id != selectedProjectID }.reduce(0) { $0 + waitingCount(forProject: $1.id) }
    }

    /// "PM authority · 2 of 6 today" (the count is read from the decision log only while the authority is on).
    var dashboardAuthority: String {
        let policy = autopilot.policy
        return dashboardAuthorityText(enabled: policy.pmAuthority, startedToday: policy.pmAuthority ? autopilot.authorityStartsToday() : 0, perDay: policy.pmStartsPerDay)
    }

    /// The same Autopilot rules sheet the top bar's autopilot icon opens.
    func openAuthorityRules() { autopilot.rulesOpen = true }

    var planRoundState: StartButtonState {
        planRoundButtonState(autopilotAvailable: autopilot.isAvailable, mode: autopilot.policy.mode, canStart: canStart, startReason: startDisabledReason)
    }

    /// A quick prompt: replaces the draft of the conversation with the project's PM. Never sends; false when no PM runs.
    @discardableResult func fillPMDraft(_ text: String) -> Bool {
        guard let id = selectedProjectID, let pane = pmPane(forProject: id) else { return false }
        Self.fillDraft(chats.session(project: id, pane: pane), with: text)
        return true
    }

    static func fillDraft(_ session: ChatSession, with text: String) { session.text = text }
}

// MARK: Dashboard v2 (N342): the header line, highlights, agents and the focus card's place in the list

/// "Good morning" before 12, "Good afternoon" before 18, else "Good evening".
func dashboardGreeting(hour: Int) -> String {
    hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
}

/// The one line under the greeting: what needs you (in the ask colour) and the rest.
struct DashboardSummary: Equatable {
    /// "2 things need you", or nil when nothing does.
    let need: String?
    /// "3 agents working · round 1 of 4 merged", without what needs you.
    let rest: String

    init(waiting: Int, working: Int, round: (done: Int, total: Int)?) {
        need = waiting == 0 ? nil : waiting == 1 ? "1 thing needs you" : "\(waiting) things need you"
        var parts: [String] = []
        if working > 0 { parts.append(working == 1 ? "1 agent working" : "\(working) agents working") }
        if let round, round.total > 0 { parts.append("round \(round.done) of \(round.total) merged") }
        rest = parts.joined(separator: " · ")
    }

    static func == (a: Self, b: Self) -> Bool { a.need == b.need && a.rest == b.rest }

    /// The whole line as it reads: "Nothing needs you" when nothing does.
    var text: String { [need ?? "Nothing needs you", rest].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// One line of the Highlights tile: only starts, ready for review, merges, failures and questions from the action log.
struct DashboardHighlight: Equatable, Identifiable {
    enum Kind: Equatable { case started, review, merged, failed, asked }
    let time: Date
    let card: String
    let kind: Kind
    let detail: String?
    var id: String { "\(time.timeIntervalSince1970)|\(card)|\(kind)" }

    var text: String {
        switch kind {
        case .started: "started"
        case .review: "ready for review"
        case .merged: detail.map { "merged · \($0)" } ?? "merged"
        case .failed: detail ?? "review packet failed"
        case .asked: "asked you a question"
        }
    }

    /// The newest `limit` highlights of `project`, newest first.
    static func from(_ events: [ActionLogEvent], project: String, limit: Int = 6) -> [DashboardHighlight] {
        var out: [DashboardHighlight] = []
        for e in events.reversed() where e.concerns(project: project) {
            if let h = parse(e) { out.append(h); if out.count == limit { break } }
        }
        return out
    }

    static func parse(_ e: ActionLogEvent) -> DashboardHighlight? {
        let w = e.text.split(separator: " ").map(String.init)
        guard let first = w.first else { return nil }
        switch first {
        case "start" where w.count >= 3 && w[2].hasPrefix("agent="):
            return DashboardHighlight(time: e.time, card: w[1], kind: .started, detail: nil)
        case "review" where w.count >= 5 && w[1] == "packet" && w[3] == "for":
            if w[2] == "prepared" { return DashboardHighlight(time: e.time, card: w[4], kind: .review, detail: nil) }
            if w[2] == "failed" { return DashboardHighlight(time: e.time, card: w[4], kind: .failed, detail: nil) }
            return nil
        case "merged" where w.count >= 3 && w[w.count - 2] == "for":
            let tag = w.firstIndex(of: "at").flatMap { w.indices.contains($0 + 1) && w[$0 + 1].hasPrefix("stable-") ? w[$0 + 1] : nil }
            return DashboardHighlight(time: e.time, card: w[w.count - 1], kind: .merged, detail: tag)
        case "fix" where w.count >= 3 && w[1] == "request":
            return DashboardHighlight(time: e.time, card: w[w.count - 1], kind: .failed, detail: "fix requested")
        case "autopilot:" where w.count >= 5 && w[1] == "fix" && w[2] == "request" && w[3] == "for":
            return DashboardHighlight(time: e.time, card: w[4], kind: .failed, detail: "fix sent by the autopilot")
        case "asked" where w.count >= 2 && w[1] != "PM":
            return DashboardHighlight(time: e.time, card: w[1], kind: .asked, detail: nil)
        default:
            return nil
        }
    }
}

/// The short Report lines the focus card shows for a review: Result, Tests and Files (first line of each), from `### Tests` headings,
/// `**Tests**` lines or `- Tests: …` lines.
func reviewReportSummary(_ report: String) -> [(label: String, text: String)] {
    let wanted = ["Result", "Tests", "Files"]
    var found: [String: String] = [:]
    var current: String?
    for raw in report.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*-` ")).trimmingCharacters(in: .whitespaces)
        if let head = wanted.first(where: { bare == $0 || bare.hasPrefix($0 + ":") || bare.hasPrefix($0 + "**") || bare.hasPrefix($0 + "`") }) {
            current = head
            let rest = bare.dropFirst(head.count).trimmingCharacters(in: CharacterSet(charactersIn: ":*` ")).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, found[head] == nil { found[head] = rest }
            continue
        }
        if line.hasPrefix("#") { current = nil; continue }
        if let c = current, found[c] == nil, !line.isEmpty { found[c] = line.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }
    }
    return wanted.compactMap { k in found[k].map { (label: k, text: $0) } }
}

/// The last `count` lines of an agent's screen that have text, for the focus card.
func lastTerminalLines(_ screen: String, count: Int = 4) -> [String] {
    Array(screen.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\t", with: "  ") }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(count))
}

/// The focus card's place in Waiting for you (N342): the item it shows, kept by id while the list changes. When the shown item leaves
/// the list (answered), the one that takes its place shows; with none left the card says "Nothing needs you."
struct DecisionFocusState: Equatable {
    private(set) var currentID: String?
    private(set) var index: Int

    init(opening id: String, in items: [DashboardWaitingItem]) {
        index = items.firstIndex { $0.id == id } ?? 0
        currentID = items.indices.contains(index) ? items[index].id : nil
    }

    func current(in items: [DashboardWaitingItem]) -> DashboardWaitingItem? { items.first { $0.id == currentID } }

    /// "1 of 2"; nil when nothing is shown.
    func position(in items: [DashboardWaitingItem]) -> String? {
        items.firstIndex { $0.id == currentID }.map { "\($0 + 1) of \(items.count)" }
    }

    /// ‹ and ›, wrapping at both ends.
    mutating func move(by step: Int, in items: [DashboardWaitingItem]) {
        guard !items.isEmpty else { return }
        let from = items.firstIndex { $0.id == currentID } ?? index
        index = ((from + step) % items.count + items.count) % items.count
        currentID = items[index].id
    }

    /// Follows the list: the shown item if still there, else the one now at its place (the next), else none.
    mutating func sync(_ items: [DashboardWaitingItem]) {
        if let i = items.firstIndex(where: { $0.id == currentID }) { index = i; return }
        guard !items.isEmpty else { currentID = nil; return }
        index = min(index, items.count - 1)
        currentID = items[index].id
    }
}

extension PanelModel {
    /// The Dashboard's summary line for the selected project.
    func dashboardSummary(plan: PlanLoad, pick: GoalPick?) -> DashboardSummary {
        var working = 0
        if case .available(let list) = visibleAgents {
            // N343: the same agents as the Agents tile (no user shells); one without a card phase counts by its own state.
            working = list.filter { !TerminalShells.isUserShell($0.paneID) && Self.isWorking(phase: phase(ofAgent: $0), agent: $0.state) }.count
        }
        let cards = selectedTaskCards
        var round: (Int, Int)?
        if case .plan(let file) = plan, let r = GoalCard.shownRound(in: file, cards: cards, pick: pick) {
            let p = PlanReader.progress(of: r, cards: cards)
            round = (p.done, p.total)
        }
        return DashboardSummary(waiting: waitingForYouCount, working: working, round: round)
    }

    /// Working for the summary line: the card's phase when the agent is on one, else the agent's own state.
    nonisolated static func isWorking(phase: TaskPhase?, agent: AgentState) -> Bool {
        if let phase { return [.working, .starting, .pmHandling].contains(phase) }
        return agent == .working
    }

    /// The Highlights tile's lines for the selected project.
    var dashboardHighlights: [DashboardHighlight] {
        guard let id = selectedProjectID else { return [] }
        return DashboardHighlight.from(actionLogEvents(), project: id)
    }

    /// The pane of the agent a waiting item is about (for the focus card's last terminal lines); nil when no agent is involved.
    func pane(of item: DashboardWaitingItem) -> String? {
        switch item.kind {
        case .question(let id): return questionsForYou.first { $0.id == id }?.paneID
        case .fix(let id), .review(let id), .startApproval(let id): return card(id: id).flatMap { agentPane(of: $0) }
        default: return nil
        }
    }
}

extension PanelModel {
    /// The action log, parsed. Kept until the file changes (size or time), so a screen that shows it does not parse thousands of lines
    /// each time it is drawn.
    func actionLogEvents() -> [ActionLogEvent] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: actionLog.fileURL.path)
        let stamp = LogStamp(size: (attributes?[.size] as? NSNumber)?.int64Value ?? -1, modified: attributes?[.modificationDate] as? Date)
        if let cached = logEventsCache, cached.stamp == stamp { return cached.events }
        let events = ActionLogEvents.parse(actionLog.read())
        logEventsCache = (stamp, events)
        return events
    }

    struct LogStamp: Equatable { let size: Int64; let modified: Date? }
}
