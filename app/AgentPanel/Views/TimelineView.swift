import SwiftUI

extension RoundTimeline {
    /// Reads the records of the selected project and builds the round (the agents' costs come from their session files).
    @MainActor static func load(model: PanelModel, round: PlanRound) -> RoundTimelineData {
        let cards = model.cards.compactMap { if case .card(let c) = $0 { c } else { nil } }
        let events = model.actionLogEvents()
        let decisions = model.autopilot.allDecisions()
        // Switching back to the Timeline builds the same round again: the agents' costs read session files of up to a megabyte each (N131).
        let key = CacheKey(project: model.selectedProjectID ?? "", round: round, events: events.count, lastEvent: events.last?.time, decisions: decisions.count,
                           lastDecision: decisions.last?.id, statuses: cards.filter { round.cards.contains($0.id) }.map { "\($0.id)=\($0.status)" })
        if let hit = cache, hit.key == key, Date().timeIntervalSince(hit.at) < cacheSeconds { return hit.data }
        var costs: [String: Double] = [:]
        if let project = model.selectedProject {
            let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            for c in cards where round.cards.contains(c.id) {
                guard let branch = c.branch else { continue }
                let start = events.filter { $0.concerns(project: project.id) && $0.text.hasPrefix("start \(c.id) agent=") }.map(\.time).min()
                costs[c.id] = CostReader.taskCost(projectsRoot: projects, worktree: project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).path, since: start)?.dollars
            }
        }
        let data = build(round: round, project: model.selectedProjectID ?? "", cards: cards, events: events, decisions: decisions, agentCosts: costs)
        cache = (key, Date(), data)
        return data
    }

    struct CacheKey: Equatable {
        let project: String; let round: PlanRound; let events: Int; let lastEvent: Date?; let decisions: Int; let lastDecision: String?; let statuses: [String]
    }
    private static let cacheSeconds: TimeInterval = 20
    @MainActor private static var cache: (key: CacheKey, at: Date, data: RoundTimelineData)?
}

/// The Timeline screen (in the rail): the selected project's rounds, opening on the current one. The links open the card on Tasks.
struct TimelineScreen: View {
    @Bindable var model: PanelModel
    var onOpen: (String) -> Void = { _ in }
    @State private var plan: PlanLoad

    /// What the screen shows for a plan: its rounds and the one to open on, or why there are none.
    enum Content: Equatable {
        case rounds([PlanRound], initial: String?)
        case empty(String)

        init(plan: PlanLoad, cards: [TaskCard]) {
            switch plan {
            case .plan(let file) where !file.rounds.isEmpty: self = .rounds(file.rounds, initial: currentRound(in: file, cards: cards)?.name)
            case .broken(let reason): self = .empty("plan.json could not be read (\(reason)). The PM should fix it; the format is in the README.")
            default: self = .empty("No rounds yet. The PM writes them to plan.json in the project's data folder.")
            }
        }
    }

    init(model: PanelModel, onOpen: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onOpen = onOpen
        // Read here, not in a task, so the first frame (and a snapshot) already shows the round.
        _plan = State(initialValue: model.selectedProject.map { PlanReader.load(dataDir: $0.dataURL) } ?? .missing)
    }

    private var dataURL: URL? { model.selectedProject?.dataURL }
    private var cards: [TaskCard] { model.cards.compactMap { if case .card(let c) = $0 { c } else { nil } } }

    var body: some View {
        Group {
            switch Content(plan: plan, cards: cards) {
            case .rounds(let rounds, let initial):
                // A new project or a changed plan starts again on its current round.
                TimelineView(rounds: rounds, initial: initial, build: { RoundTimeline.load(model: model, round: $0) }, onOpen: onOpen)
                    .id([dataURL?.path ?? ""] + rounds.map(\.name))
            case .empty(let text):
                VStack(alignment: .leading, spacing: Tok.Space.l) {
                    Text("Round timeline").font(Tok.Font.title).foregroundStyle(Tok.ink)
                    Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .pageMargin()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Tok.bg)
        .task(id: dataURL) { reload() }
        .task(id: cards.count) { reload() }
    }

    private func reload() {
        let load = dataURL.map { PlanReader.load(dataDir: $0) } ?? .missing
        if load != plan { plan = load }
    }
}

/// One round at a time: the summary, a lane per card on a shared time axis, the selected event and what slowed the round.
struct TimelineView: View {
    let rounds: [PlanRound]
    let build: (PlanRound) -> RoundTimelineData
    var onOpen: (String) -> Void = { _ in }
    /// Nil on the Timeline screen, which the rail opens: there is nothing to go back to.
    var onBack: (() -> Void)?
    @State private var index: Int
    /// The round's data, built when the first frame needs it (so a snapshot shows the round) and kept until the round changes. The
    /// initializer runs on every parent update; building there repeated the log, decision and cost reads each time (N131).
    @State private var memo = Memo()
    /// The item the user clicked; until then the likeliest question.
    @State private var picked: String?
    @State private var questionShown = false
    @State private var notesOpen = false

    private final class Memo {
        var index = -1
        var data: RoundTimelineData?
        var first: String?
    }

    static let labelWidth: CGFloat = 200

    init(rounds: [PlanRound], initial: String?, build: @escaping (PlanRound) -> RoundTimelineData, onOpen: @escaping (String) -> Void = { _ in }, onBack: (() -> Void)? = nil) {
        self.rounds = rounds
        self.build = build
        self.onOpen = onOpen
        self.onBack = onBack
        let i = rounds.firstIndex { $0.name == initial } ?? max(rounds.count - 1, 0)
        _index = State(initialValue: i)
    }

    private var data: RoundTimelineData? {
        guard rounds.indices.contains(index) else { return nil }
        if memo.index != index {
            let d = build(rounds[index])
            memo.index = index; memo.data = d; memo.first = Self.firstSelection(d)
        }
        return memo.data
    }

    private var selectedID: String? { _ = data; return picked ?? memo.first }

    /// The longest wait for the user is the likeliest question; show it first.
    private static func firstSelection(_ d: RoundTimelineData) -> String? {
        let items = d.lanes.flatMap(\.items)
        return items.filter { $0.kind == .waiting }.max { $0.seconds < $1.seconds }?.id ?? items.first?.id
    }

    var showsBack: Bool { onBack != nil }

    private var selected: TimelineItem? { data?.lanes.flatMap(\.items).first { $0.id == selectedID } }

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: Tok.Space.l) {
                header
                if let data {
                    summary(data.summary)
                    lanes(data)
                    notes(data.summary.notes)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Tok.Space.l) { detail.frame(minWidth: 520); slowed(data).frame(width: 360) }
                        VStack(spacing: Tok.Space.l) { detail; slowed(data) }
                    }
                } else if rounds.isEmpty {
                    Text("No rounds in plan.json yet.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                }
            }
            .pageMargin()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tok.bg)
        .onChange(of: index) { picked = nil; questionShown = false }
    }

    private var header: some View {
        HStack(spacing: Tok.Space.m) {
            if let onBack {
                Button(action: onBack) { Label("Dashboard", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work).help("Back to the Dashboard")
            }
            Text(rounds.indices.contains(index) ? "Round · \(rounds[index].name)" : "Round timeline")
                .font(Tok.Font.title).foregroundStyle(Tok.ink).lineLimit(1)
            if rounds.indices.contains(index), !rounds[index].status.isEmpty { Chip(text: rounds[index].status) }
            Spacer()
            Button("Previous round") { index -= 1 }.buttonStyle(PanelButtonStyle()).disabled(index <= 0)
            Button("Next round") { index += 1 }.buttonStyle(PanelButtonStyle()).disabled(index >= rounds.count - 1)
        }
    }

    /// Where the round's time went (N210): "so far" until every card is done. "≈" marks a number that rests on a guess; the notes say which.
    private func summary(_ s: RoundSummary) -> some View {
        func time(_ seconds: TimeInterval?, _ part: RoundSummary.Part) -> String {
            seconds.map { (s.estimated.contains(part) ? "≈ " : "") + Stats.durationText($0) } ?? "—"
        }
        return VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(spacing: Tok.Space.s) {
                TimelineLabel(text: s.finished ? "Round summary · finished" : "Round summary · so far")
                Text("≈ estimated, the rest exact from the action log").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            HStack(spacing: Tok.Space.m) {
                number("Round time", time(s.roundSeconds, .round))
                number("Agents working", time(s.workingSeconds, .working))
                number("Waiting for you", time(s.waitingSeconds, .waiting), color: s.waitingSeconds > 0 ? Tok.wait : Tok.ink)
                number("Packets · rebases", time(s.packetSeconds, .packets), sub: s.rebaseRounds > 0 ? "\(s.rebaseRounds) rebase\(s.rebaseRounds == 1 ? "" : "s")" : nil)
                number("Fix turns", "\(s.fixTurns)", sub: s.infrastructureTurns > 0 ? "\(s.infrastructureTurns) infrastructure" : nil)
                number("Cost", s.cost.map { "≈ " + String(format: "$%.2f", $0) } ?? "unknown")
            }
        }
    }

    /// How each ≈ number was estimated (N341): under the chart so the chart keeps its place; more than three kinds fold away.
    @ViewBuilder private func notes(_ lines: [String]) -> some View {
        let list = VStack(alignment: .leading, spacing: Tok.Space.xs) {
            ForEach(lines, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true) }
        }
        if lines.count > 3 {
            DisclosureGroup(isExpanded: $notesOpen) { list.padding(.top, Tok.Space.xs) } label: {
                Text("How ≈ is estimated").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        } else if !lines.isEmpty {
            list
        }
    }

    private func number(_ label: String, _ value: String, color: Color = Tok.ink, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.xs) {
            TimelineLabel(text: label)
            HStack(alignment: .firstTextBaseline, spacing: Tok.Space.xs) {
                Text(value).font(Tok.Font.title).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                if let sub { Text(sub).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1) }
            }
        }
        .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCard()
    }

    // MARK: lanes

    private func lanes(_ data: RoundTimelineData) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            legend.padding(.bottom, Tok.Space.xs)
            if let start = data.start, let end = data.windowEnd {
                let window = (start, max(end, start.addingTimeInterval(60)))
                axis(window)
                ForEach(data.lanes) { lane(lane: $0, window: window, drawnEnd: data.drawnEnd) }
            } else {
                Text("Nothing is recorded for this round yet.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
            }
            ForEach(data.gaps, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(Tok.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCard()
    }

    private var legend: some View {
        FlowLayout(spacing: Tok.Space.l, lineSpacing: Tok.Space.xs) {
            ForEach([TimelineItem.Kind.working, .packet, .waiting, .merged, .asked, .pmDecision], id: \.self) { kind in
                HStack(spacing: 6) {
                    if isBarKind(kind) { RoundedRectangle(cornerRadius: 2).fill(colour(kind)).frame(width: 14, height: 8) }
                    else { Circle().fill(colour(kind)).frame(width: 10, height: 10) }
                    Text(legendName(kind)).font(Tok.Font.small).foregroundStyle(Tok.ink2)
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Tok.ink3, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 8)
                Text("end unknown").font(Tok.Font.small).foregroundStyle(Tok.ink2)
            }
        }
    }

    private func axis(_ window: (Date, Date)) -> some View {
        HStack(spacing: Tok.Space.m) {
            Color.clear.frame(width: Self.labelWidth, height: 14)
            GeometryReader { geo in
                ForEach(RoundTimeline.ticks(from: window.0, to: window.1), id: \.self) { t in
                    Text(RoundTimeline.clock(t)).font(Tok.Font.mono).foregroundStyle(Tok.ink3).fixedSize()
                        .position(x: x(t, window, geo.size.width), y: 7)
                }
            }
            .frame(height: 14)
        }
    }

    private func lane(lane: TimelineLane, window: (Date, Date), drawnEnd: @escaping (TimelineItem) -> Date) -> some View {
        let isSelected = lane.items.contains { $0.id == selectedID }
        return HStack(spacing: Tok.Space.m) {
            HStack(spacing: Tok.Space.s) {
                if lane.id == "PM" {
                    Text("PM").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                    Text("decisions").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                } else {
                    Text(lane.id).font(Tok.Font.mono).foregroundStyle(Tok.ink2)
                    Text(lane.title).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1)
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(lane.items.filter(\.isBar)) { item in
                        let from = x(item.start, window, w)
                        let to = x(drawnEnd(item), window, w)
                        bar(item, width: max(to - from, 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(item.id == selectedID ? Tok.ink : .clear, lineWidth: 1.5))
                            .frame(width: max(to - from, 4), height: 16)
                            .offset(x: from, y: 6)
                            .onTapGesture { select(item) }
                            .help(item.title)
                    }
                    ForEach(lane.items.filter { !$0.isBar }) { item in
                        Circle().fill(colour(item.kind))
                            .overlay(Circle().stroke(item.id == selectedID ? Tok.ink : Tok.bg, lineWidth: 2))
                            .frame(width: 14, height: 14)
                            .offset(x: x(item.start, window, w) - 7, y: 7)
                            .onTapGesture { select(item) }
                            .help(item.title)
                    }
                }
            }
            .frame(height: 28)
            .background(Tok.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Tok.work : .clear))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lane.id == "PM" ? "PM decisions" : "\(lane.id) \(lane.title)")
    }

    /// Length of the fading, dashed tail that marks a bar whose end is not known (guessed or never recorded).
    static let unknownTail: CGFloat = 24

    /// A bar: solid for a recorded end, solid with a live edge while still running, else fading into a dashed tail (N355).
    @ViewBuilder private func bar(_ item: TimelineItem, width: CGFloat) -> some View {
        let c = colour(item.kind)
        switch item.tail {
        case .recorded:
            RoundedRectangle(cornerRadius: 4).fill(c)
        case .live:
            RoundedRectangle(cornerRadius: 4).fill(c)
                .overlay(alignment: .trailing) { Rectangle().fill(Tok.ink).frame(width: 2).padding(.vertical, 1) }
        case .guessed, .unknown:
            let tail = min(Self.unknownTail, width * (item.tail == .unknown ? 1 : 0.6))
            let solid = width - tail
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(stops: [.init(color: c, location: 0), .init(color: c, location: solid / max(width, 1)),
                                             .init(color: c.opacity(0.1), location: 1)], startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(c, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: tail)
                }
        }
    }

    private func select(_ item: TimelineItem) { picked = item.id; questionShown = false }

    private func x(_ t: Date, _ window: (Date, Date), _ width: CGFloat) -> CGFloat {
        let span = window.1.timeIntervalSince(window.0)
        return CGFloat(t.timeIntervalSince(window.0) / span) * width
    }

    // MARK: selected and slowed

    private var detail: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            if let item = selected {
                TimelineLabel(text: "Selected · \(item.title)")
                Text(when(item)).font(Tok.Font.heading).foregroundStyle(Tok.ink)
                Text(item.what).font(Tok.Font.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                if !item.why.isEmpty { Text(item.why).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
                if questionShown, let q = item.links.compactMap({ if case .question(let q) = $0 { q } else { nil } }).first {
                    Text(q).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled)
                        .padding(Tok.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: Tok.Space.s) {
                    ForEach(item.links, id: \.self) { link in
                        switch link {
                        case .card(let id):
                            Button("Open card") { onOpen(id) }.buttonStyle(PanelButtonStyle()).help("Open \(id) on the Tasks screen")
                        case .question:
                            Button(questionShown ? "Hide the question" : "Show the question") { questionShown.toggle() }.buttonStyle(PanelButtonStyle())
                        case .packet(let id):
                            Button("Show packet") { onOpen(id) }.buttonStyle(PanelButtonStyle()).help("Open \(id); the packet is in its Review packet tab")
                        }
                    }
                }
            } else {
                TimelineLabel(text: "Selected")
                Text("Select a bar or a dot to see what happened.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
            }
        }
        .padding(Tok.Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .timelineCard()
    }

    private func when(_ item: TimelineItem) -> String {
        guard item.isBar else { return RoundTimeline.clock(item.start) }
        if item.tail == .live { return "\(RoundTimeline.clock(item.start)) – now · still working" }
        guard let end = item.end else { return "\(RoundTimeline.clock(item.start)) – end not recorded" }
        let approx = item.tail == .guessed ? "≈ " : ""
        return "\(RoundTimeline.clock(item.start)) – \(approx)\(RoundTimeline.clock(end)) · \(approx)\(Stats.durationText(item.seconds))"
    }

    private func slowed(_ data: RoundTimelineData) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            TimelineLabel(text: "What slowed this round")
            if data.delays.isEmpty {
                Text("No delay is recorded for this round.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
            }
            ForEach(Array(data.delays.enumerated()), id: \.offset) { i, d in
                HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s) {
                    Text("\(i + 1).").font(Tok.Font.mono).foregroundStyle(Tok.ink3)
                    Text(d.text).font(Tok.Font.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Tok.Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .timelineCard()
    }

    // MARK: colours

    private func isBarKind(_ kind: TimelineItem.Kind) -> Bool { kind == .working || kind == .packet || kind == .waiting }

    private func colour(_ kind: TimelineItem.Kind) -> Color {
        switch kind {
        case .working: Tok.work
        case .packet: Tok.ink3
        case .waiting: Tok.wait
        case .merged: Tok.go
        case .asked: Tok.ask
        case .pmDecision: Tok.ink2
        }
    }

    private func legendName(_ kind: TimelineItem.Kind) -> String {
        switch kind {
        case .working: "Agent working"
        case .packet: "Review packet"
        case .waiting: "Waiting for you"
        case .merged: "Merged"
        case .asked: "Asked you"
        case .pmDecision: "PM decided"
        }
    }
}

private struct TimelineLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).font(Tok.Font.small.weight(.semibold)).kerning(0.6).foregroundStyle(Tok.ink3).lineLimit(1)
    }
}

private extension View {
    func timelineCard() -> some View {
        background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}
