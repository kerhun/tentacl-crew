import Foundation
import SwiftUI

struct StartButtonState: Equatable {
    let enabled: Bool
    let help: String
}

/// Whether the "Start agent" button is enabled for a card, and what its tooltip says.
func startButtonState(card: TaskCard, canStart: Bool, reason: String?, busy: Bool = false, dependencies: DependencyState? = nil) -> StartButtonState {
    if busy { return StartButtonState(enabled: false, help: "Another action is running; wait until it finishes.") }
    guard card.status == .todo || card.status == .awaitingStartApproval else {
        return StartButtonState(enabled: false, help: "Only tasks that are todo or awaiting approval can be started.")
    }
    switch dependencies {
    case .waiting(let ids)?: return StartButtonState(enabled: false, help: "Waiting for \(ids.joined(separator: ", ")): \(ids.count == 1 ? "it is" : "they are") not done yet.")
    case .problem(let text)?: return StartButtonState(enabled: false, help: "Fix the Dependencies section first: \(text).")
    default: break
    }
    guard canStart else { return StartButtonState(enabled: false, help: reason ?? "Starting agents is not set up for this project.") }
    return StartButtonState(enabled: true, help: "Start a developer agent for this task (you confirm first).")
}

struct ReviewButtonStates: Equatable {
    let prepare: StartButtonState
    let approve: StartButtonState
    let requestFix: StartButtonState
    /// Offered only for a task whose agent or worktree is gone.
    let close: StartButtonState
}

/// Which review buttons are enabled for a card, and what each tooltip says. Whether the packet is still current (the agent may
/// have committed since) is checked when Approve is clicked, not here: the panel does not run git on every selection.
func reviewButtonStates(card: TaskCard, canAct: Bool, reason: String?, worktreeExists: Bool = true, busy: Bool = false, agentWorking: Bool = false) -> ReviewButtonStates {
    let setup = StartButtonState(enabled: false, help: reason ?? "Reviewing is not set up for this project.")
    guard canAct else { return ReviewButtonStates(prepare: setup, approve: setup, requestFix: setup, close: setup) }
    if busy {
        let wait = StartButtonState(enabled: false, help: "Another action is running; wait until it finishes.")
        return ReviewButtonStates(prepare: wait, approve: wait, requestFix: wait, close: wait)
    }

    let prepare: StartButtonState
    if agentWorking && (card.status == .doing || card.status == .needsFix || card.status == .review) {
        prepare = StartButtonState(enabled: false, help: "The agent is still working on this task. Prepare the review when it has finished.")
    } else if card.status == .doing || card.status == .needsFix || card.status == .review {
        prepare = StartButtonState(enabled: true, help: "Build the app, take a screenshot and summarise the changes so you can review them.")
    } else {
        prepare = StartButtonState(enabled: false, help: "Only tasks that are doing, need a fix or are in review can be prepared for review.")
    }

    let approve: StartButtonState
    let packet = packetSections(from: card.sections["Review packet"] ?? "")
    if card.status != .review {
        approve = StartButtonState(enabled: false, help: "Only tasks in review can be approved.")
    } else if (card.sections["Review packet"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        approve = StartButtonState(enabled: false, help: "There is no review packet yet. Prepare the review first.")
    } else if card.kind != "analysis" && !packet.buildAcceptable {
        approve = StartButtonState(enabled: false, help: "The build in the review packet did not pass.")
    } else if card.kind != "analysis" && !packet.screenshotsAcceptable {
        approve = StartButtonState(enabled: false, help: "The review packet has no screenshots.")
    } else {
        approve = StartButtonState(enabled: true, help: "Merge this task into the main branch (you confirm first).")
    }

    let fix = card.status == .doing || card.status == .needsFix || card.status == .review
        ? StartButtonState(enabled: true, help: "Tell the agent what to change.")
        : StartButtonState(enabled: false, help: "Only tasks that are doing, need a fix or are in review can get a fix request.")
    let orphan = card.status.holdsAgent && (card.agent == nil || card.branch == nil || !worktreeExists)
    let close = orphan
        ? StartButtonState(enabled: true, help: "The agent or its worktree is gone. Mark the task done without merging (you confirm first).")
        : StartButtonState(enabled: false, help: "Only a task whose agent or worktree is gone can be closed this way.")
    return ReviewButtonStates(prepare: prepare, approve: approve, requestFix: fix, close: close)
}

/// Whether "Start agent" is available and whether the sheet offers "I am giving this task myself" (only when the team chart said no).
func startConfirmState(plan: StartPlan) -> (canStart: Bool, offersOverride: Bool) {
    if case .denied = plan.authority { return (false, true) }
    return (true, false)
}

/// The agents that work in a project: their folder is the repository or lies inside it (its worktrees). The window shows only these,
/// so the agents of another project do not clutter the list.
func agents(_ list: [AgentStatus], belongingToRepo repo: String) -> [AgentStatus] {
    let root = ResolvedPaths.shared.resolved(repo)
    return list.filter { agent in
        guard !agent.cwd.isEmpty else { return false }
        let cwd = ResolvedPaths.shared.resolved(agent.cwd)
        return cwd == root || cwd.hasPrefix(root + "/")
    }
}

/// `ProjectRegistry.resolved` (it asks the file system, once per path component) remembered for half a minute: the lists ask for every agent on each draw.
final class ResolvedPaths: @unchecked Sendable {
    static let shared = ResolvedPaths()
    private let lock = NSLock()
    private var known: [String: (path: String, at: Date)] = [:]
    private let lifetime: TimeInterval = 30

    func resolved(_ path: String) -> String {
        let now = Date()
        lock.lock()
        let cached = known[path]
        lock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < lifetime { return cached.path }
        let fresh = ProjectRegistry.resolved(path)
        lock.lock(); defer { lock.unlock() }
        if known.count > 2000 { known = [:] }
        known[path] = (fresh, now)
        return fresh
    }
}

func canSendAnswer(text: String, sending: Bool) -> Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

func canSend(text: String, target: String?, busy: Bool, hasImages: Bool = false) -> Bool {
    !busy && target != nil && (hasImages || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

struct SheetField: Equatable {
    let label: String
    let value: String
}

/// Everything the confirmation sheet shows, in order, so the user sees exactly what will run.
func startSheetFields(plan: StartPlan, project: ProjectConfig) -> [SheetField] {
    let role = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: plan.rolePath))) as? [String: Any]) ?? [:]
    let roleName = plan.roleName
    let model = [role["model"] as? String, role["effort"] as? String].compactMap { $0 }.joined(separator: " · ")
    var givenBy: [SheetField] = []
    switch plan.authority {
    case .notApplicable: break
    case .allowed(let from, let to): givenBy = [SheetField(label: "Given by", value: "\(from) → \(to) ✓")]
    case .denied(let reason): givenBy = [SheetField(label: "Given by", value: "✗ \(reason)")]
    }
    let simulator = project.simulator.map { [SheetField(label: "Simulator", value: "a new device for this agent, same type as \($0.baseDevice)")] } ?? []
    let trust = plan.needsTrust ? [SheetField(label: "Trust", value: "Claude Code does not trust \(project.repoPath) yet. Starting marks it as trusted in ~/.claude.json (a backup is kept); otherwise the agent would stop at the trust question.")] : []
    return givenBy + trust + [SheetField(label: "Agent", value: plan.roleDisplayName.map { "\($0) (\(plan.agentName))" } ?? plan.agentName),
            SheetField(label: "Role", value: roleName),
            SheetField(label: "Model", value: model.isEmpty ? "set in the role file" : model),
            SheetField(label: "Branch", value: plan.branch),
            SheetField(label: "Worktree", value: plan.worktreePath)] + simulator + [
            SheetField(label: "Command", value: plan.commandPreview)]
}

/// Everything the approval sheet shows, in order, so the user sees exactly what approving will do.
func approveSheetFields(plan: ApprovalPlan) -> [SheetField] {
    let changes: String
    if plan.isAnalysis { changes = "none: nothing is merged" }
    else if plan.ahead == 0 { changes = "no commits of its own: nothing to merge" }
    else {
        let commits = plan.ahead == 1 ? "1 commit" : "\(plan.ahead) commits"
        changes = plan.filesChanged.map { "\(commits), \($0) file\($0 == 1 ? "" : "s")" } ?? commits
    }
    var fields = [SheetField(label: "Branch", value: plan.branch)]
    if !plan.isAnalysis { fields.append(SheetField(label: "Merge into", value: "\(plan.base) (fast-forward only)")) }
    fields.append(SheetField(label: "Changes", value: changes))
    if !plan.isAnalysis { fields.append(SheetField(label: "Screenshots", value: "\(plan.screenshotCount)")) }
    fields.append(SheetField(label: "Reviewed commit", value: String(plan.head.prefix(7))))
    if !plan.isAnalysis { fields.append(SheetField(label: "Command", value: plan.commandPreview)) }
    return fields
}

/// The fix request that is filled in when the main branch has moved on and the branch cannot be merged as it is.
func rebaseRequestText(base: String) -> String {
    "\(base) has new commits, so this branch cannot be merged as it is. Please rebase it onto \(base), resolve any conflicts, redo the build and screenshots, and update the Report."
}

func canSendFix(notes: String, busy: Bool) -> Bool {
    !busy && !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

enum ShellScreen: String, Equatable { case dashboard, tasks, terminals, timeline, team, plan, git, stats, settings }

extension ShellScreen {
    /// The screen saved with the window; a new install (nothing saved) and anything unknown open the Dashboard.
    init(stored: String) { self = ShellScreen(rawValue: stored) ?? .dashboard }
}

/// One thing on the Dashboard's "Waiting for you" list. Every kind is a decision the panel already offers elsewhere.
struct DashboardWaitingItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// More than one card in review: the top bar's "Approve round" (N88).
        case approveRound(Int)
        /// A round the PM proposed waits for "Start round".
        case round([String])
        /// An agent's question for the user (its id).
        case question(String)
        /// Fix notes or a failed packet escalated to the user (the card id).
        case fix(String)
        case review(String)
        case startApproval(String)
        /// Initialize git or Push to GitHub for the project (N163).
        case git(GitSuggestion)
        /// A round of the PM's plan.json waits for "Approve plan & start round" (its name, N167).
        case planRound(String)
        /// A panel message to an agent that was dropped after 30 minutes (the outbox item's id, N211).
        case undelivered(String)
    }
    let kind: Kind

    var id: String {
        switch kind {
        case .approveRound: "approve-round"
        case .round: "round"
        case .question(let id): "question|" + id
        case .fix(let id): "fix|" + id
        case .review(let id): "review|" + id
        case .startApproval(let id): "start|" + id
        case .git(.initializeGit): "git|init"
        case .git(.pushToGitHub): "git|push"
        case .planRound: "plan-round"
        case .undelivered(let id): "undelivered|" + id
        }
    }

    /// The colour of the item's chip and first button (N182): the kind is told apart by it, without group headers.
    var tint: WaitingTint {
        switch kind {
        case .question: .question
        case .approveRound, .review: .review
        case .fix, .undelivered: .fix
        case .startApproval, .round, .planRound: .start
        case .git: .git
        }
    }
}

/// One colour per kind of waiting item, in the order the kinds are listed: an agent that asks is blocked, so questions come first.
enum WaitingTint: Int {
    case question, review, fix, start, git

    /// The chip's background is the colour at this opacity over the row.
    static let chipOpacity = 0.16

    var color: Color {
        switch self {
        case .question: Tok.waitQuestion
        case .review: Tok.waitReview
        case .fix: Tok.waitFix
        case .start: Tok.waitStart
        case .git: Tok.ink2
        }
    }

    /// The Dark value (contrast checks).
    var hex: UInt32 { hex(in: .dark) }

    /// The colour in `palette`.
    func hex(in palette: Palette) -> UInt32 {
        switch self {
        case .question: palette.waitQuestion
        case .review: palette.waitReview
        case .fix: palette.waitFix
        case .start: palette.waitStart
        case .git: palette.ink2
        }
    }
}

/// Everything that needs the user, in the order the Dashboard lists it: questions, reviews (Approve round first), fixes, start approvals
/// and rounds (the whole rounds first), then the project's git steps. Within a kind the oldest comes first: a question by when the panel
/// first saw it (`questionAsked`), a card by when its file last changed; an unknown age goes after the known ones, in the order given.
func dashboardWaitingItems(questions: [String], fixes: [String], cards: [TaskCard], roundWaiting: [String], approveRound: Int, git: [GitSuggestion] = [],
                           planRound: String? = nil, questionAsked: [String: Date] = [:], undelivered: [String] = []) -> [DashboardWaitingItem] {
    let modified = Dictionary(cards.map { ($0.id, $0.modified) }, uniquingKeysWith: { a, _ in a })
    func since(_ kind: DashboardWaitingItem.Kind) -> Date? {
        switch kind {
        case .question(let id): questionAsked[id]
        case .fix(let id), .review(let id), .startApproval(let id): modified[id] ?? nil
        default: nil
        }
    }
    var kinds: [DashboardWaitingItem.Kind] = questions.map { .question($0) }
    if approveRound > 1 { kinds.append(.approveRound(approveRound)) }
    kinds += cards.filter { $0.status == .review }.map { .review($0.id) }
    kinds += fixes.map { .fix($0) }
    kinds += undelivered.map { .undelivered($0) }
    if let planRound { kinds.append(.planRound(planRound)) }
    if !roundWaiting.isEmpty { kinds.append(.round(roundWaiting)) }
    kinds += cards.filter { $0.status == .awaitingStartApproval }.map { .startApproval($0.id) }
    kinds += git.map { .git($0) }
    // Sort key: kind, whole rounds first, known age before unknown, oldest, then the order given (so the sort is stable).
    func key(_ index: Int, _ kind: DashboardWaitingItem.Kind) -> (Int, Int, Int, Date, Int) {
        let whole: Bool = switch kind { case .approveRound, .round, .planRound: true; default: false }
        let date = since(kind)
        return (DashboardWaitingItem(kind: kind).tint.rawValue, whole ? 0 : 1, date == nil ? 1 : 0, date ?? .distantPast, index)
    }
    return kinds.enumerated().sorted { key($0.offset, $0.element) < key($1.offset, $1.element) }.map { DashboardWaitingItem(kind: $0.element) }
}

/// The one "waiting for you" number (top bar and the Dashboard's list): every entry of the list but Approve round, which only bundles the reviews already listed.
func waitingDecisionCount(_ items: [DashboardWaitingItem]) -> Int {
    items.filter { if case .approveRound = $0.kind { false } else { true } }.count
}

/// "A1 · Clean up…" for a waiting row; a title that already starts with the id keeps it once.
func waitingRowTitle(id: String, title: String) -> String {
    guard title.hasPrefix(id) else { return "\(id) · \(title)" }
    let rest = title.dropFirst(id.count)
    return rest.first.map { $0.isLetter || $0.isNumber } == true ? "\(id) · \(title)" : title
}

/// The Dashboard's "Plan a round": the same rule as the Tasks screen's button (autopilot not Off, agents can start), with the reason when it is not.
func planRoundButtonState(autopilotAvailable: Bool, mode: AutopilotMode, canStart: Bool, startReason: String?) -> StartButtonState {
    if !autopilotAvailable { return StartButtonState(enabled: false, help: "The PM autopilot is not available for this project.") }
    if mode == .off { return StartButtonState(enabled: false, help: "The PM autopilot is Off. Switch it to Shadow or On to let the PM plan a round.") }
    guard canStart else { return StartButtonState(enabled: false, help: startReason ?? "Starting agents is not set up for this project.") }
    return StartButtonState(enabled: true, help: "The PM picks the next 2 to 4 todo cards; one approval starts them.")
}

/// "$4.12 of $20.00 today", or without a limit "$4.12 today"; nil before the cost was read.
func dashboardCostText(today: Double?, limit: Double?) -> String? {
    guard let today else { return nil }
    return limit.map { String(format: "$%.2f of $%.2f today", today, $0) } ?? String(format: "$%.2f today", today)
}

func dashboardAuthorityText(enabled: Bool, startedToday: Int, perDay: Int) -> String {
    enabled ? "PM authority · \(startedToday) of \(perDay) today" : "PM authority · off"
}

/// SwiftUI shows only one of several `.alert` modifiers stacked on the same view (the others silently never appear), so each screen
/// has ONE alert and this says which question it is asking.
enum TeamAlertKind: Equatable { case discardForSelection, discardForNewRole, deleteRole }
func teamAlertKind(selection: Bool, newRole: Bool, delete: Bool) -> TeamAlertKind? {
    if delete { return .deleteRole }
    if newRole { return .discardForNewRole }
    if selection { return .discardForSelection }
    return nil
}

enum ShellAlertKind: Equatable { case leavingTeam, switchingProject, closeTask }
func shellAlertKind(leavingTeam: Bool, switchingProject: Bool, closeTask: Bool) -> ShellAlertKind? {
    if closeTask { return .closeTask }
    if switchingProject { return .switchingProject }
    if leavingTeam { return .leavingTeam }
    return nil
}

/// Switching the project while a role is being edited would strand the edit (the role belongs to the old project): ask first.
func projectSwitchNeedsConfirmation(screen: ShellScreen, teamIsDirty: Bool) -> Bool { screen == .team && teamIsDirty }
enum ScreenChange: Equatable { case go, askFirst }

/// Leaving the Team screen with unsaved edits asks first; every other change of screen just happens.
func screenChange(from: ShellScreen, to: ShellScreen, teamIsDirty: Bool) -> ScreenChange {
    from == .team && to != .team && teamIsDirty ? .askFirst : .go
}

/// The role a card's agent belongs to: agent names are `<role>-<task>` and role names have no "-", so it is the text before the first "-".
private func roleName(ofAgent agent: String) -> String? {
    guard let dash = agent.firstIndex(of: "-") else { return nil }
    return String(agent[..<dash])
}

/// How an agent shows in the list: "Pixel · V1" when its role has a display name (the agent is found through the task whose worktree it
/// runs in); otherwise the label it always had. Agents the panel did not start (your own PM session) are not on any card and keep it.
func agentLabel(agent: AgentStatus, cards: [TaskCard], displayNames: [String: String], projectWorktrees: URL) -> String {
    let plain = agent.title.isEmpty ? agent.paneID : agent.title
    guard !agent.cwd.isEmpty else { return plain }
    let cwd = AgentInboxModel.standardizedPath(agent.cwd)
    for card in cards {
        guard let cardAgent = card.agent, let worktree = AgentInboxModel.worktreePath(of: card, worktrees: projectWorktrees) else { continue }
        guard cwd == worktree || cwd.hasPrefix(worktree + "/") else { continue }
        if let role = roleName(ofAgent: cardAgent), let name = displayNames[role] { return "\(name) · \(card.id)" }
        return plain
    }
    return plain
}

/// A card's agent for the task header: "Pixel (dev-v1)" when its role has a display name, else the technical name.
func agentTitle(cardAgent: String, displayNames: [String: String]) -> String {
    if let role = roleName(ofAgent: cardAgent), let name = displayNames[role] { return "\(name) (\(cardAgent))" }
    return cardAgent
}
