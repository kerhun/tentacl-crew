import SwiftUI
import AppKit

/// The role editor's side column: the draft in plain words, the launch command it would start and the agents running with the role.
struct RoleSideColumn: View {
    @Bindable var model: TeamModel
    /// The live agents of the selected role.
    var running: [RoleRunningAgent] = []
    /// Both closed at first (user decision 2026-10-20).
    @State private var showInstructions: Bool
    @State private var showSettings: Bool

    init(model: TeamModel, running: [RoleRunningAgent] = [], showInstructions: Bool = false, showSettings: Bool = false) {
        self.model = model
        self.running = running
        _showInstructions = State(initialValue: showInstructions)
        _showSettings = State(initialValue: showSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            plainWords
            launchCommand
            if !model.isNew { runningView }
        }
        .onChange(of: model.selectedRole?.fileURL) { showInstructions = false; showSettings = false }
    }

    // MARK: in plain words

    private var displayNames: [String: String] {
        var names: [String: String] = [:]
        for group in model.groups { for role in group.roles { if let n = role.config.displayName, !n.isEmpty { names[role.config.name] = n } } }
        return names
    }

    private var plainWords: some View {
        card("In plain words") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(RoleSummary.lines(draft: model.draft, modelLabel: model.modelLabel, chart: model.chart.savedChart, names: displayNames), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(Tok.ink3)
                        Text(line).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Tok.Font.body)
                }
            }
        }
    }

    // MARK: launch command

    private var launchCommand: some View {
        let p = model.preview
        let shown = p.map { !($0.flags.isEmpty && model.previewNotes.isEmpty) } ?? false
        return card("Launch command", trailing: {
            if let p, shown {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.command, forType: .string) }
                    .buttonStyle(PanelButtonStyle()).help("Copy the command line")
            }
        }) {
            if let p {
                if shown { codeBox(p.command) }
                else { Text("No preview until the problems are fixed.").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                Text("Follows the draft: change a field and this updates.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                if !p.outputStyle.isEmpty { Text("Output style: " + p.outputStyle).font(Tok.Font.small).foregroundStyle(Tok.ink2) }
                ForEach(model.previewNotes, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
                let instructions = p.tool == "codex" ? p.instructions : model.draft.instructions
                if !instructions.isEmpty || !p.settingsJSON.isEmpty {
                    HStack(spacing: 14) {
                        if !instructions.isEmpty { toggle(showInstructions ? "Hide the instructions" : "Show the instructions", isOn: $showInstructions) }
                        if !p.settingsJSON.isEmpty { toggle(showSettings ? "Hide the settings file" : "Show the settings file", isOn: $showSettings) }
                    }
                }
                if showInstructions, !instructions.isEmpty { codeBox(instructions) }
                if showSettings, !p.settingsJSON.isEmpty { codeBox(p.settingsJSON) }
                if !p.overrides.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("These Claude settings also apply:").foregroundStyle(Tok.ink3)
                        ForEach(p.overrides, id: \.self) { Text("· " + $0).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
                    }
                    .font(Tok.Font.small)
                }
            } else {
                Text("Building the preview…").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button(title) { isOn.wrappedValue.toggle() }.buttonStyle(.plain).font(Tok.Font.body).foregroundStyle(Tok.work)
            .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func codeBox(_ text: String) -> some View {
        Text(text).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .padding(Tok.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.line))
    }

    // MARK: running with this role

    private var runningView: some View {
        let savedAt = model.selectedRole.flatMap { RoleSummary.savedAt($0.fileURL) }
        return card("Running with this role") {
            if running.isEmpty {
                Text("No agent is running with this role.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            } else {
                ForEach(running) { agent in
                    HStack(spacing: Tok.Space.s) {
                        Circle().fill(Tok.work).frame(width: 8, height: 8)
                        if let id = agent.cardID { Text(id).font(Tok.Font.mono).foregroundStyle(Tok.ink) }
                        Text(agent.cardID == nil ? "\(agent.title) · no card" : agent.title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(1)
                        Spacer(minLength: 0)
                        if RoleSummary.hasOldSettings(startedAt: agent.startedAt, savedAt: savedAt) {
                            Text("old settings").font(Tok.Font.small).foregroundStyle(Tok.ink3).help("The role was saved after this agent started")
                        }
                    }
                }
                Text("Running agents keep the settings they started with.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
    }

    private func card<C: View, T: View>(_ title: String, @ViewBuilder trailing: () -> T = { EmptyView() }, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            HStack(spacing: Tok.Space.s) {
                Text(title).font(Tok.Font.heading).foregroundStyle(Tok.ink)
                Spacer(minLength: 0)
                trailing()
            }
            content()
        }
        .modifier(SectionCard())
    }
}
