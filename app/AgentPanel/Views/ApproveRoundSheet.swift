import SwiftUI

/// One final approval for a whole round: every card in review with its checks. Nothing runs until "Approve all".
struct ApproveRoundSheet: View {
    @Binding var rows: [ApproveRound.Row]
    let result: ApproveRound.Result?
    let running: Bool
    let onConfirm: () -> Void
    let onClose: () -> Void

    /// Return closes the sheet; the merges need a click or ⌘↵.
    static let defaultButton = SheetButton.cancel
    static let confirmShortcut = SheetShortcut.commandReturn

    @Environment(\.snapshotMode) private var snapshot

    private var ticked: Int { rows.filter(\.ticked).count }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Approve round").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text("This merges the ticked tasks one by one, in dependency order, rebasing one that fell behind main. It stops at the first failure. The panel cannot undo a merge.")
                    .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if snapshot { list } else { ScrollView { list }.frame(maxHeight: 360) }
            statusLine
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button(result == nil ? "Cancel" : "Close", action: onClose).buttonStyle(PanelButtonStyle()).keyboardShortcut(.defaultAction).disabled(running)
                Button("Approve all (\(ticked))", action: onConfirm)
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.return, modifiers: .command).disabled(running || ticked == 0)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 620)
        .background(Tok.bg)
        .escapeCancels { if !running { onClose() } }
    }

    private var list: some View {
        VStack(spacing: Tok.Space.s + 2) {
            ForEach($rows) { $row in
                HStack(alignment: .top, spacing: Tok.Space.m) {
                    Toggle("", isOn: $row.ticked).labelsHidden().disabled(running)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.card.id) · \(row.card.title)").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(2)
                        ForEach(row.checks, id: \.label) { check in
                            HStack(alignment: .top, spacing: Tok.Space.m) {
                                Text(check.label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 96, alignment: .leading)
                                Text(check.value).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Tok.Space.m + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
                .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if running {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Merging…").font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        } else if let result {
            Text(result.text).font(Tok.Font.body).foregroundStyle(result.failure == nil ? Tok.ink2 : Tok.wait).fixedSize(horizontal: false, vertical: true)
        }
    }
}
