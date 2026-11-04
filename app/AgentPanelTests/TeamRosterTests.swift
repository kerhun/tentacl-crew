import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class TeamRosterTests: XCTestCase {
    private func role(_ name: String, source: RoleSource = .base, tool: String = "claude", model: String = "sonnet", effort: String = "medium",
                      mode: String = "acceptEdits", display: String? = nil) -> ResolvedRole {
        let config = RoleConfig(name: name, kind: "interactive", tool: tool, model: model, effort: effort, permissionMode: mode, outputStyle: "concise",
                                allowedTools: [], skills: [], instructionFile: "\(name).md", displayName: display)
        return ResolvedRole(config: config, fileURL: URL(fileURLWithPath: "/roles/\(source)/\(name).json"), source: source)
    }

    private func card(_ id: String, role: String? = "dev", status: TaskStatus = .done, title: String = "A task", branch: String? = nil) -> TaskCard {
        var c = TaskCard(id: id, project: "p", status: status, agent: nil, branch: branch, kind: nil, files: [], title: title, sections: [:],
                         url: URL(fileURLWithPath: "/cards/\(id).md"))
        c.roles = role.map { [$0] } ?? []
        return c
    }

    private let chart = TeamChart(members: [TeamMember(role: "pm", reportsTo: nil), TeamMember(role: "reviewer", reportsTo: "pm"),
                                            TeamMember(role: "dev", reportsTo: "reviewer"), TeamMember(role: "ui_dev", reportsTo: "reviewer")])

    private var standardRoles: [ResolvedRole] {
        [role("dev"), role("analyst", mode: "manual"), role("pm", model: "opus", effort: "high", mode: "manual", display: "Atlas"),
         role("reviewer", model: "opus", effort: "high", mode: "plan"), role("ui_dev", model: "opus")]
    }

    // MARK: cards

    func testRolesFollowTheChartThenTheRestByName() {
        let r = TeamRoster(base: standardRoles, project: [], projectName: "demo", chart: chart, cards: [], agents: [])
        XCTAssertEqual(r.cards.map(\.name), ["pm", "reviewer", "dev", "ui_dev", "analyst"])
        XCTAssertEqual(r.cards.map(\.tint), [0, 1, 2, 3, 4])
    }

    func testCardShowsNameInitialModelEffortStepsAndPermissionMeaning() throws {
        let r = TeamRoster(base: standardRoles, project: [], projectName: "demo", chart: chart, cards: [], agents: [])
        let pm = try XCTUnwrap(r.cards.first { $0.name == "pm" })
        XCTAssertEqual(pm.display, "Atlas")
        XCTAssertEqual(pm.initial, "A")
        XCTAssertEqual(pm.modelLabel, "Opus (latest)")
        XCTAssertEqual(pm.effort, "high")
        XCTAssertEqual(pm.effortStep, 3)
        XCTAssertEqual(pm.effortSteps, 5)
        XCTAssertEqual(pm.modeLabel, "Manual")
        XCTAssertEqual(pm.modeMeaning, TeamRoster.permissionMeaning(of: "manual", tool: "claude"))
        XCTAssertFalse(pm.isCodex)
        let dev = try XCTUnwrap(r.cards.first { $0.name == "dev" })
        XCTAssertEqual(dev.display, "dev")
        XCTAssertEqual(dev.initial, "D")
        XCTAssertEqual(dev.modeLabel, "Accept edits")
    }

    func testCodexRoleUsesTheCodexMeaningOfItsMode() throws {
        let r = TeamRoster(base: [role("dev", tool: "codex", model: "gpt-5.5", mode: "acceptEdits")], project: [], projectName: nil, chart: nil, cards: [], agents: [])
        let dev = try XCTUnwrap(r.cards.first)
        XCTAssertTrue(dev.isCodex)
        XCTAssertEqual(dev.modelLabel, "gpt-5.5")
        XCTAssertEqual(dev.modeMeaning, TeamModel.codexMeaning(of: "acceptEdits"))
    }

    func testEveryClaudeModeHasAMeaning() {
        for mode in RoleValidator.permissionModes { XCTAssertFalse(TeamRoster.permissionMeaning(of: mode, tool: "claude").isEmpty, mode) }
    }

    func testScopeSaysBaseOnlyInProjectOrOverrides() {
        let r = TeamRoster(base: [role("dev"), role("pm")], project: [role("dev", source: .project, model: "opus"), role("tester", source: .project), role("ops", source: .mapped)],
                           projectName: "demo", chart: nil, cards: [], agents: [])
        let scope = Dictionary(uniqueKeysWithValues: r.cards.map { ($0.name, $0.scope) })
        XCTAssertEqual(scope["pm"], "Base role")
        XCTAssertEqual(scope["dev"], "Only in demo · overrides the base role")
        XCTAssertEqual(scope["tester"], "Only in demo")
        XCTAssertEqual(scope["ops"], "From project.json (read-only)")
        XCTAssertEqual(r.cards.first { $0.name == "dev" }?.modelLabel, "Opus (latest)", "the project's role wins")
        XCTAssertEqual(r.cards.filter { $0.name == "dev" }.count, 1)
    }

    func testReportsToAndGivesTasksToComeFromTheChart() throws {
        let r = TeamRoster(base: standardRoles, project: [], projectName: "demo", chart: chart, cards: [], agents: [])
        let get = { (n: String) in r.cards.first { $0.name == n }! }
        XCTAssertEqual(get("pm").reportsTo, "You")
        XCTAssertEqual(get("pm").givesTasksTo, "reviewer, dev, ui_dev")
        XCTAssertEqual(get("reviewer").reportsTo, "pm")
        XCTAssertEqual(get("dev").givesTasksTo, "nobody")
        XCTAssertEqual(get("analyst").reportsTo, "Not in the chart")
        XCTAssertEqual(get("analyst").givesTasksTo, "nobody")
    }

    func testCardsDoneAndWaitingPerRole() throws {
        let cards = [card("N1"), card("N2"), card("N3", role: nil), card("N4", role: "ui_dev"), card("N5", status: .todo), card("N6", status: .awaitingStartApproval),
                     card("N7", status: .doing), card("N8", role: "ui_dev", status: .cancelled)]
        let r = TeamRoster(base: standardRoles, project: [], projectName: "demo", chart: chart, cards: cards, agents: [])
        let dev = try XCTUnwrap(r.cards.first { $0.name == "dev" })
        XCTAssertEqual(dev.done, 3, "a card without roles is the default role, dev")
        XCTAssertEqual(dev.waiting, 2)
        XCTAssertEqual(r.cards.first { $0.name == "ui_dev" }?.done, 1)
    }

    func testRunningAgentsGoUnderTheirRole() throws {
        let agents = [RosterAgent(role: "dev", cardID: "N7", title: "TentaclBackend", state: .working), RosterAgent(role: "pm", cardID: nil, title: "Project manager", state: .idle)]
        let r = TeamRoster(base: standardRoles, project: [], projectName: "demo", chart: chart, cards: [], agents: agents)
        XCTAssertEqual(r.cards.first { $0.name == "dev" }?.agents, [agents[0]])
        XCTAssertEqual(r.cards.first { $0.name == "pm" }?.agents, [agents[1]])
        XCTAssertEqual(r.cards.first { $0.name == "ui_dev" }?.agents, [])
    }

    // MARK: tiles

    func testAgentsRunningTileCountsByRoleInRosterOrder() {
        let agents = [RosterAgent(role: "dev", cardID: "N1", title: "a", state: .working), RosterAgent(role: "ui_dev", cardID: "N2", title: "b", state: .working),
                      RosterAgent(role: "dev", cardID: "N3", title: "c", state: .idle), RosterAgent(role: "pm", cardID: nil, title: "pm", state: .working)]
        let r = TeamRoster(base: standardRoles, project: [], projectName: "demo", chart: chart, cards: [], agents: agents)
        XCTAssertEqual(r.runningCount, 4)
        XCTAssertEqual(r.runningByRole, "pm · dev ×2 · ui_dev")
        XCTAssertEqual(TeamRoster(base: standardRoles, project: [], projectName: nil, chart: chart, cards: [], agents: []).runningByRole, "No agent running")
    }

    func testEnginesTileCountsClaudeAndCodexRoles() {
        let r = TeamRoster(base: [role("dev", tool: "codex", model: "gpt-5.5"), role("pm"), role("reviewer")], project: [], projectName: nil, chart: nil, cards: [], agents: [])
        XCTAssertEqual(r.claudeCount, 2)
        XCTAssertEqual(r.codexCount, 1)
    }

    func testCardsDoneTileSplitsByRoleLargestFirstWithTheRoleTint() {
        let cards = [card("N1"), card("N2"), card("N3", role: "ui_dev"), card("N4", role: "gone"), card("N5", status: .todo)]
        let r = TeamRoster(base: standardRoles, project: [], projectName: nil, chart: chart, cards: cards, agents: [])
        XCTAssertEqual(r.doneTotal, 4)
        XCTAssertEqual(r.doneSplit.map(\.role), ["dev", "gone", "ui_dev"])
        XCTAssertEqual(r.doneSplit.map(\.count), [2, 1, 1])
        XCTAssertEqual(r.doneSplit.map(\.tint), [2, nil, 3], "a role with no role file has no tint")
        XCTAssertEqual(r.doneLine, "dev 2 · gone 1 · ui_dev 1")
    }

    func testNeedsAttentionListsIdleChartRolesMissingRolesAndInvalidRoles() {
        let roles = [role("pm"), role("reviewer"), role("dev", model: " "), role("qa", tool: "gemini")]
        let withQA = TeamChart(members: chart.members + [TeamMember(role: "qa", reportsTo: "pm")])
        let r = TeamRoster(base: roles, project: [], projectName: nil, chart: withQA, cards: [card("N1", role: "qa", status: .todo), card("N2")], agents: [])
        XCTAssertEqual(r.attention, [
            "reviewer has no agent and gets no cards",
            "ui_dev is in the chart but has no role file",
            "dev: Model is missing (opus, sonnet, haiku, fable or a full model name).",
            "qa: Tool must be claude or codex.",
        ])
    }

    func testARoleWithARunningAgentOrACardNeedsNoAttentionAndThePMIsNeverIdle() {
        let r = TeamRoster(base: standardRoles, project: [], projectName: nil, chart: chart, cards: [card("N1", role: "ui_dev"), card("N2", status: .todo)],
                           agents: [RosterAgent(role: "reviewer", cardID: nil, title: "x", state: .working)])
        XCTAssertEqual(r.attention, [])
    }

    func testTitleAndSubtitle() {
        let r = TeamRoster(base: standardRoles, project: [], projectName: "agent-panel", chart: chart, cards: [], agents: [])
        XCTAssertEqual(r.title, "Team · agent-panel")
        XCTAssertEqual(r.subtitle, "5 roles. Base roles are shared by every project; a project can override one.")
        XCTAssertEqual(TeamRoster(base: [role("dev")], project: [], projectName: nil, chart: nil, cards: [], agents: []).title, "Team")
        XCTAssertEqual(TeamRoster(base: [role("dev")], project: [], projectName: nil, chart: nil, cards: [], agents: []).subtitle.hasPrefix("1 role."), true)
    }

    // MARK: helpers

    func testCopyNameIsFreeAndValid() {
        XCTAssertEqual(TeamRoster.copyName(of: "dev", taken: ["dev"]), "dev_copy")
        XCTAssertEqual(TeamRoster.copyName(of: "dev", taken: ["dev", "dev_copy", "dev_copy2"]), "dev_copy3")
        let long = TeamRoster.copyName(of: "security_reviewer", taken: [])
        XCTAssertTrue(RoleValidator.validName(long), long)
    }

    func testAgentsAreMatchedToTheCardTheyRunInAndThePM() {
        let worktrees = URL(fileURLWithPath: "/wt")
        let running = card("N7", role: "ui_dev", status: .doing, title: "Roster", branch: "task/n7")
        let finished = card("N8", status: .done, branch: "task/n8")
        let folder = worktrees.appendingPathComponent(StartTaskFlow.worktreeFolder(for: "task/n7")).path
        let a = AgentStatus(paneID: "1", workspaceID: "w", state: .working, cwd: folder, title: "")
        let b = AgentStatus(paneID: "2", workspaceID: "w", state: .idle, cwd: "/elsewhere", title: "")
        let pm = AgentStatus(paneID: "3", workspaceID: "w", state: .idle, cwd: "/repo", title: "")
        let out = TeamRoster.agents([a, b, pm], cards: [running, finished], worktrees: worktrees, pm: pm)
        XCTAssertEqual(out, [RosterAgent(role: "ui_dev", cardID: "N7", title: "Roster", state: .working, stage: .doing),
                             RosterAgent(role: "pm", cardID: nil, title: "Project manager", state: .idle)])
    }

    func testRowShowsTheCardStageNotDoneForAnUnmergedCard() {
        func row(_ st: TaskStatus, _ a: AgentState) -> RosterAgent { RosterAgent(role: "dev", cardID: "N1", title: "t", state: a, stage: st) }
        XCTAssertEqual(row(.review, .done).label, "in review")
        XCTAssertEqual(row(.needsFix, .working).label, "fixing")
        XCTAssertEqual(row(.needsFix, .done).label, "needs fix")
        XCTAssertEqual(row(.doing, .working).label, "working")
        XCTAssertEqual(row(.doing, .blocked).label, "blocked")
        XCTAssertNotEqual(RoleCardView.color(row(.review, .done)), RoleCardView.color(.done))
    }

    func testOnlyDoneCardsCountAsDone() {
        let c = [card("N1", status: .done), card("N2", status: .review), card("N3", status: .needsFix)]
        let r = TeamRoster(base: [], project: [], projectName: nil, chart: nil, cards: c, agents: [])
        XCTAssertEqual(r.doneTotal, 1)
    }

    // MARK: Team screen

    private func teamModel(_ dir: TempDir) throws -> TeamModel {
        func json(_ name: String, model: String = "sonnet", effort: String = "medium", mode: String = "acceptEdits", extra: String = "") -> String {
            "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"\(model)\",\"effort\":\"\(effort)\",\"permissionMode\":\"\(mode)\",\"outputStyle\":\"concise\",\"allowedTools\":[\"Read\"],\"skills\":[],\"instructionFile\":\"\(name).md\"\(extra)}"
        }
        try dir.write("base/pm.json", json("pm", model: "opus", effort: "high", mode: "manual", extra: ",\"displayName\":\"Atlas\""))
        try dir.write("base/reviewer.json", json("reviewer", model: "opus", effort: "high", mode: "plan", extra: ",\"displayName\":\"Umut\""))
        try dir.write("base/dev.json", json("dev", extra: ",\"displayName\":\"Ege\"")); try dir.write("base/dev.md", "You are a developer.")
        try dir.write("base/analyst.json", json("analyst", model: "opus", mode: "manual"))
        try dir.write("p/roles/ui_dev.json", json("ui_dev", model: "gpt-5.5", extra: ",\"tool\":\"codex\""))
        try dir.write("p/team.json", #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"reviewer","reportsTo":"pm"},{"role":"dev","reportsTo":"reviewer"},{"role":"ui_dev","reportsTo":"reviewer"}]}"#)
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"agent-panel\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let project = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
        let m = TeamModel(store: RoleStore(baseDir: dir.url.appendingPathComponent("base")), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("claude")),
                          claudeHome: dir.url.appendingPathComponent("claude"), makeScripts: { _ in nil }, project: project, codexCatalog: CodexModelCatalog(executable: nil))
        m.load(seed: false)
        return m
    }

    private var sampleCards: [TaskCard] {
        (1...12).map { card("N\($0)") } + (13...16).map { card("N\($0)", role: "ui_dev") } + [card("N17", role: "analyst"), card("N18", status: .todo), card("N19", role: "ui_dev", status: .todo),
         card("N20", status: .doing, title: "TentaclBackend"), card("N21", status: .doing, title: "Codex question detector"), card("N22", role: "ui_dev", status: .doing, title: "Add project form")]
    }

    private var sampleAgents: [RosterAgent] {
        [RosterAgent(role: "pm", cardID: nil, title: "Project manager", state: .working), RosterAgent(role: "dev", cardID: "N20", title: "TentaclBackend", state: .working, stage: .doing),
         RosterAgent(role: "dev", cardID: "N21", title: "Codex question detector", state: .done, stage: .review), RosterAgent(role: "ui_dev", cardID: "N22", title: "Add project form", state: .idle)]
    }

    private func png(_ view: some View, size: CGSize, name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, Int(size.width) * 2)
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
    }

    func testDuplicateCopiesTheRoleUnderAFreeNameInTheSamePlace() throws {
        let dir = try TempDir()
        let m = try teamModel(dir)
        let dev = try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" })
        let copy = m.duplicate(of: dev)
        XCTAssertEqual(copy.location, .base)
        XCTAssertEqual(copy.template.draft.name, "dev_copy")
        XCTAssertEqual(copy.template.draft.displayName, "")
        XCTAssertEqual(copy.template.draft.instructions, "You are a developer.")
        XCTAssertEqual(m.newRole(from: copy.template, in: copy.location), .switched)
        XCTAssertTrue(m.isNew)
        XCTAssertEqual(m.draft.model, "sonnet")
        let ui = try XCTUnwrap(m.groups[1].roles.first { $0.config.name == "ui_dev" })
        XCTAssertEqual(m.duplicate(of: ui).location, .project)
        XCTAssertEqual(m.duplicate(of: ui).template.draft.tool, "codex")
    }

    func testRosterIsTheFirstTabAndRenders() throws {
        let dir = try TempDir()
        let m = try teamModel(dir)
        XCTAssertEqual(TeamView.Section.allCases.first, .roster)
        let r = TeamRoster(base: m.groups[0].roles, project: m.groups[1].roles, projectName: m.project?.name, chart: m.chart.savedChart, cards: sampleCards, agents: sampleAgents)
        XCTAssertEqual(r.cards.map(\.name), ["pm", "reviewer", "dev", "ui_dev", "analyst"])
        XCTAssertEqual(r.attention, ["reviewer has no agent and gets no cards"])
        try png(TeamView(model: m, cards: sampleCards, agents: sampleAgents).frame(width: 1384, height: 1150), size: CGSize(width: 1384, height: 1150), name: "team-roster")
        let theme = AppTheme.current
        AppTheme.current = .light
        defer { AppTheme.current = theme }
        try png(TeamView(model: m, cards: sampleCards, agents: sampleAgents).frame(width: 1384, height: 1150), size: CGSize(width: 1384, height: 1150), name: "team-roster-light")
        AppTheme.current = theme
        try png(TeamView(model: m, cards: sampleCards, agents: sampleAgents).frame(width: 900, height: 1700), size: CGSize(width: 900, height: 1700), name: "team-roster-narrow")
    }

    func testEmptyRosterRenders() throws {
        let dir = try TempDir()
        let m = try teamModel(dir)
        try png(TeamView(model: m).frame(width: 1384, height: 1150), size: CGSize(width: 1384, height: 1150), name: "team-roster-empty")
    }

    func testDuplicatedRoleOpensInTheRolesTab() throws {
        let dir = try TempDir()
        let m = try teamModel(dir)
        let copy = m.duplicate(of: try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        m.newRole(from: copy.template, in: copy.location)
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 900), size: CGSize(width: 1384, height: 900), name: "team-roster-duplicate")
    }
}
