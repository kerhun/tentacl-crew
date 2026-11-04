import SwiftUI

/// The Stats screen's series colors (N137), one token per theme. Text never takes them: labels stay in `Tok` ink.
enum StatsColor {
    /// Merged cards, cost, the 5-hour window and the agent's working time.
    static let blue = Tok.chartA
    static let blueHover = Tok.chartAHover
    /// The week window and the time spent waiting for the user.
    static let orange = Tok.chartB
}

/// A box of the Stats screen: a title row (title left, a note right) above its content.
struct StatsBox<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tok.ink)
                Spacer(minLength: 0)
                trailing()
            }
            content()
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
    }
}

extension StatsBox where Trailing == Text {
    init(_ title: String, note: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        trailing = { Text(note).font(.system(size: 12)).foregroundStyle(Tok.ink3) }
        self.content = content
    }
}

/// Lays out its children side by side, splitting the width by `ratios` (all the same height).
struct RatioRow: Layout {
    var ratios: [CGFloat]
    var spacing: CGFloat = 14

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let r = (0..<count).map { $0 < ratios.count ? ratios[$0] : 1 }
        let free = max(total - spacing * CGFloat(count - 1), 0)
        let sum = r.reduce(0, +)
        return r.map { free * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        let w = widths(width, count: subviews.count)
        let height = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, w) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

/// 7 / 14 / 30 days, drawn like the Tasks tab row (N135).
struct StatsRangePicker: View {
    let selected: StatsRange
    let onSelect: (StatsRange) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases, id: \.self) { r in
                let on = r == selected
                Button { onSelect(r) } label: {
                    Text(r.title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? Tok.ink : Tok.ink2)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(on ? Tok.line : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Last \(r.rawValue) days")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.line))
        .fixedSize()
    }
}

/// Cards merged per day: one bar per day on a baseline, a 2 pt stub for an empty day; hovering a bar shows the day, the count and the ids
/// in a fixed-width grid beside the bar, kept inside the chart (N140).
struct MergedBarChart: View {
    let days: [DayCount]
    var height: CGFloat = 190
    @State private var hovered: Date?

    init(days: [DayCount], height: CGFloat = 190, hovered: Date? = nil) {
        self.days = days
        self.height = height
        _hovered = State(initialValue: hovered)
    }

    static let tooltipWidth: CGFloat = 300
    static let tooltipColumns = 6
    static let tooltipMaxRows = 8
    private static let barSpacing: CGFloat = 2
    private static let lineHeight: CGFloat = 15

    var body: some View {
        let top = CGFloat(max(days.map(\.count).max() ?? 0, 1))
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: Self.barSpacing) {
                ForEach(days, id: \.day) { d in
                    let on = hovered == d.day
                    UnevenRoundedRectangle(topLeadingRadius: d.count > 0 ? 4 : 1, topTrailingRadius: d.count > 0 ? 4 : 1)
                        .fill(d.count == 0 ? Tok.line : on ? StatsColor.blueHover : StatsColor.blue)
                        .frame(height: barHeight(d, top: top))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { inside in hovered = inside ? d.day : (hovered == d.day ? nil : hovered) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(Self.dayText(d.day)): \(d.count) merged\(d.ids.isEmpty ? "" : ", " + d.ids.joined(separator: ", "))")
                }
            }
            .frame(height: height)
            .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
            // Drawn over the bars in the chart's own space, so it never reaches the boxes around it.
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    if let i = days.firstIndex(where: { $0.day == hovered }) {
                        let d = days[i]
                        let w = (geo.size.width - Self.barSpacing * CGFloat(days.count - 1)) / CGFloat(days.count)
                        let h = barHeight(d, top: top)
                        let size = Self.tooltipSize(ids: d.ids.count)
                        let at = Self.tooltipOrigin(bar: CGRect(x: CGFloat(i) * (w + Self.barSpacing), y: geo.size.height - h, width: w, height: h), size: size, in: geo.size)
                        tooltip(d).frame(width: size.width, height: size.height, alignment: .topLeading).offset(x: at.x, y: at.y)
                    }
                }
                .allowsHitTesting(false)
            }
            HStack {
                ForEach(Array(Self.labelDays(days).enumerated()), id: \.offset) { i, day in
                    if i > 0 { Spacer() }
                    Text(Self.dayText(day)).font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cards merged per day")
    }

    private func barHeight(_ d: DayCount, top: CGFloat) -> CGFloat {
        d.count > 0 ? max(4, (height - 12) * CGFloat(d.count) / top) : 2
    }

    private func tooltip(_ d: DayCount) -> some View {
        let cells = Self.tooltipCells(d.ids)
        let cellWidth = (Self.tooltipWidth - 20) / CGFloat(Self.tooltipColumns)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(Self.dayText(d.day)) · \(d.count) merged").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.ink)
                .lineLimit(1).frame(height: Self.lineHeight)
            if !cells.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0..<Self.tooltipRows(cells.count), id: \.self) { row in
                        GridRow {
                            ForEach(row * Self.tooltipColumns..<min((row + 1) * Self.tooltipColumns, cells.count), id: \.self) { k in
                                Text(cells[k]).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tok.ink2)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .frame(width: cellWidth, height: Self.lineHeight, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: Self.tooltipWidth, alignment: .leading)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .shadow(color: .black.opacity(Tok.shadowOpacity(0.5)), radius: 10, y: 6)
    }

    /// The ids as the grid shows them: all of them up to 6 × 8, else the first 47 and "+N more" in the last cell.
    static func tooltipCells(_ ids: [String]) -> [String] {
        let room = tooltipColumns * tooltipMaxRows
        return ids.count <= room ? ids : Array(ids.prefix(room - 1)) + ["+\(ids.count - room + 1) more"]
    }

    static func tooltipRows(_ cells: Int) -> Int { (cells + tooltipColumns - 1) / tooltipColumns }

    /// Always `tooltipWidth` wide; as tall as the title and the rows of ids.
    static func tooltipSize(ids: Int) -> CGSize {
        let rows = tooltipRows(min(ids, tooltipColumns * tooltipMaxRows))
        return CGSize(width: tooltipWidth, height: 16 + lineHeight + (rows > 0 ? 6 + CGFloat(rows) * lineHeight : 0))
    }

    /// Right of the bar, or left of it when that would cross the right edge; level with the bar's top; always inside `box`.
    static func tooltipOrigin(bar: CGRect, size: CGSize, in box: CGSize) -> CGPoint {
        var x = bar.maxX + 8
        if x + size.width > box.width { x = bar.minX - 8 - size.width }
        x = min(max(x, 0), max(box.width - size.width, 0))
        let y = min(max(bar.minY - size.height / 2, 0), max(box.height - size.height, 0))
        return CGPoint(x: x, y: y)
    }

    /// The first, the middle and the last day.
    static func labelDays(_ days: [DayCount]) -> [Date] {
        guard let first = days.first?.day, let last = days.last?.day else { return [] }
        return days.count < 3 ? [first, last] : [first, days[days.count / 2].day, last]
    }

    static func dayText(_ day: Date) -> String { day.formatted(.dateTime.month(.abbreviated).day()) }
}

/// One plan window as a ring: the use in the window's color, the forecast to the reset as a light arc, the percent in the middle.
struct LimitRing: View {
    let name: String
    let window: PlanUsage.Window
    let length: TimeInterval
    let color: Color
    let now: Date
    var calendar: Calendar = .current

    var body: some View {
        let forecast = PlanUsage.forecast(window, length: length, now: now)
        let used = window.fraction
        let ahead = max((forecast?.percentAtReset ?? window.percent) / 100, used)
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Tok.line, lineWidth: 8.5)
                Circle().trim(from: used, to: min(ahead, 1)).stroke(Tok.ink.opacity(0.3), style: StrokeStyle(lineWidth: 8.5)).rotationEffect(.degrees(-90))
                Circle().trim(from: 0, to: used).stroke(color, style: StrokeStyle(lineWidth: 8.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int(window.percent.rounded()))%").font(.system(size: 21, weight: .bold)).monospacedDigit().foregroundStyle(Tok.ink)
            }
            .frame(width: 84, height: 84)
            .padding(4)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 14, weight: .bold)).foregroundStyle(Tok.ink)
                Text(PlanUsage.resetLine(window.resetsAt, now: now, calendar: calendar)).font(.system(size: 12)).foregroundStyle(Tok.ink2)
                if let forecast { Text(PlanUsage.forecastText(forecast, now: now, calendar: calendar)).font(.system(size: 13)).foregroundStyle(Tok.ink) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(Int(window.percent.rounded())) percent used, \(PlanUsage.resetLine(window.resetsAt, now: now, calendar: calendar))"
                            + (forecast.map { ". " + PlanUsage.forecastText($0, now: now, calendar: calendar) } ?? ""))
    }
}

/// The legend of a chart with two series.
struct StatsLegend: View {
    let items: [(String, Color)]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 10)
                    Text(item.0).font(.system(size: 12)).foregroundStyle(Tok.ink2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Start to merge for one card: the agent's part, a 2 pt gap, the wait for the user; the bar's width against the longest card shown.
struct FlowRow: View {
    let flow: CardFlow
    let longest: TimeInterval
    var calendar: Calendar = .current
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(flow.cardID).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink2).frame(width: 52, alignment: .leading)
                GeometryReader { geo in
                    let scale = longest > 0 ? geo.size.width / longest : 0
                    let a = flow.agent * scale, w = flow.waiting * scale
                    HStack(spacing: a > 0 && w > 0 ? 2 : 0) {
                        if a > 0 { UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: w > 0 ? 0 : 4, topTrailingRadius: w > 0 ? 0 : 4).fill(StatsColor.blue).frame(width: max(a - (w > 0 ? 1 : 0), 2)) }
                        if w > 0 { UnevenRoundedRectangle(topLeadingRadius: a > 0 ? 0 : 4, bottomLeadingRadius: a > 0 ? 0 : 4, bottomTrailingRadius: 4, topTrailingRadius: 4).fill(StatsColor.orange).frame(width: max(w - (a > 0 ? 1 : 0), 2)) }
                    }
                }
                .frame(height: 12)
                Text(Stats.shortDuration(flow.total)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Tok.ink2).frame(width: 64, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(stepsText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flow.cardID): agent working \(Stats.durationText(flow.agent)), waiting for you \(Stats.durationText(flow.waiting)), \(Stats.durationText(flow.total)) in total")
        .accessibilityHint("Opens the card on Tasks")
    }

    /// One step per line ("Started 08:00", "Review packet ready 09:00", …, "Approved 10:00"), so the tooltip stays narrow, then the split.
    var stepsText: String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let first = flow.steps.first?.time ?? flow.start
        return flow.steps.map { s in
            "\(s.title) \(calendar.isDate(s.time, inSameDayAs: first) ? f.string(from: s.time) : MergedBarChart.dayText(s.time) + " " + f.string(from: s.time))"
        }.joined(separator: "\n") + "\nAgent \(Stats.shortDuration(flow.agent)) · waiting for you \(Stats.shortDuration(flow.waiting))"
    }
}

/// Estimated cost per day: a 2 pt line over a light area, a dashed line at half the top; hovering shows a crosshair with the day's cost.
struct CostLineChart: View {
    let days: [DayCost]
    var height: CGFloat = 200
    @State private var hovered: Int?
    /// The hover label's fixed width: centered on the point, kept inside the chart.
    private static let tooltipWidth: CGFloat = 130

    var body: some View {
        let top = max(days.map(\.dollars).max() ?? 0, 0.01)
        VStack(spacing: 8) {
            GeometryReader { geo in
                let pts = points(in: geo.size, top: top)
                ZStack(alignment: .topLeading) {
                    Path { p in p.move(to: CGPoint(x: 0, y: geo.size.height / 2)); p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2)) }
                        .stroke(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    Rectangle().fill(Tok.line).frame(height: 1).offset(y: geo.size.height - 1)
                    if pts.count > 1 {
                        Path { p in
                            p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                            pts.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(StatsColor.blue.opacity(0.12))
                        Path { p in p.addLines(pts) }.stroke(StatsColor.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    if let i = hovered, i < pts.count {
                        Rectangle().fill(Tok.ink3).frame(width: 1, height: geo.size.height).offset(x: pts[i].x)
                        dot.offset(x: pts[i].x - 5, y: pts[i].y - 5)
                        Text("\(MergedBarChart.dayText(days[i].day)) · \(String(format: "$%.2f", days[i].dollars))")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.ink)
                            .lineLimit(2).multilineTextAlignment(.center)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(width: Self.tooltipWidth)
                            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line))
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(x: min(max(pts[i].x - Self.tooltipWidth / 2, 0), max(geo.size.width - Self.tooltipWidth, 0)), y: 4)
                    } else if let last = pts.last {
                        dot.offset(x: last.x - 5, y: last.y - 5)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let at): hovered = days.count > 1 ? Int((at.x / max(geo.size.width, 1) * CGFloat(days.count - 1)).rounded()) : 0
                    case .ended: hovered = nil
                    }
                }
            }
            .frame(height: height)
            HStack {
                Text(days.first.map { MergedBarChart.dayText($0.day) } ?? "").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                Spacer()
                Text("dashed line \(String(format: "$%.2f", top / 2))").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                Spacer()
                Text("today \(String(format: "$%.2f", days.last?.dollars ?? 0))").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated cost per day: " + days.filter { $0.dollars > 0 }.map { "\(MergedBarChart.dayText($0.day)) \(String(format: "$%.2f", $0.dollars))" }.joined(separator: ", "))
    }

    private var dot: some View {
        Circle().fill(StatsColor.blue).frame(width: 10, height: 10).overlay(Circle().stroke(Tok.pane, lineWidth: 2))
    }

    private func points(in size: CGSize, top: Double) -> [CGPoint] {
        guard days.count > 1 else { return [] }
        return days.enumerated().map { i, d in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(days.count - 1), y: (size.height - 2) - (size.height - 12) * CGFloat(d.dollars / top))
        }
    }
}
