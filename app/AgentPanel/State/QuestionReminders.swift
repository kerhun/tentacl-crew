import Foundation

/// Watches the open agent questions that wait for the user and says when to remind (5 and 15 min) and when to tell the PM (30 min).
/// Pure: the caller hands in the questions and the clock. Each stage fires once per question, however often the poll restarts;
/// when a stalled poll finds several stages due at once only the latest fires. Nothing here answers a question.
struct QuestionReminders {
    enum Stage: Int, Comparable {
        case none, five, fifteen, thirty
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        var minutes: Int { [0, 5, 15, 30][rawValue] }
    }

    static let after: [(Stage, TimeInterval)] = [(.thirty, 1800), (.fifteen, 900), (.five, 300)]

    struct Due: Equatable { let question: PendingQuestion; let stage: Stage }
    struct Result: Equatable {
        /// Reminders at 5 and 15 min, and the 30-min notice for the PM.
        var due: [Due] = []
        /// Ids of questions that went away: their notifications (the first one and the reminders) are to be removed.
        var cancelled: [String] = []
    }

    private var firstSeen: [String: Date] = [:]
    private var fired: [String: Stage] = [:]

    mutating func step(questions: [PendingQuestion], now: Date) -> Result {
        var result = Result()
        let open = Set(questions.map(\.id))
        for id in firstSeen.keys.sorted() where !open.contains(id) { result.cancelled.append(id) }
        firstSeen = firstSeen.filter { open.contains($0.key) }
        fired = fired.filter { open.contains($0.key) }
        for q in questions {
            let since = firstSeen[q.id] ?? now
            firstSeen[q.id] = since
            let reached = Self.after.first { now.timeIntervalSince(since) >= $0.1 }?.0 ?? .none
            guard reached > (fired[q.id] ?? .none) else { continue }
            fired[q.id] = reached
            result.due.append(Due(question: q, stage: reached))
        }
        return result
    }

    /// The second and third notification of one question. `letPM`: show "Let the PM decide" (15 min, only when the autopilot has a suggestion).
    static func notification(for due: Due, prefix: String, sound: NotificationSound, bounce: Bool, letPM: Bool) -> AppNotification {
        let q = due.question
        let who = q.cardID.isEmpty || q.agentLabel.contains(q.cardID) ? q.agentLabel : q.agentLabel + " · " + q.cardID
        return AppNotification(id: "remind|\(q.id)|\(due.stage.minutes)", title: NotificationText.plain("\(prefix)Still waiting · \(who) (\(due.stage.minutes) min)"),
                               body: NotificationText.plain(q.question.text), cardID: q.cardID, sound: sound, bounce: bounce && due.stage == .five,
                               questionID: q.id, actions: QuestionNotice.actions(for: q.question, letPM: letPM && due.stage == .fifteen))
    }

    /// The line the PM gets at 30 min.
    static func pmLine(_ q: PendingQuestion) -> String {
        let text = q.question.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return "\(q.agentLabel)\(q.cardID.isEmpty || q.agentLabel.contains(q.cardID) ? "" : " · " + q.cardID) has waited 30 min for the user's answer: “\(String(text.prefix(140)))”"
    }

    /// The notification ids to remove for a question: the first one and both reminders.
    static func notificationIDs(_ questionID: String) -> [String] { [questionID, "remind|\(questionID)|5", "remind|\(questionID)|15"] }
}
