import Foundation

enum AppSettingsStore {
    /// Reads `"scriptsDir": "/absolute/path"` from the settings file. Missing keys are fine (actions are just disabled). Older files may
    /// still carry a `terminalBackend` key; it is ignored (every agent runs in Tentacl's own terminal) and left in the file as it is.
    static func load(settingsURL: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppSettings(scriptsDir: nil, problems: [])
        }
        let appearance = AppTheme.read(object["appearance"] as? String)
        func settings(_ dir: URL?, _ problems: [String]) -> AppSettings { AppSettings(scriptsDir: dir, problems: problems, appearance: appearance) }
        guard let path = object["scriptsDir"] as? String else { return settings(nil, []) }
        if path.hasPrefix("~") { return settings(nil, ["scriptsDir: \"~\" is not expanded, write an absolute path"]) }
        guard path.hasPrefix("/") else { return settings(nil, ["scriptsDir must be an absolute path"]) }
        let dir = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return settings(nil, ["scriptsDir \(path) is not a folder"])
        }
        let candidate = AppSettings(scriptsDir: dir, problems: [])
        let missing = ScriptName.allCases.filter { candidate.scriptURL($0) == nil }
        guard missing.isEmpty else {
            return settings(nil, ["scriptsDir is missing or has unusable scripts: " + missing.map(\.rawValue).joined(separator: ", ")])
        }
        return settings(dir, [])
    }

    /// Changes keys of the settings file and keeps every other one. A file that cannot be read is never overwritten.
    static func update(_ settingsURL: URL, _ change: (inout [String: Any]) -> Void) throws {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let data = try? Data(contentsOf: settingsURL), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(settingsURL.path) is not valid JSON, so it was left as it is."])
            }
            object = parsed
        }
        change(&object)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

}
