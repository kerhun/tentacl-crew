import SwiftUI

/// The coffee button at the right of the top bar. On battery with agents working it carries a warning badge.
struct CaffeinateButton: View {
    @Bindable var guardModel: SleepGuard

    var body: some View {
        Button { guardModel.isOn.toggle() } label: {
            Image(systemName: guardModel.state == .off ? "cup.and.saucer" : "cup.and.saucer.fill")
                .foregroundStyle(guardModel.state == .holding ? Tok.ask : Tok.ink)
                .opacity(guardModel.state == .off ? 0.6 : 1)
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    if guardModel.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Tok.wait).offset(x: 2, y: -1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(guardModel.tooltip)
        .accessibilityLabel("Keep the Mac awake")
        .accessibilityValue(Self.accessibilityValue(guardModel))
    }

    static func accessibilityValue(_ g: SleepGuard) -> String {
        let base: String
        switch g.state {
        case .off: base = "off"
        case .holding: base = "on, holding"
        case .waiting: base = "on, waiting for a task"
        case .lowBattery: base = "on, paused because the battery is low"
        }
        return g.warning.map { base + ". " + $0 } ?? base
    }
}

/// A rounded track with a fill (Stats).
struct UsageBar: View {
    let fraction: Double
    let fill: Color
    var height: CGFloat = 8
    var track: Color = Tok.line

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: min(3, height / 2)).fill(track)
                RoundedRectangle(cornerRadius: min(3, height / 2)).fill(fill)
                    .frame(width: g.size.width * fraction)
            }
        }
        .frame(height: height)
    }
}

/// Two mini gauges ("5h ▮▮▯ 23%", "wk ▮▯▯ 41%") from the plan usage; click opens Stats.
struct UsageChip: View {
    let usage: PlanUsage?
    let onOpen: () -> Void

    struct Gauge: Equatable { let label: String; let percentText: String; let fraction: Double; let warn: Bool }
    struct Content: Equatable { let gauges: [Gauge]; let help: String; let accessibilityValue: String }

    static func content(_ usage: PlanUsage?, now: Date = Date()) -> Content? {
        guard let usage else { return nil }
        let windows: [(label: String, name: String, spoken: String, w: PlanUsage.Window)] = [
            usage.fiveHour.map { ("5h", "5h", "5 hours", $0) },
            usage.week.map { ("wk", "week", "week", $0) },
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        let gauges = windows.map {
            Gauge(label: $0.label, percentText: "\(Int($0.w.percent.rounded()))%", fraction: $0.w.fraction, warn: $0.w.percent > 80)
        }
        let help = windows.map { "\($0.name) \(PlanUsage.resetText($0.w.resetsAt, now: now))" }.joined(separator: " · ")
        let spoken = windows.map { "\($0.spoken) \(Int($0.w.percent.rounded())) percent" }.joined(separator: ", ")
        return Content(gauges: gauges, help: help, accessibilityValue: spoken)
    }

    var body: some View {
        if let c = Self.content(usage) {
            Button(action: onOpen) {
                HStack(spacing: Tok.Space.s) {
                    ForEach(Array(c.gauges.enumerated()), id: \.element.label) { i, g in
                        if i > 0 { Rectangle().fill(Tok.ink3).frame(width: 1, height: 14) }
                        HStack(spacing: 4) {
                            Text(g.label).font(Tok.Font.small).foregroundStyle(g.warn ? Tok.ask : Tok.ink2)
                            UsageBar(fraction: g.fraction, fill: g.warn ? Tok.ask : Tok.ink, height: 6, track: Tok.bg).frame(width: 48)
                            Text(g.percentText).font(Tok.Font.bodyStrong).foregroundStyle(g.warn ? Tok.ask : Tok.ink)
                        }
                    }
                }
                .padding(.horizontal, Tok.Space.s).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Tok.Space.s).fill(Tok.raise))
                .overlay(RoundedRectangle(cornerRadius: Tok.Space.s).stroke(Tok.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(c.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plan usage")
            .accessibilityValue(c.accessibilityValue)
        }
    }
}

/// Plan usage as two rings in one 20 pt icon (outer: week, inner: 5 hours) and the higher percent beside it; click opens Stats.
/// With `tool` set, a name ("Claude", "Codex") goes before the rings and into the hover text and the voice (both plans show, N205).
struct UsageRing: View {
    let usage: PlanUsage?
    var tool: AgentTool? = nil
    /// A crowded top bar drops the name, then the percent (N388); both stay in the hover text and the voice.
    var showsName = true
    var showsPercent = true
    let onOpen: () -> Void

    struct Ring: Equatable { let fraction: Double; let warn: Bool }
    struct Content: Equatable {
        let week: Ring?
        let fiveHour: Ring?
        let percentText: String
        let warn: Bool
        let help: String
        let accessibilityValue: String
    }

    /// The same windows, warn line and hover text as `UsageChip`; with a tool its name leads the hover text ("Codex · 5h resets in …").
    static func content(_ usage: PlanUsage?, tool: AgentTool? = nil, now: Date = Date()) -> Content? {
        guard let usage, let chip = UsageChip.content(usage, now: now) else { return nil }
        func ring(_ w: PlanUsage.Window?) -> Ring? { w.map { Ring(fraction: $0.fraction, warn: $0.percent > 80) } }
        let top = [usage.fiveHour, usage.week].compactMap { $0 }.max { $0.percent < $1.percent }
        return Content(week: ring(usage.week), fiveHour: ring(usage.fiveHour), percentText: top.map { "\(Int($0.percent.rounded()))%" } ?? "",
                       warn: (top?.percent ?? 0) > 80, help: (tool.map { name($0) + " · " } ?? "") + chip.help, accessibilityValue: chip.accessibilityValue)
    }

    static func name(_ tool: AgentTool) -> String { tool == .codex ? "Codex" : "Claude" }
    static func accessibilityLabel(_ tool: AgentTool?) -> String { tool.map { "\(name($0)) plan usage" } ?? "Plan usage" }

    static func color(warn: Bool) -> Color { warn ? Tok.ask : Tok.ink2 }

    var body: some View {
        if let c = Self.content(usage, tool: tool) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if let tool, showsName { Text(Self.name(tool)).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                    ZStack {
                        arc(c.week, diameter: 16, width: 3)
                        arc(c.fiveHour, diameter: 8, width: 2)
                    }
                    .frame(width: 20, height: 20)
                    if showsPercent { Text(c.percentText).font(.system(size: 12)).monospacedDigit().foregroundStyle(Self.color(warn: c.warn)) }
                }
                .padding(.horizontal, Tok.Space.s).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(c.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(tool))
            .accessibilityValue(c.accessibilityValue)
        }
    }

    @ViewBuilder private func arc(_ ring: Ring?, diameter: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Tok.line, lineWidth: width)
            if let ring {
                Circle().trim(from: 0, to: ring.fraction).stroke(Self.color(warn: ring.warn), style: StrokeStyle(lineWidth: width))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The usage ring (and the Codex ring beside it), the autopilot icon and the coffee button, as one line for the top bar (the only place
/// either shows, on every screen).
struct TopBarExtras: View {
    let guardModel: SleepGuard
    let usage: PlanUsage?
    /// The Codex windows to show (`codexShown`); nil hides the Codex ring.
    var codexUsage: PlanUsage? = nil
    var autopilot: AutopilotModel? = nil
    /// The autopilot icon's state; nil hides it (no autopilot for this project).
    var autopilotLook: AutopilotIcon.Look? = nil
    /// The rings' names and percents (a crowded top bar drops them, N388).
    var ringNames = true
    var ringPercents = true
    let onOpenStats: () -> Void
    /// The Codex ring opens Stats at its Codex section (N217); nil: the same as `onOpenStats`.
    var onOpenCodexStats: (() -> Void)? = nil

    enum Item: Equatable { case usage, codexUsage, autopilot, caffeinate }

    static func items(autopilotAvailable: Bool, codex: Bool = false) -> [Item] {
        [.usage] + (codex ? [.codexUsage] : []) + (autopilotAvailable ? [.autopilot] : []) + [.caffeinate]
    }

    /// The Codex windows when they show: some role uses Codex, or a Codex session wrote in the last 5 hours (a run of the current window).
    static func codexShown(_ usage: PlanUsage?, roleUsesCodex: Bool, now: Date = Date()) -> PlanUsage? {
        guard let usage, roleUsesCodex || usage.seenRecently(now: now) else { return nil }
        return usage
    }

    var body: some View {
        HStack(spacing: Tok.Space.xs) {
            ForEach(Self.items(autopilotAvailable: autopilot != nil && autopilotLook != nil, codex: codexUsage != nil), id: \.self) { item in
                switch item {
                // The names show only when both plans do.
                case .usage: UsageRing(usage: usage, tool: codexUsage != nil ? .claude : nil, showsName: ringNames, showsPercent: ringPercents, onOpen: onOpenStats)
                case .codexUsage: UsageRing(usage: codexUsage, tool: .codex, showsName: ringNames, showsPercent: ringPercents, onOpen: onOpenCodexStats ?? onOpenStats)
                case .autopilot: if let autopilot, let autopilotLook { AutopilotIcon(autopilot: autopilot, look: autopilotLook) { autopilot.rulesOpen = true } }
                case .caffeinate: CaffeinateButton(guardModel: guardModel)
                }
            }
        }
    }
}
