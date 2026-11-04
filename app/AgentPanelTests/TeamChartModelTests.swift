import XCTest
@testable import AgentPanel

@MainActor
final class TeamChartModelTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func roleJSON(_ name: String) -> String {
        "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"\(name).md\"}"
    }

    private func project(_ folder: String = "p", id: String = "demo") throws -> ProjectConfig {
        let source = try dir.write("\(folder)/project.json", "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("\(folder)-s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private let standard = #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"reviewer","reportsTo":"pm"},{"role":"dev","reportsTo":"reviewer"},{"role":"ui_dev","reportsTo":"reviewer"}]}"#

    private func chartModel(roles: [String] = ["pm", "reviewer", "dev", "ui_dev"], team: String? = nil) throws -> (TeamChartModel, ProjectConfig) {
        for r in roles { try dir.write("base/\(r).json", roleJSON(r)) }
        if let team { try dir.write("p/team.json", team) }
        let p = try project()
        let m = TeamChartModel(store: TeamChartStore(), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("base")))
        m.project = p
        m.reload()
        return (m, p)
    }

    func testRowsAreIndentedByDepthAndShowWhoTheyMayGiveTasksTo() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertEqual(m.rows.map(\.role), ["pm", "reviewer", "dev", "ui_dev"])
        XCTAssertEqual(m.rows.map(\.depth), [0, 1, 2, 2])
        XCTAssertEqual(m.rows[0].canGiveTasksTo, ["reviewer", "dev", "ui_dev"])
        XCTAssertEqual(m.rows[1].canGiveTasksTo, ["dev", "ui_dev"])
        XCTAssertEqual(m.rows[2].canGiveTasksTo, [])
        XCTAssertNil(m.rows[0].reportsTo)
        XCTAssertEqual(m.rows[2].reportsTo, "reviewer")
        XCTAssertFalse(m.isDirty)
    }

    func testAvailableManagersExcludeSelfAndDescendants() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertEqual(Set(m.availableManagers(for: "reviewer")), ["pm"], "not itself, not its own reports")
        XCTAssertEqual(Set(m.availableManagers(for: "dev")), ["pm", "reviewer", "ui_dev"])
        XCTAssertEqual(m.availableManagers(for: "pm"), [], "all of the top role's reports are below it, so none can be its manager")
    }

    func testSettingAManagerChangesTheTableAndMakesTheDraftDirty() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertTrue(m.setManager(of: "dev", to: "pm"))
        XCTAssertEqual(m.rows.first { $0.role == "dev" }?.depth, 1)
        XCTAssertTrue(m.isDirty)
        XCTAssertTrue(m.setManager(of: "dev", to: nil))
        XCTAssertEqual(m.rows.first { $0.role == "dev" }?.depth, 0)
    }

    func testSettingAManagerThatWouldCreateACycleIsRefused() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertFalse(m.setManager(of: "pm", to: "dev"))
        XCTAssertFalse(m.setManager(of: "reviewer", to: "reviewer"))
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(m.problems, [])
    }

    func testDevAbovePmIsAllowed() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertTrue(m.setManager(of: "pm", to: nil))   // already top
        XCTAssertTrue(m.setManager(of: "dev", to: nil))
        XCTAssertTrue(m.setManager(of: "pm", to: "dev"))
        XCTAssertEqual(m.rows.first { $0.role == "dev" }?.canGiveTasksTo.contains("pm"), true)
    }

    func testNotInChartListsResolvableRolesThatAreNotPlacedAndAddPlacesThem() throws {
        let (m, _) = try chartModel(roles: ["pm", "dev", "analyst"], team: #"{"version":1,"members":[{"role":"pm","reportsTo":null}]}"#)
        XCTAssertEqual(m.notInChart, ["analyst", "dev"])
        m.add("dev")
        XCTAssertEqual(m.notInChart, ["analyst"])
        XCTAssertEqual(m.rows.map(\.role), ["pm", "dev"])
        XCTAssertNil(m.rows.first { $0.role == "dev" }?.reportsTo, "a role that is added reports to you until you pick a manager")
        m.add("ghost")
        XCTAssertFalse(m.rows.contains { $0.role == "ghost" }, "only resolvable roles can be added")
    }

    func testAMemberWithoutARoleFileGetsAWarningRow() throws {
        let (m, _) = try chartModel(roles: ["pm"], team: #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"tester","reportsTo":"pm"}]}"#)
        XCTAssertEqual(m.rows.first { $0.role == "tester" }?.isMissingRole, true)
        XCTAssertEqual(m.rows.first { $0.role == "pm" }?.isMissingRole, false)
        XCTAssertEqual(m.problems, [], "a missing role file is a warning row, not a chart error")
    }

    func testCreateDefaultChartOnlyWhenThereIsNone() throws {
        let (m, _) = try chartModel()
        XCTAssertFalse(m.hasChart)
        m.createDefaultChart()
        XCTAssertTrue(m.hasChart)
        XCTAssertEqual(m.rows.map(\.role), ["pm", "reviewer", "dev", "ui_dev"])
        XCTAssertTrue(m.isDirty, "nothing is written until Save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("p/team.json").path))
    }

    func testCreateDefaultChartDoesNothingWhenAChartExists() throws {
        let (m, _) = try chartModel(team: standard)
        m.createDefaultChart()
        XCTAssertFalse(m.isDirty, "an existing chart is never replaced by the default one")
        XCTAssertEqual(m.rows.map(\.role), ["pm", "reviewer", "dev", "ui_dev"])
    }

    func testSaveWritesTheChartAndClearsDirty() async throws {
        let (m, _) = try chartModel()
        m.createDefaultChart()
        await m.save()
        XCTAssertNil(m.saveError)
        XCTAssertFalse(m.isDirty)
        guard case .valid(let onDisk) = TeamChartStore().load(for: try XCTUnwrap(m.project)) else { return XCTFail("valid file") }
        XCTAssertEqual(onDisk.members.map(\.role), ["pm", "reviewer", "dev", "ui_dev"])
    }

    func testSaveFailureKeepsTheDraft() async throws {
        let (m, _) = try chartModel(team: standard)
        m.setManager(of: "dev", to: "pm")
        let folder = dir.url.appendingPathComponent("p")
        // Read-only mode alone does not stop root or an ACL, so the folder is also made immutable and probed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555, .immutable: true], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertFalse(FileManager.default.createFile(atPath: folder.appendingPathComponent(".probe").path, contents: Data()), "the folder really refuses writes")
        await m.save()
        XCTAssertNotNil(m.saveError)
        XCTAssertTrue(m.isDirty)
        XCTAssertEqual(m.rows.first { $0.role == "dev" }?.depth, 1)
    }

    func testRevertRestoresTheSavedChart() throws {
        let (m, _) = try chartModel(team: standard)
        m.setManager(of: "dev", to: "pm"); m.add("analyst"); m.revert()
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(m.rows.map(\.role), ["pm", "reviewer", "dev", "ui_dev"])
    }

    func testInvalidFileOnDiskIsShownWithItsProblemsAndNothingIsOverwrittenUntilSaved() throws {
        let broken = #"{"version":1,"members":[{"role":"a","reportsTo":"b"},{"role":"b","reportsTo":"a"}]}"#
        let (m, _) = try chartModel(team: broken)
        XCTAssertFalse(m.hasChart)
        XCTAssertTrue(m.fileProblems.map(\.message).joined().contains("cycle"))
        XCTAssertEqual(try String(contentsOf: dir.url.appendingPathComponent("p/team.json"), encoding: .utf8), broken, "reading never rewrites the file")
        m.createDefaultChart()
        XCTAssertTrue(m.hasChart)
        XCTAssertEqual(try String(contentsOf: dir.url.appendingPathComponent("p/team.json"), encoding: .utf8), broken, "still untouched until Save")
    }

    func testSwitchingProjectReloadsTheChart() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertTrue(m.hasChart)
        m.project = try project("q", id: "other")
        m.reload()
        XCTAssertFalse(m.hasChart)
        XCTAssertEqual(m.rows, [])
    }

    // MARK: tree, drop, warnings (N176)

    private func card(_ id: String, roles: [String] = [], agent: String? = nil, status: TaskStatus = .todo) -> TaskCard {
        var c = TaskCard(id: id, project: "demo", status: status, agent: agent, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        c.roles = roles
        return c
    }

    func testTreeHasOneNodePerRoleWithNameModelAndRunningCount() throws {
        try dir.write("base/reviewer.json", #"{"name":"reviewer","displayName":"Umut","kind":"interactive","model":"opus","effort":"medium","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"reviewer.md"}"#)
        let (m, _) = try chartModel(roles: ["pm", "dev", "ui_dev"], team: standard)
        m.work = ChartWork(cards: [card("A", roles: ["dev"], agent: "dev-a", status: .doing), card("B", roles: ["dev"], agent: "dev-b", status: .doing),
                                   card("C", roles: ["dev"], agent: "dev-c", status: .done)])
        let tree = m.tree
        XCTAssertEqual(tree.map(\.role), ["pm"])
        XCTAssertEqual(tree[0].children.map(\.role), ["reviewer"])
        XCTAssertEqual(tree[0].children[0].children.map(\.role), ["dev", "ui_dev"])
        let reviewer = tree[0].children[0]
        XCTAssertEqual(reviewer.title, "Umut")
        XCTAssertEqual(reviewer.subtitle, "reviewer · opus · idle")
        XCTAssertEqual(reviewer.initial, "U")
        let dev = reviewer.children[0]
        XCTAssertEqual(dev.title, "dev", "no display name: the role name")
        XCTAssertEqual(dev.running, 2, "only cards in doing count")
        XCTAssertEqual(dev.subtitle, "dev · sonnet · 2 running")
    }

    func testSelectingANodeAndClearingItWhenTheRoleLeaves() throws {
        let (m, _) = try chartModel(team: standard)
        m.select("reviewer")
        XCTAssertEqual(m.selected, "reviewer")
        m.select("ghost")
        XCTAssertEqual(m.selected, "reviewer", "only a role in the chart can be selected")
        m.remove("reviewer")
        XCTAssertNil(m.selected)
    }

    func testDropMakesTheRoleReportToTheTarget() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertNil(m.drop("ui_dev", onto: "pm"))
        XCTAssertEqual(m.draft?.manager(of: "ui_dev"), "pm")
        XCTAssertNil(m.drop("ui_dev", onto: nil), "dropping on You makes it report to you")
        XCTAssertNil(m.draft?.manager(of: "ui_dev"))
        XCTAssertNil(m.dropRefusal)
        XCTAssertEqual(m.selected, "ui_dev", "the dropped role is selected")
    }

    func testADropThatWouldMakeALoopIsRefusedWithTheReason() throws {
        let (m, _) = try chartModel(team: standard)
        let reason = try XCTUnwrap(m.drop("reviewer", onto: "dev"))
        XCTAssertTrue(reason.contains("loop"), reason)
        XCTAssertTrue(reason.contains("dev") && reason.contains("reviewer"), reason)
        XCTAssertEqual(m.dropRefusal, reason)
        XCTAssertEqual(m.draft?.manager(of: "reviewer"), "pm", "nothing changed")
        XCTAssertFalse(m.isDirty)
        XCTAssertTrue(try XCTUnwrap(m.drop("dev", onto: "dev")).contains("itself"))
        XCTAssertNotNil(m.drop("dev", onto: "ghost"), "a role not in the chart is no target")
        XCTAssertNil(m.drop("dev", onto: "pm"))
        XCTAssertNil(m.dropRefusal, "a good drop clears the last refusal")
    }

    func testCanDropAgreesWithDrop() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertTrue(m.canDrop("dev", onto: "ui_dev"))
        XCTAssertTrue(m.canDrop("dev", onto: nil))
        XCTAssertFalse(m.canDrop("pm", onto: "reviewer"))
        XCTAssertFalse(m.canDrop("pm", onto: "pm"))
        XCTAssertFalse(m.isDirty, "asking changes nothing")
    }

    func testNoWarningsUntilTheCardsAreKnown() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertEqual(m.warnings(for: "reviewer"), [])
    }

    func testARoleWithReportsThatNoCardNamesGetsAWarningWithAMoveFix() throws {
        let (m, _) = try chartModel(team: standard)
        m.work = ChartWork(cards: [card("A", roles: ["dev"]), card("B", roles: ["ui_dev"]), card("C", agent: "pm-c")])
        XCTAssertEqual(m.warnings(for: "pm"), [], "a card whose agent is pm-… names pm")
        XCTAssertEqual(m.warnings(for: "dev"), [])
        let w = try XCTUnwrap(m.warnings(for: "reviewer").first)
        XCTAssertEqual(w.title, "No work yet")
        XCTAssertTrue(w.message.contains("No card names reviewer"), w.message)
        XCTAssertTrue(w.message.contains("dev and ui_dev"), w.message)
        XCTAssertEqual(w.fix, .moveReports(of: "reviewer", to: "pm"))
        XCTAssertEqual(w.fixLabel, "Move dev and ui_dev under pm")
        m.apply(try XCTUnwrap(w.fix))
        XCTAssertEqual(m.draft?.manager(of: "dev"), "pm")
        XCTAssertEqual(m.draft?.manager(of: "ui_dev"), "pm")
        XCTAssertEqual(m.draft?.member("reviewer")?.reportsTo, "pm", "the role itself stays")
        XCTAssertTrue(m.isDirty, "a fix is a draft edit, saved with Save chart")
    }

    func testACardWithoutRolesNamesDev() throws {
        let (m, _) = try chartModel(team: standard)
        m.work = ChartWork(cards: [card("A")])
        XCTAssertEqual(m.warnings(for: "dev"), [])
        XCTAssertFalse(m.warnings(for: "ui_dev").isEmpty)
    }

    func testALeafWithoutWorkAndATopRoleWithoutWorkGetTheRightFixes() throws {
        let (m, _) = try chartModel(team: standard)
        m.work = ChartWork(cards: [card("A", roles: ["reviewer"]), card("B", roles: ["dev"])])
        let leaf = try XCTUnwrap(m.warnings(for: "ui_dev").first)
        XCTAssertEqual(leaf.fix, .remove("ui_dev"))
        XCTAssertEqual(leaf.fixLabel, "Take ui_dev out of the chart")
        m.apply(try XCTUnwrap(leaf.fix))
        XCTAssertNil(m.draft?.member("ui_dev"))
        XCTAssertEqual(m.notInChart.contains("ui_dev"), true, "it goes back to the Not in the chart strip")
        let top = try XCTUnwrap(m.warnings(for: "pm").first)
        XCTAssertEqual(top.fix, .moveReports(of: "pm", to: nil))
        XCTAssertEqual(top.fixLabel, "Move reviewer under you")
    }

    func testAMissingRoleFileIsAWarningWithARemoveFix() throws {
        let (m, _) = try chartModel(roles: ["pm"], team: #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"tester","reportsTo":"pm"}]}"#)
        let w = try XCTUnwrap(m.warnings(for: "tester").first)
        XCTAssertEqual(w.title, "No role file")
        XCTAssertEqual(w.fix, .remove("tester"))
        XCTAssertEqual(m.allWarnings.map(\.role), ["tester"])
    }

    func testSidePanelTextsForTheSelectedRole() throws {
        let (m, _) = try chartModel(team: standard)
        XCTAssertEqual(m.reportsGoTo("reviewer"), "pm, in the Report of each card")
        XCTAssertEqual(m.reportsGoTo("pm"), "you, in the Report of each card")
        XCTAssertEqual(m.draft?.descendants(of: "reviewer"), ["dev", "ui_dev"])
    }

    func testTheRunningAgentsNoteIsPresent() {
        XCTAssertTrue(TeamChartModel.runningAgentsNote.contains("already running"))
    }

    // MARK: in the team model

    private func teamModel(team: String?) throws -> TeamModel {
        for r in ["pm", "reviewer", "dev", "ui_dev"] { try dir.write("base/\(r).json", roleJSON(r)) }
        if let team { try dir.write("p/team.json", team) }
        let m = TeamModel(store: RoleStore(baseDir: dir.url.appendingPathComponent("base")), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("c")),
                          claudeHome: dir.url.appendingPathComponent("c"), makeScripts: { _ in nil }, project: try project())
        m.load(seed: false)
        return m
    }

    func testHasUnsavedChangesCoversRoleDraftAndChartDraft() throws {
        let m = try teamModel(team: standard)
        XCTAssertFalse(m.hasUnsavedChanges)
        m.chart.setManager(of: "dev", to: "pm")
        XCTAssertTrue(m.hasUnsavedChanges)
        m.revertAll()
        XCTAssertFalse(m.hasUnsavedChanges)
        _ = m.select(m.groups[0].roles[0]); m.draft.model = "opus"
        XCTAssertTrue(m.hasUnsavedChanges)
        m.revertAll()
        XCTAssertFalse(m.hasUnsavedChanges)
    }

    func testDeletingARoleThatIsInTheChartAsksAndRewiresBothTogether() async throws {
        let m = try teamModel(team: standard)
        let reviewer = try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "reviewer" })
        _ = m.select(reviewer)
        m.requestDelete()
        XCTAssertTrue(m.pendingDeleteWarning?.contains("team chart") == true, "the confirmation says the role is in the chart")
        await m.confirmDelete()
        XCTAssertNil(m.saveError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("base/reviewer.json").path))
        guard case .valid(let chart) = TeamChartStore().load(for: try XCTUnwrap(m.project)) else { return XCTFail("valid chart") }
        XCTAssertEqual(chart.members.map(\.role), ["pm", "dev", "ui_dev"])
        XCTAssertEqual(chart.manager(of: "dev"), "pm", "its reports moved up to its manager")
        XCTAssertEqual(m.chart.rows.map(\.role), ["pm", "dev", "ui_dev"])
    }

    func testIfTheChartCannotBeWrittenTheRoleIsNotDeleted() async throws {
        let m = try teamModel(team: standard)
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "reviewer" }))
        m.requestDelete()
        let folder = dir.url.appendingPathComponent("p")
        // Read-only mode alone is not a guarantee (it does not stop root or an ACL), so the folder is also made immutable.
        try FileManager.default.setAttributes([.posixPermissions: 0o555, .immutable: true], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertFalse(FileManager.default.createFile(atPath: folder.appendingPathComponent(".probe").path, contents: Data()), "the folder really refuses writes")
        await m.confirmDelete()
        XCTAssertNotNil(m.saveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("base/reviewer.json").path), "the role file is still there")
    }

    func testDeletingARoleThatIsNotInTheChartLeavesTheChartAlone() async throws {
        let m = try teamModel(team: #"{"version":1,"members":[{"role":"pm","reportsTo":null}]}"#)
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        m.requestDelete()
        XCTAssertNil(m.pendingDeleteWarning)
        let before = try String(contentsOf: dir.url.appendingPathComponent("p/team.json"), encoding: .utf8)
        await m.confirmDelete()
        XCTAssertEqual(try String(contentsOf: dir.url.appendingPathComponent("p/team.json"), encoding: .utf8), before)
    }

    func testSavingARoleKeepsUnsavedChartEdits() async throws {
        let m = try teamModel(team: standard)
        m.chart.setManager(of: "dev", to: "pm")
        _ = m.select(m.groups[0].roles[0]); m.draft.model = "opus"
        await m.save()
        XCTAssertTrue(m.chart.isDirty, "the chart edit is still there")
        XCTAssertEqual(m.chart.rows.first { $0.role == "dev" }?.depth, 1)
    }

    func testDeleteIsRefusedWhileTheChartHasUnsavedEdits() async throws {
        let m = try teamModel(team: standard)
        m.chart.setManager(of: "dev", to: "pm")
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "reviewer" }))
        m.requestDelete()
        await m.confirmDelete()
        XCTAssertNotNil(m.saveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("base/reviewer.json").path))
        XCTAssertTrue(m.chart.isDirty, "the chart edit is kept")
    }

    func testDeletingAProjectRoleThatShadowsASharedOneKeepsTheChartEntry() async throws {
        let m = try teamModel(team: standard)
        try dir.write("p/roles/dev.json", roleJSON("dev"))
        m.reload()
        let projectDev = try XCTUnwrap(m.groups.last?.roles.first { $0.config.name == "dev" })
        _ = m.select(projectDev)
        m.requestDelete()
        await m.confirmDelete()
        guard case .valid(let chart) = TeamChartStore().load(for: try XCTUnwrap(m.project)) else { return XCTFail("valid chart") }
        XCTAssertNotNil(chart.member("dev"), "the shared dev still exists, so dev stays in the chart")
        XCTAssertEqual(chart.manager(of: "dev"), "reviewer")
    }
}
