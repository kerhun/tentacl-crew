import XCTest
@testable import AgentPanel

@MainActor
final class RoleLabelTests: XCTestCase {
    private let worktrees = URL(fileURLWithPath: "/repo/.agent-worktrees")

    private func card(_ id: String, agent: String?, branch: String?) -> TaskCard {
        TaskCard(id: id, project: "demo", status: .doing, agent: agent, branch: branch, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func agent(_ cwd: String, title: String = "✳ Orchard task V1", pane: String = "w1:p1") -> AgentStatus {
        AgentStatus(paneID: pane, workspaceID: "w1", state: .working, cwd: cwd, title: title)
    }

    func testAgentWithADisplayNameIsLabelledByRoleAndTask() {
        let cards = [card("V1", agent: "dev-v1", branch: "test/v1")]
        XCTAssertEqual(agentLabel(agent: agent("/repo/.agent-worktrees/test-v1"), cards: cards, displayNames: ["dev": "Pixel"], projectWorktrees: worktrees), "Pixel · V1")
    }

    func testRoleWithoutADisplayNameKeepsTheCurrentLabel() {
        let cards = [card("V1", agent: "dev-v1", branch: "test/v1")]
        XCTAssertEqual(agentLabel(agent: agent("/repo/.agent-worktrees/test-v1"), cards: cards, displayNames: ["pm": "Atlas"], projectWorktrees: worktrees), "✳ Orchard task V1")
    }

    func testAnAgentWithoutACardKeepsTheCurrentLabel() {
        let pm = agent("/Users/me/project", title: "PM", pane: "w2:pA")
        XCTAssertEqual(agentLabel(agent: pm, cards: [card("V1", agent: "dev-v1", branch: "test/v1")], displayNames: ["dev": "Pixel", "pm": "Atlas"], projectWorktrees: worktrees), "PM")
        XCTAssertEqual(agentLabel(agent: agent("", title: "", pane: "w3:p1"), cards: [], displayNames: [:], projectWorktrees: worktrees), "w3:p1")
    }

    func testTwoAgentsOfTheSameRoleAreToldApartByTheirTasks() {
        let cards = [card("V1", agent: "dev-v1", branch: "test/v1"), card("V2", agent: "dev-v2", branch: "test/v2")]
        let names = ["dev": "Pixel"]
        XCTAssertEqual(agentLabel(agent: agent("/repo/.agent-worktrees/test-v1"), cards: cards, displayNames: names, projectWorktrees: worktrees), "Pixel · V1")
        XCTAssertEqual(agentLabel(agent: agent("/repo/.agent-worktrees/test-v2"), cards: cards, displayNames: names, projectWorktrees: worktrees), "Pixel · V2")
    }

    func testTheRoleIsTheTextBeforeTheFirstDash() {
        let cards = [card("V1", agent: "ui_dev-v1-extra", branch: "test/v1")]
        XCTAssertEqual(agentLabel(agent: agent("/repo/.agent-worktrees/test-v1"), cards: cards, displayNames: ["ui": "Wrong", "ui_dev": "Pixel"], projectWorktrees: worktrees), "Pixel · V1")
    }

    func testAnAgentInASubfolderOfItsWorktreeIsStillMatched() {
        let cards = [card("V1", agent: "dev-v1", branch: "test/v1")]
        XCTAssertEqual(agentLabel(agent: agent("/repo/.agent-worktrees/test-v1/Orchard"), cards: cards, displayNames: ["dev": "Pixel"], projectWorktrees: worktrees), "Pixel · V1")
    }

    func testAnotherWorktreeWithTheSamePrefixIsNotMatched() {
        let cards = [card("V1", agent: "dev-v1", branch: "test/v1")]
        XCTAssertEqual(agentLabel(agent: agent("/repo/.agent-worktrees/test-v10", title: "other"), cards: cards, displayNames: ["dev": "Pixel"], projectWorktrees: worktrees), "other")
    }

    func testCardAgentTitleShowsBothNames() {
        XCTAssertEqual(agentTitle(cardAgent: "dev-v1", displayNames: ["dev": "Pixel"]), "Pixel (dev-v1)")
        XCTAssertEqual(agentTitle(cardAgent: "dev-v1", displayNames: [:]), "dev-v1")
        XCTAssertEqual(agentTitle(cardAgent: "ghost-v1", displayNames: ["dev": "Pixel"]), "ghost-v1")
    }

    func testStartSheetShowsTheDisplayNameButThePlanKeepsTheTechnicalName() throws {
        let dir = try TempDir()
        let role = try dir.write("roles/dev.json", "{}")
        let plan = StartPlan(card: card("V1", agent: nil, branch: "test/v1"), agentName: "dev-v1", branch: "test/v1", rolePath: role.path, worktreePath: "/repo/.agent-worktrees/test-v1",
                             commandPreview: "spawn-agent.sh a b V1 test/v1", roleName: "dev", roleDisplayName: "Pixel")
        let project = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(try dir.write("p/project.json", "{\"id\":\"d\",\"name\":\"D\",\"repoPath\":\"/r\",\"dataDir\":\"/d\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}").path)\"]}")).projects.first)
        let fields = startSheetFields(plan: plan, project: project)
        XCTAssertEqual(fields.first { $0.label == "Agent" }?.value, "Pixel (dev-v1)")
        XCTAssertEqual(fields.first { $0.label == "Role" }?.value, "dev")
        XCTAssertEqual(plan.agentName, "dev-v1")
        XCTAssertFalse(plan.commandPreview.contains("Pixel"), "a display name never reaches a command")
    }

    func testPanelUsesTheTeamRolesForLabels() async throws {
        let dir = try TempDir()
        try dir.write("base/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\",\"displayName\":\"Pixel\"}")
        try dir.write("data/tasks/V1.md", "---\nid: V1\nproject: demo\nstatus: doing\nagent: dev-v1\nbranch: test/v1\nfiles:\n  - a\n---\n# V1\n")
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(),
                           log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")), defaults: makeTestDefaults(), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("base")))
        await m.reload()
        XCTAssertEqual(m.roleDisplayNames, ["dev": "Pixel"])
        XCTAssertEqual(m.agentLabel(AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .working, cwd: "/repo/.agent-worktrees/test-v1", title: "t")), "Pixel · V1")
    }
}
