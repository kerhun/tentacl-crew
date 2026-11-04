import SwiftUI
import XCTest
@testable import AgentPanel

/// N329: not signed in to Claude / Codex blocks the start and leads to sign-in.
@MainActor final class SignInGateTests: XCTestCase {
    private var keep: [TempDir] = []

    private final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    private func gate(claude: Bool? = false, codex: Bool? = true, exit: Int? = 0, log: Log = Log(), now: @escaping () -> Date = Date.init, opened: @escaping (String) -> Void = { _ in }) -> SignInGate {
        SignInGate(check: { tool in tool == .claude ? claude : codex },
                   findTool: { URL(fileURLWithPath: "/fake/bin/\($0)") },
                   spawn: { id, argv in log.add("\(id) \(argv.joined(separator: " "))") },
                   exitCode: { _ in exit }, open: opened, now: now)
    }

    func testClaudeAuthStatusAnswers() {
        XCTAssertEqual(SetupCheck.parseClaudeAuth(Data(#"{"loggedIn":true,"authMethod":"claude.ai"}"#.utf8)), true)
        XCTAssertEqual(SetupCheck.parseClaudeAuth(Data(#"{"loggedIn":false}"#.utf8)), false)
        XCTAssertNil(SetupCheck.parseClaudeAuth(Data("not json".utf8)))
        XCTAssertNil(SetupCheck.parseClaudeAuth(Data(#"{"other":1}"#.utf8)))
    }

    func testSetupItemsForClaudeAnswers() async {
        func claudeItem(_ answer: Bool?, hang: Bool = false) async -> SetupItem? {
            let base = SetupProbes.live()
            let probes = SetupProbes(findTool: { URL(fileURLWithPath: "/fake/bin/\($0)") }, claudeVersion: { _ in }, terminalServer: { .running },
                                     claudeSignedIn: { _ in if hang { try? await Task.sleep(nanoseconds: 5_000_000_000) }; return answer },
                                     codexSignedIn: { _ in true }, roleExists: { _ in true }, isTrusted: { _ in true }, github: base.github)
            let inputs = SetupInputs(scriptsDir: URL(fileURLWithPath: "/s"), scriptsProblem: nil, projects: [], usesClaude: true, usesCodex: false)
            return await SetupCheck.run(inputs: inputs, probes: probes, timeout: 0.3).first { $0.id == .claudeSignIn }
        }
        let ok = await claudeItem(true), missing = await claudeItem(false), garbage = await claudeItem(nil), timeout = await claudeItem(true, hang: true)
        XCTAssertEqual([ok?.state, missing?.state, garbage?.state, timeout?.state], [.ok, .missing, .unsure, .unsure])
        XCTAssertEqual(missing?.fix, .signIn(.claude))
    }

    func testOnlyNotSignedInBlocksAndCannotTellNever() async {
        let out = gate(claude: false), unsure = gate(claude: nil)
        let blocked = await out.ensure(.claude), free = await unsure.ensure(.claude)
        XCTAssertEqual(blocked, "Claude Code is not signed in.")
        XCTAssertNil(free)
        XCTAssertEqual(out.reason(for: .claude), "Claude Code is not signed in.")
        XCTAssertNil(out.reason(for: .codex), "the other tool is not blocked")
    }

    func testAnAnswerYoungerThan30SecondsIsNotAskedAgain() async {
        let asked = Log(); var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let g = SignInGate(check: { _ in asked.add("c"); return false }, findTool: { _ in nil }, spawn: { _, _ in }, exitCode: { _ in nil }, open: { _ in }, now: { clock })
        _ = await g.ensure(.claude); clock += 20; _ = await g.ensure(.claude)
        XCTAssertEqual(asked.all.count, 1)
        clock += 11; _ = await g.ensure(.claude)
        XCTAssertEqual(asked.all.count, 2)
    }

    func testSignInSpawnsTheLoginShowsTheTabAndAFreshCheckClearsTheReason() async {
        for (tool, line) in [(AgentTool.claude, "signin-claude /fake/bin/claude auth login"), (.codex, "signin-codex /fake/bin/codex login")] {
            let log = Log(); var opened: [String] = []
            var signed = false
            let g = SignInGate(check: { _ in signed }, findTool: { URL(fileURLWithPath: "/fake/bin/\($0)") },
                               spawn: { id, argv in log.add("\(id) \(argv.joined(separator: " "))") }, exitCode: { _ in 0 }, open: { opened.append($0) })
            _ = await g.refresh(tool)
            XCTAssertNotNil(g.reason(for: tool))
            signed = true
            await g.signIn(tool)
            XCTAssertEqual(log.all, [line])
            XCTAssertEqual(opened, [tool == .claude ? "signin-claude" : "signin-codex"])
            XCTAssertNil(g.reason(for: tool), "a successful exit checks again")
            XCTAssertNil(g.signingIn)
        }
    }

    func testThreeParallelEnsuresRunOneCheck() async {
        let asked = Log()
        let g = SignInGate(check: { _ in asked.add("c"); try? await Task.sleep(for: .milliseconds(100)); return false }, findTool: { _ in nil },
                           spawn: { _, _ in }, exitCode: { _ in nil }, open: { _ in })
        async let a = g.ensure(.claude), b = g.ensure(.claude), c = g.ensure(.claude)
        let all = await [a, b, c]
        XCTAssertEqual(all, Array(repeating: "Claude Code is not signed in.", count: 3))
        XCTAssertEqual(asked.all.count, 1)
    }

    func testTwoParallelStartsWithAStaleCheckStartOnce() async throws {
        let slow = SignInGate(check: { _ in try? await Task.sleep(for: .milliseconds(150)); return true }, findTool: { _ in nil },
                              spawn: { _, _ in }, exitCode: { _ in nil }, open: { _ in })
        let scripts = FakeScripts()
        let (m, iso) = try await model(claude: true, codex: true, gate: slow, scripts: scripts)
        try FileManager.default.createDirectory(at: iso.roleStore.baseDir, withIntermediateDirectories: true)
        try #"{"name":"dev","kind":"interactive","model":"sonnet","effort":"medium","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"dev.md"}"#
            .write(to: iso.roleStore.baseDir.appendingPathComponent("dev.json"), atomically: true, encoding: .utf8)
        let card = try XCTUnwrap(m.selectedTaskCards.first)
        guard case .success(let plan) = m.startPlan(for: card) else { return XCTFail("no plan") }
        async let first: Void = m.confirmStart(plan)
        async let second: Void = m.confirmStart(plan)
        _ = await (first, second)
        XCTAssertEqual(scripts.calls.filter { $0.script == .spawn }.count, 1, "\(m.actionState) the second click finds the panel busy and does nothing")
    }

    func testAFailedLoginKeepsTheReason() async {
        let g = gate(claude: false, exit: 1)
        _ = await g.refresh(.claude)
        await g.signIn(.claude)
        XCTAssertNotNil(g.reason(for: .claude))
    }

    func testTheStartGateIsPerToolOfTheRoleAndStartsStop() async throws {
        let (m, iso) = try await model(claude: false, codex: true)
        try FileManager.default.createDirectory(at: iso.roleStore.baseDir, withIntermediateDirectories: true)
        try #"{"name":"cx","kind":"interactive","tool":"codex","model":"gpt","effort":"medium","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"cx.md"}"#
            .write(to: iso.roleStore.baseDir.appendingPathComponent("cx.json"), atomically: true, encoding: .utf8)
        await m.refreshSignIn()
        XCTAssertEqual(m.signInReason(forRole: "dev"), "Claude Code is not signed in.")
        XCTAssertEqual(m.signInReason(forRole: "pm"), "Claude Code is not signed in.")
        XCTAssertNil(m.signInReason(forRole: "cx"), "a Codex role does not care about Claude")
        XCTAssertEqual(m.startDisabledReason, "Claude Code is not signed in.")
        XCTAssertFalse(m.canStart)
        let card = try XCTUnwrap(m.selectedTaskCards.first)
        XCTAssertEqual(m.startDisabledReason(for: card), "Claude Code is not signed in.")
        let plan = StartPlan(card: card, agentName: "dev-n1", branch: "task/n1", rolePath: "/r", worktreePath: "/w", commandPreview: "x")
        let failure = await m.startInRound(plan)
        XCTAssertEqual(failure, "Claude Code is not signed in.")
        await m.confirmStart(plan)
        XCTAssertEqual(m.actionState, .failed("Claude Code is not signed in."))
        await m.startPM()
        XCTAssertEqual(m.actionState, .failed("Claude Code is not signed in."))
    }

    func testTheReverseCodexSignedOutDoesNotBlockAClaudeRole() async throws {
        let (m, _) = try await model(claude: true, codex: false)
        await m.refreshSignIn()
        XCTAssertNil(m.signInReason(forRole: "dev"))
        XCTAssertTrue(m.canStart)
        XCTAssertNil(m.startDisabledReason)
    }

    func testPMBarLineHasTheSignInButtonAndGoesAfterSignIn() async throws {
        let (m, _) = try await model(claude: false, codex: true)
        await m.refreshSignIn()
        let block = PMStartBlock.make(setupReason: nil, signInReason: m.signInReason(forRole: "pm"), gateReason: nil, safePointReason: nil, busy: false)
        XCTAssertEqual(block, PMStartBlock(text: "Claude Code is not signed in.", signInTool: .claude))
        XCTAssertEqual(PMStartBlock.make(setupReason: "x", signInReason: "y", gateReason: nil, safePointReason: nil, busy: false)?.signInTool, nil, "the setup reason comes first")
        for (name, scheme) in [("", ColorScheme.light), ("-dark", ColorScheme.dark)] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: DashboardView(model: m).environment(\.colorScheme, scheme), size: CGSize(width: 1440, height: 900)))
            XCTAssertGreaterThan(data.count, 20_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N329-pm-bar-sign-in\(name).png")) }
        }
    }

    func testSetupSheetShowsTheSignInLine() throws {
        let m = SetupModel(probes: .live(), inputs: { SetupInputs(scriptsDir: nil, scriptsProblem: nil, projects: []) }, settingsURL: URL(fileURLWithPath: "/tmp/n329-none.json"),
                           picker: Picker(), roleBaseDir: URL(fileURLWithPath: "/tmp/n329-roles"), defaults: makeTestDefaults(prefix: "n329"), onSettingsChanged: {})
        m.setItemsForPreview([SetupItem(id: .claude, title: "claude installed", state: .ok, detail: "claude is installed (/usr/local/bin/claude)."),
                              SetupItem(id: .claudeSignIn, title: "Claude Code signed in", state: .missing, detail: "Claude Code is not signed in. Run claude auth login.", fix: .signIn(.claude))])
        for (name, scheme) in [("", ColorScheme.light), ("-dark", ColorScheme.dark)] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: SetupView(model: m, onClose: {}, onAddProject: {}).environment(\.colorScheme, scheme), size: CGSize(width: 640, height: 520)))
            XCTAssertGreaterThan(data.count, 8_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N329-setup-sign-in\(name).png")) }
        }
    }

    private struct Picker: FolderPicking { func chooseFolder(message: String) -> String? { nil } }

    private func model(claude: Bool?, codex: Bool?, gate custom: SignInGate? = nil, scripts: FakeScripts? = nil) async throws -> (PanelModel, TestIsolation) {
        let dir = try TempDir()
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("data/tasks/N1.md", "---\nid: N1\nproject: demo\nstatus: todo\nroles: [dev]\nfiles:\n  - a\n---\n# N1 · Task\n")
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let iso = TestIsolation(dir, owner: self)
        let fake = scripts ?? FakeScripts()
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success([])) }, opener: RecordingOpener(), makeScripts: { _ in fake }, log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore,
                           signInGate: custom ?? gate(claude: claude, codex: codex))
        m.usageSource = { nil } // never the machine's real usage: at ~99% it holds every start (usageHold)
        await m.reload()
        await m.refreshAgents()
        keep.append(dir)
        return (m, iso)
    }
}
