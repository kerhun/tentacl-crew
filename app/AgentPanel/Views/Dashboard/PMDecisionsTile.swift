import SwiftUI

/// N385: the PM decisions tile. Today's agent questions the PM answered (with its answer) and the ones it sent to you; a row opens the
/// card's timeline.
struct PMDecisionsTile: View {
    let day: PMDecisionsDay
    let onOpen: (String) -> Void

    var body: some View {
        DashboardTileShell(title: "PM decisions", meta: day.header) {
            if day.isEmpty {
                Text(DashboardFeeds.noDecisions).font(.system(size: 13)).foregroundStyle(Tok.ink3)
            } else {
                Scroller {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(day.rows) { row($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func row(_ r: PMDecisionRow) -> some View {
        Button { onOpen(r.cardID) } label: {
            HStack(spacing: 8) {
                if r.toYou { Chip(text: "to you", style: .ask) } else { Chip(text: "answered", tint: Tok.you) }
                Self.line(r).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(r.toYou && r.critical ? "critical" : HighlightsTile.clock(r.time))
                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(r.toYou && r.critical ? Tok.askText : Tok.ink3).fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(DashboardRowButtonStyle())
        .help("Open the timeline of \(r.cardID)")
        .accessibilityLabel(Self.spoken(r))
    }

    /// "A5-q1 Which colour? → **Circle**"; a question sent to you has no answer.
    static func line(_ r: PMDecisionRow) -> Text {
        let q = Text(r.ref + " ").foregroundStyle(Tok.ink3) + Text(r.question).foregroundStyle(Tok.ink)
        return r.toYou || r.answer.isEmpty ? q : q + Text(" → ").foregroundStyle(Tok.ink3) + Text(r.answer).fontWeight(.semibold).foregroundStyle(Tok.ink)
    }

    static func spoken(_ r: PMDecisionRow) -> String {
        r.toYou ? "Sent to you\(r.critical ? ", critical" : ""): \(r.ref) \(r.question)" : "PM answered \(r.ref) \(r.question) with \(r.answer) at \(HighlightsTile.clock(r.time))"
    }
}
