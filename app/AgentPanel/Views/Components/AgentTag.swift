import SwiftUI

/// What the agent tag of a task says: the role's display name and the agent ("Developer · dev-n12"), from the card's `roles:` and `agent:`.
struct AgentTagInfo: Equatable {
    enum Style: Equatable { case running(TaskPhase), finished }

    let text: String
    let style: Style
    /// The day the Decision section records, for a finished card; nil while the agent runs or when the card says none.
    let date: String?

    /// A running agent's tag opens the agent's terminal; a finished one is only a record.
    var opensTerminal: Bool { if case .running = style { return true } else { return false } }
    var label: String { date.map { "\(text) · \($0)" } ?? text }

    /// nil when the card never had an agent. `phase` is the running phase (nil for a card whose agent is not running).
    static func make(_ card: TaskCard, displayNames: [String: String], phase: TaskPhase?) -> AgentTagInfo? {
        guard let agent = card.agent, !agent.isEmpty else { return nil }
        let role = card.roles.first ?? "dev"
        let text = "\(displayNames[role] ?? role) · \(agent)"
        if let phase { return AgentTagInfo(text: text, style: .running(phase), date: nil) }
        return AgentTagInfo(text: text, style: .finished, date: decisionDate(card))
    }

    /// The first `yyyy-MM-dd` in the card's Decision section ("Approved 2026-10-18 14:25 by ...").
    static func decisionDate(_ card: TaskCard) -> String? {
        guard let decision = card.sections["Decision"] else { return nil }
        return decision.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression).map { String(decision[$0]) }
    }
}

extension AgentTagInfo {
    /// The Decision section's `yyyy-MM-dd` plus its ` HH:mm` when the next words give one; midnight otherwise.
    static func decisionDateTime(_ card: TaskCard, calendar: Calendar = .current) -> Date? {
        guard let decision = card.sections["Decision"],
              let range = decision.range(of: #"\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?"#, options: .regularExpression) else { return nil }
        let text = String(decision[range])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = text.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.date(from: text)
    }
}

/// The tag on a task row and in the task header. While the agent runs it wears the phase colour and `onOpen` opens its terminal;
/// a finished card shows the agent in grey with the approval date.
struct AgentTag: View {
    let info: AgentTagInfo
    var onOpen: () -> Void = {}

    var body: some View {
        let color: Color = { if case .running(let phase) = info.style { return phase.tone.color } else { return Tok.ink3 } }()
        let capsule = Text(info.label).font(Tok.Font.small.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
        if info.opensTerminal {
            Button(action: onOpen) { capsule.contentShape(Capsule()) }
                .buttonStyle(.plain).help("Open this agent's terminal.").accessibilityLabel("\(info.label), open terminal")
        } else {
            capsule.accessibilityLabel(info.label)
        }
    }
}
