import Foundation
import Observation

/// "Add project": creates a brand-new project or registers one that is already on disk. The checks run before anything is written; the
/// script that builds a new project undoes its own half-made work, and a failure after it removes the folders this run made (never
/// an existing repository). The GitHub repository is not created here either: a choice only becomes `publishRequest`, and the app opens the Push to GitHub sheet
/// for the new project (N178); nothing is created or pushed until the user clicks that sheet's button.
/// An existing folder is filled in from the probe (shown as detected); only what the probe cannot settle is asked (`questions`).
/// A folder without git is registered as it is: Waiting for you then offers "Initialize git". Registering also tells Claude Code to
/// trust the folder.
@Observable @MainActor
final class AddProjectFlow: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    enum Mode { case newProject, existing }
    enum Preset: String, CaseIterable { case other, ios }
    enum GitHubChoice { case notNow, privateRepo, publicRepo }
    enum Phase: Equatable { case editing, working(String), done(String), failed(String) }
    /// A form value the probe can fill in.
    enum Field: Hashable { case name, mainBranch, preset, buildCommand, testCommand, xcodeProject, xcodeScheme, simulator }
    /// What the probe could not settle; each one blocks until the user answers it.
    enum Question: Hashable { case mainBranch, commands, xcodeProject, xcodeScheme }

    var mode: Mode = .newProject { didSet { if mode != oldValue { forgetProbe() } } }
    var name = ""
    var repoParent: String
    var dataRoot: String
    private(set) var repoPath = ""
    var preset: Preset = .other { didSet { if preset == .ios { Task { await loadSimulators() } } } }
    var simulator = ""
    var github: GitHubChoice = .notNow
    var githubOwner = ""
    /// The branch the project's work merges into (an existing folder: from the probe).
    private(set) var mainBranch = "main"
    /// Suggestions from the probe; the user reviews them (a wrong command breaks every review). Empty means none is recorded.
    var buildCommand = "" { didSet { if buildCommand != oldValue { answered.insert(.commands) } } }
    var testCommand = "" { didSet { if testCommand != oldValue { answered.insert(.commands) } } }
    /// The chosen Xcode project and scheme of an existing folder; nil/empty when it has none.
    private(set) var xcodeProject: String?
    private(set) var xcodeScheme = ""
    /// Start the PM once the project is added (it writes the project summary); on by default.
    var startPM = true
    /// "PM runs on" (N367); nil hides the row. Claude writes nothing (the shared pm role applies, as before); Codex writes the project's pm role.
    var pmTool: PMToolPicker?
    var roleStore: RoleStore?

    private(set) var probe: ProjectProbe?
    var facts: RepoFacts? { probe?.facts }
    /// The value each field got from the probe; a field shows "detected" while it still has that value.
    private var detected: [Field: String] = [:]
    private var answered: Set<Question> = []
    private(set) var simulators: [String] = []
    /// True once the simulator list has been asked for (an empty answer then means Xcode's tools are missing).
    private(set) var simulatorsLoaded = false
    private(set) var phase: Phase = .editing
    /// Something went wrong after the project existed (for example Claude Code could not be told to trust the folder); the project itself is fine.
    private(set) var notice: String?
    /// Set once the project exists and a GitHub repository was wanted: what the Push to GitHub sheet starts from.
    private(set) var publishRequest: (visibility: GitPublisher.Visibility, owner: String)?

    @ObservationIgnored private let scripts: ScriptRunning
    @ObservationIgnored private let registry: ProjectRegistry
    @ObservationIgnored private let probeFolder: @Sendable (String) async -> ProjectProbe
    @ObservationIgnored private let listSimulators: @Sendable () async -> [String]
    @ObservationIgnored private let existingIDs: () -> Set<String>
    @ObservationIgnored private let registeredRepoPaths: () -> Set<String>
    @ObservationIgnored private let fileExists: (String) -> Bool

    init(scripts: ScriptRunning, registry: ProjectRegistry, probe: @escaping @Sendable (String) async -> ProjectProbe,
         listSimulators: @escaping @Sendable () async -> [String], existingIDs: @escaping () -> Set<String>,
         registeredRepoPaths: @escaping () -> Set<String> = { [] }, fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }, repoParent: String, dataRoot: String) {
        self.scripts = scripts; self.registry = registry; self.probeFolder = probe; self.listSimulators = listSimulators
        self.existingIDs = existingIDs; self.registeredRepoPaths = registeredRepoPaths; self.fileExists = fileExists; self.repoParent = repoParent; self.dataRoot = dataRoot
    }

    // MARK: what the form shows

    /// The names the project would get; nil while the name has no usable slug (or no folder is chosen in "existing" mode).
    var names: ProjectNames? {
        switch mode {
        case .newProject: return ProjectNaming.names(for: name, repoParent: repoParent, dataRoot: dataRoot)
        case .existing:
            guard !repoPath.isEmpty, let slug = ProjectNaming.slug(from: name) else { return nil }
            return ProjectNames(slug: slug, repoDir: repoPath, dataDir: dataRoot.hasSuffix("/") ? dataRoot + slug : dataRoot + "/" + slug,
                                xcodeName: xcodeProject.map { String($0.dropLast(".xcodeproj".count)) } ?? ProjectNaming.xcodeName(from: name))
        }
    }

    /// Reasons the project cannot be created yet; empty means it can.
    var problems: [String] {
        var found: [String] = []
        if mode == .existing {
            if repoPath.isEmpty { return ["Choose the project's folder."] }
            // A folder without git is registered as it is; Waiting for you then offers "Initialize git".
            if let facts {
                if !facts.isGitRepo {}
                else if !facts.isTopLevel { found.append("\(repoPath) is inside a repository; choose its top folder.") }
                else if !facts.hasCommits { found.append("The repository has no commits yet; make one first.") }
            } else { found.append("The folder has not been checked yet.") }
        }
        if mode == .newProject {
            for (label, folder) in [("code", repoParent), ("data", dataRoot)] where !fileExists(folder) {
                found.append("The folder for the \(label) (\(folder)) does not exist; choose another one or create it.")
            }
        }
        for question in questions { found.append(questionText(question)) }
        for (label, command) in [("build", buildCommand), ("test", testCommand)] where command.contains(where: \.isNewline) {
            found.append("The \(label) command has a line break; keep it on one line.")
        }
        if preset == .ios, simulatorsLoaded, simulators.isEmpty {
            found.append("There are no simulators: Xcode's command line tools are missing or none is installed. Install Xcode, or choose Other.")
        }
        guard let names else { return found + ["Give the project a name that has letters in it (it must start with a letter)."] }
        let repo = ProjectRegistry.resolved(names.repoDir), data = ProjectRegistry.resolved(names.dataDir)
        if repo == data { found.append("The code and the data cannot go in the same folder: choose two different folders.") }
        else if data.hasPrefix(repo + "/") { found.append("The data folder would be inside the repository (\(names.dataDir)); choose another folder for it.") }
        if mode == .existing {
            if existingIDs().contains(names.slug) { found.append("A project with the id \"\(names.slug)\" is already in the list.") }
            if let owner = existingSettingsRepo(names), ProjectRegistry.resolved(owner) != repo {
                found.append("The settings already in \(names.dataDir) belong to another repository (\(owner)); choose another data folder.")
            }
            if registeredRepoPaths().contains(repo) { found.append("This repository is already used by another project in the list.") }
            if let xcode = xcodeProject, preset == .ios, !Self.isScriptSafeXcodeName(String(xcode.dropLast(".xcodeproj".count))) {
                found.append("The Xcode project name \"\(xcode)\" has characters the panel cannot put in a build command; choose Other and set the build command in Edit project.")
            }
        } else {
            found += ProjectNaming.collisions(of: names, existingIDs: existingIDs(), fileExists: fileExists)
        }
        if github != .notNow, !githubOwner.isEmpty, !GitPublisher.isValidOwner(githubOwner) { found.append("\"\(githubOwner)\" is not a GitHub user or organisation name.") }
        return found
    }

    /// For "existing" mode: the data folder is already there, so it is used and only what is missing is added.
    var usesExistingData: Bool { mode == .existing && names.map { fileExists($0.dataDir) } == true }

    /// The repository named in `agent-panel/project.json` of a data folder that already has one.
    private func existingSettingsRepo(_ names: ProjectNames) -> String? {
        let file = names.dataDir + "/agent-panel/project.json"
        guard fileExists(file), let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["repoPath"] as? String
    }

    /// The same rule create-project.sh applies to the Xcode name.
    static func isScriptSafeXcodeName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._-]{0,59}$", options: .regularExpression) != nil
    }

    /// The open questions, in the order the form shows them; only in "existing" mode, once the folder is probed.
    var questions: [Question] {
        guard mode == .existing, let probe else { return [] }
        var open: [Question] = []
        if probe.mainCandidates.count > 1 { open.append(.mainBranch) }
        if probe.ecosystems.count > 1 { open.append(.commands) }
        if preset == .ios, probe.xcodeProjects.count > 1 { open.append(.xcodeProject) }
        if preset == .ios, probe.xcodeSchemes.count > 1 { open.append(.xcodeScheme) }
        return open.filter { !answered.contains($0) }
    }

    func questionText(_ question: Question) -> String {
        guard let probe else { return "" }
        switch question {
        case .mainBranch:
            let current = probe.facts.branch.map { " (checked out: \($0))" } ?? ""
            return "Which is the main branch? Found \(probe.mainCandidates.joined(separator: ", "))\(current)."
        case .commands:
            return "Found \(probe.ecosystems.map(Self.label).joined(separator: " and ")): check the build and test commands, then confirm them."
        case .xcodeProject: return "Choose the Xcode project the review builds: \(probe.xcodeProjects.joined(separator: ", "))."
        case .xcodeScheme: return "Choose the scheme the review builds: \(probe.xcodeSchemes.joined(separator: ", "))."
        }
    }

    static func label(_ ecosystem: ProjectProbe.Ecosystem) -> String {
        switch ecosystem {
        case .swiftPackage: return "Swift package"
        case .xcode: return "Xcode"
        case .node: return "Node"
        case .python: return "Python"
        case .rust: return "Rust"
        case .go: return "Go"
        case .ruby: return "Ruby"
        case .gradle: return "Gradle"
        case .make: return "Make"
        }
    }

    /// True while the field still holds what the probe found and nothing about it is in question.
    func isDetected(_ field: Field) -> Bool {
        guard mode == .existing, let value = detected[field] else { return false }
        let current: String
        switch field {
        case .name: current = name
        case .mainBranch: if questions.contains(.mainBranch) { return false }; current = mainBranch
        case .preset: current = preset.rawValue
        case .buildCommand: if questions.contains(.commands) { return false }; current = buildCommand
        case .testCommand: if questions.contains(.commands) { return false }; current = testCommand
        case .xcodeProject: if questions.contains(.xcodeProject) { return false }; current = xcodeProject ?? ""
        case .xcodeScheme: if questions.contains(.xcodeScheme) { return false }; current = xcodeScheme
        case .simulator: current = simulator
        }
        return !value.isEmpty && value == current
    }

    /// The PM starts after adding only when asked and when it can: a folder without git waits for "Initialize git".
    var startsPM: Bool { startPM && (mode == .newProject || facts?.isGitRepo == true) }

    var canSubmit: Bool { !isWorking && problems.isEmpty }
    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    // MARK: choosing

    /// Looks at a folder chosen in "existing" mode and fills in what the probe found: the name, the main branch, the preset, the
    /// commands and the Xcode project and scheme. Each one is marked detected; what stays unclear becomes a question.
    func chooseRepo(_ path: String) async {
        repoPath = path
        forgetProbe()   // the old folder's facts must not describe the new one while it is being inspected
        let found = await probeFolder(path)
        probe = found
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = URL(fileURLWithPath: path).lastPathComponent
            detected[.name] = name
        }
        mainBranch = found.mainCandidates.first ?? found.facts.branch ?? "main"
        xcodeProject = found.facts.xcodeProject
        xcodeScheme = xcodeProject.map { project in
            let base = String(project.dropLast(".xcodeproj".count))
            return found.xcodeSchemes.contains(base) ? base : (found.xcodeSchemes.first ?? base)
        } ?? ""
        buildCommand = found.buildCommand ?? ""
        testCommand = found.testCommand ?? ""
        preset = xcodeProject != nil ? .ios : .other
        answered = []   // after the fields: setting the commands above is not the user's answer
        if found.mainCandidates.first ?? found.facts.branch != nil { detected[.mainBranch] = mainBranch }   // "main" for a folder without git is a default
        detected[.preset] = preset.rawValue
        detected[.buildCommand] = buildCommand; detected[.testCommand] = testCommand
        detected[.xcodeProject] = xcodeProject ?? ""; detected[.xcodeScheme] = xcodeScheme
        if preset == .ios { await loadSimulators(); detected[.simulator] = simulator }
    }

    /// Back to a form that knows nothing about a folder (another mode, or before a new probe).
    private func forgetProbe() {
        probe = nil; detected = [:]
        mainBranch = "main"; xcodeProject = nil; xcodeScheme = ""; buildCommand = ""; testCommand = ""
        answered = []
    }

    func chooseMainBranch(_ branch: String) { mainBranch = branch; answered.insert(.mainBranch) }

    /// The commands are right as they are (several ecosystems were found).
    func confirmCommands() { answered.insert(.commands) }

    /// Another Xcode project: the commands follow it, with its own name as the scheme (the probe read the schemes of the first only).
    func chooseXcodeProject(_ project: String) {
        let old = xcodeProject, oldScheme = xcodeScheme, commandsAnswered = answered.contains(.commands)
        xcodeProject = project
        xcodeScheme = String(project.dropLast(".xcodeproj".count))
        for keyPath in [\AddProjectFlow.buildCommand, \.testCommand] {
            var command = self[keyPath: keyPath]
            if let old { command = command.replacingOccurrences(of: "-project '\(old)'", with: "-project '\(project)'") }
            self[keyPath: keyPath] = command.replacingOccurrences(of: "-scheme '\(oldScheme)'", with: "-scheme '\(xcodeScheme)'")
        }
        if !commandsAnswered { answered.remove(.commands) }   // following the choice is not the user's edit
        answered.insert(.xcodeProject)
        answered.insert(.xcodeScheme)
    }

    func chooseScheme(_ scheme: String) {
        let old = xcodeScheme, commandsAnswered = answered.contains(.commands)
        xcodeScheme = scheme
        buildCommand = buildCommand.replacingOccurrences(of: "-scheme '\(old)'", with: "-scheme '\(scheme)'")
        testCommand = testCommand.replacingOccurrences(of: "-scheme '\(old)'", with: "-scheme '\(scheme)'")
        if !commandsAnswered { answered.remove(.commands) }
        answered.insert(.xcodeScheme)
    }

    func loadSimulators() async {
        if simulators.isEmpty { simulators = await listSimulators(); simulatorsLoaded = true }
        if simulator.isEmpty || !simulators.contains(simulator) { simulator = RepoInspector.preferredSimulator(in: simulators) ?? "" }
    }

    // MARK: submitting

    /// Creates or registers the project. Returns it when it is in the list now; nil when nothing was added (see `phase`).
    @discardableResult
    func submit() async -> ProjectConfig? {
        guard !isWorking else { return nil }
        guard problems.isEmpty, let names else { phase = .failed(problems.first ?? "The project cannot be created yet."); return nil }
        let dataExisted = fileExists(names.dataDir)
        let submittedMode = mode, submittedGitHub = mode == .newProject ? github : .notNow, submittedOwner = githubOwner
        phase = .working(mode == .newProject ? "Creating the project…" : "Registering the project…")
        notice = nil; publishRequest = nil
        if preset == .ios, simulator.isEmpty { await loadSimulators() }
        if preset == .ios, simulator.isEmpty { phase = .failed(problems.first ?? "There are no simulators."); return nil }

        var args: [String] = []
        if mode == .existing { args += ["--existing"] + (facts?.isGitRepo == true ? [] : ["--no-git"]) + ["--branch", mainBranch] }
        for (flag, command) in [("--build-command", buildCommand), ("--test-command", testCommand)] {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { args += [flag, trimmed] }
        }
        args += [names.repoDir, names.dataDir, names.slug, name.trimmingCharacters(in: .whitespaces), preset.rawValue, names.xcodeName, simulator]

        let result: ScriptResult
        do { result = try await scripts.run(.createProject, arguments: args) }
        catch { phase = .failed("The setup script could not run: \(error)"); return nil }
        guard result.status == 0 else {
            let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed(text.isEmpty ? "create-project.sh exited with status \(result.status)." : text)
            return nil
        }
        guard let line = result.stdout.split(separator: "\n").last.map(String.init), line.hasPrefix("/") else {
            phase = .failed("The setup script answered with output the panel cannot read.")
            removeWhatThisRunMade(names, mode: submittedMode, dataExisted: dataExisted)
            return nil
        }

        let project: ProjectConfig
        do { project = try registry.add(projectFile: URL(fileURLWithPath: line)) }
        catch {
            removeWhatThisRunMade(names, mode: submittedMode, dataExisted: dataExisted)
            phase = .failed(Self.describe(error))
            return nil
        }

        if submittedGitHub != .notNow { publishRequest = (submittedGitHub == .privateRepo ? .privateRepo : .publicRepo, submittedOwner) }
        // Claude Code trusts the folder now, so the PM and the first agents do not stop at its trust question.
        let trustProblem: String?
        do {
            let trusted = try await scripts.run(.trustFolder, arguments: [names.repoDir])
            let text = trusted.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            trustProblem = trusted.status == 0 ? nil : (text.isEmpty ? "exit status \(trusted.status)" : text)
        } catch { trustProblem = "\(error)" }
        if let trustProblem {
            let line = "The project was added, but Claude Code could not be told to trust the folder (\(trustProblem)); it is asked again when an agent starts."
            notice = notice.map { $0 + " " + line } ?? line
        }
        if let pmTool, let roleStore {
            do { try pmTool.apply(to: project, store: roleStore) }
            catch { let line = "The project was added, but the PM stays on Claude Code: " + PMToolChoice.describe(error); notice = notice.map { $0 + " " + line } ?? line }
        }
        phase = .done(project.id)
        return project
    }

    /// Only the folders the script made for this project: the data folder always, the repository only for a new project.
    private func removeWhatThisRunMade(_ names: ProjectNames, mode: Mode, dataExisted: Bool) {
        // A data folder that was there before is never removed; the script already took back what it added to it.
        if !dataExisted { try? FileManager.default.removeItem(atPath: names.dataDir) }
        if mode == .newProject { try? FileManager.default.removeItem(atPath: names.repoDir) }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? ProjectRegistry.RegistryError {
        case .settingsUnreadable(let m), .invalidProject(let m), .writeFailed(let m): return m
        case .duplicateID(let id): return "A project with the id \"\(id)\" is already in the list."
        case .duplicateRepo(let id): return "The project \"\(id)\" already uses this repository."
        case .duplicatePath: return "This project is already in the list."
        case .notRegistered: return "The project is not in the list."
        case nil: return "\(error)"
        }
    }
}
