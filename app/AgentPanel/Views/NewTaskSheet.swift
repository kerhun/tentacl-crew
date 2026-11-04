import SwiftUI

/// Writes a new task card, or (opened on a card) edits one that is not running: title, goal, scope, acceptance criteria, files, role, kind and dependencies.
struct NewTaskSheet: View {
    @Bindable var flow: NewTaskFlow
    let onCreated: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(flow.isEditing ? "Edit card" : "New task").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text(flow.isEditing ? "Changes tasks/\(flow.nextID).md. Other front matter keys and sections stay as they are."
                                    : "Saved as tasks/\(flow.nextID).md with status todo. You start it from the list like any other card.")
                    .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
                if !flow.isEditing { row("Id prefix") { FieldText(text: $flow.prefix, placeholder: "T", mono: true).frame(width: 80); Text("→ \(flow.nextID)").font(Tok.Font.mono).foregroundStyle(Tok.ink3) } }
                row("Title") { FieldText(text: $flow.title, placeholder: "What the task is called") }
                row("Goal", top: true) { editor($flow.goal, "What should be true when it is done?", height: 70) }
                row("Scope", top: true) { editor($flow.scope, "What it may touch and what it must not", height: 56) }
                row("Acceptance", top: true) { editor($flow.acceptance, "How the reviewer checks it", height: 56) }
                row("Files", top: true) { editor($flow.files, "One path per line", height: 56, mono: true) }
                row("Branch") { FieldText(text: $flow.branch, placeholder: "optional, e.g. feat/search", mono: true) }
                row("Depends on") { FieldText(text: $flow.dependencies, placeholder: "card ids, e.g. A1, A2", mono: true) }
                row("Role") {
                    MenuBox {
                        ForEach(flow.roles, id: \.self) { r in Button(r) { flow.role = r } }
                    } label: { menuLabel(flow.role) }
                    Spacer(minLength: Tok.Space.m)
                    ForEach(NewTaskFlow.Kind.allCases, id: \.self) { k in choice(k.rawValue.capitalized, selected: flow.kind == k) { flow.kind = k } }
                }
                row("Priority") {
                    ForEach(CardPriority.allCases, id: \.self) { p in choice(p.rawValue.capitalized, selected: flow.priority == p) { flow.priority = p } }
                }
            }
            ForEach(shownProblems, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
            if let failure = flow.failure { Text(failure).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Tok.Space.s + 2) {
                if flow.isEditing {
                    ForEach(flow.statusActions, id: \.label) { status in
                        Button(statusTitle(status)) { if flow.setStatus(status) { onCreated(flow.nextID) } }.buttonStyle(PanelButtonStyle())
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button(flow.isEditing ? "Save card" : "Create task") { if let id = flow.submit() { onCreated(id) } }
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction).disabled(!flow.canSubmit)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 620)
        .background(Tok.bg)
    }

    private func statusTitle(_ status: TaskStatus) -> String {
        switch status {
        case .todo: return "Back to todo"
        case .blocked: return "Mark blocked"
        case .cancelled: return "Cancel card"
        default: return status.label
        }
    }

    /// Nothing is flagged for a form the user has not started on.
    private var shownProblems: [String] { flow.isEditing || !(flow.title.isEmpty && flow.goal.isEmpty) ? flow.problems : [] }

    private func row<C: View>(_ label: String, top: Bool = false, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: top ? .top : .center, spacing: Tok.Space.m) {
            Text(label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 84, alignment: .leading).padding(.top, top ? 6 : 0)
            content()
        }
    }

    /// ImageRenderer cannot draw a TextEditor, so snapshots draw the text instead.
    private func editor(_ text: Binding<String>, _ placeholder: String, height: CGFloat, mono: Bool = false) -> some View {
        let font = mono ? Tok.Font.mono : Tok.Font.body
        return Group {
            if snapshot {
                Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue).font(font)
                    .foregroundStyle(text.wrappedValue.isEmpty ? Tok.ink3 : Tok.ink).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: text).font(font).foregroundStyle(Tok.ink).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if text.wrappedValue.isEmpty { Text(placeholder).font(font).foregroundStyle(Tok.ink3).padding(.leading, 5).allowsHitTesting(false) }
                    }
            }
        }
        .padding(Tok.Space.s)
        .frame(height: height, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        .accessibilityLabel(placeholder)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Tok.Font.bodyStrong).foregroundStyle(selected ? Tok.ink : Tok.ink2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Tok.raise : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Tok.ink3 : Tok.line))
        }
        .buttonStyle(.plain)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Tok.ink3)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
    }
}
