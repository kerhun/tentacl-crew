import AppKit
import Foundation

/// The Tentacl terminal backend: talks to tentacld (the PTY daemon, N228) through `TentacldClient`, one session per agent. The
/// session id is the agent name, which is also the pane id and the workspace id. The agent state is the daemon's last live OSC 7501
/// record of the session (error reads as blocked); only a program with no live record falls back to the state files
/// `agent-state-hook.sh` writes to `<cache>/<agent>/state.json`.
struct TentaclBackend: TerminalBackend, @unchecked Sendable {
    let client: TentacldClient
    /// Where the state files live (`AGENT_PANEL_CACHE`, default `~/.cache/agent-panel`).
    let cache: URL
    /// Brings Tentacl to the front (the terminal itself is part of the app).
    let activate: @Sendable () async throws -> Void
    /// Time the TUI gets to take a paste before Enter is sent.
    let pasteDelay: Duration

    init(client: TentacldClient = TentacldClient(),
         cache: URL = AgentCache.defaultURL(),
         activate: @escaping @Sendable () async throws -> Void = { await MainActor.run { NSApp.activate(ignoringOtherApps: true) } },
         pasteDelay: Duration = .milliseconds(200)) {
        self.client = client
        self.cache = cache
        self.activate = activate
        self.pasteDelay = pasteDelay
    }

    // MARK: listing

    /// No daemon means no agents (it is started by the first agent that opens, not by a list).
    func agents() async throws -> [AgentStatus] {
        try await sessions().map { s in
            let state = readState(agent: s.id)
            let session = state?["session_id"] as? String
            var status = "unknown", seq = state?["seq"] as? Int, live: String?
            if s.alive {
                if let osc = s.status, osc.live {
                    status = Self.state(of: osc); seq = osc.seq; live = osc.message ?? osc.title
                } else {
                    status = state?["status"] as? String ?? "unknown"
                }
            }
            return AgentStatus(paneID: s.id, workspaceID: s.id, state: AgentState(raw: status), cwd: s.cwd, title: s.id,
                               sessionID: session?.isEmpty == false ? session : nil, changeSeq: seq, name: s.id, liveMessage: live)
        }
    }

    /// The app's state name for an OSC 7501 state: error needs the user like blocked does; anything unknown stays unknown.
    static func state(of osc: TentacldClient.ProgramStatus) -> String {
        switch osc.state {
        case "working", "idle", "done", "blocked": return osc.state
        case "error": return "blocked"
        default: return "unknown"
        }
    }

    func workspaces() async throws -> [WorkspaceInfo] {
        try await sessions().filter { !$0.cwd.isEmpty }
            .map { WorkspaceInfo(workspaceID: $0.id, label: $0.id, checkoutPath: $0.cwd, isLinkedWorktree: true) }
    }

    private func sessions() async throws -> [TentacldClient.SessionInfo] {
        guard await client.ping() else { return [] }
        return try await call { try await client.list() }
    }

    // MARK: commands

    /// Pastes the text (bracketed, so a multi-line prompt stays one message), then presses Enter.
    func prompt(target: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackendError.failed("empty command") }
        let id = try session(target)
        try await call { try await client.write(id: id, text: "\u{1B}[200~\(text)\u{1B}[201~") }
        if pasteDelay > .zero { try await Task.sleep(for: pasteDelay) }
        try await call { try await client.write(id: id, text: "\r") }
    }

    func sendKeys(target: String, keys: [String]) async throws {
        guard !keys.isEmpty, keys.allSatisfy(TerminalKeys.isAllowed) else { throw BackendError.failed("these keys are not allowed") }
        let bytes = ["enter": "\r", "esc": "\u{1B}", "tab": "\t", "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D"]
        let id = try session(target)
        try await call { try await client.write(id: id, text: keys.map { bytes[$0] ?? $0 }.joined()) }
    }

    func sendText(target: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackendError.failed("empty command") }
        let id = try session(target)
        try await call { try await client.write(id: id, text: text) }
    }

    /// Only brings Tentacl to the front; showing the agent's terminal is the app's own job.
    func focus(target: String) async throws {
        _ = try session(target)
        try await activate()
    }

    /// The last `lines` lines of the agent's screen and scrollback. The daemon's scrollback read trims every line (a command's indentation
    /// is gone), its screen read keeps them: the rows on screen are taken from the second, the older lines from the first.
    func screen(of target: String, lines: Int) async throws -> String {
        let id = try session(target)
        let history = try await call { try await client.read(id: id, lines: max(1, lines)) }
        let visible = try? await call { try await client.read(id: id) }
        return Self.merged(history: history, visible: visible, lines: lines)
    }

    static func merged(history: String, visible: String?, lines: Int) -> String {
        var all = history.components(separatedBy: "\n")
        while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
        var rows = (visible ?? "").components(separatedBy: "\n")
        while rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rows.removeLast() }
        // Both end at the last non-empty row, so the rows line up from the end; a row that differs in more than its margin stays as it was.
        for (offset, row) in rows.reversed().enumerated() where offset < all.count {
            let at = all.count - 1 - offset
            if row.trimmingCharacters(in: .whitespaces) == all[at].trimmingCharacters(in: .whitespaces) { all[at] = row }
        }
        return all.suffix(max(1, lines)).joined(separator: "\n")
    }

    // MARK: helpers

    /// The session id for an agent name or pane id (the same string); anything that is not a plain name is refused.
    private func session(_ target: String) throws -> String {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw BackendError.failed("empty target") }
        guard target.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }), target != ".", target != ".." else {
            throw BackendError.failed("bad target: \(target)")
        }
        return target
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let e as TentacldClient.TentacldError { throw BackendError.failed(e.message) }
    }

    private func readState(agent: String) -> [String: Any]? {
        guard !agent.contains("/"), let data = try? Data(contentsOf: cache.appendingPathComponent(agent).appendingPathComponent("state.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
