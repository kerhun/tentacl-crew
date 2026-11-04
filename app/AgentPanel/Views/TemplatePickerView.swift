import SwiftUI

/// The first step of "+ New role": pick a ready-made member (or an empty form). Picking fills the whole form; nothing of the template
/// is saved with the role.
struct TemplatePickerView: View {
    let templates: [RoleTemplate]
    let onPick: (RoleTemplate) -> Void
    let onCancel: () -> Void
    @State private var selectedID: String

    init(templates: [RoleTemplate], onPick: @escaping (RoleTemplate) -> Void, onCancel: @escaping () -> Void) {
        self.templates = templates; self.onPick = onPick; self.onCancel = onCancel
        _selectedID = State(initialValue: templates.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New role").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text("Start from a template, or from an empty form. You can change everything before saving.").font(Tok.Font.body).foregroundStyle(Tok.ink2)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Tok.Space.m), GridItem(.flexible(), spacing: Tok.Space.m)], spacing: Tok.Space.m) {
                ForEach(templates) { t in card(t) }
            }
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Use this template") { if let t = templates.first(where: { $0.id == selectedID }) { onPick(t) } }
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 640)
        .background(Tok.bg)
    }

    private func card(_ t: RoleTemplate) -> some View {
        let selected = t.id == selectedID
        return Button { selectedID = t.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(t.title).font(Tok.Font.heading).foregroundStyle(Tok.ink)
                    if t.id != "empty" { Chip(text: "\(ModelCatalog.label(for: t.draft.model)) · \(t.draft.effort)") }
                    Spacer(minLength: 0)
                }
                Text(t.summary).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                if t.id != "empty" {
                    Text(t.draft.allowedTools.joined(separator: ", ") + " · " + t.draft.permissionMode).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1)
                }
            }
            .padding(Tok.Space.m + 2)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius + 2))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius + 2).stroke(selected ? Tok.work : Tok.line, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Tok.radius + 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.title)\(selected ? ", selected" : "")")
    }
}

#Preview("TemplatePickerView") { TemplatePickerView(templates: RoleTemplates.all, onPick: { _ in }, onCancel: {}) }
