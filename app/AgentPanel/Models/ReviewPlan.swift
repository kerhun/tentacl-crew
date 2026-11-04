import Foundation

/// What approving a task will do; shown to the user in the approval sheet before anything runs.
struct ApprovalPlan: Equatable {
    let card: TaskCard
    let agentName: String
    let branch: String
    let worktreePath: String
    let base: String
    /// The branch tip the review packet was built from (and the one that will be merged).
    let head: String
    /// Commits the branch has on top of the main branch.
    let ahead: Int
    let filesChanged: Int?
    let screenshotCount: Int
    /// Analysis tasks change nothing: approving only marks the card done and closes the agent.
    let isAnalysis: Bool
    /// The merge call as the user would type it.
    let commandPreview: String
}

extension ApprovalPlan: Identifiable {
    var id: String { card.id }
}

enum ReviewError: Error, Equatable {
    case invalid(String)
    /// The branch moved on after the packet was built (or the packet has no Head line): prepare the review again.
    case stale
    case notFastForward
    /// Approve tried to rebase the branch onto main and it conflicts; the agent was asked to resolve it.
    case rebaseConflict([String])
    case userFilesInTheWay([String])
    case worktreeDirty
    /// The branch tip is not the one the user looked at.
    case headMoved
    case alreadyRunning
    case agentGone
    case packetMissing(String)
    /// The merge happened (it cannot be undone) but a later step did not: what is done, what failed, what to do by hand.
    case mergedButIncomplete(done: String, failed: String, manual: String)
    case failed(String)

    var message: String {
        switch self {
        case .invalid(let m): return m
        case .stale: return "The agent committed after this review packet was built. Prepare the review again."
        case .notFastForward: return "The main branch has moved on, so this cannot be merged as it is. Request a fix and ask the agent to rebase onto the main branch."
        case .rebaseConflict(let files): return "Rebasing onto the main branch conflicts in \(files.joined(separator: ", ")). Nothing was changed; the agent was asked to rebase and resolve it."
        case .userFilesInTheWay(let files): return "Unsaved changes in your repository are in the way: \(files.joined(separator: ", ")). Save or stash them, then approve again. Nothing was changed."
        case .worktreeDirty: return "The agent's worktree has unsaved work. Ask the agent to commit it (or discard it), then prepare the review again. Nothing was changed."
        case .headMoved: return "The branch changed while you were looking at it. Prepare the review again. Nothing was changed."
        case .alreadyRunning: return "This task is already being handled."
        case .agentGone: return "The agent is no longer running, so it cannot receive a fix request. Nothing was changed."
        case .packetMissing(let m): return m.isEmpty ? "The review packet is incomplete. Prepare the review first." : m
        case .mergedButIncomplete(let done, let failed, let manual): return "\(done) \(failed) Do by hand: \(manual)"
        case .failed(let m): return m
        }
    }
}
