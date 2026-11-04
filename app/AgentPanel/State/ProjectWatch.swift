import Foundation

/// What the panel keeps for one project, open or not: its inbox, its autopilot, the cards last read, what was already notified and told to
/// its PM, and its PM hand-off state.
@MainActor
final class ProjectWatch {
    var project: ProjectConfig
    let inbox: AgentInboxModel
    let autopilot: AutopilotModel
    /// The cards read at the last poll (the selected project's own list lives in `PanelModel.cards`).
    var cards: [CardLoadResult] = []
    var planner = NotificationPlanner()
    var pmNotice: PMNotice
    var reminders = QuestionReminders()
    /// Lines for the PM that wait to be added to `pmNotice` (the 30-min question notice).
    var noticeLines: [String] = []
    /// The Report each needs-fix card had when it was first seen in that state (see `TaskPhase`).
    var fixReports = FixReportTracker()
    /// Why this project's PM is due a fresh conversation with hand-off (N171).
    var freshPending: FreshStartTrigger?
    var freshSafePointFired = false
    /// The plan.json last read for the PM hand-off; the open project's own lives in `RoundModel`.
    var plan: PlanFile?

    init(project: ProjectConfig, inbox: AgentInboxModel, autopilot: AutopilotModel, pmNotice: PMNotice = PMNotice()) {
        self.project = project; self.inbox = inbox; self.autopilot = autopilot; self.pmNotice = pmNotice
    }

    var taskCards: [TaskCard] { cards.compactMap { if case .card(let c) = $0 { c } else { nil } } }

    /// Questions, finished work and fix notes waiting for the user in this project.
    func waitingCount(cards list: [TaskCard]) -> Int {
        let approvals = list.filter { $0.status == .review || $0.status == .awaitingStartApproval }.count
        return approvals + autopilot.forUser(inbox.questions).count + autopilot.fixesForYou.count
    }
}
