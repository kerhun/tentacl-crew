import SwiftUI

/// The tool(s) that will trust the folder: the PM's choice and the shared roles' tools (N378).
@MainActor func trustText(_ flow: AddProjectFlow) -> String {
    var codex = flow.pmTool?.choice == .codex, claude = flow.pmTool?.choice != .codex
    for role in flow.roleStore?.baseRoles().roles ?? [] where role.config.name != "pm" { if role.config.tool == "codex" { codex = true } else { claude = true } }
    return (claude && codex ? "Claude Code and Codex" : codex ? "Codex" : "Claude Code") + " will trust this folder"
}

/// What the form will do, one line each, so the user sees every name before anything is created.
@MainActor func addProjectPreviewRows(_ flow: AddProjectFlow) -> [SheetField] {
    guard let n = flow.names else { return [] }
    var rows = [SheetField(label: "Project id", value: n.slug)]
    let repository: String
    if flow.mode == .newProject { repository = "\(n.repoDir) (new git repository \"\(n.slug)\")" }
    else if flow.facts?.isGitRepo == false { repository = "\(n.repoDir) (not a git repository yet: after adding, Waiting for you offers Initialize git)" }
    else { repository = "\(n.repoDir) (stays as it is)" }
    rows.append(SheetField(label: "Repository", value: repository))
    rows.append(SheetField(label: "Data", value: flow.usesExistingData ? "\(n.dataDir) (already there: kept as it is, only what is missing is added)" : n.dataDir))
    if flow.preset == .ios { rows.append(SheetField(label: "Xcode", value: "\(n.xcodeName).xcodeproj")) }
    switch flow.github {
    case .notNow: break
    case .privateRepo, .publicRepo:
        let owner = flow.githubOwner.isEmpty ? n.slug : "\(flow.githubOwner)/\(n.slug)"
        rows.append(SheetField(label: "GitHub", value: "the \(flow.github == .privateRepo ? "private" : "public") repository \(owner) is created and pushed from a sheet you confirm after the project is added"))
    }
    rows.append(SheetField(label: "Trust", value: trustText(flow)))
    return rows
}

/// Adds a project to the panel: a new one (folders and git repository are created) or one that already exists on disk.
struct AddProjectSheet: View {
    @Bindable var flow: AddProjectFlow
    var picker: FolderPicking = OpenPanelFolderPicker()
    let onAdded: (ProjectConfig) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            Text("Add project").font(Tok.Font.title).foregroundStyle(Tok.ink)
            modeSwitch
            if flow.mode == .newProject { newFields } else { existingFields }
            presetSection
            commandsSection
            if !flow.questions.isEmpty { questionsSection }
            if flow.mode == .newProject { githubSection }
            pmSection
            preview
            problemsAndStatus
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction).disabled(flow.isWorking)
                Button(flow.mode == .newProject ? "Create project" : "Add project") {
                    Task { if let project = await flow.submit() { onAdded(project) } }
                }
                .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction).disabled(!flow.canSubmit)
                .tutorialAnchor(.addProjectCreate)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 640)
        .background(Tok.bg)
    }

    // MARK: parts

    private var modeSwitch: some View {
        HStack(spacing: Tok.Space.s) {
            choice("New project", selected: flow.mode == .newProject) { flow.mode = .newProject }
            choice("Existing project", selected: flow.mode == .existing) { flow.mode = .existing }
        }
        .tutorialAnchor(.addProjectKind)
        .disabled(flow.isWorking)
    }

    private var newFields: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            field("Name") { FieldText(text: $flow.name, placeholder: "Recipe Box") }
            folderRow("Code goes in", path: flow.repoParent) { if let p = picker.chooseFolder(message: "Choose the folder the new repository is created in") { flow.repoParent = p } }
            folderRow("Data goes in", path: flow.dataRoot) { if let p = picker.chooseFolder(message: "Choose the folder that holds the project's tasks and settings") { flow.dataRoot = p } }
        }
    }

    private var existingFields: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            folderRow("Project folder", path: flow.names?.repoDir ?? "") {
                if let p = picker.chooseFolder(message: "Choose the project's folder (the top of its git repository)") { Task { await flow.chooseRepo(p) } }
            }
            field("Name", detected: flow.isDetected(.name)) { FieldText(text: $flow.name, placeholder: "Name in the panel") }
            if flow.probe != nil {
                field("Main branch", detected: flow.isDetected(.mainBranch)) {
                    Text(flow.mainBranch).font(Tok.Font.mono).foregroundStyle(Tok.ink)
                    Spacer(minLength: 0)
                }
            }
            folderRow("Data goes in", path: flow.dataRoot) { if let p = picker.chooseFolder(message: "Choose the folder that holds the project's tasks and settings") { flow.dataRoot = p } }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(spacing: Tok.Space.s) {
                Text("Project type").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                if flow.isDetected(.preset) { detectedMark }
            }
            HStack(spacing: Tok.Space.s) {
                choice("Other", selected: flow.preset == .other) { flow.preset = .other }
                choice("iOS app", selected: flow.preset == .ios) { flow.preset = .ios }
                Spacer()
                if flow.preset == .ios, !flow.simulators.isEmpty {
                    MenuBox {
                        ForEach(flow.simulators, id: \.self) { s in Button(s) { flow.simulator = s } }
                    } label: { menuLabel(flow.simulator.isEmpty ? "Simulator" : flow.simulator) }
                }
            }
            if flow.preset == .ios, let project = flow.xcodeProject {
                HStack(spacing: Tok.Space.s) {
                    Text("\(project), scheme \(flow.xcodeScheme)").font(Tok.Font.mono).foregroundStyle(Tok.ink2)
                    if flow.isDetected(.xcodeProject), flow.isDetected(.xcodeScheme) { detectedMark }
                }
            }
            Text(flow.preset == .ios ? (flow.mode == .newProject ? "Agents get a simulator of their own and the review builds the Xcode project. The Xcode project does not exist yet in a new project: the first task creates it."
                                                                 : "Agents get a simulator of their own and the review builds the Xcode project.")
                                     : "No simulator. The review runs the build and test commands below when they are set.")
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Always shown for review: a wrong command breaks every review.
    private var commandsSection: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            field("Build", detected: flow.isDetected(.buildCommand)) {
                FieldText(text: $flow.buildCommand, placeholder: flow.preset == .ios && flow.mode == .newProject ? "the xcodebuild template" : "none", mono: true)
            }
            field("Test", detected: flow.isDetected(.testCommand)) { FieldText(text: $flow.testCommand, placeholder: "none (optional)", mono: true) }
            Text("Check both: the review runs them on every task. Change them later with Edit project.")
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the probe could not settle: each one is answered here before the project can be added.
    private var questionsSection: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            Text("Please check").font(Tok.Font.bodyStrong).foregroundStyle(Tok.wait)
            ForEach(flow.questions, id: \.self) { question in
                VStack(alignment: .leading, spacing: Tok.Space.s) {
                    Text(flow.questionText(question)).font(Tok.Font.small).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Tok.Space.s) {
                        switch question {
                        case .mainBranch:
                            ForEach(flow.probe?.mainCandidates ?? [], id: \.self) { b in choice(b, selected: false) { flow.chooseMainBranch(b) } }
                        case .commands:
                            choice("The commands are right", selected: false) { flow.confirmCommands() }
                        case .xcodeProject:
                            ForEach(flow.probe?.xcodeProjects ?? [], id: \.self) { p in choice(p, selected: false) { flow.chooseXcodeProject(p) } }
                        case .xcodeScheme:
                            ForEach(flow.probe?.xcodeSchemes ?? [], id: \.self) { s in choice(s, selected: false) { flow.chooseScheme(s) } }
                        }
                    }
                }
            }
        }
        .padding(Tok.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.wait.opacity(0.6)))
    }

    private var pmSection: some View {
        VStack(alignment: .leading, spacing: Tok.Space.xs) {
            if let pmTool = flow.pmTool { PMToolRow(picker: pmTool, labelWidth: nil).disabled(flow.isWorking) }
            Toggle(isOn: $flow.startPM) { Text("Start the PM and write a project summary").font(Tok.Font.body).foregroundStyle(Tok.ink) }
                .toggleStyle(.checkbox).disabled(flow.isWorking)
                .tutorialAnchor(.addProjectStartsPM)
            if flow.startPM, !flow.startsPM {
                Text("The PM starts after Initialize git (in Waiting for you).").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
        }
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            Text("GitHub repository").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            HStack(spacing: Tok.Space.s) {
                choice("Not now", selected: flow.github == .notNow) { flow.github = .notNow }
                choice("Private", selected: flow.github == .privateRepo) { flow.github = .privateRepo }
                choice("Public", selected: flow.github == .publicRepo) { flow.github = .publicRepo }
                if flow.github != .notNow { FieldText(text: $flow.githubOwner, placeholder: "user or organisation (optional)") }
            }
            if flow.github != .notNow {
                Text("Nothing is created here. After the project is added a sheet shows what will happen; the repository is created and pushed only when you click its button.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        let rows = addProjectPreviewRows(flow)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .top, spacing: Tok.Space.m) {
                        Text(row.label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 84, alignment: .leading)
                        Text(row.value).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Tok.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        }
    }

    @ViewBuilder private var problemsAndStatus: some View {
        let asked = Set(flow.questions.map(flow.questionText))   // shown with their answers above
        let problems = flow.name.isEmpty && flow.mode == .newProject ? [] : flow.problems.filter { !asked.contains($0) }
        ForEach(problems, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
        if let notice = flow.notice { Text(notice).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true) }
        switch flow.phase {
        case .working(let m): HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m).font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .failed(let m): Text(m).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        case .editing, .done: EmptyView()
        }
    }

    // MARK: small pieces

    private func field<C: View>(_ label: String, detected: Bool = false, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: Tok.Space.m) {
            Text(label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 96, alignment: .leading)
            content()
            if detected { detectedMark }
        }
    }

    /// A value the probe found and the user has not changed.
    private var detectedMark: some View {
        Text("detected").font(Tok.Font.small).foregroundStyle(Tok.go)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().stroke(Tok.go.opacity(0.5)))
            .help("Found in the folder; check it and change it if it is wrong")
    }

    private func folderRow(_ label: String, path: String, choose: @escaping () -> Void) -> some View {
        HStack(spacing: Tok.Space.m) {
            Text(label).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 96, alignment: .leading)
            Text(path.isEmpty ? "Not chosen" : path).font(Tok.Font.mono).foregroundStyle(path.isEmpty ? Tok.ink3 : Tok.ink2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Choose…", action: choose).buttonStyle(PanelButtonStyle()).disabled(flow.isWorking)
        }
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

/// "PM runs on: Claude Code / Codex" (N367) in Add project and Edit project. A tool that is not installed is disabled with the reason;
/// Codex offers to copy the user's Claude rules into `~/.codex/AGENTS.md` (a sheet shows them first).
struct PMToolRow: View {
    @Bindable var picker: PMToolPicker
    /// Edit project lines its labels up in a 110 pt column; Add project puts the label in front.
    let labelWidth: CGFloat?
    @State private var rules: CodexRulesFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.xs) {
            HStack(alignment: .center, spacing: Tok.Space.m) {
                Text("PM runs on").font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: labelWidth, alignment: .leading)
                option(.claude, "Claude Code")
                option(.codex, "Codex")
                if picker.status == nil { Text("Checking…").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                Spacer(minLength: 0)
            }
            ForEach([AgentTool.claude, .codex], id: \.self) { tool in
                if let why = picker.reason(tool) { note(why) }
            }
            if let restart = picker.restartNote { note(restart, color: Tok.wait) }
            if picker.offersRules {
                HStack(spacing: Tok.Space.s) {
                    Button("Copy my Claude rules to Codex…") { rules = CodexRulesFlow(rules: picker.rules) }.buttonStyle(PanelButtonStyle())
                    note("Codex does not read ~/.claude/CLAUDE.md; you see the text before it is added.")
                }
            }
        }
        .task { if picker.status == nil { await picker.load() } }
        .sheet(item: $rules) { flow in CodexRulesSheet(flow: flow) { rules = nil } }
    }

    private func option(_ tool: AgentTool, _ title: String) -> some View {
        let on = picker.choice == tool
        return Button { picker.choice = tool } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Tok.go : Tok.ink3)
                Text(title).font(Tok.Font.body).foregroundStyle(Tok.ink)
            }
        }
        .buttonStyle(.plain)
        .disabled(picker.reason(tool) != nil)
        .opacity(picker.reason(tool) != nil ? 0.45 : 1)
        .help(picker.reason(tool) ?? "The project's PM runs on \(title).")
        .accessibilityLabel("PM runs on \(title)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func note(_ text: String, color: Color = Tok.ink3) -> some View {
        Text(text).font(Tok.Font.small).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
