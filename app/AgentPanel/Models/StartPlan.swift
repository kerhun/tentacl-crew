import Foundation

/// What starting a task will do; shown to the user in the confirmation sheet before anything runs.
struct StartPlan: Equatable {
    let card: TaskCard
    let agentName: String
    let branch: String
    let rolePath: String
    let worktreePath: String
    /// The script call as the user would type it, arguments quoted one by one.
    let commandPreview: String
    /// The role that will run (its technical name) and the display name its role file gives it, if any.
    var roleName: String = "dev"
    var roleDisplayName: String? = nil
    /// Whether the team chart lets the card's giver give this task (not applicable when the project has no chart).
    var authority: StartAuthority = .notApplicable
    /// Claude Code does not trust the project's folder yet; starting marks it trusted first (the sheet says so).
    var needsTrust = false
}

enum StartAuthority: Equatable {
    case notApplicable
    case allowed(from: String, to: String)
    /// The reason the chart does not allow it; the user may still give the task themselves.
    case denied(String)
}

extension StartPlan: Identifiable {
    var id: String { card.id }
}

struct StartedAgent: Equatable {
    let agent: String
    let paneID: String
    let worktreePath: String
    let udid: String
}

enum StartError: Error, Equatable {
    case invalid(String)
    case capacity(Int)
    case conflict(String)
    case alreadyStarting
    /// The team chart does not let the card's giver give this task; the user can confirm giving it themselves.
    case notAuthorized(String)
    case notStartable(String)
    /// The card asks for a role nobody defined, but a template of that name exists: the user can add it from the template (`detail` says where the panel looked).
    case missingRole(name: String, template: String, detail: String)
    case spawnFailed(String)
    case promptFailed(String)
    case cardWriteFailed(String)
    /// The start failed and so did the automatic cleanup: `manual` lists what the user has to remove by hand.
    case cleanupFailed(cause: String, detail: String, manual: String)

    /// The cause alone, without any claim about cleanup (used when the cleanup itself failed).
    var plainMessage: String {
        switch self {
        case .promptFailed(let m): return "The agent was started but did not accept the task: \(m)."
        case .cardWriteFailed(let m): return "The agent was started but the card could not be updated: \(m)."
        case .cleanupFailed(let cause, _, _): return cause
        default: return message
        }
    }

    /// A sentence for the user.
    var message: String {
        switch self {
        case .invalid(let m): return "Cannot start: \(m)"
        case .capacity(let n): return "Cannot start: \(n) tasks are already running (the project's limit)."
        case .conflict(let m): return "Cannot start: it touches the same files as a running task. \(m)"
        case .alreadyStarting: return "This task is already being started."
        case .notAuthorized(let m): return "Cannot start: \(m)"
        case .notStartable(let m): return "Cannot start: \(m)"
        case .missingRole(let name, _, let detail): return "Cannot start: no role called \"\(name)\" is defined (\(detail)). Add the \"\(name)\" role from its template: it opens the Team screen with the form filled in."
        case .spawnFailed(let m): return "The agent could not be started: \(m)"
        case .promptFailed(let m): return "The agent was started but did not accept the task (it was stopped again): \(m)"
        case .cardWriteFailed(let m): return "The agent was started but the card could not be updated (it was stopped again): \(m)"
        case .cleanupFailed(let cause, let detail, let manual): return "\(cause) The automatic cleanup also failed (\(detail)). Remove manually: \(manual)."
        }
    }
}
