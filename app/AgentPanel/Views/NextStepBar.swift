import SwiftUI

/// The one button the action bar puts first for a card.
enum NextAction: Equatable {
    case start, prepare, approve, resume

    var title: String {
        switch self {
        case .start: return "Start"
        case .prepare: return "Prepare review"
        case .approve: return "Approve"
        case .resume: return "Resume agent"
        }
    }
}

/// What the task detail tells the user to do next: one button (with the reason it is off, if it is), a calm status line, or nothing.
enum NextStep: Equatable {
    case action(NextAction, blocked: String?)
    case status(String)
    case none
}

private func hasPacket(_ card: TaskCard) -> Bool {
    !(card.sections["Review packet"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// The next step for a card's phase. The button keeps the enable rules of `startButtonState` and `reviewButtonStates`.
/// `resume` is non-nil for a card whose agent is gone but whose worktree is there (`ResumeSession.buttonState`): Resume agent comes first.
func nextStep(card: TaskCard, phase: TaskPhase?, start: StartButtonState, review: ReviewButtonStates, resume: StartButtonState? = nil) -> NextStep {
    func action(_ a: NextAction, _ state: StartButtonState) -> NextStep { .action(a, blocked: state.enabled ? nil : state.help) }
    if let resume { return .action(.resume, blocked: resume.enabled ? nil : resume.help) }
    switch phase {
    case .working?, .starting?: return .status("Agent is working")
    case .needsFix?: return .status("Agent is fixing")
    case .waitingForYou?: return .status("Agent waits for your answer")
    case .pmHandling?: return .status("The PM is deciding for the agent")
    case .idle?: return .status("Agent is idle; it may need a nudge")
    case .blocked?: return .status("Agent is blocked; look at its terminal")
    case .finished?: return action(.prepare, review.prepare)
    case .inReview?: return hasPacket(card) ? action(.approve, review.approve) : action(.prepare, review.prepare)
    case nil: return card.status == .todo || card.status == .awaitingStartApproval ? action(.start, start) : .none
    }
}

/// The tab a card opens on: the Overview for every card (design B, N135); the agent tag opens the agent's terminal.
func openingTab(card: TaskCard) -> TaskDetailView.Tab { .overview }

enum MoreAction: Equatable { case approve, requestFix, prepare, close, start, edit, resume }

struct MoreItem: Equatable {
    let action: MoreAction
    let title: String
    let state: StartButtonState
}

/// Every action that is not the next step, with the same enable rules as before. Close task is listed only when it applies, Edit card
/// only for a card without an agent (as the buttons were).
func moreItems(card: TaskCard, step: NextStep, start: StartButtonState, review: ReviewButtonStates, canEdit: Bool) -> [MoreItem] {
    let primary: NextAction? = { if case .action(let a, _) = step { return a } else { return nil } }()
    var items: [MoreItem] = []
    if primary != .approve { items.append(MoreItem(action: .approve, title: "Approve", state: review.approve)) }
    items.append(MoreItem(action: .requestFix, title: "Request fix", state: review.requestFix))
    if primary != .prepare { items.append(MoreItem(action: .prepare, title: hasPacket(card) ? "Prepare review again" : "Prepare review", state: review.prepare)) }
    if review.close.enabled { items.append(MoreItem(action: .close, title: "Close task", state: review.close)) }
    if primary != .start { items.append(MoreItem(action: .start, title: "Start agent", state: start)) }
    if canEdit && !card.status.holdsAgent { items.append(MoreItem(action: .edit, title: "Edit card", state: StartButtonState(enabled: true, help: "Change the card."))) }
    return items
}

/// The action bar of the task detail: the next step first, every other action in More….
struct NextStepBar: View {
    /// Return must never merge (N54): the next-step button has no keyboard shortcut.
    static let primaryShortcut: KeyboardShortcut? = nil

    let card: TaskCard
    let step: NextStep
    let items: [MoreItem]
    let opener: WorkspaceOpener?
    let help: (NextAction) -> String
    let perform: (MoreAction) -> Void
    @State private var openError: String?

    var body: some View {
        // Design B (N142): the secondary button first, the next step at the right, 16 apart.
        HStack(alignment: .top, spacing: Tok.Space.l) {
            MenuBox {
                ForEach(items, id: \.title) { item in
                    Button(item.title) { perform(item.action) }.disabled(!item.state.enabled).help(item.state.help)
                }
                if let opener {
                    Divider()
                    open("Open folder") { try opener.openFolder(opener.project.repoURL) }
                    if opener.project.xcodeProject != nil { open("Open in Xcode") { try opener.openInXcode() } }
                    if card.branch != nil { open("Open worktree") { try opener.openFolder(OpenButtons.worktreeURL(opener.project, card)) } }
                }
            } label: {
                Text("More…").font(.system(size: 13)).foregroundStyle(Tok.ink)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                    .fixedSize()
            }
            .help("Every other action for this task")
            .tutorialAnchor(.nextStepMore)
            switch step {
            case .action(let a, let blocked):
                VStack(alignment: .trailing, spacing: Tok.Space.xs) {
                    primaryButton(a).disabled(blocked != nil).help(blocked ?? help(a)).tutorialAnchor(.nextStep)
                    if let blocked { Text(blocked).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2) }
                }
            case .status(let text):
                Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink2).frame(minHeight: 34)
            case .none:
                EmptyView()
            }
        }
        .alert("Cannot open", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(openError ?? "") }
    }

    private static func more(_ a: NextAction) -> MoreAction {
        switch a {
        case .start: return .start
        case .prepare: return .prepare
        case .approve: return .approve
        case .resume: return .resume
        }
    }

    /// Approve is green (design B, N142); Start keeps the calm blue it had; Prepare review stays orange.
    static func primaryKind(_ a: NextAction) -> HeaderButtonStyle.Kind {
        switch a {
        case .approve: return .approve
        case .prepare: return .decision
        case .start, .resume: return .confirm
        }
    }

    private func primaryButton(_ a: NextAction) -> some View {
        Button(a.title) { perform(Self.more(a)) }.buttonStyle(HeaderButtonStyle(kind: Self.primaryKind(a)))
    }

    private func open(_ title: String, _ action: @escaping () throws -> Void) -> some View {
        Button(title) { do { try action() } catch { openError = OpenButtons.describe(error) } }
    }
}
