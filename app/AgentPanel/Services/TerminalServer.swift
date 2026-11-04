import Foundation

/// Makes sure the terminal daemon (tentacld) answers before a start runs `spawn-agent.sh`.
protocol TerminalServerEnsuring: Sendable {
    /// Returns once the daemon answers. When it does not, starts it and waits; `onStarting` is called once that begins. Throws a plain
    /// `BackendError` when the daemon cannot be started.
    func ensureRunning(onStarting: @escaping @Sendable () -> Void) async throws
}

/// Does nothing: the default where no real daemon must ever be touched (tests).
struct NoTerminalServerCheck: TerminalServerEnsuring {
    func ensureRunning(onStarting: @escaping @Sendable () -> Void) async throws {}
}

/// Starts tentacld (the helper inside the app) when nothing answers on its socket. One start at a time: starts that arrive meanwhile
/// wait for the same one.
actor TentacldLauncher: TerminalServerEnsuring {
    private let client: TentacldClient
    private var current: Task<Void, Error>?

    init(client: TentacldClient = TentacldClient()) { self.client = client }

    func ensureRunning(onStarting: @escaping @Sendable () -> Void) async throws {
        if let current { return try await current.value }
        let client = client
        let task = Task {
            if await client.ping() { return }
            onStarting()
            do { try await client.ensureRunning() }
            catch let e as TentacldClient.TentacldError { throw BackendError.failed(e.message) }
        }
        current = task
        defer { current = nil }
        try await task.value
    }
}

/// What a running tentacld reports on `ping`: when its binary was built (a modification time) and when it started. Both nil for an older one.
struct HelperInfo: Equatable {
    let built: Date?
    let started: Date?

    /// Old: it does not report its build, or its binary is older than the helper inside the app (a second of slack for file times).
    func isOld(bundled: Date?) -> Bool {
        guard let built else { return true }
        guard let bundled else { return false }
        return built.addingTimeInterval(1) < bundled
    }

    static func bundledDate(_ helper: URL = TentacldClient.bundledHelper) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: helper.path))?[.modificationDate] as? Date
    }
}

/// The terminal switches of Settings → Terminals.
enum TerminalSettings {
    static let restoreHistoryKey = "terminals.restoreHistory"
    /// Default on: a shell's last screen comes back after a restart (N273).
    static func restoreHistory(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: restoreHistoryKey) as? Bool ?? true }
}

enum TerminalMessage {
    /// An error JSON inside a message ("the terminal is not reachable: {…}") cut down to its `message` text; other text is unchanged.
    static func plain(_ text: String) -> String {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any],
              let message = (object["error"] as? [String: Any])?["message"] as? String else { return text }
        return String(text[..<open]) + message + String(text[text.index(after: close)...])
    }
}
