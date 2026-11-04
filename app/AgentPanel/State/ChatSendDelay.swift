import Foundation

/// A message typed into an agent's terminal cannot be taken back, so the Command box holds each one briefly first (Edit / Undo).
enum ChatSendDelay {
    static let seconds = 3
    static let hold: Duration = .seconds(seconds)
}

/// A message the user sent that has not gone to the agent yet: its draft text and images (put back on Undo or Edit),
/// the copies of the images saved for sending, and when it goes.
struct HeldMessage {
    let id = "held-" + UUID().uuidString
    let text: String
    let images: [PendingImage]
    let stored: [URL]
    let deadline: Date

    /// Whole seconds left, rounded up and never below 1 (it goes at 0).
    func secondsLeft(now: Date) -> Int { max(1, Int(deadline.timeIntervalSince(now).rounded(.up))) }

    static func mark(seconds: Int) -> String { "Sending in \(seconds) s…" }
}
