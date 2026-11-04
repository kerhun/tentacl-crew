import SwiftUI
import AppKit

/// What the question window shows for one question (N183), worked out without a view so each kind can be tested.
struct QuestionFocusContent {
    enum OwnWords: Equatable {
        case none
        /// Plan "Tell Claude what to change" or a permission's "No, and tell Claude…": sent by the question's `FeedbackPath`.
        case feedback
        /// A free-text question: the typed answer goes in as a prompt.
        case reply
        /// A menu with "Type something.": the text is typed into that option (one tab of a call that is answered one by one).
        case typed
    }

    let kindLabel: String
    /// "The plan", "Why it asks"; the context is shown whole.
    let contextLabel: String
    let context: String
    /// A permission's command or diff, shown as code.
    let code: String?
    let text: String
    /// A permission's command reads in monospace.
    let mono: Bool
    /// The options answered with one key, in the menu's numbers.
    let answers: [QuestionOption]
    let ownWords: OwnWords
    let terminalOnly: Bool

    init(_ pending: PendingQuestion) {
        let q = pending.question
        switch q.kind {
        case .plan: kindLabel = "Plan approval"; contextLabel = "The plan"
        case .permission: kindLabel = "Permission"; contextLabel = "Why it asks"
        case .choice, .freeText: kindLabel = "Question"; contextLabel = "Context"
        case .signIn: kindLabel = "Sign-in"; contextLabel = "Context"
        }
        context = q.context.trimmingCharacters(in: .whitespacesAndNewlines)
        text = q.title.isEmpty || q.text.hasPrefix(q.title) ? q.text : q.title + "\n" + q.text
        code = q.code
        mono = q.kind == .permission && q.code == nil
        terminalOnly = q.terminalOnly
        answers = q.terminalOnly ? [] : q.options.filter { !$0.isSpecial }
        if q.terminalOnly { ownWords = .none }
        else if q.kind == .freeText { ownWords = .reply }
        else if (q.kind == .plan || q.kind == .permission), q.feedbackPath != nil { ownWords = .feedback }
        else if q.typeNumber != nil { ownWords = .typed }
        else { ownWords = .none }
    }

    /// The footer's key hints; ←/→ only when there is another question to move to.
    func keyHint(questions: Int) -> String {
        var parts: [String] = []
        if let last = answers.last?.number, let first = answers.first?.number { parts.append(first == last ? "\(first) answers" : "\(first)–\(last) answers") }
        else if ownWords == .reply { parts.append("Type your answer") }
        if questions > 1 { parts.append("←/→ next question") }
        parts.append("Esc later")
        return parts.joined(separator: " · ")
    }

    /// The footer's key hints for a call of several questions, from where the user is in it.
    static func callHint(_ draft: CallDraft, options: Int) -> String {
        var parts: [String]
        if draft.isSummary { parts = ["Enter sends all answers", "← back"] }
        else { parts = ["1–\(options) answers", draft.step > 0 ? "←/→ back and forth" : "→ next"] }
        parts.append("Esc later")
        return parts.joined(separator: " · ")
    }

    /// The first non-empty line, for the list item.
    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}

/// The question window (N183, design "D"): one open question in full, with ‹ › through the others. Answers go through the same
/// paths as the list (`AgentInboxModel.answer`, `.feedback`); the model's `QuestionFocus` follows the list while it is open.
struct QuestionFocusSheet: View {
    static let width: CGFloat = 860
    static let height: CGFloat = 780

    @Bindable var inbox: AgentInboxModel
    /// The open questions in the order Waiting for you lists them.
    let questions: [PendingQuestion]
    /// The question to show; the window follows `inbox.focus` when this is nil (snapshots pass one).
    var shown: PendingQuestion? = nil
    var suggestion: (PendingQuestion) -> PMSuggestion? = { _ in nil }
    /// The autopilot's reason for handing the question back to the user.
    var escalation: (PendingQuestion) -> String? = { _ in nil }
    var cardTitle: (String) -> String? = { _ in nil }
    var waited: (PendingQuestion) -> String? = { _ in nil }
    /// Pass on to the PM; nil when the project has no PM to pass it to.
    var onPassOn: ((PendingQuestion) -> Void)? = nil
    /// "Always allow in this project" (N213): saves a rule for this prompt's command and answers it once; nil when the project has no autopilot.
    var onAlwaysAllow: ((PendingQuestion) -> Void)? = nil
    /// The rule that button would save, or nil when this prompt cannot have one.
    var rulePattern: (PendingQuestion) -> String? = { PermissionRules.pattern(for: $0.question) }
    /// The window is never taller than the main window.
    var maxHeight: CGFloat = QuestionFocusSheet.height
    /// Shows the Details block open (snapshots).
    var detailsOpen = false

    @State private var text = ""
    @FocusState private var keys: Bool
    @Environment(\.snapshotMode) private var snapshot

    private var current: PendingQuestion? { shown ?? inbox.focus?.current(in: questions) }

    var body: some View {
        VStack(spacing: 0) {
            if let current {
                let content = QuestionFocusContent(current)
                header(current, content)
                Divider().overlay(Tok.line)
                // The snapshot renderer draws no ScrollView content: snapshots show the body as it is.
                if snapshot { main(current, content).padding(Tok.Space.xl).frame(maxHeight: .infinity, alignment: .top) }
                else { ScrollView { main(current, content).padding(Tok.Space.xl) } }
                Divider().overlay(Tok.line)
                footer(current, content)
            }
        }
        .frame(width: Self.width, height: min(Self.height, maxHeight))
        .background(Tok.pane)
        .overlay(alignment: .top) { Rectangle().fill(WaitingTint.question.color).frame(height: 4) }
        .focusable().focusEffectDisabled().focused($keys)
        .onAppear { keys = true }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.return) { sendCall() }
        .onKeyPress(characters: .decimalDigits) { press($0.characters) }
        .escapeCancels { inbox.closeFocus() }
        .onChange(of: questions.map(\.id)) { inbox.syncFocus(questions) }
        .onChange(of: inbox.focus?.currentID) { text = "" }
        .onChange(of: current.flatMap { inbox.callDraft(for: $0) }?.step) { text = ownText }
    }

    /// The typed answer of the call's current question, when it has one.
    private var ownText: String {
        guard let current, let draft = inbox.callDraft(for: current), draft.step < draft.answers.count, case .text(let t)? = draft.answers[draft.step] else { return "" }
        return t
    }

    private func move(_ step: Int) -> KeyPress.Result {
        // A call of several questions: ← and → go through its own questions; the list's ‹ › buttons move to the other items.
        if let current, current.question.isCall { inbox.moveInCall(current, by: step); return .handled }
        guard questions.count > 1 else { return .ignored }
        inbox.moveFocus(by: step, in: questions)
        return .handled
    }

    private func sendCall() -> KeyPress.Result {
        guard let current, current.question.isCall, !inbox.sending, let answers = inbox.callDraft(for: current)?.complete, inbox.callDraft(for: current)?.isSummary == true else { return .ignored }
        Task { await inbox.answerCall(current, answers: answers) }
        return .handled
    }

    private func press(_ key: String) -> KeyPress.Result {
        if let current, let call = current.question.call {
            guard let n = Int(key), let draft = inbox.callDraft(for: current), !draft.isSummary, call.items[draft.step].options.indices.contains(n - 1) else { return .ignored }
            inbox.chooseInCall(current, .option(n))
            return .handled
        }
        guard let current, let n = Int(key), let option = QuestionFocusContent(current).answers.first(where: { $0.number == n }), !inbox.sending else { return .ignored }
        Task { await inbox.answer(current, option: option) }
        return .handled
    }

    // MARK: header

    private func header(_ q: PendingQuestion, _ c: QuestionFocusContent) -> some View {
        HStack(alignment: .center, spacing: Tok.Space.m) {
            Text(c.kindLabel).font(Tok.Font.small.weight(.bold)).foregroundStyle(Tok.bg)
                .padding(.horizontal, 10).padding(.vertical, 4).background(WaitingTint.question.color, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(q.agentLabel).font(Tok.Font.heading).foregroundStyle(Tok.ink).lineLimit(1)
                Text(subtitle(q)).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1)
            }
            Spacer(minLength: Tok.Space.m)
            if questions.count > 1 {
                Button { _ = move(-1) } label: { Text("‹").font(Tok.Font.heading) }.buttonStyle(PanelButtonStyle()).help("Previous question (←)")
                Text(inbox.focus?.position(in: questions) ?? shown.flatMap { s in questions.firstIndex(of: s).map { "\($0 + 1) of \(questions.count)" } } ?? "")
                    .font(Tok.Font.small.monospacedDigit()).foregroundStyle(Tok.ink2)
                Button { _ = move(1) } label: { Text("›").font(Tok.Font.heading) }.buttonStyle(PanelButtonStyle()).help("Next question (→)")
            }
            Button { inbox.closeFocus() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Tok.ink3).help("Later (Esc)")
        }
        .padding(.horizontal, Tok.Space.xl).padding(.top, Tok.Space.l + 4).padding(.bottom, Tok.Space.l)
    }

    private func subtitle(_ q: PendingQuestion) -> String {
        var parts: [String] = []
        if q.isPM { parts.append("PM") } else if !q.cardID.isEmpty { parts.append(q.cardID) }
        if !q.isPM, let title = cardTitle(q.cardID), !title.isEmpty { parts.append(title) }
        if let waited = waited(q) { parts.append("waiting " + waited) }
        return parts.joined(separator: " · ")
    }

    // MARK: main

    private func main(_ q: PendingQuestion, _ c: QuestionFocusContent) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.l + 4) {
            if let note = inbox.focus?.note { Text(note).font(Tok.Font.small).foregroundStyle(Tok.ink2) }
            if let error = inbox.error { Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
            if q.question.isCall {
                if !c.context.isEmpty { QuestionBody(text: c.context, font: .system(size: 14), color: Tok.ink2, maxCodeHeight: 320).lineSpacing(5) }
                if let code = c.code { QuestionCode(code: code, maxHeight: 320, font: .system(size: 13, design: .monospaced)) }
            } else {
                Text(ReadableQuestion(q).title).font(.system(size: 20, weight: .semibold)).lineSpacing(4).foregroundStyle(Tok.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !ReadableQuestion(q).subtitle.isEmpty {
                    Text(ReadableQuestion(q).subtitle).font(Tok.Font.body).foregroundStyle(Tok.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let escalation = escalation(q) { Text(escalation).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
            if let s = suggestion(q) { PMSuggestionBox(suggestion: s) }
            if let call = q.question.call, let draft = inbox.callDraft(for: q) {
                callBody(q, call, draft)
            } else if c.terminalOnly {
                VStack(alignment: .leading, spacing: Tok.Space.xs) {
                    ForEach(q.question.options.filter { !$0.isSpecial }, id: \.number) { Text($0.label).font(Tok.Font.body).foregroundStyle(Tok.ink2) }
                    Text("Answer in \(q.isPM ? "the PM" : "the agent")'s terminal.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    if let tool = q.question.signInTool { Button("Sign in to \(SignInGate.name(tool))") { Task { await inbox.signIn(for: q) } }.buttonStyle(ConfirmButtonStyle()) }
                }
            } else {
                answers(q, c)
                ownWords(q, c)
            }
            if !q.question.isCall {
                // The plan is what the user approves: its Details start open.
                QuestionDetails(text: ReadableQuestion(q).details, open: detailsOpen || ReadableQuestion.detailsOpenByDefault(q.question.kind), maxHeight: 360)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: a call of several questions (N188)

    @ViewBuilder private func callBody(_ q: PendingQuestion, _ call: AskCall, _ draft: CallDraft) -> some View {
        if draft.isSummary { callSummary(q, call, draft) } else { callStep(q, call, draft) }
    }

    private func callStep(_ q: PendingQuestion, _ call: AskCall, _ draft: CallDraft) -> some View {
        let item = call.items[draft.step]
        return VStack(alignment: .leading, spacing: Tok.Space.l) {
            label("Question \(draft.step + 1) of \(call.items.count) · \(item.header)")
            Text(item.question).font(.system(size: 20, weight: .semibold)).lineSpacing(4).foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                    let picked = draft.answers[draft.step] == .option(index + 1)
                    Button { inbox.chooseInCall(q, .option(index + 1)) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(WaitingTint.question.color)
                                .frame(width: 28, height: 28).background(WaitingTint.question.color.opacity(WaitingTint.chipOpacity), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tok.ink)
                                if !option.description.isEmpty, option.description != option.label { Text(option.description).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2) }
                            }
                            Spacer(minLength: 0)
                            if picked { Image(systemName: "checkmark").foregroundStyle(WaitingTint.question.color) }
                        }
                        .padding(.horizontal, Tok.Space.l).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(Tok.raise, in: RoundedRectangle(cornerRadius: Tok.radius))
                        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(picked ? WaitingTint.question.color : Tok.line, lineWidth: picked ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: Tok.radius))
                    }
                    .buttonStyle(.plain).disabled(inbox.sending)
                    .help("Pick \(index + 1) (\(index + 1) key); nothing is sent yet")
                }
            }
            if item.canType { VStack(alignment: .leading, spacing: Tok.Space.s) {
                label("Or answer in your own words")
                HStack(alignment: .top, spacing: Tok.Space.s) {
                    FieldText(text: $text, placeholder: "Your answer")
                    Button("Use") { inbox.chooseInCall(q, .text(text.trimmingCharacters(in: .whitespacesAndNewlines))) }
                        .buttonStyle(ConfirmButtonStyle(fill: WaitingTint.question.color))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.contains(where: \.isNewline))
                }
            } }
            callNav(q, draft)
        }
    }

    private func callNav(_ q: PendingQuestion, _ draft: CallDraft) -> some View {
        HStack(spacing: Tok.Space.s) {
            Button("‹ Back") { inbox.moveInCall(q, by: -1) }.buttonStyle(PanelButtonStyle()).disabled(draft.step == 0).help("Previous question (←)")
            Button("Next ›") { inbox.moveInCall(q, by: 1) }.buttonStyle(PanelButtonStyle())
                .disabled(draft.step >= draft.answers.count || draft.answers[draft.step] == nil).help("Next question (→)")
            Spacer(minLength: 0)
        }
    }

    private func callSummary(_ q: PendingQuestion, _ call: AskCall, _ draft: CallDraft) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            label("Your answers")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(call.items.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Divider().overlay(Tok.line) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.question).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                        Text(draft.answers[i].map { call.words($0, at: i) } ?? "").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tok.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Tok.bg, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            Text("Nothing has gone to \(q.isPM ? "the PM" : q.agentLabel) yet. Send answers all questions and submits them.").font(Tok.Font.small).foregroundStyle(Tok.ink2)
            HStack(spacing: Tok.Space.s) {
                Button("‹ Back") { inbox.moveInCall(q, by: -1) }.buttonStyle(PanelButtonStyle())
                Spacer(minLength: 0)
                Button("Cancel") { inbox.clearCallDraft(q); inbox.closeFocus() }.buttonStyle(PanelButtonStyle())
                    .help("Throws the answers away; the agent is not touched and the question stays in Waiting for you")
                Button("Send") { if let answers = draft.complete { Task { await inbox.answerCall(q, answers: answers) } } }
                    .buttonStyle(ConfirmButtonStyle(fill: WaitingTint.question.color)).disabled(inbox.sending || !draft.isComplete)
                    .help("Sends every answer and Submit to the agent (Enter)")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(Tok.Font.small.weight(.semibold)).tracking(0.7).foregroundStyle(Tok.ink2)
    }

    private func answers(_ q: PendingQuestion, _ c: QuestionFocusContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(c.answers, id: \.number) { option in
                Button { Task { await inbox.answer(q, option: option) } } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(option.number)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(WaitingTint.question.color)
                            .frame(width: 28, height: 28).background(WaitingTint.question.color.opacity(WaitingTint.chipOpacity), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: Tok.Space.s) {
                                Text(ReadableQuestion.stripRecommended(option.label)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tok.ink)
                                if ReadableQuestion.isRecommended(option.label) { Text("Recommended").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work) }
                            }
                            if !option.detail.isEmpty, option.detail != option.label {
                                Text(option.detail).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2)
                            }
                            if option.role == .allowAlways { Text(alwaysAllowWarning).font(Tok.Font.small).foregroundStyle(Tok.stop).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tok.Space.l).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: Tok.radius))
                    .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(option.role == .allowAlways ? Tok.stop.opacity(0.7) : suggestion(q)?.option == option.number || (suggestion(q) == nil && ReadableQuestion.isRecommended(option.label)) ? Tok.work : Tok.line,
                                                                                lineWidth: suggestion(q)?.option == option.number ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: Tok.radius))
                }
                .buttonStyle(.plain).disabled(inbox.sending).opacity(inbox.sending ? 0.45 : 1)
                .help("Answer \(option.number) (\(option.number) key)")
            }
            if let pattern = rulePattern(q), PermissionRules.answer(for: q.question) != nil {
                HStack(spacing: Tok.Space.m) {
                    Button("Always allow in this project") { onAlwaysAllow?(q) }.buttonStyle(PanelButtonStyle()).disabled(onAlwaysAllow == nil || inbox.sending)
                        .help(onAlwaysAllow == nil ? "This project has no autopilot." : "Answers Yes this once and saves \(pattern); the autopilot then answers Yes to it by itself. Remove it in PM autopilot rules.")
                    Text(pattern).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink3).lineLimit(1).truncationMode(.middle)
                }
            }
            if q.question.options.contains(where: \.isSpecial), c.ownWords == .none, !c.answers.isEmpty {
                Text(q.question.kind == .plan ? "To ask for changes, use the agent's terminal." : "Other answers: use the agent's terminal.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
    }

    @ViewBuilder private func ownWords(_ q: PendingQuestion, _ c: QuestionFocusContent) -> some View {
        if c.ownWords != .none {
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                label(c.ownWords == .reply ? "Your answer" : "Or answer in your own words")
                if c.ownWords == .reply, let suggested = suggestion(q)?.text {
                    Button("Send PM's answer") { Task { await inbox.answer(q, text: suggested) } }.buttonStyle(ConfirmButtonStyle()).disabled(inbox.sending)
                }
                HStack(alignment: .top, spacing: Tok.Space.s) {
                    FieldText(text: $text, placeholder: placeholder(q))
                    Button("Send") {
                        let typed = text
                        Task {
                            let sent: Bool
                            switch c.ownWords {
                            case .reply: sent = await inbox.answer(q, text: typed)
                            case .typed: sent = await inbox.answerTyped(q, text: typed)
                            default: sent = await inbox.feedback(q, text: typed)
                            }
                            if sent { text = "" }
                        }
                    }
                    .buttonStyle(ConfirmButtonStyle(fill: WaitingTint.question.color)).disabled(!canSendAnswer(text: text, sending: inbox.sending))
                }
            }
        }
    }

    private func placeholder(_ q: PendingQuestion) -> String {
        switch q.question.kind {
        case .plan: "What should change in the plan?"
        case .permission: "What should Claude do instead?"
        case .choice, .freeText, .signIn: "Your answer"
        }
    }

    // MARK: footer

    private func footer(_ q: PendingQuestion, _ c: QuestionFocusContent) -> some View {
        HStack(spacing: Tok.Space.s) {
            Button(q.isPM ? "Open PM" : "Open terminal") { Task { await inbox.openPane(of: q) } }.buttonStyle(PanelButtonStyle())
            if !c.terminalOnly, !q.isPM {
                Button("Pass on to the PM") { onPassOn?(q) }.buttonStyle(PanelButtonStyle()).disabled(onPassOn == nil)
                    .help(onPassOn == nil ? "This project has no PM session." : "Sends the question to the PM's chat; it stays here until it is answered")
            }
            Spacer(minLength: Tok.Space.m)
            Text(q.question.isCall ? QuestionFocusContent.callHint(inbox.callDraft(for: q) ?? CallDraft(count: 1), options: q.question.call.map { $0.items[min(inbox.callDraft(for: q)?.step ?? 0, $0.items.count - 1)].options.count } ?? 2) : c.keyHint(questions: questions.count)).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1)
            Button("Later") { inbox.closeFocus() }.buttonStyle(PanelButtonStyle()).help("Closes the window; the question stays in Waiting for you (Esc)")
        }
        .padding(.horizontal, Tok.Space.xl).padding(.vertical, Tok.Space.l)
    }
}

/// What "Pass on to the PM" writes in the PM's chat: who asks, the question and its answers, and that the user wants the PM to decide.
func passOnToPMText(_ q: PendingQuestion) -> String {
    if let call = q.question.call {
        let asks = call.items.enumerated().map { i, item in
            "\(i + 1). \(item.question) Answers: " + item.options.enumerated().map { "\($0 + 1). \($1.label)" }.joined(separator: "; ") + "."
        }.joined(separator: " ")
        return "\(q.agentLabel)\(q.cardID.isEmpty ? "" : " (\(q.cardID))") asks \(call.items.count) questions in one call: \(asks) Please decide and answer them in its pane, or tell me what to answer."
    }
    let answers = q.question.options.filter { !$0.isSpecial }.map { "\($0.number). \($0.label)" }.joined(separator: "; ")
    let asks = q.question.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    return "\(q.agentLabel)\(q.cardID.isEmpty ? "" : " (\(q.cardID))") asks: \(asks)" + (answers.isEmpty ? "" : " Answers: \(answers).")
        + " Please decide and answer it in its pane, or tell me what to answer."
}
