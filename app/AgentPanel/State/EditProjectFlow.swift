import Foundation
import Observation

/// "Edit project": changes the settings in a project's own `project.json` (not its id or folders) or takes it off the list.
/// Text fields use "" for "not set", which removes the key from the file.
@Observable @MainActor
final class EditProjectFlow: Identifiable {
    enum Phase: Equatable { case editing, working, saved, failed(String) }
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    let project: ProjectConfig
    var name: String
    var maxParallel: Int
    var buildCommand: String
    var setupCommand: String
    var xcodeProject: String
    var simulatorDevice: String
    var openWith: String
    /// One path per line.
    var sharedFiles: String
    var screenshots: Bool
    var mainBranch: String
    /// "default", "none" or "custom"; the text is used for custom only.
    var attribution: String
    var attributionText: String
    private(set) var phase: Phase = .editing

    @ObservationIgnored private let registry: ProjectRegistry
    @ObservationIgnored private let original: ProjectConfig
    /// "PM runs on" (N367); nil hides the row. The choice is saved in the project's own pm role, not in project.json.
    let pmTool: PMToolPicker?
    @ObservationIgnored private let roleStore: RoleStore?

    init(project: ProjectConfig, registry: ProjectRegistry, pmTool: PMToolPicker? = nil, roleStore: RoleStore? = nil) {
        self.project = project; self.original = project; self.registry = registry; self.pmTool = pmTool; self.roleStore = roleStore
        name = project.name; maxParallel = project.maxParallel
        buildCommand = project.buildCommand ?? ""; setupCommand = project.setupCommand ?? ""; xcodeProject = project.xcodeProject ?? ""
        simulatorDevice = project.simulator?.baseDevice ?? ""; openWith = project.openWith ?? ""
        sharedFiles = project.sharedFiles.joined(separator: "\n")
        screenshots = project.screenshotsEnabled; mainBranch = project.mainBranch ?? ""
        attribution = ["none", "custom"].contains(project.attribution ?? "") ? project.attribution! : "default"; attributionText = project.attributionText ?? ""
    }

    private static func optional(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The project the form describes.
    func applied() -> ProjectConfig {
        var p = ProjectConfig(id: original.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), repoPath: original.repoPath, dataDir: original.dataDir,
                              maxParallel: maxParallel, buildCommand: Self.optional(buildCommand), xcodeProject: Self.optional(xcodeProject),
                              simulator: Self.optional(simulatorDevice).map { .init(baseDevice: $0) },
                              sharedFiles: sharedFiles.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                              openWith: Self.optional(openWith), screenshots: screenshots, setupCommand: Self.optional(setupCommand), copyFiles: original.copyFiles, roles: original.roles, mainBranch: Self.optional(mainBranch))
        p.attribution = attribution == "default" ? nil : attribution
        p.attributionText = attribution == "custom" ? Self.optional(attributionText) : nil
        p.sourcePath = original.sourcePath
        return p
    }

    /// Shown once in the sheet for a project whose file said 1 agent; the 2 is written on the next save.
    var migrationNote: String? {
        original.raisedToMinimum ? "This project was set to 1 parallel agent, which is no longer allowed. It runs with 2 now; the file is updated when you save." : nil
    }

    var isDirty: Bool { projectDirty || pmTool?.changed == true }

    /// The project.json part of the form changed.
    private var projectDirty: Bool {
        var a = applied(); var b = original
        // A project without the screenshots key shows the box as on; saving it unchanged must not write the key.
        if original.screenshots == nil, screenshots { a.screenshots = nil }
        b.sourcePath = nil; a.sourcePath = nil; b.raisedToMinimum = false; a.raisedToMinimum = false
        return a != b
    }

    var problems: [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append("The name is empty.") }
        if !ProjectConfig.parallelRange.contains(maxParallel) { found.append("Parallel agents must be from \(ProjectConfig.parallelRange.lowerBound) to \(ProjectConfig.parallelRange.upperBound).") }
        if let branch = Self.optional(mainBranch), !TaskInput.validBranch(branch) { found.append("\"\(branch)\" is not a plain branch name.") }
        if attribution == "custom", Self.optional(attributionText) == nil { found.append("Custom attribution needs a text.") }
        if attribution == "custom", attributionText.contains(where: \.isNewline) { found.append("The attribution text must be one line.") }
        return found
    }

    /// Things worth knowing that do not stop the save.
    var warnings: [String] {
        var found: [String] = []
        if Self.optional(simulatorDevice) == nil, buildCommand.contains("$UDID") {
            found.append("The build command uses $UDID, but no simulator is set: reviews cannot give it a device. Set a simulator or change the command.")
        }
        return found
    }

    var isWorking: Bool { phase == .working }
    var canSave: Bool { problems.isEmpty && isDirty && !isWorking }

    /// Why "Edit project…" cannot open, or nil when it can.
    static func unavailableReason(project: ProjectConfig?, scriptsDir: URL?) -> String? {
        guard let project else { return "No project is selected, so there is nothing to edit." }
        if project.sourcePath == nil { return "\(project.name) cannot be edited: the panel does not know where its project.json is." }
        if scriptsDir == nil { return "Set scriptsDir in the settings file first: saving a project is checked by the panel's scripts." }
        return nil
    }

    /// Saves the form. Returns the project when it was written; nil when it was not (see `phase`).
    @discardableResult
    func save() async -> ProjectConfig? {
        guard problems.isEmpty else { phase = .failed(problems[0]); return nil }
        phase = .working
        var project = applied()
        if original.screenshots == nil, screenshots { project.screenshots = nil }
        do {
            if projectDirty || pmTool == nil { try await registry.update(project) }
            if let pmTool, let roleStore {
                do { try pmTool.apply(to: original, store: roleStore) }
                catch { phase = .failed(PMToolChoice.describe(error)); return nil }
            }
            phase = .saved; return project
        }
        catch {
            switch error as? ProjectRegistry.RegistryError {
            case .invalidProject(let m), .writeFailed(let m), .settingsUnreadable(let m): phase = .failed(m)
            default: phase = .failed("\(error)")
            }
            return nil
        }
    }

    /// Takes the project off the list; its folders and files stay.
    func remove() async -> Bool {
        guard let source = original.sourcePath else { phase = .failed("The location of project.json is unknown."); return false }
        do { try registry.remove(projectFile: URL(fileURLWithPath: source)); return true }
        catch {
            if case ProjectRegistry.RegistryError.settingsUnreadable(let m) = error { phase = .failed(m) } else { phase = .failed("\(error)") }
            return false
        }
    }
}
