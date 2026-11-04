import SwiftUI

/// The Dashboard's agents (design A, N283): one compact row per agent with its role's name, its task and its status, or a clear message
/// when the terminal cannot be reached.
struct AgentsPane: View {
    let state: AgentsState
    var label: (AgentStatus) -> String = { $0.title.isEmpty ? $0.paneID : $0.title }
    /// The status tag of the task an agent works on (nil: no tag).
    var phase: (AgentStatus) -> TaskPhase? = { _ in nil }
    /// The questions agents are asking; shown above the agent list.
    var inbox: AgentInboxModel? = nil
    /// The PM autopilot: its switch, what it is deciding and what it decided today.
    var autopilot: AutopilotModel? = nil
    /// The decisions waiting for the user live elsewhere (the Dashboard's Waiting for you): this pane then shows only the agents.
    var feedOnly = false
    /// Open terminal for an agent; nil hides the action.
    var onOpenTerminal: ((AgentStatus) -> Void)? = nil
    /// The terminal the agents run in, named in the help texts.
    var terminal = "Tentacl"
    /// Stop for an agent on no card (asks first); nil, or false from `canStop`, hides the action.
    var onStop: ((AgentStatus) -> Void)? = nil
    var canStop: (AgentStatus) -> Bool = { _ in false }
    /// The task agents' cards (summary, select, nudge); nil shows every agent as a row on no card.
    var cards: AgentCardSource? = nil
    /// Opens a card on the Tasks screen; set, a click on a task agent's row opens its card there instead of its terminal.
    var onOpenCard: ((String) -> Void)? = nil
    /// The one live line of an agent on no card (N251): the PM's row shows it as what the PM is doing.
    var statusLine: (AgentStatus) -> String = agentSummaryLine
    /// Sleep (N261): puts an idle task agent to sleep; `sleepWhy` is the reason it cannot (nil: it can). The sleeping agents are listed after the active ones with Wake.
    var onSleep: ((AgentStatus) -> Void)? = nil
    var sleepWhy: (AgentStatus) -> String? = { _ in nil }
    var sleeping: [SleepingAgent] = []
    var onWake: ((String) -> Void)? = nil
    /// Role name to display name (roles without one are left out).
    var displayNames: [String: String] = [:]
    /// A role's colour on the Team screen.
    var roleTint: (String) -> Color = { _ in Tok.ink3 }
    /// Whether an agent is the project's PM session.
    var isPM: (AgentStatus) -> Bool = { _ in false }
    /// A PM question is open: the PM's row shows a dot.
    var pmAsking = false
    /// An agent with an open question for the user (N370): its status reads "asking you" in Tok.ask.
    var askingYou: (AgentStatus) -> Bool = { _ in false }
    /// The header's Terminals link; nil hides it.
    var onOpenTerminals: (() -> Void)? = nil

    static func openHelp(cardID: String) -> String { "Open \(cardID) on Tasks" }

    /// A click on an agent's row: its card on Tasks (or its terminal on Terminals without `onOpenCard`); an agent on no card does nothing.
    func open(_ agent: AgentStatus) {
        guard let cards, let summary = cards.summary(agent) else { return }
        if let onOpenCard { onOpenCard(summary.cardID) } else { cards.select(agent) }
    }

    /// The message to show instead of the list, or nil when there are agents to list.
    static func text(for state: AgentsState, hasSleeping: Bool = false) -> String? {
        switch state {
        case .loading: return "Checking agents…"
        case .unavailable(let message): return message
        case .available(let agents): return agents.isEmpty && !hasSleeping ? "No agents are running." : nil
        }
    }

    /// The old chip right of the title (before N283): how many agents wait on someone, else where the list comes from.
    static func headerChip(waiting: Int, terminal: String = "Tentacl") -> String { waiting > 0 ? "\(waiting) waiting" : terminal }

    /// The words of the count line under the title, in order, with the phases each one counts ("waiting" counts what `agentsWaitingCount` counts).
    static let summaryParts: [(word: String, phases: Set<TaskPhase>)] = [
        ("working", [.starting, .working]),
        ("waiting", [.waitingForYou, .pmHandling, .blocked]),
        ("needs fix", [.needsFix]),
        ("in review", [.inReview]),
        ("finished", [.finished]),
        ("idle", [.idle]),
    ]

    /// The count line by phase ("4 agents · 2 working · 1 waiting · 1 idle"), parts that are zero left out; nil with no agents.
    static func summaryLine(phases: [TaskPhase?]) -> String? {
        summaryTexts(phases: phases)?.map(\.text).joined(separator: " · ")
    }

    /// The count line for a state: none while loading or when the terminal cannot be reached.
    static func summaryLine(state: AgentsState, phase: (AgentStatus) -> TaskPhase? = { _ in nil }) -> String? {
        summaryTexts(state: state, phase: phase)?.map(\.text).joined(separator: " · ")
    }

    static func summaryTexts(state: AgentsState, phase: (AgentStatus) -> TaskPhase?) -> [(text: String, waiting: Bool)]? {
        guard case .available(let agents) = state else { return nil }
        return summaryTexts(phases: agents.map(phase))
    }

    /// The parts of the count line; `waiting` marks the part shown in the ask colour.
    static func summaryTexts(phases: [TaskPhase?]) -> [(text: String, waiting: Bool)]? {
        guard !phases.isEmpty else { return nil }
        let total = (text: "\(phases.count) agent" + (phases.count == 1 ? "" : "s"), waiting: false)
        return [total] + summaryParts.compactMap { part in
            let n = phases.filter { $0.map(part.phases.contains) ?? false }.count
            return n > 0 ? ("\(n) \(part.word)", part.word == "waiting") : nil
        }
    }

    /// The line under the title (N283): the live agents, and those whose row waits for you.
    static func headerLine(running: Int, waiting: Int) -> String {
        "\(running) running" + (waiting > 0 ? " · \(waiting) waiting for you" : "")
    }

    /// The header line for a state: none while loading or when the terminal cannot be reached.
    func headerLine() -> String? {
        guard case .available(let list) = state else { return nil }
        return Self.headerLine(running: list.count, waiting: list.filter { status($0) == .waitingForYou }.count)
    }

    /// The PM's role name; its row reads the role's display name like any other.
    static let pmRole = "pm"

    /// The rows in order: the PM first, then the agents as the terminal lists them.
    var rowAgents: [AgentStatus] {
        guard case .available(let list) = state else { return [] }
        return list.filter(isPM) + list.filter { !isPM($0) }
    }

    func status(_ agent: AgentStatus) -> AgentRowStatus {
        if let summary = cards?.summary(agent) { return AgentRowStatus.of(summary) }
        return AgentRowStatus.of(agent.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents").font(Tok.Font.heading).foregroundStyle(Tok.ink)
                    if let line = headerLine() { Text(line).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1) }
                }
                Spacer()
                if let onOpenTerminals {
                    Button(action: onOpenTerminals) { Text("Terminals").font(Tok.Font.small).foregroundStyle(Tok.work) }
                        .buttonStyle(.plain).help("Open the Terminals screen")
                }
            }
            .padding(.horizontal, Tok.Space.l).padding(.vertical, Tok.Space.m + 2)
            Scroller {
                // Lazy: the rows of agents out of view are not laid out when the pane appears.
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !feedOnly, let autopilot, autopilot.isAvailable { FixCards(autopilot: autopilot) }
                    if !feedOnly, let inbox { QuestionCards(inbox: inbox, autopilot: autopilot) }
                    if !feedOnly, let autopilot, autopilot.isAvailable { DecisionFeed(autopilot: autopilot) }
                    if let text = Self.text(for: state, hasSleeping: !sleeping.isEmpty) {
                        Text(text).font(Tok.Font.body)
                            .foregroundStyle({ if case .unavailable = state { return Tok.wait } else { return Tok.ink3 } }())
                    }
                    ForEach(rowAgents) { row($0) }
                    ForEach(sleeping) { row($0) }
                }
                .padding(.horizontal, Tok.Space.m).padding(.bottom, Tok.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Tok.pane)
    }

    /// Terminal · Sleep · Stop for a live agent: the ones the pane was given (Sleep only for an agent on a card).
    func actions(_ agent: AgentStatus, onCard: Bool) -> [AgentRow.Action] {
        var out: [AgentRow.Action] = []
        if let onOpenTerminal { out.append(.init(title: "Terminal", help: "Show this agent's pane in \(terminal)") { onOpenTerminal(agent) }) }
        if onCard, let onSleep {
            let why = sleepWhy(agent)
            out.append(.init(title: "Sleep", help: why ?? "Stop this agent's process; its worktree, branch and session stay. Wake continues the same conversation.",
                             disabled: why != nil) { onSleep(agent) })
        }
        if canStop(agent), let onStop { out.append(.init(title: "Stop", help: "Close this agent's workspace (asks first)") { onStop(agent) }) }
        return out
    }

    @ViewBuilder func row(_ agent: AgentStatus) -> some View {
        if let cards, let summary = cards.summary(agent) {
            let role = summary.role ?? "dev"
            AgentRow(name: .make(role: role, displayNames: displayNames), task: "\(summary.cardID) · \(summary.title)", status: AgentRowStatus.of(summary),
                     tint: roleTint(role), progress: summary.progress.map(AgentRowStatus.fraction), warning: summary.warning,
                     nudging: cards.isNudging(agent), onNudge: { cards.nudge(agent) }, onOpen: { open(agent) },
                     openHelp: onOpenCard == nil ? "Show \(summary.cardID)'s terminal" : Self.openHelp(cardID: summary.cardID),
                     actions: actions(agent, onCard: true), askingYou: askingYou(agent))
        } else if isPM(agent) {
            let line = PMActivityLine.shared.line(statusLine(agent), pane: agent.paneID)
            AgentRow(name: .make(role: Self.pmRole, displayNames: displayNames), task: line.isEmpty ? "No task" : line, status: AgentRowStatus.of(agent.state),
                     tint: roleTint(Self.pmRole), asking: pmAsking, actions: actions(agent, onCard: false), askingYou: askingYou(agent))
        } else {
            let line = statusLine(agent)
            AgentRow(name: AgentRowName(name: label(agent), role: ""), task: line.isEmpty ? "No task" : line, status: AgentRowStatus.of(agent.state),
                     tint: Tok.ink3, actions: actions(agent, onCard: false), askingYou: askingYou(agent))
        }
    }

    func row(_ agent: SleepingAgent) -> some View {
        let role = AgentRowName.role(ofAgent: agent.agent) ?? "dev"
        let wake = onWake.map { wake in [AgentRow.Action(title: "Wake", help: "Start this agent again in its worktree and continue its conversation") { wake(agent.cardID) }] } ?? []
        return AgentRow(name: .make(role: role, displayNames: displayNames), task: "\(agent.cardID) · \(AgentSummary.plainTitle(agent.title, id: agent.cardID))",
                        status: .asleep, tint: roleTint(role), actions: wake)
    }
}

/// The PM row's activity line without its control replies (N305): "✓" to the panel's key message says nothing, so the row keeps
/// the PM's last real line (one for the whole app: the pane is built anew on every draw).
@MainActor final class PMActivityLine {
    static let shared = PMActivityLine()
    private var last: [String: String] = [:]

    /// A reply made only of check marks, "ok" or "done" (any case, with a full stop).
    static func isControlReply(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)).lowercased()
        return t.isEmpty || t.allSatisfy { "✓✔✅ ".contains($0) } || ["ok", "okay", "done"].contains(t)
    }

    func line(_ line: String, pane: String) -> String {
        if Self.isControlReply(line) { return last[pane] ?? "" }
        last[pane] = line
        return line
    }
}

/// One agent's row (design A, N283): the role's avatar, its display name and role, the task, the status chip and, for a card agent, a
/// 3 pt line of its step progress. Terminal · Sleep · Stop show on hover; the context menu and the accessibility actions always have them.
struct AgentRow: View {
    struct Action {
        let title: String
        let help: String
        var disabled = false
        let perform: () -> Void
    }

    let name: AgentRowName
    let task: String
    let status: AgentRowStatus
    let tint: Color
    var progress: Double? = nil
    /// Waiting for the user: a dot after the name.
    var asking = false
    /// A stopped agent's warning: shown under the row with Nudge.
    var warning: String? = nil
    var nudging = false
    var onNudge: () -> Void = {}
    /// A click on the row; nil: the row opens nothing.
    var onOpen: (() -> Void)? = nil
    var openHelp: String? = nil
    var actions: [Action] = []
    /// An open question for the user (N370): the chip reads "asking you" in Tok.ask instead of the usual status.
    var askingYou = false
    @State var hovering = false

    static let askingLabel = "asking you"
    /// The chip's words: "asking you" over the usual status while a question is open.
    static func chipLabel(_ status: AgentRowStatus, askingYou: Bool) -> String { askingYou ? askingLabel : status.label }

    static func color(_ status: AgentRowStatus) -> Color {
        switch status {
        case .working: Tok.work
        case .waitingForYou: Tok.askText
        case .fixing: Tok.wait
        case .idle: Tok.ink2
        case .asleep: Tok.ink3
        case .stopped: Tok.stop
        }
    }

    static func chipFill(_ status: AgentRowStatus) -> Color {
        switch status {
        case .working: Tok.work.opacity(0.14)
        case .waitingForYou: Tok.ask.opacity(0.16)
        case .fixing: Tok.wait.opacity(0.14)
        case .idle: Tok.ink2.opacity(0.12)
        case .asleep: Tok.ink3.opacity(0.12)
        case .stopped: Tok.stop.opacity(0.14)
        }
    }

    private var color: Color { askingYou ? Tok.ask : Self.color(status) }
    private var chipLabel: String { Self.chipLabel(status, askingYou: askingYou) }
    private var stopped: Bool { status == .stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(name.initial).font(.system(size: 12, weight: .bold)).foregroundStyle(Tok.bg)
                    .frame(width: 30, height: 30).background(tint, in: Circle())
                    .opacity(status == .asleep ? 0.4 : 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(status == .asleep ? Tok.ink2 : Tok.ink).lineLimit(1)
                        if !name.role.isEmpty { Text(name.role).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1) }
                        if asking { Circle().fill(Tok.ask).frame(width: 7, height: 7).help("The PM is waiting for you").accessibilityLabel("The PM is waiting for you") }
                    }
                    Text(task).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.tail).help(task)
                }
                Spacer(minLength: 0)
                if hovering && !actions.isEmpty {
                    HStack(spacing: Tok.Space.s) {
                        ForEach(actions, id: \.title) { action in
                            Button(action: action.perform) { Text(action.title).font(Tok.Font.small).foregroundStyle(action.disabled ? Tok.ink3 : Tok.work).fixedSize() }
                                .buttonStyle(.plain).disabled(action.disabled).help(action.help)
                        }
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(chipLabel).font(Tok.Font.small.weight(.semibold)).foregroundStyle(color).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(askingYou ? Tok.ask.opacity(0.16) : Self.chipFill(status), in: Capsule())
                .fixedSize()
            }
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tok.line)
                        Capsule().fill(color).frame(width: geo.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 3).accessibilityHidden(true)
            }
            if let warning {
                Text(warning).font(Tok.Font.small).foregroundStyle(Tok.stop).fixedSize(horizontal: false, vertical: true)
                Button(nudging ? "Sending…" : "Nudge to continue", action: onNudge).disabled(nudging)
                    .controlSize(.small).help("Tell the agent to re-read its card and continue")
            }
        }
        .padding(.horizontal, Tok.Space.m).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stopped ? Tok.stop.opacity(0.06) : (hovering ? Tok.raise : Tok.bg), in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(stopped ? Tok.stop.opacity(0.35) : Tok.line))
        .contentShape(RoundedRectangle(cornerRadius: Tok.radius))
        .onTapGesture { onOpen?() }
        .onHover { inside in
            hovering = inside
            guard onOpen != nil else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(openHelp ?? "")
        .contextMenu { ForEach(actions, id: \.title) { action in Button(action.title, action: action.perform).disabled(action.disabled) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name.name)\(name.role.isEmpty ? "" : ", \(name.role)"), \(task), \(chipLabel)")
        .modifier(RowActions(open: onOpen, actions: actions))
    }
}

/// Open and the row's actions as accessibility actions, so they are reachable without hovering.
private struct RowActions: ViewModifier {
    let open: (() -> Void)?
    let actions: [AgentRow.Action]

    func body(content: Content) -> some View {
        let opened = open.map { open in AnyView(content.accessibilityAction(named: "Open on Tasks", open)) } ?? AnyView(content)
        return actions.filter { !$0.disabled }.reduce(opened) { view, action in AnyView(view.accessibilityAction(named: action.title, action.perform)) }
    }
}

/// A plain agent row with its phase tag (kept for the phase tag snapshot; the Agents pane draws `AgentRow`).
struct AgentCard: View {
    let agent: AgentStatus
    /// The agent's one live line (N251).
    var line: String? = nil
    let label: String
    var phase: TaskPhase? = nil
    var pmHandling = false
    var onOpenTerminal: ((AgentStatus) -> Void)? = nil
    var terminal = "Tentacl"
    var onStop: ((AgentStatus) -> Void)? = nil

    var color: Color {
        switch agent.state {
        case .working: return Tok.work
        case .done: return Tok.go
        case .blocked: return Tok.stop
        case .idle, .unknown: return Tok.ink3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Tok.Space.s) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
                Spacer()
                if let phase { TaskPhaseTag(phase: phase) } else if pmHandling { PMChip() }
                Chip(text: agent.paneID)
            }
            Text(line ?? agentSummaryLine(agent)).font(Tok.Font.mono).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.tail)
                .help(line ?? agentSummaryLine(agent))
            if onOpenTerminal != nil || onStop != nil {
                HStack(spacing: Tok.Space.s) {
                    if let onOpenTerminal { Button("Open terminal") { onOpenTerminal(agent) }.help("Show this agent's pane in \(terminal)") }
                    if let onStop { Button("Stop") { onStop(agent) }.help("Close this agent's workspace (asks first)") }
                }
                .buttonStyle(.link).font(Tok.Font.small)
            }
        }
        .padding(Tok.Space.s + 2)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        .accessibilityElement(children: onOpenTerminal != nil || onStop != nil ? .contain : .combine)
    }
}

/// "PM handling": the agent waits, but on the PM, not on you.
private struct PMChip: View {
    var body: some View {
        Text("PM handling").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Tok.work.opacity(0.16), in: Capsule())
    }
}

#Preview("AgentsPane · available") {
    AgentsPane(state: .available([
        AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .working, cwd: "/Users/you/Projects/demo/.agent-worktrees/a5", title: "dev-a5"),
        AgentStatus(paneID: "w4:p1", workspaceID: "w4", state: .blocked, cwd: "/Users/you/Projects/demo/.agent-worktrees/a3", title: "dev-a3"),
    ])).frame(height: 500)
}

#Preview("AgentsPane · terminal down") {
    AgentsPane(state: .unavailable("the terminal is not running: no daemon")).frame(height: 300)
}
