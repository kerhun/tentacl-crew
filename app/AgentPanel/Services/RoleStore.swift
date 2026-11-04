import Foundation

struct RoleLoadResult: Equatable {
    let roles: [ResolvedRole]
    /// One line per role file that could not be used. A broken file never hides the others.
    let problems: [String]
}

/// Reads roles from the three places they can live: the project's `roles` entries in project.json (read-only), the `roles/` folder
/// next to project.json, and the shared library in `~/.config/tentacl/roles`.
struct RoleStore {
    let baseDir: URL

    init(baseDir: URL = RoleStore.defaultBaseDir) { self.baseDir = baseDir }

    static var defaultBaseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tentacl/roles")
    }

    /// `<folder of project.json>/roles`, or nil when the project's file is unknown.
    func projectRolesDir(_ project: ProjectConfig) -> URL? {
        project.sourcePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("roles") }
    }

    func baseRoles() -> RoleLoadResult { loadFolder(baseDir, source: .base) }

    /// The project's own roles: the `roles/` folder plus the entries of project.json (those are read-only).
    func projectRoles(_ project: ProjectConfig) -> RoleLoadResult {
        var roles: [ResolvedRole] = [], problems: [String] = []
        if let folder = projectRolesDir(project) {
            let r = loadFolder(folder, source: .project)
            roles += r.roles; problems += r.problems
        }
        for (key, path) in (project.roles ?? [:]).sorted(by: { $0.key < $1.key }) {
            switch loadMapped(key: key, path: path) {
            case .success(let role): roles.removeAll { $0.config.name == role.config.name }; roles.append(role)
            case .failure(let message): problems.append(message)
            }
        }
        return RoleLoadResult(roles: roles.sorted { $0.config.name < $1.config.name }, problems: problems)
    }

    /// The role a card asks for: the project's `roles` entry, then the project's folder, then the shared library.
    /// `searched` lists the places looked at (empty for a name that is not a plain role name: it never becomes a path).
    func resolve(_ name: String, in project: ProjectConfig) -> (role: ResolvedRole?, searched: [String]) {
        guard RoleValidator.validName(name) else { return (nil, []) }
        var searched = ["the \"roles\" entry \"\(name)\" in project.json"]
        if let path = project.roles?[name], case .success(let role) = loadMapped(key: name, path: path) { return (role, searched) }
        if let folder = projectRolesDir(project) {
            let file = folder.appendingPathComponent("\(name).json")
            searched.append(file.path)
            if case .success(let role) = load(file, source: .project) { return (role, searched) }
        } else {
            searched.append("(the project's roles folder: the location of project.json is unknown)")
        }
        let shared = baseDir.appendingPathComponent("\(name).json")
        searched.append(shared.path)
        if case .success(let role) = load(shared, source: .base) { return (role, searched) }
        return (nil, searched)
    }

    /// The role's instruction text: `<name>.md` next to the role file, else the file its `instructionFile` names (a plain file name).
    func instructions(of role: ResolvedRole) -> String {
        let folder = role.fileURL.deletingLastPathComponent()
        var candidates = [folder.appendingPathComponent(role.fileURL.deletingPathExtension().lastPathComponent + ".md")]
        let legacy = role.config.instructionFile
        if !legacy.isEmpty, !legacy.contains("/"), legacy != ".", legacy != ".." { candidates.append(folder.appendingPathComponent(legacy)) }
        for url in candidates { if let text = try? String(contentsOf: url, encoding: .utf8) { return text } }
        return ""
    }

    // MARK: loading

    private enum Loaded { case success(ResolvedRole), failure(String) }

    private func loadFolder(_ folder: URL, source: RoleSource) -> RoleLoadResult {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return RoleLoadResult(roles: [], problems: []) }
        var roles: [ResolvedRole] = [], problems: [String] = []
        for file in names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted() {
            switch load(folder.appendingPathComponent(file), source: source) {
            case .success(let role): roles.append(role)
            case .failure(let message): problems.append(message)
            }
        }
        return RoleLoadResult(roles: roles.sorted { $0.config.name < $1.config.name }, problems: problems)
    }

    private func load(_ url: URL, source: RoleSource) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure("\(url.path): file not found") }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return .failure("\(url.path): is a symbolic link; the panel does not use it") }
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(RoleConfig.self, from: data) else {
            return .failure("\(url.path): not a valid role file")
        }
        let stem = url.deletingPathExtension().lastPathComponent
        guard config.name == stem else { return .failure("\(url.path): the file is called \(stem) but the role's name is \(config.name)") }
        return .success(ResolvedRole(config: config, fileURL: url, source: source))
    }

    /// A project.json "roles" entry: an absolute path to a role file whose name is the entry's key (so the list and a start agree).
    private func loadMapped(key: String, path: String) -> Loaded {
        guard path.hasPrefix("/") else { return .failure("project.json roles.\(key): the path must be absolute") }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(RoleConfig.self, from: data) else {
            return .failure("\(path): not a valid role file (project.json roles.\(key))")
        }
        guard config.name == key else { return .failure("project.json roles.\(key): the file \(path) is the role \"\(config.name)\", not \"\(key)\"; give them the same name") }
        return .success(ResolvedRole(config: config, fileURL: url, source: .mapped))
    }
}

/// The roles that exist on a first launch. Created only when the shared folder does not exist at all, so a role the user deleted
/// never comes back.
enum RoleSeeder {
    @discardableResult
    static func seedIfMissing(baseDir: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: baseDir.path) else { return false }
        let parent = baseDir.deletingLastPathComponent()
        let temp = parent.appendingPathComponent("\(baseDir.lastPathComponent).seed-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for (config, text) in DefaultRoles.all {
                try encoder.encode(config).write(to: temp.appendingPathComponent("\(config.name).json"))
                try text.write(to: temp.appendingPathComponent("\(config.name).md"), atomically: true, encoding: .utf8)
            }
            try fm.moveItem(at: temp, to: baseDir)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }
}

enum DefaultRoles {
    static var all: [(RoleConfig, String)] {
        func role(_ name: String, model: String, effort: String, mode: String, tools: [String], text: String) -> (RoleConfig, String) {
            (RoleConfig(name: name, kind: "interactive", model: model, effort: effort, permissionMode: mode, outputStyle: "concise",
                        allowedTools: tools, skills: ["superpowers"], instructionFile: "\(name).md", displayName: nil, advanced: nil), text)
        }
        return [
            role("pm", model: "opus", effort: "high", mode: "manual", tools: ["Read", "Bash"], text: """
            You are the project manager (PM). You do not write code.
            - Read the backlog and the task cards. Pick independent tasks; never give two agents tasks that touch the same file.
            - Never start a task without the user's approval. Present your proposal and reasoning first.
            - Verify developer reports against the evidence (build or test output, and screenshots when the project uses them); do not trust a report on its own.
            - Write briefly and plainly (concise).

            """),
            role("dev", model: "sonnet", effort: "medium", mode: "acceptEdits", tools: ["Read", "Edit", "Write", "Bash"], text: """
            You are a developer agent. Do only the task on your task card and stay inside its scope.
            - Work in your own worktree and branch; never touch the main branch.
            - Build and test as the project does, add a screenshot when the task has something to see, and write the report into the card. Do not say "done" without evidence.
            - Make small, focused commits. Keep the session open until approval; fixes may be requested.
            - Write briefly and plainly (concise).

            """),
            role("reviewer", model: "opus", effort: "high", mode: "plan", tools: ["Read", "Bash"], text: """
            You are the reviewer. You do not change code; you read and report.
            - Compare the card's acceptance criteria with the evidence in the card: build or test output, and screenshots when the project uses them.
            - List findings by severity, with file and line.
            - Write briefly and plainly (concise).

            """),
        ]
    }
}
