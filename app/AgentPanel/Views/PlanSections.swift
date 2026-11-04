import SwiftUI

/// The Plan screen's main column (N223): Now, Next (with the later rounds) and History.
struct PlanBoard: View {
    let groups: PlanGroups
    let cards: [TaskCard]
    let times: PlanTimes
    @Binding var historyAll: Bool
    let onOpen: (String) -> Void

    private var byID: [String: TaskCard] { Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        let byID = byID
        // Lazy: a plan with ten running rounds of a dozen cards lays out the rows in view, not all of them, on every switch to this screen.
        LazyVStack(alignment: .leading, spacing: Tok.Space.xl) {
            if groups.now.isEmpty {
                HStack(spacing: Tok.Space.s + 2) {
                    PlanSectionLabel(text: "Now")
                    Text("Nothing running").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .planPanel(padding: 20)
            } else {
                ForEach(groups.now) { now($0, byID: byID) }
            }
            if groups.next != nil || !groups.later.isEmpty { next(byID: byID) }
            if !groups.history.isEmpty { history }
        }
    }

    // MARK: Now

    private func now(_ round: PlanRound, byID: [String: TaskCard]) -> some View {
        let p = PlanProgress(round: round, cards: byID)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tok.Space.s + 2) {
                PlanSectionLabel(text: "Now")
                PlanChip(text: "Running", color: Tok.work, dot: true)
                Spacer(minLength: Tok.Space.s)
                if let start = times.started(round) { Text(PlanAge.started(start)).font(Tok.Font.body).foregroundStyle(Tok.ink2) }
            }
            Text(round.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(Tok.ink).padding(.top, 10).padding(.bottom, Tok.Space.xs)
            if !round.reason.isEmpty { Text(round.reason).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Tok.Space.m) {
                PlanProgressBar(progress: p)
                Text("\(p.merged) of \(p.total) merged").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).fixedSize()
            }
            .padding(.top, Tok.Space.l).padding(.bottom, Tok.Space.s + 6)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(round.cards, id: \.self) { id in cardRow(id, card: byID[id]) }
            }
        }
        .planPanel(padding: 20)
        .accessibilityElement(children: .contain).accessibilityLabel("Now: \(round.name)")
    }

    @ViewBuilder private func cardRow(_ id: String, card: TaskCard?) -> some View {
        let state = PlanCardState(card?.status)
        let row = HStack(spacing: Tok.Space.m) {
            Circle().fill(state.color).frame(width: 8, height: 8)
            Text(id).font(Tok.Font.mono).foregroundStyle(Tok.ink3).frame(width: 48, alignment: .leading)
            Text(card.map { Self.title($0) } ?? "(no such card)").font(.system(size: 14)).foregroundStyle(card == nil ? Tok.ink3 : Tok.ink).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            PlanChip(text: state.label, color: state.color)
        }
        .padding(.vertical, 10).padding(.horizontal, Tok.Space.xs)
        .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
        .contentShape(Rectangle())
        if card != nil {
            Button { onOpen(id) } label: { row }.buttonStyle(.plain).help("Open \(id) on the Tasks screen.")
                .accessibilityElement(children: .combine)
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    // MARK: Next

    private func next(byID: [String: TaskCard]) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            PlanSectionLabel(text: "Next")
            if let round = groups.next {
                VStack(alignment: .leading, spacing: Tok.Space.m) {
                    HStack(spacing: Tok.Space.s + 2) {
                        Text(round.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Tok.ink)
                        if round == groups.waiting { PlanChip(text: "Waiting for your approval", color: Tok.askText, fill: Tok.ask) }
                        else { PlanChip(text: round.status.isEmpty ? "Planned" : round.status.capitalized, color: Tok.ink2, fill: Tok.ink3) }
                        Spacer(minLength: Tok.Space.s)
                        Text(nextLine(round)).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(1)
                    }
                    if !round.reason.isEmpty { Text(round.reason).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
                    FlowLayout(spacing: Tok.Space.s, lineSpacing: Tok.Space.s) {
                        ForEach(round.cards, id: \.self) { id in cardChip(id, card: byID[id]) }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, Tok.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
            }
            if !groups.later.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Tok.Space.m, alignment: .top)], alignment: .leading, spacing: Tok.Space.m) {
                    ForEach(groups.later) { later($0) }
                }
            }
        }
    }

    private func nextLine(_ round: PlanRound) -> String {
        let count = round.cards.count == 1 ? "1 card" : "\(round.cards.count) cards"
        return groups.now.last.map { "\(count) · after \($0.name)" } ?? count
    }

    private func cardChip(_ id: String, card: TaskCard?) -> some View {
        Button { onOpen(id) } label: {
            HStack(spacing: 6) {
                Text(id).font(Tok.Font.mono).foregroundStyle(Tok.ink3)
                Text(card.map { Self.title($0) } ?? "no such card").font(Tok.Font.small.weight(.semibold)).foregroundStyle(card == nil ? Tok.ink3 : Tok.ink).lineLimit(1)
            }
            .padding(.horizontal, Tok.Space.s).frame(height: 26).frame(maxWidth: 280, alignment: .leading)
            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).disabled(card == nil).help(card == nil ? "\(id) is not a card of this project." : "Open \(id) on the Tasks screen.")
    }

    private func later(_ round: PlanRound) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.xs) {
            HStack(spacing: Tok.Space.s) {
                Text(round.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tok.ink).lineLimit(1)
                PlanChip(text: round.cards.isEmpty ? "No cards yet" : (round.status.lowercased() == "later" ? "Later" : "Planned"), color: Tok.ink2, fill: Tok.ink3)
            }
            Text(laterLine(round)).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Tok.Space.l).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.list, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
    }

    private func laterLine(_ round: PlanRound) -> String {
        let cards: String = switch round.cards.count {
        case 0: "No cards yet"
        case 1: "1 card (\(round.cards[0]))"
        default: "\(round.cards.count) cards (\(round.cards.first!)–\(round.cards.last!))"
        }
        return round.reason.isEmpty ? cards : "\(cards) · \(round.reason)"
    }

    // MARK: History

    private var history: some View {
        let rounds = historyAll ? groups.history : Array(groups.history.prefix(PlanGroups.historyShown))
        return VStack(alignment: .leading, spacing: Tok.Space.m) {
            HStack(spacing: Tok.Space.s + 2) {
                PlanSectionLabel(text: "History")
                Text(PlanBoard.historyHeader(groups)).font(Tok.Font.body).foregroundStyle(Tok.ink3)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rounds) { round in
                    HStack(spacing: Tok.Space.m) {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Tok.go)
                        Text(round.name).font(.system(size: 14)).foregroundStyle(Tok.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.cardCount(round, cards: cards)).font(Tok.Font.body).foregroundStyle(Tok.ink2).frame(width: 70, alignment: .trailing)
                        Text(times.lastMerge(round).map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
                            .font(Tok.Font.body).foregroundStyle(Tok.ink3).frame(width: 56, alignment: .trailing)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
                    .accessibilityElement(children: .combine)
                }
                if groups.history.count > PlanGroups.historyShown {
                    Button(historyAll ? "Show fewer" : "Show all \(groups.history.count) rounds") { withAnimation(.easeOut(duration: 0.15)) { historyAll.toggle() } }
                        .buttonStyle(.plain).font(Tok.Font.bodyStrong).foregroundStyle(Tok.work).padding(.vertical, 10)
                }
            }
            .padding(.horizontal, Tok.Space.l).padding(.vertical, Tok.Space.xs)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
        }
    }

    /// The card's title without the "N214 · " the heading starts with (the id is shown beside it).
    static func title(_ card: TaskCard) -> String {
        for sep in [" · ", " - ", ": "] where card.title.hasPrefix(card.id + sep) { return String(card.title.dropFirst(card.id.count + sep.count)) }
        return card.title
    }

    static func historyHeader(_ groups: PlanGroups) -> String {
        "\(groups.history.count) \(groups.history.count == 1 ? "round" : "rounds") done · \(groups.historyCards) \(groups.historyCards == 1 ? "card" : "cards")"
    }

    /// "5 cards", cancelled ones left out.
    static func cardCount(_ round: PlanRound, cards: [TaskCard]) -> String {
        let n = PlanReader.progress(of: round, cards: cards).total
        return n == 1 ? "1 card" : "\(n) cards"
    }
}

/// A round's cards by state, for the Now bar: merged, fix requested, working (any other started card); cancelled ones left out.
struct PlanProgress: Equatable {
    var merged = 0, fix = 0, working = 0, total = 0

    init(round: PlanRound, cards: [String: TaskCard]) {
        for id in round.cards {
            let status = cards[id]?.status
            if status == .cancelled { continue }
            total += 1
            switch status {
            case .done: merged += 1
            case .needsFix: fix += 1
            case .doing, .review, .blocked: working += 1
            default: break
            }
        }
    }
}

struct PlanProgressBar: View {
    let progress: PlanProgress

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / CGFloat(max(progress.total, 1))
            HStack(spacing: 0) {
                Tok.go.frame(width: unit * CGFloat(progress.merged))
                StatusDot.color(for: .needsFix).frame(width: unit * CGFloat(progress.fix))
                Tok.work.frame(width: unit * CGFloat(progress.working))
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Tok.raise)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("\(progress.merged) merged, \(progress.fix) fix requested, \(progress.working) working of \(progress.total)")
    }
}

/// A card's state in the Now rows: its label and the colour the panel gives that state elsewhere (`StatusDot`).
struct PlanCardState: Equatable {
    let label: String
    let color: Color

    init(_ status: TaskStatus?) {
        guard let status else { label = "No such card"; color = Tok.ink3; return }
        color = StatusDot.color(for: status)
        label = switch status {
        case .todo: "Not started"
        case .awaitingStartApproval: "Approve start"
        case .doing: "Working"
        case .review: "In review"
        case .needsFix: "Fix requested"
        case .done: "Merged"
        case .blocked: "Blocked"
        case .cancelled: "Cancelled"
        case .unknown: status.label
        }
    }
}

/// The small uppercase section label ("NOW", "GOAL").
struct PlanSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.7).foregroundStyle(Tok.ink2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded state chip: the colour as text over the same colour faintly (`fill` when the background should differ).
struct PlanChip: View {
    let text: String
    let color: Color
    var fill: Color? = nil
    var dot = false

    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(Tok.Font.small.weight(.semibold)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, Tok.Space.s).frame(height: 22)
        .background((fill ?? color).opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }
}

extension View {
    /// A Plan screen panel: the pane colour with a line border, radius 12.
    func planPanel(padding: CGFloat) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
    }
}

/// Short time texts of the Plan screen.
enum PlanAge {
    /// "10 min ago", "3 h ago", or the date for anything older (or in the future).
    static func text(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 0 || s >= 86_400 { return date.formatted(.dateTime.month(.abbreviated).day()) }
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int(s / 3600)) h ago"
    }

    /// "started 11:52 · 1 h 40 min" (the date instead of the time when it was not today).
    static func started(_ date: Date, now: Date = Date()) -> String {
        let when = Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        let span = minutes < 60 ? "\(minutes) min" : (minutes < 1440 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes / 1440) d")
        return "started \(when) · \(span)"
    }

    /// The summary's first non-blank lines (at most `count`), for the right column before "Read all".
    static func firstLines(_ text: String, count: Int = 6) -> String {
        let lines = text.components(separatedBy: "\n")
        var seen = 0
        for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            seen += 1
            if seen == count { return i == lines.count - 1 ? text : lines[...i].joined(separator: "\n") }
        }
        return text
    }
}
