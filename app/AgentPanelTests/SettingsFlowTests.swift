import XCTest
import SwiftUI
@testable import AgentPanel

@MainActor
final class SettingsFlowTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    /// Answers `git` by its arguments; records every command.
    private final class FakeGit: CommandRunner, @unchecked Sendable {
        var tags = "stable-1\nstable-2\nstable-10\n"
        var head = "abc1234\n"
        var headTags = "stable-2\n"
        private let lock = NSLock()
        private var recorded: [[String]] = []
        /// Locked: the `.task { load() }` of every view a snapshot test renders keeps running after the test, and calls this from several threads (N126).
        var calls: [[String]] { lock.withLock { recorded } }
        func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
            lock.withLock { recorded.append(arguments) }
            if arguments.contains("--list"), !arguments.contains("--points-at") { return Data(tags.utf8) }
            if arguments.contains("--points-at") { return Data(headTags.utf8) }
            if arguments.contains("rev-parse") { return Data(head.utf8) }
            return Data()
        }
    }

    private final class FakeRelease: @unchecked Sendable {
        var result = ScriptResult(status: 0, stdout: "stable is now abc1234", stderr: "")
        var calls: [(URL, [String])] = []
    }

    private final class FakeLauncher: @unchecked Sendable {
        var calls: [(URL, [String])] = []
        var fails = false
    }

    private func flow(scripts: Bool = true, git: FakeGit = FakeGit(), release: FakeRelease = FakeRelease(), problems: [String] = [], signing: Bool = false,
                      launcher: FakeLauncher = FakeLauncher(), relaunchScript: Bool = true, app: Bool = true) throws -> SettingsFlow {
        let scriptsDir = try dir.write("scripts/release-stable.sh", "#!/bin/bash\n").deletingLastPathComponent()
        if relaunchScript { _ = try dir.write("scripts/relaunch-app.sh", "#!/bin/bash\n") }
        let appURL = dir.url.appendingPathComponent("Applications/Tentacl.app")
        if app { try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true) }
        let settings = AppSettings(scriptsDir: scripts ? scriptsDir : nil, problems: problems)
        return SettingsFlow(settings: settings, settingsURL: URL(fileURLWithPath: "/home/u/.config/tentacl/projects.json"),
                            stableDir: URL(fileURLWithPath: "/home/u/stable"), signingConfigured: signing, git: git,
                            release: { url, args in release.calls.append((url, args)); return release.result },
                            appURL: appURL, processID: 4242,
                            launch: { url, args in launcher.calls.append((url, args)); if launcher.fails { throw CocoaError(.fileNoSuchFile) } },
                            extras: SettingsExtras(defaults: makeTestDefaults(prefix: "settings-flow-tests"), loginItem: FakeLoginItem(), toolProbe: { _ in nil }))
    }

    /// N279: the agent-question mode and the user's language are saved and found by search.
    func testSettingsFlowSavesTheQuestionModeAndLanguage() throws {
        let f = try flow()
        XCTAssertEqual(f.questionMode, .pmCritical)
        f.setQuestionMode(.user)
        XCTAssertEqual(f.questionMode, .user)
        f.setUserLanguage("Turkish")
        XCTAssertEqual(f.userLanguage, "Turkish")
        f.setUserLanguage("")
        XCTAssertEqual(f.userLanguage, QuestionSettings.systemLanguage)
        XCTAssertEqual(SettingsItem.matching("agent questions"), [.agentQuestions])
        XCTAssertEqual(SettingsItem.agentQuestions.category, .autopilot)
    }

    func testLoadListsTagsNewestFirstAndTheStableVersion() async throws {
        let f = try flow()
        await f.load()
        XCTAssertEqual(f.tags, ["stable-10", "stable-2", "stable-1"])
        XCTAssertEqual(f.stableVersion, "abc1234 · build 2")
        XCTAssertEqual(f.ref, "stable-10")
    }

    /// N302: the flow built before the settings were read lists the tags once they arrive.
    func testApplyingSettingsLaterListsTheTags() async throws {
        let f = try flow(scripts: false)
        await f.load()
        XCTAssertEqual(f.tags, [])
        let scriptsDir = dir.url.appendingPathComponent("scripts")
        f.apply(AppSettings(scriptsDir: scriptsDir, problems: []))
        await f.load()
        XCTAssertEqual(f.tags, ["stable-10", "stable-2", "stable-1"])
        XCTAssertEqual(f.ref, "stable-10")
    }

    func testTheFakeGitSurvivesLoadsFromSeveralThreads() async throws {
        let git = FakeGit()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 { group.addTask { _ = try? await git.run(URL(fileURLWithPath: "/usr/bin/git"), ["tag", "--list"]) } }
        }
        XCTAssertEqual(git.calls.count, 200)
    }

    /// N325: releases are named as versions, build tags as builds.
    func testTagAndVersionNames() {
        XCTAssertEqual(SettingsFlow.tagName("v1.0-beta.1"), "Tentacl Crew 1.0 Beta 1")
        XCTAssertEqual(SettingsFlow.tagName("v1.0"), "Tentacl Crew 1.0")
        XCTAssertEqual(SettingsFlow.tagName("stable-252"), "build 252")
        XCTAssertEqual(["stable-10", "v1.0-beta.1", "v1.0", "v1.0-beta.9", "stable-2", "v0.9"].sorted(by: SettingsFlow.isNewer),
                       ["v1.0", "v1.0-beta.9", "v1.0-beta.1", "v0.9", "stable-10", "stable-2"])
        XCTAssertEqual(SettingsExtras.versionName(short: "1.0", label: "Beta 1", build: "252"), "1.0 Beta 1 (build 252)")
        XCTAssertEqual(SettingsExtras.versionName(short: "1.0", label: nil, build: "252"), "1.0 (build 252)")
        XCTAssertEqual(SettingsExtras.versionName(short: "dev", label: nil, build: nil), "dev")
    }

    func testInstalledVersionPrefersTheReleaseTag() async throws {
        let git = FakeGit(); git.headTags = "stable-252\nv1.0-beta.1\n"
        let f = try flow(git: git); await f.load()
        XCTAssertEqual(f.stableVersion, "abc1234 · Tentacl Crew 1.0 Beta 1")
    }

    func testStableVersionWithoutATagOrCheckout() async throws {
        let git = FakeGit(); git.headTags = ""
        let f = try flow(git: git); await f.load()
        XCTAssertEqual(f.stableVersion, "abc1234")
        git.head = ""
        await f.load()
        XCTAssertNil(f.stableVersion)
    }

    func testTheConfirmationShowsTheExactCommand() async throws {
        let f = try flow(); await f.load()
        f.ref = "stable-2"
        f.requestUpdate()
        XCTAssertEqual(f.phase, .confirming)
        let script = try XCTUnwrap(f.scriptsDir).appendingPathComponent("release-stable.sh").path
        XCTAssertEqual(f.command, "bash \(script) stable-2 --set-scripts-dir /home/u/.config/tentacl/projects.json")
    }

    func testConfirmRunsTheScriptWithTheRefAndSettings() async throws {
        let release = FakeRelease()
        let f = try flow(release: release); await f.load()
        f.ref = "stable-2"; f.requestUpdate()
        await f.confirm()
        XCTAssertEqual(release.calls.count, 1)
        XCTAssertEqual(release.calls[0].0.lastPathComponent, "release-stable.sh")
        XCTAssertEqual(release.calls[0].1, ["stable-2", "--set-scripts-dir", "/home/u/.config/tentacl/projects.json"])
        XCTAssertEqual(f.phase, .done)
        XCTAssertTrue(f.message?.contains("Relaunch") ?? false)
    }

    func testRelaunchIsOfferedOnlyAfterASuccessfulUpdate() async throws {
        let f = try flow(); await f.load()
        XCTAssertFalse(f.canRelaunch)
        f.requestUpdate()
        XCTAssertFalse(f.canRelaunch)
        await f.confirm()
        XCTAssertEqual(f.phase, .done)
        XCTAssertTrue(f.canRelaunch)
        XCTAssertEqual(f.message, "Relaunch now to use it, or quit and reopen Tentacl Crew yourself.")

        let release = FakeRelease(); release.result = ScriptResult(status: 1, stdout: "", stderr: "nope")
        let failed = try flow(release: release); await failed.load()
        failed.requestUpdate(); await failed.confirm()
        XCTAssertFalse(failed.canRelaunch)
    }

    func testNoRelaunchWithoutTheScriptOrTheInstalledApp() async throws {
        for (script, app) in [(false, true), (true, false)] {
            dir = try TempDir()
            let f = try flow(relaunchScript: script, app: app); await f.load()
            f.requestUpdate(); await f.confirm()
            XCTAssertEqual(f.phase, .done)
            XCTAssertFalse(f.canRelaunch)
            XCTAssertEqual(f.message, "Quit and reopen Tentacl Crew to use it.")
        }
    }

    func testRelaunchClosesSheetsStartsTheScriptThenQuits() async throws {
        let launcher = FakeLauncher(); var order: [String] = []
        let f = try flow(launcher: launcher); await f.load()
        f.requestUpdate(); await f.confirm()
        f.relaunch(closeSheets: { order.append("close"); XCTAssertTrue(launcher.calls.isEmpty) }, quit: { order.append("quit"); XCTAssertEqual(launcher.calls.count, 1) })
        XCTAssertEqual(order, ["close", "quit"])
        XCTAssertEqual(launcher.calls[0].0.lastPathComponent, "relaunch-app.sh")
        XCTAssertEqual(launcher.calls[0].1, [dir.url.appendingPathComponent("Applications/Tentacl.app").path, "4242"])
    }

    func testRelaunchThatCannotStartDoesNotQuit() async throws {
        let launcher = FakeLauncher(); launcher.fails = true
        var quit = false
        let f = try flow(launcher: launcher); await f.load()
        f.requestUpdate(); await f.confirm()
        f.relaunch(closeSheets: {}, quit: { quit = true })
        XCTAssertFalse(quit)
        guard case .failed = f.phase else { return XCTFail("phase \(f.phase)") }
    }

    func testRelaunchBeforeAnUpdateDoesNothing() async throws {
        let launcher = FakeLauncher(); var quit = false
        let f = try flow(launcher: launcher); await f.load()
        f.relaunch(closeSheets: {}, quit: { quit = true })
        XCTAssertFalse(quit)
        XCTAssertTrue(launcher.calls.isEmpty)
    }

    func testAFailingScriptShowsItsError() async throws {
        let release = FakeRelease(); release.result = ScriptResult(status: 1, stdout: "", stderr: "building\nERROR: the build failed\n")
        let f = try flow(release: release); await f.load()
        f.requestUpdate(); await f.confirm()
        XCTAssertEqual(f.phase, .failed("ERROR: the build failed"))
    }

    func testNoRefMeansNoConfirmation() async throws {
        let git = FakeGit(); git.tags = ""
        let f = try flow(git: git); await f.load()
        XCTAssertNil(f.ref)
        XCTAssertEqual(f.refusal, "There is no release tag yet. Create one in the development repository (git tag v1.0-beta.1).")
        f.requestUpdate()
        XCTAssertEqual(f.phase, .idle)
    }

    func testARefThatIsNotATagIsRefused() async throws {
        let release = FakeRelease()
        let f = try flow(release: release); await f.load()
        f.ref = "main"; f.requestUpdate()
        XCTAssertEqual(f.phase, .idle)
        XCTAssertNotNil(f.refusal)
        await f.confirm()
        XCTAssertTrue(release.calls.isEmpty)
    }

    func testWithoutScriptsDirNothingRuns() async throws {
        let release = FakeRelease()
        let f = try flow(scripts: false, release: release, problems: ["scriptsDir must be an absolute path"]); await f.load()
        XCTAssertEqual(f.refusal, "scriptsDir is not set, so there is nothing to run.")
        f.requestUpdate(); await f.confirm()
        XCTAssertEqual(f.phase, .idle)
        XCTAssertTrue(release.calls.isEmpty)
        XCTAssertEqual(f.problems, ["scriptsDir must be an absolute path"])
    }

    func testCancelLeavesTheConfirmationWithoutRunning() async throws {
        let release = FakeRelease()
        let f = try flow(release: release); await f.load()
        f.requestUpdate(); f.cancel()
        XCTAssertEqual(f.phase, .idle)
        await f.confirm()
        XCTAssertTrue(release.calls.isEmpty)
    }

    func testSigningHint() throws {
        XCTAssertTrue(try flow(signing: false).signingHint.contains("ad hoc"))
        XCTAssertTrue(try flow(signing: true).signingHint.contains("keeps its identity"))
    }

    // MARK: N73 sections

    private final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
        var isEnabled = false
        var fails = false
        var calls: [Bool] = []
        func setEnabled(_ on: Bool) throws {
            calls.append(on)
            if fails { throw CocoaError(.fileWriteNoPermission) }
            isEnabled = on
        }
    }

    private func richFlow(login: FakeLoginItem = FakeLoginItem(), update: UpdateModel? = nil) throws -> (SettingsFlow, UserDefaults, AutopilotStore) {
        let defaults = makeTestDefaults(prefix: "settings-flow")
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        let scriptsDir = try dir.write("scripts/release-stable.sh", "#!/bin/bash\n").deletingLastPathComponent()
        let f = SettingsFlow(settings: AppSettings(scriptsDir: scriptsDir, problems: []), settingsURL: URL(fileURLWithPath: "/home/u/.config/tentacl/projects.json"),
                             stableDir: URL(fileURLWithPath: "/home/u/stable"), signingConfigured: true, git: FakeGit(),
                             release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") },
                             appURL: dir.url.appendingPathComponent("Tentacl.app"), processID: 1, launch: { _, _ in },
                             extras: SettingsExtras(defaults: defaults, loginItem: login, appVersion: "1.0 Beta 1 (build 268)", update: update, autopilotStore: store,
                                                    actionLogURL: dir.url.appendingPathComponent("actions.log"), rolesDir: dir.url.appendingPathComponent("roles"),
                                                    toolProbe: { name in InstalledTool(name: name, path: "/opt/homebrew/bin/\(name)", version: "2.1.0 (Claude Code)") }))
        return (f, defaults, store)
    }

    func testOpenAtLoginTogglesThroughTheService() throws {
        let login = FakeLoginItem()
        let (f, _, _) = try richFlow(login: login)
        XCTAssertFalse(f.openAtLogin)
        f.setOpenAtLogin(true)
        XCTAssertTrue(f.openAtLogin); XCTAssertEqual(login.calls, [true]); XCTAssertNil(f.loginError)
        f.setOpenAtLogin(false)
        XCTAssertFalse(f.openAtLogin); XCTAssertEqual(login.calls, [true, false])
        login.fails = true
        f.setOpenAtLogin(true)
        XCTAssertFalse(f.openAtLogin, "a refused change leaves the toggle as it was")
        XCTAssertNotNil(f.loginError)
    }

    private final class FakePower: PowerAssertions {
        var held = 0
        func create(kind: AssertionKind, reason: String) -> UInt32? { held += 1; return 7 }
        func release(_ id: UInt32) { held -= 1 }
    }

    @MainActor private final class FakeEnvironment: PowerEnvironment {
        var snapshot = PowerSnapshot(hasBattery: true, onBattery: false, percent: 90)
        func start(onChange: @escaping @MainActor () -> Void, willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {}
    }

    func testKeepAwakeSavesItsChoices() throws {
        let defaults = makeTestDefaults(prefix: "settings-flow")
        let g = SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: defaults)
        XCTAssertEqual(g.mode, .agents)
        g.mode = .always; g.keepDisplay = true; g.lidOnPower = false; g.warnOnBattery = false; g.stopBelowEnabled = true; g.stopBelowPercent = 30
        let again = SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: defaults)
        XCTAssertEqual([again.mode, again.keepDisplay, again.lidOnPower, again.warnOnBattery, again.stopBelowEnabled, again.stopBelowPercent] as [AnyHashable],
                       [KeepAwakeMode.always, true, false, false, true, 30] as [AnyHashable])
    }

    func testCaffeinateSwitchIsTheSleepGuardOfTheTopBar() throws {
        let defaults = makeTestDefaults(prefix: "settings-flow")
        defaults.set(false, forKey: SleepGuard.key)
        let power = FakePower()
        let guardModel = SleepGuard(power: power, environment: FakeEnvironment(), defaults: defaults)
        XCTAssertEqual(SettingsView.caffeinateStatus(guardModel.state), "Off")
        guardModel.isOn = true   // what the Settings switch does
        XCTAssertTrue(defaults.bool(forKey: SleepGuard.key))
        XCTAssertEqual(SettingsView.caffeinateStatus(guardModel.state), "On, no task is running")
        guardModel.update(running: true)
        XCTAssertEqual(SettingsView.caffeinateStatus(guardModel.state), "On, keeping the Mac awake now")
        XCTAssertEqual(power.held, 2, "idle-sleep and lid assertions on power")
        XCTAssertNil(defaults.object(forKey: "caffeinateOn"))
    }

    func testAutopilotDefaultsApplyToNewProjectsOnly() throws {
        let (f, _, store) = try richFlow()
        var existing = AutopilotPolicy(); existing.model = "haiku"
        try store.save(existing, for: "old")
        var d = AutopilotPolicy(); d.mode = .off; d.model = "sonnet"; d.budgetUSD = 1.5; d.dailyLimitUSD = 20
        f.saveAutopilotDefaults(d)
        let fresh = store.load("brand-new")
        XCTAssertEqual(fresh.mode, .off); XCTAssertEqual(fresh.model, "sonnet"); XCTAssertEqual(fresh.budgetUSD, 1.5); XCTAssertEqual(fresh.dailyLimitUSD, 20)
        XCTAssertEqual(store.load("old").model, "haiku")
        // On needs a confirmation per project, so it is never a default.
        d.mode = .on
        f.saveAutopilotDefaults(d)
        XCTAssertEqual(store.load("another").mode, .shadow)
    }

    func testDiagnosticsHaveVersionsAndPathsButNoSecrets() async throws {
        setenv("ANTHROPIC_API_KEY", "sk-ant-secret-value", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let (f, _, _) = try richFlow()
        await f.load()
        let text = f.diagnostics
        for expected in ["1.0 Beta 1 (build 268)", "terminal: Tentacl Crew (tentacld)", "/opt/homebrew/bin/claude", "2.1.0 (Claude Code)", "projects.json", "scripts", "stable"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in:\n\(text)")
        }
        XCTAssertFalse(text.contains("sk-ant"))
        XCTAssertFalse(text.lowercased().contains("api_key"))
        XCTAssertFalse(text.lowercased().contains("token"))
    }

    // MARK: the terminal

    private func diagnosticsFlow(settingsURL: URL) -> SettingsFlow {
        SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: settingsURL,
                     stableDir: URL(fileURLWithPath: "/home/u/stable"), signingConfigured: false, git: FakeGit(),
                     release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") },
                     appURL: dir.url.appendingPathComponent("Tentacl.app"), processID: 1, launch: { _, _ in },
                     extras: SettingsExtras(defaults: makeTestDefaults(prefix: "settings-terminal"), loginItem: FakeLoginItem(),
                                            toolProbe: { name in InstalledTool(name: name, path: "/opt/homebrew/bin/\(name)", version: "\(name) 1.0") }))
    }

    func testTheTerminalIsInTheDiagnosticsAndThereIsNoTerminalSetting() async throws {
        let f = diagnosticsFlow(settingsURL: dir.url.appendingPathComponent("p.json"))
        await f.load()
        XCTAssertTrue(f.diagnostics.contains("terminal: Tentacl Crew (tentacld)"), f.diagnostics)
        XCTAssertEqual(SettingsFlow.toolNames, ["claude"], "no terminal program is probed")
        XCTAssertFalse(SettingsItem.allCases.map(\.title).contains("Terminal"), "there is no backend picker")
    }

    func testTheNotificationsCategoryShowsSoundPickersAndDockSettings() async throws {
        let f = diagnosticsFlow(settingsURL: dir.url.appendingPathComponent("p.json"))
        await f.load(); f.show(.sound)
        var prefs = NotificationPrefs()
        prefs.sounds[.agentAsks] = .named("Glass"); prefs.sounds[.pmReply] = .silent
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: f, notificationsOn: true, notificationPrefs: prefs), size: CGSize(width: 900, height: 900)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N258-sounds.png")) }
    }

    /// N337: the update-available state of Settings → Version and updates (dark); source-build rows follow the scripts folder.
    func testGeneralShowsTheGitHubUpdateAndHidesSourceBuildWithoutScripts() async throws {
        XCTAssertFalse(try flow(scripts: false).hasSourceBuild); XCTAssertTrue(try flow().hasSourceBuild)
        let n = SnapshotNet()
        n.data = Data(###"[{"tag_name":"v1.0-beta.2","prerelease":true,"body":"## What's new\n- In-app updates from GitHub\n- Fewer notification sounds"}]"###.utf8)
        let defaults = makeTestDefaults(prefix: "settings-flow-update")
        let update = UpdateModel(ownTag: "v1.0-beta.1", defaults: defaults, get: { _ in n.data }, appFolder: dir.url, workFolder: dir.url, start: { _ in })
        await update.check()
        let f = SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: dir.url.appendingPathComponent("p.json"), stableDir: dir.url, signingConfigured: false,
                             git: FakeGit(), release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") }, appURL: dir.url, processID: 1, launch: { _, _ in },
                             extras: SettingsExtras(defaults: defaults, loginItem: FakeLoginItem(), update: update, toolProbe: { _ in nil }))
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: f, onCleanup: {}), size: CGSize(width: 900, height: 900)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N337-update.png")) }
    }

    private final class SnapshotNet: @unchecked Sendable { var data = Data() }

    func testTheAgentsCategoryRenders() async throws {
        let f = diagnosticsFlow(settingsURL: dir.url.appendingPathComponent("p.json"))
        await f.load(); f.show(.agents)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: f, onCleanup: {}), size: CGSize(width: 900, height: 640)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-agents.png")) }
    }

    func testThePMAndAutopilotCategoryRenders() async throws {
        let f = diagnosticsFlow(settingsURL: dir.url.appendingPathComponent("p.json"))
        await f.load(); f.show(.autopilot)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: f, onCleanup: {}), size: CGSize(width: 900, height: 640)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N279-settings.png")) }
    }

    // MARK: N111 categories

    func testCategoriesAreInTheAgreedOrder() {
        XCTAssertEqual(SettingsCategory.allCases.map(\.title), ["General", "Notifications", "Keep awake", "Usage", "PM & Autopilot", "Agents & Team", "Terminals", "Projects", "GitHub", "Advanced"])
        XCTAssertTrue(SettingsCategory.allCases.allSatisfy { !$0.explanation.isEmpty && !$0.symbol.isEmpty })
    }

    /// Every setting the one long page had, and the category it now lives in (the table in the N111 report).
    func testEveryOldSettingHasACategory() {
        let table: [(SettingsItem, SettingsCategory, Bool)] = [
            (.appearance, .general, false), (.tours, .general, false), (.openAtLogin, .general, false), (.version, .general, false), (.githubUpdate, .general, false), (.stableVersion, .general, false), (.updateStable, .general, false), (.signing, .general, true),
            (.notifications, .notifications, false), (.events, .notifications, false), (.sound, .notifications, false), (.dock, .notifications, false), (.questionPanel, .notifications, false),
            (.keepAwakeMode, .keepAwake, false), (.display, .keepAwake, false), (.battery, .keepAwake, false), (.lid, .keepAwake, true), (.safePoint, .usage, false), (.usageLimit, .usage, false),
            (.agentQuestions, .autopilot, false), (.userLanguage, .autopilot, false), (.autopilotMode, .autopilot, false), (.autopilotModel, .autopilot, false), (.perDecision, .autopilot, false), (.perDay, .autopilot, false), (.decisionLogs, .autopilot, true),
            (.team, .agents, false), (.sleep, .agents, false), (.cleanUp, .agents, false), (.sharedRoles, .agents, true),
            (.restoreHistory, .terminals, false), (.terminalHelper, .terminals, false),
            (.projects, .projects, false), (.addProject, .projects, false), (.githubAccount, .github, false),
            (.setupCheck, .advanced, false), (.scriptsFolder, .advanced, false), (.settingsFile, .advanced, false), (.actionLog, .advanced, false), (.tools, .advanced, false), (.diagnostics, .advanced, false),
        ]
        XCTAssertEqual(table.count, SettingsItem.allCases.count, "every item is in the table")
        for (item, category, advanced) in table {
            XCTAssertEqual(item.category, category, "\(item)")
            XCTAssertEqual(item.isAdvanced, advanced, "\(item)")
            XCTAssertFalse(item.title.isEmpty)
        }
        XCTAssertTrue(SettingsCategory.allCases.allSatisfy { !$0.items.isEmpty }, "no empty category")
    }

    func testSearchFindsSettingsByNameOrWhatTheyDo() {
        XCTAssertEqual(SettingsItem.matching("login"), [.openAtLogin])
        XCTAssertEqual(SettingsItem.matching("BATTERY"), [.battery])
        XCTAssertEqual(SettingsItem.matching("claude"), [.tools])
        XCTAssertEqual(SettingsItem.matching("lid closed"), [.lid])
        XCTAssertEqual(SettingsItem.matching("worktree"), [.cleanUp])
        XCTAssertTrue(SettingsItem.matching("budget").contains(.perDecision))
        XCTAssertTrue(SettingsItem.matching("autopilot").contains(.autopilotMode), "the category name matches too")
        for word in ["tour", "tutorial", "guide", "help"] { XCTAssertTrue(SettingsItem.matching(word).contains(.tours), word) }
        XCTAssertEqual(SettingsItem.matching("  "), [])
        XCTAssertEqual(SettingsItem.matching("no such setting"), [])
    }

    /// N267: the Usage limit, Safe point and Sleep groups are found by the words a user would try.
    func testSearchFindsUsageSafePointAndSleep() {
        for word in ["usage", "limit", "5h", "week"] {
            XCTAssertTrue(SettingsItem.matching(word).contains(.usageLimit), word)
        }
        XCTAssertTrue(SettingsItem.matching("safe point").contains(.safePoint))
        XCTAssertTrue(SettingsItem.matching("sleep").contains(.sleep))
        XCTAssertTrue(SettingsItem.matching("idle").contains(.sleep))
        XCTAssertEqual(SettingsItem.usageLimit.category.items, [.safePoint, .usageLimit])
        XCTAssertFalse(SettingsCategory.keepAwake.items.contains(.safePoint))
    }

    func testShowingAResultOpensItsCategoryAndItsAdvancedPart() throws {
        let (f, _, _) = try richFlow()
        f.show(.lid)
        XCTAssertEqual(f.category, .keepAwake); XCTAssertTrue(f.advancedOpen)
        f.show(.sound)
        XCTAssertEqual(f.category, .notifications); XCTAssertFalse(f.advancedOpen)
        f.advancedOpen = true
        f.show(.projects as SettingsCategory)
        XCTAssertEqual(f.category, .projects); XCTAssertFalse(f.advancedOpen, "another category starts with Advanced closed")
    }

    func testTheLastCategoryIsRemembered() throws {
        let (f, defaults, _) = try richFlow()
        XCTAssertEqual(f.category, .general, "General the first time")
        f.show(.agents as SettingsCategory)
        XCTAssertEqual(defaults.string(forKey: SettingsFlow.categoryKey), "agents")
        let again = SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: URL(fileURLWithPath: "/tmp/p.json"), stableDir: URL(fileURLWithPath: "/tmp/s"),
                                 signingConfigured: false, git: FakeGit(), release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") },
                                 appURL: URL(fileURLWithPath: "/tmp/T.app"), processID: 1, launch: { _, _ in },
                                 extras: SettingsExtras(defaults: defaults, loginItem: FakeLoginItem(), toolProbe: { _ in nil }))
        XCTAssertEqual(again.category, .agents)
        defaults.set("gone", forKey: SettingsFlow.categoryKey)
        let unknown = SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: URL(fileURLWithPath: "/tmp/p.json"), stableDir: URL(fileURLWithPath: "/tmp/s"),
                                   signingConfigured: false, git: FakeGit(), release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") },
                                   appURL: URL(fileURLWithPath: "/tmp/T.app"), processID: 1, launch: { _, _ in },
                                   extras: SettingsExtras(defaults: defaults, loginItem: FakeLoginItem(), toolProbe: { _ in nil }))
        XCTAssertEqual(unknown.category, .general)
    }

    func testEveryCategoryRendersWithSampleData() async throws {
        let (f, _, _) = try richFlow()
        await f.load()
        let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/Users/u/Documents/GitHub/demo", dataDir: "/Users/u/Documents/Demo-data", maxParallel: 2,
                                    buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
        let guardModel = SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: makeTestDefaults(prefix: "settings-view-tests"))
        for category in SettingsCategory.allCases {
            f.show(category); f.advancedOpen = true
            let view = SettingsView(flow: f, projects: [project, project], sleepGuard: guardModel, onCleanup: {}, notificationsOn: true, onAddProject: {})
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 900, height: 640)), "\(category)")
            XCTAssertGreaterThan(data.count, 20_000, "\(category)")
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(category.rawValue).png")) }
            if category == .usage, let path = ProcessInfo.processInfo.environment["AGENT_PANEL_USAGE_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
        }
    }

    func testSearchResultsRender() async throws {
        let (f, _, _) = try richFlow()
        await f.load()
        f.query = "battery"
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: f, notificationsOn: true), size: CGSize(width: 900, height: 640)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-search.png")) }
    }

    func testTheSettingsScreenRenders() async throws {
        let f = try flow(); await f.load()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: f, onCleanup: {}, notificationsOn: true), size: CGSize(width: 760, height: 520)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings.png")) }
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SETTINGS_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: N339 Settings v2

    private func sampleProject(_ name: String) -> ProjectConfig {
        ProjectConfig(id: name, name: name, repoPath: NSHomeDirectory() + "/Documents/GitHub/\(name)", dataDir: "/Users/u/Documents/\(name)-data", maxParallel: 2,
                      buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
    }

    /// N339: every setting has a row on its category page once search → show opened it (the Advanced part too).
    func testEverySettingHasAVisibleRowOnItsPage() async throws {
        let (f, _, _) = try richFlow()
        await f.load()
        let guardModel = SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: makeTestDefaults(prefix: "settings-v2-rows"))
        let tutorial = TutorialModel(store: TutorialStore(defaults: makeTestDefaults(prefix: "settings-v2-tours")), screen: .settings)
        for item in SettingsItem.allCases {
            f.query = item.title
            XCTAssertTrue(f.results.contains(item), "search finds \(item) by its title")
            f.show(item)
            XCTAssertEqual(f.category, item.category); XCTAssertEqual(f.advancedOpen, item.isAdvanced)
            var shown: Set<SettingsItem> = []
            let view = SettingsView(flow: f, projects: [sampleProject("demo")], sleepGuard: guardModel, onCleanup: {}, notificationsOn: true, onAddProject: {},
                                    onRowsShown: { shown = $0 })
                .environment(tutorial).environment(\.snapshotMode, true)
            let host = NSHostingView(rootView: view.frame(width: 1000, height: 2400))
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 2400)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(shown.contains(item), "\(item) has no row on \(item.category); shown: \(shown)")
            XCTAssertTrue(shown.allSatisfy { $0.category == item.category }, "\(item.category) shows rows of another page: \(shown)")
        }
    }

    /// Settings v2 snapshots (N339, data from N340): every category in dark, General and Notifications in light, General in Midnight (N340-<category>[-theme].png).
    /// N340: the status lines on the cards.
    func testStatusLines() async throws {
        XCTAssertEqual(SettingsFlow.cleanupHint(nil), "Agents and worktrees that outlived their card.")
        XCTAssertEqual(SettingsFlow.cleanupHint(0), "nothing to clean up")
        XCTAssertEqual(SettingsFlow.cleanupHint(2), "2 outlived their card")
        let (f, _, _) = try richFlow()
        var scans = 0
        await f.countLeftovers { scans += 1; return 3 }
        XCTAssertEqual(f.leftovers, 3); XCTAssertEqual(scans, 1)

        func item(_ id: SetupItemID, _ state: SetupState) -> SetupItem { SetupItem(id: id, title: id.rawValue, state: state, detail: "") }
        XCTAssertNil(SettingsFlow.setupSummary([]))
        let six: [SetupItemID] = [.terminalServer, .claude, .jq, .scripts, .project, .roles]
        XCTAssertEqual(SettingsFlow.setupSummary(six.map { item($0, .ok) })?.text, "All 6 in place")
        XCTAssertEqual(SettingsFlow.setupSummary(six.map { item($0, .ok) })?.ok, true)
        let two = six.enumerated().map { item($0.element, $0.offset < 2 ? .missing : .ok) }
        XCTAssertEqual(SettingsFlow.setupSummary(two)?.text, "2 missing"); XCTAssertEqual(SettingsFlow.setupSummary(two)?.ok, false)

        XCTAssertEqual(SettingsFlow.awakeLine(agents: 2, power: PowerSnapshot(hasBattery: true, onBattery: false, percent: 90)), "2 agents are working · on power adapter")
        XCTAssertEqual(SettingsFlow.awakeLine(agents: 1, power: PowerSnapshot(hasBattery: true, onBattery: true, percent: 64)), "1 agent is working · on battery 64%")
        XCTAssertEqual(SettingsFlow.awakeLine(agents: 0, power: PowerSnapshot(hasBattery: false, onBattery: false, percent: nil)), "No agent is working")
        XCTAssertEqual(SettingsFlow.splitVersion("1.0 Beta 1 (build 268)").name, "1.0 Beta 1")
        XCTAssertEqual(SettingsFlow.splitVersion("1.0 Beta 1 (build 268)").build, "268")
        XCTAssertNil(SettingsFlow.splitVersion("dev").build)
    }

    /// N340: the plan usage bar is green below the limit, `wait` within 10 points of it, `stop` at or above it; no data reads "unknown".
    func testUsageBarColourThresholds() {
        XCTAssertEqual(SettingsFlow.usageTone(percent: 42, limit: 90), .go)
        XCTAssertEqual(SettingsFlow.usageTone(percent: 79.9, limit: 90), .go)
        XCTAssertEqual(SettingsFlow.usageTone(percent: 80, limit: 90), .wait)
        XCTAssertEqual(SettingsFlow.usageTone(percent: 89, limit: 90), .wait)
        XCTAssertEqual(SettingsFlow.usageTone(percent: 90, limit: 90), .stop)
        XCTAssertEqual(SettingsFlow.usageTone(percent: 95, limit: nil), .wait)
        XCTAssertEqual(SettingsFlow.usageValue(percent: 42, limit: 90), "42% / 90%")
        XCTAssertEqual(SettingsFlow.usageValue(percent: 42, limit: nil), "42%")
        XCTAssertEqual(SettingsFlow.usageValue(percent: nil, limit: 90), "unknown")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // Friday 2027-01-15 08:00 UTC
        XCTAssertEqual(SettingsFlow.resetHint(now.addingTimeInterval(3600 + 2400), now: now, calendar: cal), "resets 09:40")
        XCTAssertEqual(SettingsFlow.resetHint(now.addingTimeInterval(86400 + 7200), now: now, calendar: cal), "resets Saturday 10:00")
    }

    func testSettingsV2Snapshots() async throws {
        defer { AppTheme.current = .dark }
        let n = SnapshotNet()
        n.data = Data(###"[{"tag_name":"v1.0-beta.2","prerelease":true,"body":"## What's new\n- In-app updates from GitHub\n- Fewer notification sounds"}]"###.utf8)
        let update = UpdateModel(ownTag: "v1.0-beta.1", defaults: makeTestDefaults(prefix: "settings-v2-update"), get: { _ in n.data }, appFolder: dir.url, workFolder: dir.url, start: { _ in })
        await update.check()
        let (f, _, _) = try richFlow(update: update)
        await f.load()
        let guardModel = SleepGuard(power: FakePower(), environment: FakeEnvironment(), defaults: makeTestDefaults(prefix: "settings-v2-shots"))
        guardModel.update(running: true, agents: 2)
        let tutorial = TutorialModel(store: TutorialStore(defaults: makeTestDefaults(prefix: "settings-v2-shot-tours")), screen: .settings)
        var prefs = NotificationPrefs()
        prefs.sounds[.agentAsks] = .named("Glass"); prefs.sounds[.pmReply] = .silent
        await f.countLeftovers { 2 }
        let setup = SetupModel(probes: .live(), inputs: { SetupInputs(scriptsDir: nil, scriptsProblem: nil, projects: []) }, settingsURL: dir.url.appendingPathComponent("none.json"),
                               picker: NoPicker(), roleBaseDir: dir.url, defaults: makeTestDefaults(prefix: "settings-v2-setup"), onSettingsChanged: {})
        setup.setItemsForPreview([SetupItemID.terminalServer, .claude, .jq, .scripts, .project, .roles].map { SetupItem(id: $0, title: $0.rawValue, state: .ok, detail: "") },
                                 checkedAt: Date().addingTimeInterval(-600))
        let now = Date()
        let usage = PlanUsage(fiveHour: .init(percent: 42, resetsAt: now.addingTimeInterval(2 * 3600)), week: .init(percent: 71, resetsAt: now.addingTimeInterval(3 * 86400)), todayCost: 0)
        var shots: [(SettingsCategory, AppTheme)] = SettingsCategory.allCases.map { ($0, .dark) }
        shots += [(.general, .light), (.notifications, .light), (.general, .midnight)]
        for (category, theme) in shots {
            AppTheme.current = theme
            f.show(category)
            let view = SettingsView(flow: f, projects: [sampleProject("agent-panel"), sampleProject("orchard")], sleepGuard: guardModel, onCleanup: {},
                                    notificationsOn: true, notificationPrefs: prefs, onAddProject: {},
                                    planUsage: usage, workingAgents: 2, setup: setup, leftoverScan: { 2 })
                .environment(tutorial).environment(\.colorScheme, theme == .light ? .light : .dark)
            let data = try XCTUnwrap(hostShot(view, size: CGSize(width: 1000, height: 900), dark: theme != .light), "\(category)")
            XCTAssertGreaterThan(data.count, 20_000, "\(category) \(theme)")
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                let name = "N340-\(category.rawValue)" + (theme == .dark ? "" : "-\(theme.rawValue)") + ".png"
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
            }
        }
    }

    private struct NoPicker: FolderPicking { func chooseFolder(message: String) -> String? { nil } }

    /// A PNG of the view in a real hosting view, so AppKit controls (switches, pop-ups, steppers) are drawn too; `ImageRenderer` leaves them out.
    private func hostShot<V: View>(_ view: V, size: CGSize, dark: Bool) -> Data? {
        let host = NSHostingView(rootView: view.environment(\.snapshotMode, true).frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func testTheConfirmationSheetRenders() async throws {
        let f = try flow(); await f.load(); f.requestUpdate()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: UpdateStableSheet(flow: f, onConfirm: {}, onCancel: {}), size: CGSize(width: 560, height: 360)))
        XCTAssertGreaterThan(data.count, 8_000)
    }

    func testRailLeavingTeamStillAsksFirstWhenGoingToSettings() {
        XCTAssertEqual(screenChange(from: .team, to: .settings, teamIsDirty: true), .askFirst)
        XCTAssertEqual(screenChange(from: .settings, to: .tasks, teamIsDirty: true), .go)
    }
}
