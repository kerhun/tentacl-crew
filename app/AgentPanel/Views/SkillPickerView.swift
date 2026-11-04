import SwiftUI

/// The skills a role may use: a search field above a list of fixed height that scrolls, so a long list never pushes the form around.
struct SkillPickerView: View {
    static let listHeight: CGFloat = 176

    @Bindable var model: TeamModel
    @State private var query = ""
    let editable: Bool

    var body: some View {
        let entries = model.skillEntries(matching: query)
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            FieldText(text: $query, placeholder: "Search skills")
            Scroller {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in row(entry) }
                    if entries.isEmpty { Text("No skill matches.").font(Tok.Font.small).foregroundStyle(Tok.ink3).padding(Tok.Space.s) }
                }
                .padding(Tok.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.listHeight)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            Text("A plugin is on or off as a whole; single skills inside a plugin cannot be switched off. Everything not ticked is switched off for this agent.")
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ entry: SkillChoice) -> some View {
        Button { model.toggleSkill(entry.name) } label: {
            HStack(spacing: Tok.Space.s + 2) {
                Image(systemName: entry.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(entry.isSelected ? Tok.work : Tok.ink3)
                Text(entry.name).font(Tok.Font.body).foregroundStyle(Tok.ink)
                if entry.isMissing {
                    Text("not installed on this machine").font(Tok.Font.small).foregroundStyle(Tok.wait)
                } else if let kind = entry.kind {
                    Text(kind == .plugin ? "plugin" : "your skill").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .accessibilityLabel("\(entry.name), \(entry.isSelected ? "on" : "off")")
    }
}
