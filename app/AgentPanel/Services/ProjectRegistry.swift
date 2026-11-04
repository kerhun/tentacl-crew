import Foundation

/// Writes the project list (`projects.json`) and a project's own `project.json`. Both files may hold keys the panel does not know
/// (`scriptsDir`, a newer version's settings): those are kept. A file that cannot be read is never overwritten, and a write is
/// all-or-nothing (a temporary file is checked, then moved into place).
struct ProjectRegistry: Sendable {
    enum RegistryError: Error, Equatable, CustomStringConvertible {
        case settingsUnreadable(String)
        case invalidProject(String)
        case duplicatePath
        case duplicateID(String)
        /// Another project in the list already uses this repository (the id of that project).
        case duplicateRepo(String)
        case notRegistered
        case writeFailed(String)

        var description: String {
            switch self {
            case .settingsUnreadable(let m), .invalidProject(let m), .writeFailed(let m): return m
            case .duplicatePath: return "This project is already in the list."
            case .duplicateID(let id): return "A project with the id \"\(id)\" is already in the list."
            case .duplicateRepo(let id): return "The project \"\(id)\" already uses this repository."
            case .notRegistered: return "The project is not in the list."
            }
        }
    }

    private static let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    let settingsURL: URL
    let scripts: ScriptRunning

    // MARK: the list

    @discardableResult
    func add(projectFile: URL) throws -> ProjectConfig {
        let path = projectFile.standardizedFileURL.path
        guard path.hasPrefix("/") else { throw RegistryError.invalidProject("the path must be absolute") }
        var object = try readSettings()
        var paths = (object["projects"] as? [String]) ?? []
        guard !paths.contains(where: { Self.resolved($0) == Self.resolved(path) }) else { throw RegistryError.duplicatePath }
        let project: ProjectConfig
        switch ProjectStore.loadProject(at: URL(fileURLWithPath: path)) {
        case .failure(let message): throw RegistryError.invalidProject(message)
        case .success(let loaded): project = loaded
        }
        for other in paths {
            guard case .success(let existing) = ProjectStore.loadProject(at: URL(fileURLWithPath: other)) else { continue }
            if existing.id == project.id { throw RegistryError.duplicateID(project.id) }
            if Self.resolved(existing.repoPath) == Self.resolved(project.repoPath) { throw RegistryError.duplicateRepo(existing.id) }
        }
        paths.append(path)
        object["projects"] = paths
        try writeSettings(object)
        return project
    }

    /// A folder path with symlinks, "..", and a trailing slash resolved, so two spellings of one folder compare equal.
    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// Takes the project off the list. Its files are not touched.
    func remove(projectFile: URL) throws {
        let path = projectFile.standardizedFileURL.path
        var object = try readSettings()
        var paths = (object["projects"] as? [String]) ?? []
        let target = Self.resolved(path)
        guard paths.contains(where: { Self.resolved($0) == target }) else { throw RegistryError.notRegistered }
        paths.removeAll { Self.resolved($0) == target }
        object["projects"] = paths
        try writeSettings(object)
    }

    /// Puts the listed project files in this order. An entry that is not listed (one that does not load) keeps its place; every listed
    /// file must be on the list, or nothing is written.
    func reorder(projectFiles: [URL]) throws {
        var object = try readSettings()
        var paths = (object["projects"] as? [String]) ?? []
        let wanted = projectFiles.map { Self.resolved($0.standardizedFileURL.path) }
        let slots = paths.indices.filter { wanted.contains(Self.resolved(paths[$0])) }
        guard Set(wanted).count == wanted.count, slots.count == wanted.count else { throw RegistryError.notRegistered }
        // The paths as they are spelled in the file now, so only the order changes.
        let spelled = Dictionary(slots.map { (Self.resolved(paths[$0]), paths[$0]) }, uniquingKeysWith: { first, _ in first })
        for (slot, file) in zip(slots, wanted) { paths[slot] = spelled[file] ?? file }
        object["projects"] = paths
        try writeSettings(object)
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RegistryError.settingsUnreadable("\(settingsURL.path) is not a valid settings file, so it was left as it is")
        }
        if let projects = object["projects"], !(projects is [String]) {
            throw RegistryError.settingsUnreadable("\(settingsURL.path) has a \"projects\" entry that is not a list of paths, so it was left as it is")
        }
        return object
    }

    private func writeSettings(_ object: [String: Any]) throws {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: Self.jsonOptions)
            // A symlinked file is written through the link, so the link stays.
            try data.write(to: settingsURL.resolvingSymlinksInPath(), options: .atomic)
        } catch { throw RegistryError.writeFailed(error.localizedDescription) }
    }

    // MARK: one project

    /// The keys the "Edit project" form changes.
    private static let editedKeys = ["name", "maxParallel", "buildCommand", "setupCommand", "attribution", "attributionText", "xcodeProject", "simulator", "sharedFiles", "openWith", "screenshots", "mainBranch"]

    /// Saves the project's own file. The new text goes to a temporary file next to it, `validate-config.sh` has to accept it, and only then
    /// does it replace the old file; keys the panel does not know stay as they were.
    func update(_ project: ProjectConfig) async throws {
        guard let source = project.sourcePath else { throw RegistryError.notRegistered }
        let file = URL(fileURLWithPath: source).resolvingSymlinksInPath()   // write through a symlink, never replace it
        guard let existing = try? Data(contentsOf: file), var object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw RegistryError.invalidProject("\(source) could not be read")
        }
        let encoded = try JSONEncoder().encode(project)
        let fresh = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
        // Only what the form edits; id, folders, roles, copyFiles stay as they are on disk now (a hand edit may have changed them).
        for key in Self.editedKeys where key != "simulator" { object[key] = fresh[key] }   // a key the project no longer has is removed
        if let device = (fresh["simulator"] as? [String: Any])?["baseDevice"] {
            var simulator = (object["simulator"] as? [String: Any]) ?? [:]
            simulator["baseDevice"] = device
            object["simulator"] = simulator
        } else { object["simulator"] = nil }
        let data = try JSONSerialization.data(withJSONObject: object, options: Self.jsonOptions)

        let temp = file.deletingLastPathComponent().appendingPathComponent(".project.json.\(UUID().uuidString).tmp")
        do { try data.write(to: temp, options: .atomic) } catch { throw RegistryError.writeFailed(error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: temp) }
        let result: ScriptResult
        do { result = try await scripts.run(.validate, arguments: [temp.path]) }
        catch { throw RegistryError.writeFailed("the check could not run: \(error)") }
        guard result.status == 0 else {
            let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RegistryError.invalidProject(text.isEmpty ? "validate-config.sh exited with status \(result.status)" : text)
        }
        do { _ = try FileManager.default.replaceItemAt(file, withItemAt: temp) } catch { throw RegistryError.writeFailed(error.localizedDescription) }
    }
}
