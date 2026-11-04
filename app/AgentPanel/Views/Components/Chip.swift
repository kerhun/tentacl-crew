import SwiftUI

struct Chip: View {
    enum Style { case neutral, ask, ok, problem }
    let text: String
    var style: Style = .neutral
    /// A colour of its own (an Activity kind); it wins over the style.
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(Tok.Font.small)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        if let tint { return tint }
        switch style {
        case .neutral: return Tok.ink2
        case .ask: return Tok.askText
        case .ok: return Tok.go
        case .problem: return Tok.wait
        }
    }

    private var background: Color {
        if let tint { return tint.opacity(0.16) }
        switch style {
        case .neutral: return Tok.raise
        case .ask: return Tok.ask.opacity(0.16)
        case .ok: return Tok.go.opacity(0.14)
        case .problem: return Tok.wait.opacity(0.16)
        }
    }
}

#Preview("Chip") {
    HStack { Chip(text: "review", style: .ask); Chip(text: "dev-3"); Chip(text: "done", style: .ok) }
        .padding().background(Tok.pane)
}
