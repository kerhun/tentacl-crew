import SwiftUI

/// Where the user tells the agent what to change. The note goes into the card's "Fix notes" and to the agent.
struct FixRequestSheet: View {
    let card: TaskCard
    @Binding var notes: String
    let state: ActionState
    let onSend: () -> Void
    let onCancel: () -> Void

    @Environment(\.snapshotMode) private var snapshot

    private var running: Bool { if case .running = state { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Request a fix for \(card.id)").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text(card.title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2)
            }
            Text("Your note is saved in the card under \"Fix notes\", the card moves to needs-fix and the agent is asked to work on it.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            editor
                .padding(Tok.Space.s)
                .frame(height: 140, alignment: .topLeading)
                .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
                .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("What should change?").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(.horizontal, Tok.Space.m + 1).padding(.vertical, Tok.Space.s + 3).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Fix request")
            statusLine
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction).disabled(running)
                Button("Send fix request", action: onSend).buttonStyle(ConfirmButtonStyle())
                    .disabled(!canSendFix(notes: notes, busy: running))
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 560)
        .background(Tok.bg)
    }

    /// ImageRenderer cannot draw a TextEditor (it shows a placeholder glyph), so snapshots draw the text instead.
    @ViewBuilder private var editor: some View {
        if snapshot {
            Text(notes).font(Tok.Font.body).foregroundStyle(Tok.ink).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            TextEditor(text: $notes).font(Tok.Font.body).foregroundStyle(Tok.ink).scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch state {
        case .running(let m): HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m).font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .failed(let m): Text(m).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        case .idle, .done: EmptyView()
        }
    }
}

#Preview("FixRequestSheet") {
    FixRequestSheet(card: TaskCard(id: "A4", project: "demo", status: .review, agent: "dev-a4", branch: "feat/a4", kind: nil, files: [], title: "Tighten the home header",
                                   sections: [:], url: URL(fileURLWithPath: "/tmp/A4.md")),
                    notes: .constant("The title is cut off on small phones."), state: .idle, onSend: {}, onCancel: {})
}
