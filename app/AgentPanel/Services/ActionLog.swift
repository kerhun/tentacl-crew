import Foundation

/// An append-only record of what the panel did (commands sent, agents started), kept in the app's own folder.
/// Failing to write the log never blocks the action it describes.
final class ActionLog: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) { self.fileURL = fileURL }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tentacl/actions.log")
    }

    /// The whole log as text (empty when there is none yet).
    func read() -> String { lock.lock(); defer { lock.unlock() }; return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }

    /// With a project id the line reads `[project] text`: the log is shared by all projects, and card ids repeat between them.
    func append(_ text: String, project: String? = nil) {
        let oneLine = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let tag = project.map { "[\($0.replacingOccurrences(of: " ", with: "_"))] " } ?? ""
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(tag)\(oneLine)\n"
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) { try Data().write(to: fileURL) }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // The log is a convenience; ignore failures.
        }
    }
}
