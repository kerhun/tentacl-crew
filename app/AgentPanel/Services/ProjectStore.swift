import Foundation

struct ProjectLoadResult: Equatable {
    let projects: [ProjectConfig]
    /// Human-readable problems: one line per settings entry or file that could not be used.
    let problems: [String]
}

/// Loads the project list from the app settings file (`{"projects": ["/abs/path/project.json", ...]}`).
enum ProjectStore {
    static var defaultSettingsURL: URL { defaultSettingsURL(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// `~/.config/tentacl/projects.json`; a file left in the old `~/.config/agent-panel/` folder keeps working until the new one exists.
    static func defaultSettingsURL(home: URL) -> URL {
        let current = home.appendingPathComponent(".config/tentacl/projects.json")
        let old = home.appendingPathComponent(".config/agent-panel/projects.json")
        let fm = FileManager.default
        return !fm.fileExists(atPath: current.path) && fm.fileExists(atPath: old.path) ? old : current
    }

    static func load(settingsURL: URL) -> ProjectLoadResult {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return ProjectLoadResult(projects: [], problems: ["No settings file at \(settingsURL.path)"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["projects"] as? [String] else {
            return ProjectLoadResult(projects: [], problems: ["Settings file \(settingsURL.path) is not valid: expected {\"projects\": [\"/abs/path/project.json\"]}"])
        }

        var projects: [ProjectConfig] = []
        var problems: [String] = []
        for path in paths {
            if path.hasPrefix("~") { problems.append("\(path): \"~\" is not expanded, write an absolute path"); continue }
            if !path.hasPrefix("/") { problems.append("\(path): path must be absolute"); continue }
            switch loadProject(at: URL(fileURLWithPath: path)) {
            case .failure(let message):
                problems.append("\(path): \(message)")
            case .success(let project):
                if projects.contains(where: { $0.id == project.id }) {
                    problems.append("\(path): duplicate project id \"\(project.id)\"")
                } else {
                    projects.append(project)
                }
            }
        }
        return ProjectLoadResult(projects: projects, problems: problems)
    }

    enum Loaded { case success(ProjectConfig), failure(String) }

    static func loadProject(at url: URL) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return .failure("file not found") }
        var project: ProjectConfig
        do { project = try JSONDecoder().decode(ProjectConfig.self, from: data) }
        catch { return .failure("not a valid project.json (\(describe(error)))") }
        if project.maxParallel == 1 { project.maxParallel = ProjectConfig.parallelRange.lowerBound; project.raisedToMinimum = true }
        if let problem = validate(project) { return .failure(problem) }
        project.sourcePath = url.path
        return .success(project)
    }

    private static func validate(_ p: ProjectConfig) -> String? {
        for (name, value) in [("id", p.id), ("name", p.name), ("repoPath", p.repoPath), ("dataDir", p.dataDir)]
        where value.isEmpty { return "\(name) is empty" }
        for (name, value) in [("buildCommand", p.buildCommand), ("openWith", p.openWith), ("xcodeProject", p.xcodeProject), ("simulator.baseDevice", p.simulator?.baseDevice)]
        where value?.isEmpty == true { return "\(name) is empty (leave it out instead)" }
        if let branch = p.mainBranch, !TaskInput.validBranch(branch) { return "mainBranch is not a plain branch name" }
        if !ProjectConfig.parallelRange.contains(p.maxParallel) { return "maxParallel must be an integer from \(ProjectConfig.parallelRange.lowerBound) to \(ProjectConfig.parallelRange.upperBound)" }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .keyNotFound(let key, _): return "missing \(key.stringValue)"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return ctx.codingPath.map(\.stringValue).joined(separator: ".").isEmpty ? ctx.debugDescription : "\(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        @unknown default: return "decoding failed"
        }
    }
}
