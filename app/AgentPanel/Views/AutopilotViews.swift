import SwiftUI

/// The autopilot icon of the top bar: green when on, amber in shadow, grey when off, orange while the daily cost limit pauses the PM.
/// It opens a menu to change the mode or edit the rules.
struct AutopilotIcon: View {
    @Bindable var autopilot: AutopilotModel
    let look: Look
    let onRules: () -> Void

    enum Tint: Equatable {
        case on, shadow, off, paused
        var color: Color {
            switch self {
            case .on: Tok.go
            case .shadow: Tok.wait
            case .off: Tok.ink3
            case .paused: Tok.ask
            }
        }
    }

    struct Look: Equatable { let tint: Tint; let help: String; let accessibilityValue: String }

    static func look(mode: AutopilotMode, limitReached: Bool, dailyLimit: Double?) -> Look {
        if limitReached, let limit = dailyLimit {
            let paused = String(format: "PM paused: daily limit $%.2f reached", limit)
            return Look(tint: .paused, help: paused + ". Today's estimated cost reached the limit in the autopilot rules. Questions come to you until tomorrow or until you raise the limit.",
                        accessibilityValue: "\(mode.title), " + paused)
        }
        let tint: Tint = switch mode { case .on: .on; case .shadow: .shadow; case .off: .off }
        return Look(tint: tint, help: "PM autopilot · \(mode.title.lowercased()). \(mode.explanation)", accessibilityValue: mode.title)
    }

    static func look(_ autopilot: AutopilotModel) -> Look {
        look(mode: autopilot.policy.mode, limitReached: autopilot.limitReached, dailyLimit: autopilot.policy.dailyLimitUSD)
    }

    var body: some View {
        MenuBox {
            ForEach(AutopilotMode.allCases, id: \.self) { mode in
                Button { autopilot.requestMode(mode) } label: {
                    Text("\(mode == autopilot.policy.mode ? "✓ " : "")\(mode.title): \(mode.explanation)")
                }
            }
            Divider()
            Button("Autopilot rules…", action: onRules)
        } label: {
            AutopilotGlyph().stroke(look.tint.color, lineWidth: 1.6).frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .help(look.help)
        .accessibilityLabel("PM autopilot")
        .accessibilityValue(look.accessibilityValue)
    }
}

/// A hexagon with a dot in the middle (the artboard's autopilot mark).
private struct AutopilotGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.minX + w * 0.5, y: r.minY + h * 0.094))
        p.addLine(to: CGPoint(x: r.minX + w * 0.875, y: r.minY + h * 0.3125))
        p.addLine(to: CGPoint(x: r.minX + w * 0.875, y: r.minY + h * 0.6875))
        p.addLine(to: CGPoint(x: r.minX + w * 0.5, y: r.minY + h * 0.906))
        p.addLine(to: CGPoint(x: r.minX + w * 0.125, y: r.minY + h * 0.6875))
        p.addLine(to: CGPoint(x: r.minX + w * 0.125, y: r.minY + h * 0.3125))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: r.midX - w * 0.125, y: r.midY - h * 0.125, width: w * 0.25, height: h * 0.25))
        return p
    }
}

/// What the PM is deciding now and what was decided today, newest first.
struct DecisionFeed: View {
    @Bindable var autopilot: AutopilotModel
    var limit = 6

    private var today: [DecisionRecord] {
        Array(autopilot.records.filter { Calendar.current.isDateInToday($0.time) }.reversed().prefix(limit))
    }

    var body: some View {
        let deciding = autopilot.deciding
        let readingFixes = autopilot.decidingFixes
        if !deciding.isEmpty || !readingFixes.isEmpty || !today.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("PM DECISIONS · TODAY").font(Tok.Font.mono).foregroundStyle(Tok.ink3).padding(.bottom, Tok.Space.xs)
                ForEach(deciding) { q in
                    row(time: "now", who: "PM", whoColor: Tok.work, text: "is deciding for \(q.agentLabel)", detail: shortQuestion(q.question))
                }
                ForEach(readingFixes) { f in
                    row(time: "now", who: "PM", whoColor: Tok.work, text: "is reading the new fix notes on \(f.card.id)", detail: "")
                }
                ForEach(today) { r in
                    row(time: Self.clock.string(from: r.time), who: r.by == .pm ? "PM" : "You", whoColor: r.by == .pm ? Tok.work : Tok.ink2,
                        text: Self.summary(r), detail: r.why)
                }
            }
            .padding(.vertical, Tok.Space.xs)
        }
        if let error = autopilot.saveError {
            Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(time: String, who: String, whoColor: Color, text: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Tok.Space.s) {
            Text(time).font(Tok.Font.mono).foregroundStyle(Tok.ink3).frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                (Text(who).foregroundStyle(whoColor).fontWeight(.semibold) + Text(" · " + text).foregroundStyle(Tok.ink2))
                    .font(Tok.Font.small).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2) }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
    }

    private func shortQuestion(_ q: AgentQuestion) -> String {
        String((q.title.isEmpty ? q.text : q.title).replacingOccurrences(of: "\n", with: " ").prefix(90))
    }

    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    static func summary(_ r: DecisionRecord) -> String {
        if r.kind == AutopilotModel.roundKind {
            let stopped = "Round stopped: "
            return r.question.hasPrefix(stopped) ? "round stopped: " + r.question.dropFirst(stopped.count) : "round started: \(r.answer)"
        }
        if r.kind == AutopilotModel.startKind {
            switch r.result {
            case .answered: return "started \(r.answer) as you asked"
            case .suggested: return "opened the Round sheet for \(r.cardID)"
            case .escalated: return "could not start \(r.cardID): \(String(r.why.prefix(80)))"
            }
        }
        if r.kind == AutopilotModel.authorityResetKind { return "PM start count reset to 0 by you" }
        if r.kind == AutopilotModel.approveKind {
            switch r.result {
            case .answered: return "approved \(r.answer) as you asked"
            case .suggested: return "opened the Approve sheet for \(r.cardID)"
            case .escalated: return "could not approve \(r.cardID): \(String(r.why.prefix(80)))"
            }
        }
        if r.kind == DecisionCategory.fix.rawValue {
            switch r.result {
            case .answered: return "\(r.cardID): fix notes passed on to \(r.agent)"
            case .suggested: return "suggests passing \(r.cardID)'s fix notes on to \(r.agent)"
            case .escalated: return "sent \(r.cardID)'s fix notes to you"
            }
        }
        // One row per question (N305): who asked, the question cut at a word, and the answer once there is one.
        let short = "\(r.agent): \"\(cutAtWord(r.question, 70))\""
        switch r.result {
        case .answered: return "\(short) → \(cutAtWord(r.answer, 60))"
        case .suggested: return "\(short) · suggests \(cutAtWord(r.answer, 60))"
        case .escalated: return "\(short) · sent to you"
        }
    }

    /// `text` on one line, cut at the last word that fits in `limit` characters, with "…" when cut.
    static func cutAtWord(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        let head = line.prefix(limit)
        var cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        while let last = cut.last, last == " " || ",;:.-".contains(last) { cut = cut.dropLast() }
        return String(cut) + "…"
    }
}

/// "Fix notes from a reviewer": the PM's suggestion to pass them on (shadow), or why it left them to the user. Orange means a decision of yours.
struct FixCards: View {
    @Bindable var autopilot: AutopilotModel

    var body: some View {
        ForEach(autopilot.fixesForYou) { fix in
            FixCard(fix: fix, autopilot: autopilot)
        }
    }
}

/// One fix; the Dashboard's Waiting for you lists each on its own, in its order and colour (N182).
struct FixCard: View {
    let fix: PendingFix
    @Bindable var autopilot: AutopilotModel
    /// Waiting for you: the headline becomes the kind's chip, the outline and Send fix request take its colour; elsewhere orange and blue.
    var tint: WaitingTint? = nil

    private var why: (text: String, suggested: Bool)? {
        switch fix.state {
        case .suggested(let why): (why, true)
        case .escalated(let reason): (reason, false)
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            HStack(spacing: Tok.Space.s) {
                if let tint { WaitingChip(text: fix.headline, tint: tint) } else {
                    Circle().fill(Tok.ask).frame(width: 8, height: 8).overlay { Circle().stroke(Tok.ask.opacity(0.25), lineWidth: 3) }
                    Text(fix.headline).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ask)
                }
                Spacer(minLength: 0)
                Chip(text: fix.card.id)
            }
            Text(fix.card.agent ?? fix.card.title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
            if let why, !why.suggested {
                Text(why.text).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Text(fix.entry).font(Tok.Font.small).foregroundStyle(Tok.ink).lineLimit(10).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if let why, why.suggested {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PM suggests passing this fix on").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work)
                    Text(why.text).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Tok.Space.s + 2).padding(.vertical, Tok.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.work.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .leading) { Rectangle().fill(Tok.work).frame(width: 2) }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: Tok.Space.m) {
                if fix.isRetryablePacket {
                    Button("Retry") { autopilot.retryPacket(cardID: fix.card.id) }.buttonStyle(ConfirmButtonStyle(fill: tint?.color ?? Tok.work))
                } else if why != nil {
                    Button("Send fix request") { Task { await autopilot.sendSuggestedFix(cardID: fix.card.id) } }.buttonStyle(ConfirmButtonStyle(fill: tint?.color ?? Tok.work))
                }
                Spacer()
                Button("Dismiss") { autopilot.dismissFix(cardID: fix.card.id) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    .help("Only hides this card. Use Request fix on the task when you want the developer to get it")
            }
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke((tint?.color ?? Tok.ask).opacity(0.6), lineWidth: 1))
    }
}

/// The policy table: who answers each kind of question, how long the PM may take, which model and budget it uses.
struct AutopilotRulesSheet: View {
    let initial: AutopilotPolicy
    /// Commands the user said may always run in this project; Remove acts at once, not on Save (N213).
    var onRemoveRule: (PermissionRule) -> Void = { _ in }
    /// Today's estimated cost, shown next to the daily limit; nil when it is not known.
    var costToday: Double? = nil
    let onSave: (AutopilotPolicy) -> Void
    let onCancel: () -> Void
    /// Sets the PM's start count back to zero at once (not on Save).
    let onResetCount: () -> Void
    @State private var draft: AutopilotPolicy
    /// Cards the PM started today under its authority, since the last reset.
    @State private var startedToday: Int
    @State private var confirmingReset = false
    @State private var rules: [PermissionRule]

    init(policy: AutopilotPolicy, permissionRules: [PermissionRule] = [], onRemoveRule: @escaping (PermissionRule) -> Void = { _ in }, costToday: Double? = nil, startedToday: Int = 0, onResetCount: @escaping () -> Void = {},
         onSave: @escaping (AutopilotPolicy) -> Void, onCancel: @escaping () -> Void) {
        initial = policy; _rules = State(initialValue: permissionRules); self.onRemoveRule = onRemoveRule; self.costToday = costToday; self.onResetCount = onResetCount; self.onSave = onSave; self.onCancel = onCancel
        _draft = State(initialValue: policy)
        _startedToday = State(initialValue: startedToday)
    }

    /// "Always allow in this project" rules, one per row with Remove.
    @ViewBuilder private var permissionRulesList: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            Text("Always allowed in this project").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
            if rules.isEmpty {
                Text("None. Use “Always allow in this project” on a permission question to add one.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            ForEach(rules) { rule in
                HStack(spacing: Tok.Space.m) {
                    Text(rule.pattern).font(.system(size: 13, design: .monospaced)).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Remove") { rules.removeAll { $0 == rule }; onRemoveRule(rule) }.buttonStyle(PanelButtonStyle())
                        .help("Stops answering this command by itself, at once")
                }
            }
            Text("With the autopilot On or in Shadow, a matching permission prompt is answered Yes once. Never covered: \(PermissionRules.neverCovered)")
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func startedText(_ started: Int, of perDay: Int) -> String { "Started today: \(started) of \(perDay)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PM autopilot").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text("Who answers what while a task runs. Final approval, merging, closing a task and every step outside the project always stay with you.")
                    .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Tok.Space.m) {
                Text("Mode").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).frame(width: 150, alignment: .leading)
                Segments(options: AutopilotMode.allCases.map { ($0, $0.title) }, selection: $draft.mode)
                Text(draft.mode.explanation).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(DecisionCategory.allCases, id: \.self) { category in
                    HStack(alignment: .top, spacing: Tok.Space.m) {
                        Text(category.title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).frame(width: 150, alignment: .leading)
                        Segments(options: [(DecisionOwner.you, "You"), (DecisionOwner.pm, "PM")],
                                 selection: Binding(get: { draft.owner(of: category) }, set: { draft.setOwner($0, for: category) }))
                            .frame(width: 110, alignment: .leading)
                        Text(category.rule).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Tok.Space.s)
                    .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
                }
            }
            Text("Commands a role may always run belong in its Allowed tools (Team screen): those never ask, so they never reach you or the PM.")
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            permissionRulesList
            HStack(spacing: Tok.Space.xl) {
                Nudge(label: "Escalate after \(AutopilotModel.duration(draft.timeoutSeconds))",
                      onLess: { draft.timeoutSeconds = max(60, draft.timeoutSeconds - 60) }, onMore: { draft.timeoutSeconds = min(900, draft.timeoutSeconds + 60) })
                HStack(spacing: Tok.Space.s) {
                    Text("Model").font(Tok.Font.body).foregroundStyle(Tok.ink)
                    Segments(options: AutopilotPolicy.models.map { ($0, $0) }, selection: $draft.model)
                }
                Nudge(label: String(format: "Budget $%.2f per decision", draft.budgetUSD),
                      onLess: { draft.budgetUSD = max(0.1, ((draft.budgetUSD - 0.1) * 10).rounded() / 10) }, onMore: { draft.budgetUSD = min(3, ((draft.budgetUSD + 0.1) * 10).rounded() / 10) })
            }
            Text("Codex decisions (used only when Claude is not signed in) have no per-decision budget cap; the daily cost limit still applies.")
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tok.Space.xl) {
                Toggle("Daily cost limit", isOn: Binding(get: { draft.dailyLimitUSD != nil }, set: { draft.dailyLimitUSD = $0 ? 5 : nil }))
                    .font(Tok.Font.body).foregroundStyle(Tok.ink)
                if let limit = draft.dailyLimitUSD {
                    Nudge(label: String(format: "$%.0f a day", limit),
                          onLess: { draft.dailyLimitUSD = max(1, limit - 1) }, onMore: { draft.dailyLimitUSD = min(1000, limit + 1) })
                }
                Text("Today " + Stats.costText(costToday) + (draft.dailyLimitUSD == nil ? "" : "; at the limit the PM stops deciding and questions come to you."))
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            Toggle("Tell the PM when a card changes phase", isOn: $draft.tellPM)
                .font(Tok.Font.body).foregroundStyle(Tok.ink)
            Toggle("Run build and test while writing the summary", isOn: $draft.runBuildAndTest)
                .font(Tok.Font.body).foregroundStyle(Tok.ink)
                .help("The PM runs the build and test commands read-only when it first looks at a project, and keeps the last 30 lines of output")
            Toggle("Start a fresh conversation with hand-off at each new round, when a round is finished, and at the safe point", isOn: $draft.freshConversation)
                .font(Tok.Font.body).foregroundStyle(Tok.ink)
                .help("Saves tokens: the PM writes its hand-off note and the conversation is cleared, only while the PM is idle and has no open question")
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                HStack(spacing: Tok.Space.xl) {
                    Toggle("PM authority", isOn: $draft.pmAuthority).font(Tok.Font.body).foregroundStyle(Tok.ink)
                    if draft.pmAuthority {
                        Nudge(label: "\(draft.pmStartsPerDay) starts a day",
                              onLess: { draft.pmStartsPerDay = max(1, draft.pmStartsPerDay - 1) }, onMore: { draft.pmStartsPerDay = min(50, draft.pmStartsPerDay + 1) })
                        Text(Self.startedText(startedToday, of: draft.pmStartsPerDay)).font(Tok.Font.small).foregroundStyle(Tok.ink2).monospacedDigit()
                        Button("Reset count") { confirmingReset = true }.buttonStyle(PanelButtonStyle()).disabled(startedToday == 0)
                            .help("Count the PM's starts from zero again")
                    }
                }
                Text("The PM may start planned cards and approve cards whose review packet passed, without a new message from you. Never setup cards; the daily cost limit, conflicts and free slots still apply. Every such step is tagged \"PM authority\" in the feed.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }.buttonStyle(ConfirmButtonStyle()).disabled(draft == initial)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 720)
        .background(Tok.bg)
        .modifier(ResetCountDialog(isPresented: $confirmingReset) { onResetCount(); startedToday = 0 })
    }
}

/// "Count PM starts from zero again?" Left out of snapshots: a dialog drawn by ImageRenderer crashes the test runner later.
private struct ResetCountDialog: ViewModifier {
    @Binding var isPresented: Bool
    let onReset: () -> Void
    @Environment(\.snapshotMode) private var snapshot

    func body(content: Content) -> some View {
        if snapshot {
            content
        } else {
            content.confirmationDialog("Count PM starts from zero again?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Reset count", action: onReset)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Cards already started keep running.")
            }
        }
    }
}

/// A row of buttons for one choice, drawn by the panel itself (snapshots cannot draw AppKit's segmented control).
private struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title).font(Tok.Font.small.weight(.semibold))
                        .foregroundStyle(selection == value ? Tok.ink : Tok.ink3)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selection == value ? Tok.raise : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .fixedSize()
    }
}

/// A value with − and + buttons.
private struct Nudge: View {
    let label: String
    let onLess: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: Tok.Space.s) {
            Text(label).font(Tok.Font.body).foregroundStyle(Tok.ink).monospacedDigit()
            HStack(spacing: 0) {
                Button(action: onLess) { Text("−").frame(width: 24, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Less")
                Rectangle().fill(Tok.line).frame(width: 1, height: 14)
                Button(action: onMore) { Text("+").frame(width: 24, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("More")
            }
            .font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink2)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.line))
        }
    }
}

#Preview("Autopilot rules") {
    AutopilotRulesSheet(policy: AutopilotPolicy(), onSave: { _ in }, onCancel: {})
}
