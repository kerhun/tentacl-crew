import SwiftUI

/// N385: the Fix loops tile. Cards back from review, their open F-notes and the fix round; round 3 and later are red. A row opens the card.
struct FixLoopsTile: View {
    let loops: [FixLoopSummary]
    let onOpen: (String) -> Void

    static func meta(_ n: Int) -> String? { n == 0 ? nil : n == 1 ? "1 card back from review" : "\(n) cards back from review" }

    var body: some View {
        DashboardTileShell(title: "Fix loops", meta: Self.meta(loops.count)) {
            if loops.isEmpty {
                Text(DashboardFeeds.noFixLoops).font(.system(size: 13)).foregroundStyle(Tok.ink3)
            } else {
                Scroller {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(loops) { row($0) }
                        if loops.contains(where: \.isRed) {
                            Text(DashboardFeeds.redLine).font(.system(size: 12)).foregroundStyle(Tok.ink3)
                                .padding(.horizontal, 8).padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func row(_ l: FixLoopSummary) -> some View {
        Button { onOpen(l.id) } label: {
            HStack(spacing: 8) {
                Text(l.id).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Tok.ink)
                (Text(l.title).foregroundStyle(Tok.ink) + Text(l.notesText.isEmpty ? "" : " · " + l.notesText).foregroundStyle(Tok.ink3))
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Chip(text: "round \(l.round)", tint: Self.tint(l))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(DashboardRowButtonStyle())
        .help("Open \(l.id)")
        .accessibilityLabel("\(l.id) \(l.title), fix round \(l.round)\(l.notesText.isEmpty ? "" : ", " + l.notesText)")
    }

    /// Rounds 1–2 wait (yellow), round 3 and later stop (red).
    static func tint(_ l: FixLoopSummary) -> Color { l.isRed ? Tok.stop : Tok.wait }
}

/// A Dashboard list row: the raised colour while hovered or pressed.
struct DashboardRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}
