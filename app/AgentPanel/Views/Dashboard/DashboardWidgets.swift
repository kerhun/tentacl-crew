import SwiftUI
import AppKit

// The Dashboard's tiles (N342). Each reuses the data and actions the old Dashboard had; only the look is new.

/// What a Waiting for you row says: the kind ("Question"), what it is about ("N339") and a one-line title.
struct WaitingRowText: Equatable {
    let kind: String
    let ref: String?
    let title: String

    /// "Question · N339"
    var heading: String { [kind, ref].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

extension PanelModel {
    func waitingRowText(_ item: DashboardWaitingItem) -> WaitingRowText {
        let title = { (id: String) in self.card(id: id).map { AgentSummary.plainTitle($0.title, id: id) } ?? id }
        switch item.kind {
        case .question(let id):
            guard let q = questionsForYou.first(where: { $0.id == id }) else { return WaitingRowText(kind: "Question", ref: nil, title: "") }
            return WaitingRowText(kind: QuestionFocusContent(q).kindLabel, ref: q.isPM ? "PM" : q.cardID, title: QuestionFocusContent.firstLine(ReadableQuestion(q).title))
        case .fix(let id):
            let fix = autopilot.fixesForYou.first { $0.id == id }
            return WaitingRowText(kind: fix?.headline ?? "Fix", ref: id, title: title(id))
        case .review(let id): return WaitingRowText(kind: "Review", ref: id, title: title(id))
        case .startApproval(let id): return WaitingRowText(kind: "Start", ref: id, title: title(id))
        case .approveRound(let n): return WaitingRowText(kind: "Approve round", ref: nil, title: "\(n) tasks passed review")
        case .round(let ids): return WaitingRowText(kind: "Round", ref: nil, title: "The PM proposed " + ids.joined(separator: ", "))
        case .planRound(let name): return WaitingRowText(kind: "Plan", ref: nil, title: "Round \(name) waits for your approval")
        case .git(let s): return WaitingRowText(kind: "Git", ref: nil, title: s.title)
        case .undelivered(let id):
            let entry = undeliveredMessages.first { $0.id == id }
            return WaitingRowText(kind: "Not delivered", ref: nil, title: entry.map { String($0.item.text.prefix(120)) } ?? "")
        }
    }
}

/// An agent's question in Waiting for you (N370): "Question · ui_dev · N370 · 4 min" over the question's first line, "Answer ↗" on the right.
struct WaitingQuestionRowText: Equatable {
    let kind: String
    let role: String
    let card: String?
    let waited: String?
    let question: String

    var heading: String { [kind, role, card, waited].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }

    static func make(_ q: PendingQuestion, role: String?, askedAt: Date?, now: Date) -> WaitingQuestionRowText {
        WaitingQuestionRowText(kind: QuestionFocusContent(q).kindLabel, role: q.isPM ? "PM" : role ?? "", card: q.isPM ? nil : q.cardID,
                               waited: askedAt.map { Stats.durationText(max(now.timeIntervalSince($0), 0)) },
                               question: QuestionFocusContent.firstLine(ReadableQuestion(q).title))
    }
}

/// How a question row is lit (design B, N370): a slowly pulsing Tok.ask frame with a glow ring, or with Reduce Motion the same frame held still.
enum QuestionHighlight: Equatable {
    case pulsing, still

    static func style(reduceMotion: Bool) -> QuestionHighlight { reduceMotion ? .still : .pulsing }
    /// One breath of the pulse (ease-in-out, there and back).
    static let period: Double = 1.8
}

extension PanelModel {
    /// The role of the agent asking `q`: the card's (else the pane's) agent name before its first dash ("ui_dev-n370-…" → "ui_dev").
    func questionRole(_ q: PendingQuestion) -> String? {
        if q.isPM { return "PM" }
        if let role = card(id: q.cardID)?.agent.flatMap({ AgentRowName.role(ofAgent: $0) }) { return role }
        guard case .available(let list) = agents, let agent = list.first(where: { $0.paneID == q.paneID }) else { return nil }
        return AgentRowName.role(ofAgent: agent.name ?? agent.title)
    }

    /// The agents with an open question for the user (their panes): their row says "asking you".
    var askingPanes: Set<String> { Set(questionsForYou.map(\.paneID)) }
}

// MARK: Waiting for you

/// Compact rows (kind dot, "Question · N339", one line, ↗); a click opens the focus card in front. The tile never grows.
/// Agents' questions come first (the list's order) and stand out with a glowing frame; a click opens the question window.
struct WaitingTile: View {
    @Bindable var model: PanelModel
    let onOpen: (DashboardWaitingItem) -> Void
    var focusedRow: FocusState<String?>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = model.dashboardWaiting
        let count = waitingDecisionCount(items)
        let held = model.inbox.heldRows
        let isQuestion: (DashboardWaitingItem) -> Bool = { if case .question = $0.kind { true } else { false } }
        DashboardTileShell(title: items.isEmpty ? "Waiting for you" : "Waiting for you · \(count)", titleColor: items.isEmpty ? Tok.ink3 : Tok.askText) {
            if items.isEmpty && held.isEmpty {
                HStack(spacing: 10) {
                    Circle().fill(Tok.go).frame(width: 8, height: 8)
                    Text("Nothing needs you. The PM has it.").font(.system(size: 13)).foregroundStyle(Tok.ink3)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if let error = model.inbox.error {
                Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).lineLimit(2)
            }
            Scroller {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // The user's questions, then the ones the PM is answering (N380, muted), then the rest.
                    ForEach(items.filter(isQuestion)) { item in
                        if case .question(let id) = item.kind, let q = model.questionsForYou.first(where: { $0.id == id }) {
                            questionRow(item, q, items: items)
                        }
                    }
                    ForEach(held) { h in
                        HeldQuestionRow(held: h, role: model.questionRole(h.question)) { model.inbox.answerMyself(h.id) }
                            .transition(.opacity)
                    }
                    ForEach(items.filter { !isQuestion($0) }) { row($0) }
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: held.map(\.id))
                .padding(QuestionGlow.reach)
            }
            // N375: the scroll view clips; widen it by the glow's reach into the tile's padding (content inset back), so a
            // question row's glow is never cut at the top, bottom or sides while rows stay where they were.
            .padding(-QuestionGlow.reach)
        }
    }

    private func questionRow(_ item: DashboardWaitingItem, _ q: PendingQuestion, items: [DashboardWaitingItem]) -> some View {
        let role = model.questionRole(q)
        let asked = model.inbox.askedAt[q.id]
        return Button { openQuestion(q, items: items) } label: {
            SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { context in
                let text = WaitingQuestionRowText.make(q, role: role, askedAt: asked, now: context.date)
                HStack(spacing: 10) {
                    Circle().fill(Tok.ask).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(text.heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.askText).lineLimit(1)
                        Text(text.question).font(.system(size: 13.5)).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Text("Answer ↗").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.askText).fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(text.heading): \(text.question). Answer")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .modifier(QuestionGlow(style: .style(reduceMotion: reduceMotion)))
        }
        .buttonStyle(WaitingRowStyle())
        .focused(focusedRow, equals: item.id)
        .help("Open the question window")
    }

    /// The question window on this question, with ‹ › through the others in the list's order.
    private func openQuestion(_ q: PendingQuestion, items: [DashboardWaitingItem]) {
        let byID = Dictionary(model.questionsForYou.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let open = items.compactMap { if case .question(let id) = $0.kind { byID[id] } else { nil } }
        model.inbox.openFocus(q, in: open)
    }

    private func row(_ item: DashboardWaitingItem) -> some View {
        let text = model.waitingRowText(item)
        return Button { onOpen(item) } label: {
            HStack(spacing: 10) {
                Circle().fill(item.tint.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(text.heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(item.tint.color).lineLimit(1)
                    Text(text.title).font(.system(size: 13.5)).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Text("↗").font(.system(size: 12)).foregroundStyle(Tok.ink3)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(WaitingRowStyle())
        .focused(focusedRow, equals: item.id)
        .help("Open in front")
        .accessibilityLabel("\(text.heading): \(text.title)")
    }
}

private struct WaitingRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 10))
            .onHover { hovering = $0 }
    }
}

// MARK: Agents

/// One row of the Agents tile: a status dot, the role, the card and "asks · 38 min".
struct DashboardAgentRow: Equatable, Identifiable {
    let id: String
    let role: String
    let card: String?
    let state: String
    let tone: TaskPhase.Tone?
    let agentState: AgentState
    /// An open question for the user (N370): the state reads "asking you" in Tok.ask.
    var asking = false

    static let askingWord = "asking you"
    /// N380: its question waits on the PM's answer.
    static let withPMWord = "question with PM"

    /// "asks", "working", "in review"…: the phase in a word or two.
    static func stateWord(_ phase: TaskPhase?, agent: AgentState) -> String {
        switch phase {
        case .waitingForYou?: "asks"
        case .pmHandling?: "PM deciding"
        case .working?: "working"
        case .starting?: "starting"
        case .finished?: "finished"
        case .idle?: "idle"
        case .blocked?: "blocked"
        case .inReview?: "in review"
        case .needsFix?: "fixing"
        case nil:
            switch agent {
            case .working: "working"
            case .blocked: "asks"
            case .idle, .done: "idle"
            case .unknown: "unknown"
            }
        }
    }

    @MainActor static func make(_ model: PanelModel) -> [DashboardAgentRow] {
        guard case .available(let list) = model.visibleAgents else { return [] }
        let pm = model.selectedProjectID.flatMap { model.pmPane(forProject: $0) }
        let asking = model.askingPanes
        let withPM = model.inbox.panesWithPM
        return list.filter { !TerminalShells.isUserShell($0.paneID) }.map { agent in
            let summary = model.agentSummary(agent)
            let phase = model.phase(ofAgent: agent)
            var state = stateWord(phase, agent: agent.state)
            if let elapsed = summary?.elapsed, phase != .inReview { state += " · " + Stats.durationText(elapsed) }
            let isAsking = asking.contains(agent.paneID)
            if isAsking { state = askingWord } else if withPM.contains(agent.paneID) { state = withPMWord }
            let role = agent.paneID == pm ? "PM" : summary?.role ?? model.agentLabel(agent)
            return DashboardAgentRow(id: agent.paneID, role: role, card: summary?.cardID, state: state, tone: phase?.tone, agentState: agent.state, asking: isAsking)
        }
    }
}

struct AgentsTile: View {
    @Bindable var model: PanelModel
    let onOpen: (String) -> Void
    let onOpenTerminals: () -> Void

    var body: some View {
        let rows = DashboardAgentRow.make(model)
        DashboardTileShell(title: "Agents", link: "Terminals", linkHelp: "Open the Terminals screen", onLink: onOpenTerminals) {
            if rows.isEmpty {
                Text("No agent is running.").font(.system(size: 13)).foregroundStyle(Tok.ink3)
            }
            Scroller {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        Button { if let card = row.card { onOpen(card) } } label: {
                            HStack(spacing: 10) {
                                Circle().fill(dot(row)).frame(width: 8, height: 8)
                                HStack(spacing: 6) {
                                    Text(row.role).font(.system(size: 13.5)).foregroundStyle(Tok.ink).lineLimit(1)
                                    if let card = row.card { Text(card).font(.system(size: 12)).foregroundStyle(Tok.ink3) }
                                }
                                Spacer(minLength: 6)
                                Text(row.state).font(.system(size: 12, weight: row.asking ? .semibold : .regular)).foregroundStyle(row.asking ? Tok.ask : Tok.ink3).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(row.card == nil)
                        .help(row.card.map { "Open \($0) on the Tasks screen" } ?? "")
                        .accessibilityLabel("\(row.role)\(row.card.map { " on \($0)" } ?? ""), \(row.state)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func dot(_ row: DashboardAgentRow) -> Color {
        if row.asking { return Tok.ask }
        if let tone = row.tone { return tone == .orange ? Tok.ask : tone.color }
        switch row.agentState {
        case .working: return Tok.work
        case .blocked: return Tok.ask
        default: return Tok.ink3
        }
    }
}

// MARK: Round

/// Today's Goal card content: the goal, the picked round, its progress in segments and the Plan link.
struct RoundTile: View {
    let goal: String
    let plan: PlanLoad
    let cards: [TaskCard]
    var pick: GoalPick?
    var onPick: (String?) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    var onOpenPlan: () -> Void = {}

    var body: some View {
        DashboardTileShell(title: "Round", link: "Plan", linkHelp: "Open the Plan screen to edit the goal and see every round", onLink: onOpenPlan) {
            Text(goal.isEmpty ? "No goal yet. Write it on the Plan screen; the PM plans against it." : goal)
                .font(.system(size: 14, weight: goal.isEmpty ? .regular : .semibold)).foregroundStyle(goal.isEmpty ? Tok.ink3 : Tok.ink).lineLimit(2)
            roundPart
        }
    }

    static func segmentColor(_ status: TaskStatus?) -> Color {
        switch status {
        case .done?: Tok.go
        case .review?: Tok.waitReview
        case .needsFix?: Tok.waitFix
        case .doing?: Tok.work
        default: Tok.raise
        }
    }

    @ViewBuilder private var roundPart: some View {
        if case .plan(let file) = plan, let round = GoalCard.shownRound(in: file, cards: cards, pick: pick) {
            let p = PlanReader.progress(of: round, cards: cards)
            let status = Dictionary(cards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            let working = round.cards.filter { status[$0] == .doing || status[$0] == .needsFix }.count
            HStack(spacing: 4) {
                ForEach(round.cards, id: \.self) { id in
                    Button { onOpen(id) } label: { RoundedRectangle(cornerRadius: 3).fill(Self.segmentColor(status[id])).frame(height: 6) }
                        .buttonStyle(.plain).help("\(id): open on the Tasks screen")
                }
            }
            HStack(spacing: 4) {
                Text("\(p.done) of \(p.total)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Tok.ink)
                Text("merged" + (working > 0 ? " · \(working) working" : "") + " · \(round.name)").font(.system(size: 12.5)).foregroundStyle(Tok.ink3).lineLimit(1)
                Spacer(minLength: 0)
                picker(file)
            }
        } else if case .broken = plan {
            Text("plan.json could not be read; the Plan screen says why.").font(Tok.Font.small).foregroundStyle(Tok.wait)
        } else {
            Text("No round planned yet.").font(.system(size: 12.5)).foregroundStyle(Tok.ink3)
        }
    }

    private func picker(_ file: PlanFile) -> some View {
        Menu {
            Button("Current") { onPick(nil) }
            ForEach(goalRoundGroups(in: file, cards: cards), id: \.title) { g in
                Section(g.title) { ForEach(g.rounds) { r in Button(r.name) { onPick(r.name) } } }
            }
        } label: { Image(systemName: "chevron.up.chevron.down").font(Tok.Font.small) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Show another round")
    }
}

// MARK: Cost

struct CostTile: View {
    /// This project's today cost (the line's last point); nil when not read yet.
    let today: Double?
    let limit: Double?
    let limitReached: Bool
    var onOpenStats: () -> Void = {}
    /// The last 7 days' cost, oldest first, today last (see `week`); nil or all zero hides the line.
    var week: [Double]? = nil
    /// The plan-wide status-line total (every project); shown only as a labelled second line, see `allProjectsText`.
    var allProjects: Double? = nil

    private var line: [Double]? { week.flatMap { $0.contains { $0 > 0 } ? $0 : nil } }

    var body: some View {
        DashboardTileShell(title: "Cost", link: "Stats", linkHelp: "Open the Stats screen", onLink: onOpenStats) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) { amount; if let line { spark(line).frame(minWidth: 120, maxWidth: 220) } }
                VStack(alignment: .leading, spacing: 8) { amount; if let line { spark(line) } }
            }
        }
    }

    private var amount: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(today.map { String(format: "≈ $%.2f", $0) } ?? "–")
                .font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundStyle(limitReached ? Tok.stop : Tok.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.subtitle(today: today, limit: limit, reached: limitReached)).font(.system(size: 12.5)).foregroundStyle(limitReached ? Tok.stop : Tok.ink3).lineLimit(2)
                if let all = Self.allProjectsText(today: today, allProjects: allProjects) {
                    Text(all).font(.system(size: 11.5)).foregroundStyle(Tok.ink3).lineLimit(1)
                        .help("The status line's total for today covers every project; the amount above is this project only")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func spark(_ values: [Double]) -> some View {
        let text = Self.weekText(values)
        return CostSparkline(values: values, color: limitReached ? Tok.stop : Tok.ink3)
            .frame(height: 28).frame(maxWidth: .infinity)
            .help(text).accessibilityElement().accessibilityLabel(text)
    }

    /// The last `count` days' cost from per-day totals, oldest first and today last; a day without data is 0. `today`, when known, is
    /// today's point: the project's own today cost (`StatsModel.todayCost`, which also counts the PM's decisions), never the plan-wide
    /// status-line total, which covers every project and would dwarf the other days.
    static func week(_ days: [DayCost], today: Double? = nil, count: Int = 7, calendar: Calendar = .current, now: Date = Date()) -> [Double] {
        let start = calendar.startOfDay(for: now)
        var byDay: [Date: Double] = [:]
        for d in days { byDay[calendar.startOfDay(for: d.day), default: 0] += d.dollars }
        var result = (0..<count).reversed().map { back -> Double in
            guard let day = calendar.date(byAdding: .day, value: -back, to: start) else { return 0 }
            return byDay[day] ?? 0
        }
        if let today, !result.isEmpty { result[result.count - 1] = today }
        return result
    }

    static func weekText(_ values: [Double]) -> String {
        String(format: "Last %d days: $%.2f total", values.count, values.reduce(0, +))
    }
}

/// A small line of daily costs with no axes; the last point (today) is drawn as a dot.
struct CostSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let pts = Self.points(values, in: geo.size, inset: 3)
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first); pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(color).frame(width: 6, height: 6).position(last)
                }
            }
        }
    }

    static func points(_ values: [Double], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard values.count > 1 else { return values.map { _ in CGPoint(x: size.width / 2, y: size.height / 2) } }
        let top = values.max() ?? 0
        let w = max(size.width - inset * 2, 1), h = max(size.height - inset * 2, 1)
        return values.enumerated().map { i, v in
            CGPoint(x: inset + w * CGFloat(i) / CGFloat(values.count - 1), y: inset + h * (1 - CGFloat(top > 0 ? v / top : 0)))
        }
    }
}

extension CostTile {

    static func subtitle(today: Double?, limit: Double?, reached: Bool) -> String {
        guard today != nil else { return "Not read yet today" }
        if reached { return "Daily limit reached: questions come to you" }
        return limit.map { String(format: "today · limit $%.2f", $0) } ?? "today"
    }

    /// The tile's big amount: this project's today cost from the week's read (`StatsModel.recentCost`), or the autopilot's last read of the
    /// same number while that read is pending. Never the plan-wide total.
    static func projectToday(read: Double?, autopilot: Double?) -> Double? { read ?? autopilot }

    /// One `StatsModel.recentCost` read, tagged with the project it was read for.
    struct Read: Equatable {
        let project: String
        let days: [DayCost]
        let today: Double

        /// `read` only when it belongs to `project`; after a project switch the old read is dropped until the new one lands.
        static func of(_ read: Read?, project: String) -> Read? { read?.project == project ? read : nil }
    }

    /// How often the open Dashboard re-reads the project's cost while nothing else changes.
    static let refreshSeconds: Double = 60

    /// The read's trigger: project, card count, the autopilot's read (only moves with a daily limit) and the plan-wide total (moves with
    /// the status line, with or without a limit). The plan-wide total is a trigger only, never shown as the big amount.
    static func refreshKey(project: String, cards: Int, autopilot: Double?, allProjects: Double?) -> String {
        "\(project)|\(cards)|\(autopilot ?? -1)|\(allProjects ?? -1)"
    }

    /// "all projects ≈ $X today" when the plan-wide total is known and differs from this project's amount by at least a cent.
    static func allProjectsText(today: Double?, allProjects: Double?) -> String? {
        guard let all = allProjects, all > 0, abs(all - (today ?? 0)) >= 0.01 else { return nil }
        return String(format: "all projects ≈ $%.2f today", all)
    }
}

// MARK: Highlights

struct HighlightsTile: View {
    let highlights: [DashboardHighlight]
    let onOpen: (String) -> Void
    let onOpenTimeline: () -> Void
    var timelineEnabled = true

    var body: some View {
        DashboardTileShell(title: "Highlights", link: "Timeline", linkHelp: timelineEnabled ? "See how each round ran" : "No rounds in plan.json yet",
                           onLink: onOpenTimeline, linkDisabled: !timelineEnabled) {
            if highlights.isEmpty { Text("Nothing has happened yet today.").font(.system(size: 13)).foregroundStyle(Tok.ink3) }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(highlights) { h in
                    Button { onOpen(h.card) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.clock(h.time)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tok.ink3).frame(width: 40, alignment: .leading)
                            (Text(h.card).foregroundStyle(Tok.ink).fontWeight(.medium) + Text(" " + h.text).foregroundStyle(Tok.ink2))
                                .font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Open \(h.card) on the Tasks screen")
                }
            }
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: Plan usage

struct UsageTile: View {
    let usage: PlanUsage?
    let gate: UsageGate

    struct Bar: Equatable { let name: String; let percent: Int; let limit: Int?; let reset: String }

    static func bars(_ usage: PlanUsage?, gate: UsageGate, now: Date = Date()) -> [Bar] {
        guard let usage else { return [] }
        return [("5 hours", usage.fiveHour, gate.fiveHour), ("Week", usage.week, gate.week)].compactMap { name, w, limit in
            w.map { Bar(name: name, percent: Int($0.percent.rounded()), limit: limit, reset: PlanUsage.resetText($0.resetsAt, now: now)) }
        }
    }

    var body: some View {
        DashboardTileShell(title: "Plan usage") {
            let bars = Self.bars(usage, gate: gate)
            if bars.isEmpty { Text("Plan usage is not known yet.").font(.system(size: 13)).foregroundStyle(Tok.ink3) }
            ForEach(bars, id: \.name) { b in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(b.name).font(.system(size: 13)).foregroundStyle(Tok.ink)
                        Spacer()
                        Text("\(b.percent)%\(b.limit.map { " / \($0)%" } ?? "") · \(b.reset)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Tok.ink3).lineLimit(1)
                    }
                    meter(b)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(b.name) \(b.percent) percent\(b.limit.map { ", limit \($0) percent" } ?? "")")
            }
        }
    }

    private func meter(_ b: Bar) -> some View {
        let fill = b.limit.map { b.percent >= $0 } == true ? Tok.stop : b.percent >= 70 ? Tok.wait : Tok.go
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Tok.raise).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: g.size.width * min(Double(b.percent) / 100, 1), height: 6)
                if let limit = b.limit {
                    RoundedRectangle(cornerRadius: 1).fill(Tok.ink2).frame(width: 2, height: 12).offset(x: g.size.width * Double(limit) / 100 - 1)
                        .help("Usage gate: no new agent starts above \(limit)%")
                }
            }
            .frame(height: 12)
        }
        .frame(height: 12)
    }
}

// MARK: Git

struct GitTile: View {
    @Bindable var model: PanelModel

    /// "3 commits not on GitHub", "No GitHub remote yet", "Not a git repository", "Up to date with GitHub".
    static func status(_ state: GitState?) -> String {
        guard let state else { return "Not checked yet" }
        guard state.isGitRepo else { return "Not a git repository" }
        guard state.remote != nil else { return "No GitHub remote yet" }
        guard let n = state.unpushed else { return "No upstream branch" }
        return n == 0 ? "Up to date with GitHub" : n == 1 ? "1 commit not on GitHub" : "\(n) commits not on GitHub"
    }

    var body: some View {
        let project = model.selectedProject
        let state = project.flatMap { model.gitSetup.states[$0.id] }
        DashboardTileShell(title: "Git") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(project?.baseBranch ?? "").font(.system(size: 15, weight: .medium)).foregroundStyle(Tok.ink)
                Text("· " + Self.status(state)).font(.system(size: 12.5)).foregroundStyle(Tok.ink3).lineLimit(1)
            }
            if let project {
                if state?.isGitRepo == false {
                    Button("Initialize git…") { Task { await model.gitSetup.openInitGit(project) } }.buttonStyle(PanelButtonStyle())
                        .help("Choose the files for the first commit; nothing is committed until you confirm")
                } else if state?.remote == nil || (state?.unpushed ?? 0) > 0 {
                    Button("Push to GitHub…") { Task { await model.gitSetup.openPush(project) } }.buttonStyle(PanelButtonStyle())
                        .help("Nothing is pushed from here; the sheet says what happens").disabled(state == nil)
                }
            }
        }
        .task(id: project?.id) { await model.refreshGitState() }
    }
}
