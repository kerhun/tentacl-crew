import SwiftUI

/// The confirmation before an agent is started: it lists everything that will happen. Nothing runs until "Start agent".
struct StartTaskSheet: View {
    let plan: StartPlan
    let project: ProjectConfig
    let state: ActionState
    let onConfirm: () -> Void
    /// Offered when the team chart does not allow the task: you are at the top of the chart and can give it yourself.
    var onGiveMyself: (() -> Void)? = nil
    let onCancel: () -> Void

    private var confirm: (canStart: Bool, offersOverride: Bool) { startConfirmState(plan: plan) }
    private var running: Bool { if case .running = state { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start an agent for \(plan.card.id)").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text(plan.card.title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(2)
            }
            Text("The panel will run the script below, give the agent the task card and mark the card as doing. Nothing starts until you confirm.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
                ForEach(startSheetFields(plan: plan, project: project), id: \.label) { field in
                    HStack(alignment: .top, spacing: Tok.Space.m) {
                        Text(field.label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 72, alignment: .leading)
                        Text(field.value).font(field.label == "Command" || field.label == "Worktree" ? Tok.Font.mono : Tok.Font.body)
                            .foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Tok.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            if confirm.offersOverride {
                Text("The team chart does not allow this. You are at the top of the chart, so you can still give the task yourself.")
                    .font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
            }
            statusLine
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction).disabled(running)
                if confirm.offersOverride, let onGiveMyself {
                    Button("I am giving this task myself", action: onGiveMyself).buttonStyle(PanelButtonStyle()).disabled(running)
                }
                Button("Start agent", action: onConfirm).buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction).disabled(running || !confirm.canStart)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 560)
        .background(Tok.bg)
    }

    @ViewBuilder private var statusLine: some View {
        switch state {
        case .running(let m): HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m).font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .failed(let m): Text(m).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        case .idle, .done: EmptyView()
        }
    }
}
