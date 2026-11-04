import Foundation

enum RoleLocation: Equatable {
    case base
    case project(ProjectConfig)
}

enum RoleWriteError: Error, Equatable {
    case invalidName
    case readOnly
    case outsideRolesFolder
    case isSymlink
    case problems([RoleProblem])
    /// A role with that name is already in that folder.
    case exists
    case writeFailed(String)
}

/// The panel's only way to change roles. It writes `<name>.json` and `<name>.md` in exactly two kinds of folder (the shared library
/// and a project's `roles/` folder), refuses anything that is not a plain role name or that is, or sits behind, a symbolic link,
/// and never touches `project.json`.
struct RoleWriter {
    let store: RoleStore

    func save(_ role: RoleConfig, instructions: String, at location: RoleLocation, replacing existing: ResolvedRole?) throws -> ResolvedRole {
        guard RoleValidator.validName(role.name) else { throw RoleWriteError.invalidName }
        let errors = RoleValidator.problems(for: role).filter { $0.severity == .error }
        guard errors.isEmpty else { throw RoleWriteError.problems(errors) }
        if let existing, !existing.isEditable { throw RoleWriteError.readOnly }

        let folder = try folderURL(for: location)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            if isSymlink(folder) { throw RoleWriteError.isSymlink }
        } else {
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { throw RoleWriteError.writeFailed(error.localizedDescription) }
        }
        if let existing, existing.fileURL.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path { throw RoleWriteError.outsideRolesFolder }

        let jsonURL = folder.appendingPathComponent("\(role.name).json"), mdURL = folder.appendingPathComponent("\(role.name).md")
        guard jsonURL.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { throw RoleWriteError.invalidName }
        if isSymlink(jsonURL) || isSymlink(mdURL) { throw RoleWriteError.isSymlink }
        let isSameFile = existing.map { $0.fileURL.standardizedFileURL.path == jsonURL.standardizedFileURL.path } ?? false
        if fm.fileExists(atPath: jsonURL.path), !isSameFile { throw RoleWriteError.exists }

        var config = role
        config.instructionFile = "\(role.name).md"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData: Data
        do { jsonData = try encoder.encode(config) } catch { throw RoleWriteError.writeFailed(error.localizedDescription) }

        // Both files are written to temporary names first: a failure leaves the old files exactly as they were.
        let tmpJSON = folder.appendingPathComponent(".\(role.name).json.panel-\(UUID().uuidString)")
        let tmpMD = folder.appendingPathComponent(".\(role.name).md.panel-\(UUID().uuidString)")
        do {
            try jsonData.write(to: tmpJSON)
            try Data(instructions.utf8).write(to: tmpMD)
            try swap(mdURL, with: tmpMD)
            try swap(jsonURL, with: tmpJSON)
        } catch {
            try? fm.removeItem(at: tmpJSON); try? fm.removeItem(at: tmpMD)
            throw RoleWriteError.writeFailed(error.localizedDescription)
        }

        // A rename leaves no second copy behind: the old role's own two files go.
        if let existing, !isSameFile { removeFiles(of: existing) }
        return ResolvedRole(config: config, fileURL: jsonURL, source: existing?.source ?? sourceFor(location))
    }

    /// Removes the role's `<name>.json` and `<name>.md` (and nothing else).
    func delete(_ role: ResolvedRole, project: ProjectConfig? = nil) throws {
        guard role.isEditable else { throw RoleWriteError.readOnly }
        let parent = role.fileURL.deletingLastPathComponent()
        let inBase = role.source == .base && parent.standardizedFileURL.path == store.baseDir.standardizedFileURL.path
        let inProject = role.source == .project && project.flatMap { store.projectRolesDir($0) }.map { $0.standardizedFileURL.path == parent.standardizedFileURL.path } == true
        guard inBase || inProject else { throw RoleWriteError.outsideRolesFolder }
        if isSymlink(role.fileURL) || isSymlink(parent) { throw RoleWriteError.isSymlink }
        do {
            try FileManager.default.removeItem(at: role.fileURL)
            let md = parent.appendingPathComponent(role.fileURL.deletingPathExtension().lastPathComponent + ".md")
            if FileManager.default.fileExists(atPath: md.path), !isSymlink(md) { try FileManager.default.removeItem(at: md) }
        } catch { throw RoleWriteError.writeFailed(error.localizedDescription) }
    }

    // MARK: helpers

    private func folderURL(for location: RoleLocation) throws -> URL {
        switch location {
        case .base: return store.baseDir
        case .project(let p):
            guard let folder = store.projectRolesDir(p) else { throw RoleWriteError.writeFailed("The location of the project's project.json is unknown.") }
            return folder
        }
    }

    private func sourceFor(_ location: RoleLocation) -> RoleSource { if case .base = location { return .base } else { return .project } }

    private func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }

    private func swap(_ url: URL, with temp: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) } else { try fm.moveItem(at: temp, to: url) }
    }

    private func removeFiles(of role: ResolvedRole) {
        let parent = role.fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: role.fileURL)
        try? FileManager.default.removeItem(at: parent.appendingPathComponent(role.fileURL.deletingPathExtension().lastPathComponent + ".md"))
    }
}
