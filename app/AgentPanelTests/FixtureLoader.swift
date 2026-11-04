import Foundation

/// Reads files from AgentPanelTests/Fixtures next to the test sources.
enum Fixture {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }
}
