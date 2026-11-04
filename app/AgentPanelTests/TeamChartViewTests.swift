import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class TeamChartViewTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func roleJSON(_ name: String) -> String {
        "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"\(name).md\"}"
    }
    private let standard = #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"reviewer","reportsTo":"pm"},{"role":"dev","reportsTo":"reviewer"},{"role":"ui_dev","reportsTo":"reviewer"}]}"#

    private func team(chart: String?, roles: [String] = ["pm", "reviewer", "dev", "ui_dev", "analyst"]) throws -> TeamModel {
        for r in roles { try dir.write("base/\(r).json", roleJSON(r)) }
        if let chart { try dir.write("p/team.json", chart) }
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Orchard\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let p = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
        let m = TeamModel(store: RoleStore(baseDir: dir.url.appendingPathComponent("base")), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("c")),
                          claudeHome: dir.url.appendingPathComponent("c"), makeScripts: { _ in nil }, project: p)
        m.load(seed: false)
        return m
    }

    private func png(_ view: some View, size: CGSize, name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, Int(size.width) * 2)
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
    }

    private func card(_ id: String, roles: [String], agent: String? = nil, status: TaskStatus = .todo) -> TaskCard {
        var c = TaskCard(id: id, project: "demo", status: status, agent: agent, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        c.roles = roles
        return c
    }

    func testChartRendersAsATreeWithNotInChart() throws {
        let m = try team(chart: standard)
        m.chart.work = ChartWork(cards: [card("A", roles: ["dev"], agent: "dev-a", status: .doing), card("B", roles: ["ui_dev"], agent: "ui_dev-b", status: .doing), card("C", roles: ["pm"])])
        try png(ChartView(model: m.chart).frame(width: 1300, height: 760), size: CGSize(width: 1300, height: 760), name: "chart")
    }

    func testSelectedRoleShowsTheSidePanelWithAWarningAndItsFix() throws {
        let m = try team(chart: standard, roles: ["pm", "reviewer", "dev", "ui_dev"])
        m.chart.work = ChartWork(cards: [card("A", roles: ["dev"], agent: "dev-a", status: .doing), card("B", roles: ["ui_dev"]), card("C", roles: ["pm"])])
        m.chart.select("reviewer")
        XCTAssertFalse(m.chart.warnings(for: "reviewer").isEmpty)
        try png(ChartView(model: m.chart).frame(width: 1300, height: 760), size: CGSize(width: 1300, height: 760), name: "chart-selected")
    }

    func testARefusedDropShowsItsReason() throws {
        let m = try team(chart: standard)
        m.chart.select("pm")
        XCTAssertNotNil(m.chart.drop("pm", onto: "dev"))
        try png(ChartView(model: m.chart).frame(width: 1300, height: 760), size: CGSize(width: 1300, height: 760), name: "chart-drop-refused")
    }

    func testAWideChartRenders() throws {
        let m = try team(chart: #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"reviewer","reportsTo":"pm"},{"role":"analyst","reportsTo":"pm"},{"role":"dev","reportsTo":"reviewer"},{"role":"ui_dev","reportsTo":"reviewer"}]}"#)
        m.chart.select("dev")
        try png(ChartView(model: m.chart).frame(width: 1300, height: 760), size: CGSize(width: 1300, height: 760), name: "chart-wide")
    }

    func testChartRendersWhenThereIsNoChartAndWhenTheFileIsBroken() throws {
        try png(ChartView(model: try team(chart: nil).chart).frame(width: 1100, height: 420), size: CGSize(width: 1100, height: 420), name: "chart-none")
        dir = try TempDir()
        let broken = try team(chart: #"{"version":1,"members":[{"role":"a","reportsTo":"b"},{"role":"b","reportsTo":"a"}]}"#)
        try png(ChartView(model: broken.chart).frame(width: 1100, height: 420), size: CGSize(width: 1100, height: 420), name: "chart-broken")
    }

    func testTeamViewShowsTheChartSection() throws {
        let m = try team(chart: standard)
        try png(TeamView(model: m, initialSection: .chart).frame(width: 1384, height: 800), size: CGSize(width: 1384, height: 800), name: "team-chart")
    }

    func testTemplatePickerRendersAllTemplates() throws {
        try png(TemplatePickerView(templates: RoleTemplates.all, onPick: { _ in }, onCancel: {}).frame(width: 640, height: 560), size: CGSize(width: 640, height: 560), name: "templates")
    }

    // MARK: start sheet

    private func plan(_ authority: StartAuthority) throws -> StartPlan {
        let card = TaskCard(id: "T1", project: "demo", status: .todo, agent: nil, branch: "feat/t1", kind: nil, files: [], title: "Add c", sections: [:], url: URL(fileURLWithPath: "/tmp/T1.md"))
        var p = StartPlan(card: card, agentName: "dev-t1", branch: "feat/t1", rolePath: "/x", worktreePath: "/w", commandPreview: "spawn-agent.sh a b T1 feat/t1")
        p.authority = authority
        return p
    }

    func testStartConfirmStateByAuthority() throws {
        XCTAssertTrue(startConfirmState(plan: try plan(.notApplicable)) == (canStart: true, offersOverride: false))
        XCTAssertTrue(startConfirmState(plan: try plan(.allowed(from: "pm", to: "dev"))) == (canStart: true, offersOverride: false))
        XCTAssertTrue(startConfirmState(plan: try plan(.denied("x"))) == (canStart: false, offersOverride: true))
    }

    func testDeniedStartSheetRenders() throws {
        let p = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(try dir.write("p/project.json", "{\"id\":\"d\",\"name\":\"D\",\"repoPath\":\"/r\",\"dataDir\":\"/d\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}").path)\"]}")).projects.first)
        try dir.write("roles/dev.json", "{}")
        var pl = try plan(.denied("\"ui_dev\" is not above \"dev\" in the team chart (it reports to \"reviewer\")."))
        pl = StartPlan(card: pl.card, agentName: pl.agentName, branch: pl.branch, rolePath: dir.url.appendingPathComponent("roles/dev.json").path, worktreePath: pl.worktreePath, commandPreview: pl.commandPreview, authority: pl.authority)
        try png(StartTaskSheet(plan: pl, project: p, state: .idle, onConfirm: {}, onGiveMyself: {}, onCancel: {}), size: CGSize(width: 560, height: 640), name: "start-denied")
    }

    func testEachScreenAsksOneAlertQuestionAtATime() throws {
        XCTAssertNil(teamAlertKind(selection: false, newRole: false, delete: false))
        XCTAssertEqual(teamAlertKind(selection: false, newRole: false, delete: true), .deleteRole)
        XCTAssertEqual(teamAlertKind(selection: false, newRole: true, delete: false), .discardForNewRole)
        XCTAssertEqual(teamAlertKind(selection: true, newRole: false, delete: false), .discardForSelection)
        XCTAssertEqual(teamAlertKind(selection: true, newRole: true, delete: true), .deleteRole)
        XCTAssertNil(shellAlertKind(leavingTeam: false, switchingProject: false, closeTask: false))
        XCTAssertEqual(shellAlertKind(leavingTeam: true, switchingProject: false, closeTask: false), .leavingTeam)
        XCTAssertEqual(shellAlertKind(leavingTeam: false, switchingProject: true, closeTask: false), .switchingProject)
        XCTAssertEqual(shellAlertKind(leavingTeam: true, switchingProject: true, closeTask: true), .closeTask)
    }

    /// Stacked `.alert` modifiers on one view do not all appear (the Delete button did nothing); each view may have only one.
    func testNoViewStacksSeveralAlerts() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPanel/Views")
        for file in ["TeamView.swift", "ShellView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            XCTAssertLessThanOrEqual(source.components(separatedBy: ".alert(").count - 1, 1, "\(file) has more than one .alert(")
        }
    }

    func testDeleteAsksInlineInTheFormNotInAWindowAlert() async throws {
        let m = try team(chart: nil)
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "analyst" }))
        m.requestDelete()
        XCTAssertEqual(m.pendingDelete?.config.name, "analyst")
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 900), size: CGSize(width: 1384, height: 900), name: "team-delete-confirm")
        let teamSource = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPanel/Views/TeamView.swift"), encoding: .utf8)
        XCTAssertFalse(teamSource.contains("pendingDelete"), "the delete question is not a window alert")
        let formSource = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPanel/Views/RoleFormView.swift"), encoding: .utf8)
        XCTAssertTrue(formSource.contains("pendingDelete"))
        await m.confirmDelete()
        XCTAssertNil(m.pendingDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("base/analyst.json").path))
    }

    func testShellGuardsUseHasUnsavedChanges() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPanel/Views/ShellView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("hasUnsavedChanges"))
        XCTAssertFalse(source.contains("team.isDirty"), "the chart draft is unsaved work too")
        XCTAssertTrue(source.contains("revertAll"))
    }
}
