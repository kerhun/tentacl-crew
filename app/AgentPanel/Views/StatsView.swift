import SwiftUI

/// The Stats screen (the chart in the rail).
struct StatsView: View {
    @Bindable var stats: StatsModel
    /// Opens a card on Tasks.
    var onOpen: (String) -> Void = { _ in }

    var body: some View {
        StatsContent(stats: stats.stats, usage: stats.usage, codexUsage: stats.codexUsage, range: stats.range, now: Date(), focusCodex: stats.focusCodex,
                     onRange: { stats.setRange($0) }, onOpen: onOpen, onFocused: { stats.focusCodex = false })
            .background(Tok.bg)
            .onAppear { stats.refreshOnAppear() }
    }
}

/// The combined design (N137): range, four headline tiles, merged per day beside the plan limits, start to merge per card beside the cost per
/// day, and the range's cards in a table. Draws only what `Stats` holds; nothing is read here.
struct StatsContent: View {
    let stats: Stats
    let usage: PlanUsage?
    /// The Codex plan windows (`StatsModel.codexUsage`); nil hides the Codex section.
    var codexUsage: PlanUsage? = nil
    let range: StatsRange
    let now: Date
    var calendar: Calendar = .current
    /// Scroll to the Codex section (the top bar's Codex ring was clicked); `onFocused` clears it.
    var focusCodex = false
    let onRange: (StatsRange) -> Void
    let onOpen: (String) -> Void
    var onFocused: () -> Void = {}
    @State private var showAllFlows = false
    @State private var showAllRows = false

    static let codexSectionID = "stats.codex"

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: focusCodex, initial: true) {
                    guard focusCodex else { return }
                    // After the first layout: the screen may have just been opened by the click.
                    if codexUsage != nil { DispatchQueue.main.async { withAnimation { proxy.scrollTo(Self.codexSectionID, anchor: .top) } } }
                    onFocused()
                }
        }
    }

    private var content: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("Stats").font(Tok.Font.title).foregroundStyle(Tok.ink)
                    Spacer()
                    StatsRangePicker(selected: range, onSelect: onRange)
                }
                tiles
                RatioRow(ratios: [1.55, 1]) {
                    StatsBox("Cards merged per day", note: "\(stats.mergedCount) in \(stats.days) days") { MergedBarChart(days: stats.merged) }
                    limits
                }
                if let codexUsage { codexLimits(codexUsage).id(Self.codexSectionID) }
                RatioRow(ratios: [1.55, 1]) {
                    flowsBox
                    StatsBox("Estimated cost per day", note: "\(String(format: "$%.2f", stats.totalCost)) in \(stats.days) days") { CostLineChart(days: stats.costPerDay) }
                }
                roundsBox
                table
            }
            .pageMargin()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: tiles

    private var tiles: some View {
        let s = stats
        let leftOut = s.flowsLeftOut > 0 ? " · \(s.flowsLeftOut) left out" : ""
        return RatioRow(ratios: [1, 1, 1, 1]) {
            tile("Cards merged", "\(s.mergedCount)", Stats.changeText(now: s.mergedCount, before: s.previousMergedCount, days: s.days, logCoversBefore: s.logCoversBefore))
            tile("Median start → merge", s.medianTotal.map(Stats.shortDuration) ?? "—",
                 s.medianTotal == nil ? "no merged card with a start, a packet and a merge in the log"
                     : "agent \(Stats.shortDuration(s.medianAgent ?? 0)) · waiting for you \(Stats.shortDuration(s.medianWaiting ?? 0))" + leftOut)
            tile("Estimated cost", String(format: "$%.2f", s.totalCost),
                 (s.costPerMerged.map { String(format: "$%.2f per merged card", $0) } ?? "no cost known") + (s.unknownCostTasks > 0 ? " · \(s.unknownCostTasks) unknown" : "") + (s.tokensOnlyTasks > 0 ? " · \(s.tokensOnlyTasks) Codex, tokens only" : ""))
            tile("Packets passed first time", s.firstPassPercent.map { "\($0)%" } ?? "—",
                 s.packetCards == 0 ? "no review packet in this range" : "\(s.neededFix) of \(s.packetCards) needed a fix")
        }
    }

    private func tile(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Tok.ink2)
            Text(value).font(.system(size: 30, weight: .bold)).monospacedDigit().foregroundStyle(Tok.ink)
            Text(sub).font(.system(size: 12)).foregroundStyle(Tok.ink3).lineLimit(1)
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value), \(sub)")
    }

    // MARK: limits

    private var limits: some View {
        // Named once the Codex section shows, as the top bar names its rings only when both plans do.
        StatsBox(codexUsage == nil ? "Plan limits" : "Claude plan limits", note: "") {
            if let u = usage, u.fiveHour != nil || u.week != nil {
                VStack(alignment: .leading, spacing: 14) {
                    if let w = u.fiveHour { LimitRing(name: "5-hour session", window: w, length: PlanUsage.fiveHourLength, color: StatsColor.blue, now: now, calendar: calendar) }
                    if let w = u.week { LimitRing(name: "Week", window: w, length: PlanUsage.weekLength, color: StatsColor.orange, now: now, calendar: calendar) }
                    Text("The light arc is the forecast up to the reset, at today’s pace.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
            } else {
                Text("No data yet. It appears after an agent's first reply in a session (Claude Pro or Max).").font(Tok.Font.body).foregroundStyle(Tok.ink3)
            }
        }
    }

    /// The Codex plan beside Claude's (N217): the same rings, side by side, from the Codex session files.
    private func codexLimits(_ u: PlanUsage) -> some View {
        StatsBox("Codex plan limits", note: u.seenAt.map { "last Codex session \(Stats.durationText(max(now.timeIntervalSince($0), 0))) ago" } ?? "") {
            VStack(alignment: .leading, spacing: 14) {
                RatioRow(ratios: [1, 1]) {
                    if let w = u.fiveHour { LimitRing(name: "5-hour session", window: w, length: PlanUsage.fiveHourLength, color: StatsColor.blue, now: now, calendar: calendar) }
                    else { Text("No 5-hour window reported.").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
                    if let w = u.week { LimitRing(name: "Week", window: w, length: PlanUsage.weekLength, color: StatsColor.orange, now: now, calendar: calendar) }
                    else { Text("No week window reported.").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
                }
                Text("From the newest Codex session file. Codex tasks count tokens, not dollars.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex plan limits")
    }

    // MARK: start to merge

    private var flowsBox: some View {
        let shown = showAllFlows ? stats.flows : Array(stats.flows.prefix(10))
        let longest = shown.map(\.total).max() ?? 0
        return StatsBox(title: "Start to merge, per card", trailing: { StatsLegend(items: [("Agent working", StatsColor.blue), ("Waiting for you", StatsColor.orange)]) }) {
            if shown.isEmpty {
                Text("No merged card in this range has a start, a review packet and a merge in the action log.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown, id: \.cardID) { f in FlowRow(flow: f, longest: longest, calendar: calendar) { onOpen(f.cardID) } }
                }
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Start to merge, per card")
                HStack(spacing: 12) {
                    Color.clear.frame(width: 52, height: 1)
                    HStack {
                        ForEach(0..<4) { i in
                            if i > 0 { Spacer() }
                            Text(i == 0 ? "0" : Stats.shortDuration(longest * Double(i) / 3)).font(Tok.Font.small).monospacedDigit().foregroundStyle(Tok.ink3)
                        }
                    }
                    Color.clear.frame(width: 64, height: 1)
                }
                .accessibilityHidden(true)
                if stats.flowsLeftOut > 0 {
                    Text("\(stats.flowsLeftOut) merged \(stats.flowsLeftOut == 1 ? "card is" : "cards are") left out: no start, review packet or merge in the action log.")
                        .font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
                if stats.flows.count > 10 {
                    Button(showAllFlows ? "Show the newest 10" : "Show all \(stats.flows.count)") { showAllFlows.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Tok.ink2)
                }
            }
        }
    }

    // MARK: rounds

    private static let roundColumns: [(String, CGFloat?)] = [("Round", nil), ("Cards", 54), ("Round time", 96), ("Agents", 84), ("Waiting for you", 116),
                                                              ("Packets · rebases", 128), ("Fix turns", 96), ("Cost", 80)]

    /// A row per round, newest first: where its time went (N210). "≈" marks a number that rests on a guess; the notes say which.
    private var roundsBox: some View {
        StatsBox("Rounds", note: "newest first · ≈ estimated, the rest exact from the action log") {
            VStack(alignment: .leading, spacing: 0) {
                roundRow(Self.roundColumns.map(\.0), header: true)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
                    .accessibilityHidden(true)
                if stats.rounds.isEmpty {
                    Text("No round of plan.json has anything recorded in this range.").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(.vertical, 8)
                }
                ForEach(stats.rounds, id: \.name) { r in
                    let s = r.summary
                    let cells = [r.name + (s.finished ? "" : " · running"), "\(r.cards.count)", Stats.roundText(s.roundSeconds, .round, in: s),
                                 Stats.roundText(s.workingSeconds, .working, in: s), Stats.roundText(s.waitingSeconds, .waiting, in: s),
                                 Stats.roundText(s.packetSeconds, .packets, in: s) + (s.rebaseRounds > 0 ? " · \(s.rebaseRounds)" : ""),
                                 Stats.fixTurnsText(s), Stats.costText(s.cost)]
                    roundRow(cells, header: false)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
                        .help(([r.cards.joined(separator: ", ")] + s.notes).joined(separator: "\n"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Round \(cells[0]), \(r.cards.count) cards: round time \(cells[2]), agents \(cells[3]), waiting for you \(cells[4]), packets and rebases \(cells[5]), fix turns \(cells[6]), cost \(cells[7])")
                }
                if !stats.rounds.isEmpty {
                    Text("Agents and packets are summed over the cards; waiting counts overlapping waits once. Fix turns leave out rebases (the number after the packet time); “infra” turns are broken test runs, not the agent’s code. Hover a row for its estimates.")
                        .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            }
        }
    }

    private func roundRow(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(zip(cells, Self.roundColumns).enumerated()), id: \.offset) { i, pair in
                let (text, column) = pair
                let last = i == cells.count - 1
                Text(text)
                    .font(header ? Tok.Font.small : last ? .system(size: 13).weight(.semibold) : .system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(header ? Tok.ink3 : i == 0 || last ? Tok.ink : Tok.ink2)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: column.1, alignment: last ? .trailing : .leading)
                    .frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
    }

    // MARK: table

    private static let columns: [(String, CGFloat?)] = [("Card", 70), ("Title", nil), ("Model", 120), ("Effort", 80), ("Tokens", 150), ("Agent · waiting", 120), ("Cost", 80)]

    private var table: some View {
        StatsBox("Cards in this range", note: (stats.toolSplitText.map { $0 + " · " } ?? "") + "sorted by cost · click a row to open the card") {
            VStack(alignment: .leading, spacing: 0) {
                row(Self.columns.map(\.0), font: Tok.Font.small, ink: Tok.ink3)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
                    .accessibilityHidden(true)
                if stats.rows.isEmpty {
                    Text("No card merged in this range.").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(.vertical, 8)
                }
                // The table was ~65% of the screen's switch time with 40 rows (N321); it shows the 10 costliest like the flows box.
                ForEach(showAllRows ? stats.rows : Array(stats.rows.prefix(10)), id: \.cardID) { r in
                    let flow = r.flow.map { "\(Stats.shortDuration($0.agent)) · \(Stats.shortDuration($0.waiting))" } ?? "—"
                    let cost = r.tokensOnly ? "tokens only" : Stats.costText(r.dollars)
                    Button { onOpen(r.cardID) } label: {
                        row([r.cardID, r.title, r.facts.model, r.facts.effort, r.facts.tokens, flow, cost], font: .system(size: 13), ink: Tok.ink)
                            .padding(.vertical, 7)
                            .overlay(alignment: .bottom) { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(r.facts.modelHelp ?? "")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(r.cardID), \(r.title): \(r.facts.model), effort \(r.facts.effort), tokens \(r.facts.tokens), agent and waiting \(flow), cost \(cost)")
                    .accessibilityHint("Opens the card on Tasks")
                }
                if stats.rows.count > 10 {
                    Button(showAllRows ? "Show the costliest 10" : "Show all \(stats.rows.count)") { showAllRows.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Tok.ink2).padding(.top, 8)
                }
            }
        }
    }

    /// One line of the table: the card id in mono, the title flexible, the cost right-aligned and strong, the rest secondary.
    private func row(_ cells: [String], font: Font, ink: Color) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(zip(cells, Self.columns).enumerated()), id: \.offset) { i, pair in
                let (text, column) = pair
                let header = ink == Tok.ink3
                Text(text)
                    .font(i == 0 && !header ? .system(size: 13, design: .monospaced) : i == 6 && !header ? font.weight(.semibold) : font)
                    .foregroundStyle(header ? Tok.ink3 : i == 1 || i == 2 || i == 6 ? Tok.ink : Tok.ink2)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: column.1, alignment: i == 6 ? .trailing : .leading)
                    .frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
    }
}
