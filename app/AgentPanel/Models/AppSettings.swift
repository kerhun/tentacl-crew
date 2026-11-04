import Foundation

/// The scripts the panel may run. The names are fixed; nothing else in `scriptsDir` is ever executed.
enum ScriptName: String, CaseIterable {
    case spawn = "spawn-agent.sh"
    case checkConflicts = "check-conflicts.sh"
    case stop = "stop-agent.sh"
    case sim = "sim-for-agent.sh"
    case reviewPacket = "review-packet.sh"
    case merge = "merge-task.sh"
    case createProject = "create-project.sh"
    case validate = "validate-config.sh"
    case trustFolder = "trust-folder.sh"
}

/// App-wide settings read from the settings file (next to the project list).
struct AppSettings: Equatable {
    /// The folder with the Phase 0 scripts, or nil when it is not configured or incomplete (actions stay disabled).
    let scriptsDir: URL?
    let problems: [String]
    /// Look of the app (N310); `dark` until the user picks one.
    var appearance: AppTheme = .dark
    /// The script's real path, only when it lies inside `scriptsDir` (a symlink pointing elsewhere is refused).
    func scriptURL(_ name: ScriptName) -> URL? { fileURL(named: name.rawValue) }

    /// Any file of `scriptsDir` under the same rule (used for `release-stable.sh`, which is not one of the scripts every folder must have).
    func fileURL(named fileName: String) -> URL? {
        guard let scriptsDir else { return nil }
        let root = scriptsDir.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let file = scriptsDir.appendingPathComponent(fileName).resolvingSymlinksInPath().standardizedFileURL
        let parts = file.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root,
              FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        return file
    }
}
