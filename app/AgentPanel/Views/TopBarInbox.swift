import SwiftUI

/// The top bar's one Inbox (N133): questions waiting in every project, then the cards of every project that are ready to approve (N208).
enum TopBarInbox {
    /// One project's questions for the user, with when each was first seen, and its cards that wait for approval.
    struct Source {
        let id: String
        let name: String
        let questions: [PendingQuestion]
        var askedAt: [String: Date] = [:]
        var ready: [TaskCard] = []
        /// The questions the PM is answering, and those it just answered (N380): listed muted, never counted.
        var held: [HeldQuestion] = []
    }

    /// A question with the PM (N380): "N380 asks: …", "ui_dev · PM is answering · comes to you in 7 min".
    struct WithPM: Equatable, Identifiable {
        let id: String
        let projectID: String
        /// The inbox's question id, for Answer myself.
        let questionID: String
        let title: String
        let detail: String
        let answered: Bool
        let otherProject: Bool
    }

    struct Question: Equatable, Identifiable {
        let id: String
        let projectID: String
        /// The card it is answered on; nil for a question of the PM (answered on the Dashboard).
        let cardID: String?
        let title: String
        let detail: String
        let otherProject: Bool
    }

    struct Ready: Equatable, Identifiable {
        let id: String
        let title: String
        var projectID: String?
        var cardID: String?
        var otherProject = false
    }

    struct Content: Equatable {
        let questions: [Question]
        let ready: [Ready]
        var withPM: [WithPM] = []
        /// Questions with the PM are not counted (N380): nothing waits for the user there.
        var count: Int { questions.count + ready.count }
        var isEmpty: Bool { count == 0 }
        /// The open project's cards: the Approve button takes these.
        var ownReady: [Ready] { ready.filter { !$0.otherProject } }
        /// The other projects' cards: each opens its project.
        var otherReady: [Ready] { ready.filter(\.otherProject) }
        var approveTitle: String { ownReady.count == 1 ? "Approve" : "Approve round" }
        var readyLine: String { ownReady.map(\.title).joined(separator: " · ") }
    }

    /// The selected project's questions first, then the others in project order; `ready` is this project's Approve round cards, followed by
    /// the cards waiting in the other projects (each labelled with its project).
    static func content(sources: [Source], selected: String?, ready: [TaskCard], now: Date = Date()) -> Content {
        let ordered = sources.filter { $0.id == selected } + sources.filter { $0.id != selected }
        let questions = ordered.flatMap { source in
            source.questions.map { q in
                let other = source.id != selected
                let short = String((q.question.title.isEmpty ? q.question.text : q.question.title).replacingOccurrences(of: "\n", with: " ").prefix(70))
                let age = source.askedAt[q.id].map { " · " + Stats.durationText(max(now.timeIntervalSince($0), 0)) } ?? ""
                return Question(id: source.id + "|" + q.id, projectID: source.id, cardID: q.isPM ? nil : q.cardID,
                                title: (other ? source.name + " · " : "") + "\(q.owner) asks: \(short)",
                                detail: (q.isPM ? "PM" : q.agentLabel) + age, otherProject: other)
            }
        }
        let own = ready.map { Ready(id: $0.id, title: waitingRowTitle(id: $0.id, title: $0.title), projectID: selected, cardID: $0.id) }
        let others = ordered.filter { $0.id != selected }.flatMap { source in
            source.ready.map { Ready(id: source.id + "|" + $0.id, title: source.name + " · " + waitingRowTitle(id: $0.id, title: $0.title), projectID: source.id, cardID: $0.id, otherProject: true) }
        }
        let withPM = ordered.flatMap { source in
            source.held.map { h in
                let other = source.id != selected
                let q = h.question
                let short = String((q.question.title.isEmpty ? q.question.text : q.question.title).replacingOccurrences(of: "\n", with: " ").prefix(70))
                return WithPM(id: source.id + "|" + h.id, projectID: source.id, questionID: h.id,
                              title: (other ? source.name + " · " : "") + "\(q.owner) asks: \(short)",
                              detail: (q.isPM ? "PM" : q.agentLabel) + " · " + h.status(now: now), answered: h.isAnswered, otherProject: other)
            }
        }
        return Content(questions: questions, ready: own + others, withPM: withPM)
    }

    static func buttonLabel(_ count: Int) -> String { count == 0 ? "Inbox, nothing waiting" : "Inbox, \(count) waiting" }
}

extension PanelModel {
    /// The Inbox of the top bar, read from every project's watch.
    func topBarInbox(now: Date = Date()) -> TopBarInbox.Content {
        let sources = projects.compactMap { project in
            watches[project.id].map { TopBarInbox.Source(id: project.id, name: project.name, questions: $0.autopilot.forUser($0.inbox.questions), askedAt: $0.inbox.askedAt,
                                        ready: $0.taskCards.filter { $0.status == .review || $0.status == .awaitingStartApproval }, held: $0.inbox.heldRows) }
        }
        return TopBarInbox.content(sources: sources, selected: selectedProjectID, ready: approveRoundCards, now: now)
    }
}

/// The "Inbox N" button: orange outline while something waits, plain when nothing does.
struct InboxButton: View {
    let count: Int
    let action: () -> Void

    /// What the number counts (N305): the Dashboard's "Waiting for you" also lists steps like Push to GitHub, which are not here.
    static func help(active: Bool) -> String {
        (active ? "Counts" : "Nothing to count: it counts") + " agents' questions and cards waiting for your approval, in every project."
            + " Other steps (like Push to GitHub) are under the Dashboard's Waiting for you."
    }

    var body: some View {
        let active = count > 0
        Button(action: action) {
            HStack(spacing: Tok.Space.s) {
                Image(systemName: "tray").font(.system(size: 12, weight: .medium))
                Text("Inbox").font(Tok.Font.body.weight(.semibold))
                Text("\(count)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .foregroundStyle(active ? Tok.askInk : Tok.ink3)
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                    .background(active ? Tok.ask : Tok.raise, in: Capsule())
            }
            .foregroundStyle(active ? Tok.ask : Tok.ink2)
            .padding(.horizontal, Tok.Space.m).frame(height: 32)
            .background(active ? Tok.ask.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? Tok.ask : Tok.line))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Self.help(active: active))
        .accessibilityLabel(TopBarInbox.buttonLabel(count))
    }
}

/// The Inbox's popover: "WAITING FOR YOU" and "READY TO APPROVE".
struct InboxPanel: View {
    let content: TopBarInbox.Content
    var busy = false
    let onOpen: (TopBarInbox.Question) -> Void
    var onOpenReady: (TopBarInbox.Ready) -> Void = { _ in }
    let onApprove: () -> Void
    /// Answer myself on a question the PM has (N380).
    var onAnswerMyself: (TopBarInbox.WithPM) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if content.isEmpty && content.withPM.isEmpty {
                Text("Nothing waits for you.").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(.horizontal, 10).padding(.vertical, Tok.Space.m)
            }
            if !content.questions.isEmpty {
                header("WAITING FOR YOU · \(content.questions.count)").padding(.horizontal, 10).padding(.top, Tok.Space.s).padding(.bottom, Tok.Space.xs)
                ForEach(content.questions) { QuestionRow(question: $0, onOpen: onOpen) }
            }
            if !content.withPM.isEmpty {
                if !content.questions.isEmpty { Rectangle().fill(Tok.line).frame(height: 1).padding(.horizontal, Tok.Space.xs).padding(.vertical, 6) }
                header("WITH THE PM · \(content.withPM.count)").padding(.horizontal, 10).padding(.top, Tok.Space.s).padding(.bottom, Tok.Space.xs)
                ForEach(content.withPM) { WithPMRow(item: $0, onAnswerMyself: onAnswerMyself) }
            }
            if !content.ready.isEmpty {
                if !content.questions.isEmpty || !content.withPM.isEmpty { Rectangle().fill(Tok.line).frame(height: 1).padding(.horizontal, Tok.Space.xs).padding(.vertical, 6) }
                HStack {
                    header("READY TO APPROVE · \(content.ready.count)")
                    Spacer()
                    if !content.ownReady.isEmpty {
                        Button(content.approveTitle, action: onApprove).buttonStyle(ApproveButtonStyle()).disabled(busy)
                            .help(content.ownReady.count == 1 ? "Approve this task" : "Approve every task that is in review in one go")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, Tok.Space.xs)
                if !content.ownReady.isEmpty {
                    Text(content.readyLine).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.top, Tok.Space.xs).padding(.bottom, Tok.Space.s)
                }
                ForEach(content.otherReady) { ReadyRow(ready: $0, onOpen: onOpenReady) }
            }
        }
        .padding(Tok.Space.s)
        .frame(width: 400, alignment: .leading)
        .background(Tok.pane)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(Tok.Font.small).tracking(0.3).foregroundStyle(Tok.ink2)
    }
}

private struct QuestionRow: View {
    let question: TopBarInbox.Question
    let onOpen: (TopBarInbox.Question) -> Void
    @State private var hovering = false

    var body: some View {
        Button { onOpen(question) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Tok.ask).frame(width: 7, height: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.title).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(question.detail).font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, Tok.Space.s)
            .background(hovering ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(question.otherProject ? "Opens the other project's Dashboard, where it is answered" : "Opens the Dashboard, where it is answered")
    }
}

/// A question the PM is answering (N380): muted, with Answer myself; "PM answered: …" for a moment once answered.
private struct WithPMRow: View {
    let item: TopBarInbox.WithPM
    let onAnswerMyself: (TopBarInbox.WithPM) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.answered ? "checkmark.circle.fill" : "clock").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.answered ? Tok.go : Tok.ink3).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(item.detail).font(Tok.Font.small).foregroundStyle(item.answered ? Tok.go : Tok.ink3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !item.answered {
                Button("Answer myself") { onAnswerMyself(item) }.buttonStyle(PanelButtonStyle()).fixedSize()
                    .help("Take the question from the PM: it comes to you now, with its options")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, Tok.Space.s)
        .accessibilityElement(children: .contain)
    }
}

/// A card waiting for approval in another project: opens that project on the card.
private struct ReadyRow: View {
    let ready: TopBarInbox.Ready
    let onOpen: (TopBarInbox.Ready) -> Void
    @State private var hovering = false

    var body: some View {
        Button { onOpen(ready) } label: {
            Text(ready.title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, Tok.Space.s)
                .background(hovering ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Opens the other project on this task, where it is approved")
    }
}

/// The green "Approve" of the popover.
private struct ApproveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold)).foregroundStyle(Tok.bg)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Tok.go.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.5)
    }
}
