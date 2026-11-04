import Foundation
import Observation

/// Whether Claude Code / Codex are signed in, as the start gate needs it (N329). Only a plain "not signed in" blocks;
/// "cannot tell" (no answer in time, unreadable answer, tool not installed) never does.
@MainActor @Observable
final class SignInGate {
    /// A result no older than this is not asked again right before a start.
    static let maxAge: TimeInterval = 30

    private(set) var missing: Set<AgentTool> = []
    /// Tools that answered "signed in" at the last check (a tool that was never checked, or could not be told, is in neither set).
    private(set) var signedIn: Set<AgentTool> = []
    /// Tools whose program was not found at the last check (N378).
    private(set) var notInstalled: Set<AgentTool> = []
    private(set) var signingIn: AgentTool?
    /// One check per tool at a time: later callers wait for it.
    @ObservationIgnored private var inFlight: [AgentTool: Task<Void, Never>] = [:]
    @ObservationIgnored private var checkedAt: [AgentTool: Date] = [:]
    @ObservationIgnored private let check: @Sendable (AgentTool) async -> Bool?
    @ObservationIgnored private let findTool: @Sendable (String) -> URL?
    /// Starts the program in a session of Tentacl's terminal (tentacld `spawn`), and waits for its exit code (nil = never ran).
    @ObservationIgnored private let spawn: @Sendable (_ id: String, _ argv: [String]) async throws -> Void
    @ObservationIgnored private let exitCode: @Sendable (_ id: String) async -> Int?
    @ObservationIgnored private let open: (String) -> Void
    @ObservationIgnored private let now: () -> Date

    init(check: @escaping @Sendable (AgentTool) async -> Bool?, findTool: @escaping @Sendable (String) -> URL?,
         spawn: @escaping @Sendable (String, [String]) async throws -> Void, exitCode: @escaping @Sendable (String) async -> Int?,
         open: @escaping (String) -> Void, now: @escaping () -> Date = Date.init) {
        self.check = check; self.findTool = findTool; self.spawn = spawn; self.exitCode = exitCode; self.open = open; self.now = now
    }

    static func name(_ tool: AgentTool) -> String { tool == .claude ? "Claude" : "Codex" }
    static func reason(_ tool: AgentTool) -> String { "\(tool == .claude ? "Claude Code" : "Codex") is not signed in." }
    /// What the Sign in button runs, shown as text too.
    static func command(_ tool: AgentTool) -> [String] { tool == .claude ? ["claude", "auth", "login"] : ["codex", "login"] }

    func reason(for tool: AgentTool) -> String? { missing.contains(tool) ? Self.reason(tool) : nil }

    /// The reason right before a start: the last answer when it is fresh, else asks again.
    func ensure(_ tool: AgentTool) async -> String? {
        if let at = checkedAt[tool], now().timeIntervalSince(at) < Self.maxAge { return reason(for: tool) }
        return await refresh(tool)
    }

    @discardableResult
    func refresh(_ tool: AgentTool) async -> String? {
        if let running = inFlight[tool] { await running.value; return reason(for: tool) }
        let task = Task {
            let answer = await check(tool)
            checkedAt[tool] = now()
            if answer == false { missing.insert(tool) } else { missing.remove(tool) }
            if answer == true { signedIn.insert(tool) } else { signedIn.remove(tool) }
            if answer == nil, findTool(Self.command(tool)[0]) == nil { notInstalled.insert(tool) } else { notInstalled.remove(tool) }
            inFlight[tool] = nil
        }
        inFlight[tool] = task
        await task.value
        return reason(for: tool)
    }

    /// Opens the login in the terminal and shows its tab; when the program exits 0, asks again. Never starts an agent.
    func signIn(_ tool: AgentTool) async {
        guard signingIn == nil else { return }
        let command = Self.command(tool)
        guard let exe = findTool(command[0]) else { return }
        signingIn = tool
        defer { signingIn = nil }
        let id = "signin-\(tool.rawValue)"
        do { try await spawn(id, [exe.path] + command.dropFirst()) } catch { return }
        open(id)
        if await exitCode(id) == 0 { await refresh(tool) }
    }
}

extension SignInGate {
    /// The live gate: probes of Setup, login sessions in the bundled tentacld.
    static func live(probes: SetupProbes, open: @escaping (String) -> Void) -> SignInGate {
        SignInGate(check: { await SetupCheck.signedIn($0, probes: probes) }, findTool: probes.findTool,
                   spawn: { id, argv in
                       let client = TentacldClient()
                       try await client.ensureRunning()
                       try? await client.kill(id: id)
                       try await client.spawn(id: id, argv: argv)
                   },
                   exitCode: { id in
                       let client = TentacldClient()
                       while true {
                           try? await Task.sleep(for: .seconds(1))
                           guard let list = try? await client.list() else { continue }
                           guard let session = list.first(where: { $0.id == id }) else { return nil }
                           if !session.alive { return session.exitCode }
                       }
                   }, open: open)
    }
}
