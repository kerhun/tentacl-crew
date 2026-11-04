import XCTest
@testable import AgentPanel

/// N366: the app follows the PM's tool (pm role `tool`); no `tool` / claude behaves as before.
@MainActor
final class PMToolTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    override func setUpWithError() throws { dir = try TempDir(); scripts = FakeScripts() }

    private func model(pmTool: String?, claudeIn: Bool? = true, codexIn: Bool? = true) async throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        let toolKey = pmTool.map { "\"tool\":\"\($0)\"," } ?? ""
        try dir.write("roles/pm.json", "{\"name\":\"pm\",\"kind\":\"interactive\",\(toolKey)\"model\":\"m\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"pm.md\"}")
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: todo\nagent:\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5 · Title\n")
        let project = try dir.write("p/demo.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":3,\"buildCommand\":\"b\",\"sharedFiles\":[],\"openWith\":\"Xcode\",\"roles\":{\"pm\":\"\(dir.url.appendingPathComponent("roles/pm.json").path)\"}}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let s = scripts!
        let gate = SignInGate(check: { $0 == .claude ? claudeIn : codexIn }, findTool: { URL(fileURLWithPath: "/fake/bin/\($0)") }, spawn: { _, _ in }, exitCode: { _ in 0 }, open: { _ in })
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success([])) }, opener: RecordingOpener(),
                           makeScripts: { _ in s }, log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                           defaults: makeTestDefaults(), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), signInGate: gate)
        m.usageSource = { nil }
        await m.reload()
        return m
    }

    private let pmAgent = AgentStatus(paneID: "w2:p1", workspaceID: "w2", state: .idle, cwd: "/repo", title: "pm-demo", sessionID: "pm-s", name: "pm-demo")

    // Claude golden: what main does today.
    func testClaudeDefaultAndExplicitClaudeUnchanged() async throws {
        for tool in [nil, "claude"] {
            let m = try await model(pmTool: tool)
            XCTAssertEqual(m.pmTool(of: "demo"), .claude)
            XCTAssertEqual(m.tool(ofRole: "pm"), .claude)
            XCTAssertEqual(m.tool(of: pmAgent), .claude)
            XCTAssertFalse(m.anyRoleUsesCodex)
            XCTAssertTrue(m.setupInputs.usesClaude)
            XCTAssertFalse(m.setupInputs.usesCodex)
            scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{}\n", stderr: "") }
            await m.spawnPM()
            guard case .done(let message) = m.actionState else { return XCTFail("\(m.actionState)") }
            XCTAssertEqual(message, "Started the PM.")
        }
    }

    func testClaudePMNotSignedInIsRefusedWithClaudeMessage() async throws {
        let m = try await model(pmTool: nil, claudeIn: false)
        await m.spawnPM()
        guard case .failed(let why) = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertTrue(why.contains("Claude"), why)
        XCTAssertEqual(scripts.calls(of: .spawn).count, 0)
    }

    func testCodexPMFollowsTheCodexTool() async throws {
        let m = try await model(pmTool: "codex")
        XCTAssertEqual(m.pmTool(of: "demo"), .codex)
        XCTAssertEqual(m.tool(ofRole: "pm"), .codex)
        XCTAssertEqual(m.tool(of: pmAgent), .codex)
        XCTAssertTrue(m.anyRoleUsesCodex)
        XCTAssertTrue(m.setupInputs.usesCodex)
        XCTAssertFalse(m.setupInputs.usesClaude, "no role uses Claude: it is optional (N378)")
    }

    func testCodexPMAsksTheCodexSignIn() async throws {
        let m = try await model(pmTool: "codex", claudeIn: true, codexIn: false)
        await m.spawnPM()
        guard case .failed(let why) = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertTrue(why.contains("Codex"), why)
        XCTAssertEqual(scripts.calls(of: .spawn).count, 0)
    }

    func testCodexPMStartsWithoutTheClaudeNote() async throws {
        let m = try await model(pmTool: "codex")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{}\n", stderr: "") }
        await m.spawnPM()
        guard case .done(let message) = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertEqual(message, "Started the PM.")
    }

    func testCodexPMResumeLooksInTheCodexSessions() async throws {
        let m = try await model(pmTool: "codex")
        m.codexSessionsRoot = dir.url.appendingPathComponent("codex")
        m.claudeProjectsRoot = dir.url.appendingPathComponent("claude")
        let meta = #"{"type":"session_meta","timestamp":"2026-10-19T10:00:00.000Z","payload":{"id":"cx-1","cwd":"/repo"}}"#
        try dir.write("codex/2026/10/19/rollout-2026-10-19T10-00-00-cx-1.jsonl", meta + "\n")
        XCTAssertEqual(m.pmResumeSession, "cx-1")
    }

    func testSafePointReachedFollowsThePMsTool() async throws {
        let hot = PlanUsage(fiveHour: .init(percent: 99, resetsAt: Date().addingTimeInterval(3600)), week: nil, todayCost: 0)
        for (tool, expected) in [("claude", true), ("codex", false)] {
            let m = try await model(pmTool: tool)
            m.usageSource = { hot }
            m.codexUsageSource = { nil }
            await m.refreshAgents()
            for _ in 0..<200 where m.planUsage == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(m.safePointReached, expected, tool)
        }
    }
}
