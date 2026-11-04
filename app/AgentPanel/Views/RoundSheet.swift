import SwiftUI

/// "Plan a round": the cards the PM picked and the panel accepted, with the PM's reason and the start plan of each. One button starts the ticked ones.
struct RoundSheet: View {
    @Bindable var model: RoundModel
    /// Cancel / Close: a ready round is only hidden (the PM tab's pinned card reopens it).
    let onClose: () -> Void

    static let startShortcut = SheetShortcut.commandReturn

    /// Return presses Cancel once cards are proposed; on the question step it plans (nothing starts).
    static func defaultButton(for state: RoundModel.State) -> SheetButton {
        if case .asking = state { return .confirm }
        return .cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Round").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text(model.state == .asking ? "The PM picks the next cards. Tell it what matters, or leave the field empty."
                     : "The PM picked these cards. Untick the ones you do not want; the rest start one after another.")
                    .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            content
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                switch model.state {
                case .asking:
                    Button("Cancel", action: onClose).buttonStyle(PanelButtonStyle())
                    Button("Plan") { Task { await model.plan() } }.buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction)
                case .ready:
                    Button("Discard round") { model.close() }.buttonStyle(PanelButtonStyle())
                    Button("Cancel", action: onClose).buttonStyle(PanelButtonStyle()).keyboardShortcut(.defaultAction)
                    Button("Start round") { Task { await model.start(); if model.state == .idle { onClose() } } }
                        .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.return, modifiers: .command).disabled(!model.canStart)
                case .starting:
                    EmptyView()
                default:
                    Button("Close", action: onClose).buttonStyle(PanelButtonStyle())
                }
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 600)
        .background(Tok.bg)
        .escapeCancels(onClose)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle: EmptyView()
        case .asking:
            TextField("What matters for this round?", text: $model.note).textFieldStyle(.roundedBorder).onSubmit { Task { await model.plan() } }
        case .planning:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("The PM is picking the next cards…").font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .failed(let message):
            Text(message).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        case .ready(let round): list(round, editable: true)
        case .starting(let round):
            list(round, editable: false)
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting the round…").font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .finished(let round):
            list(round, editable: false)
            if let text = round.failureText { Text(text).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func list(_ round: RoundModel.Round, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            if !round.note.isEmpty {
                Text("You said: \(round.note)").font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(round.items) { item in
                HStack(alignment: .top, spacing: Tok.Space.m) {
                    if editable {
                        Toggle("", isOn: Binding(get: { item.ticked }, set: { _ in model.toggle(item.id) })).labelsHidden().toggleStyle(.checkbox)
                            .accessibilityLabel("Start \(item.card.id)")
                    } else {
                        Image(systemName: icon(item)).foregroundStyle(color(item)).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.card.id) · \(item.card.title)").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(2)
                        Text(item.why).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                        Text(Self.planLine(item.plan)).font(Tok.Font.mono).foregroundStyle(Tok.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .opacity(item.ticked ? 1 : 0.5)
            }
            if !round.dropped.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Left out").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink3)
                    ForEach(round.dropped, id: \.id) { d in
                        Text("\(d.id): \(d.reason)").font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Tok.Space.xs)
            }
        }
        .padding(Tok.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }

    private func icon(_ item: RoundModel.Item) -> String {
        switch item.outcome {
        case .started: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .pending: item.ticked ? "circle" : "minus.circle"
        }
    }

    private func color(_ item: RoundModel.Item) -> Color {
        switch item.outcome {
        case .started: Tok.go
        case .failed: Tok.wait
        case .pending: Tok.ink3
        }
    }

    /// "dev · sonnet · medium · task/n20": the role, its model and effort (read from the role file) and the branch.
    static func planLine(_ plan: StartPlan) -> String {
        let role = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: plan.rolePath))) as? [String: Any]) ?? [:]
        return ([plan.roleName] + [role["model"] as? String, role["effort"] as? String].compactMap { $0 } + [plan.branch]).joined(separator: " · ")
    }
}
