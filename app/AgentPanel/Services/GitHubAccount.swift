import Foundation
import Observation

/// One GitHub login as `gh auth status` reports it. The panel never sees the token.
struct GitHubLogin: Equatable, Sendable {
    var account: String
    var host: String
    var gitProtocol: String?
    /// The other logged-in accounts (other hosts or a second account on the same host), by name.
    var others: [String]
    var summary: String { "\(account) on \(host)" }
}

enum GitHubState: Equatable, Sendable {
    case ghMissing
    case signedOut
    case signedIn(GitHubLogin)
    /// gh answered with something the panel cannot read.
    case unsure(String)

    var login: GitHubLogin? { if case .signedIn(let login) = self { login } else { nil } }
}

/// The two read-only questions the panel asks gh. Tests answer them with recorded text.
protocol GitHubCLI: Sendable {
    /// The first line of `gh --version`; nil when gh is not installed.
    func ghVersion() async -> String?
    /// `gh auth status`: exit status and everything it printed (stdout and stderr; older versions use stderr).
    func authStatus() async -> (status: Int32, output: String)
}

enum GitHubAccount {
    /// What "Sign in to GitHub" runs in Terminal (the user finishes it in the browser).
    static let signInCommand = "gh auth login --web --git-protocol https"
    static let installCommand = "brew install gh"

    static func parseVersion(_ text: String) -> String? {
        text.range(of: #"gh version (\S+)"#, options: .regularExpression)
            .map { String(text[$0]).replacingOccurrences(of: "gh version ", with: "") }
    }

    /// Reads `gh auth status`. Several accounts: the active github.com one is shown (else the first active, else the first), the rest are listed.
    static func parseStatus(_ output: String, status: Int32) -> GitHubState {
        struct Entry { var host: String; var account: String; var active = false; var gitProtocol: String? }
        var entries: [Entry] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.range(of: #"^✓ Logged in to (\S+) (?:account|as) (\S+)"#, options: .regularExpression) {
                let words = line[match].split(separator: " ").map(String.init)
                entries.append(Entry(host: words[4], account: words[6]))
            } else if line.hasPrefix("- Active account:"), !entries.isEmpty { entries[entries.count - 1].active = line.hasSuffix("true") }
            else if line.hasPrefix("- Git operations protocol:"), !entries.isEmpty { entries[entries.count - 1].gitProtocol = line.split(separator: " ").last.map(String.init) }
            else if line.hasPrefix("✓ Git operations for"), !entries.isEmpty, line.contains(" configured to use "), let word = line.split(separator: " ").dropLast().last {
                entries[entries.count - 1].gitProtocol = String(word)
            }
        }
        guard let shown = entries.first(where: { $0.active && $0.host == "github.com" }) ?? entries.first(where: { $0.host == "github.com" })
                ?? entries.first(where: \.active) ?? entries.first else {
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if status != 0, text.contains("not logged into") || text.contains("Failed to log in") || text.contains("authentication") { return .signedOut }
            return .unsure(text.isEmpty ? "gh auth status printed nothing (exit \(status))." : String(text.split(whereSeparator: \.isNewline).first ?? ""))
        }
        let others = entries.filter { !($0.host == shown.host && $0.account == shown.account) }.map(\.account)
        return .signedIn(GitHubLogin(account: shown.account, host: shown.host, gitProtocol: shown.gitProtocol, others: others))
    }

    static func check(_ cli: GitHubCLI) async -> GitHubState {
        guard await cli.ghVersion() != nil else { return .ghMissing }
        let answer = await cli.authStatus()
        return parseStatus(answer.output, status: answer.status)
    }
}

/// The live reader: runs the installed gh with a short timeout. Only `--version` and `auth status`.
struct ProcessGitHubCLI: GitHubCLI {
    var find: @Sendable () -> URL? = { SetupCheck.findTool("gh") }
    var timeout: TimeInterval = 8

    func ghVersion() async -> String? {
        guard let gh = find() else { return nil }
        let (status, output) = await Self.run(gh, ["--version"], timeout: timeout)
        return status == 0 ? GitHubAccount.parseVersion(output) ?? output.split(whereSeparator: \.isNewline).first.map(String.init) : nil
    }

    func authStatus() async -> (status: Int32, output: String) {
        guard let gh = find() else { return (127, "") }
        return await Self.run(gh, ["auth", "status"], timeout: timeout)
    }

    /// Output of stdout and stderr together; a program that does not finish within `timeout` is stopped (status -1).
    static func run(_ exe: URL, _ arguments: [String], timeout: TimeInterval) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = exe; process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["GH_PROMPT_DISABLED"] = "1"; env["NO_COLOR"] = "1"; env["GH_NO_UPDATE_NOTIFIER"] = "1"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            let collected = Locked()
            let reader = pipe.fileHandleForReading
            reader.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
            }
            process.terminationHandler = { finished in
                reader.readabilityHandler = nil
                collected.append(reader.readDataToEndOfFile())
                continuation.resume(returning: (finished.terminationReason == .exit ? finished.terminationStatus : -1, collected.text))
            }
            do { try process.run() } catch { reader.readabilityHandler = nil; continuation.resume(returning: (127, "")); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }

    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

/// Opens a Terminal window running one command (the user finishes `gh auth login` there).
protocol GitHubTerminal: Sendable {
    func open(_ command: String) async throws
}

struct TerminalAppOpener: GitHubTerminal {
    func open(_ command: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tentacl-github-\(UUID().uuidString).command")
        try "#!/bin/zsh\nrm -f \"$0\"\n\(command)\necho\necho 'Done. Go back to Tentacl Crew; it checks again by itself.'\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        do { _ = try await CommandFileOpener.open(file) } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
}

/// Settings › GitHub: who is signed in, "Sign in to GitHub" (Terminal), "Install GitHub CLI" (brew, after one confirmation).
@Observable @MainActor
final class GitHubAccountModel {
    /// nil until the first check.
    private(set) var state: GitHubState?
    private(set) var isChecking = false
    private(set) var message: String?
    /// "Sign in" opened Terminal; the check runs again when the app is active (and on "Check again").
    private(set) var isWaitingForSignIn = false
    private(set) var isConfirmingInstall = false
    private(set) var isInstalling = false
    private(set) var installLog = ""
    private(set) var canInstall = false

    var installCommand: String { GitHubAccount.installCommand }

    @ObservationIgnored private let read: @Sendable () async -> GitHubState
    @ObservationIgnored private let terminal: GitHubTerminal
    @ObservationIgnored private let installer: ToolInstalling
    @ObservationIgnored private let findBrew: @Sendable () -> URL?
    @ObservationIgnored private let findGh: @Sendable () -> URL?

    init(read: @escaping @Sendable () async -> GitHubState = { await GitHubAccount.check(ProcessGitHubCLI()) },
         terminal: GitHubTerminal = TerminalAppOpener(), installer: ToolInstalling = ShellInstaller(),
         findBrew: @escaping @Sendable () -> URL? = { SetupCheck.findTool("brew") }, findGh: @escaping @Sendable () -> URL? = { SetupCheck.findTool("gh") }) {
        self.read = read; self.terminal = terminal; self.installer = installer; self.findBrew = findBrew; self.findGh = findGh
    }

    func check() async {
        isChecking = true
        let read = read, findBrew = findBrew
        async let answer = Task.detached { await read() }.value
        async let brew = Task.detached { findBrew() }.value
        state = await answer; canInstall = await brew != nil
        isChecking = false
        if state?.login != nil { isWaitingForSignIn = false }
    }

    /// Opens Terminal on `gh auth login --web --git-protocol https`; nothing else runs.
    func signIn() async {
        message = nil
        let gh = findGh()?.path ?? "gh"
        do { try await terminal.open(GitHubAccount.signInCommand.replacingOccurrences(of: "gh ", with: "\(gh) ", options: .anchored)) }
        catch { message = "Terminal could not be opened: \(error.localizedDescription). Run this in a terminal: \(GitHubAccount.signInCommand)"; return }
        isWaitingForSignIn = true
    }

    /// The app is active again (the user may be back from Terminal or the browser).
    func appBecameActive() async {
        guard isWaitingForSignIn, !isInstalling else { return }
        await check()
    }

    func requestInstall() { message = nil; isConfirmingInstall = canInstall }
    func cancelInstall() { isConfirmingInstall = false }

    func confirmInstall() async {
        isConfirmingInstall = false
        guard let brew = findBrew(), !isInstalling else { return }
        isInstalling = true
        installLog = "$ \(installCommand)\n"
        let (stream, sink) = AsyncStream<String>.makeStream()
        let installer = installer
        let run = Task.detached { let status = await installer.run("brew install gh", brewDirectory: brew.deletingLastPathComponent()) { sink.yield($0) }; sink.finish(); return status }
        for await chunk in stream { installLog += chunk }
        let status = await run.value
        if status != 0 { message = "\(installCommand) failed (exit \(status)). The output is above." }
        isInstalling = false
        await check()
    }
}
