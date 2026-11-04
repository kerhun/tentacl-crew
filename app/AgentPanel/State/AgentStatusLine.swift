import Foundation

/// The one live line that says what an agent does now (N251), for the Agents pane and the Terminals sidebar.
enum AgentStatusLine {
    /// The longest line kept; the view truncates at the end, the tooltip shows all of it.
    static let limit = 160

    /// A waiting agent shows what it waits for; else the program's live 7501 message, else the transcript's last action, else the state line.
    static func make(question: AgentQuestion?, live: String?, transcript: String?, state: String) -> String {
        for candidate in [question.map(waiting), live, transcript, state] {
            let line = clean(candidate ?? "")
            if !line.isEmpty { return line }
        }
        return ""
    }

    /// N380: the agent's question is with the PM (held by the relay).
    static let withPM = "Question with PM"

    static func make(heldByPM: Bool, question: AgentQuestion?, live: String?, transcript: String?, state: String) -> String {
        heldByPM ? withPM : make(question: question, live: live, transcript: transcript, state: state)
    }

    /// "asks: Colour?", "permission: Bash npm test", "approval: plan".
    static func waiting(_ q: AgentQuestion) -> String {
        switch q.kind {
        case .permission:
            if let command = q.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty { return "permission: Bash " + command }
            return "permission: " + (q.text.isEmpty ? q.title : q.text)
        case .plan: return "approval: " + (q.title.isEmpty ? "plan" : q.title)
        case .signIn: return "needs sign-in"
        case .choice, .freeText: return "asks: " + (q.title.isEmpty ? q.text : q.title)
        }
    }

    /// One line: the first non-empty line, spaces folded, cut at `limit` with an ellipsis.
    static func clean(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }.first { !$0.isEmpty } ?? ""
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }
}
