import Foundation

/// One task card (a Markdown file with front matter), parsed read-only.
/// `priority:` in a card's front matter; missing or unknown means normal.
enum CardPriority: String, Equatable, CaseIterable {
    case high, normal, low
}

struct TaskCard: Identifiable, Equatable {
    let id: String
    let project: String
    let status: TaskStatus
    let agent: String?
    let branch: String?
    let kind: String?
    let files: [String]
    let title: String
    /// Section name (text after "## ") to its trimmed body.
    let sections: [String: String]
    let url: URL
    /// A hash of the front matter text as read. Writers refuse to write when it no longer matches the file, so an edit made
    /// by someone else while the card was on screen is never overwritten. Empty for cards built by hand (tests).
    var fingerprint: String = ""
    /// A hash of everything below the front matter, so a section write can tell the body changed since it was read. Empty for cards built by hand.
    var bodyFingerprint: String = ""
    /// The roles the card asks for (`roles: [dev]`); the first one is started. Empty means the default role, `dev`.
    var roles: [String] = []
    /// Who gave the task (`from: reviewer`); nil means the user. It is the card's own claim, checked against the team chart when a start is planned.
    var from: String? = nil
    /// When the card file was last changed (read from the file by the repository); nil for a card built by hand.
    var modified: Date? = nil
    /// When the card file was created (read from the file by the repository); nil for a card built by hand.
    var created: Date? = nil
    /// What the user wants first (`priority: high | normal | low`); the PM prefers high cards when it picks a round.
    var priority: CardPriority = .normal
}
