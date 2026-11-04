import SwiftUI

/// The task list column (design B, N135): "By round" (plan.json rounds with progress bars, then the open cards in no round), "By status"
/// (today's sections) and "Done" (each finished round with its cards, then the finished cards in no round with their sort, N181). Unreadable
/// cards are listed, never hidden.
struct TaskListView: View {
    @Bindable var model: PanelModel
    var onPlanRound: () -> Void = {}
    var onNewTask: () -> Void = {}
    var onAddProject: () -> Void = {}
    var onOpenSetup: () -> Void = {}
    /// The project's plan.json, read off the main thread by this view; the shell keeps it for the detail's round name.
    var plan: Binding<PlanFile?> = .constant(nil)
    @State private var query = ""
    /// Titles of the default-collapsed sections (Done, Cancelled) the user opened.
    @State private var expanded: Set<String> = []
    /// The Done and Cancelled order of the selected project.
    @State private var finishedSort = FinishedSort.default
    /// By round, By status or Done; kept per project.
    @State private var mode = TaskListMode.byRound
    /// Done groups the user opened or closed against their default (the newest one open).
    @State private var toggledDone: Set<String> = []
    /// The note under a dimmed "Plan a round": why it is off.
    @State private var planWhyOpen = false
    /// The view a snapshot draws, in place of the project's saved one.
    var startMode: TaskListMode? = nil
    /// The search a snapshot draws.
    var startQuery: String? = nil
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let filtered = TaskListFilter.filter(model.cards, query: query)
        // Only By status lists by status: By round and Done do not need its sections.
        let sections = mode == .byStatus ? TaskGrouping.sections(from: filtered, finishedSort: finishedSort) : []
        let graph = model.dependencyGraph
        let groups = roundGroups(filtered)
        let done = mode == .done ? doneGroups(filtered) : []
        VStack(alignment: .leading, spacing: 0) {
            if model.selectedProject != nil { toolbar }
            Scroller {
                // Lazy: a project with a hundred cards lays out the rows in view, not all of them, on every switch to this screen.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.cards.isEmpty { emptyState }
                    else if filtered.isEmpty { Text("No card matches \u{201C}\(query)\u{201D}").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(Tok.Space.l) }
                    else {
                        switch mode {
                        case .byRound: byRound(groups, filtered, graph)
                        case .byStatus: statusSections(sections, graph)
                        case .done: doneView(done, graph)
                        }
                    }
                }
                .padding(.bottom, Tok.Space.m)
            }
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(-1, sections, groups, done) }
        .onKeyPress(.downArrow) { moveSelection(1, sections, groups, done) }
        .background(Tok.list)
        .onAppear(perform: loadSort)
        .onChange(of: model.selectedProjectID) { loadSort() }
        .task(id: PlanKey(dir: model.selectedProject?.dataURL, cards: model.cards.count)) { await loadPlan() }
    }

    private struct PlanKey: Equatable { let dir: URL?; let cards: Int }

    /// plan.json is read off the main thread; a missing or broken file means no rounds (the Plan screen says why).
    private func loadPlan() async {
        guard let dir = model.selectedProject?.dataURL else { plan.wrappedValue = nil; return }
        let loaded = await Task.detached { PlanReader.load(dataDir: dir) }.value
        let file: PlanFile? = if case .plan(let f) = loaded { f } else { nil }
        if plan.wrappedValue != file { plan.wrappedValue = file }
    }

    private func roundGroups(_ filtered: [CardLoadResult]) -> (open: [RoundGroup], finished: [RoundGroup]) {
        let cards = filtered.compactMap { if case .card(let c) = $0 { c } else { nil } }
        let asking = Set(model.questionsForYou.map(\.cardID))
        return TaskGrouping.rounds(cards: cards, plan: plan.wrappedValue, needsYou: { asking.contains($0.id) })
    }

    /// Judged on all cards, so a search never makes an unfinished round look finished; the search then keeps the matches.
    private func doneGroups(_ filtered: [CardLoadResult]) -> [RoundGroup] {
        let all = model.cards.compactMap { if case .card(let c) = $0 { c } else { nil } }
        let matching: Set<String>? = searching ? Set(filtered.compactMap { if case .card(let c) = $0 { c.id } else { nil } }) : nil
        return TaskGrouping.doneGroups(cards: all, plan: plan.wrappedValue, finishedSort: finishedSort, matching: matching)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Search, New task (+), Plan a round, and the three views.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tok.Space.s) {
                if model.cards.isEmpty { Spacer() }
                else if snapshot {
                    // The AppKit text field cannot be drawn into a snapshot (N117): a look-alike stands in.
                    searchBox(query.isEmpty ? Text("Search id, title, role, status").foregroundStyle(Tok.ink3) : Text(query).foregroundStyle(Tok.ink))
                } else {
                    // Design B (N142): a plain field in a 30 pt box, as the snapshot look-alike.
                    searchBox(TextField("", text: $query, prompt: Text("Search id, title, role, status").foregroundStyle(Tok.ink3))
                        .textFieldStyle(.plain).foregroundStyle(Tok.ink))
                }
                planRoundButton
                Button(action: onNewTask) { Image(systemName: "plus") }.buttonStyle(IconButtonStyle())
                    .help("Write a new task card in this project.").accessibilityLabel("New task").tutorialAnchor(.taskNew)
            }
            .padding(.horizontal, Tok.Space.l).padding(.top, Tok.Space.l).padding(.bottom, 10)
            HStack(spacing: Tok.Space.l) {
                ForEach(TaskListMode.allCases, id: \.self) { m in
                    Button { setMode(m) } label: {
                        Text(m.label).font(.system(size: 12, weight: mode == m ? .semibold : .regular)).foregroundStyle(mode == m ? Tok.ink : Tok.ink2)
                            .padding(.vertical, Tok.Space.s)
                            .overlay(alignment: .bottom) { if mode == m { Rectangle().fill(Tok.ink).frame(height: 2) } }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == m ? .isSelected : [])
                }
                Spacer()
                if mode == .done { sortMenu }
            }
            .tutorialAnchor(.taskModes)
            .padding(.horizontal, Tok.Space.l)
            .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
        }
    }

    /// Always there (N206): when a round cannot be planned the icon is dimmed and a click says why, with a way to turn the autopilot on.
    private var planRoundButton: some View {
        let state = model.planRoundState
        return Button { if state.enabled { onPlanRound() } else { planWhyOpen = true } } label: { Image(systemName: "square.stack.3d.up") }
            .buttonStyle(IconButtonStyle()).opacity(state.enabled ? 1 : 0.45)
            .help(state.enabled ? "Plan a round: \(state.help)" : "Plan a round is off: \(state.help)")
            .accessibilityLabel("Plan a round").accessibilityValue(state.enabled ? "" : "Off")
            .popover(isPresented: Binding(get: { planWhyOpen && !snapshot }, set: { planWhyOpen = $0 }), arrowEdge: .bottom) {
                PlanRoundWhy(autopilot: model.autopilot, reason: state.help) { planWhyOpen = false }
            }
    }

    private func searchBox(_ field: some View) -> some View {
        field.font(.system(size: 12))
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(Tok.bg, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
    }

    // MARK: By round

    @ViewBuilder private func byRound(_ groups: (open: [RoundGroup], finished: [RoundGroup]), _ filtered: [CardLoadResult], _ graph: DependencyGraph) -> some View {
        // A search also opens the finished rounds, so a match is never hidden.
        let shown = query.trimmingCharacters(in: .whitespaces).isEmpty ? groups.open : groups.open + groups.finished
        ForEach(shown) { group in
            RoundHeader(group: group)
            ForEach(group.cards) { card in roundRow(card, graph) }
        }
        if shown.count == groups.open.count, !groups.finished.isEmpty {
            Button { setMode(.done) } label: {
                Text(groups.finished.count == 1 ? "1 finished round under Done" : "\(groups.finished.count) finished rounds under Done")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).underline()
            }
            .buttonStyle(.plain).padding(.horizontal, Tok.Space.l).padding(.top, Tok.Space.m)
        }
        unreadableRows(filtered)
    }

    private func roundRow(_ card: TaskCard, _ graph: DependencyGraph) -> some View {
        let phase = model.phase(of: card)
        let tag = AgentTagInfo.make(card, displayNames: model.roleDisplayNames, phase: phase)
        return RoundRow(card: card, selected: model.selectedCardID == card.id,
                        state: TaskGrouping.rowState(card, phase: phase, dependency: graph.state(of: card.id), startedAt: model.cardFacts[card.id]?.startedAt, now: Date(), finishedSort: finishedSort),
                        agentTag: tag?.opensTerminal == true ? tag : nil,
                        onOpenScreen: { if let pane = model.agentPane(of: card) { model.openTerminalTab(pane) } }) { model.selectedCardID = card.id }
    }

    @ViewBuilder private func unreadableRows(_ filtered: [CardLoadResult]) -> some View {
        let broken = filtered.filter { if case .unreadable = $0 { true } else { false } }
        if !broken.isEmpty {
            sectionTitle("Unreadable cards", count: broken.count)
            ForEach(broken, id: \.rowID) { row in
                if case .unreadable(let url, let reason) = row { UnreadableRow(url: url, reason: reason) }
            }
        }
    }

    // MARK: Done

    /// Each finished round, newest first, with its cards; then "Not in a round". The newest group starts open, the others closed.
    @ViewBuilder private func doneView(_ groups: [RoundGroup], _ graph: DependencyGraph) -> some View {
        let open = TaskGrouping.openDoneGroups(groups, toggled: toggledDone, searching: searching)
        if groups.isEmpty {
            Text(searching ? "No finished card matches \u{201C}\(query)\u{201D}" : "Nothing finished yet.").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(Tok.Space.l)
        }
        ForEach(groups) { group in
            RoundHeader(group: group, open: open.contains(group.id)) {
                // While searching every group is open; a click then waits for the search to end.
                if toggledDone.contains(group.id) { toggledDone.remove(group.id) } else { toggledDone.insert(group.id) }
            }
            if open.contains(group.id) { ForEach(group.cards) { card in roundRow(card, graph) } }
        }
    }

    // MARK: By status (today's sections)

    @ViewBuilder private func statusSections(_ sections: [TaskSection], _ graph: DependencyGraph) -> some View {
        ForEach(sections) { section in
            let collapsed = TaskListFilter.isCollapsed(section.title, expanded: expanded, query: query)
            HStack(spacing: Tok.Space.xs) {
                Button {
                    guard TaskListFilter.collapsedByDefault.contains(section.title) else { return }
                    if expanded.contains(section.title) { expanded.remove(section.title) } else { expanded.insert(section.title) }
                } label: {
                    HStack {
                        if TaskListFilter.collapsedByDefault.contains(section.title) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        Text(section.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(section.title), \(section.rows.count)")
                if TaskListFilter.collapsedByDefault.contains(section.title) { sortMenu }
                Text("\(section.rows.count)")
            }
            .font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink3)
            .padding(.horizontal, Tok.Space.m + 2).padding(.top, Tok.Space.m).padding(.bottom, Tok.Space.xs)
            if !collapsed { rows(section, graph) }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack { Text(title); Spacer(); Text("\(count)") }
            .font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink3)
            .padding(.horizontal, Tok.Space.m + 2).padding(.top, Tok.Space.m).padding(.bottom, Tok.Space.xs)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func rows(_ section: TaskSection, _ graph: DependencyGraph) -> some View {
        ForEach(section.rows, id: \.rowID) { row in
            switch row {
            case .card(let card): roundRow(card, graph)
            case .unreadable(let url, let reason): UnreadableRow(url: url, reason: reason)
            }
        }
    }

    private func setMode(_ m: TaskListMode) {
        mode = m
        if let id = model.selectedProjectID { m.save(model.defaults, project: id) }
    }

    private func loadSort() {
        finishedSort = model.selectedProjectID.map { FinishedSort.load(model.defaults, project: $0) } ?? .default
        mode = startMode ?? model.selectedProjectID.map { TaskListMode.load(model.defaults, project: $0) } ?? .byRound
        toggledDone = []
        if let startQuery { query = startQuery }
    }

    @ViewBuilder private var sortMenu: some View {
        // The AppKit menu cannot be drawn into a snapshot (N117): its icon stands in.
        if snapshot { sortIcon } else { sortMenuButton }
    }

    private var sortIcon: some View {
        Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.ink3)
    }

    private var sortMenuButton: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { finishedSort.key }, set: { setSort(FinishedSort(key: $0, newestFirst: finishedSort.newestFirst)) })) {
                ForEach(FinishedSort.Key.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Direction", selection: Binding(get: { finishedSort.newestFirst }, set: { setSort(FinishedSort(key: finishedSort.key, newestFirst: $0)) })) {
                Text(finishedSort.directionLabels.first).tag(true)
                Text(finishedSort.directionLabels.second).tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            sortIcon
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Sort the finished tasks: \(finishedSort.key.label), \(finishedSort.newestFirst ? finishedSort.directionLabels.first : finishedSort.directionLabels.second).")
        .accessibilityLabel("Sort finished tasks")
    }

    private func setSort(_ sort: FinishedSort) {
        finishedSort = sort
        if let id = model.selectedProjectID { sort.save(model.defaults, project: id) }
    }

    private func moveSelection(_ delta: Int, _ sections: [TaskSection], _ groups: (open: [RoundGroup], finished: [RoundGroup]), _ done: [RoundGroup]) -> KeyPress.Result {
        let ids: [String]
        switch mode {
        case .byStatus: ids = TaskListFilter.visibleCardIDs(sections, expanded: expanded, query: query)
        case .done: ids = TaskGrouping.visibleDoneCardIDs(done, open: TaskGrouping.openDoneGroups(done, toggled: toggledDone, searching: searching))
        case .byRound:
            let shown = query.trimmingCharacters(in: .whitespaces).isEmpty ? groups.open : groups.open + groups.finished
            ids = shown.flatMap(\.cards).map(\.id)
        }
        guard let next = TaskListFilter.move(from: model.selectedCardID, in: ids, by: delta) else { return .ignored }
        model.selectedCardID = next
        return .handled
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            if model.projects.isEmpty {
                Text("No project yet").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                Text(emptyProjectsHint(setupMissing: model.setup.hasMissingRequired))
                    .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Tok.Space.s) {
                    Button("Add project…", action: onAddProject).buttonStyle(PanelButtonStyle()).disabled(model.settings.scriptsDir == nil)
                    Button("Setup…", action: onOpenSetup).buttonStyle(PanelButtonStyle()).tutorialAnchor(.setupButton)
                }
                ForEach(model.problems, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.wait) }
            } else {
                // N308: the first card is made from here, with the same actions as the toolbar's + and Plan a round.
                Text("No task cards").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                Text("Write the first card yourself, or let the PM plan a round of cards.").font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Tok.Space.s) {
                    Button("New task…", action: onNewTask).buttonStyle(PanelButtonStyle()).help("Write a new task card in this project.")
                    let plan = model.planRoundState
                    Button("Plan a round") { if plan.enabled { onPlanRound() } else { planWhyOpen = true } }
                        .buttonStyle(PanelButtonStyle()).opacity(plan.enabled ? 1 : 0.45)
                        .help(plan.enabled ? "Plan a round: \(plan.help)" : "Plan a round is off: \(plan.help)")
                        .accessibilityValue(plan.enabled ? "" : "Off")
                }
            }
        }
        .padding(Tok.Space.l)
    }
}

private extension CardLoadResult {
    var rowID: String {
        switch self {
        case .card(let c): return "card:\(c.id)"
        case .unreadable(let url, _): return "file:\(url.path)"
        }
    }
}

private struct UnreadableRow: View {
    let url: URL
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: Tok.Space.s + 1) {
            Circle().fill(Tok.wait).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                Text(reason).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
        .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.s + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A round's header in the list: its name, "n of m merged" and one bar segment per card. On Done (N181) it opens and closes its cards.
private struct RoundHeader: View {
    let group: RoundGroup
    /// Nil: the header cannot be closed (By round).
    var open: Bool? = nil
    var onToggle: () -> Void = {}

    var body: some View {
        if let open {
            Button(action: onToggle) { content(open).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.name), \(group.progressText)")
                .accessibilityValue(open ? "open" : "closed")
        } else {
            content(nil)
        }
    }

    private func content(_ open: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Tok.Space.s) {
                if let open {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tok.ink3)
                        .frame(width: 10)
                }
                Text(group.name).font(.system(size: 12, weight: .bold)).foregroundStyle(Tok.ink).lineLimit(1)
                Spacer()
                Text(group.progressText).font(Tok.Font.small).monospacedDigit().foregroundStyle(Tok.ink3)
            }
            if !group.segments.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(group.segments.enumerated()), id: \.offset) { _, tone in Capsule().fill(Self.color(tone)).frame(height: 4) }
                }
            }
        }
        .padding(.horizontal, Tok.Space.l).padding(.top, 14).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    static func color(_ tone: SegmentTone) -> Color {
        switch tone {
        case .done: return Tok.go
        case .doing: return Tok.work
        case .needsYou: return Tok.ask
        case .todo: return Tok.line
        }
    }
}

/// One line per card in all three list views (N139): status dot, id, title without its leading id (cut with an ellipsis), the running
/// agent's tag, and a short state (a finished card's finish time).
struct RoundRow: View {
    let card: TaskCard
    let selected: Bool
    let state: RowState
    var agentTag: AgentTagInfo? = nil
    var onOpenScreen: () -> Void = {}
    let onSelect: () -> Void

    var body: some View {
        let title = TaskGrouping.rowTitle(card)
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // A plain dot as in design B (N142), without StatusDot's halo for a review.
                Circle().fill(StatusDot.color(for: card.status)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(card.id).font(Tok.Font.mono).foregroundStyle(Tok.ink3).lineLimit(1).frame(width: 38, alignment: .leading)
                Text(title).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let agentTag { AgentTag(info: agentTag, onOpen: onOpenScreen) }
                Text(state.text).font(Tok.Font.small).foregroundStyle(Self.color(state.tone)).lineLimit(1).fixedSize().tutorialAnchor(.taskRowStatus)
            }
            .padding(.horizontal, Tok.Space.l).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Tok.raise : .clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Tok.ask).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("\(card.id), \(title), \(state.text)")
    }

    static func color(_ tone: RowState.Tone) -> Color {
        switch tone {
        case .ask: return Tok.askText
        case .wait: return Tok.wait
        case .normal: return Tok.ink2
        case .quiet: return Tok.ink3
        case .problem: return Tok.stop
        }
    }
}

/// Why "Plan a round" is off (N206). With the autopilot Off: Shadow is one click (the PM only suggests), On and the rest are in the rules.
struct PlanRoundWhy: View {
    @Bindable var autopilot: AutopilotModel
    let reason: String
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            Text("Plan a round is off").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
            Text(reason).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            if autopilot.isAvailable, autopilot.policy.mode == .off {
                HStack(spacing: Tok.Space.s) {
                    Button("Switch to Shadow") { autopilot.setMode(.shadow); onClose() }.buttonStyle(ConfirmButtonStyle())
                        .help("Shadow: the PM suggests answers and plans rounds; nothing is sent or started without you.")
                    Button("Autopilot rules…") { onClose(); autopilot.rulesOpen = true }.buttonStyle(PanelButtonStyle())
                }
            }
        }
        .padding(Tok.Space.m)
        .frame(width: 320, alignment: .topLeading)
        .background(Tok.bg)
    }
}
