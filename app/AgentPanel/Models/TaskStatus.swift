import Foundation

/// Task card status. Raw values match the card front matter written by the Phase 0 scripts.
enum TaskStatus: Equatable {
    case todo, awaitingStartApproval, doing, review, needsFix, done, blocked, cancelled
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "todo": self = .todo
        case "awaiting-start-approval": self = .awaitingStartApproval
        case "doing": self = .doing
        case "review": self = .review
        case "needs-fix": self = .needsFix
        case "done": self = .done
        case "blocked": self = .blocked
        case "cancelled": self = .cancelled
        default: self = .unknown(raw)
        }
    }

    /// The text written in the card's `status:` line.
    var raw: String {
        switch self {
        case .todo: return "todo"
        case .awaitingStartApproval: return "awaiting-start-approval"
        case .doing: return "doing"
        case .review: return "review"
        case .needsFix: return "needs-fix"
        case .done: return "done"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .unknown(let raw): return raw
        }
    }

    /// A card in one of these states has an agent, a worktree and a simulator, and its files are not merged yet.
    var holdsAgent: Bool {
        switch self {
        case .doing, .needsFix, .review: return true
        default: return false
        }
    }
}
