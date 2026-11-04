import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class SetupCheckTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo/demo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)

    /// The probes run at the same time, so the list is behind a lock (an unlocked append could lose a call).
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var commands: [String] { lock.withLock { list } }
        func append(_ command: String) { lock.withLock { list.append(command) } }
    }

    private func probes(tools: Set<String> = ["claude", "jq", "codex"], codexSignedIn: Bool = true, server: TerminalServerState = .running, versionFails: Bool = false, signedIn: Bool = true,
                        roles: Set<String> = ["dev", "pm"], trusted: Bool = true, hang: Set<String> = [], calls: Calls = Calls()) -> SetupProbes {
        SetupProbes(
            findTool: { tools.contains($0) ? URL(fileURLWithPath: "/bin/\($0)") : nil },
            claudeVersion: { _ in
                calls.append("claude --version")
                if hang.contains("claude") { try await Task.sleep(nanoseconds: 5_000_000_000) }
                if versionFails { throw CocoaError(.fileNoSuchFile) }
            },
            terminalServer: {
                if hang.contains("terminal") { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                return server
            },
            claudeSignedIn: { _ in signedIn },
            codexSignedIn: { _ in
                calls.append("codex login status")
                if hang.contains("codex") { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                return codexSignedIn
            },
            roleExists: { roles.contains($0) },
            isTrusted: { _ in trusted },
            github: { .signedIn(GitHubLogin(account: "kerhun", host: "github.com", gitProtocol: "https", others: [])) })
    }

    private func inputs(scripts: Bool = true, projects: [ProjectConfig]? = nil, claude: Bool = true, codex: Bool = false) -> SetupInputs {
        SetupInputs(scriptsDir: scripts ? URL(fileURLWithPath: "/s/scripts") : nil, scriptsProblem: nil, projects: projects ?? [project], usesClaude: claude, usesCodex: codex)
    }

    private func state(_ items: [SetupItem], _ id: SetupItemID) -> SetupState { items.first { $0.id == id }!.state }

    func testEverythingPresentIsAllOk() async {
        let items = await SetupCheck.run(inputs: inputs(), probes: probes())
        XCTAssertEqual(items.map(\.id), SetupItemID.allCases.filter { ![.codex, .codexSignIn].contains($0) })
        XCTAssertTrue(items.allSatisfy { $0.state == .ok }, "\(items)")
        XCTAssertFalse(SetupCheck.shouldOpen(items, seenBefore: true))
        let both = await SetupCheck.run(inputs: inputs(codex: true), probes: probes())
        XCTAssertEqual(both.map(\.id), SetupItemID.allCases)
        XCTAssertTrue(both.allSatisfy { $0.state == .ok }, "\(both)")
    }

    // MARK: the terminal (tentacld)

    func testTheTerminalLineChecksTentacldAndNeedsNoOtherTool() async {
        let items = await SetupCheck.run(inputs: inputs(), probes: probes(tools: ["claude", "jq"]))
        XCTAssertEqual(state(items, .terminalServer), .ok)
        XCTAssertTrue(items.first { $0.id == .terminalServer }!.detail.contains("tentacld"))
        XCTAssertNil(items.first { $0.title.lowercased().contains("installed") && $0.id != .claude && $0.id != .jq }, "no terminal program is looked for")
        XCTAssertFalse(SetupCheck.shouldOpen(items, seenBefore: true))
    }

    func testATerminalThatCannotStartIsMissingAndOpensTheGuide() async {
        let items = await SetupCheck.run(inputs: inputs(), probes: probes(server: .notRunning("no such file")))
        XCTAssertEqual(state(items, .terminalServer), .missing)
        XCTAssertTrue(items.first { $0.id == .terminalServer }!.detail.contains("no such file"))
        XCTAssertTrue(items.first { $0.id == .terminalServer }!.isRequired)
        XCTAssertTrue(SetupCheck.shouldOpen(items, seenBefore: true))
    }

    func testSetupTerminalSnapshot() async throws {
        let items = await SetupCheck.run(inputs: inputs(scripts: false, projects: []), probes: probes(tools: ["claude", "jq"]))
        let (m, _, _) = model(picker: nil)
        m.setItemsForPreview(items)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SetupView(model: m, onClose: {}, onAddProject: {}), size: CGSize(width: 640, height: 860)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("setup-terminal.png")) }
    }

    // MARK: N143 one-click install

    /// The tools on the fake machine; an install adds to them.
    private final class Machine: @unchecked Sendable {
        private let lock = NSLock()
        private var set: Set<String>
        init(_ tools: Set<String>) { set = tools }
        var tools: Set<String> { lock.withLock { set } }
        func add(_ names: [String]) { lock.withLock { set.formUnion(names) } }
    }

    /// Records the install commands; never runs anything.
    private final class FakeInstaller: ToolInstalling, @unchecked Sendable {
        private let lock = NSLock()
        private var runList: [String] = []
        var runs: [String] { lock.withLock { runList } }
        let status: Int32
        let machine: Machine?
        init(status: Int32 = 0, machine: Machine? = nil) { self.status = status; self.machine = machine }
        func run(_ command: String, brewDirectory: URL?, output: @escaping @Sendable (String) -> Void) async -> Int32 {
            lock.withLock { runList.append(command) }
            output("==> \(command)\n")
            if status == 0 { machine?.add(Self.tools(in: command)) }
            return status
        }
        static func tools(in command: String) -> [String] {
            if command == InstallPlan.claudeCommand { return ["claude"] }
            if command == InstallPlan.codexCommand { return ["codex"] }
            if command.contains("/jq") { return ["jq"] }
            return []
        }
    }

    private func installModel(_ machine: Machine, codex: Bool = false, installer: ToolInstalling) -> SetupModel {
        let base = probes()
        let live = SetupProbes(findTool: { machine.tools.contains($0) ? URL(fileURLWithPath: "/fake/bin/\($0)") : nil }, claudeVersion: base.claudeVersion,
                               terminalServer: base.terminalServer, claudeSignedIn: base.claudeSignedIn, codexSignedIn: base.codexSignedIn,
                               roleExists: base.roleExists, isTrusted: base.isTrusted, github: base.github)
        return SetupModel(probes: live, inputs: { [self] in inputs(codex: codex) }, settingsURL: dir.url.appendingPathComponent("cfg/projects.json"),
                          picker: Picker(path: nil), roleBaseDir: dir.url.appendingPathComponent("roles"), defaults: makeTestDefaults(prefix: "setup-install"),
                          installer: installer, onSettingsChanged: {})
    }

    func testInstallPlanForEachMissingSet() async {
        func plan(_ tools: Set<String>, claude: Bool = true, codex: Bool = false, versionFails: Bool = false, arch: String = "arm64") async -> InstallPlan {
            let items = await SetupCheck.run(inputs: inputs(claude: claude, codex: codex), probes: probes(tools: tools, versionFails: versionFails))
            return InstallPlan.make(items, arch: arch)
        }
        let none = await plan(["claude", "jq"])
        XCTAssertTrue(none.isEmpty); XCTAssertEqual(none.count, 0)
        let claudeOnly = await plan(["jq"])
        XCTAssertEqual(claudeOnly.steps.map(\.command), ["curl -fsSL https://claude.ai/install.sh | bash"])
        XCTAssertEqual(claudeOnly.count, 1)
        let jqArm = await plan(["claude"], arch: "arm64")
        XCTAssertEqual(jqArm.steps.map(\.command), ["mkdir -p ~/.local/bin && curl -fsSL -o ~/.local/bin/jq https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64 && chmod +x ~/.local/bin/jq"])
        let jqIntel = await plan(["claude"], arch: "x86_64")
        XCTAssertTrue(jqIntel.steps[0].command.contains("/jq-macos-amd64 "), jqIntel.steps[0].command)
        let codexRole = await plan(["claude", "jq"], codex: true)
        XCTAssertEqual(codexRole.steps.map(\.command), ["curl -fsSL https://github.com/openai/codex/releases/latest/download/install.sh | CODEX_NON_INTERACTIVE=true sh"])
        let codexUnused = await plan(["claude", "jq"], codex: false)
        XCTAssertTrue(codexUnused.isEmpty, "codex only when a role uses it")
        let all = await plan([], codex: true)
        XCTAssertEqual(all.steps.map(\.command).map { $0.split(separator: " ").first.map(String.init) ?? "" }, ["mkdir", "curl", "curl"])
        XCTAssertEqual(all.tools, ["jq", "claude", "codex"])
        let claudeUnused = await plan(["jq"], claude: false)
        XCTAssertTrue(claudeUnused.isEmpty, "claude is not installed when no role uses it")
        let claudeBroken = await plan(["jq", "claude"], versionFails: true)
        XCTAssertTrue(claudeBroken.isEmpty, "a claude that is there (even one that fails) never gets a second copy")
        for command in [InstallPlan.claudeCommand, InstallPlan.codexCommand, InstallPlan.jqCommand()] { XCTAssertFalse(command.contains("sudo"), command) }
    }

    func testClaudeLinesAreOptionalWhenNoRoleUsesClaude() async {
        let items = await SetupCheck.run(inputs: inputs(claude: false, codex: true), probes: probes(tools: ["jq", "codex"]))
        for id in [SetupItemID.claude, .claudeSignIn] { XCTAssertFalse(items.first { $0.id == id }!.isRequired, "\(id)") }
        XCTAssertFalse(SetupCheck.shouldOpen(items.filter { $0.id != .project && $0.id != .roles && $0.id != .trust && $0.id != .github }, seenBefore: true), "a missing Claude never opens the guide")
        let used = await SetupCheck.run(inputs: inputs(claude: true, codex: true), probes: probes(tools: ["jq", "codex"]))
        XCTAssertTrue(used.first { $0.id == .claude }!.isRequired)
    }

    func testCopyCommandsAreTheCurlInstallers() async {
        let items = await SetupCheck.run(inputs: inputs(codex: true), probes: probes(tools: []))
        XCTAssertEqual(items.first { $0.id == .claude }?.fix, .copy(InstallPlan.claudeCommand))
        XCTAssertEqual(items.first { $0.id == .codex }?.fix, .copy(InstallPlan.codexCommand))
        XCTAssertEqual(items.first { $0.id == .jq }?.fix, .copy(InstallPlan.jqCommand()))
    }

    func testSetupCannotBeClosedWhileARequiredToolIsMissing() async {
        let machine = Machine(["claude"])
        let m = installModel(machine, installer: FakeInstaller())
        m.open(); await m.check()
        XCTAssertTrue(m.blocksDashboard)
        XCTAssertFalse(m.close())
        XCTAssertTrue(m.isOpen)
        XCTAssertEqual(m.message, "Tentacl Crew needs jq before it can open.")
        machine.add(["jq"])
        await m.check()
        XCTAssertFalse(m.blocksDashboard)
        XCTAssertTrue(m.close())
        XCTAssertFalse(m.isOpen)

        let noScripts = SetupModel(probes: probes(), inputs: { [self] in inputs(scripts: false, projects: []) }, settingsURL: dir.url.appendingPathComponent("x.json"),
                                   picker: Picker(path: nil), defaults: makeTestDefaults(prefix: "setup-x"), installer: FakeInstaller(), onSettingsChanged: {})
        await noScripts.check()
        XCTAssertTrue(noScripts.hasMissingRequired)
        XCTAssertFalse(noScripts.blocksDashboard, "only the terminal and the tools block; a project is added after Setup")
    }

    func testOneClickAsksOnceRunsEveryMissingToolAndChecksAgain() async {
        let machine = Machine(["claude"])
        let installer = FakeInstaller(machine: machine)
        let m = installModel(machine, codex: true, installer: installer)
        await m.check()
        XCTAssertEqual(m.installPlan.count, 2)
        m.requestInstall()
        XCTAssertTrue(m.isConfirmingInstall)
        XCTAssertTrue(installer.runs.isEmpty, "nothing runs before the confirmation")
        await m.confirmInstall()
        XCTAssertEqual(installer.runs, [InstallPlan.jqCommand(), InstallPlan.codexCommand])
        XCTAssertTrue(m.installLog.contains("$ \(InstallPlan.codexCommand)\n==> \(InstallPlan.codexCommand)"), m.installLog)
        XCTAssertFalse(m.blocksDashboard, "checked again after the install")
        XCTAssertTrue(m.installPlan.isEmpty)
        XCTAssertNil(m.message)
    }

    func testAFailingInstallStopsAndSaysSo() async {
        let installer = FakeInstaller(status: 1)
        let m = installModel(Machine([]), installer: installer)
        await m.check()
        m.requestInstall(); await m.confirmInstall()
        XCTAssertEqual(installer.runs, [InstallPlan.jqCommand()], "the next install after a failed one does not start")
        XCTAssertEqual(m.message, "\(InstallPlan.jqCommand()) failed (exit 1). The output is above; fix it and press Install missing again.")
        XCTAssertTrue(m.blocksDashboard)
        XCTAssertFalse(m.isInstalling)
    }

    /// The live runner with harmless local commands: output (stdout and stderr), the status, a failing pipe stage and the PATH come through. Nothing is installed.
    func testShellInstallerStreamsOutputAndReportsTheStatus() async {
        final class Out: @unchecked Sendable { let lock = NSLock(); var text = ""; func add(_ s: String) { lock.withLock { text += s } } }
        let out = Out()
        let status = await ShellInstaller().run("echo hello; echo warn >&2", brewDirectory: nil) { out.add($0) }
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.text.contains("hello") && out.text.contains("warn"), out.text)
        let failed = await ShellInstaller().run("false | cat", brewDirectory: nil) { _ in }
        XCTAssertEqual(failed, 1, "a failing download is not hidden by the shell at the end of the pipe")
        let path = Out()
        _ = await ShellInstaller().run("echo $PATH", brewDirectory: URL(fileURLWithPath: "/custom/brew")) { path.add($0) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(path.text.hasPrefix("/custom/brew:\(home)/.local/bin:"), path.text)
    }

    func testSetupInstallSnapshot() async throws {
        let m = installModel(Machine(["claude"]), codex: true, installer: FakeInstaller())
        await m.check()
        m.requestInstall()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SetupView(model: m, onClose: {}, onAddProject: {}), size: CGSize(width: 640, height: 880)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("setup-install-confirm.png")) }
        m.cancelInstall()
        let button = try XCTUnwrap(SnapshotRenderer.render(view: SetupView(model: m, onClose: {}, onAddProject: {}), size: CGSize(width: 640, height: 1080)))
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try button.write(to: URL(fileURLWithPath: dir).appendingPathComponent("setup-install-button.png")) }
    }

    /// A 13" laptop window (~760 pt): the list scrolls and the sheet keeps Install/Cancel, Re-check and Close inside the window.
    func testSetupFitsASmallWindowWithTheButtonsReachable() async throws {
        let m = installModel(Machine(["claude"]), codex: true, installer: FakeInstaller())
        await m.check()
        m.requestInstall()
        let host = NSHostingView(rootView: SetupView(model: m, onClose: {}, onAddProject: {}).frame(maxHeight: 760))
        let fitted = host.fittingSize
        XCTAssertLessThanOrEqual(fitted.height, 760, "the sheet grows past the window instead of scrolling")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SetupView(model: m, onClose: {}, onAddProject: {}), size: CGSize(width: 640, height: 760)))
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("setup-install-small.png")) }
    }

    // MARK: Codex

    func testCodexLinesAreShownOnlyWhenSomeRoleUsesCodex() async {
        let calls = Calls()
        let without = await SetupCheck.run(inputs: inputs(), probes: probes(tools: ["claude", "jq"], calls: calls))
        XCTAssertNil(without.first { $0.id == .codex || $0.id == .codexSignIn })
        XCTAssertFalse(calls.commands.contains("codex login status"))
        XCTAssertFalse(SetupCheck.shouldOpen(without, seenBefore: true), "a missing codex does not matter when no role uses it")
    }

    func testCodexMissingIsRequiredAndSignInWaits() async throws {
        let items = await SetupCheck.run(inputs: inputs(codex: true), probes: probes(tools: ["claude", "jq"]))
        XCTAssertEqual(state(items, .codex), .missing)
        XCTAssertEqual(items.first { $0.id == .codex }?.fix, .copy(InstallPlan.codexCommand))
        XCTAssertEqual(state(items, .codexSignIn), .unsure)
        XCTAssertTrue(SetupCheck.shouldOpen(items, seenBefore: true))
    }

    func testCodexSignInAndTimeout() async {
        let out = await SetupCheck.run(inputs: inputs(codex: true), probes: probes(codexSignedIn: false))
        XCTAssertEqual(state(out, .codexSignIn), .missing)
        XCTAssertEqual(out.first { $0.id == .codexSignIn }?.fix, .signIn(.codex))
        XCTAssertTrue(SetupCheck.shouldOpen(out, seenBefore: true))
        let slow = await SetupCheck.run(inputs: inputs(codex: true), probes: probes(hang: ["codex"]), timeout: 0.1)
        XCTAssertEqual(state(slow, .codexSignIn), .unsure)
        XCTAssertTrue(slow.first { $0.id == .codexSignIn }!.detail.contains("did not answer"))
    }

    func testClaudeIsRequiredOnlyWhenSomeRoleUsesIt() async {
        let none = await SetupCheck.run(inputs: inputs(claude: false, codex: true), probes: probes(tools: ["jq", "codex"]))
        XCTAssertEqual(state(none, .claude), .missing)
        XCTAssertFalse(SetupCheck.shouldOpen(none, seenBefore: true))
        XCTAssertFalse(SetupModelProbe.hasMissingRequired(none))
        let used = await SetupCheck.run(inputs: inputs(), probes: probes(tools: ["jq"]))
        XCTAssertTrue(SetupCheck.shouldOpen(used, seenBefore: true))
    }

    private enum SetupModelProbe { static func hasMissingRequired(_ items: [SetupItem]) -> Bool { items.contains { $0.isRequired && $0.state == .missing } } }

    func testFindToolAndLoginStatusWithFakeBinariesOnATempPath() async throws {
        let bin = dir.url.appendingPathComponent("fakebin"), home = dir.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertNil(SetupCheck.findTool("codex", pathDirs: [bin.path], home: home.path))
        let local = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let fake = local.appendingPathComponent("codex")
        try "#!/bin/sh\n[ \"$1 $2\" = \"login status\" ] && exit 0\nexit 3\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let found = try XCTUnwrap(SetupCheck.findTool("codex", pathDirs: [bin.path], home: home.path))
        XCTAssertEqual(found.lastPathComponent, "codex")
        let live = SetupProbes.live()
        let signedIn = await live.codexSignedIn(found)
        XCTAssertEqual(signedIn, true)
        try "#!/bin/sh\necho 'Not logged in' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        let signedOut = await live.codexSignedIn(found)
        XCTAssertEqual(signedOut, false)
    }

    func testMissingToolsAreMissingWithACopyableCommand() async throws {
        let items = await SetupCheck.run(inputs: inputs(), probes: probes(tools: []))
        for id in [SetupItemID.claude, .jq] { XCTAssertEqual(state(items, id), .missing) }
        let jq = try XCTUnwrap(items.first { $0.id == .jq })
        XCTAssertEqual(jq.fix, .copy(InstallPlan.jqCommand()))
        XCTAssertEqual(state(items, .claudeSignIn), .unsure)
        XCTAssertTrue(SetupCheck.shouldOpen(items, seenBefore: true))
    }

    func testClaudeVersionFailureAndSignIn() async {
        let broken = await SetupCheck.run(inputs: inputs(), probes: probes(versionFails: true))
        XCTAssertEqual(state(broken, .claude), .unsure)
        let out = await SetupCheck.run(inputs: inputs(), probes: probes(signedIn: false))
        XCTAssertEqual(state(out, .claudeSignIn), .missing)
        XCTAssertEqual(out.first { $0.id == .claudeSignIn }?.fix, .signIn(.claude))
    }

    func testNoScriptsFolderNoProjectsMissingRolesUntrusted() async throws {
        let items = await SetupCheck.run(inputs: inputs(scripts: false, projects: []), probes: probes(roles: ["pm"]))
        XCTAssertEqual(state(items, .scripts), .missing)
        XCTAssertEqual(items.first { $0.id == .scripts }?.fix, .chooseScripts)
        XCTAssertEqual(state(items, .project), .missing)
        XCTAssertNil(items.first { $0.id == .project }?.fix, "adding a project needs the scripts folder first")
        XCTAssertEqual(state(items, .roles), .missing)
        XCTAssertEqual(items.first { $0.id == .roles }?.fix, .addRoles(["dev"]))
        XCTAssertEqual(state(items, .trust), .unsure)
        let withScripts = await SetupCheck.run(inputs: inputs(projects: []), probes: probes())
        XCTAssertEqual(withScripts.first { $0.id == .project }?.fix, .addProject)
        let untrusted = await SetupCheck.run(inputs: inputs(), probes: probes(trusted: false))
        XCTAssertEqual(state(untrusted, .trust), .missing)
        XCTAssertEqual(untrusted.first { $0.id == .trust }?.fix, .copy("bash /s/scripts/trust-folder.sh /repo/demo"))
    }

    func testAProbeThatDoesNotAnswerIsUnsureNotMissing() async {
        let started = Date()
        let items = await SetupCheck.run(inputs: inputs(), probes: probes(hang: ["claude", "terminal"]), timeout: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(state(items, .claude), .unsure)
        XCTAssertEqual(state(items, .terminalServer), .unsure)
        XCTAssertTrue(items.first { $0.id == .claude }!.detail.contains("did not answer"))
    }

    func testTheGuideOpensOnFirstLaunchAndWhenARequiredItemIsMissing() async {
        let ok = await SetupCheck.run(inputs: inputs(), probes: probes())
        XCTAssertTrue(SetupCheck.shouldOpen(ok, seenBefore: false))
        XCTAssertFalse(SetupCheck.shouldOpen(ok, seenBefore: true))
        let bad = await SetupCheck.run(inputs: inputs(), probes: probes(tools: ["claude"]))
        XCTAssertTrue(SetupCheck.shouldOpen(bad, seenBefore: true))
    }

    func testNoCheckRunsAPaidCallOrAnInstall() async {
        let calls = Calls()
        _ = await SetupCheck.run(inputs: inputs(), probes: probes(calls: calls))
        XCTAssertEqual(calls.commands, ["claude --version"])
        let withCodex = Calls()
        _ = await SetupCheck.run(inputs: inputs(codex: true), probes: probes(calls: withCodex))
        XCTAssertEqual(Set(withCodex.commands), ["claude --version", "codex login status"])
    }

    // MARK: scripts folder

    func testScriptsFolderValidation() throws {
        let good = try dir.write("good/spawn-agent.sh", "#!/bin/bash\n").deletingLastPathComponent()
        for name in ScriptName.allCases { try "#!/bin/bash\n".write(to: good.appendingPathComponent(name.rawValue), atomically: true, encoding: .utf8) }
        XCTAssertNil(SetupCheck.validateScripts(good))
        let bad = try dir.write("bad/readme.txt", "x").deletingLastPathComponent()
        let reason = try XCTUnwrap(SetupCheck.validateScripts(bad))
        XCTAssertTrue(reason.contains("spawn-agent.sh"), reason)
        XCTAssertNotNil(SetupCheck.validateScripts(dir.url.appendingPathComponent("nope")))
    }

    private struct Picker: FolderPicking { var path: String?; func chooseFolder(message: String) -> String? { path } }

    private func model(picker: String?, scripts: URL? = nil, seen: Bool = false, changed: @escaping @MainActor () -> Void = {}) -> (SetupModel, URL, UserDefaults) {
        let settings = dir.url.appendingPathComponent("cfg/projects.json")
        let defaults = makeTestDefaults(prefix: "setup")
        if seen { defaults.set(true, forKey: SetupModel.seenKey) }
        let m = SetupModel(probes: probes(), inputs: { SetupInputs(scriptsDir: scripts, scriptsProblem: nil, projects: [], usesClaude: true, usesCodex: false) }, settingsURL: settings,
                           picker: Picker(path: picker), roleBaseDir: dir.url.appendingPathComponent("roles"), defaults: defaults,
                           onSettingsChanged: changed)
        return (m, settings, defaults)
    }

    func testChoosingAGoodFolderWritesScriptsDirAndKeepsOtherKeys() async throws {
        let good = dir.url.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        for name in ScriptName.allCases { try "#!/bin/bash\n".write(to: good.appendingPathComponent(name.rawValue), atomically: true, encoding: .utf8) }
        var changed = 0
        let (m, settings, _) = model(picker: good.path, changed: { changed += 1 })
        try dir.write("cfg/projects.json", #"{"projects":["/p/project.json"]}"#)
        await m.chooseScripts()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(object["scriptsDir"] as? String, good.path)
        XCTAssertEqual(object["projects"] as? [String], ["/p/project.json"])
        XCTAssertEqual(changed, 1)
        XCTAssertNil(m.message)
    }

    func testChoosingAWrongFolderIsRefusedWithAReasonAndWritesNothing() async throws {
        let bad = try dir.write("bad/readme.txt", "x").deletingLastPathComponent()
        let (m, settings, _) = model(picker: bad.path)
        await m.chooseScripts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertTrue(m.message?.contains("spawn-agent.sh") == true, m.message ?? "nil")
    }

    func testAnUnreadableSettingsFileIsNeverOverwritten() throws {
        let file = try dir.write("cfg/projects.json", "not json")
        XCTAssertThrowsError(try SetupCheck.writeScriptsDir(URL(fileURLWithPath: "/x"), to: file))
        XCTAssertEqual(try String(contentsOf: file), "not json")
    }

    func testAddingTheRolesWritesDevAndPmFromTemplates() async throws {
        let (m, _, _) = model(picker: nil)
        await m.addRoles(["dev", "pm"])
        let store = RoleStore(baseDir: dir.url.appendingPathComponent("roles"))
        XCTAssertEqual(Set(store.baseRoles().roles.map(\.config.name)), ["dev", "pm"])
    }

    func testLaunchCheckOpensOnceThenOnlyWhenSomethingRequiredIsMissing() async {
        let (first, _, defaults) = model(picker: nil, seen: false)
        let opens = await first.checkOnLaunch()
        XCTAssertTrue(opens)   // first launch (even though the fake machine has nothing missing except scripts)
        first.markSeen()
        XCTAssertTrue(defaults.bool(forKey: SetupModel.seenKey))
    }

    // MARK: text and view

    func testEmptyTaskListPointsToAddProjectAndSetup() {
        XCTAssertTrue(emptyProjectsHint(setupMissing: false).contains("Add project"))
        XCTAssertFalse(emptyProjectsHint(setupMissing: false).contains("projects.json"))
        XCTAssertTrue(emptyProjectsHint(setupMissing: true).contains("Setup"))
    }

    func testSetupViewSnapshotWithMixedItems() async throws {
        let items = await SetupCheck.run(inputs: inputs(scripts: false, projects: []), probes: probes(tools: ["claude"], server: .notRunning("no such file"), roles: ["pm"]))
        let (m, _, _) = model(picker: nil)
        m.setItemsForPreview(items)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SetupView(model: m, onClose: {}, onAddProject: {}), size: CGSize(width: 640, height: 980)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: Claude golden (N367): written on main's behaviour before the change; must stay green.

    private func golden(_ items: [SetupItem]) -> [String] {
        items.map { "\($0.id.rawValue)|\($0.title)|\($0.state)|\($0.detail)|\(String(describing: $0.fix))|\($0.isRequired)" }
    }

    func testClaudeGoldenSignedInSetupIsUnchanged() async {
        let calls = Calls()
        let items = await SetupCheck.run(inputs: inputs(), probes: probes(calls: calls))
        XCTAssertEqual(golden(items), [
            "terminalServer|Terminal running|ok|Tentacl Crew's terminal (tentacld) answers. The agents run in it; no other terminal app is needed.|nil|true",
            "claude|claude installed|ok|claude is installed (/bin/claude).|nil|true",
            "claudeSignIn|Claude Code signed in|ok|`claude auth status` reports a login.|nil|true",
            "jq|jq installed|ok|jq is installed (/bin/jq).|nil|true",
            "scripts|Scripts folder set|ok|/s/scripts|nil|true",
            "project|At least one project|ok|Demo|nil|true",
            "roles|Shared dev and pm roles|ok|The shared library has dev and pm.|nil|true",
            "trust|Project folder trusted by Claude Code|ok|Every project folder is trusted.|nil|false",
            "github|GitHub: signed in|ok|kerhun on github.com. Tentacl Crew uses this login to create repositories and push.|nil|false",
        ])
        XCTAssertFalse(calls.commands.contains("codex login status"), "a Claude-only Setup never asks codex")
        XCTAssertTrue(InstallPlan.make(items).isEmpty)
    }

    func testClaudeGoldenClaudeLinesWhenNotSignedInOrMissing() async {
        let out = await SetupCheck.run(inputs: inputs(), probes: probes(signedIn: false))
        XCTAssertEqual(golden(out.filter { [.claude, .claudeSignIn].contains($0.id) }), [
            "claude|claude installed|ok|claude is installed (/bin/claude).|nil|true",
            "claudeSignIn|Claude Code signed in|missing|Claude Code is not signed in. Run claude auth login.|Optional(AgentPanel.SetupFix.signIn(AgentPanel.AgentTool.claude))|true",
        ])
        XCTAssertTrue(SetupCheck.shouldOpen(out, seenBefore: true))
        let none = await SetupCheck.run(inputs: inputs(), probes: probes(tools: ["jq"]))
        XCTAssertEqual(golden(none.filter { [.claude, .claudeSignIn].contains($0.id) }), [
            "claude|claude installed|missing|The claude command (Claude Code) is not installed.|Optional(AgentPanel.SetupFix.copy(\"\(InstallPlan.claudeCommand)\"))|true",
            "claudeSignIn|Claude Code signed in|unsure|Checked once claude is installed.|nil|true",
        ])
        XCTAssertEqual(InstallPlan.make(none).tools, ["claude"])
        XCTAssertTrue(SetupModel.blockingIDs.contains(.claude))
    }

    // MARK: N367 · both tools

    func testNeitherSignedInShowsBothWithSignInAndOneRequired() async {
        let items = await SetupCheck.run(inputs: inputs(), probes: probes(codexSignedIn: false, signedIn: false))
        XCTAssertEqual(items.first { $0.id == .claudeSignIn }?.fix, .signIn(.claude))
        XCTAssertEqual(items.first { $0.id == .codexSignIn }?.fix, .signIn(.codex))
        XCTAssertEqual(state(items, .codexSignIn), .missing)
        let required = items.filter { [.claudeSignIn, .codexSignIn].contains($0.id) && $0.isRequired }.map(\.id)
        XCTAssertEqual(required, [.claudeSignIn], "Claude is in use, Codex is offered as optional")
        XCTAssertTrue(SetupCheck.shouldOpen(items, seenBefore: true))
        XCTAssertTrue(InstallPlan.make(items).isEmpty)
        // codex missing while Claude cannot be used: shown, optional, never in the install plan, never blocks.
        let noCodex = await SetupCheck.run(inputs: inputs(), probes: probes(tools: ["claude", "jq"], signedIn: false))
        let codex = noCodex.first { $0.id == .codex }
        XCTAssertEqual(codex?.state, .missing); XCTAssertEqual(codex?.isRequired, false)
        XCTAssertTrue(codex?.detail.hasPrefix("Optional") == true)
        XCTAssertFalse(InstallPlan.make(noCodex).tools.contains("codex"))
    }

    func testOnlyCodexSignedInIsOK() async {
        let items = await SetupCheck.run(inputs: inputs(claude: false, codex: true), probes: probes(signedIn: false))
        XCTAssertEqual(state(items, .codexSignIn), .ok)
        XCTAssertEqual(state(items, .claudeSignIn), .missing)
        XCTAssertFalse(SetupCheck.shouldOpen(items, seenBefore: true))
        XCTAssertFalse(items.contains { $0.isRequired && $0.state == .missing })
    }

    func testProjectPMOnCodexWithCodexMissingIsRequired() async {
        let items = await SetupCheck.run(inputs: inputs(codex: true), probes: probes(tools: ["claude", "jq"]))
        let codex = items.first { $0.id == .codex }
        XCTAssertEqual(codex?.state, .missing); XCTAssertEqual(codex?.isRequired, true)
        XCTAssertTrue(SetupCheck.shouldOpen(items, seenBefore: true))
        XCTAssertEqual(InstallPlan.make(items).tools, ["codex"])
    }

    /// The real `claude auth status` / `codex login status` parsing, against fake binaries on a temp PATH.
    func testBothToolsWithFakeBinaries() async throws {
        let bin = dir.url.appendingPathComponent("fakebin"), home = dir.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func fake(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try fake("claude", #"[ "$1" = "--version" ] && { echo 2.0.0; exit 0; }; [ "$1 $2" = "auth status" ] && { echo '{"loggedIn":false}'; exit 1; }; exit 3"#)
        try fake("codex", #"[ "$1 $2" = "login status" ] && { echo 'Not logged in' >&2; exit 1; }; exit 3"#)
        try fake("jq", "exit 0")
        let live = SetupProbes.live()
        let probes = SetupProbes(findTool: { SetupCheck.findTool($0, pathDirs: [bin.path], home: home.path) }, claudeVersion: live.claudeVersion,
                                 terminalServer: { .running }, claudeSignedIn: live.claudeSignedIn, codexSignedIn: live.codexSignedIn,
                                 roleExists: { _ in true }, isTrusted: { _ in true }, github: { .signedOut })
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false { throw XCTSkip("an API key counts as signed in") }
        let items = await SetupCheck.run(inputs: inputs(), probes: probes)
        XCTAssertEqual(state(items, .claude), .ok); XCTAssertEqual(state(items, .codex), .ok)
        XCTAssertEqual(state(items, .claudeSignIn), .missing); XCTAssertEqual(state(items, .codexSignIn), .missing)
        XCTAssertEqual(items.filter { $0.fix == .signIn(.claude) || $0.fix == .signIn(.codex) }.count, 2)
        try fake("codex", #"[ "$1 $2" = "login status" ] && exit 0; exit 3"#)
        let codexOnly = await SetupCheck.run(inputs: inputs(claude: false, codex: true), probes: probes)
        XCTAssertEqual(state(codexOnly, .codexSignIn), .ok)
        XCTAssertFalse(SetupCheck.shouldOpen(codexOnly, seenBefore: true))
    }

    func testSetupOffersTheRulesOnlyWithCodexShown() async throws {
        let home = dir.url.appendingPathComponent("rules-home")
        try dir.write("rules-home/.claude/CLAUDE.md", "# Rules\n- wiki first\n")
        let rules = CodexRules(home: home)
        let m = SetupModel(probes: probes(codexSignedIn: false, signedIn: false), inputs: { [self] in inputs() }, settingsURL: dir.url.appendingPathComponent("cfg.json"),
                           picker: NoPicker(), roleBaseDir: dir.url.appendingPathComponent("roles"), defaults: makeTestDefaults(prefix: "n367"),
                           codexRules: rules, onSettingsChanged: {})
        await m.check()
        XCTAssertTrue(m.offersCodexRules)
        m.openRules()
        XCTAssertEqual(m.rulesFlow?.preview, rules.block)
        let claudeOnly = SetupModel(probes: probes(), inputs: { [self] in inputs() }, settingsURL: dir.url.appendingPathComponent("cfg.json"),
                                    picker: NoPicker(), defaults: makeTestDefaults(prefix: "n367"), codexRules: rules, onSettingsChanged: {})
        await claudeOnly.check()
        XCTAssertFalse(claudeOnly.offersCodexRules, "a signed-in Claude-only Setup shows no Codex offer")
    }

    private struct NoPicker: FolderPicking { func chooseFolder(message: String) -> String? { nil } }

    func testN367SetupSnapshot() async throws {
        let home = dir.url.appendingPathComponent("shot-home")
        try dir.write("shot-home/.claude/CLAUDE.md", "# Rules\n- wiki first\n")
        let m = SetupModel(probes: probes(codexSignedIn: false, signedIn: false), inputs: { [self] in inputs() }, settingsURL: dir.url.appendingPathComponent("cfg.json"),
                           picker: NoPicker(), defaults: makeTestDefaults(prefix: "n367"), codexRules: CodexRules(home: home), onSettingsChanged: {})
        await m.check()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SetupView(model: m, onClose: {}, onAddProject: {}), size: CGSize(width: 640, height: 880)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N367-setup.png")) }
    }
}
