import SwiftUI

/// The Plan screen (the book in the rail), design plan-v2 A (N223): Needs you on top when something waits, then Now, Next and History,
/// with the goal and the PM's project summary in a column on the right (under the main column when the window is narrow).
struct PlanView: View {
    @Bindable var model: PanelModel
    var onOpen: (String) -> Void = { _ in }
    /// Opens the PM's chat (on the Dashboard) after Answer put the question in its message box.
    var onOpenChat: () -> Void = {}
    @State private var goal = ""
    @State private var saved = ""
    @State private var loaded: String?
    @State private var plan: PlanLoad
    @State private var times: PlanTimes
    @State private var error: String?
    @State private var asked = false
    @State private var summary: ProjectSummary?
    @State private var summaryAll = false
    @State private var historyAll = false
    @Environment(\.snapshotMode) private var snapshot

    /// Below this width the right column goes under the main one.
    static let wideWidth: CGFloat = 900
    static let sideWidth: CGFloat = 320

    /// `summary`, `plan` and `times` are what to show before the first read (snapshots, which never run the reads).
    init(model: PanelModel, onOpen: @escaping (String) -> Void = { _ in }, onOpenChat: @escaping () -> Void = {}, summary: ProjectSummary? = nil,
         plan: PlanLoad = .missing, times: PlanTimes = PlanTimes()) {
        _model = Bindable(model)
        self.onOpen = onOpen
        self.onOpenChat = onOpenChat
        _summary = State(initialValue: summary)
        _plan = State(initialValue: plan)
        _times = State(initialValue: times)
    }

    private var dataURL: URL? { model.selectedProject?.dataURL }
    private var cards: [TaskCard] { model.selectedTaskCards }
    private var pmPane: String? { model.selectedProjectID.flatMap { model.pmPane(forProject: $0) } }

    var body: some View {
        GeometryReader { geo in
            Scroller {
                content(wide: geo.size.width >= Self.wideWidth)
                    .pageMargin()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Tok.bg)
        .task(id: dataURL) { reload() }
        .task(id: dataURL) { await followSummary() }
        .task(id: dataURL) { await followPlan() }
        .task(id: cards.count) { reload(goalToo: false) }
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.xl) {
            header
            switch plan {
            case .plan(let file):
                let groups = PlanGroups.group(file, cards: cards, waiting: RoundModel.waitingRound(in: file, cards: cards))
                if groups.needsYouCount > 0 { needsYou(groups) }
                columns(wide: wide) { PlanBoard(groups: groups, cards: cards, times: times, historyAll: $historyAll, onOpen: onOpen) }
            case .broken(let reason):
                columns(wide: wide) {
                    Text("plan.json could not be read (\(reason)). The PM should fix it; the format is in the README.")
                        .font(Tok.Font.body).foregroundStyle(Tok.ink3).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .missing:
                emptyState
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tok.Space.m) {
            Text("Plan").font(Tok.Font.title).foregroundStyle(Tok.ink)
            Text("· where the project is and what comes next").font(.system(size: 14)).foregroundStyle(Tok.ink3).lineLimit(1)
            Spacer(minLength: Tok.Space.m)
            if plan != .missing {
                let state = model.planRoundState
                Button("Ask the PM to plan a round") { model.round.begin() }
                    .buttonStyle(PanelButtonStyle()).disabled(!state.enabled).help(state.help)
                    .tutorialAnchor(.planAskRound)
            }
        }
        .tutorialAnchor(.planHeader)
    }

    /// The main column and the right one side by side, or stacked when narrow.
    @ViewBuilder private func columns<Main: View>(wide: Bool, @ViewBuilder main: () -> Main) -> some View {
        if wide {
            HStack(alignment: .top, spacing: Tok.Space.xl) {
                main().frame(maxWidth: .infinity, alignment: .topLeading)
                side.frame(width: Self.sideWidth)
            }
        } else {
            VStack(alignment: .leading, spacing: Tok.Space.xl) { main(); side }
        }
    }

    /// A snapshot keeps what it was given: the renderer runs the first part of `.task`, and the action log there is not the fixture's.
    private func reload(goalToo: Bool = true) {
        if snapshot { return }
        guard let url = dataURL else { plan = .missing; return }
        apply(PlanReader.load(dataDir: url))
        if goalToo || loaded != url.path { saved = GoalStore.read(dataDir: url); goal = saved; loaded = url.path }
    }

    private func apply(_ loaded: PlanLoad) {
        plan = loaded
        if case .plan(let file) = loaded, let id = model.selectedProjectID {
            times = PlanTimes(events: model.actionLogEvents().filter { $0.concerns(project: id) }, ids: Set(file.rounds.flatMap(\.cards)))
        }
    }

    /// plan.json again, read off the main thread, when its date differs from `since`; nil when it did not change.
    nonisolated static func planIfChanged(dataDir: URL, since: Date?) -> (plan: PlanLoad, date: Date?)? {
        let url = dataDir.appendingPathComponent(PlanReader.fileName)
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return date == since ? nil : (PlanReader.load(dataDir: dataDir), date)
    }

    /// Follows plan.json every 2 s (the PM rewrites it without adding cards).
    private func followPlan() async {
        if snapshot { return }
        guard let url = dataURL else { return }
        var last: Date? = nil
        while !Task.isCancelled {
            let since = last
            let changed = await Task.detached(priority: .utility) { Self.planIfChanged(dataDir: url, since: since) }.value
            if Task.isCancelled { return }
            if let changed { last = changed.date; if changed.plan != plan { apply(changed.plan) } }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Reads summary.md off the main thread, then again whenever its date changes (the PM rewrites it).
    private func followSummary() async {
        if snapshot { return }
        guard let url = dataURL else { summary = nil; return }
        var last: ProjectSummary? = nil
        while !Task.isCancelled {
            let previous = last
            last = await Task.detached(priority: .utility) { SummaryReader.reload(dataDir: url, previous: previous) }.value
            if Task.isCancelled { return }
            if last != summary { summary = last }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: Needs you

    private func needsYou(_ groups: PlanGroups) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            HStack(spacing: Tok.Space.s + 2) {
                Circle().fill(Tok.ask).frame(width: 8, height: 8)
                Text("Needs you · \(groups.needsYouCount)").font(Tok.Font.heading).foregroundStyle(Tok.askText)
            }
            if let round = groups.waiting {
                PlanRoundApproval(round: round, blocker: model.approvePlanBlocker(round), message: model.round.approveMessage,
                                  onApprove: { Task { await model.approvePlan(round) } }, onEdit: { model.editPlan(round) },
                                  onNotNow: model.round.waitingForYouPlanRound == round ? { model.round.notNow(round) } : nil)
            }
            ForEach(groups.questions, id: \.self) { question($0) }
        }
        .padding(.horizontal, 18).padding(.vertical, Tok.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.ask.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.ask.opacity(0.45)))
        .accessibilityElement(children: .contain).accessibilityLabel("Needs you")
        .tutorialAnchor(.planNeedsYou)
    }

    /// A plan.json question: Answer puts it, quoted, in the PM's message box (never sent) and opens the PM's chat.
    private func question(_ text: String) -> some View {
        HStack(spacing: Tok.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 14)).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                Text("Question from the PM").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Answer") { if model.fillPMDraft(Self.answerDraft(text)) { onOpenChat() } }
                .buttonStyle(PanelButtonStyle()).disabled(pmPane == nil)
                .help(pmPane == nil ? "No PM runs for this project; start it to answer." : "Puts the question in the PM's message box and opens the chat; you write the answer and send it")
        }
        .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s + 2)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
    }

    static func answerDraft(_ question: String) -> String { "About your question in plan.json, \"\(question)\": " }

    // MARK: Right column

    private var side: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            goalBox
            summaryBox
        }
    }

    private var goalBox: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            PlanSectionLabel(text: "Goal")
            goalEditor(background: Tok.bg)
            HStack(alignment: .firstTextBaseline) {
                goalStatus.frame(maxWidth: .infinity, alignment: .leading)
                Button("Save goal") { save() }.buttonStyle(PanelButtonStyle())
                    .disabled(dataURL == nil || goal.trimmingCharacters(in: .whitespacesAndNewlines) == saved)
            }
            .font(Tok.Font.small)
        }
        .planPanel(padding: Tok.Space.l)
    }

    private static let goalPrompt = "What is this project for? The PM plans against it."

    private func goalEditor(background: Color) -> some View {
        Group {
            // ImageRenderer cannot draw a vertical TextField: a snapshot shows the text as it would read.
            if snapshot { Text(goal.isEmpty ? Self.goalPrompt : goal).foregroundStyle(goal.isEmpty ? Tok.ink3 : Tok.ink).lineLimit(4...10) }
            else { TextField(Self.goalPrompt, text: $goal, axis: .vertical).textFieldStyle(.plain).lineLimit(4...10).foregroundStyle(Tok.ink) }
        }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .topLeading).padding(Tok.Space.s + 2)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
            .accessibilityLabel("Project goal")
    }

    @ViewBuilder private var goalStatus: some View {
        if let error { Text(error).foregroundStyle(Tok.stop) }
        else if goal.trimmingCharacters(in: .whitespacesAndNewlines) != saved { Text("Not saved yet.").foregroundStyle(Tok.ink3) }
        else { Text("The PM plans every round from this.").foregroundStyle(Tok.ink3) }
    }

    private var summaryBox: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            HStack(alignment: .firstTextBaseline) {
                PlanSectionLabel(text: "Project summary")
                Spacer(minLength: Tok.Space.s)
                if let date = summary?.modified { Text("by the PM · \(PlanAge.text(date))").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            }
            if let summary {
                let short = PlanAge.firstLines(summary.text)
                MarkdownText(text: summaryAll ? summary.text : short)
                if short != summary.text {
                    Button(summaryAll ? "Show less" : "Read all") { withAnimation(.easeOut(duration: 0.15)) { summaryAll.toggle() } }
                        .buttonStyle(.plain).font(Tok.Font.bodyStrong).foregroundStyle(Tok.work)
                        .help(summaryAll ? "Show the first lines only." : "Show the whole summary the PM wrote to summary.md.")
                }
            } else {
                Text(SummaryReader.emptyText).font(Tok.Font.body).foregroundStyle(Tok.ink3)
            }
        }
        .planPanel(padding: Tok.Space.l)
    }

    private func save() {
        guard let url = dataURL, let project = model.selectedProject else { return }
        do {
            try GoalStore.write(goal, dataDir: url)
            error = nil
            saved = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pane = model.pmPane(forProject: project.id) { let text = GoalStore.pmMessage(goal: saved); Task { await model.tellPM(pane: pane, text) } }
        } catch { self.error = "Could not save: \(error.localizedDescription)" }
    }

    // MARK: No plan yet

    private var emptyState: some View {
        let blank = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: Tok.Space.l) {
            Image(systemName: "book.closed").font(.system(size: 40, weight: .light)).foregroundStyle(Tok.ink3)
            Text("No plan yet").font(.system(size: 20, weight: .semibold)).foregroundStyle(Tok.ink)
            Text("Write what you want this project to reach. The PM turns it into rounds of task cards; each round waits for your approval before it starts.")
                .font(.system(size: 14)).foregroundStyle(Tok.ink2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                PlanSectionLabel(text: "Goal")
                goalEditor(background: Tok.pane)
            }
            HStack(spacing: Tok.Space.s + 2) {
                Button("Save and ask the PM to plan") { saveAndAsk() }
                    .buttonStyle(HeaderButtonStyle(kind: .approve)).disabled(dataURL == nil || blank || pmPane == nil)
                    .help(pmPane == nil ? "Start the PM first." : "Saves the goal in goal.md and asks the PM to write plan.json")
                if model.pmStatus == .missing {
                    Button("Start the PM") { Task { await model.startPM() } }.buttonStyle(HeaderButtonStyle())
                        .help("Starts the project's PM in the project folder")
                }
            }
            Group {
                if let error { Text(error).foregroundStyle(Tok.stop) }
                else if asked { Text("Asked the PM. The plan shows here once it writes plan.json.").foregroundStyle(Tok.ink3) }
                else if pmPane == nil { Text("The PM is not running. Start it first, then ask it to plan.").foregroundStyle(Tok.ink3) }
            }
            .font(Tok.Font.small)
        }
        .frame(maxWidth: 640)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    private func saveAndAsk() {
        guard let url = dataURL, let pane = pmPane else { return }
        do {
            try GoalStore.write(goal, dataDir: url)
            error = nil
            saved = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            asked = true
            let text = GoalStore.planRequest(goal: saved)
            Task { await model.tellPM(pane: pane, text) }
        } catch { self.error = "Could not save: \(error.localizedDescription)" }
    }
}

/// A round of the PM's plan that waits for the user: Approve plan & start round (opens the Round sheet with its cards ticked), Edit, Not now.
/// The Plan screen and the Dashboard's "Waiting for you" both show it.
struct PlanRoundApproval: View {
    let round: PlanRound
    /// Why Approve is disabled; nil when it can be clicked.
    let blocker: String?
    /// What the last Approve could not do (nothing could start).
    let message: String?
    let onApprove: () -> Void
    let onEdit: () -> Void
    /// Nil hides the button (the round was already put off).
    var onNotNow: (() -> Void)?
    /// Waiting for you colours the chip and Approve by the item's kind (N182); the Plan screen keeps the orange chip.
    var tint: WaitingTint? = nil

    static func title(_ round: PlanRound) -> String { "Round \(round.name) · " + (round.cards.isEmpty ? "no cards" : round.cards.joined(separator: ", ")) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            if let tint { WaitingChip(text: "Plan waiting", tint: tint) } else { Chip(text: "Plan waiting", style: .ask) }
            Text(Self.title(round)).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(2)
            if !round.reason.isEmpty { Text(round.reason).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
            if let blocker { Text(blocker).font(Tok.Font.small).foregroundStyle(Tok.stop).fixedSize(horizontal: false, vertical: true) }
            else if let message { Text(message).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
            FlowLayout(spacing: Tok.Space.s, lineSpacing: Tok.Space.s) {
                Button("Approve plan & start round", action: onApprove).buttonStyle(PanelButtonStyle(tint: tint?.color)).disabled(blocker != nil)
                    .tutorialAnchor(.planApprove)
                    .help(blocker ?? "Opens the Round sheet with this round's cards ticked; nothing starts until you click Start round there")
                Button("Edit", action: onEdit).buttonStyle(PanelButtonStyle())
                    .help("Puts a request to change this round in the PM's message box; you send it")
                if let onNotNow {
                    Button("Not now", action: onNotNow).buttonStyle(PanelButtonStyle())
                        .help("Hide this from Waiting for you until another round waits; the Plan screen keeps it")
                }
            }
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        .accessibilityElement(children: .contain)
    }
}
