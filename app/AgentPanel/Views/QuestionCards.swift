import SwiftUI

/// "Needs your answer": one card per agent that is asking something. Orange means it waits for a decision of yours.
struct QuestionCards: View {
    @Bindable var inbox: AgentInboxModel
    /// With the autopilot, the questions the PM is still deciding are left out and the PM's suggestion is shown on the card.
    var autopilot: AutopilotModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            if let error = inbox.error {
                Text(error).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(autopilot?.forUser(inbox.questions) ?? inbox.questions) { q in
                QuestionCard(inbox: inbox, question: q, suggestion: autopilot?.suggestion(for: q), escalation: autopilot?.escalation(for: q))
            }
        }
    }
}

/// One question; the Dashboard's Waiting for you lists each on its own, in its order and colour (N182).
struct QuestionCard: View {
    @Bindable var inbox: AgentInboxModel
    let question: PendingQuestion
    var suggestion: PMSuggestion? = nil
    var escalation: String? = nil
    /// Waiting for you: the heading becomes the kind's chip and the outline takes its colour; elsewhere the card stays orange.
    var tint: WaitingTint? = nil
    /// Waiting for you (N183): the item shows the question's first lines and opens the question window; nil keeps the full card.
    var onOpen: ((PendingQuestion) -> Void)? = nil
    /// Shows the Details block open (snapshots).
    var detailsOpen = false
    @State private var text = ""

    private var q: AgentQuestion { question.question }
    private var readable: ReadableQuestion { ReadableQuestion(question) }
    private var heading: String {
        switch q.kind {
        case .permission: "Needs your permission"
        case .plan: "Needs your approval"
        case .choice, .freeText: "Needs your answer"
        case .signIn: "Needs sign-in"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            HStack(spacing: Tok.Space.s) {
                if let tint { WaitingChip(text: heading, tint: tint) } else {
                    Circle().fill(Tok.ask).frame(width: 8, height: 8).overlay { Circle().stroke(Tok.ask.opacity(0.25), lineWidth: 3) }
                    Text(heading).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ask)
                }
                Spacer(minLength: 0)
                if !question.cardID.isEmpty { Chip(text: question.cardID) }
            }
            Text(question.agentLabel).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
            if let escalation {
                Text(escalation).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let onOpen { summary(onOpen) } else { full }
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke((tint?.color ?? Tok.ask).opacity(0.6), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Tok.radius))
        .onTapGesture { onOpen?(question) }
        .accessibilityAction(named: "Answer…") { onOpen?(question) }
    }

    /// Waiting for you: the question's title (the agent's `user:` line, else its first sentence) and the buttons; the whole item opens the window.
    @ViewBuilder private func summary(_ open: @escaping (PendingQuestion) -> Void) -> some View {
        if q.isCall { Text(q.title).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink2).lineLimit(1) }
        else {
            Text(readable.title).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if !readable.subtitle.isEmpty { Text(readable.subtitle).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }
        if let suggestion { PMSuggestionBox(suggestion: suggestion) }
        HStack(spacing: Tok.Space.m) {
            Button("Answer…") { open(question) }.buttonStyle(ConfirmButtonStyle(fill: tint?.color ?? Tok.ask))
                .help("Opens the whole question in a large window")
            let count = QuestionFocusContent(question).answers.count
            if q.isCall { Text("\(q.call?.items.count ?? 0) questions").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            else if count > 0 { Text("\(count) answers").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            Spacer()
            buttons
        }
    }

    @ViewBuilder private var full: some View {
            if q.isCall {
                if !q.title.isEmpty { Text(q.title).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                QuestionBody(text: q.plainText, font: Tok.Font.body)
            } else {
                Text(readable.title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                if !readable.subtitle.isEmpty { Text(readable.subtitle).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            }
            if let suggestion { PMSuggestionBox(suggestion: suggestion) }
            if q.terminalOnly || q.isCall { terminalNote } else {
            switch q.kind {
            case .choice:
                choices
                if q.typeNumber != nil { typedBox }
            case .permission, .plan:
                choices
                if q.feedbackPath != nil { feedbackBox }
            case .freeText: reply
            case .signIn: EmptyView()
            }
            }
            if !q.isCall { QuestionDetails(text: readable.details, open: detailsOpen) }
            HStack(spacing: Tok.Space.m) {
                Spacer()
                buttons
            }
    }

    @ViewBuilder private var buttons: some View {
        if (q.kind == .choice || q.kind == .freeText) && !q.terminalOnly {
            Button("Skip") { Task { await inbox.skip(question) } }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink2).disabled(inbox.sending)
                .help("Tell the agent to carry on without an answer")
        }
        Button("Dismiss") { inbox.dismiss(question) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            .help("Only hides this card: the agent keeps waiting. It comes back if the agent asks again")
    }

    /// Multi-select questions (and Codex's several questions) are not answered from the panel: the options are listed and the terminal is one click away.
    private var terminalNote: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            ForEach(q.options.filter { !$0.isSpecial }, id: \.number) { option in
                Text(option.label).font(Tok.Font.small).foregroundStyle(Tok.ink2)
            }
            Text(q.isCall ? "Answer all questions in the question window (Answer…) or in \(question.isPM ? "the PM" : "the agent")'s terminal"
                 : "Answer in \(question.isPM ? "the PM" : "the agent")'s terminal").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            if let tool = q.signInTool { Button("Sign in to \(SignInGate.name(tool))") { Task { await inbox.signIn(for: question) } }.buttonStyle(ConfirmButtonStyle()) }
            Button(question.isPM ? "Open PM" : "Open terminal") { Task { await inbox.openPane(of: question) } }
                .buttonStyle(ConfirmButtonStyle())
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(q.options.filter { !$0.isSpecial }, id: \.number) { option in
                let recommended = ReadableQuestion.isRecommended(option.label)
                Button { Task { await inbox.answer(question, option: option) } } label: {
                    HStack(alignment: .top, spacing: Tok.Space.s) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ReadableQuestion.stripRecommended(option.label)).font(Tok.Font.bodyStrong)
                            if !option.detail.isEmpty, option.detail != option.label { Text(option.detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2) }
                        }
                        Spacer(minLength: 0)
                        if recommended { Text("Recommended").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(AnswerButtonStyle(danger: option.role == .allowAlways, suggested: suggestion?.option == option.number || (suggestion == nil && recommended)))
                .disabled(inbox.sending)
                if option.role == .allowAlways {
                    Text(alwaysAllowWarning).font(Tok.Font.small).foregroundStyle(Tok.stop).padding(.top, -3)
                }
            }
            if let note = Self.otherAnswersNote(q) { Text(note).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
        }
    }

    /// The terminal note under the options, only when the menu has an answer the panel cannot give: a menu with "Type something."
    /// gets the own-words box instead (N192, N206), a plan or permission with a feedback path gets its feedback box.
    static func otherAnswersNote(_ q: AgentQuestion) -> String? {
        guard q.options.contains(where: \.isSpecial), q.feedbackPath == nil, q.typeNumber == nil else { return nil }
        return q.kind == .plan ? "To ask for changes, use the agent's terminal." : "Other answers: use the agent's terminal."
    }

    /// Plan: "Request changes"; permission: "Deny with a reason". Sent as typed feedback to the agent.
    private var feedbackBox: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            Text(q.kind == .plan ? "Request changes" : "Deny with a reason").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink2)
            HStack(alignment: .top, spacing: Tok.Space.s) {
                FieldText(text: $text, placeholder: q.kind == .plan ? "What should change?" : "What should Claude do instead?")
                Button("Send feedback") { let reason = text; Task { if await inbox.feedback(question, text: reason) { text = "" } } }
                    .buttonStyle(ConfirmButtonStyle()).disabled(!canSendAnswer(text: text, sending: inbox.sending))
            }
        }
    }

    /// A menu with "Type something.": the own words are typed into that option.
    private var typedBox: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            Text("Or answer in your own words").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink2)
            HStack(alignment: .top, spacing: Tok.Space.s) {
                FieldText(text: $text, placeholder: "Your answer")
                Button("Send") { let words = text; Task { if await inbox.answerTyped(question, text: words) { text = "" } } }
                    .buttonStyle(ConfirmButtonStyle()).disabled(!canSendAnswer(text: text, sending: inbox.sending))
            }
        }
    }

    private var reply: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            if let suggested = suggestion?.text {
                Button("Send PM's answer") { Task { await inbox.answer(question, text: suggested) } }
                    .buttonStyle(ConfirmButtonStyle()).disabled(inbox.sending)
            }
            typedReply
        }
    }

    private var typedReply: some View {
        HStack(alignment: .top, spacing: Tok.Space.s) {
            FieldText(text: $text, placeholder: "Your answer")
            Button("Send") { let answer = text; Task { if await inbox.answer(question, text: answer) { text = "" } } }
                .buttonStyle(ConfirmButtonStyle()).disabled(!canSendAnswer(text: text, sending: inbox.sending))
        }
    }
}

/// A full-width option button: calm like the other panel buttons, not orange.
private struct AnswerButtonStyle: ButtonStyle {
    var danger = false
    /// The PM's pick: outlined in blue, still a plain option the user presses.
    var suggested = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Tok.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(danger ? Tok.stop.opacity(0.7) : suggested ? Tok.work : Tok.line, lineWidth: suggested ? 1.5 : 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// The PM's answer on a card the user decides: what it would pick and why, in the PM's blue.
struct PMSuggestionBox: View {
    let suggestion: PMSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(suggestion.option.map { "PM suggests \($0): \(suggestion.summary)" } ?? (suggestion.text == nil && !suggestion.summary.isEmpty ? "PM suggests: \(suggestion.summary)" : "PM suggests:"))
                .font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work)
            if suggestion.option == nil, let text = suggestion.text {
                Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text(suggestion.why).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Tok.Space.s + 2).padding(.vertical, Tok.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.work.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) { Rectangle().fill(Tok.work).frame(width: 2) }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The red note under the "don't ask again" button on a permission card.
let alwaysAllowWarning = "Permanent: Claude will not ask again for this. You can only undo it in Claude Code's permission settings."

/// A command, a file's content or a diff: monospaced, its line breaks and indentation as the agent drew them, long lines and long
/// blocks scroll instead of wrapping in the middle of a word.
struct QuestionCode: View {
    let code: String
    var maxHeight: CGFloat = 240
    var font: Font = Tok.Font.mono

    @Environment(\.snapshotMode) private var snapshot

    private var text: some View {
        Text(code).font(font).foregroundStyle(Tok.ink).textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        // ImageRenderer draws a ScrollView empty: a snapshot shows the text itself.
        Group { if snapshot { text } else { ScrollView([.horizontal, .vertical]) { text } } }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .accessibilityLabel("Code")
    }
}

/// A question's text as paragraphs and code: lines the agent indented (a snippet in the plan or in the question) are code, the rest is prose.
enum QuestionSegments {
    struct Segment: Equatable { let code: Bool; let text: String }

    static func split(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var run: [String] = [], runIsCode = false
        func flush() {
            while run.last?.isEmpty == true { run.removeLast() }
            if !run.isEmpty { out.append(Segment(code: runIsCode, text: run.joined(separator: "\n"))) }
            run = []
        }
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            // A blank line belongs to the code run when the next non-blank line is code too.
            let code = isBlank ? runIsCode && (lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.hasPrefix("  ") ?? false) : line.hasPrefix("  ")
            if !run.isEmpty, code != runIsCode, !(isBlank && !runIsCode) { flush() }
            if isBlank && run.isEmpty { continue }
            if run.isEmpty { runIsCode = code }
            run.append(code ? String(line) : line)
        }
        flush()
        // The code's own margin comes off, its relative indentation stays.
        return out.map { seg in
            guard seg.code else { return seg }
            let rows = seg.text.components(separatedBy: "\n")
            let margin = rows.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
            return Segment(code: true, text: rows.map { String($0.dropFirst(min(margin, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n"))
        }
    }
}

/// Prose as text, indented snippets as code blocks.
struct QuestionBody: View {
    let text: String
    var font: Font
    var color: Color = Tok.ink
    var maxCodeHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            ForEach(Array(QuestionSegments.split(text).enumerated()), id: \.offset) { _, seg in
                if seg.code { QuestionCode(code: seg.text, maxHeight: maxCodeHeight) }
                else { Text(seg.text).font(font).foregroundStyle(color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
}


/// "Details": everything of a question that is not its title or answers (code, paths, the agent's longer text) as one monospaced block;
/// long lines wrap, nothing scrolls sideways. Closed until the user opens it.
struct QuestionDetails: View {
    let text: String
    var open = false
    var maxHeight: CGFloat = 240
    @State private var shown = false
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                Button { shown.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: shown || open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text("Details").font(Tok.Font.small.weight(.semibold))
                    }.foregroundStyle(Tok.ink2).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Details")
                if shown || open {
                    let block = Text(text).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s + 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // ImageRenderer draws a ScrollView empty: a snapshot shows the text itself.
                    Group { if snapshot { block } else { ScrollView(.vertical) { block } } }
                        .frame(maxHeight: maxHeight).fixedSize(horizontal: false, vertical: true)
                        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                        .accessibilityLabel("Question details")
                }
            }
        }
    }
}

/// Under Waiting for you: what the PM answered for the agents (the last 20), so modes 1 and 2 stay auditable.
struct AnsweredByPMList: View {
    let items: [AnsweredByPM]
    @State private var expanded = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text("Answered by PM · \(items.count)").font(Tok.Font.small.weight(.semibold))
                    }.foregroundStyle(Tok.ink2).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if expanded { rows }
            }
        }
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Tok.Space.s) {
                        Text(item.cardID.isEmpty ? item.agent : item.cardID).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink2)
                        Spacer(minLength: 0)
                        Text(item.time, style: .time).font(Tok.Font.small.monospacedDigit()).foregroundStyle(Tok.ink3)
                    }
                    Text(item.question).font(Tok.Font.small).foregroundStyle(Tok.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text("→ " + item.answer).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.id != items.last?.id { Divider().overlay(Tok.line) }
            }
        }
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}

/// What a muted "with the PM" row says (N380): "Question · ui_dev · N380", the question's title, and the PM's state.
struct HeldQuestionRowText: Equatable {
    let heading: String
    let question: String
    let status: String

    static func make(_ held: HeldQuestion, role: String?, now: Date) -> HeldQuestionRowText {
        let q = held.question
        let heading = [QuestionFocusContent(q).kindLabel, q.isPM ? "PM" : role ?? "", q.isPM ? nil : q.cardID].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return HeldQuestionRowText(heading: heading, question: QuestionFocusContent.firstLine(ReadableQuestion(q).title), status: held.status(now: now))
    }
}

/// A question the PM is answering (N380), muted (no Tok.ask: orange stays "waiting for your decision"): who asks, the question,
/// "PM is answering · comes to you in N min" and Answer myself; once answered, "PM answered: …" for a moment.
struct HeldQuestionRow: View {
    let held: HeldQuestion
    let role: String?
    var compact = false
    let onAnswerMyself: () -> Void

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 20)) { context in
            let text = HeldQuestionRowText.make(held, role: role, now: context.date)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: held.isAnswered ? "checkmark.circle.fill" : "clock")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(held.isAnswered ? Tok.go : Tok.ink3).frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(text.heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.ink3).lineLimit(1)
                        Text(text.question).font(.system(size: compact ? 12.5 : 13.5)).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if !held.isAnswered {
                        Button("Answer myself", action: onAnswerMyself).buttonStyle(PanelButtonStyle()).fixedSize()
                            .help("Take the question from the PM: it comes to you now, with its options")
                    }
                }
                // Its own line under the button: the minutes left must never be cut.
                Text(text.status).font(.system(size: 11.5, weight: held.isAnswered ? .semibold : .regular))
                    .foregroundStyle(held.isAnswered ? Tok.go : Tok.ink3).lineLimit(1).truncationMode(.tail).monospacedDigit()
                    .padding(.leading, 22)
            }
            .padding(.horizontal, 10).padding(.vertical, compact ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(text.heading): \(text.question). \(text.status)")
        }
    }
}
