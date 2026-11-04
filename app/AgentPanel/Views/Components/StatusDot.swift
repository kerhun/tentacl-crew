import SwiftUI

extension TaskPhase.Tone {
    var color: Color {
        switch self {
        case .orange: return Tok.ask
        case .blue: return Tok.dotBlue
        case .green: return Tok.go
        case .grey: return Tok.ink3
        case .red: return Tok.stop
        case .yellow: return Tok.wait
        case .work: return Tok.work
        }
    }
}

/// The status tag of a running task: a coloured capsule with the phase name. The same tag shows on the task row and on the agent's card.
struct TaskPhaseTag: View {
    let phase: TaskPhase

    var body: some View {
        let color = phase.tone.color
        Text(phase.label).font(Tok.Font.small.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .help(phase.help)
            .accessibilityLabel(phase.label)
    }
}

struct StatusDot: View {
    let status: TaskStatus

    static func color(for status: TaskStatus) -> Color {
        switch status {
        case .review, .awaitingStartApproval: return Tok.ask
        case .doing: return Tok.work
        case .needsFix: return Tok.wait
        case .done: return Tok.go
        case .blocked: return Tok.stop
        case .todo, .cancelled, .unknown: return Tok.ink3
        }
    }

    var body: some View {
        let color = Self.color(for: status)
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay { if color == Tok.ask { Circle().stroke(Tok.ask.opacity(0.25), lineWidth: 3) } }
            .accessibilityHidden(true)
    }
}

#Preview("StatusDot") {
    HStack(spacing: 12) {
        ForEach([TaskStatus.todo, .doing, .review, .needsFix, .done, .blocked], id: \.label) { StatusDot(status: $0) }
    }
    .padding().background(Tok.pane)
}

extension TaskStatus {
    /// Short human label used in chips.
    var label: String {
        switch self {
        case .todo: return "todo"
        case .awaitingStartApproval: return "approve start"
        case .doing: return "doing"
        case .review: return "review"
        case .needsFix: return "needs fix"
        case .done: return "done"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .unknown(let raw): return raw.isEmpty ? "unknown" : raw
        }
    }
}
