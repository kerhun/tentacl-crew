import Foundation

enum BackendError: Error, Equatable {
    case notInstalled
    case notRunning(String)
    case failed(String)
    case badOutput
}

/// Read-only view of the terminal (tentacld): listing agents and workspaces.
protocol TerminalListing: Sendable {
    func agents() async throws -> [AgentStatus]
    func workspaces() async throws -> [WorkspaceInfo]
}

/// Sends a prompt to one agent. Everything else (listing agents and workspaces) goes through the read-only `TerminalListing`.
protocol TerminalCommanding: Sendable {
    func prompt(target: String, text: String) async throws
}

/// Reads what an agent shows on its terminal. Read-only: it never sends anything to the agent.
protocol TerminalReading: Sendable {
    /// The visible screen of the agent as plain text (the last `lines` lines).
    func screen(of target: String, lines: Int) async throws -> String
}

/// The few keys the panel may press in an agent's menu: a digit picks an option, the others confirm, cancel or move (← → between the tabs of a call, N192).
enum TerminalKeys {
    static func isAllowed(_ key: String) -> Bool { ["enter", "esc", "tab", "up", "down", "left", "right"].contains(key) || (key.count == 1 && key.first!.isASCII && key.first!.isNumber) }
}

/// Pressing keys in an agent's terminal (to pick a menu option). Separate from `TerminalCommanding`, whose only job stays sending prompts.
protocol TerminalKeySending: Sendable {
    func sendKeys(target: String, keys: [String]) async throws
    /// Types literal text into the agent's session; keys never carry text.
    func sendText(target: String, text: String) async throws
    /// Brings the agent's terminal to the front (it is part of Tentacl).
    func focus(target: String) async throws
}

extension TerminalKeySending {
    func sendText(target: String, text: String) async throws { throw BackendError.failed("typing text is not supported") }
    func focus(target: String) async throws { throw BackendError.failed("focusing an agent is not supported") }
}

/// The terminal behind the panel: everything it does with agent terminals. The facets stay separate protocols so a caller (or a
/// test fake) takes only what it needs. `TentaclBackend` is the one real conformance.
protocol TerminalBackend: TerminalListing, TerminalCommanding, TerminalKeySending, TerminalReading {}

/// Runs a command and returns its standard output.
protocol CommandRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> Data
}

enum AgentCache {
    /// Where the agents' state files live (`AGENT_PANEL_CACHE`, default `~/.cache/agent-panel`).
    static func defaultURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_CACHE"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/agent-panel")
    }
}
