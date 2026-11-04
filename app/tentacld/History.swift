import Foundation

/// The last screen of a user's shell on disk (N273), in `history/` next to the socket: a restart of the daemon or the Mac ends the shell,
/// the text stays. One JSON file per session id. Files are private to the user: shell output can hold secrets.
struct HistoryStore {
    /// Lines of scrollback and screen kept per shell.
    static let maxLines = 2000
    let dir: String

    init(socketPath: String) { dir = (socketPath as NSString).deletingLastPathComponent + "/history" }

    /// Only the user's own shells (`my-shell-N`) are saved, never an agent's session; the id becomes a file name.
    static func valid(_ id: String) -> Bool {
        id.hasPrefix("my-shell-") && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 }
    }

    private func path(_ id: String) -> String { "\(dir)/\(id).json" }

    static func capped(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines).joined(separator: "\n")
    }

    func save(id: String, cwd: String, text: String) {
        guard Self.valid(id) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record: [String: Any] = ["cwd": cwd, "saved": Date().timeIntervalSince1970, "text": Self.capped(text)]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let url = URL(fileURLWithPath: path(id))
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    func load(id: String) -> (cwd: String, saved: Double, text: String)? {
        guard Self.valid(id), let data = FileManager.default.contents(atPath: path(id)),
              let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let text = r["text"] as? String else { return nil }
        return (r["cwd"] as? String ?? "", r["saved"] as? Double ?? 0, text)
    }

    func remove(id: String) {
        guard Self.valid(id) else { return }
        try? FileManager.default.removeItem(atPath: path(id))
    }

    func removeAll() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(name)")
        }
    }
}
