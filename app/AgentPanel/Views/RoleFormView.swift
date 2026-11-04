import SwiftUI

/// A one-line text field that draws plain text in snapshots (ImageRenderer cannot draw AppKit text fields).
struct FieldText: View {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    var editable = true
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        Group {
            if snapshot {
                Text(text.isEmpty ? placeholder : text).foregroundStyle(text.isEmpty ? Tok.ink3 : Tok.ink).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.plain).foregroundStyle(Tok.ink).disabled(!editable)
            }
        }
        .font(mono ? Tok.Font.mono : Tok.Font.body)
        .padding(.horizontal, Tok.Space.m).padding(.vertical, 7)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .opacity(editable ? 1 : 0.6)
        .accessibilityLabel(placeholder)
    }
}

/// A multi-line editor that draws plain text in snapshots.
struct PlainEditor: View {
    @Binding var text: String
    var height: CGFloat
    var mono = false
    var editable = true
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        Group {
            if snapshot {
                Text(text).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $text).scrollContentBackground(.hidden).disabled(!editable)
            }
        }
        .font(mono ? Tok.Font.mono : Tok.Font.body).foregroundStyle(Tok.ink)
        .padding(Tok.Space.s)
        .frame(height: height, alignment: .topLeading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        .opacity(editable ? 1 : 0.6)
    }
}

/// A value with a menu of choices: a styled label (readable in snapshots too) with the real menu laid over it.
private struct MenuField: View {
    let value: String
    let options: [String]
    let editable: Bool
    let onPick: (String) -> Void

    var body: some View {
        if editable {
            MenuBox { ForEach(options, id: \.self) { o in Button(o) { onPick(o) } } } label: { box }
                .accessibilityLabel(value)
        } else {
            box.accessibilityLabel(value)
        }
    }

    private var box: some View {
        HStack {
            Text(value).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Tok.ink3)
        }
        .padding(.horizontal, Tok.Space.m).padding(.vertical, 7)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .opacity(editable ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The model picker: Claude's latest aliases and pinned versions, or the models Codex lists, with their readable names.
private struct ModelMenu: View {
    let choices: [ModelChoice]
    let editable: Bool
    let onPick: (String) -> Void

    private var groups: [String] { choices.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } } }

    var body: some View {
        MenuBox {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(choices.filter { $0.group == group }) { m in
                        Button("\(m.label)  ·  \(m.id)") { onPick(m.id) }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Tok.ink2).frame(maxWidth: .infinity)
                .padding(.horizontal, Tok.Space.m).padding(.vertical, 7)
                .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                .opacity(editable ? 1 : 0.6)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(!editable || choices.isEmpty)
        .accessibilityLabel("Choose a model")
    }
}

/// One permission mode as a choice card: what it lets the agent do and how risky that is.
struct PermissionChoice: Equatable, Identifiable {
    enum Risk: Equatable {
        case safest, safe, normal, risky
        var label: String {
            switch self {
            case .safest: return "Safest"
            case .safe: return "Safe"
            case .normal: return "Normal"
            case .risky: return "Risky"
            }
        }
    }
    let mode: String
    let title: String
    let meaning: String
    let risk: Risk
    var id: String { mode }

    private static let all = [
        PermissionChoice(mode: "plan", title: "Plan", meaning: "Reads and proposes. Never edits.", risk: .safest),
        PermissionChoice(mode: "manual", title: "Manual", meaning: "Asks before every edit and command.", risk: .safe),
        PermissionChoice(mode: "acceptEdits", title: "Accept edits", meaning: "Edits files freely; asks before commands.", risk: .normal),
        PermissionChoice(mode: "auto", title: "Auto", meaning: "Decides when to ask; a safety check stops risky steps.", risk: .normal),
        PermissionChoice(mode: "dontAsk", title: "Don't ask", meaning: "Never asks; anything not allowed below is refused.", risk: .normal),
        PermissionChoice(mode: "bypassPermissions", title: "Bypass", meaning: "Never asks. Only for throwaway sandboxes.", risk: .risky),
    ]

    /// The modes the role's tool accepts, safest first.
    static func choices(codex: Bool) -> [PermissionChoice] {
        let modes = codex ? RoleValidator.codexPermissionModes : RoleValidator.permissionModes
        return all.filter { modes.contains($0.mode) }
    }
}

/// A row of equal segments, one of them chosen (Kind, Effort).
private struct Segments: View {
    let options: [String]
    let selection: String
    var label: (String) -> String = { $0 }
    let editable: Bool
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { onPick(o) } label: {
                    Text(label(o)).font(on ? Tok.Font.bodyStrong : Tok.Font.body).foregroundStyle(on ? Tok.ink : Tok.ink2).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(on ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!editable)
                .accessibilityLabel(label(o)).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .opacity(editable ? 1 : 0.6)
    }
}

/// A large choice: a title, what it means and an optional coloured footer; the chosen one has a blue border.
private struct ChoiceCard: View {
    let title: String
    let text: String
    var footer: String? = nil
    var footerColor: Color = Tok.ink2
    let isSelected: Bool
    let editable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                Text(text).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                if let footer { Text(footer).font(.system(size: 11, weight: .semibold)).foregroundStyle(footerColor) }
                Spacer(minLength: 0)
            }
            .padding(Tok.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isSelected ? Tok.work.opacity(0.12) : Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(isSelected ? Tok.work : Tok.line, lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Tok.radius))
        }
        .buttonStyle(.plain).disabled(!editable).opacity(editable || isSelected ? 1 : 0.6)
        .accessibilityLabel("\(title): \(text)").accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A rounded tag that is on or off (allowed tools), or that removes itself (typed rules).
private struct ToggleChip: View {
    let text: String
    let isOn: Bool
    var removable = false
    let editable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text).font(Tok.Font.small).foregroundStyle(isOn ? Tok.ink : Tok.ink3)
                if removable { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Tok.ink3) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isOn ? Tok.work.opacity(0.14) : .clear, in: Capsule())
            .overlay(Capsule().stroke(isOn ? Tok.work.opacity(0.5) : Tok.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!editable)
    }
}

/// The right side of the Team screen: the selected role as section cards (Identity, Engine, permissions, Skills, Instructions, Advanced)
/// and its problems, with the side column (plain words, launch command, running agents) beside them or, on a narrow form, under them;
/// then Delete/Override/Revert/Save.
struct RoleFormView: View {
    @Bindable var model: TeamModel
    var activity: [String: RoleActivity] = [:]
    /// The live agents by role, for the side column.
    var running: [String: [RoleRunningAgent]] = [:]
    let onDelete: () -> Void
    @State private var choosingSkills = false
    @State private var addingRule = false
    @State private var newRule = ""
    /// nil follows the role: open when it has extra settings or they have a problem.
    @State private var advancedOpen: Bool?

    private var editable: Bool { model.isEditable }

    var body: some View {
        if model.selectedRole == nil && !model.isNew {
            Tok.bg.overlay { Text("Select a role, or create a new one").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
        } else {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Scroller {
                        VStack(alignment: .leading, spacing: Tok.Space.l) {
                            header
                            if let reason = model.readOnlyReason { Text(reason).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
                            if RoleSummary.sideBySide(width: geo.size.width) {
                                HStack(alignment: .top, spacing: Tok.Space.l + 2) {
                                    sections
                                    sideColumn.frame(width: 340)
                                }
                            } else {
                                sections
                                sideColumn
                            }
                        }
                        .padding(Tok.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let role = model.pendingDelete { deleteConfirmation(role) }
                actionBar
            }
            .background(Tok.bg)
            .task(id: model.draft.tool) { if model.isCodex { await model.loadCodexModels() } }
            .onChange(of: model.selectedRole?.fileURL) { advancedOpen = nil; addingRule = false }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            identity
            engine
            permissions
            if !model.isCodex { skills }
            instructions
            if !model.isCodex { advanced }
            problemsView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sideColumn: some View {
        RoleSideColumn(model: model, running: model.isNew ? [] : running[model.selectedRole?.config.name ?? ""] ?? [])
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: Tok.Space.l) {
            RoleTile(name: model.draft.name, displayName: model.draft.displayName, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s) {
                    Text(model.isNew && model.draft.name.isEmpty ? "New role" : (model.draft.displayName.isEmpty ? model.draft.name : model.draft.displayName))
                        .font(Tok.Font.title).foregroundStyle(Tok.ink)
                    if !model.draft.displayName.isEmpty { Text(model.draft.name).font(.system(size: 13, design: .monospaced)).foregroundStyle(Tok.ink3) }
                }
                Text(headerLine).font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tok.Space.m)
            let changes = model.unsavedChangeCount
            if changes > 0 {
                Text(changes == 1 ? "1 unsaved change" : "\(changes) unsaved changes").font(Tok.Font.small).foregroundStyle(Tok.wait)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Tok.wait.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Tok.wait.opacity(0.35)))
            }
        }
    }

    /// "Base role · 2 agents running · 118 cards done · edits apply to agents started after saving"
    private var headerLine: String {
        if model.isNew { return "New role · fill in the fields below, then save" }
        let a = activity[model.selectedRole?.config.name ?? ""] ?? RoleActivity()
        return [sourceText, a.running == 1 ? "1 agent running" : "\(a.running) agents running", a.done == 1 ? "1 card done" : "\(a.done) cards done",
                "edits apply to agents started after saving"].joined(separator: " · ")
    }

    private var sourceText: String {
        switch model.selectedRole?.source {
        case .base?: return "Base role"
        case .project?: return "Only in \(model.project?.name ?? "this project")"
        case .mapped?: return "Defined in the project's project.json"
        case nil: return ""
        }
    }

    // MARK: sections

    private var identity: some View {
        card("Identity") {
            HStack(alignment: .top, spacing: Tok.Space.m) {
                labelled("Name", hint: "Lowercase, used on cards and agent names") { FieldText(text: $model.draft.name, placeholder: "lowercase_name", mono: true, editable: editable) }
                labelled("Display name", hint: "Shown in the panel; optional") { FieldText(text: $model.draft.displayName, placeholder: "Optional, shown on screen only", editable: editable) }
                labelled("Kind", hint: model.draft.kind == "headless" ? "Headless: runs without a terminal; the panel does not start it" : "Interactive: a terminal you can talk to") {
                    Segments(options: RoleValidator.kinds, selection: model.draft.kind, label: { $0.prefix(1).uppercased() + $0.dropFirst() }, editable: editable) { model.draft.kind = $0 }
                }
            }
        }
    }

    private var engine: some View {
        card("Engine") {
            HStack(alignment: .top, spacing: Tok.Space.s + 2) {
                ForEach(RoleValidator.tools, id: \.self) { tool in
                    ChoiceCard(title: TeamModel.toolLabel(tool),
                               text: tool == "codex" ? "Models from the Codex catalog. Sandbox instead of tool lists." : "Claude's models. Skills, plugins, output styles.",
                               isSelected: model.draft.tool == tool, editable: editable && model.toolOptions.contains(tool)) { model.setTool(tool) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.draft.name == "pm" { Text("The PM runs on Claude Code.").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            HStack(alignment: .top, spacing: Tok.Space.m) {
                labelled("Model") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            FieldText(text: $model.draft.model, placeholder: model.isCodex ? "Pick one, or type a Codex model name" : "Pick one, or type a model name", mono: true, editable: editable)
                            ModelMenu(choices: model.modelChoices, editable: editable) { model.setModel($0) }.frame(width: 44)
                        }
                        if model.isCodex, model.codexModels.models.isEmpty, let reason = model.codexModels.reason {
                            Text(reason).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
                        } else {
                            let name = model.modelLabel
                            if !name.isEmpty && name != model.draft.model { Text(name).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                        }
                    }
                }
                labelled("Effort") { Segments(options: model.effortOptions, selection: model.draft.effort, editable: editable) { model.draft.effort = $0 } }
            }
            if !model.isCodex {
                HStack(alignment: .top, spacing: Tok.Space.m) {
                    labelled("Thinking", hint: thinkingHint) {
                        Segments(options: ["default", "on", "off"], selection: model.draft.thinking, label: { $0.prefix(1).uppercased() + $0.dropFirst() }, editable: editable) { model.draft.thinking = $0 }
                    }
                    labelled("Reply language", hint: "Like turkish or english; empty follows Claude Code's setting") {
                        FieldText(text: $model.draft.language, placeholder: "Default", editable: editable)
                    }
                }
            }
        }
    }

    private var thinkingHint: String {
        switch model.draft.thinking {
        case "on": return "Always thinks before answering"
        case "off": return "Answers without thinking; some models then refuse effort above high"
        default: return "Claude Code's default: on for models that support it"
        }
    }

    private var permissions: some View {
        card("What it may do without asking") {
            let choices = PermissionChoice.choices(codex: model.isCodex)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tok.Space.s, alignment: .top), count: model.isCodex ? 4 : 3), alignment: .leading, spacing: Tok.Space.s) {
                ForEach(choices) { c in
                    ChoiceCard(title: c.title, text: c.meaning, footer: c.risk.label, footerColor: riskColor(c.risk), isSelected: model.draft.permissionMode == c.mode, editable: editable) {
                        model.draft.permissionMode = c.mode
                    }
                }
            }
            if model.isCodex { Text(TeamModel.codexMeaning(of: model.draft.permissionMode)).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true) }
            if !model.isCodex { allowedTools }
        }
    }

    private func riskColor(_ risk: PermissionChoice.Risk) -> Color {
        switch risk {
        case .safest, .safe: return Tok.go
        case .normal: return Tok.ink2
        case .risky: return Tok.stop
        }
    }

    /// Claude only: the catalog's tools as chips that switch on and off, the typed rules as chips that remove themselves, and "+ Rule".
    private var allowedTools: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            FlowLayout(spacing: 6) {
                Text("Also allowed:").font(Tok.Font.small).foregroundStyle(Tok.ink3).padding(.vertical, 5)
                ForEach(model.toolChoices()) { tool in
                    ToggleChip(text: tool.name, isOn: tool.isSelected, editable: editable) { model.toggleTool(tool.name) }
                        .help(tool.summary)
                        .accessibilityLabel("\(tool.name), \(tool.isSelected ? "allowed" : "not allowed")")
                }
                ForEach(customRules, id: \.self) { rule in
                    ToggleChip(text: rule, isOn: true, removable: true, editable: editable) { model.draft.allowedTools.removeAll { $0 == rule } }
                        .accessibilityLabel("\(rule), allowed. Remove")
                }
                if editable && !addingRule {
                    Button { addingRule = true } label: {
                        Text("+ Rule, like Bash(git status:*)").font(Tok.Font.small).foregroundStyle(Tok.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().stroke(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if addingRule {
                HStack(spacing: Tok.Space.s) {
                    FieldText(text: $newRule, placeholder: "A rule, like Bash(git status:*) or mcp__server__tool", mono: true)
                    Button("Add") { addRule() }.buttonStyle(PanelButtonStyle()).disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { addingRule = false; newRule = "" }.buttonStyle(PanelButtonStyle())
                }
            }
        }
    }

    private var customRules: [String] { model.draft.allowedTools.filter { !ToolCatalog.names.contains($0) } }

    private func addRule() {
        let text = model.draft.customToolsText
        model.draft.customToolsText = text.isEmpty ? newRule : text + ", " + newRule
        newRule = ""; addingRule = false
    }

    private var skills: some View {
        let chosen = model.skillEntries().filter(\.isSelected)
        return card("Skills", note: "\(chosen.count) of \(model.skillEntries().count) on · everything else is off for this agent") {
            FlowLayout(spacing: 6) {
                ForEach(chosen) { entry in
                    HStack(spacing: 5) {
                        Text(entry.name).font(Tok.Font.body).foregroundStyle(Tok.ink)
                        if entry.isMissing { Text("not installed").font(Tok.Font.small).foregroundStyle(Tok.wait) }
                        else if entry.kind == .plugin { Text("plugin").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Tok.work.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(entry.isMissing ? Tok.wait.opacity(0.5) : Tok.work.opacity(0.5)))
                }
                Button { choosingSkills = true } label: {
                    Text(editable ? "Choose skills…" : "Show skills…").font(Tok.Font.body).foregroundStyle(Tok.ink2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $choosingSkills, arrowEdge: .bottom) {
                    SkillPickerView(model: model, editable: editable).padding(Tok.Space.l).frame(width: 420).background(Tok.bg)
                }
            }
        }
    }

    private var instructionPath: String {
        let file = "\(model.draft.name.isEmpty ? "<name>" : model.draft.name).md"
        guard let role = model.selectedRole, !model.isNew else { return file }
        return (role.fileURL.deletingLastPathComponent().appendingPathComponent(file).path as NSString).abbreviatingWithTildeInPath
    }

    private var styleOptions: [String] {
        let names = model.styleNames
        return names.contains(model.draft.outputStyle) ? names : [model.draft.outputStyle] + names
    }

    private var instructions: some View {
        card("Instructions", note: instructionPath, mono: true, trailing: {
            if !model.isCodex {
                MenuField(value: "Output style: \(model.draft.outputStyle)", options: styleOptions, editable: editable) { model.draft.outputStyle = $0 }
                    .fixedSize()
            }
        }) {
            PlainEditor(text: $model.draft.instructions, height: 140, mono: true, editable: editable)
        }
    }

    private var advancedIsOpen: Bool {
        advancedOpen ?? (!model.draft.advancedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.problems.contains { $0.field == "advanced" })
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            Button { advancedOpen = !advancedIsOpen } label: {
                HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s) {
                    Image(systemName: advancedIsOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.ink3).frame(width: 12)
                    Text("Advanced").font(Tok.Font.heading).foregroundStyle(Tok.ink)
                    Text("Extra Claude settings as JSON").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(advancedIsOpen ? "Advanced, open" : "Advanced, closed")
            if advancedIsOpen {
                PlainEditor(text: $model.draft.advancedText, height: 104, mono: true, editable: editable)
                Text("Merged into this agent's settings file. The fields above win on a clash. \"env\" is not allowed: define secrets in your terminal.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(SectionCard())
    }

    // MARK: problems

    @ViewBuilder private var problemsView: some View {
        let problems = model.problems
        if !problems.isEmpty || model.saveError != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(problems.enumerated()), id: \.offset) { _, p in
                    Text(p.message).font(Tok.Font.small).foregroundStyle(p.severity == .error ? Tok.stop : Tok.wait).fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.saveError { Text(error).font(Tok.Font.small).foregroundStyle(Tok.stop).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    // MARK: delete and footer

    /// Asking "delete this role?" inline: a confirmation shown in the form itself cannot fail to appear the way a window alert can.
    private func deleteConfirmation(_ role: ResolvedRole) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            Text("Delete \"\(role.config.name)\"?").font(Tok.Font.heading).foregroundStyle(Tok.ink)
            Text("The role and its instruction file are deleted. Tasks that name this role cannot be started until it exists again." + (model.pendingDeleteWarning.map { " " + $0 } ?? ""))
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel") { model.cancelDelete() }.buttonStyle(PanelButtonStyle())
                Button("Delete role") { Task { await model.confirmDelete() } }.buttonStyle(PanelButtonStyle(primary: true))
            }
        }
        .padding(Tok.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane)
        .overlay(alignment: .top) { Rectangle().fill(Tok.stop).frame(height: 2) }
    }

    private var actionBar: some View {
        HStack(spacing: Tok.Space.s + 2) {
            if !model.isNew && editable { Button("Delete", action: onDelete).buttonStyle(PanelButtonStyle()) }
            if !model.isNew, model.selectedRole?.source == .base, let project = model.project {
                Button("Override for \(project.name)") { model.overrideForProject() }.buttonStyle(PanelButtonStyle())
                    .disabled(!model.canOverride)
                    .help(model.canOverride ? "Make a copy of this role that only \(project.name) uses" : "\(project.name) already has its own \"\(model.draft.name)\"")
            }
            Spacer()
            Button("Revert") { model.revert() }.buttonStyle(PanelButtonStyle()).disabled(!model.isDirty)
            Button("Save role") { Task { await model.save() } }.buttonStyle(ConfirmButtonStyle())
                .disabled(model.saveDisabledReason != nil).help(model.saveDisabledReason ?? "Save this role")
        }
        .padding(.horizontal, Tok.Space.xl).padding(.vertical, Tok.Space.m + 2)
        .background(Tok.bg)
        .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
    }

    // MARK: building blocks

    private func labelled<C: View>(_ title: String, hint: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            content()
            if let hint { Text(hint).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One section card: a heading with an optional note and trailing control, then the content.
    private func card<C: View, T: View>(_ title: String, note: String? = nil, mono: Bool = false, @ViewBuilder trailing: () -> T = { EmptyView() }, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s + 2) {
                Text(title).font(Tok.Font.heading).foregroundStyle(Tok.ink)
                if let note { Text(note).font(mono ? Tok.Font.mono : Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
                trailing()
            }
            content()
        }
        .modifier(SectionCard())
    }
}

/// The look of a section card of the role editor and its side column.
struct SectionCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Tok.Space.l + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.list, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tok.line))
    }
}

#Preview("RoleFormView") {
    let model = TeamModel(makeScripts: { _ in nil })
    return RoleFormView(model: model, onDelete: {}).frame(width: 900, height: 900)
}
