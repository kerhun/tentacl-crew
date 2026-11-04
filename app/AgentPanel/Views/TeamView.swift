import SwiftUI

/// The Team screen: the Roster (every role at a glance), the Roles tab (the role list and the form) and the Chart.
struct TeamView: View {
    enum Section: String, CaseIterable { case roster = "Roster", roles = "Roles", chart = "Chart" }
    private struct NewRequest: Identifiable { let location: TeamModel.NewRoleLocation; let template: RoleTemplate; var id: String { template.id } }

    @Bindable var model: TeamModel
    @State private var section: Section
    @State private var pendingSelection: ResolvedRole?
    @State private var pendingNew: NewRequest?
    /// The project's cards and the agents at work, for the Roster.
    private let cards: [TaskCard]
    private let agents: [RosterAgent]

    /// Live agents and done cards per role, from the panel (empty in tests that do not set it).
    let activity: [String: RoleActivity]
    /// Live agents by role with their card and start time (the role editor's side column).
    let running: [String: [RoleRunningAgent]]

    init(model: TeamModel, activity: [String: RoleActivity] = [:], running: [String: [RoleRunningAgent]] = [:], initialSection: Section = .roster,
         cards: [TaskCard] = [], agents: [RosterAgent] = []) {
        self.model = model
        self.activity = activity
        self.running = running
        self.cards = cards; self.agents = agents
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            switch section {
            case .roster: RosterView(roster: roster, onEdit: { edit($0) }, onDuplicate: { duplicate($0) }, onNewRole: { model.templateLocation = .base })
            case .roles: roles
            case .chart: ChartView(model: model.chart)
            }
        }
        .background(Tok.bg)
        .task {
            while !Task.isCancelled {
                model.refreshFromDisk()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: PreviewKey(draft: model.draft, selection: model.selectedRole?.fileURL.path, isNew: model.isNew)) {
            try? await Task.sleep(for: .milliseconds(300))   // wait for the typing to settle
            guard !Task.isCancelled else { return }
            await model.refreshPreview()
        }
        .sheet(item: Binding(get: { model.templateLocation.map { TemplateStep(location: $0) } }, set: { if $0 == nil { model.templateLocation = nil } })) { step in
            TemplatePickerView(templates: RoleTemplates.all, onPick: { template in
                model.templateLocation = nil
                section = .roles
                if model.newRole(from: template, in: step.location) == .needsConfirmation { pendingNew = NewRequest(location: step.location, template: template) }
            }, onCancel: { model.templateLocation = nil })
        }
        .alert(alertTitle, isPresented: Binding(get: { alertKind != nil }, set: { if !$0 { pendingSelection = nil; pendingNew = nil } })) {
            switch alertKind {
            case .discardForSelection?:
                Button("Discard changes", role: .destructive) { if let role = pendingSelection { model.discardAndSelect(role) }; pendingSelection = nil }
                Button("Keep editing", role: .cancel) { pendingSelection = nil }
            case .discardForNewRole?:
                Button("Discard changes", role: .destructive) { if let r = pendingNew { model.discardAndNewRole(from: r.template, in: r.location) }; pendingNew = nil }
                Button("Keep editing", role: .cancel) { pendingNew = nil }
            case .deleteRole?, nil:
                EmptyView()
            }
        } message: {
            Text("This role has changes that are not saved.")
        }
    }

    /// The one question this screen is asking right now (SwiftUI shows only one `.alert` per view).
    private var alertKind: TeamAlertKind? { teamAlertKind(selection: pendingSelection != nil, newRole: pendingNew != nil, delete: false) }
    private var alertTitle: String { "Discard your changes?" }

    private struct TemplateStep: Identifiable { let location: TeamModel.NewRoleLocation; var id: Int { location == .base ? 0 : 1 } }

    private var tabs: some View {
        HStack(alignment: .bottom, spacing: 22) {
            ForEach(Section.allCases, id: \.self) { s in
                Button { section = s } label: {
                    Text(s.rawValue).font(Tok.Font.bodyStrong).foregroundStyle(section == s ? Tok.ink : Tok.ink3)
                        .padding(.bottom, 9)
                        .overlay(alignment: .bottom) { if section == s { Rectangle().fill(Tok.ink).frame(height: 2) } }
                }
                .buttonStyle(.plain)
                .tutorialAnchor(.teamRoster, if: s == .roster)
            }
            Spacer()
            if section == .roster { rosterButtons }
        }
        .pageMargin([.horizontal, .top])
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
    }

    private var roster: TeamRoster {
        let groups = model.groups
        return TeamRoster(base: groups.first?.roles ?? [], project: groups.count > 1 ? groups[1].roles : [], projectName: model.project?.name,
                          chart: model.chart.savedChart, cards: cards, agents: agents)
    }

    private func edit(_ role: ResolvedRole) {
        section = .roles
        if model.select(role) == .needsConfirmation { pendingSelection = role }
    }

    private func duplicate(_ role: ResolvedRole) {
        let copy = model.duplicate(of: role)
        section = .roles
        if model.newRole(from: copy.template, in: copy.location) == .needsConfirmation { pendingNew = NewRequest(location: copy.location, template: copy.template) }
    }

    /// "Templates" and "+ New role": both open the template picker; "+ New role" first asks where the role goes, as the role list does.
    private var rosterButtons: some View {
        HStack(spacing: 10) {
            Button { model.templateLocation = .base } label: {
                Text("Templates").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).padding(.horizontal, 14).frame(height: 30)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
            MenuBox {
                Button("Shared role (all projects)") { model.templateLocation = .base }
                if let project = model.project { Button("Only in \(project.name)") { model.templateLocation = .project } }
            } label: {
                Text("+ New role").font(Tok.Font.bodyStrong).foregroundStyle(Tok.bg).padding(.horizontal, 14).frame(height: 30)
                    .background(Tok.work, in: RoundedRectangle(cornerRadius: 8)).contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .fixedSize()
            .accessibilityLabel("New role")
        }
        .padding(.bottom, 8)
    }

    private var roles: some View {
        VStack(spacing: 0) {
            if model.diskChanged { diskBanner }
            rolesColumns
        }
    }

    private var diskBanner: some View {
        HStack(spacing: 10) {
            Text("This role changed on disk").font(Tok.Font.small).foregroundStyle(Tok.askText)
            Text("·").foregroundStyle(Tok.ink3)
            Button("Reload") { model.reloadFromDisk() }.buttonStyle(.plain).foregroundStyle(Tok.you).accessibilityLabel("Reload from disk")
            Text("·").foregroundStyle(Tok.ink3)
            Button("Keep mine") { model.keepMine() }.buttonStyle(.plain).foregroundStyle(Tok.you).accessibilityLabel("Keep my changes")
            Spacer()
        }
        .font(Tok.Font.small).pageMargin(.horizontal).padding(.vertical, 8)
        .background(Tok.raise)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
    }

    private var rolesColumns: some View {
        HStack(spacing: 0) {
            RoleListColumn(model: model, activity: activity, onSelect: { role in
                if model.select(role) == .needsConfirmation { pendingSelection = role }
            }, onNew: { location in model.templateLocation = location })
            Divider().overlay(Tok.line)
            RoleFormView(model: model, activity: activity, running: running, onDelete: { model.requestDelete() })
        }
    }

    private struct PreviewKey: Hashable { let draft: RoleDraft; let selection: String?; let isNew: Bool }
}
