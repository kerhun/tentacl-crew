import SwiftUI

/// The widget gallery (N343): a sheet over the Dashboard with one card per widget (a small preview, the title, one sentence and
/// Add / Added). The PM chat is not listed; it is always there.
struct WidgetGallery: View {
    let layout: DashboardGridLayout
    let onAdd: (DashboardWidget) -> Void
    let onClose: () -> Void

    static let width: CGFloat = 760
    /// N344: the grid is full, so Add is disabled.
    static let noRoom = "No room: make a tile smaller or remove one."
    static var widgets: [DashboardWidget] { DashboardWidget.allCases.filter { $0 != .chat } }

    /// Which button a card shows (N354): only `.add` is the blue confirm button; the other two are the plain disabled one.
    enum CardButton: Equatable { case add, added, noRoom }
    static func button(added: Bool, room: Bool) -> CardButton { added ? .added : (room ? .add : .noRoom) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tok.Space.s) {
                Text("Add a widget").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tok.ink2).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.ink3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Tok.line)
            // N385: eleven cards are taller than a small window; the cards scroll when the sheet does not fit.
            ViewThatFits(in: .vertical) {
                cards
                ScrollView { cards }
            }
        }
        .frame(width: Self.width)
        // N385 F1: the shadow belongs to the sheet's shape only. On the whole view it was drawn under every card, text and bar inside
        // (the content is not one layer), a grey haze over the cards.
        .background(RoundedRectangle(cornerRadius: 16).fill(Tok.pane).shadow(color: .black.opacity(0.45), radius: 40, y: 30))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tok.line, lineWidth: 1))
        .escapeCancels(onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add a widget")
        .accessibilityAddTraits(.isModal)
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The PM chat is always there. Everything else is yours to add, size and remove.")
                .font(.system(size: 12.5)).foregroundStyle(Tok.ink3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(Self.widgets, id: \.self) { w in card(w) }
            }
        }
        .padding(20)
    }

    private func card(_ w: DashboardWidget) -> some View {
        let added = layout.contains(w)
        let room = layout.hasRoom(for: w)
        return VStack(alignment: .leading, spacing: 8) {
            preview(w)
            Text(w.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Tok.ink)
            Text(w.blurb).font(.system(size: 12)).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            if !added && !room {
                Text(Self.noRoom).font(.system(size: 11.5)).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                // Blue confirm for Add (orange is reserved for "waiting for your decision"); Added, and Add with no room (N354),
                // are the plain disabled button: neutral grey, not a faded blue that reads as "active but pale".
                switch Self.button(added: added, room: room) {
                case .added: Button("Added") {}.buttonStyle(PanelButtonStyle()).disabled(true)
                case .add: Button("Add") { onAdd(w) }.buttonStyle(ConfirmButtonStyle())
                case .noRoom: Button("Add") {}.buttonStyle(PanelButtonStyle()).disabled(true)
                }
            }
            .accessibilityLabel(added ? "\(w.title) added" : "Add \(w.title)")
            .accessibilityHint(!added && !room ? Self.noRoom : "")
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tok.line, lineWidth: 1))
        .opacity(added ? 0.75 : 1)
        .accessibilityElement(children: .contain)
    }

    /// A few bars in the widget's colours: a hint of what it shows, not its data.
    @ViewBuilder private func preview(_ w: DashboardWidget) -> some View {
        if w == .terminal { terminalPreview } else { barsPreview(w) }
    }

    /// N359: a small dark terminal with a prompt and a cursor.
    private var terminalPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("$ claude").foregroundStyle(Color.white.opacity(0.55))
            HStack(spacing: 2) {
                Text("›").foregroundStyle(Tok.go)
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.8)).frame(width: 6, height: 11)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .topLeading)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func barsPreview(_ w: DashboardWidget) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.bars(w).enumerated()), id: \.offset) { _, bar in
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3).fill(bar.color).frame(width: g.size.width * bar.share, height: 5)
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private static func bars(_ w: DashboardWidget) -> [(color: Color, share: CGFloat)] {
        switch w {
        case .chat: []
        case .waiting: [(Tok.waitQuestion, 0.7), (Tok.waitReview, 0.55)]
        case .agents: [(Tok.ask, 0.6), (Tok.work, 0.75), (Tok.ink3, 0.4)]
        case .round: [(Tok.go, 0.9), (Tok.raise, 0.5)]
        case .cost: [(Tok.work, 0.4), (Tok.work, 0.8)]
        case .highlights: [(Tok.ink3, 0.8), (Tok.ink3, 0.65), (Tok.ink3, 0.72)]
        case .usage: [(Tok.go, 0.42), (Tok.wait, 0.71)]
        case .git: [(Tok.ink2, 0.55), (Tok.ink3, 0.35)]
        case .terminal: []
        case .reviewPackets: [(Tok.go, 0.35), (Tok.raise, 0.6), (Tok.wait, 0.45)]
        case .fixLoops: [(Tok.wait, 0.7), (Tok.stop, 0.55)]
        case .pmDecisions: [(Tok.you, 0.65), (Tok.you, 0.5), (Tok.ask, 0.4)]
        }
    }
}
