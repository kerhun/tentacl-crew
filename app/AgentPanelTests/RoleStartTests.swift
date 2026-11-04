import XCTest
@testable import AgentPanel

final class RoleStartTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
    }

    private func roleJSON(_ name: String, kind: String = "interactive", effort: String = "medium") -> String {
        "{\"name\":\"\(name)\",\"kind\":\"\(kind)\",\"model\":\"sonnet\",\"effort\":\"\(effort)\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"\(name).md\"}"
    }

    private var baseDir: URL { dir.url.appendingPathComponent("base") }

    private func project() throws -> ProjectConfig {
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":3,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private func card(_ id: String = "T1", roles: String? = nil) throws -> TaskCard {
        let r = roles.map { "roles: \($0)\n" } ?? ""
        let url = try dir.write("data/tasks/\(id).md", "---\nid: \(id)\nproject: demo\nstatus: todo\nagent:\nbranch: feat/\(id.lowercased())\n\(r)files:\n  - a.swift\n---\n# \(id) · Title\n\n## Goal\nx\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private func flow(_ project: ProjectConfig) -> StartTaskFlow {
        StartTaskFlow(project: project, scripts: scripts, commander: commander, writer: CardWriter(), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")),
                      roleStore: RoleStore(baseDir: baseDir), teamStore: TeamChartStore(), runningCards: { [] })
    }

    func testCardRolesParseInlineAndBlock() throws {
        XCTAssertEqual(try card("A1", roles: "[reviewer]").roles, ["reviewer"])
        XCTAssertEqual(try card("A2", roles: "[ui_dev, dev]").roles, ["ui_dev", "dev"])
        XCTAssertEqual(try card("A3").roles, [])
        XCTAssertEqual(try card("A5", roles: "reviewer").roles, ["reviewer"], "a bare value is a one-item list, not silently dropped")
        XCTAssertEqual(try card("A6", roles: "\"reviewer\"").roles, ["reviewer"])
        let url = try dir.write("data/tasks/A4.md", "---\nid: A4\nstatus: todo\nroles:\n  - reviewer\n  - dev\nfiles:\n  - a.swift\n---\n# A4\n")
        XCTAssertEqual(try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url).roles, ["reviewer", "dev"])
        XCTAssertEqual(try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url).files, ["a.swift"], "files still parse after roles")
    }

    func testPlanUsesTheFirstRoleOfTheCard() throws {
        try dir.write("base/reviewer.json", roleJSON("reviewer")); try dir.write("base/dev.json", roleJSON("dev"))
        let plan = try flow(try project()).plan(for: try card("T1", roles: "[reviewer, dev]"))
        XCTAssertEqual(plan.roleName, "reviewer")
        XCTAssertEqual(plan.agentName, "reviewer-t1-demo")
        XCTAssertEqual(URL(fileURLWithPath: plan.rolePath).standardizedFileURL.path, baseDir.appendingPathComponent("reviewer.json").standardizedFileURL.path)
        XCTAssertTrue(plan.commandPreview.contains("reviewer.json"))
    }

    func testNoRolesMeansDev() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let plan = try flow(try project()).plan(for: try card("T1"))
        XCTAssertEqual(plan.roleName, "dev")
        XCTAssertEqual(plan.agentName, "dev-t1-demo")
    }

    func testProjectRoleShadowsTheBaseRoleWhenStarting() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        try dir.write("p/roles/dev.json", roleJSON("dev"))
        let plan = try flow(try project()).plan(for: try card())
        XCTAssertEqual(URL(fileURLWithPath: plan.rolePath).standardizedFileURL.path, dir.url.appendingPathComponent("p/roles/dev.json").standardizedFileURL.path)
    }

    func testUnknownRoleRefusesAndNamesTheSearchedPlaces() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        XCTAssertThrowsError(try flow(try project()).plan(for: try card("T1", roles: "[ghost]"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("ghost"))
            XCTAssertTrue(m.contains(baseDir.appendingPathComponent("ghost.json").path), m)
        }
        XCTAssertEqual(scripts.calls, [])
    }

    func testNoDevRoleAnywhereIsAPlanErrorNotASilentFallback() throws {
        XCTAssertThrowsError(try flow(try project()).plan(for: try card())) {
            guard case .missingRole(let name, _, _) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "dev")
        }
    }

    func testHeadlessRoleIsRefusedWithAClearMessage() throws {
        try dir.write("base/bot.json", roleJSON("bot", kind: "headless"))
        XCTAssertThrowsError(try flow(try project()).plan(for: try card("T1", roles: "[bot]"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("headless"), m)
        }
    }

    func testAnInvalidRoleFileIsRefusedEarlyWithItsProblem() throws {
        try dir.write("base/dev.json", roleJSON("dev", effort: "ultra"))
        XCTAssertThrowsError(try flow(try project()).plan(for: try card())) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("effort"), m)
        }
    }

    func testHostileRoleNamesNeverReachAScript() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        for name in ["../../x", "--force", "Dev", "a/b"] {
            XCTAssertThrowsError(try flow(try project()).plan(for: try card("T\(name.count)", roles: "[\(name)]")), name) {
                guard case .invalid = $0 as? StartError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertEqual(scripts.calls, [])
    }

    func testARoleDeletedBetweenPlanAndStartDoesNotCrash() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let f = flow(try project())
        let plan = try f.plan(for: try card())
        try FileManager.default.removeItem(at: baseDir.appendingPathComponent("dev.json"))
        do { _ = try await f.start(plan); XCTFail("should throw") }
        catch let error as StartError { guard case .invalid(let m) = error else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("role"), m) }
        XCTAssertEqual(scripts.calls, [], "no script ran")
    }

    func testStartPassesTheResolvedRoleFileToTheSpawnScript() async throws {
        try dir.write("base/reviewer.json", roleJSON("reviewer"))
        let f = flow(try project())
        let c = try card("T1", roles: "[reviewer]")
        _ = try await f.start(try f.plan(for: c))
        let spawn = try XCTUnwrap(scripts.calls(of: .spawn).first)
        XCTAssertEqual(URL(fileURLWithPath: spawn.args[1]).standardizedFileURL.path, baseDir.appendingPathComponent("reviewer.json").standardizedFileURL.path)
    }

    // MARK: a missing role with a template

    func testMissingRoleWithATemplateOffersToAddIt() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        XCTAssertThrowsError(try flow(try project()).plan(for: try card("T1", roles: "[analyst]"))) {
            guard case .missingRole(let name, let template, _) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "analyst"); XCTAssertEqual(template, "analyst")
            let m = ($0 as? StartError)?.message ?? ""
            XCTAssertTrue(m.contains("no role called \"analyst\" is defined"), m)
            XCTAssertTrue(m.contains("Add the \"analyst\" role from its template"), m)
        }
    }

    func testMissingRoleWithoutATemplateKeepsTodaysMessage() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        XCTAssertThrowsError(try flow(try project()).plan(for: try card("T1", roles: "[ghost]"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("no role called \"ghost\" is defined"), m)
            XCTAssertFalse(m.contains("template"), m)
        }
    }

    func testTheEmptyTemplateIsNeverOffered() throws {
        XCTAssertThrowsError(try flow(try project()).plan(for: try card("T1", roles: "[empty]"))) {
            guard case .invalid = $0 as? StartError else { return XCTFail("\($0)") }
        }
    }

    @MainActor func testAddingFromTheOfferFillsTheFormAndAfterSavingTheStartPlanSucceeds() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let f = flow(try project()), c = try card("T1", roles: "[analyst]")
        let team = TeamModel(store: RoleStore(baseDir: baseDir), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("c")),
                             claudeHome: dir.url.appendingPathComponent("c"), makeScripts: { _ in nil }, project: nil)
        XCTAssertThrowsError(try f.plan(for: c))
        XCTAssertEqual(team.addRoleFromTemplate(named: "analyst"), .switched)
        XCTAssertEqual(team.draft.name, "analyst")
        XCTAssertTrue(team.isNew)
        await team.save()
        XCTAssertNil(team.saveError)
        XCTAssertEqual(try f.plan(for: c).roleName, "analyst")
    }

    @MainActor func testAddingAnUnknownTemplateDoesNothing() throws {
        let team = TeamModel(store: RoleStore(baseDir: baseDir), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("c")),
                             claudeHome: dir.url.appendingPathComponent("c"), makeScripts: { _ in nil }, project: nil)
        XCTAssertNil(team.addRoleFromTemplate(named: "ghost"))
        XCTAssertFalse(team.isNew)
    }
}
