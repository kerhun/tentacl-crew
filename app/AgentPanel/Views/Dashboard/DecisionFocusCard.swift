import SwiftUI
import AppKit

/// The buttons the focus card offers for a Waiting for you item, in footer order. Each runs what the panel already does elsewhere.
enum DecisionFocusAction: Equatable {
    case openCard, terminal, letPMDecide, screenshot, fixNotes, approveMerge, start, approveRound, openRoundSheet, editPlan, notNow, approvePlan,
         initGit, pushGit, dismiss, retry

    var title: String {
        switch self {
        case .openCard: "Open card"
        case .terminal: "Terminal"
        case .letPMDecide: "Let the PM decide"
        case .screenshot: "Screenshot"
        case .fixNotes: "Fix notes…"
        case .approveMerge: "Approve and merge"
        case .start: "Start…"
        case .approveRound: "Approve round"
        case .openRoundSheet: "Open the Round sheet"
        case .editPlan: "Edit"
        case .notNow: "Not now"
        case .approvePlan: "Approve plan & start round"
        case .initGit: "Initialize git…"
        case .pushGit: "Push to GitHub…"
        case .dismiss: "Dismiss"
        case .retry: "Retry"
        }
    }

    /// The main button of the item (filled in its kind's colour).
    var isPrimary: Bool { [.approveMerge, .start, .approveRound, .openRoundSheet, .approvePlan, .initGit, .pushGit, .retry].contains(self) }

    /// What the card offers for `kind`. A question: Open card (not for the PM's own), Terminal, and Let the PM decide where the
    /// question could go to the PM (`pmMayDecide`). A fix shows its own card with its buttons; the footer adds Open card and Terminal.
    static func actions(for kind: DashboardWaitingItem.Kind, isPMQuestion: Bool = false, pmMayDecide: Bool = false) -> [DecisionFocusAction] {
        switch kind {
        case .question: (isPMQuestion ? [] : [.openCard]) + [.terminal] + (pmMayDecide ? [.letPMDecide] : [])
        case .review: [.openCard, .screenshot, .fixNotes, .approveMerge]
        case .fix: [.openCard, .terminal]
        case .startApproval: [.openCard, .start]
        case .approveRound: [.approveRound]
        case .round: [.openRoundSheet]
        case .planRound: [.editPlan, .notNow, .approvePlan]
        case .git(.initializeGit): [.initGit]
        case .git(.pushToGitHub): [.notNow, .pushGit]
        case .undelivered: [.dismiss, .retry]
        }
    }
}

/// The decision in front of the Dashboard (N342): one Waiting for you item at a time, 600 pt wide, with ‹ › through the others.
/// Answering shows the next item; with none left it says "Nothing needs you."
struct DecisionFocusCard: View {
    static let width: CGFloat = 600

    @Bindable var model: PanelModel
    let items: [DashboardWaitingItem]
    @Binding var state: DecisionFocusState
    var onClose: () -> Void = {}
    var onOpen: (String) -> Void = { _ in }
    var onApprove: (TaskCard) -> Void = { _ in }
    var onStart: (TaskCard) -> Void = { _ in }
    var onApproveRound: () -> Void = {}
    var onRequestFix: (TaskCard) -> Void = { _ in }
    /// The agent's screen, for snapshots; the app reads it once when the item shows.
    var terminalText: String? = nil
    /// The "Write my own answer…" field open (snapshots).
    var ownOpen = false

    @State private var screen: String?
    @State private var own = false
    @State private var text = ""
    @FocusState private var keys: Bool
    @FocusState private var field: Bool

    private var current: DashboardWaitingItem? { state.current(in: items) }

    var body: some View {
        VStack(spacing: 0) {
            if let item = current { content(item) } else { done }
        }
        .frame(width: Self.width)
        .background(Tok.pane)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Tok.line))
        .shadow(color: .black.opacity(Tok.shadowOpacity(0.45)), radius: 30, y: 16)
        .focusable().focusEffectDisabled().focused($keys)
        .onAppear { keys = true; own = ownOpen }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(characters: .decimalDigits) { press($0.characters) }
        .escapeCancels { onClose() }
        .onChange(of: items.map(\.id)) { state.sync(items) }
        .onChange(of: state.currentID) { own = false; text = ""; screen = nil }
        .task(id: current.flatMap { model.pane(of: $0) }) { await readScreen() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decision")
        .accessibilityAddTraits(.isModal)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !field, items.count > 1 else { return .ignored }
        state.move(by: step, in: items)
        return .handled
    }

    private func press(_ key: String) -> KeyPress.Result {
        guard !field, let item = current, case .question(let id) = item.kind, let q = question(id), let n = Int(key) else { return .ignored }
        let c = QuestionFocusContent(q)
        if let option = c.answers.first(where: { $0.number == n }), !q.question.isCall { answer(q, option); return .handled }
        if c.ownWords != .none, n == (c.answers.last?.number ?? 0) + 1 { openOwn(); return .handled }
        return .ignored
    }

    private func readScreen() async {
        if let terminalText { screen = terminalText; return }
        guard let item = current, let pane = model.pane(of: item) else { screen = nil; return }
        screen = try? await model.makeReader().screen(of: pane, lines: 40)
    }

    private func question(_ id: String) -> PendingQuestion? { model.questionsForYou.first { $0.id == id } }

    // MARK: header

    private func header(_ item: DashboardWaitingItem) -> some View {
        let text = model.waitingRowText(item)
        return HStack(spacing: 10) {
            Circle().fill(item.tint.color).frame(width: 8, height: 8)
            Text(text.heading.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.55).foregroundStyle(item.tint.color).lineLimit(1)
            Spacer(minLength: 8)
            if items.count > 1 {
                HStack(spacing: 4) {
                    navButton("‹", help: "Previous (←)") { _ = move(-1) }
                    Text(state.position(in: items) ?? "").font(.system(size: 12).monospacedDigit()).foregroundStyle(Tok.ink3)
                    navButton("›", help: "Next (→)") { _ = move(1) }
                }
            }
            navButton("✕", help: "Close (Esc)", action: onClose).accessibilityLabel("Close")
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func navButton(_ label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 14)).foregroundStyle(Tok.ink3).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help)
    }

    // MARK: body

    @ViewBuilder private func content(_ item: DashboardWaitingItem) -> some View {
        header(item)
        Divider().overlay(Tok.line)
        VStack(alignment: .leading, spacing: 14) {
            Text(title(item)).font(.system(size: 19, weight: .semibold)).lineSpacing(3).foregroundStyle(Tok.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let line = contextLine(item) { Text(line).font(.system(size: 12.5)).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true) }
            if let error = model.inbox.error, case .question = item.kind {
                Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
            }
            main(item)
            terminalLines
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider().overlay(Tok.line)
        footer(item)
    }

    private func title(_ item: DashboardWaitingItem) -> String {
        switch item.kind {
        case .question(let id): question(id).map { ReadableQuestion($0).title } ?? ""
        case .undelivered(let id): model.undeliveredMessages.first { $0.id == id }.map { $0.item.text } ?? ""
        case .git(let s): s.title
        default: model.waitingRowText(item).title
        }
    }

    /// "ui_dev · asked 4 min ago · not critical: the PM could answer"
    private func contextLine(_ item: DashboardWaitingItem) -> String? {
        switch item.kind {
        case .question(let id):
            guard let q = question(id) else { return nil }
            var parts = [q.agentLabel]
            if let at = model.inbox.askedAt[q.id] { parts.append("asked \(Stats.durationText(max(Date().timeIntervalSince(at), 0))) ago") }
            if !q.isPM { parts.append(pmMayDecide(q) ? "not critical: the PM could answer" : "critical: yours to decide") }
            return parts.joined(separator: " · ")
        case .review(let id), .startApproval(let id), .fix(let id):
            guard let card = model.card(id: id) else { return nil }
            return [card.agent, card.branch].compactMap { $0 }.joined(separator: " · ")
        case .git(let s): return s.detail
        case .undelivered(let id): return model.undeliveredMessages.first { $0.id == id }.map { "Not delivered: \($0.reason)." }
        case .approveRound: return "Approve them in one go; the sheet lists each card first."
        default: return nil
        }
    }

    private func pmMayDecide(_ q: PendingQuestion) -> Bool {
        guard let id = model.selectedProjectID, model.pmPane(forProject: id) != nil else { return false }
        return QuestionRelay.relayable(q, routing: model.inbox.routing)
    }

    @ViewBuilder private func main(_ item: DashboardWaitingItem) -> some View {
        switch item.kind {
        case .question(let id):
            if let q = question(id) { questionBody(q) }
        case .review(let id):
            if let card = model.card(id: id) { reviewBody(card) }
        case .fix(let id):
            if let fix = model.autopilot.fixesForYou.first(where: { $0.id == id }) { FixCard(fix: fix, autopilot: model.autopilot, tint: item.tint) }
        case .round(let ids):
            Text("Cards: " + ids.joined(separator: ", ")).font(.system(size: 13)).foregroundStyle(Tok.ink2)
        case .planRound:
            if let round = model.round.waitingForYouPlanRound {
                Text(round.reason).font(.system(size: 13)).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                Text("Cards: " + round.cards.joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(Tok.ink3)
                if let blocker = model.approvePlanBlocker(round) { Text(blocker).font(Tok.Font.small).foregroundStyle(Tok.wait) }
                if let message = model.round.approveMessage { Text(message).font(Tok.Font.small).foregroundStyle(Tok.ink2) }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var terminalLines: some View {
        if let screen = screen ?? terminalText, case let lines = lastTerminalLines(screen), !lines.isEmpty {
            Text(lines.joined(separator: "\n")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Tok.ink2).lineSpacing(3)
                .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Tok.bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.line))
                .accessibilityLabel("The agent's last terminal lines")
        }
    }

    // MARK: question

    @ViewBuilder private func questionBody(_ q: PendingQuestion) -> some View {
        let c = QuestionFocusContent(q)
        if q.question.isCall {
            Text("This is a call of several questions; answer them one by one in the question window.").font(.system(size: 13)).foregroundStyle(Tok.ink2)
            Button("Open the question window") { openQuestionWindow(q) }.buttonStyle(ConfirmButtonStyle(fill: WaitingTint.question.color))
        } else if c.terminalOnly {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(q.question.options.filter { !$0.isSpecial }, id: \.number) { Text($0.label).font(.system(size: 13)).foregroundStyle(Tok.ink2) }
                Text("Answer in \(q.isPM ? "the PM" : "the agent")'s terminal.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                if let tool = q.question.signInTool {
                    Button("Sign in to \(SignInGate.name(tool))") { Task { await model.inbox.signIn(for: q) } }.buttonStyle(ConfirmButtonStyle())
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(c.answers, id: \.number) { option in optionRow(q, option) }
                if c.ownWords != .none {
                    Button { openOwn() } label: {
                        optionLabel(number: (c.answers.last?.number ?? 0) + 1, title: c.ownWords == .reply ? "Write your answer…" : "Write my own answer…", detail: nil, tag: nil)
                    }
                    .buttonStyle(.plain).disabled(model.inbox.sending)
                }
            }
            if own || c.answers.isEmpty && c.ownWords != .none { ownField(q, c) }
        }
    }

    private func optionRow(_ q: PendingQuestion, _ option: QuestionOption) -> some View {
        let suggested = model.autopilot.suggestion(for: q)?.option == option.number
        let tag: String? = suggested ? "PM suggests" : ReadableQuestion.isRecommended(option.label) ? "Recommended" : nil
        return Button { answer(q, option) } label: {
            optionLabel(number: option.number, title: ReadableQuestion.stripRecommended(option.label),
                        detail: option.detail.isEmpty || option.detail == option.label ? nil : option.detail, tag: tag)
        }
        .buttonStyle(.plain).disabled(model.inbox.sending).opacity(model.inbox.sending ? 0.45 : 1)
        .help("Answer \(option.number) (\(option.number) key)")
    }

    private func optionLabel(number: Int, title: String, detail: String?, tag: String?) -> some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tok.ink3)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Tok.raise, in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(Tok.line))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Tok.ink)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Tok.ink3).lineLimit(2) }
            }
            Spacer(minLength: 6)
            if let tag {
                Text(tag).font(.system(size: 11)).foregroundStyle(WaitingTint.question.color)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .overlay(Capsule().stroke(WaitingTint.question.color.opacity(0.4)))
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.line))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func ownField(_ q: PendingQuestion, _ c: QuestionFocusContent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            FieldText(text: $text, placeholder: "Your answer to \(q.isPM ? "the PM" : q.agentLabel)…").focused($field)
            Button("Send answer") {
                let typed = text
                Task {
                    let sent: Bool
                    switch c.ownWords {
                    case .reply: sent = await model.inbox.answer(q, text: typed)
                    case .typed: sent = await model.inbox.answerTyped(q, text: typed)
                    default: sent = await model.inbox.feedback(q, text: typed)
                    }
                    if sent { text = ""; own = false; field = false; keys = true }
                }
            }
            .buttonStyle(ConfirmButtonStyle(fill: WaitingTint.question.color)).disabled(!canSendAnswer(text: text, sending: model.inbox.sending))
        }
    }

    private func openOwn() { own = true; field = true }

    private func answer(_ q: PendingQuestion, _ option: QuestionOption) {
        guard !model.inbox.sending else { return }
        Task { await model.inbox.answer(q, option: option) }
    }

    private func openQuestionWindow(_ q: PendingQuestion) {
        let open = items.compactMap { item -> PendingQuestion? in if case .question(let id) = item.kind { question(id) } else { nil } }
        onClose()
        model.inbox.openFocus(q, in: open)
    }

    // MARK: review

    @ViewBuilder private func reviewBody(_ card: TaskCard) -> some View {
        let lines = reviewReportSummary(card.sections["Report"] ?? "")
        if lines.isEmpty {
            Text("The Report is empty.").font(.system(size: 13)).foregroundStyle(Tok.ink3)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.label) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(line.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.ink3).frame(width: 52, alignment: .leading)
                        Text(line.text).font(.system(size: 13)).foregroundStyle(Tok.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: footer

    private func footer(_ item: DashboardWaitingItem) -> some View {
        let q: PendingQuestion? = { if case .question(let id) = item.kind { return question(id) } else { return nil } }()
        let actions = DecisionFocusAction.actions(for: item.kind, isPMQuestion: q?.isPM ?? false, pmMayDecide: q.map(pmMayDecide) ?? false)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(actions.filter { !$0.isPrimary && $0 != .letPMDecide && $0 != .fixNotes }, id: \.title) { button($0, item) }
                Spacer(minLength: 8)
                ForEach(actions.filter { $0.isPrimary || $0 == .letPMDecide || $0 == .fixNotes }, id: \.title) { button($0, item) }
            }
            Text(hint(item, q)).font(.system(size: 11.5)).foregroundStyle(Tok.ink3)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.bg)
    }

    private func hint(_ item: DashboardWaitingItem, _ q: PendingQuestion?) -> String {
        var parts: [String] = []
        if let q, !q.question.isCall {
            let c = QuestionFocusContent(q)
            let last = (c.answers.last?.number ?? 0) + (c.ownWords == .none ? 0 : 1)
            if last > 0 { parts.append(last == 1 ? "1 answers" : "1–\(last) answer") }
        }
        if items.count > 1 { parts.append("← → other items") }
        parts.append("Esc close")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func button(_ action: DecisionFocusAction, _ item: DashboardWaitingItem) -> some View {
        let s = state(of: action, item)
        let fill: Color? = action == .approveMerge ? Tok.go : action == .fixNotes ? Tok.waitFix : action.isPrimary ? item.tint.color : nil
        Group {
            if let fill {
                Button(action.title) { run(action, item) }.buttonStyle(ConfirmButtonStyle(fill: fill))
            } else {
                Button(action.title) { run(action, item) }.buttonStyle(PanelButtonStyle())
            }
        }
        .disabled(!s.enabled).help(s.help)
    }

    private func state(of action: DecisionFocusAction, _ item: DashboardWaitingItem) -> StartButtonState {
        let ok = { (help: String) in StartButtonState(enabled: true, help: help) }
        switch (action, item.kind) {
        case (.approveMerge, .review(let id)):
            guard let card = model.card(id: id) else { return StartButtonState(enabled: false, help: "") }
            return reviewButtonStates(card: card, canAct: model.reviewDisabledReason == nil, reason: model.reviewDisabledReason,
                                      busy: model.isBusy, agentWorking: model.phase(of: card) == .working).approve
        case (.fixNotes, .review(let id)):
            guard let card = model.card(id: id) else { return StartButtonState(enabled: false, help: "") }
            return reviewButtonStates(card: card, canAct: model.reviewDisabledReason == nil, reason: model.reviewDisabledReason,
                                      busy: model.isBusy, agentWorking: model.phase(of: card) == .working).requestFix
        case (.start, .startApproval(let id)):
            guard let card = model.card(id: id) else { return StartButtonState(enabled: false, help: "") }
            return startButtonState(card: card, canStart: model.startDisabledReason(for: card) == nil, reason: model.startDisabledReason(for: card), busy: model.isBusy,
                                    dependencies: model.dependencyGraph.state(of: card.id))
        case (.screenshot, .review(let id)):
            let has = model.card(id: id).map { !screenshots($0).isEmpty } ?? false
            return StartButtonState(enabled: has, help: has ? "Open the card's newest screenshot" : "The card has no screenshot")
        case (.approveRound, _):
            return StartButtonState(enabled: !model.isBusy, help: "Approve every task that is in review in one go")
        case (.approvePlan, _):
            guard let round = model.round.waitingForYouPlanRound else { return StartButtonState(enabled: false, help: "") }
            let blocker = model.approvePlanBlocker(round)
            return StartButtonState(enabled: blocker == nil, help: blocker ?? "Approve the plan and start the round's cards")
        case (.terminal, _):
            return model.pane(of: item) == nil ? StartButtonState(enabled: false, help: "No agent runs for this item") : ok("Open the agent's terminal")
        case (.letPMDecide, _): return ok("Sends the question to the PM's chat; it stays here until it is answered")
        case (.openCard, _): return ok("Open the card on the Tasks screen")
        case (.pushGit, _): return ok("Nothing is pushed from here; the sheet says what happens")
        case (.initGit, _): return ok("Choose the files for the first commit; nothing is committed until you confirm")
        case (.retry, _): return ok("Send it again now; it waits for the agent if it is busy")
        case (.dismiss, _): return ok("Forget this message")
        case (.notNow, _): return ok("Hide this until it changes")
        default: return ok("")
        }
    }

    private func screenshots(_ card: TaskCard) -> [URL] {
        guard let dir = model.selectedProject?.dataURL else { return [] }
        return CardRepository(dataDir: dir).screenshots(for: card)
    }

    private func cardID(_ item: DashboardWaitingItem) -> String? {
        switch item.kind {
        case .question(let id): question(id).map(\.cardID)
        case .review(let id), .startApproval(let id), .fix(let id): id
        default: nil
        }
    }

    private func run(_ action: DecisionFocusAction, _ item: DashboardWaitingItem) {
        let card: TaskCard? = cardID(item).flatMap { model.card(id: $0) }
        switch action {
        case .openCard: if let id = cardID(item), !id.isEmpty { onClose(); onOpen(id) }
        case .terminal:
            if case .question(let id) = item.kind, let q = question(id) { Task { await model.inbox.openPane(of: q) } }
            else if let pane = model.pane(of: item) { model.openTerminalTab(pane) }
        case .letPMDecide:
            if case .question(let id) = item.kind, let q = question(id), let project = model.selectedProjectID, let pane = model.pmPane(forProject: project) {
                Task { await model.tellPM(pane: pane, passOnToPMText(q)) }
            }
        case .screenshot: if let card, let shot = screenshots(card).last { NSWorkspace.shared.open(shot) }
        case .fixNotes: if let card { onClose(); onRequestFix(card) }
        case .approveMerge: if let card { onClose(); onApprove(card) }
        case .start: if let card { onClose(); onStart(card) }
        case .approveRound: onClose(); onApproveRound()
        case .openRoundSheet: onClose(); model.round.reopen()
        case .editPlan: if let round = model.round.waitingForYouPlanRound { onClose(); model.editPlan(round) }
        case .approvePlan: if let round = model.round.waitingForYouPlanRound { Task { await model.approvePlan(round) } }
        case .notNow:
            if case .planRound = item.kind, let round = model.round.waitingForYouPlanRound { model.round.notNow(round) }
            else if case .git = item.kind, let id = model.selectedProjectID { model.gitSetup.notNow(id) }
        case .initGit: if let project = model.selectedProject { onClose(); Task { await model.gitSetup.openInitGit(project) } }
        case .pushGit: if let project = model.selectedProject { onClose(); Task { await model.gitSetup.openPush(project) } }
        case .retry: if case .undelivered(let id) = item.kind { Task { await model.retryUndelivered(id) } }
        case .dismiss: if case .undelivered(let id) = item.kind { model.dismissUndelivered(id) }
        }
    }

    // MARK: empty

    private var done: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ALL DONE").font(.system(size: 11, weight: .semibold)).kerning(0.55).foregroundStyle(Tok.go)
                Spacer()
                navButton("✕", help: "Close (Esc)", action: onClose).accessibilityLabel("Close")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Tok.line)
            VStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(Tok.go)
                    .frame(width: 40, height: 40).background(Tok.go.opacity(0.15), in: Circle())
                Text(Self.emptyText).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tok.ink)
                Text("The PM carries on. Esc closes.").font(.system(size: 12.5)).foregroundStyle(Tok.ink3)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
            .contentShape(Rectangle()).onTapGesture(perform: onClose)
        }
    }

    static let emptyText = "Nothing needs you."
}
