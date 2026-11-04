import SwiftUI

/// Chooses how the agent's conversation is restarted. Nothing is sent until Start; Return presses Cancel.
struct NewConversationSheet: View {
    let agentLabel: String
    let modes: [RestartMode]
    let onStart: (RestartMode) -> Void
    let onCancel: () -> Void
    @State private var mode: RestartMode

    /// `mode`: the choice it opens with ("Compact conversation…" opens it on Compact, N346).
    init(agentLabel: String, mode: RestartMode = .handoff, modes: [RestartMode] = RestartMode.allCases, onStart: @escaping (RestartMode) -> Void, onCancel: @escaping () -> Void) {
        self.agentLabel = agentLabel
        self.modes = modes
        self.onStart = onStart
        self.onCancel = onCancel
        _mode = State(initialValue: modes.contains(mode) ? mode : (modes.first ?? .handoff))
    }

    static let defaultButton = SheetButton.cancel

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New conversation").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text("\(agentLabel) · a long conversation costs more and answers slower.").font(Tok.Font.body).foregroundStyle(Tok.ink2)
            }
            VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
                ForEach(modes, id: \.self) { option in
                    Button { mode = option } label: {
                        HStack(alignment: .top, spacing: Tok.Space.m) {
                            Image(systemName: mode == option ? "largecircle.fill.circle" : "circle").foregroundStyle(mode == option ? Tok.go : Tok.ink3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title).font(Tok.Font.body).foregroundStyle(Tok.ink)
                                Text(option.detail).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Tok.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
                        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(mode == option ? Tok.go : Tok.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                }
            }
            Text("Only while the agent is idle. The panel never interrupts a working agent.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.defaultAction)
                Button("Start") { onStart(mode) }.buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 520)
        .background(Tok.bg)
        .escapeCancels(onCancel)
    }
}
