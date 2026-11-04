import Foundation

/// A project as described by its `project.json` (the same file the Phase 0 scripts read).
struct ProjectConfig: Codable, Identifiable, Equatable {
    struct Simulator: Codable, Equatable { let baseDevice: String }

    let id: String
    let name: String
    let repoPath: String
    let dataDir: String
    /// How many agents may run at once; the allowed range is `parallelRange`.
    var maxParallel: Int
    /// Optional: a project without a build command is reviewed without building.
    let buildCommand: String?
    /// Optional: the review packet runs it after the build command; a project without one is reviewed on the build alone.
    var testCommand: String? = nil
    let xcodeProject: String?
    /// Optional: only projects with a simulator give each agent a device.
    let simulator: Simulator?
    let sharedFiles: [String]
    let openWith: String?
    /// Whether a review packet takes a screenshot; a missing value means yes, so projects written before this field keep working.
    var screenshots: Bool? = nil
    /// Optional: a shell command (npm install, xcodegen) run once in every new agent worktree before the agent starts.
    var setupCommand: String? = nil
    /// Commit attribution of agents' work: "default" (the agent tool's own), "none" or "custom" (with `attributionText`); nil means default.
    var attribution: String? = nil
    var attributionText: String? = nil
    /// Untracked files (signing settings, .env) copied from the repository into every new worktree; relative paths only.
    var copyFiles: [String]? = nil
    /// Optional role files by name, e.g. {"dev": "/abs/path/dev.json"}; used to start agents.
    var roles: [String: String]? = nil
    /// The branch finished tasks are merged into; nil means "main".
    var mainBranch: String? = nil
    /// The project.json this was loaded from (set by ProjectStore, not part of the file); scripts need it as an argument.
    var sourcePath: String? = nil
    /// Set by ProjectStore when the file said 1 (no longer allowed) and the project was loaded as 2; not part of the file.
    var raisedToMinimum = false

    /// The allowed number of parallel agents per project (also checked by scripts/validate-config.sh).
    static let parallelRange = 2...8

    private enum CodingKeys: String, CodingKey {
        case id, name, repoPath, dataDir, maxParallel, buildCommand, testCommand, xcodeProject, simulator, sharedFiles, openWith, screenshots, setupCommand, attribution, attributionText, copyFiles, roles, mainBranch
    }

    /// The keys the panel itself reads and writes; any other key in the file is left alone when the project is saved.
    static let knownKeys = ["id", "name", "repoPath", "dataDir", "maxParallel", "buildCommand", "testCommand", "xcodeProject", "simulator", "sharedFiles", "openWith", "screenshots", "setupCommand", "attribution", "attributionText", "copyFiles", "roles", "mainBranch"]

    var screenshotsEnabled: Bool { screenshots ?? true }
    var baseBranch: String { mainBranch ?? "main" }

    var repoURL: URL { Self.url(repoPath) }
    var dataURL: URL { Self.url(dataDir) }
    /// Agent worktrees live inside the project (see spawn-agent.sh).
    var worktreesURL: URL {
        let repo = repoURL
        return Self.url(repoPath + "\n.agent-worktrees") { repo.appendingPathComponent(".agent-worktrees") }
    }

    /// `URL(fileURLWithPath:)` asks the file system whether the path is a folder (`lstat`), and views ask for these on every draw.
    private final class URLs: @unchecked Sendable {
        let lock = NSLock()
        var byKey: [String: URL] = [:]
    }
    private static let urls = URLs()
    private static func url(_ key: String, make: () -> URL) -> URL {
        urls.lock.lock(); defer { urls.lock.unlock() }
        if let known = urls.byKey[key] { return known }
        let made = make()
        if urls.byKey.count > 500 { urls.byKey = [:] }
        urls.byKey[key] = made
        return made
    }
    private static func url(_ path: String) -> URL { url(path) { URL(fileURLWithPath: path) } }

    /// The role file for `name` when it is configured with an absolute path and the file exists.
    func roleURL(_ name: String) -> URL? {
        guard let path = roles?[name], path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
