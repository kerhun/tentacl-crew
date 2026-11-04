import SwiftUI

/// A role's initial on a coloured tile; the colour follows the name so a role keeps it everywhere.
struct RoleTile: View {
    let name: String
    var displayName = ""
    var size: CGFloat = 28

    private static let tints = [Tok.work, Tok.wait, Tok.go, Tok.askText, Tok.stop]

    var body: some View {
        let label = displayName.isEmpty ? name : displayName
        let tint = Self.tints[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.tints.count]
        Text(label.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(Tok.goInk)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

/// The left column of the Team screen: a search field, base roles, the roles of this project only, and the "New role" menu.
struct RoleListColumn: View {
    @Bindable var model: TeamModel
    var activity: [String: RoleActivity] = [:]
    let onSelect: (ResolvedRole) -> Void
    let onNew: (TeamModel.NewRoleLocation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Team").font(Tok.Font.heading).foregroundStyle(Tok.ink)
                .padding(.horizontal, Tok.Space.l).padding(.vertical, Tok.Space.m + 2)
            VStack(alignment: .leading, spacing: 5) {
                Text("Find a role").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                FieldText(text: $model.roleQuery, placeholder: "Name, model, skill")
            }
            .padding(.horizontal, Tok.Space.l)
            Scroller {
                VStack(alignment: .leading, spacing: 2) {
                    let searching = !model.roleQuery.trimmingCharacters(in: .whitespaces).isEmpty
                    ForEach(Array(model.filteredGroups.enumerated()), id: \.offset) { _, group in
                        Text(group.title).font(Tok.Font.small).foregroundStyle(Tok.ink3).padding(.top, Tok.Space.m).padding(.bottom, 4).padding(.horizontal, 4)
                        ForEach(group.roles) { role in row(role) }
                        if group.roles.isEmpty {
                            Text(searching ? "No role matches." : "No roles yet").font(Tok.Font.small).foregroundStyle(Tok.ink3).padding(.horizontal, Tok.Space.m)
                        }
                    }
                    if model.isNew { newRow }
                    if !model.loadProblems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.loadProblems, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
                        }.padding(.top, Tok.Space.m).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, Tok.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            newRoleMenu.padding(Tok.Space.m)
        }
        .frame(width: 260)
        .background(Tok.pane)
    }

    private func row(_ role: ResolvedRole) -> some View {
        let selected = !model.isNew && model.selectedRole?.fileURL == role.fileURL
        let running = (activity[role.config.name]?.running ?? 0) > 0
        return Button { onSelect(role) } label: {
            HStack(alignment: .top, spacing: Tok.Space.s + 2) {
                RoleTile(name: role.config.name, displayName: role.config.displayName ?? "")
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.config.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? role.config.name).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
                    Text(([role.config.name, model.listModel(for: role)] + (model.listIsCodex(for: role) ? ["Codex"] : [])).joined(separator: " · "))
                        .font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1)
                    if let note = model.shadowNote(for: role) { Text(note).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                    if role.source == .mapped { Text("from project.json (read-only)").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                }
                Spacer(minLength: 0)
                if running { Circle().fill(Tok.work).frame(width: 8, height: 8).padding(.top, 10).accessibilityLabel("agent running") }
            }
            .padding(.horizontal, Tok.Space.s).padding(.vertical, Tok.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Tok.line : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((role.config.displayName.flatMap { $0.isEmpty ? nil : "\($0), \(role.config.name)" } ?? role.config.name) + (running ? ", agent running" : ""))
    }

    private var newRow: some View {
        Text("New role").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink2)
            .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
    }

    private var newRoleMenu: some View {
        MenuBox {
            Button("Shared role (all projects)") { onNew(.base) }
            if let project = model.project { Button("Only in \(project.name)") { onNew(.project) } }
        } label: {
            Text("+ New role").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Tok.raise, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Tok.line))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .accessibilityLabel("New role")
    }
}
