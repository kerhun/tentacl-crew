import Foundation

/// A throwaway directory that deletes itself.
final class TempDir {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relativePath: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
