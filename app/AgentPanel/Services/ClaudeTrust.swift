import Foundation

/// Whether Claude Code already trusts a folder (`hasTrustDialogAccepted` in its config, for the folder or one above it). An agent started
/// in a folder it does not trust stops at a question and never becomes ready for its task.
struct ClaudeTrust: Sendable {
    let configURL: URL

    static var standard: ClaudeTrust {
        let path = ProcessInfo.processInfo.environment["AGENT_PANEL_CLAUDE_JSON"] ?? NSHomeDirectory() + "/.claude.json"
        return ClaudeTrust(configURL: URL(fileURLWithPath: path))
    }

    func isTrusted(_ folder: String) -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any] else { return false }
        // Claude records the real path of its working folder, so symlinks are resolved first.
        var url = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL
        for _ in 0..<64 {
            if let entry = projects[url.path] as? [String: Any], entry["hasTrustDialogAccepted"] as? Bool == true { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return false
    }
}
