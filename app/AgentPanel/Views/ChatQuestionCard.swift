import SwiftUI

/// What the chat's question card says and offers (pure, so it can be tested without a view).
enum ChatQuestionContent {
    struct Action: Equatable {
        enum Kind: Equatable { case allow, always, denyWithNote, deny, plain }
        let kind: Kind
        let label: String
        let option: QuestionOption
    }

    /// "the PM" or the agent's label: who gets the answer.
    static func who(_ p: PendingQuestion) -> String { p.isPM ? "the PM" : p.agentLabel }

    static func title(_ p: PendingQuestion) -> String {
        let asker = p.isPM ? "PM" : p.agentLabel
        switch p.question.kind {
        case .permission: return "\(asker) needs your permission"
        case .plan: return "\(p.isPM ? "The PM" : p.agentLabel) has a plan"
        case .signIn: return "\(asker) needs a sign-in"
        case .choice, .freeText: return p.question.title.isEmpty ? "\(asker) asks you" : "Question · \(p.question.title)"
        }
    }

    /// What a permission is for: "Run a shell command", "Edit a file"; nil for the other kinds.
    static func what(_ q: AgentQuestion) -> String? {
        guard q.kind == .permission else { return nil }
        if q.command != nil || q.title.localizedCaseInsensitiveContains("bash") { return "Run a shell command" }
        let said = q.title + " " + q.text
        if ["file", "edit", "create", "write"].contains(where: { said.localizedCaseInsensitiveContains($0) }) { return "Edit a file" }
        return q.title.isEmpty ? nil : q.title
    }

    /// The permission's buttons, one per option the panel can press, named by the option's role.
    static func actions(_ p: PendingQuestion) -> [Action] {
        let q = p.question
        // The first "Yes" is Allow; a later one ("Yes, and switch to accept edits … for this session") widens it, like an always.
        let firstAllow = q.options.first { !$0.isSpecial && $0.role == .allow }?.number
        return q.options.filter { !$0.isSpecial }.map { o in
            switch o.role {
            case .allow where o.number == firstAllow: return Action(kind: .allow, label: "Allow", option: o)
            case .allow: return Action(kind: .always, label: alwaysLabel(o.label), option: o)
            case .allowAlways: return Action(kind: .always, label: alwaysLabel(o.label), option: o)
            case .deny:
                return q.feedbackPath != nil ? Action(kind: .denyWithNote, label: "Deny and tell \(who(p))…", option: o) : Action(kind: .deny, label: "Deny", option: o)
            case .plain: return Action(kind: .plain, label: ReadableQuestion.stripRecommended(o.label), option: o)
            }
        }
    }

    /// "Yes, and don't ask again for git log commands in …" → "Allow “git log” always".
    static func alwaysLabel(_ label: String) -> String {
        if let r = label.range(of: #"don't ask again for (.+?) commands"#, options: .regularExpression) {
            let what = label[r].replacingOccurrences(of: "don't ask again for ", with: "").replacingOccurrences(of: " commands", with: "")
            return "Allow “\(what)” always"
        }
        if label.localizedCaseInsensitiveContains("edits") { return "Allow edits this session" }
        if label.localizedCaseInsensitiveContains("access to") { return "Allow this folder always" }
        return "Allow always"
    }

    /// The first lines of a plan, and how many lines it has in all.
    static func planHead(_ q: AgentQuestion, lines: Int = 4) -> (head: String, total: Int) {
        let all = q.context.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (all.prefix(lines).joined(separator: "\n"), all.count)
    }

    /// The one line the card turns into after an answer: "You allowed" + the command, "You answered" + the answer.
    static func answered(_ a: SentAnswer) -> (verb: String, detail: String) {
        let q = a.question.question
        let feedback = a.sent.hasPrefix("feedback: ")
        let words = feedback ? String(a.sent.dropFirst("feedback: ".count)) : a.sent
        let option = q.options.first { $0.label == a.sent }
        switch q.kind {
        case .permission:
            let what = (q.command ?? q.code ?? ReadableQuestion(q).title).components(separatedBy: "\n").first ?? ""
            if feedback { return ("You denied", what + " · " + words) }
            return (option?.role == .deny ? "You denied" : "You allowed", what)
        case .plan:
            if feedback { return ("You asked for changes", words) }
            return ("You approved", ReadableQuestion.stripRecommended(words))
        case .choice, .freeText, .signIn:
            return ("You answered", ReadableQuestion.stripRecommended(words))
        }
    }

    /// "0:42", "12:05".
    static func waited(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// The option a digit key picks (N293), the number the terminal gives it: a choice's option, a permission's button, a plan's
    /// Approve or other button, or the plan's "Tell Claude what to change" when the note can be written. Nil when the digit has none.
    static func digitOption(_ p: PendingQuestion, _ n: Int) -> QuestionOption? {
        let q = p.question
        guard !q.terminalOnly, !q.isCall, q.kind != .freeText,
              let o = q.options.first(where: { !$0.isSpecial && $0.number == n }) else { return nil }
        if q.kind == .plan, o.label.hasPrefix("Tell Claude what to change"), q.feedbackPath == nil { return nil }
        return o
    }

    /// How long the answered line stays.
    static let answeredFor: TimeInterval = 10
}

/// The open question of the agent the chat talks to (the PM on the Dashboard), between the thread and the input (N289). It sits outside
/// the thread's scroll view, so it stays in reach when the thread is scrolled up. Answers go through the inbox, like Waiting for you.
struct ChatQuestionCard: View {
    @Bindable var inbox: AgentInboxModel
    /// The agent's open questions, in the order Waiting for you lists them.
    let questions: [PendingQuestion]
    let paneID: String?
    /// Snapshots: a fixed clock and the card's state.
    var now: Date? = nil
    var noteOpen = false
    var wholePlan = false
    /// The shown question's index, kept by the chat so its digit keys know the question (N293); nil keeps it here.
    var selection: Binding<Int>? = nil
    /// A digit key from the chat's empty input: picks that option as a click does.
    var digit: ChatDigit? = nil
    @State private var ownIndex = 0
    @State private var text = ""
    @State private var writing: Bool?
    @State private var planOpen: Bool?

    private var index: Int {
        get { selection?.wrappedValue ?? ownIndex }
        nonmutating set { if let selection { selection.wrappedValue = newValue } else { ownIndex = newValue } }
    }

    private var current: PendingQuestion? { questions.isEmpty ? nil : questions[min(index, questions.count - 1)] }

    var body: some View {
        Group {
            if let now { content(now) } else {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
            }
        }
        .onChange(of: digit) { _, d in if let d, let p = current { pick(p, d.number) } }
    }

    /// A digit does what a click on its option's button does: answer, or open the note for "Deny and tell …" / the plan's note.
    private func pick(_ p: PendingQuestion, _ n: Int) {
        guard !inbox.sending, let o = ChatQuestionContent.digitOption(p, n) else { return }
        let opensNote = p.question.kind == .plan ? o.label.hasPrefix("Tell Claude what to change")
            : ChatQuestionContent.actions(p).first { $0.option.number == n }?.kind == .denyWithNote
        if opensNote { writing = true } else { press(p, o) }
    }

    @ViewBuilder private func content(_ now: Date) -> some View {
        if let p = current { card(p, now: now).id(p.id) }
        else if let a = inbox.lastAnswer, a.question.paneID == paneID, now.timeIntervalSince(a.at) < ChatQuestionContent.answeredFor { answeredLine(a) }
    }

    private func card(_ p: PendingQuestion, now: Date) -> some View {
        let q = p.question
        return VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            header(p, now: now)
            if q.terminalOnly || q.isCall { terminalOnly(p) } else {
                switch q.kind {
                case .permission: permission(p)
                case .choice: choice(p)
                case .plan: plan(p)
                case .freeText, .signIn: EmptyView()
                }
            }
            if let error = inbox.error { Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 14).padding(.vertical, Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.ask.opacity(0.07), in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.ask.opacity(0.45)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChatQuestionContent.title(p))
    }

    private func header(_ p: PendingQuestion, now: Date) -> some View {
        HStack(spacing: Tok.Space.s) {
            Image(systemName: "shield").font(Tok.Font.body.weight(.semibold)).foregroundStyle(Tok.askText)
            Text(ChatQuestionContent.title(p)).font(Tok.Font.bodyStrong.weight(.semibold)).foregroundStyle(Tok.askText).lineLimit(1)
            Spacer(minLength: Tok.Space.s)
            if let asked = inbox.askedAt[p.id] {
                Text(asked.formatted(date: .omitted, time: .shortened) + " · waiting " + ChatQuestionContent.waited(since: asked, now: now))
                    .font(Tok.Font.small).foregroundStyle(Tok.ink2).monospacedDigit()
            }
            if questions.count > 1 {
                Button { index = (min(index, questions.count - 1) + 1) % questions.count; writing = nil; text = "" } label: {
                    Text("\(min(index, questions.count - 1) + 1) of \(questions.count) ›").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink)
                }
                .buttonStyle(.plain).help("Show the next open question")
            }
        }
    }

    // MARK: kinds

    @ViewBuilder private func permission(_ p: PendingQuestion) -> some View {
        let q = p.question
        if let what = ChatQuestionContent.what(q) { Text(what).font(Tok.Font.small).foregroundStyle(Tok.ink2) }
        if q.command == nil { Text(ReadableQuestion(q).title).font(Tok.Font.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true) }
        if let code = q.command ?? q.code { codeBox(code) }
        let actions = ChatQuestionContent.actions(p)
        if isWriting, let deny = actions.first(where: { $0.kind == .denyWithNote }) {
            note(p, placeholder: "What should \(ChatQuestionContent.who(p)) do instead?", send: "Deny and send", cancelHelp: deny.option.label)
        } else {
            FlowButtons {
                ForEach(actions, id: \.option.number) { a in
                    switch a.kind {
                    case .allow: Button { press(p, a.option) } label: { keyed(a.option.number, a.label) }.buttonStyle(GoButtonStyle()).help(a.option.label)
                    case .denyWithNote: Button { writing = true } label: { keyed(a.option.number, a.label) }.buttonStyle(PanelButtonStyle()).help("Denies, and sends your note to \(ChatQuestionContent.who(p))")
                    case .always: Button { press(p, a.option) } label: { keyed(a.option.number, a.label) }.buttonStyle(PanelButtonStyle(tint: Tok.stop)).help(a.option.label + "\n" + alwaysAllowWarning)
                    case .deny, .plain: Button { press(p, a.option) } label: { keyed(a.option.number, a.label) }.buttonStyle(PanelButtonStyle()).help(a.option.label)
                    }
                }
            }
        }
    }

    @ViewBuilder private func choice(_ p: PendingQuestion) -> some View {
        let q = p.question
        if !q.plainText.isEmpty { Text(q.plainText).font(Tok.Font.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(q.options.filter { !$0.isSpecial }, id: \.number) { o in
                Button { press(p, o) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        (Text("\(o.number)").fontWeight(.semibold) + Text(" · " + o.label)).font(Tok.Font.body).foregroundStyle(Tok.ink)
                        if !o.detail.isEmpty, o.detail != o.label { Text(o.detail).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(inbox.sending)
            }
        }
        if q.typeNumber != nil {
            HStack(alignment: .top, spacing: Tok.Space.s) {
                FieldText(text: $text, placeholder: "Or type your own answer…")
                Button("Send") { let words = text; Task { if await inbox.answerTyped(p, text: words) { text = "" } } }
                    .buttonStyle(PanelButtonStyle()).disabled(!canSendAnswer(text: text, sending: inbox.sending))
            }
        }
    }

    @ViewBuilder private func plan(_ p: PendingQuestion) -> some View {
        let q = p.question
        let head = ChatQuestionContent.planHead(q)
        VStack(alignment: .leading, spacing: 3) {
            if isPlanOpen { Scroller { Text(q.context).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260) }
            else { Text(head.head).fixedSize(horizontal: false, vertical: true) }
            if head.total > 4 {
                Button(isPlanOpen ? "Show less" : "Show the whole plan · \(head.total) lines") { planOpen = !isPlanOpen }
                    .buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work)
            }
        }
        .font(Tok.Font.body).foregroundStyle(Tok.ink).textSelection(.enabled)
        .padding(.horizontal, 10).padding(.vertical, Tok.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.rail, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line))
        let options = q.options.filter { !$0.isSpecial && !$0.label.hasPrefix("Tell Claude what to change") }
        if isWriting, q.feedbackPath != nil {
            note(p, placeholder: "What should change?", send: "Send my note", cancelHelp: nil)
        } else {
            FlowButtons {
                if let first = options.first { Button { press(p, first) } label: { keyed(first.number, "Approve") }.buttonStyle(GoButtonStyle()).help(first.label) }
                ForEach(options.dropFirst(), id: \.number) { o in Button { press(p, o) } label: { keyed(o.number, ReadableQuestion.stripRecommended(o.label)) }.buttonStyle(PanelButtonStyle()) }
                if q.feedbackPath != nil {
                    let tell = q.options.first { !$0.isSpecial && $0.label.hasPrefix("Tell Claude what to change") }
                    Button { writing = true } label: { keyed(tell?.number, "Keep planning with my note…") }.buttonStyle(PanelButtonStyle())
                }
            }
        }
    }

    private func terminalOnly(_ p: PendingQuestion) -> some View {
        HStack(spacing: Tok.Space.m) {
            Text("Answer it in \(p.isPM ? "the PM" : p.agentLabel)'s terminal").font(Tok.Font.body).foregroundStyle(Tok.ink)
            Spacer(minLength: 0)
            if let tool = p.question.signInTool { Button("Sign in to \(SignInGate.name(tool))") { Task { await inbox.signIn(for: p) } }.buttonStyle(ConfirmButtonStyle()) }
            Button("Open terminal") { Task { await inbox.openPane(of: p) } }.buttonStyle(PanelButtonStyle())
        }
    }

    // MARK: pieces

    private var isWriting: Bool { writing ?? noteOpen }
    private var isPlanOpen: Bool { planOpen ?? wholePlan }

    private func press(_ p: PendingQuestion, _ option: QuestionOption) { Task { await inbox.answer(p, option: option) } }

    /// A button's label with the digit key that picks it in front, muted (N293).
    private func keyed(_ n: Int?, _ label: String) -> some View {
        HStack(spacing: 6) {
            if let n { Text("\(n)").font(.system(size: 10, weight: .semibold)).opacity(0.6).monospacedDigit() }
            Text(label)
        }
    }

    private func codeBox(_ code: String) -> some View {
        // Long commands and diffs show their first lines; the whole text is in Waiting for you's question window.
        Text(code).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled).lineLimit(10)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, Tok.Space.s)
        .background(Tok.rail, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line))
    }

    /// The note for "Deny and tell …" and "Keep planning with my note…": it goes by the question's feedback path.
    private func note(_ p: PendingQuestion, placeholder: String, send: String, cancelHelp: String?) -> some View {
        HStack(alignment: .top, spacing: Tok.Space.s) {
            FieldText(text: $text, placeholder: placeholder)
            Button(send) { let words = text; Task { if await inbox.feedback(p, text: words) { text = ""; writing = nil } } }
                .buttonStyle(PanelButtonStyle()).disabled(!canSendAnswer(text: text, sending: inbox.sending))
            Button("Cancel") { writing = false; text = "" }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink2)
        }
    }

    private func answeredLine(_ a: SentAnswer) -> some View {
        let line = ChatQuestionContent.answered(a)
        return HStack(spacing: Tok.Space.s) {
            Image(systemName: "checkmark").font(Tok.Font.small.weight(.bold)).foregroundStyle(Tok.go)
            Text(line.verb).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink)
            Text(line.detail).font(Tok.Font.mono).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(a.at.formatted(date: .omitted, time: .shortened)).font(Tok.Font.small).foregroundStyle(Tok.ink3)
        }
        .padding(.horizontal, Tok.Space.s).padding(.vertical, Tok.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

/// A digit key pressed in the chat's empty input (N293); `seq` makes the same digit twice a new press.
struct ChatDigit: Equatable {
    let number: Int
    let seq: Int
}

/// Buttons in a row that wrap onto the next line when the chat is narrow.
private struct FlowButtons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tok.Space.s) { content }
            VStack(alignment: .leading, spacing: Tok.Space.s) { content }
        }
    }
}

/// The card's main answer (Allow, Approve): `Tok.go` with its dark ink.
private struct GoButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tok.Font.bodyStrong.weight(.semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(Tok.goInk)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Tok.go, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
