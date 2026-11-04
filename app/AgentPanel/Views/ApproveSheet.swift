import SwiftUI

/// The last step before a merge: it lists what approving will do. Nothing runs until "Approve and merge".
struct ApproveSheet: View {
    let plan: ApprovalPlan
    let state: ActionState
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Return presses Cancel; the merge needs a click or ⌘↵.
    static let defaultButton = SheetButton.cancel
    static let confirmShortcut = SheetShortcut.commandReturn

    private var running: Bool { if case .running = state { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Approve \(plan.card.id)").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text(plan.card.title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2)
            }
            Text(plan.isAnalysis
                 ? "This marks the task done and closes its agent. Nothing is merged."
                 : "This merges the branch into \(plan.base), marks the task done and closes its agent. The panel cannot undo a merge.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
                ForEach(approveSheetFields(plan: plan), id: \.label) { field in
                    HStack(alignment: .top, spacing: Tok.Space.m) {
                        Text(field.label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 104, alignment: .leading)
                        Text(field.value).font(field.label == "Command" || field.label == "Reviewed commit" ? Tok.Font.mono : Tok.Font.body)
                            .foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Tok.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            statusLine
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.defaultAction).disabled(running)
                Button(plan.isAnalysis ? "Approve" : "Approve and merge", action: onConfirm)
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.return, modifiers: .command).disabled(running)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 560)
        .background(Tok.bg)
        .escapeCancels { if !running { onCancel() } }
    }

    @ViewBuilder private var statusLine: some View {
        switch state {
        case .running(let m): HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m).font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .failed(let m): Text(m).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        case .idle, .done: EmptyView()
        }
    }
}

#Preview("ApproveSheet · merge") {
    ApproveSheet(plan: ApprovalPlan(card: TaskCard(id: "A4", project: "demo", status: .review, agent: "dev-a4", branch: "feat/a4", kind: nil, files: [], title: "Tighten the home header",
                                                   sections: [:], url: URL(fileURLWithPath: "/tmp/A4.md")),
                                    agentName: "dev-a4", branch: "feat/a4", worktreePath: "/repo/.agent-worktrees/feat-a4", base: "main",
                                    head: "0123456789abcdef0123456789abcdef01234567", ahead: 2, filesChanged: 3, screenshotCount: 2, isAnalysis: false,
                                    commandPreview: "merge-task.sh /p/project.json feat/a4 /repo/.agent-worktrees/feat-a4 --expect-head 0123456"),
                 state: .idle, onConfirm: {}, onCancel: {})
}
