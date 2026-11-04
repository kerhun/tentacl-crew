import XCTest
import SwiftUI
@testable import AgentPanel

/// N177: the panel reads `gh --version` and `gh auth status` (read-only). Nothing here calls GitHub: the outputs are recorded and
/// the live reader is pointed at a fake `gh` script in a temp folder.
@MainActor
final class GitHubAccountTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    // Recorded output of gh 2.x (stdout; older versions print it to stderr).
    static let signedIn = """
    github.com
      ✓ Logged in to github.com account kerhun (keyring)
      - Active account: true
      - Git operations protocol: https
      - Token: gho_************************************
      - Token scopes: 'gist', 'read:org', 'repo'

    """
    static let several = """
    github.com
      ✓ Logged in to github.com account work-acct (keyring)
      - Active account: false
      - Git operations protocol: ssh
      - Token: gho_************************************
      - Token scopes: 'repo'

      ✓ Logged in to github.com account kerhun (keyring)
      - Active account: true
      - Git operations protocol: https
      - Token: gho_************************************
      - Token scopes: 'gist', 'read:org', 'repo'
    ghe.example.com
      ✓ Logged in to ghe.example.com account corp (keyring)
      - Active account: true
      - Git operations protocol: https

    """
    static let old = """
    github.com
      ✓ Logged in to github.com as kerhun (/Users/u/.config/gh/hosts.yml)
      ✓ Git operations for github.com configured to use ssh protocol.
      ✓ Token: *******************

    """
    static let signedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n"
    static let expired = """
    github.com
      X Failed to log in to github.com account kerhun (keyring)
      - Active account: true
      - The token in keyring is invalid.
      - To re-authenticate, run: gh auth login -h github.com
      - To forget about this account, run: gh auth logout -h github.com -u kerhun

    """

    func testSignedInReadsAccountHostAndProtocol() {
        XCTAssertEqual(GitHubAccount.parseStatus(Self.signedIn, status: 0),
                       .signedIn(GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: [])))
    }

    func testSeveralAccountsUseTheActiveGitHubComOneAndListTheRest() {
        guard case .signedIn(let login) = GitHubAccount.parseStatus(Self.several, status: 0) else { return XCTFail("signed in expected") }
        XCTAssertEqual(login.account, "kerhun"); XCTAssertEqual(login.host, "github.com"); XCTAssertEqual(login.gitProtocol, "https")
        XCTAssertEqual(login.others, ["work-acct", "corp"])
        XCTAssertEqual(login.summary, "kerhun on github.com")
    }

    func testOlderGhPrintsAsInsteadOfAccount() {
        XCTAssertEqual(GitHubAccount.parseStatus(Self.old, status: 0),
                       .signedIn(GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "ssh", others: [])))
    }

    func testSignedOutAndAnInvalidTokenBothCountAsNotSignedIn() {
        XCTAssertEqual(GitHubAccount.parseStatus(Self.signedOut, status: 1), .signedOut)
        XCTAssertEqual(GitHubAccount.parseStatus(Self.expired, status: 1), .signedOut)
    }

    func testOnlyAnEnterpriseHostIsStillSignedInButNamesTheHost() {
        let text = "ghe.example.com\n  ✓ Logged in to ghe.example.com account corp (keyring)\n  - Active account: true\n  - Git operations protocol: https\n"
        guard case .signedIn(let login) = GitHubAccount.parseStatus(text, status: 0) else { return XCTFail("signed in expected") }
        XCTAssertEqual(login.host, "ghe.example.com")
        XCTAssertEqual(login.summary, "corp on ghe.example.com")
    }

    func testAnAnswerThePanelCannotReadIsUnsureNotSignedOut() {
        guard case .unsure(let why) = GitHubAccount.parseStatus("gh: something odd happened\n", status: 2) else { return XCTFail("unsure expected") }
        XCTAssertTrue(why.contains("something odd"), why)
        guard case .unsure = GitHubAccount.parseStatus("", status: 0) else { return XCTFail("exit 0 without an account is unsure") }
    }

    func testVersionLine() {
        XCTAssertEqual(GitHubAccount.parseVersion("gh version 2.62.0 (2024-11-06)\nhttps://github.com/cli/cli/releases/tag/v2.62.0\n"), "2.62.0")
        XCTAssertNil(GitHubAccount.parseVersion("nothing\n"))
    }

    // MARK: check with a fake gh

    private struct FakeCLI: GitHubCLI {
        var version: String? = "gh version 2.62.0 (2024-11-06)"
        var status: Int32 = 0
        var output = GitHubAccountTests.signedIn
        func ghVersion() async -> String? { version }
        func authStatus() async -> (status: Int32, output: String) { (status, output) }
    }

    func testCheckSaysGhMissingWithoutAskingForAuth() async {
        let state = await GitHubAccount.check(FakeCLI(version: nil))
        XCTAssertEqual(state, .ghMissing)
    }

    func testCheckSignedInSignedOutAndSeveral() async {
        let a = await GitHubAccount.check(FakeCLI())
        XCTAssertEqual(a, .signedIn(GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: [])))
        let b = await GitHubAccount.check(FakeCLI(status: 1, output: Self.signedOut))
        XCTAssertEqual(b, .signedOut)
        let c = await GitHubAccount.check(FakeCLI(output: Self.several))
        guard case .signedIn(let login) = c else { return XCTFail("signed in expected") }
        XCTAssertEqual(login.others.count, 2)
    }

    /// The live reader against a fake `gh` script: it runs `--version` and `auth status` and nothing else.
    func testLiveReaderRunsOnlyReadOnlyCommands() async throws {
        let log = dir.url.appendingPathComponent("calls.log")
        let gh = try dir.write("bin/gh", "#!/bin/bash\necho \"$*\" >> '\(log.path)'\ncase \"$1\" in\n--version) echo 'gh version 9.9.9 (2030-01-01)';;\nauth) cat <<'EOF'\n\(Self.signedIn)EOF\n;;\nesac\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let state = await GitHubAccount.check(ProcessGitHubCLI(find: { gh }))
        XCTAssertEqual(state, .signedIn(GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: [])))
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["--version", "auth status"])
    }

    func testLiveReaderWithoutGhIsMissing() async {
        let state = await GitHubAccount.check(ProcessGitHubCLI(find: { nil }))
        XCTAssertEqual(state, .ghMissing)
    }

    func testLiveReaderKeepsStderrAndExitStatus() async throws {
        let gh = try dir.write("bin/gh", "#!/bin/bash\ncase \"$1\" in\n--version) echo 'gh version 1.0.0';;\nauth) echo 'You are not logged into any GitHub hosts.' >&2; exit 1;;\nesac\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let state = await GitHubAccount.check(ProcessGitHubCLI(find: { gh }))
        XCTAssertEqual(state, .signedOut)
    }

    // MARK: the Setup line

    private func setupProbes(github: @escaping @Sendable () async -> GitHubState) -> SetupProbes {
        SetupProbes(findTool: { ["terminal", "claude", "jq"].contains($0) ? URL(fileURLWithPath: "/bin/\($0)") : nil }, claudeVersion: { _ in },
                    terminalServer: { .running }, claudeSignedIn: { _ in true }, codexSignedIn: { _ in true }, roleExists: { _ in true }, isTrusted: { _ in true },
                    github: github)
    }
    private let inputs = SetupInputs(scriptsDir: URL(fileURLWithPath: "/s/scripts"), scriptsProblem: nil,
                                     projects: [ProjectConfig(id: "d", name: "D", repoPath: "/r", dataDir: "/d", maxParallel: 1, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)])

    func testSetupHasAnOptionalGitHubLine() async throws {
        let login = GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: [])
        let okItems = await SetupCheck.run(inputs: inputs, probes: setupProbes { .signedIn(login) })
        let ok = try XCTUnwrap(okItems.first { $0.id == .github })
        XCTAssertEqual(ok.state, .ok); XCTAssertEqual(ok.title, "GitHub: signed in"); XCTAssertFalse(ok.isRequired)
        XCTAssertTrue(ok.detail.contains("kerhun"), ok.detail)

        let outItems = await SetupCheck.run(inputs: inputs, probes: setupProbes { .signedOut })
        let out = try XCTUnwrap(outItems.first { $0.id == .github })
        XCTAssertEqual(out.state, .missing); XCTAssertFalse(out.isRequired); XCTAssertEqual(out.fix, .copy(GitHubAccount.signInCommand))

        let noneItems = await SetupCheck.run(inputs: inputs, probes: setupProbes { .ghMissing })
        let none = try XCTUnwrap(noneItems.first { $0.id == .github })
        XCTAssertEqual(none.state, .missing); XCTAssertFalse(none.isRequired); XCTAssertEqual(none.fix, .copy("brew install gh"))
    }

    func testNotBeingSignedInToGitHubNeverBlocksOrOpensSetup() async {
        for state in [GitHubState.signedOut, .ghMissing] {
            let items = await SetupCheck.run(inputs: inputs, probes: setupProbes { state })
            XCTAssertFalse(SetupCheck.shouldOpen(items, seenBefore: true), "\(state)")
            XCTAssertTrue(InstallPlan.make(items).isEmpty, "GitHub is not part of Install missing")
            XCTAssertFalse(SetupModel.blockingIDs.contains(.github))
        }
    }

    func testAGitHubCheckThatDoesNotAnswerIsUnsure() async throws {
        let items = await SetupCheck.run(inputs: inputs, probes: setupProbes { try? await Task.sleep(nanoseconds: 5_000_000_000); return .signedOut }, timeout: 0.2)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == .github }).state, .unsure)
    }

    // MARK: the Settings model

    private final class FakeTerminal: GitHubTerminal, @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var fails = false
        var commands: [String] { lock.withLock { list } }
        func open(_ command: String) async throws {
            if fails { throw CocoaError(.fileNoSuchFile) }
            lock.withLock { list.append(command) }
        }
    }

    private final class Account: @unchecked Sendable {
        private let lock = NSLock()
        private var value: GitHubState
        init(_ value: GitHubState) { self.value = value }
        var state: GitHubState { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private func model(_ account: Account, terminal: FakeTerminal = FakeTerminal(), brew: URL? = URL(fileURLWithPath: "/fake/brew"), installer: ToolInstalling = FakeInstaller()) -> GitHubAccountModel {
        GitHubAccountModel(read: { account.state }, terminal: terminal, installer: installer, findBrew: { brew }, findGh: { URL(fileURLWithPath: "/fake/bin/gh") })
    }

    private final class FakeInstaller: ToolInstalling, @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[String]] = []
        var status: Int32 = 0
        var onRun: (@Sendable () -> Void)?
        var runs: [[String]] { lock.withLock { list } }
        func run(_ command: String, brewDirectory: URL?, output: @escaping @Sendable (String) -> Void) async -> Int32 {
            lock.withLock { list.append(command.split(separator: " ").dropFirst().map(String.init)) }
            output("==> \(command)\n")
            if status == 0 { onRun?() }
            return status
        }
    }

    func testCheckFillsTheState() async {
        let account = Account(.signedOut)
        let m = model(account)
        XCTAssertNil(m.state, "unknown until the first check")
        await m.check()
        XCTAssertEqual(m.state, .signedOut)
        account.state = .signedIn(GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: []))
        await m.check()
        XCTAssertEqual(m.state?.login?.account, "kerhun")
        XCTAssertFalse(m.isChecking)
    }

    func testSignInOpensTerminalWithTheLoginCommandAndNothingElse() async {
        let terminal = FakeTerminal()
        let m = model(Account(.signedOut), terminal: terminal)
        await m.check()
        await m.signIn()
        XCTAssertEqual(terminal.commands, ["/fake/bin/gh auth login --web --git-protocol https"])
        XCTAssertTrue(m.isWaitingForSignIn)
    }

    func testSignInFailureIsShownAndTheCommandIsGivenToCopy() async {
        let terminal = FakeTerminal(); terminal.fails = true
        let m = model(Account(.signedOut), terminal: terminal)
        await m.signIn()
        XCTAssertFalse(m.isWaitingForSignIn)
        XCTAssertTrue(m.message?.contains(GitHubAccount.signInCommand) == true, m.message ?? "nil")
    }

    func testTheAppBecomingActiveRefreshesOnlyAfterSignInWasStarted() async {
        let account = Account(.signedOut)
        let m = model(account)
        await m.check()
        account.state = .signedIn(GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: []))
        await m.appBecameActive()
        XCTAssertEqual(m.state, .signedOut, "no sign-in started: no refresh")
        await m.signIn()
        await m.appBecameActive()
        XCTAssertEqual(m.state?.login?.account, "kerhun")
        XCTAssertFalse(m.isWaitingForSignIn, "signed in: done waiting")
    }

    func testStillSignedOutAfterComingBackKeepsWaiting() async {
        let m = model(Account(.signedOut))
        await m.signIn()
        await m.appBecameActive()
        XCTAssertTrue(m.isWaitingForSignIn)
        XCTAssertEqual(m.state, .signedOut)
    }

    func testInstallGhShowsTheCommandAndRunsOnlyAfterTheConfirmation() async {
        let account = Account(.ghMissing)
        let installer = FakeInstaller()
        installer.onRun = { account.state = .signedOut }
        let m = model(account, installer: installer)
        await m.check()
        XCTAssertEqual(m.installCommand, "brew install gh")
        m.requestInstall()
        XCTAssertTrue(m.isConfirmingInstall)
        XCTAssertTrue(installer.runs.isEmpty, "nothing runs before the confirmation")
        await m.confirmInstall()
        XCTAssertEqual(installer.runs, [["install", "gh"]])
        XCTAssertTrue(m.installLog.contains("$ brew install gh"), m.installLog)
        XCTAssertEqual(m.state, .signedOut, "checked again after the install")
        XCTAssertFalse(m.isConfirmingInstall)
    }

    func testCancelledInstallRunsNothing() async {
        let installer = FakeInstaller()
        let m = model(Account(.ghMissing), installer: installer)
        await m.check(); m.requestInstall(); m.cancelInstall()
        XCTAssertFalse(m.isConfirmingInstall)
        XCTAssertTrue(installer.runs.isEmpty)
    }

    func testFailedInstallSaysSo() async {
        let installer = FakeInstaller(); installer.status = 1
        let m = model(Account(.ghMissing), installer: installer)
        await m.check(); m.requestInstall(); await m.confirmInstall()
        XCTAssertTrue(m.message?.contains("brew install gh failed") == true, m.message ?? "nil")
    }

    func testWithoutHomebrewTheInstallIsOnlyTheCommandToCopy() async {
        let installer = FakeInstaller()
        let m = model(Account(.ghMissing), brew: nil, installer: installer)
        await m.check()
        XCTAssertFalse(m.canInstall)
        m.requestInstall()
        XCTAssertFalse(m.isConfirmingInstall)
        XCTAssertEqual(m.installCommand, "brew install gh")
        XCTAssertTrue(installer.runs.isEmpty)
    }

    // MARK: Settings screen

    private final class IdleLoginItem: LoginItemControlling, @unchecked Sendable {
        var isEnabled = false
        func setEnabled(_ on: Bool) throws { isEnabled = on }
    }

    func testGitHubIsASettingsCategoryBeforeAdvanced() {
        XCTAssertEqual(SettingsItem.githubAccount.category, .github)
        XCTAssertEqual(SettingsCategory.github.title, "GitHub")
        XCTAssertFalse(SettingsItem.githubAccount.isAdvanced)
        XCTAssertEqual(SettingsItem.matching("github"), [.githubAccount])
        XCTAssertEqual(SettingsItem.matching("gh sign in"), [.githubAccount])
    }

    func testTheThreeStatesRender() async throws {
        let login = GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: [])
        for (name, state) in [("settings-github-signed-in", GitHubState.signedIn(login)), ("settings-github-signed-out", .signedOut), ("settings-github-missing", .ghMissing)] {
            let m = model(Account(state))
            await m.check()
            let flow = SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: URL(fileURLWithPath: "/tmp/p.json"), stableDir: URL(fileURLWithPath: "/tmp/s"),
                                    signingConfigured: false, git: ProcessRunner(timeout: 1), release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") },
                                    appURL: URL(fileURLWithPath: "/tmp/a.app"), processID: 1, launch: { _, _ in },
                                    extras: SettingsExtras(defaults: makeTestDefaults(prefix: "github-render"), loginItem: IdleLoginItem(), toolProbe: { _ in nil }, github: m))
            flow.show(.github)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: flow), size: CGSize(width: 900, height: 480)))
            XCTAssertGreaterThan(data.count, 10_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
        }
    }
}
