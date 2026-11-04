import SwiftUI
import AppKit

/// The floating question card under the top bar's waiting pill (N376, was the N371 strip): over the content, nothing moves.
/// "Question · role · card · N min" in Tok.askText as in Waiting for you, the question on up to two lines (whole in the tooltip),
/// +N more, Answer (filled Tok.ask), Later (5 min) and from 15 min with a PM suggestion Let the PM decide. The frame carries the
/// shared question glow (pulsing; still with Reduce Motion); a small notch points up at the pill.
struct BlockedBannerView: View {
    let content: BlockedBanner.Content
    /// Where the notch sits, from the card's leading edge (nil: no notch).
    var notchX: CGFloat? = nil
    var onAnswer: () -> Void = {}
    var onLater: () -> Void = {}
    var onLetPMDecide: (() -> Void)?
    /// For the rows of questions the PM has (N380).
    var role: (PendingQuestion) -> String? = { _ in nil }
    var onAnswerMyself: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    static let radius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            if content.hasQuestion { question }
            if !content.held.isEmpty { heldRows }
        }
        .padding(Tok.Space.l)
        .frame(width: BlockedBanner.cardWidth, alignment: .leading)
        .modifier(CardFrame(lit: content.hasQuestion, style: QuestionHighlight.style(reduceMotion: reduceMotion), radius: Self.radius))
        // The shadow on the surface only: on the whole card it would be drawn under every text and button too.
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Tok.raise)
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 18, y: 8))
        .overlay(alignment: .topLeading) { if let notchX { notch.offset(x: notchX - 7, y: -6.5) } }
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.hasQuestion ? "\(content.heading): \(content.question)" : "Questions with the PM")
    }

    /// N380: "WITH THE PM · N" and a muted row for each (Answer myself), under the question or alone.
    private var heldRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            if content.hasQuestion { Rectangle().fill(Tok.line).frame(height: 1).padding(.vertical, 2) }
            Text("WITH THE PM · \(content.held.count)").font(Tok.Font.small).tracking(0.3).foregroundStyle(Tok.ink2)
            ForEach(content.held) { h in
                HeldQuestionRow(held: h, role: role(h.question), compact: true) { onAnswerMyself(h.id) }
                    .padding(.horizontal, -10)
                    .transition(.opacity)
            }
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(spacing: Tok.Space.s) {
                Text(content.heading).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.askText).lineLimit(1)
                Spacer(minLength: Tok.Space.s)
                if let more = content.moreText {
                    Text(more).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.askText).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Tok.ask.opacity(0.16), in: Capsule())
                        .help("More questions wait; Answer goes through all of them with ‹ ›")
                }
            }
            Text(content.question).font(Tok.Font.body).foregroundStyle(Tok.ink)
                .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(content.fullQuestion)
            if let title = content.pmDecide, let onLetPMDecide {
                // Its own row: the title carries the PM's suggestion and would push Answer out of the card.
                Button(title, action: onLetPMDecide).buttonStyle(PanelButtonStyle()).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Sends the question to the PM's chat; you still see it until it is answered")
            }
            HStack(spacing: Tok.Space.s) {
                Spacer(minLength: 0)
                Button("Later (5 min)", action: onLater).buttonStyle(PanelButtonStyle()).fixedSize()
                    .help("Hides this card for 5 minutes or until a new question; the agent keeps waiting")
                Button(action: onAnswer) {
                    Text("Answer").font(Tok.Font.body.weight(.semibold))
                        .foregroundStyle(Tok.askInk)
                        .padding(.horizontal, Tok.Space.l).frame(height: 28)
                        .background(Tok.ask, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).fixedSize()
                .help(content.more > 0 ? "Opens the oldest question; the window's ‹ › go through the others" : "Opens the question")
            }
        }
    }

    /// A small triangle toward the pill, in the card's colours (its Tok.ask edges continue the frame).
    private var notch: some View {
        ZStack {
            NotchShape(closed: true).fill(Tok.raise)
            NotchShape(closed: false).stroke(content.hasQuestion ? Tok.ask.opacity(0.9) : Tok.line, lineWidth: content.hasQuestion ? 1.5 : 1)
        }
        .frame(width: 14, height: 7)
        .accessibilityHidden(true)
    }
}

/// The question glow while a question waits for the user; a plain hairline when the card only lists questions the PM has (N380).
private struct CardFrame: ViewModifier {
    let lit: Bool
    let style: QuestionHighlight
    let radius: CGFloat

    func body(content: Content) -> some View {
        if lit { content.modifier(QuestionGlow(style: style, cornerRadius: radius)) }
        else { content.overlay(RoundedRectangle(cornerRadius: radius).stroke(Tok.line)) }
    }
}

private struct NotchShape: Shape {
    let closed: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY + (closed ? 1 : 0)))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY + (closed ? 1 : 0)))
        if closed { p.closeSubpath() }
        return p
    }
}

/// The waiting pill's frame in the window, for the card under it.
struct WaitingPillAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// Esc closes the card while it shows, unless a text field or a terminal has the keys or a sheet is open (then Esc is theirs).
/// A local key monitor: the card never takes focus.
struct BlockedCardEscape: ViewModifier {
    let active: Bool
    let onEscape: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: active) { _, _ in sync() }
            .onDisappear { remove() }
    }

    private func sync() {
        remove()
        guard active else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, let window = event.window else { return event }
            let r = window.firstResponder
            let takesText = r is NSText || r is LiveTerminalNSView || (r as? NSView)?.enclosingScrollView?.documentView is NSText
            guard BlockedBanner.escCloses(cardShown: true, responderTakesText: takesText, sheetOpen: window.attachedSheet != nil || window.isSheet) else { return event }
            onEscape()
            return nil
        }
    }

    private func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

/// The top bar's "N agents waiting on you" pill (N371), next to Inbox; only shown for N > 0. A click opens or closes the question card (N376).
/// N380: questions the PM is answering show as a muted "1 with PM" part (also alone, so a held question is never invisible).
struct WaitingOnYouPill: View {
    let count: Int
    var withPM = 0
    /// A narrow top bar: only the dot and the number (the full title is the tooltip and the accessibility label).
    var compact = false
    /// A crowded top bar: the "with PM" part shows only the clock and the number (N388).
    var compactHeld = false
    let action: () -> Void

    var body: some View {
        if let title = BlockedBanner.pillTitle(count, withPM: withPM) {
            Button(action: action) {
                HStack(spacing: 4) {
                    if count > 0 {
                        HStack(spacing: Tok.Space.s) {
                            Circle().fill(Tok.askInk).frame(width: 6, height: 6)
                            Text(compact ? "\(count) waiting" : BlockedBanner.pillTitle(count) ?? "").font(Tok.Font.body.weight(.semibold)).monospacedDigit().lineLimit(1)
                        }
                        .foregroundStyle(Tok.askInk)
                        .padding(.horizontal, Tok.Space.m).frame(height: 28)
                        .background(Tok.ask, in: Capsule())
                    }
                    if let held = HeldQuestion.pillText(withPM) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                            Text(compactHeld ? "\(withPM)" : held).font(Tok.Font.body.weight(.medium)).monospacedDigit().lineLimit(1)
                        }
                        .foregroundStyle(Tok.ink2)
                        .padding(.horizontal, Tok.Space.m).frame(height: 28)
                        .background(Tok.raise, in: Capsule())
                        .overlay(Capsule().stroke(Tok.line))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).fixedSize()
            .help(count > 0 ? "\(title): stopped on a question for you. Shows or hides the question card."
                  : "\(title): the PM is answering; it comes to you if the PM does not. Shows or hides the question card.")
            .anchorPreference(key: WaitingPillAnchorKey.self, value: .bounds) { $0 }
            .accessibilityLabel(title)
        }
    }
}
