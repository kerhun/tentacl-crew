import SwiftUI

/// The floating question panel (N373): the oldest open question with its options, reply box or Allow/Deny (the question card itself, so
/// answers take the in-app path), "+N more", and × that hides it until the next new question. Orange is Tok.ask only.
struct QuestionPanel: View {
    static let width: CGFloat = 380
    @Bindable var content: QuestionPanelContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = content.item {
                header(item)
                QuestionCard(inbox: item.inbox, question: item.question, suggestion: item.suggestion, escalation: item.escalation)
                    .padding(Tok.Space.s)
                footer(item)
            }
        }
        .frame(width: Self.width, alignment: .topLeading)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.ask.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ item: QuestionPanelItem) -> some View {
        HStack(spacing: Tok.Space.s) {
            WaitingDot(pulse: !reduceMotion)
            Text(Self.headline(total: content.total)).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ask).lineLimit(1)
            Spacer(minLength: 0)
            if let waited = item.askedAt.map({ Stats.durationText(max(content.now.timeIntervalSince($0), 0)) }) {
                Text(waited).font(Tok.Font.small.monospacedDigit()).foregroundStyle(Tok.ask)
            }
            Button { content.onClose() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Tok.ink3)
                .help("Hide until the next new question. The agent keeps waiting.")
                .accessibilityLabel("Close question panel")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Tok.ask.opacity(0.12))
    }

    private func footer(_ item: QuestionPanelItem) -> some View {
        HStack(spacing: Tok.Space.m) {
            Text(item.projectName).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1)
            if content.more > 0 { Text("+\(content.more) more").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink2) }
            Spacer(minLength: 0)
            if item.pmPane != nil {
                Button("Let the PM decide") { content.onPassOn(item) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink2)
                    .help("Sends the question to the PM's chat; it stays open until it is answered")
            }
            Button("Open Tentacl") { content.onOpenApp(item) }.buttonStyle(.plain).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink)
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 2)
    }

    static func headline(total: Int) -> String {
        (total == 1 ? "1 agent waiting" : "\(total) agents waiting") + " · stays on top"
    }
}

/// The orange dot; it pulses unless Reduce Motion is on (then a static ring).
private struct WaitingDot: View {
    let pulse: Bool
    @State private var on = false

    var body: some View {
        Circle().fill(Tok.ask).frame(width: 8, height: 8)
            .overlay { Circle().stroke(Tok.ask.opacity(pulse && on ? 0.05 : 0.3), lineWidth: pulse && on ? 6 : 3) }
            .onAppear { if pulse { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true } } }
            .accessibilityHidden(true)
    }
}
