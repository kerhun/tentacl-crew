import SwiftUI

/// Design B (N370, soft glow N375): a 1.5 pt Tok.ask frame with a soft Tok.ask glow fading outward, both breathing every
/// `QuestionHighlight.period`; still (Reduce Motion), both held at their middle strength. The glow is a blurred copy of the
/// frame's own shape, so its corners stay concentric. It shows up to `QuestionGlow.reach` past the frame: give the row
/// that much room in any clipping container (see `WaitingTile`).
struct QuestionGlow: ViewModifier {
    let style: QuestionHighlight
    var cornerRadius: CGFloat = 10
    @State private var lit = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.questionGlowFixedStrength) private var fixedStrength

    /// How far the glow shows past the frame's edge.
    static let reach: CGFloat = 10
    static let ringStep: CGFloat = 0.5
    static let rings = 18
    /// Ring `i`'s share of the glow: strongest at the frame, gone at `reach`.
    static func ringFade(_ i: Int) -> Double { let t = 1 - Double(i) / Double(rings); return t * t }

    /// The glow's opacity at `strength`; light theme gets a lighter wash so orange on white stays clean, not muddy.
    static func glowOpacity(strength: Double, dark: Bool) -> Double { dark ? 0.30 + 0.45 * strength : 0.16 + 0.30 * strength }

    func body(content: Content) -> some View {
        let strength: Double = fixedStrength ?? (style == .still ? 0.5 : (lit ? 1 : 0))
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(Tok.ask.opacity(0.07), in: shape)
            .background {
                // Concentric half-point rings outward from the frame, each at radius + its distance, fading quadratically: a soft
                // glow without blur filters (they are not drawn in every render path, and a filter halo is not concentric).
                ZStack {
                    ForEach(0..<Self.rings, id: \.self) { i in
                        let d = (CGFloat(i) + 0.5) * Self.ringStep
                        RoundedRectangle(cornerRadius: cornerRadius + d).stroke(Tok.ask.opacity(Self.ringFade(i)), lineWidth: Self.ringStep).padding(-d)
                    }
                }
                .opacity(Self.glowOpacity(strength: strength, dark: scheme == .dark))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay(shape.strokeBorder(Tok.ask.opacity(0.55 + 0.35 * strength), lineWidth: 1.5))
            .onAppear {
                guard style == .pulsing, fixedStrength == nil else { return }
                withAnimation(Self.pulse) { lit = true }
            }
            .onChange(of: style) { _, new in
                if new == .still { withAnimation(nil) { lit = false } }
                else { withAnimation(Self.pulse) { lit = true } }
            }
    }

    private static var pulse: Animation { .easeInOut(duration: QuestionHighlight.period / 2).repeatForever(autoreverses: true) }
}

extension EnvironmentValues {
    /// Shots only: hold every question glow at one pulse strength (0 dimmest, 1 brightest).
    @Entry var questionGlowFixedStrength: Double? = nil
}
