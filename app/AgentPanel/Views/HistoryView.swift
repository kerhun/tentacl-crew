import SwiftUI

/// The History tab's filters: a card search and who decided.
struct HistoryFilter: Equatable {
    enum Who: String, CaseIterable { case all, pm, you }
    var card = ""
    var who: Who = .all
}

struct HistoryDay: Identifiable {
    let day: Date
    let rows: [DecisionRecord]
    var id: Date { day }
}

/// The kinds of an agent's question (not a fix, review, round, start…).
func historyIsQuestion(_ kind: String) -> Bool {
    [DecisionCategory.choice, .freeText, .permission, .plan].map(\.rawValue).contains(kind)
}

/// One record per question (N305): the PM's suggestion, its "sent to you" and the answer of the same question are one row,
/// the last outcome's, with the first reason when the last has none. A question is the same agent, card, kind and words,
/// and an answer closes it: the same words asked again later are a new row.
func historyMergedQuestions(_ records: [DecisionRecord]) -> [DecisionRecord] {
    var out: [DecisionRecord] = []
    var open: [String: Int] = [:]
    for r in records.sorted(by: { $0.time < $1.time }) {
        guard historyIsQuestion(r.kind) else { out.append(r); continue }
        let key = [r.cardID, r.agent, r.kind, r.question].joined(separator: "\n")
        if let i = open[key] {
            let earlier = out[i]
            out[i] = DecisionRecord(id: r.id, time: r.time, cardID: r.cardID, agent: r.agent, kind: r.kind, question: r.question, by: r.by, result: r.result,
                                    answer: r.answer, why: r.why.isEmpty ? earlier.why : r.why,
                                    costUSD: earlier.costUSD == nil && r.costUSD == nil ? nil : (earlier.costUSD ?? 0) + (r.costUSD ?? 0))
        } else {
            out.append(r)
            open[key] = out.count - 1
        }
        if r.result == .answered { open[key] = nil }
    }
    return out
}

/// The records that pass the filter, newest first, grouped by day.
func historyDays(_ records: [DecisionRecord], filter: HistoryFilter, calendar: Calendar = .current) -> [HistoryDay] {
    let needle = filter.card.trimmingCharacters(in: .whitespaces).lowercased()
    let kept = historyMergedQuestions(records).filter { r in
        (needle.isEmpty || r.cardID.lowercased().contains(needle))
            && (filter.who == .all || (filter.who == .pm) == (r.by == .pm))
    }
    let newestFirst = Array(kept.reversed()).sorted { $0.time > $1.time }
    return Dictionary(grouping: newestFirst) { calendar.startOfDay(for: $0.time) }
        .map { HistoryDay(day: $0.key, rows: $0.value) }
        .sorted { $0.day > $1.day }
}

/// The kind of a decision in plain words.
func historyKind(_ kind: String) -> String {
    switch kind {
    case DecisionCategory.choice.rawValue, DecisionCategory.freeText.rawValue: "question"
    default: kind
    }
}

/// The colour of a decision's kind, so neighbouring rows read apart (N281); an unknown kind stays grey (nil).
func historyKindTint(_ kind: String) -> Color? {
    switch kind {
    case AutopilotModel.startKind: Tok.work
    case "review", AutopilotModel.approveKind: Tok.go
    case "fix": Tok.stop
    case AutopilotModel.rebaseKind: Tok.wait
    case "plan": Tok.you
    case "permission": Tok.askText
    case AutopilotModel.roundKind: Tok.ink
    case DecisionCategory.choice.rawValue, DecisionCategory.freeText.rawValue, "answered-by-pm": Tok.waitStart
    case AutopilotModel.authorityResetKind: Tok.waitQuestion
    default: nil
    }
}

func historyCost(_ usd: Double?) -> String? { usd.map { String(format: "$%.2f", $0) } }

/// A decision the PM is making right now; it stays at the top of History while it runs.
struct HistoryPending: Identifiable, Equatable {
    let id: String
    let text: String
    let detail: String
}

/// The History tab of the right column: every decision of the project, newest first.
struct HistoryTab: View {
    @Bindable var autopilot: AutopilotModel
    var select: (String) -> Void
    @State private var records: [DecisionRecord]

    /// Read here, not on appear, so the first draw already has the records instead of laying the tab out twice (N131).
    init(autopilot: AutopilotModel, select: @escaping (String) -> Void) {
        self.autopilot = autopilot
        self.select = select
        _records = State(initialValue: autopilot.allRecords())
    }

    private var deciding: [HistoryPending] {
        autopilot.deciding.map { q in
            HistoryPending(id: q.id, text: "is deciding for \(q.agentLabel)", detail: String((q.question.title.isEmpty ? q.question.text : q.question.title).replacingOccurrences(of: "\n", with: " ").prefix(90)))
        } + autopilot.decidingFixes.map { HistoryPending(id: "fix|" + $0.id, text: "is reading the new fix notes on \($0.card.id)", detail: "") }
    }

    var body: some View {
        HistoryView(records: records, deciding: deciding, select: select)
            .onChange(of: autopilot.records.last?.id) { _, _ in records = autopilot.allRecords() }
            .onChange(of: autopilot.isAvailable) { _, _ in records = autopilot.allRecords() }
    }
}

/// The grouped days of the last records and filter: grouping thousands of records is not done again on every draw.
final class HistoryDaysCache {
    /// One for the whole app: the Dashboard builds its History view anew on every switch to it, so a cache inside the view would never be hit.
    @MainActor static let shared = HistoryDaysCache()
    private var key: (count: Int, last: String?, filter: HistoryFilter)?
    private var days: [HistoryDay] = []
    func days(_ records: [DecisionRecord], filter: HistoryFilter) -> [HistoryDay] {
        // The tab draws once with no records before it reads them; that must not push the real answer out of the cache.
        if records.isEmpty { return [] }
        if let key, key.count == records.count, key.last == records.last?.id, key.filter == filter { return days }
        days = historyDays(records, filter: filter)
        key = (records.count, records.last?.id, filter)
        return days
    }
}

struct HistoryView: View {
    let records: [DecisionRecord]
    let deciding: [HistoryPending]
    var select: (String) -> Void
    @State private var filter = HistoryFilter()

    static let dayTitle: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"; return f }()

    var body: some View {
        let days = HistoryDaysCache.shared.days(records, filter: filter)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tok.Space.s) {
                TextField("Card, e.g. N74", text: $filter.card).textFieldStyle(.roundedBorder).accessibilityLabel("Filter by card")
                Picker("", selection: $filter.who) {
                    Text("All").tag(HistoryFilter.Who.all)
                    Text("PM").tag(HistoryFilter.Who.pm)
                    Text("You").tag(HistoryFilter.Who.you)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130).accessibilityLabel("Filter by who decided")
            }
            .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s)
            Divider().overlay(Tok.line)
            Scroller {
                // Lazy: a project with thousands of decisions lays out the rows in view, not all of them, each time the Dashboard appears.
                LazyVStack(alignment: .leading, spacing: Tok.Space.xs) {
                    ForEach(deciding) { p in
                        HStack(alignment: .top, spacing: Tok.Space.s) {
                            Text("now").font(Tok.Font.mono).foregroundStyle(Tok.ink3).frame(width: 36, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                (Text("PM").foregroundStyle(Tok.work).fontWeight(.semibold) + Text(" · " + p.text).foregroundStyle(Tok.ink2)).font(Tok.Font.small)
                                if !p.detail.isEmpty { Text(p.detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2) }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    if days.isEmpty && deciding.isEmpty {
                        Text(records.isEmpty ? "No decisions yet." : "No decision matches.").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(.top, Tok.Space.s)
                    }
                    ForEach(days) { day in
                        Text(Self.dayTitle.string(from: day.day).uppercased()).font(Tok.Font.mono).foregroundStyle(Tok.ink3).padding(.top, Tok.Space.s)
                        ForEach(day.rows) { r in HistoryRow(record: r, select: select) }
                    }
                }
                .padding(.horizontal, Tok.Space.m).padding(.bottom, Tok.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tok.pane)
    }
}

struct HistoryRow: View {
    let record: DecisionRecord
    var select: (String) -> Void

    /// A click selects the row's card; rows without a card (a round) do nothing.
    static func open(_ r: DecisionRecord, select: (String) -> Void) { if !r.cardID.isEmpty { select(r.cardID) } }

    var body: some View {
        let r = record
        let pm = r.by == .pm
        Button { Self.open(r, select: select) } label: {
            HStack(alignment: .top, spacing: Tok.Space.s) {
                Text(DecisionFeed.clock.string(from: r.time)).font(Tok.Font.mono).foregroundStyle(Tok.ink3).frame(width: 36, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pm ? "PM" : "You").font(Tok.Font.small.weight(.semibold)).foregroundStyle(pm ? Tok.work : Tok.ink2)
                        if !r.cardID.isEmpty { Chip(text: r.cardID) }
                        Chip(text: historyKind(r.kind), tint: historyKindTint(r.kind))
                        Spacer(minLength: 0)
                        if let cost = historyCost(r.costUSD) { Text(cost).font(Tok.Font.mono).foregroundStyle(Tok.ink3) }
                    }
                    Text(DecisionFeed.summary(r)).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                    if !r.question.isEmpty && r.kind != AutopilotModel.roundKind && !historyIsQuestion(r.kind) {
                        Text(r.question).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(3)
                    }
                    if !r.why.isEmpty { Text("Why: " + r.why).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(4).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(historyIsQuestion(r.kind) ? r.question : "")
        .accessibilityElement(children: .combine)
    }
}
