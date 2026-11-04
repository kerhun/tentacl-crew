import Foundation
import Observation

enum SetupItemID: String, CaseIterable, Sendable {
    case terminalServer, claude, claudeSignIn, codex, codexSignIn, jq, scripts, project, roles, trust, github

    /// An unfinished required item opens the guide by itself; the others are shown but never force it open.
    /// The tool lines (claude, codex and their sign-in) depend on the roles, so `SetupItem.isRequired` decides for them.
    var isRequired: Bool { [.terminalServer, .claude, .codex, .jq, .scripts, .project, .roles].contains(self) }
}

/// ✓ ok, ✗ missing, ! cannot tell (not installed yet, no answer in time, no evidence either way).
enum SetupState: Equatable, Sendable { case ok, missing, unsure }

enum SetupFix: Equatable, Sendable {
    /// A command (or address) to copy; the panel never runs it.
    case copy(String)
    /// Opens `claude auth login` / `codex login` in Tentacl's own terminal (N329). The command stays visible as text.
    case signIn(AgentTool)
    case chooseScripts
    case addProject
    case addRoles([String])
}

struct SetupItem: Identifiable, Equatable, Sendable {
    let id: SetupItemID
    let title: String
    let state: SetupState
    let detail: String
    var fix: SetupFix? = nil
    /// Set by the check: claude / codex are required only while some role uses them.
    var requiredOverride: Bool? = nil
    var isRequired: Bool { requiredOverride ?? id.isRequired }
}

/// Whether tentacld (the terminal daemon inside the app) answers; `notRunning` carries why it could not be started.
enum TerminalServerState: Equatable, Sendable { case running, notRunning(String) }

/// What the checks need from the panel, copied on the main thread so the checks can run elsewhere.
struct SetupInputs: Sendable {
    var scriptsDir: URL?
    var scriptsProblem: String?
    var projects: [ProjectConfig]
    /// Some role (a project's PM included) runs on Claude / Codex: that tool's lines are required. The Codex lines are also shown, as
    /// optional, while Claude Code is missing or not signed in (N367), so the user can sign in to either; a signed-in Claude-only Setup is unchanged.
    var usesClaude: Bool = true
    var usesCodex: Bool = false
}

/// The machine, as a set of questions. Tests answer them with fakes; none of the live answers runs a paid call or installs anything.
struct SetupProbes: Sendable {
    var findTool: @Sendable (String) -> URL?
    /// `claude --version`: starts the program, talks to nobody.
    var claudeVersion: @Sendable (URL) async throws -> Void
    /// Starts the bundled tentacld helper when nothing answers (as the app does) and says whether it answers.
    var terminalServer: @Sendable () async -> TerminalServerState
    /// `claude auth status` (JSON `loggedIn`); nil = cannot tell (no answer in time, unreadable answer).
    var claudeSignedIn: @Sendable (URL) async -> Bool?
    /// `codex login status`: exit 0 means signed in; nil = cannot tell (no answer in time).
    var codexSignedIn: @Sendable (URL) async -> Bool?
    var roleExists: @Sendable (String) -> Bool
    var isTrusted: @Sendable (String) -> Bool
    /// `gh --version` and `gh auth status` (read-only). Optional: not being signed in never blocks anything.
    var github: @Sendable () async -> GitHubState = { .signedOut }

    static func live(roleBaseDir: URL = RoleStore.defaultBaseDir, trust: ClaudeTrust = .standard) -> SetupProbes {
        SetupProbes(
            findTool: { SetupCheck.findTool($0) },
            claudeVersion: { exe in _ = try await ProcessRunner(timeout: 5).run(exe, ["--version"]) },
            terminalServer: {
                do { try await TentacldClient().ensureRunning(); return .running }
                catch let e as TentacldClient.TentacldError { return .notRunning(e.message) }
                catch { return .notRunning("\(error)") }
            },
            claudeSignedIn: { exe in
                if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false { return true }
                guard let out = await SetupCheck.output(exe, ["auth", "status"], timeout: 5) else { return nil }
                return SetupCheck.parseClaudeAuth(out.stdout)
            },
            codexSignedIn: { exe in await SetupCheck.output(exe, ["login", "status"], timeout: 5).map { $0.status == 0 } },
            roleExists: { name in RoleStore(baseDir: roleBaseDir).baseRoles().roles.contains { $0.config.name == name } },
            isTrusted: { trust.isTrusted($0) },
            github: { await GitHubAccount.check(ProcessGitHubCLI()) })
    }
}

enum SetupCheck {
    static let sharedRoles = ["dev", "pm"]

    /// The guide opens on the first launch, and afterwards only while a required item is missing.
    static func shouldOpen(_ items: [SetupItem], seenBefore: Bool) -> Bool {
        !seenBefore || items.contains { $0.isRequired && $0.state == .missing }
    }

    /// `name` on PATH and in the usual install folders (an app started from Finder has a short PATH).
    static func findTool(_ name: String, pathDirs: [String]? = nil, home: String? = nil) -> URL? {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirs = pathDirs ?? (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = pathDirs + ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `exe` and returns its exit status and stdout; nil when it cannot start or does not finish within `timeout` seconds (it is stopped then).
    static func output(_ exe: URL, _ arguments: [String], timeout: TimeInterval) async -> (status: Int32, stdout: Data)? {
        await withCheckedContinuation { continuation in
            let process = Process(), pipe = Pipe()
            process.executableURL = exe; process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: p.terminationReason == .exit ? (p.terminationStatus, data) : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }

    /// `loggedIn` of `claude auth status`'s JSON; nil when the answer is not that JSON.
    static func parseClaudeAuth(_ data: Data) -> Bool? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["loggedIn"] as? Bool
    }

    /// Whether `tool` is signed in (nil = cannot tell, also when it is not installed: Setup says that). Bounded by `timeout`.
    static func signedIn(_ tool: AgentTool, probes: SetupProbes, timeout: TimeInterval = 6) async -> Bool? {
        guard let exe = probes.findTool(tool == .claude ? "claude" : "codex") else { return nil }
        let answer: Bool?? = await bounded(timeout) { tool == .claude ? await probes.claudeSignedIn(exe) : await probes.codexSignedIn(exe) }
        return answer ?? nil
    }

    /// Runs `work` for at most `seconds`; nil when it did not answer in time.
    static func bounded<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// All checks, side by side, off the main thread. A check that does not answer within `timeout` seconds is "!" ("cannot tell"), never "✗".
    static func run(inputs: SetupInputs, probes: SetupProbes, timeout: TimeInterval = 6) async -> [SetupItem] {
        async let claudeURL = bounded(timeout) { probes.findTool("claude") }
        async let jqURL = bounded(timeout) { probes.findTool("jq") }
        async let codexURL = bounded(timeout) { probes.findTool("codex") }
        let claude = await claudeURL ?? nil, jq = await jqURL ?? nil, codexFound = await codexURL ?? nil

        async let server: TerminalServerState? = bounded(timeout) { await probes.terminalServer() }
        async let version: Bool?? = claude == nil ? nil : bounded(timeout) { (try? await probes.claudeVersion(claude!)) != nil }
        async let signed: Bool?? = claude == nil ? nil : bounded(timeout) { await probes.claudeSignedIn(claude!) }
        async let roleFlags: [String: Bool]? = bounded(timeout) { Dictionary(uniqueKeysWithValues: sharedRoles.map { ($0, probes.roleExists($0)) }) }
        async let githubState: GitHubState? = bounded(timeout) { await probes.github() }
        async let untrusted: [String]? = bounded(timeout) { inputs.projects.map(\.repoPath).filter { !probes.isTrusted($0) } }
        let serverState = await server, versionOK = await version, signedIn = (await signed) ?? nil, roles = await roleFlags, notTrusted = await untrusted, githubNow = await githubState

        var items: [SetupItem] = []
        func tool(_ id: SetupItemID, _ title: String, _ url: URL?, ok: String, missing: String, command: String) -> SetupItem {
            url.map { SetupItem(id: id, title: title, state: .ok, detail: "\(ok) (\($0.path)).") }
                ?? SetupItem(id: id, title: title, state: .missing, detail: missing, fix: .copy(command))
        }
        switch serverState {
        case .running?: items.append(SetupItem(id: .terminalServer, title: "Terminal running", state: .ok, detail: "Tentacl Crew's terminal (tentacld) answers. The agents run in it; no other terminal app is needed."))
        case .notRunning(let why)?: items.append(SetupItem(id: .terminalServer, title: "Terminal running", state: .missing, detail: "Tentacl Crew's terminal (tentacld) could not be started: \(why)"))
        case nil: items.append(SetupItem(id: .terminalServer, title: "Terminal running", state: .unsure, detail: "tentacld did not answer within \(Int(timeout)) seconds."))
        }

        if claude == nil {
            items.append(SetupItem(id: .claude, title: "claude installed", state: .missing, detail: "The claude command (Claude Code) is not installed.", fix: .copy(InstallPlan.claudeCommand)))
            items.append(SetupItem(id: .claudeSignIn, title: "Claude Code signed in", state: .unsure, detail: "Checked once claude is installed."))
        } else {
            switch versionOK {
            case .some(.some(true)): items.append(SetupItem(id: .claude, title: "claude installed", state: .ok, detail: "claude is installed (\(claude!.path))."))
            case .some(.some(false)): items.append(SetupItem(id: .claude, title: "claude installed", state: .unsure, detail: "claude is there but `claude --version` failed."))
            default: items.append(SetupItem(id: .claude, title: "claude installed", state: .unsure, detail: "claude did not answer within \(Int(timeout)) seconds."))
            }
            switch signedIn {
            case true?: items.append(SetupItem(id: .claudeSignIn, title: "Claude Code signed in", state: .ok, detail: "`claude auth status` reports a login."))
            case false?: items.append(SetupItem(id: .claudeSignIn, title: "Claude Code signed in", state: .missing, detail: "Claude Code is not signed in. Run claude auth login.", fix: .signIn(.claude)))
            case nil: items.append(SetupItem(id: .claudeSignIn, title: "Claude Code signed in", state: .unsure, detail: "`claude auth status` gave no usable answer within \(Int(timeout)) seconds."))
            }
        }

        let claudeRequired = inputs.usesClaude
        for index in items.indices where items[index].id == .claude || items[index].id == .claudeSignIn { items[index].requiredOverride = claudeRequired }

        // Codex: required while a role or a project's PM uses it; else offered (optional) while Claude Code cannot be used (N367).
        let showCodex = inputs.usesCodex || claude == nil || signedIn == false
        let codex = showCodex ? codexFound : nil
        let codexIn: Bool? = codex == nil ? nil : ((await bounded(timeout) { await probes.codexSignedIn(codex!) }) ?? nil)
        if showCodex {
            if codex == nil {
                items.append(SetupItem(id: .codex, title: "codex installed", state: .missing,
                                       detail: inputs.usesCodex ? "The codex command (OpenAI Codex CLI) is not installed. A role uses it." : "Optional: the codex command (OpenAI Codex CLI) is not installed. Install it to run the PM or roles on Codex instead.",
                                       fix: .copy(InstallPlan.codexCommand)))
                items.append(SetupItem(id: .codexSignIn, title: "Codex signed in", state: .unsure, detail: "Checked once codex is installed."))
            } else {
                items.append(SetupItem(id: .codex, title: "codex installed", state: .ok, detail: "codex is installed (\(codex!.path))."))
                switch codexIn {
                case true?: items.append(SetupItem(id: .codexSignIn, title: "Codex signed in", state: .ok, detail: "`codex login status` reports a login."))
                case false?: items.append(SetupItem(id: .codexSignIn, title: "Codex signed in", state: .missing, detail: "Codex is not signed in. Run codex login.", fix: .signIn(.codex)))
                case nil: items.append(SetupItem(id: .codexSignIn, title: "Codex signed in", state: .unsure, detail: "`codex login status` did not answer within \(Int(timeout)) seconds."))
                }
            }
            for index in items.indices where items[index].id == .codex || items[index].id == .codexSignIn { items[index].requiredOverride = inputs.usesCodex }
        }

        items.append(tool(.jq, "jq installed", jq, ok: "jq is installed", missing: "jq is not installed. The scripts need it.", command: InstallPlan.jqCommand()))

        if let dir = inputs.scriptsDir { items.append(SetupItem(id: .scripts, title: "Scripts folder set", state: .ok, detail: dir.path)) }
        else { items.append(SetupItem(id: .scripts, title: "Scripts folder set", state: .missing, detail: inputs.scriptsProblem ?? "The panel does not know where the Tentacl Crew scripts are. Choose the scripts folder of the repository.", fix: .chooseScripts)) }

        if inputs.projects.isEmpty {
            items.append(SetupItem(id: .project, title: "At least one project", state: .missing,
                                   detail: inputs.scriptsDir == nil ? "No project yet. Choose the scripts folder first; then Add project works." : "No project yet. Add one with Add project.",
                                   fix: inputs.scriptsDir == nil ? nil : .addProject))
        } else { items.append(SetupItem(id: .project, title: "At least one project", state: .ok, detail: inputs.projects.map(\.name).joined(separator: ", "))) }

        if let roles {
            let missing = sharedRoles.filter { roles[$0] != true }
            items.append(missing.isEmpty ? SetupItem(id: .roles, title: "Shared dev and pm roles", state: .ok, detail: "The shared library has dev and pm.")
                                         : SetupItem(id: .roles, title: "Shared dev and pm roles", state: .missing, detail: "Missing in the shared library: \(missing.joined(separator: ", ")). They can be added from the templates.", fix: .addRoles(missing)))
        } else { items.append(SetupItem(id: .roles, title: "Shared dev and pm roles", state: .unsure, detail: "The check did not answer within \(Int(timeout)) seconds.")) }

        if inputs.projects.isEmpty { items.append(SetupItem(id: .trust, title: "Project folder trusted by Claude Code", state: .unsure, detail: "No project to check yet.")) }
        else if let notTrusted {
            if let first = notTrusted.first {
                let command = inputs.scriptsDir.map { "bash \($0.path)/trust-folder.sh \(first)" } ?? "cd \(first) && claude"
                items.append(SetupItem(id: .trust, title: "Project folder trusted by Claude Code", state: .missing, detail: "Claude Code does not trust \(first) yet; an agent started there would stop at a question.", fix: .copy(command)))
            } else { items.append(SetupItem(id: .trust, title: "Project folder trusted by Claude Code", state: .ok, detail: "Every project folder is trusted.")) }
        } else { items.append(SetupItem(id: .trust, title: "Project folder trusted by Claude Code", state: .unsure, detail: "The check did not answer within \(Int(timeout)) seconds.")) }

        items.append(githubItem(githubNow, timeout: timeout))
        return items
    }

    /// The optional GitHub line (`requiredOverride` false: it never opens or blocks the guide).
    private static func githubItem(_ state: GitHubState?, timeout: TimeInterval) -> SetupItem {
        var item: SetupItem
        switch state {
        case .signedIn(let login)?: item = SetupItem(id: .github, title: "GitHub: signed in", state: .ok, detail: "\(login.summary). Tentacl Crew uses this login to create repositories and push.")
        case .signedOut?: item = SetupItem(id: .github, title: "GitHub: not signed in", state: .missing, detail: "Optional. Sign in once to create repositories and push from Tentacl Crew (Settings → GitHub).", fix: .copy(GitHubAccount.signInCommand))
        case .ghMissing?: item = SetupItem(id: .github, title: "GitHub: CLI missing", state: .missing, detail: "Optional. Tentacl Crew talks to GitHub through the GitHub CLI (gh).", fix: .copy(GitHubAccount.installCommand))
        case .unsure(let why)?: item = SetupItem(id: .github, title: "GitHub: cannot tell", state: .unsure, detail: "gh gave an answer the panel cannot use: \(why)")
        case nil: item = SetupItem(id: .github, title: "GitHub: cannot tell", state: .unsure, detail: "gh did not answer within \(Int(timeout)) seconds.")
        }
        item.requiredOverride = false
        return item
    }

    /// Why `folder` cannot be the scripts folder, or nil when it can: every script the panel runs must be in it.
    static func validateScripts(_ folder: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return "\(folder.path) is not a folder." }
        let candidate = AppSettings(scriptsDir: folder, problems: [])
        let missing = ScriptName.allCases.filter { candidate.scriptURL($0) == nil }
        return missing.isEmpty ? nil : "This is not the scripts folder: missing \(missing.map(\.rawValue).joined(separator: ", ")). Choose the scripts folder of the agent-panel repository."
    }

    /// Sets `scriptsDir` and keeps every other key. A file that cannot be read is never overwritten.
    static func writeScriptsDir(_ dir: URL, to settingsURL: URL) throws {
        try AppSettingsStore.update(settingsURL) { $0["scriptsDir"] = dir.standardizedFileURL.path }
    }
}

/// One command of the install plan, shown to the user exactly as it runs (through `bash -c`).
struct InstallStep: Equatable, Sendable {
    let command: String
}

/// What "Install missing" does: each missing tool with its own official installer (they put it in ~/.local/bin; none needs sudo).
/// Only tools the check did not find anywhere (PATH, ~/.local/bin, the brew folders, /usr/bin) are in it, so nothing gets a second copy.
struct InstallPlan: Equatable, Sendable {
    var tools: [String]
    var steps: [InstallStep]
    /// The n of "Install missing (n)".
    var count: Int { tools.count }
    var isEmpty: Bool { tools.isEmpty }

    static let claudeCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let codexCommand = "curl -fsSL https://github.com/openai/codex/releases/latest/download/install.sh | CODEX_NON_INTERACTIVE=true sh"

    /// "arm64" or "x86_64" (`uname -m`).
    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// macOS 15+ ships /usr/bin/jq (the check finds it, so this never runs there); macOS 14 gets the official binary in ~/.local/bin.
    static func jqCommand(arch: String = currentArch) -> String {
        let name = arch == "arm64" ? "jq-macos-arm64" : "jq-macos-amd64"
        return "mkdir -p ~/.local/bin && curl -fsSL -o ~/.local/bin/jq https://github.com/jqlang/jq/releases/latest/download/\(name) && chmod +x ~/.local/bin/jq"
    }

    static func make(_ items: [SetupItem], arch: String = currentArch) -> InstallPlan {
        let packages: [(SetupItemID, String, String)] = [(.jq, "jq", jqCommand(arch: arch)),
                                                         (.claude, "claude", claudeCommand), (.codex, "codex", codexCommand)]
        let missing = packages.filter { pkg in items.contains { $0.id == pkg.0 && $0.isRequired && $0.state == .missing } }
        return InstallPlan(tools: missing.map(\.1), steps: missing.map { InstallStep(command: $0.2) })
    }
}

/// Runs one install command with its output streamed as it comes. Tests put a fake in its place; nothing is installed on this Mac by a test.
protocol ToolInstalling: Sendable {
    /// The exit status; the output (stdout and stderr together) goes to `output` in order.
    func run(_ command: String, brewDirectory: URL?, output: @escaping @Sendable (String) -> Void) async -> Int32
}

struct ShellInstaller: ToolInstalling {
    func run(_ command: String, brewDirectory: URL?, output: @escaping @Sendable (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["-c", "set -o pipefail; " + command]
            var env = ProcessInfo.processInfo.environment
            // An app started from Finder has a short PATH; the installers need the system tools, and brew its own folder.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = ([brewDirectory?.path].compactMap { $0 } + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                           + (env["PATH"].map { [$0] } ?? [])).joined(separator: ":")
            env["NONINTERACTIVE"] = "1"; env["HOMEBREW_NO_ENV_HINTS"] = "1"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            let reader = pipe.fileHandleForReading
            reader.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { output(String(decoding: data, as: UTF8.self)) }
            }
            process.terminationHandler = { finished in
                reader.readabilityHandler = nil
                let rest = reader.readDataToEndOfFile()
                if !rest.isEmpty { output(String(decoding: rest, as: UTF8.self)) }
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() } catch {
                reader.readabilityHandler = nil
                output("Could not start the install: \(error.localizedDescription)\n")
                continuation.resume(returning: -1)
            }
        }
    }
}

/// The empty task list: Add project first, Setup when something is missing. Never the settings file.
func emptyProjectsHint(setupMissing: Bool) -> String {
    setupMissing ? "Open Setup to see what is missing, then use Add project in the top bar."
                 : "Use Add project in the top bar to create a project or add one from disk."
}

@Observable @MainActor
final class SetupModel {
    static let seenKey = "setup.seen"

    private(set) var items: [SetupItem] = []
    private(set) var isChecking = false
    /// When the last check finished (Settings › Advanced shows it, N340).
    private(set) var checkedAt: Date?
    private(set) var message: String?
    var isOpen = false

    @ObservationIgnored private let probes: SetupProbes
    @ObservationIgnored private let inputs: @MainActor () -> SetupInputs
    @ObservationIgnored private let settingsURL: URL
    @ObservationIgnored private let picker: FolderPicking
    @ObservationIgnored private let roleBaseDir: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onSettingsChanged: @MainActor () -> Void
    @ObservationIgnored private let installer: ToolInstalling
    /// "Install missing" was pressed: the plan is shown and waits for the one confirmation.
    private(set) var isConfirmingInstall = false
    private(set) var isInstalling = false
    /// The live output of the install, shown in the sheet.
    private(set) var installLog = ""

    /// `~/.claude/CLAUDE.md` → `~/.codex/AGENTS.md` (N367): offered once the Codex lines are shown and codex is installed.
    @ObservationIgnored let codexRules: CodexRules
    /// The open "Copy my Claude rules to Codex…" sheet.
    var rulesFlow: CodexRulesFlow?

    init(probes: SetupProbes, inputs: @escaping @MainActor () -> SetupInputs, settingsURL: URL, picker: FolderPicking, roleBaseDir: URL = RoleStore.defaultBaseDir,
         defaults: UserDefaults = .standard, installer: ToolInstalling = ShellInstaller(), codexRules: CodexRules = CodexRules(),
         onSettingsChanged: @escaping @MainActor () -> Void) {
        self.probes = probes; self.inputs = inputs; self.settingsURL = settingsURL; self.picker = picker; self.installer = installer; self.codexRules = codexRules
        self.roleBaseDir = roleBaseDir; self.defaults = defaults; self.onSettingsChanged = onSettingsChanged
    }

    /// A required item is missing: the task list points to Setup.
    var hasMissingRequired: Bool { items.contains { $0.isRequired && $0.state == .missing } }

    /// The terminal or a required tool is missing: Setup cannot be closed (the dashboard needs them).
    var blockingItems: [SetupItem] { items.filter { $0.isRequired && $0.state == .missing && SetupModel.blockingIDs.contains($0.id) } }
    var blocksDashboard: Bool { !blockingItems.isEmpty }
    static let blockingIDs: Set<SetupItemID> = [.terminalServer, .claude, .codex, .jq]

    var installPlan: InstallPlan { InstallPlan.make(items) }

    /// Codex is shown and installed, and `~/.codex/AGENTS.md` lacks the user's Claude rules: Setup offers to copy them.
    var offersCodexRules: Bool { items.contains { $0.id == .codex && $0.state == .ok } && codexRules.needsOffer }
    func openRules() { rulesFlow = CodexRulesFlow(rules: codexRules) }

    func setItemsForPreview(_ items: [SetupItem], checkedAt: Date? = nil) { self.items = items; self.checkedAt = checkedAt }
    func markSeen() { defaults.set(true, forKey: Self.seenKey) }

    /// Closes the guide unless a required tool is missing; says what is missing then. Returns whether it closed.
    @discardableResult func close() -> Bool {
        if blocksDashboard {
            message = "Tentacl Crew needs \(blockingItems.map { $0.id.rawValue }.joined(separator: ", ")) before it can open."
            isOpen = true
            return false
        }
        isOpen = false
        return true
    }

    /// Runs every check again.
    func check() async {
        isChecking = true
        let snapshot = inputs(), probes = probes
        items = await SetupCheck.run(inputs: snapshot, probes: probes)
        checkedAt = Date()
        isChecking = false
    }

    /// "Install missing (n)": shows what will run and waits for the confirmation.
    func requestInstall() { message = nil; isConfirmingInstall = !installPlan.isEmpty }
    func cancelInstall() { isConfirmingInstall = false }

    /// The one confirmation: the install steps start now.
    func confirmInstall() async {
        isConfirmingInstall = false
        let plan = installPlan
        guard !plan.isEmpty else { return }
        installLog = ""
        await runSteps(plan.steps)
    }

    /// Runs the install steps one after another with live output; stops at the first failure. Checks again at the end.
    private func runSteps(_ steps: [InstallStep]) async {
        guard !isInstalling else { return }
        isInstalling = true
        for step in steps {
            installLog += "$ \(step.command)\n"
            let (stream, sink) = AsyncStream<String>.makeStream()
            let installer = installer, command = step.command
            let run = Task.detached { let status = await installer.run(command, brewDirectory: nil) { sink.yield($0) }; sink.finish(); return status }
            for await chunk in stream { appendLog(chunk) }
            let status = await run.value
            if status != 0 {
                message = "\(step.command) failed (exit \(status)). The output is above; fix it and press Install missing again."
                break
            }
        }
        isInstalling = false
        await check()
    }

    /// Keeps the last 400 lines (an installer can print a lot).
    private func appendLog(_ chunk: String) {
        installLog += chunk
        let lines = installLog.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 400 { installLog = lines.suffix(400).joined(separator: "\n") }
    }

    /// At startup: check, and say whether the guide should open now.
    func checkOnLaunch() async -> Bool {
        await check()
        return SetupCheck.shouldOpen(items, seenBefore: defaults.bool(forKey: Self.seenKey))
    }

    func open() { isOpen = true; markSeen(); Task { await check() } }

    /// Asks for a folder, refuses one without the scripts (with the reason), otherwise writes `scriptsDir`.
    func chooseScripts() async {
        message = nil
        guard let path = picker.chooseFolder(message: "Choose the scripts folder of the agent-panel repository") else { return }
        let folder = URL(fileURLWithPath: path)
        if let reason = SetupCheck.validateScripts(folder) { message = reason; return }
        do { try SetupCheck.writeScriptsDir(folder, to: settingsURL) } catch { message = "Could not save scriptsDir: \(error.localizedDescription)"; return }
        onSettingsChanged()
        await check()
    }

    /// Writes the named shared roles from their templates; a role that already exists is left alone.
    func addRoles(_ names: [String]) async {
        message = nil
        let writer = RoleWriter(store: RoleStore(baseDir: roleBaseDir))
        for name in names {
            guard let template = RoleTemplates.all.first(where: { $0.id == name }) else { continue }
            let (config, _) = template.draft.config()
            do { _ = try writer.save(config, instructions: template.draft.instructions, at: .base, replacing: nil) }
            catch RoleWriteError.exists { continue }
            catch { message = "Could not add the \(name) role: \(error)"; return }
        }
        onSettingsChanged()
        await check()
    }
}
