import SwiftUI

/// The middle column (design B, N135): the task's header with its next step, the progress steps, a segmented tab row, and the Overview
/// boxes (report in short, agent, changed files) or one of today's tab contents.
struct TaskDetailView: View {
    enum Tab: String, CaseIterable {
        case overview = "Overview", card = "Card", report = "Report", packet = "Review packet", changes = "Changes", screenshots = "Screenshots"
        case timeline = "Timeline", preview = "Preview"
    }

    let card: TaskCard
    let shots: [ShotItem]
    let opener: WorkspaceOpener?
    var phase: TaskPhase? = nil
    var agentTag: AgentTagInfo? = nil
    /// What the running action is doing (the buttons are off while it runs); nil when nothing runs.
    var busyMessage: String? = nil
    let startState: StartButtonState
    let reviewState: ReviewButtonStates
    let onStart: () -> Void
    /// Resume agent (the agent is gone, the worktree is there): the state is nil when Resume does not apply.
    var resumeState: StartButtonState? = nil
    var onResume: () -> Void = {}
    let onPrepare: () -> Void
    let onApprove: () -> Void
    let onRequestFix: () -> Void
    var onClose: () -> Void = {}
    /// Opens the Edit card form; nil hides the button.
    var onEdit: (() -> Void)? = nil
    /// The action log lines (for the timeline) and what is needed to read the agent's screen (Preview).
    var logEvents: () -> [ActionLogEvent] = { [] }
    var screenReader: TerminalReading = PanelModel.inertTerminal
    var agentPane: String? = nil
    /// Shows an agent's live pane on the Terminals screen (the agent tag, Preview's back button).
    var onOpenTerminal: (String) -> Void = { _ in }
    /// The decisions recorded for the project (the timeline keeps this card's).
    var decisions: () -> [DecisionRecord] = { [] }
    /// The plan.json round the card is in.
    var roundName: String? = nil
    /// The Agent box before the session files are read (the role's configured model and effort), and the reader of the full one
    /// (tokens, cost, the model really used; off the main thread).
    var agentFacts: AgentFacts? = nil
    var loadAgentFacts: (() async -> AgentFacts?)? = nil
    /// The tab shown until the user picks one.
    var startTab: Tab = .overview
    /// The Changes tab's files and diffs given up front (snapshots); else read from the branch when the project is known.
    var diffPreload: DiffPreload? = nil
    /// Comments on the Changes tab's lines (N249) and the fix request that sends them; nil leaves the diff without comments.
    var diffComments: DiffCommentStore? = nil
    var onSendDiffComments: ((String) async -> Bool)? = nil
    /// Told each tab the user picks (the window keeps it for the next launch, N260).
    var onTab: ((Tab) -> Void)? = nil
    @State private var picked: Tab?
    @State private var loadedFacts: AgentFacts?
    /// The Preview tab's screenshots (`tasks/assets/<ID>-preview-<n>.png`), shown with the card's others.
    @State private var previewShots: [ShotItem] = []
    private var tab: Tab { picked ?? startTab }

    private var packet: PacketSections { packetSections(from: card.sections["Review packet"] ?? "") }

    var body: some View {
        let tabs = DetailTab.items(card: card, shots: allShots.count)
        Scroller {
            VStack(alignment: .leading, spacing: 18) {
                header
                ProgressStepsRow(steps: TaskProgress.steps(card: card, phase: phase, events: logEvents(), now: Date()))
                SegmentedTabs(items: tabs, selected: tab) { picked = $0 }.tutorialAnchor(.taskTabs).padding(.top, -4)
                VStack(alignment: .leading, spacing: Tok.Space.xl) {
                    switch tab {
                    case .overview: overview
                    case .card: cardTab
                    case .packet: packetTab
                    case .report: reportTab
                    case .changes: changesTab
                    case .screenshots: ShotGrid(items: allShots)
                    case .timeline: timelineTab
                    case .preview:
                        PreviewTab(card: card, reader: screenReader, target: agentPane, assets: assetsFolder, onShot: { _ in loadPreviewShots() },
                                   onBackToTerminal: { if let agentPane { onOpenTerminal(agentPane) } })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 32).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tok.bg)
        .background {
            Button("") { picked = DetailTab.move(from: tab, in: tabs, by: -1) }.keyboardShortcut("[", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            Button("") { picked = DetailTab.move(from: tab, in: tabs, by: 1) }.keyboardShortcut("]", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .task(id: card.id) { if let loadAgentFacts { loadedFacts = await loadAgentFacts() } }
        .task(id: card.id) { loadPreviewShots() }
        .onChange(of: picked) { _, next in if let next { onTab?(next) } }
    }

    private var assetsFolder: URL { card.url.deletingLastPathComponent().appendingPathComponent("assets") }

    private var allShots: [ShotItem] { shots + previewShots.filter { s in !shots.contains { $0.id == s.id } } }

    private func loadPreviewShots() { previewShots = ShotItem.items(for: PreviewShots.existing(in: assetsFolder, id: card.id)) }

    /// "N130 · ui_dev · round “…”", the title, and the next step at the right.
    private var header: some View {
        let step = nextStep(card: card, phase: phase, start: startState, review: reviewState, resume: resumeState)
        return VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(alignment: .top, spacing: Tok.Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Tok.Space.s) {
                        Text(metaLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink3).lineLimit(1)
                        if let agentTag { AgentTag(info: agentTag) { if let agentPane { onOpenTerminal(agentPane) } } }
                        if let phase { TaskPhaseTag(phase: phase) }
                    }
                    // The id is in the line above (design B, N142): the title drops a leading one, as the list rows do.
                    Text(TaskGrouping.rowTitle(card)).font(.system(size: 22, weight: .bold)).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NextStepBar(card: card, step: step, items: moreItems(card: card, step: step, start: startState, review: reviewState, canEdit: onEdit != nil),
                            opener: opener, help: help(for:), perform: perform)
                    .fixedSize()
            }
            if let busyMessage {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busyMessage).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(2) }
            }
        }
    }

    private var metaLine: String {
        ([card.id, card.roles.first ?? "dev"] + [roundName.map { "round \u{201C}\($0)\u{201D}" }].compactMap { $0 }).joined(separator: " · ")
    }

    // MARK: Overview

    @ViewBuilder private var overview: some View {
        let facts = loadedFacts ?? agentFacts
        OverviewColumns {
            reportBox
            VStack(spacing: Tok.Space.m) { agentBox(facts); filesBox }
        }
    }

    private var reportBox: some View {
        let lines = ReportSummary.lines(card.sections["Report"] ?? "")
        return DetailBox(title: "Report in short", horizontalPadding: 18, verticalPadding: 16) {
            if lines.isEmpty { Text("No report yet").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                (line.lead.map { Text("\($0): ").bold() } ?? Text("")) + Text(line.text)
            }
            .font(Tok.Font.body).foregroundStyle(Tok.ink).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            if !lines.isEmpty {
                Button("Full report") { picked = .report }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tok.ink2).underline()
            }
        }
    }

    private func agentBox(_ facts: AgentFacts?) -> some View {
        let f = facts ?? AgentFacts(model: "—", modelHelp: nil, effort: "—", tokens: "—", cost: "—")
        return DetailBox(title: "Agent") {
            Grid(alignment: .leading, horizontalSpacing: Tok.Space.l, verticalSpacing: 10) {
                GridRow { fact("Model", f.model).help(f.modelHelp ?? ""); fact("Effort", f.effort) }
                GridRow { fact("Tokens", f.tokens); fact("Cost (estimate)", f.cost) }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tok.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filesBox: some View {
        let files = ChangedFile.parse(packet.diff)
        return DetailBox(title: files.isEmpty ? "Changed files" : "Changed files · \(files.count)", spacing: 8) {
            if files.isEmpty { Text("No diff yet; it comes with the review packet.").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            ForEach(Array(files.prefix(8).enumerated()), id: \.offset) { _, file in
                HStack(spacing: Tok.Space.s) {
                    Text(file.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle).help(file.path)
                    Spacer(minLength: Tok.Space.s)
                    Text(file.text).font(.system(size: 12)).monospacedDigit().foregroundStyle(file.removed > 0 && file.added == 0 ? Tok.stop : Tok.go)
                        .help(file.exact ? "" : "git scaled the +/− bar of this file; the split is a share of its changed lines.")
                }
            }
            if files.count > 8 {
                Button("\(files.count - 8) more") { picked = .changes }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tok.ink2).underline()
            }
        }
    }

    private func help(for action: NextAction) -> String {
        switch action {
        case .start: return startState.help
        case .resume: return resumeState?.help ?? ""
        case .prepare: return reviewState.prepare.help
        case .approve: return reviewState.approve.help
        }
    }

    private func perform(_ action: MoreAction) {
        switch action {
        case .approve: onApprove()
        case .requestFix: onRequestFix()
        case .prepare: onPrepare()
        case .close: onClose()
        case .start: onStart()
        case .resume: onResume()
        case .edit: onEdit?()
        }
    }

    @ViewBuilder private var packetTab: some View {
        let raw = card.sections["Review packet"] ?? ""
        if raw.isEmpty {
            Text("No review packet yet.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
        } else if packet.build.isEmpty && packet.screenshots.isEmpty {
            Text(raw).font(Tok.Font.body).foregroundStyle(Tok.ink2).textSelection(.enabled)
        } else {
            HStack(spacing: Tok.Space.m) {
                Check(title: "Build", value: packet.build.hasPrefix("none") ? "none" : (packet.buildPassed ? "passed" : "failed"), good: packet.buildAcceptable)
                Check(title: "Screenshots", value: packet.screenshotsNotUsed ? "not used" : "\(shots.count)", good: packet.screenshotsAcceptable)
                Check(title: "Files changed", value: packet.filesChanged.map(String.init) ?? "—", good: packet.filesChanged != nil)
            }
            ShotGrid(items: shots)
            if !packet.diff.isEmpty {
                Text(packet.diff).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled)
                    .padding(Tok.Space.m + 2).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            }
        }
    }

    @ViewBuilder private var cardTab: some View {
        ForEach(CardOverview.sections(for: card), id: \.title) { section in
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                Text(section.title).font(Tok.Font.heading).foregroundStyle(Tok.ink)
                if section.entries.isEmpty {
                    Text("Nothing written.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                }
                ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in MarkdownText(text: entry) }
            }
        }
    }

    @ViewBuilder private var reportTab: some View {
        let report = card.sections["Report"] ?? ""
        if report.isEmpty { Text("The agent has not written a report yet.").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
        else { MarkdownText(text: report) }
    }

    /// Reads the branch's diff against the main branch (N204); nil under XCTest, so no test reads a real repository.
    private var diffReader: TaskDiffReader? {
        guard !PanelModel.runsUnderXCTest, let project = opener?.project, let branch = card.branch, TaskInput.validBranch(branch) else { return nil }
        return TaskDiffReader(runner: ProcessToolRunner(timeout: 30), repoPath: project.repoPath, base: project.baseBranch, branch: branch)
    }

    @ViewBuilder private var changesTab: some View {
        if diffPreload != nil || diffReader != nil {
            let reader = diffReader
            ChangesPane(reader: reader, preload: diffPreload,
                        openInXcode: opener.flatMap { o in card.branch.map { b in { DiffOpening.openInXcode($0, project: o.project, branch: b) } } },
                        openInTerminal: reader.map { r in { DiffOpening.openInTerminal($0, reader: r) } },
                        comments: diffComments, commentKey: DiffCommentStore.key(project: card.project, card: card.id), onSend: onSendDiffComments)
        } else {
            plainChanges
        }
    }

    @ViewBuilder private var plainChanges: some View {
        if card.files.isEmpty { Text("No files listed on the card.").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
        ForEach(card.files, id: \.self) { Text($0).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled) }
        if !packet.diff.isEmpty {
            Text(packet.diff).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled)
        }
    }

    @ViewBuilder private var timelineTab: some View {
        let entries = TaskTimeline.build(card: card, events: logEvents(), decisions: decisions())
        if entries.isEmpty { Text("Nothing recorded for this task yet.").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
        ForEach(entries) { e in
            HStack(spacing: Tok.Space.m) {
                Text(e.time.formatted(date: .abbreviated, time: .shortened)).font(Tok.Font.mono).foregroundStyle(Tok.ink3)
                Text(e.title).font(Tok.Font.body).foregroundStyle(Tok.ink)
                if let detail = e.detail { Text(detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2) }
            }
        }
    }
}

/// The Preview tab (N225): the local page the agent's terminal shows, found with `LocalPageFinder` (the last one found stays when it
/// scrolls off the screen); with none, the empty state with an address field. Close goes back to the agent's terminal when a page was
/// found (N229: it used to show "No local page found"), else to the empty state.
private struct PreviewTab: View {
    let card: TaskCard
    let assets: URL
    let onShot: (URL) -> Void
    let onBackToTerminal: () -> Void
    @State private var poller: AgentScreenPoller
    @State private var found: LocalPage?
    @State private var reset = 0

    init(card: TaskCard, reader: TerminalReading, target: String?, assets: URL, onShot: @escaping (URL) -> Void, onBackToTerminal: @escaping () -> Void) {
        self.card = card; self.assets = assets; self.onShot = onShot; self.onBackToTerminal = onBackToTerminal
        _poller = State(initialValue: AgentScreenPoller(reader: reader, target: target, interval: .seconds(3)))
    }

    var body: some View {
        let page = found
        PreviewPane(url: page?.url, source: page?.command, cardID: card.id, assetsFolder: assets,
                    addFixNote: { line in
                        do { try PreviewNote.append(line, toCardAt: card.url); return nil }
                        catch { return "Could not add the note: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))" }
                    },
                    onShot: onShot, onClose: {
                        switch PreviewClose.after(found: found) {
                        case .terminal: onBackToTerminal()
                        case .empty: reset += 1
                        }
                    })
            .id("\(page?.url.absoluteString ?? "")|\(reset)")
            .frame(height: page == nil ? nil : 680)
            .onAppear { poller.appear() }
            .onDisappear { poller.disappear() }
            .onChange(of: poller.text, initial: true) { _, text in
                if let page = LocalPageFinder.find(in: text), page != found { found = page }
            }
    }
}

private struct Check: View {
    let title: String
    let value: String
    let good: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Tok.Font.heading).foregroundStyle(good ? Tok.go : Tok.wait)
            Text(title).font(Tok.Font.small).foregroundStyle(Tok.ink3)
        }
        .padding(Tok.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}

/// The Overview's two columns as in design B: the report and the side column (Agent, Changed files) split the width 1.4 to 1 with 16
/// between them, when the side gets at least 300 (the report then 420); else the three boxes under each other. One set of views, laid out
/// once: a `ViewThatFits` with both arrangements built and measured every box twice on each switch to the Tasks screen (N138).
struct OverviewColumns: Layout {
    private static let gap = Tok.Space.l
    private static let minSide: CGFloat = 300

    /// The report's and the side column's widths, or nil when the boxes stack.
    static func columns(width: CGFloat) -> (report: CGFloat, side: CGFloat)? {
        let side = (width - gap) / 2.4
        return side >= minSide ? (width - gap - side, side) : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 1000
        if let c = Self.columns(width: width) {
            let report = subviews[0].sizeThatFits(ProposedViewSize(width: c.report, height: nil))
            let side = subviews[1].sizeThatFits(ProposedViewSize(width: c.side, height: nil))
            return CGSize(width: width, height: max(report.height, side.height))
        }
        let report = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let side = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: report.height + Tok.Space.m + side.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if let c = Self.columns(width: bounds.width) {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: c.report, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + c.report + Self.gap, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: c.side, height: nil))
        } else {
            let report = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + report.height + Tok.Space.m), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// A box of the Overview: a small capitalised heading over its content.
private struct DetailBox<Content: View>: View {
    let title: String
    var spacing: CGFloat = 10
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(Tok.ink2)
            content()
        }
        .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
    }
}

/// Card → Started → Work → Packet → Your review → Merged, each with a bar, its name and a time.
struct ProgressStepsRow: View {
    let steps: [ProgressStep]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Self.bar(step.tone)).frame(height: 4)
                    Text(step.kind.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Self.ink(step.tone)).lineLimit(1)
                    Text(step.when).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    static func bar(_ tone: ProgressStep.Tone) -> Color {
        switch tone {
        case .done: return Tok.go
        case .waiting: return Tok.ask
        case .working: return Tok.work
        case .todo: return Tok.line
        }
    }

    static func ink(_ tone: ProgressStep.Tone) -> Color {
        switch tone {
        case .waiting: return Tok.askText
        case .todo: return Tok.ink3
        default: return Tok.ink
        }
    }
}

/// The tab row as a segmented control (user's choice, N135): one rounded track, the selected tab raised; counts as small numbers.
struct SegmentedTabs: View {
    let items: [DetailTab]
    let selected: TaskDetailView.Tab
    let onSelect: (TaskDetailView.Tab) -> Void

    var body: some View {
        Scroller(axes: .horizontal) {
            HStack(spacing: 2) {
                ForEach(items, id: \.tab) { item in
                    let on = item.tab == selected
                    Button { onSelect(item.tab) } label: {
                        HStack(spacing: 5) {
                            Text(item.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Tok.ink : item.enabled ? Tok.ink2 : Tok.ink3.opacity(0.6))
                            if let count = item.count { Text("\(count)").font(Tok.Font.small).monospacedDigit().foregroundStyle(Tok.ink3) }
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(on ? Tok.line : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                    .help(item.enabled ? "" : "Nothing here yet")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.line))
            .fixedSize()
        }
        .frame(height: 34)
    }
}
