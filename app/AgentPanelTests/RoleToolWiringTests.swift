import XCTest
@testable import AgentPanel

@MainActor
final class RoleToolWiringTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func role(_ name: String, tool: String) -> String {
        """
        {"name":"\(name)","kind":"worker","tool":"\(tool)","model":"gpt-5","effort":"medium","permissionMode":"acceptEdits","outputStyle":"concise",
         "allowedTools":[],"skills":[],"instructionFile":"\(name).md"}
        """
    }

    private func panel(roles: [String: String], card role: String, agents: [AgentStatus] = []) throws -> PanelModel {
        for (name, tool) in roles { try dir.write("no-roles/\(name).json", self.role(name, tool: tool)) }
        try dir.write("data/tasks/N1.md", "---\nid: N1\nproject: demo\nstatus: doing\nagent: \(role)-n1\nbranch: task/n1\nroles: [\(role)]\nfiles:\n  - a\n---\n# N1 · Task\n")
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(agents)) }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        m.claudeProjectsRoot = dir.url.appendingPathComponent("claude-projects")
        m.codexSessionsRoot = dir.url.appendingPathComponent("codex-sessions")
        return m
    }

    private func agent(_ cwd: String = "/repo/.agent-worktrees/task-n1") -> AgentStatus {
        AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .idle, cwd: cwd, title: "x", sessionID: "sess-1")
    }

    private func codexSession(cwd: String) throws {
        let meta = #"{"type":"session_meta","timestamp":"2026-10-19T10:00:00.000Z","payload":{"id":"sess-1","cwd":"\#(cwd)"}}"#
        let reply = #"{"type":"response_item","timestamp":"2026-10-19T10:00:01.000Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex here"}]}}"#
        try dir.write("codex-sessions/2026/10/19/rollout-2026-10-19T10-00-00-sess-1.jsonl", meta + "\n" + reply + "\n")
    }

    func testARoleWithToolCodexGivesACodexAgent() async throws {
        let m = try panel(roles: ["cdev": "codex"], card: "cdev")
        await m.reload()
        XCTAssertEqual(m.tool(of: agent()), .codex)
        XCTAssertEqual(m.tool(ofRole: "cdev"), .codex)
        XCTAssertEqual(m.tool(ofRole: "pm"), .claude)
        XCTAssertEqual(m.tool(of: agent("/elsewhere")), .claude)
    }

    func testAClaudeRoleStaysClaude() async throws {
        let m = try panel(roles: ["dev": "claude"], card: "dev")
        await m.reload()
        XCTAssertEqual(m.tool(of: agent()), .claude)
        XCTAssertFalse(m.anyRoleUsesCodex)
    }

    func testAnyRoleUsesCodexCountsThePM() async throws {
        let m = try panel(roles: ["pm": "claude", "dev": "claude"], card: "dev")
        await m.reload()
        XCTAssertFalse(m.anyRoleUsesCodex)
        try dir.write("no-roles/pm.json", role("pm", tool: "codex"))
        XCTAssertTrue(m.anyRoleUsesCodex)
    }

    private func usage(_ percent: Double?) -> PlanUsage? {
        percent.map { PlanUsage(fiveHour: .init(percent: $0, resetsAt: Date().addingTimeInterval(5400)), week: nil, todayCost: 0) }
    }

    /// Both roles exist; Claude and Codex usage are as given (nil: no data). The safe point is the default 90%.
    private func safePointPanel(claude: Double?, codex: Double?) async throws -> PanelModel {
        let m = try panel(roles: ["dev": "claude", "cdev": "codex"], card: "dev")
        await m.reload()
        let c = usage(claude), x = usage(codex)
        m.usageSource = { c }
        m.codexUsageSource = { x }
        await m.refreshAgents()
        for _ in 0..<200 where m.planUsage?.fiveHour?.percent != claude || m.codexPlanUsage?.fiveHour?.percent != codex { try await Task.sleep(for: .milliseconds(5)) }
        return m
    }

    func testASafePointOnClaudeHoldsClaudeCardsNotCodexOnes() async throws {
        let m = try await safePointPanel(claude: 95, codex: 40)
        XCTAssertNotNil(m.safePointReason(forRole: "dev"))
        XCTAssertNil(m.safePointReason(forRole: "cdev"))
        XCTAssertNil(m.safePointReason, "without a card a Codex card could still start")
    }

    func testASafePointOnCodexHoldsCodexCardsNotClaudeOnes() async throws {
        let m = try await safePointPanel(claude: 40, codex: 93)
        XCTAssertNil(m.safePointReason(forRole: "dev"))
        XCTAssertTrue(try XCTUnwrap(m.safePointReason(forRole: "cdev")).contains("Codex 5-hour limit"))
    }

    func testNoCodexDataLeavesCodexCardsUnheldByTheClaudeWindow() async throws {
        let m = try await safePointPanel(claude: 95, codex: nil)
        XCTAssertNotNil(m.safePointReason(forRole: "dev"))
        XCTAssertNil(m.safePointReason(forRole: "cdev"))
    }

    func testBothToolsFullHoldEveryCard() async throws {
        let m = try await safePointPanel(claude: 95, codex: 95)
        XCTAssertNotNil(m.safePointReason(forRole: "dev"))
        XCTAssertNotNil(m.safePointReason(forRole: "cdev"))
        XCTAssertNotNil(m.safePointReason)
    }

    func testThePMLineGivesBothWindowsOnlyWhenCodexIsInUse() {
        let sp = SafePoint(percent: 90)
        XCTAssertEqual(sp.promptLine(usage(62), codex: usage(86))?.contains("Used now: Claude 62%, Codex 86%."), true)
        XCTAssertEqual(sp.promptLine(nil, codex: usage(86))?.contains("Used now: Claude unknown, Codex 86%."), true)
        XCTAssertEqual(sp.promptLine(usage(62))?.contains("Used now: 62%."), true)
    }

    func testSetupShowsCodexLinesOnlyWithACodexRole() async throws {
        let m = try panel(roles: ["dev": "claude"], card: "dev")
        await m.reload()
        XCTAssertFalse(m.setupInputs.usesCodex)
        try dir.write("no-roles/cdev.json", role("cdev", tool: "codex"))
        XCTAssertTrue(m.setupInputs.usesCodex)
        XCTAssertTrue(m.setupInputs.usesClaude, "a Claude role keeps Claude required")
    }

    func testACodexAgentsTurnIsReadFromItsCodexSession() async throws {
        let m = try panel(roles: ["cdev": "codex"], card: "cdev")
        await m.reload()
        try codexSession(cwd: "/repo/.agent-worktrees/task-n1")
        XCTAssertTrue(TurnTracker.transcriptHasReply(agent(), tool: m.tool(of: agent()), projectsRoot: m.claudeProjectsRoot, codexRoot: m.codexSessionsRoot))
        XCTAssertFalse(TurnTracker.transcriptHasReply(agent(), tool: .claude, projectsRoot: m.claudeProjectsRoot, codexRoot: m.codexSessionsRoot))
    }

    func testACodexCardsLastActionComesFromItsCodexSession() async throws {
        let m = try panel(roles: ["cdev": "codex"], card: "cdev", agents: [agent()])
        try codexSession(cwd: "/repo/.agent-worktrees/task-n1")
        await m.reload()
        m.noteAgentCards()
        XCTAssertEqual(m.lastActions["w1:p1|sess-1"], "codex here")
    }

    func testAnAgentOnNoCardGetsItsLineFromTheLiveMessageThenItsTranscript() async throws {
        let other = AgentStatus(paneID: "w1:p2", workspaceID: "w1", state: .working, cwd: "/work/demo", title: "x", sessionID: "sess-1")
        let m = try panel(roles: ["cdev": "codex"], card: "cdev", agents: [other])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let target = TranscriptReader.path(projectsRoot: m.claudeProjectsRoot, cwd: "/work/demo", session: "sess-1")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/transcripts/session.jsonl"), to: target)
        await m.reload()
        m.noteAgentCards()
        XCTAssertEqual(m.statusLine(other), "Done.")
        var live = other
        live.liveMessage = "Compiling"
        XCTAssertEqual(m.statusLine(live), "Compiling")
        XCTAssertEqual(m.statusLine(AgentStatus(paneID: "my-shell-1", workspaceID: "x", state: .idle, cwd: "/r", title: "t")), "")
    }

    func testTheChatReadsACodexSessionForACodexAgent() async throws {
        try codexSession(cwd: "/work/demo")
        let chat = ChatModel(projectsRoot: dir.url.appendingPathComponent("claude-projects"), codexRoot: dir.url.appendingPathComponent("codex-sessions"))
        await chat.refresh(agent: agent("/work/demo"), tool: .codex, viewing: true)
        XCTAssertEqual(chat.entries.last?.text, "codex here")
    }
}
