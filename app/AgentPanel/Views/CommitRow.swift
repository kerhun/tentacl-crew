import SwiftUI

/// One commit on one line (N269): short sha, card chip, type chip, the subject without its prefix and card, the age. A click on the row
/// shows the full message below it. The push sheet adds a checkbox; the Git screen's "Not pushed" list has none.
struct CommitRow: View {
    let short: String
    let subject: String
    var date: Date?
    /// The full message under the subject; nil while it is not read (the subject is shown alone).
    var message: String?
    /// The card the subject names when the subject itself has no `(N123)` (the Git screen reads it from merges too).
    var card: String?
    var expanded = false
    /// nil: no checkbox.
    var ticked: Bool?
    var tickDisabled = false
    var onTick: () -> Void = {}
    var onToggle: () -> Void = {}

    private var parsed: CommitSubject { CommitSubject(subject) }

    var body: some View {
        let p = parsed
        let dim = ticked == false
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(spacing: Tok.Space.s + 2) {
                if let ticked {
                    Toggle("", isOn: Binding(get: { ticked }, set: { _ in onTick() })).toggleStyle(.checkbox).labelsHidden()
                        .disabled(tickDisabled)
                        .help(ticked ? "Untick to keep this commit and every newer one on this Mac" : "Tick to push this commit and every older one")
                }
                HStack(spacing: Tok.Space.s + 2) {
                    Text(short).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tok.ink3).frame(width: 58, alignment: .leading)
                    // A fixed column, so the subjects line up whether or not a row names a card.
                    Group { if let card = p.card ?? card { Self.chip(card, colour: Tok.work, mono: false) } }
                        .frame(width: 48, alignment: .leading)
                    if let type = p.type { typeChip(type, scope: p.scope) }
                    Text(p.text).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let date { Text(GitDetails.ago(date)).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1).fixedSize() }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tok.ink3)
                        .frame(width: 10)
                }
                // Kept-back rows fade; the checkbox stays clear so it can be ticked again.
                .opacity(dim ? 0.45 : 1)
            }
            if expanded {
                Text(fullMessage).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Tok.ink2).lineSpacing(2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s + 2)
                    .background(Tok.bg, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
            }
        }
        .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.s + 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(subject)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var fullMessage: String {
        guard let message, !message.isEmpty else { return subject }
        return subject + "\n\n" + message
    }

    private func typeChip(_ type: String, scope: String?) -> some View {
        let colour = Self.colour(of: type)
        return HStack(spacing: 3) {
            Text(type).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(colour)
            if let scope { Text(scope).font(.system(size: 10)).foregroundStyle(colour.opacity(0.75)).lineLimit(1) }
        }
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        .fixedSize()
    }

    static func chip(_ text: String, colour: Color, mono: Bool) -> some View {
        Text(text).font(mono ? .system(size: 10.5, design: .monospaced) : .system(size: 10.5, weight: .semibold)).foregroundStyle(colour)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(colour.opacity(0.35)))
            .fixedSize()
    }

    static func colour(of type: String) -> Color {
        switch type {
        case "feat": Tok.go
        case "fix": Tok.wait
        case "test", "tests": Tok.work
        case "docs": Tok.you
        case "revert": Tok.stop
        default: Tok.ink2
        }
    }
}
