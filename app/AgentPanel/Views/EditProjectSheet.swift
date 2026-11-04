import SwiftUI

/// The settings of one project, and "Remove from list".
struct EditProjectSheet: View {
    @Bindable var flow: EditProjectFlow
    let onSaved: (ProjectConfig) -> Void
    let onRemoved: () -> Void
    let onCancel: () -> Void
    @State private var confirmingRemove = false
    @State private var editingIgnore: GitignoreFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit project").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text("\(flow.project.id) · \(flow.project.repoPath)").font(Tok.Font.mono).foregroundStyle(Tok.ink3).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
                row("Name") { FieldText(text: $flow.name, placeholder: "Name") }
                if let pmTool = flow.pmTool { PMToolRow(picker: pmTool, labelWidth: 110) }
                row("Parallel agents") {
                    HStack(spacing: Tok.Space.s) {
                        Button("−") { flow.maxParallel = max(ProjectConfig.parallelRange.lowerBound, flow.maxParallel - 1) }.buttonStyle(PanelButtonStyle()).disabled(flow.maxParallel <= ProjectConfig.parallelRange.lowerBound).accessibilityLabel("Fewer")
                        Text("\(flow.maxParallel)").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).frame(minWidth: 18)
                        Button("+") { flow.maxParallel = min(ProjectConfig.parallelRange.upperBound, flow.maxParallel + 1) }.buttonStyle(PanelButtonStyle()).disabled(flow.maxParallel >= ProjectConfig.parallelRange.upperBound).accessibilityLabel("More")
                        Spacer()
                    }
                }
                Text("More agents use more of your plan and of this Mac." + (flow.migrationNote.map { " " + $0 } ?? ""))
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                row("Build or test") { FieldText(text: $flow.buildCommand, placeholder: "Command run before a review (optional)", mono: true) }
                row("Setup command") { FieldText(text: $flow.setupCommand, placeholder: "npm install (optional)", mono: true) }
                Text("Runs once in every new agent worktree before the agent starts (10 minute limit). A failure stops the start.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                row("Attribution") {
                    HStack(spacing: Tok.Space.s) {
                        Picker("", selection: $flow.attribution) {
                            Text("Agent default").tag("default"); Text("None").tag("none"); Text("Custom").tag("custom")
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 240).accessibilityLabel("Attribution")
                        Spacer()
                    }
                }
                if flow.attribution == "custom" {
                    row("Attribution text") { FieldText(text: $flow.attributionText, placeholder: "Co-Authored-By: Team <team@example.com>", mono: true) }
                }
                Text("What agents add to commit messages and pull requests. None leaves the tool's credit line out; Custom replaces it with your text.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                row("Main branch") { FieldText(text: $flow.mainBranch, placeholder: "main", mono: true) }
                row("Ignored files") {
                    HStack {
                        Button("Edit .gitignore…") {
                            editingIgnore = GitignoreFlow(repoPath: flow.project.repoPath, projectName: flow.project.name,
                                                          tool: PanelModel.runsUnderXCTest ? nil : GitignoreTool(runner: ProcessToolRunner(timeout: 30)))
                        }
                        .buttonStyle(PanelButtonStyle())
                        .help("Opens the .gitignore editor; nothing is saved before its button.")
                        Spacer()
                    }
                }
                row("Xcode project") { FieldText(text: $flow.xcodeProject, placeholder: "Name.xcodeproj (optional)", mono: true) }
                row("Simulator") { FieldText(text: $flow.simulatorDevice, placeholder: "iPhone 17 Pro (optional: agents get one each)") }
                row("Open with") { FieldText(text: $flow.openWith, placeholder: "Xcode (optional)") }
                row("Screenshots") {
                    HStack {
                        Toggle("Take a screenshot in every review", isOn: $flow.screenshots).toggleStyle(.checkbox).foregroundStyle(Tok.ink2)
                        Spacer()
                    }
                }
                row("Shared files") { PlainEditor(text: $flow.sharedFiles, height: 70, mono: true) }
                Text("Two tasks that list the same shared file (matched by file name, in any folder) never run side by side. One path per line. Empty text removes the setting from the file.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(flow.problems + flow.warnings, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
            if case .failed(let m) = flow.phase { Text(m).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
            if confirmingRemove {
                VStack(alignment: .leading, spacing: Tok.Space.s) {
                    Text("Take \(flow.project.name) off the list? Its folders, tasks and settings stay where they are; you can add it again later.")
                        .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Keep it") { confirmingRemove = false }.buttonStyle(PanelButtonStyle())
                        Button("Remove from list") { Task { if await flow.remove() { onRemoved() } else { confirmingRemove = false } } }.buttonStyle(PanelButtonStyle())
                    }
                }
            }
            HStack(spacing: Tok.Space.s + 2) {
                if !confirmingRemove { Button("Remove from list…") { confirmingRemove = true }.buttonStyle(PanelButtonStyle()) }
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction).disabled(flow.isWorking)
                Button("Save") { Task { if let project = await flow.save() { onSaved(project) } } }
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction).disabled(!flow.canSave)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 560)
        .background(Tok.bg)
        .sheet(item: $editingIgnore) { ignore in GitignoreSheet(flow: ignore) { _ in editingIgnore = nil } }
    }

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: Tok.Space.m) {
            Text(label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 110, alignment: .leading)
            content()
        }
    }
}
