import Foundation

/// Every control a tour step can point at (N311, spec agent-panel-tutorial-tasarim). A view marks its control with `.tutorialAnchor(.id)`.
enum TutorialAnchorID: String, CaseIterable, Hashable {
    // First launch
    case setupButton, addProject, addProjectKind, addProjectStartsPM, addProjectCreate, teamRoster
    // Dashboard
    case rail, projectPicker, dashboardWaiting, dashboardGoal, dashboardPlanRound, pmChat, agents, inbox
    // Chat
    case pmState, chatMessage, chatSend, chatQuestion, chatStop, chatShowAll, chatNewConversation
    // Tasks
    case taskModes, taskRowStatus, taskNew, taskTabs, nextStep, nextStepMore
    // Plan
    case planHeader, planNeedsYou, planApprove, planAskRound
    // Preview
    case previewButton, previewAddress, previewPick, previewScreenshot
    // Settings
    case settingsSearch, settingsCategories, settingsTours

    /// What VoiceOver reads after "Highlighted:" on the coach card.
    var spokenName: String {
        switch self {
        case .setupButton: "Setup"
        case .addProject: "Add project"
        case .addProjectKind: "New project or Existing project"
        case .addProjectStartsPM: "Start the PM and write a project summary"
        case .addProjectCreate: "Create project"
        case .teamRoster: "Roster"
        case .rail: "Screens"
        case .projectPicker: "Project"
        case .dashboardWaiting: "Waiting for you"
        case .dashboardGoal: "Goal"
        case .dashboardPlanRound: "Plan a round"
        case .pmChat: "PM chat"
        case .agents: "Agents"
        case .inbox: "Inbox"
        case .pmState: "PM state"
        case .chatMessage: "Message the PM"
        case .chatSend: "Send"
        case .chatQuestion: "Question"
        case .chatStop: "Stop"
        case .chatShowAll: "Show all"
        case .chatNewConversation: "New conversation"
        case .taskModes: "List modes"
        case .taskRowStatus: "Task state"
        case .taskNew: "New task"
        case .taskTabs: "Detail tabs"
        case .nextStep: "Next step"
        case .nextStepMore: "More"
        case .planHeader: "Plan"
        case .planNeedsYou: "Needs you"
        case .planApprove: "Approve plan and start round"
        case .planAskRound: "Ask the PM to plan a round"
        case .previewButton: "Preview"
        case .previewAddress: "Address"
        case .previewPick: "Pick element"
        case .previewScreenshot: "Screenshot to card"
        case .settingsSearch: "Search settings"
        case .settingsCategories: "Categories"
        case .settingsTours: "Tours"
        }
    }
}

enum TutorialTourID: String, CaseIterable, Hashable, Codable {
    case firstLaunch, dashboard, chat, tasks, plan, preview, settings

    var title: String {
        switch self {
        case .firstLaunch: "First launch"
        case .dashboard: "Dashboard"
        case .chat: "Chat"
        case .tasks: "Tasks"
        case .plan: "Plan"
        case .preview: "Preview"
        case .settings: "Settings"
        }
    }

    /// The Dashboard tour's Round step points at the Round tile (N342); while that tile is not on the grid its anchor is missing and
    /// the tour passes over the step, like any step whose target is not on screen.
    var tour: TutorialTour { TutorialTours.tour(self) }
}

/// One step: where it is, what it points at, what it says. Nothing here presses a button.
struct TutorialStep: Equatable {
    /// The screen the step is on; nil: wherever the target is (a sheet). The tour goes to the screen itself.
    var screen: ShellScreen?
    let anchor: TutorialAnchorID
    let title: String
    let text: String
    var tryIt: String?
    /// The target is missing (no open question): a dashed example is drawn at this anchor instead of skipping the step.
    var exampleAt: TutorialAnchorID?
    /// This anchor missing (no page in the Preview): the step says `aloneText` and is the tour's only step.
    var aloneWithout: TutorialAnchorID?
    var aloneText: String?
    /// The target is missing: the ring goes around this one instead (the Preview icon is hidden while there is no page).
    var orAt: TutorialAnchorID?
    /// The user's own move that ends the step: the tour goes on when this anchor appears (the Add project sheet opens).
    var advancesWhen: TutorialAnchorID?
}

struct TutorialTour: Equatable {
    let id: TutorialTourID
    /// Raised when the steps change: a saved progress of an older version starts over (only that tour).
    let version: Int
    let steps: [TutorialStep]
}

enum TutorialTours {
    static let all: [TutorialTour] = TutorialTourID.allCases.map(tour)

    /// The tour "Tour this screen" opens (nil: the screen has none).
    static func forScreen(_ screen: ShellScreen, hasProjects: Bool) -> TutorialTourID? {
        guard hasProjects else { return .firstLaunch }
        switch screen {
        case .dashboard: return .dashboard
        case .tasks: return .tasks
        case .plan: return .plan
        case .settings: return .settings
        case .team: return .firstLaunch
        case .terminals, .timeline, .git, .stats: return nil
        }
    }

    static func tour(_ id: TutorialTourID) -> TutorialTour {
        switch id {
        case .firstLaunch:
            return TutorialTour(id: id, version: 1, steps: [
                TutorialStep(screen: .tasks, anchor: .setupButton, title: "Check the tools.",
                             text: "Setup lists what Tentacl Crew needs and installs what is missing after you confirm."),
                TutorialStep(screen: .tasks, anchor: .addProject, title: "Add your first project.",
                             text: "Pick a new folder or a repo you already have. Everything Tentacl Crew does happens inside a project.",
                             tryIt: "click Add project", advancesWhen: .addProjectKind),
                TutorialStep(anchor: .addProjectKind, title: "New or existing?",
                             text: "New makes a fresh folder; Existing uses a repo you already have."),
                TutorialStep(anchor: .addProjectStartsPM, title: "Let the PM start.",
                             text: "Leave this on: the PM starts right after the project is made and writes a short summary."),
                TutorialStep(anchor: .addProjectCreate, title: "Create it.",
                             text: "Nothing is pushed anywhere; the project stays on this Mac.", advancesWhen: .teamRoster),
                TutorialStep(screen: .team, anchor: .teamRoster, title: "Meet your team.",
                             text: "These roles do the work. Roster shows who is busy; Roles changes how each one works.",
                             tryIt: "open Roles to see a role's prompt"),
            ])
        case .dashboard:
            return TutorialTour(id: id, version: 1, steps: [
                TutorialStep(screen: .dashboard, anchor: .rail, title: "Move between screens.", text: "Each icon is a screen; ⌘1–⌘9 jump to them."),
                TutorialStep(screen: .dashboard, anchor: .projectPicker, title: "You are in this project.", text: "Switch projects or add one here."),
                TutorialStep(screen: .dashboard, anchor: .dashboardWaiting, title: "Waiting for you.",
                             text: "Anything that needs your decision lands here: questions, reviews, approvals. Click a row to decide it in front."),
                TutorialStep(screen: .dashboard, anchor: .dashboardGoal, title: "Goal and round.", text: "The Round tile: the project's goal and the round of tasks being worked on."),
                TutorialStep(screen: .dashboard, anchor: .dashboardPlanRound, title: "Plan the next round.", text: "Ask the PM to plan the next set of tasks."),
                TutorialStep(screen: .dashboard, anchor: .pmChat, title: "Talk to the PM.",
                             text: "This is your main conversation; the Chat tour shows it step by step."),
                TutorialStep(screen: .dashboard, anchor: .agents, title: "Your agents.",
                             text: "Who is working and on which task. Click an agent to open its task; Terminals shows its screen."),
                TutorialStep(screen: .dashboard, anchor: .inbox, title: "Inbox.", text: "The same waiting items, from any screen."),
            ])
        case .chat:
            return TutorialTour(id: id, version: 1, steps: [
                TutorialStep(screen: .dashboard, anchor: .pmState, title: "The PM's state.",
                             text: "The dot is green while idle, blue while working. Without a PM, Start PM is in the chat; Stop PM is in ⋯ (asks first)."),
                TutorialStep(screen: .dashboard, anchor: .chatMessage, title: "Write to the PM.", text: "Plain words are fine. You can type while the PM works."),
                TutorialStep(screen: .dashboard, anchor: .chatSend, title: "Send.", text: "Or ⌘↵. While the PM is busy, the Waiting: line says what it waits for."),
                TutorialStep(screen: .dashboard, anchor: .chatQuestion, title: "The PM asks you.",
                             text: "When the PM needs a decision it asks here. Click an option or press its number, 1–9.",
                             tryIt: "press 1 when a real question comes", exampleAt: .chatMessage),
                TutorialStep(screen: .dashboard, anchor: .chatStop, title: "Stop the PM's turn.",
                             text: "Stop interrupts what the PM is doing now, like Esc in its terminal. The PM stays open."),
                TutorialStep(screen: .dashboard, anchor: .chatShowAll, title: "Long messages fold.",
                             text: "Show all opens the whole message; it stays open when you switch tabs."),
                TutorialStep(screen: .dashboard, anchor: .chatNewConversation, title: "Start fresh.",
                             text: "New conversation is in ⋯."),
            ])
        case .tasks:
            return TutorialTour(id: id, version: 1, steps: [
                TutorialStep(screen: .tasks, anchor: .taskModes, title: "Three views.", text: "By round, By status, or Done."),
                TutorialStep(screen: .tasks, anchor: .taskRowStatus, title: "Each task's state.", text: "todo, doing, review, done — at a glance."),
                TutorialStep(screen: .tasks, anchor: .taskNew, title: "Write a task.", text: "The PM usually writes them; you can too."),
                TutorialStep(screen: .tasks, anchor: .taskTabs, title: "Everything about the task.",
                             text: "Overview, Card, Report, Changes, Screenshots. ⌘[ and ⌘] switch."),
                TutorialStep(screen: .tasks, anchor: .nextStep, title: "Do the next step.",
                             text: "This button changes with the task: Start, Prepare review, Approve."),
                TutorialStep(screen: .tasks, anchor: .nextStepMore, title: "More.", text: "Request fix, Edit card and opening the worktree are here."),
                TutorialStep(screen: .tasks, anchor: .nextStep, title: "Approve merges.",
                             text: "Before anything runs, the sheet lists what approving will do."),
            ])
        case .plan:
            return TutorialTour(id: id, version: 1, steps: [
                TutorialStep(screen: .plan, anchor: .planHeader, title: "Where the project is.", text: "The goal, the rounds and what comes next."),
                TutorialStep(screen: .plan, anchor: .planNeedsYou, title: "The PM's open questions.", text: "Answer opens the chat with a draft."),
                TutorialStep(screen: .plan, anchor: .planApprove, title: "Approve the round.",
                             text: "The PM proposed these tasks. Approve to start them, Edit to change, or Not now."),
                TutorialStep(screen: .plan, anchor: .planAskRound, title: "Need a new round?", text: "Ask the PM to plan one."),
            ])
        case .preview:
            return TutorialTour(id: id, version: 1, steps: [
                TutorialStep(screen: .dashboard, anchor: .previewButton, title: "See the page.",
                             text: "When the PM shares a page, open it here next to the chat.",
                             aloneWithout: .previewAddress, aloneText: "The Preview opens when the PM shares a page.", orAt: .pmChat),
                TutorialStep(screen: .dashboard, anchor: .previewAddress, title: "Any address.", text: "Type a local address and press Return."),
                TutorialStep(screen: .dashboard, anchor: .previewPick, title: "Point at what to change.",
                             text: "Click Pick element, then a part of the page, and write what should change."),
                TutorialStep(screen: .dashboard, anchor: .previewScreenshot, title: "Keep a screenshot.", text: "Saves the page into the task card."),
            ])
        case .settings:
            return TutorialTour(id: id, version: 1, steps: [
                TutorialStep(screen: .settings, anchor: .settingsSearch, title: "Find a setting.", text: "Type its name."),
                TutorialStep(screen: .settings, anchor: .settingsCategories, title: "Categories.",
                             text: "PM & Autopilot sets how much the PM may do alone."),
                TutorialStep(screen: .settings, anchor: .settingsTours, title: "Tours.", text: "See your progress or reset the tours."),
            ])
        }
    }
}
