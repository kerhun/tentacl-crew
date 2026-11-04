import XCTest
@testable import AgentPanel

final class StartAuthorityTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
        for r in ["pm", "reviewer", "dev", "ui_dev", "analyst"] { try dir.write("base/\(r).json", roleJSON(r)) }
    }

    private func roleJSON(_ name: String) -> String {
        "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"\(name).md\"}"
    }

    private let standard = #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"reviewer","reportsTo":"pm"},{"role":"dev","reportsTo":"reviewer"},{"role":"ui_dev","reportsTo":"reviewer"}]}"#

    private func project() throws -> ProjectConfig {
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":3,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private func card(_ id: String = "T1", from: String? = nil, roles: String = "[dev]") throws -> TaskCard {
        let f = from.map { "from: \($0)\n" } ?? ""
        let url = try dir.write("data/tasks/\(id).md", "---\nid: \(id)\nproject: demo\nstatus: todo\nagent:\nbranch: feat/\(id.lowercased())\nroles: \(roles)\n\(f)files:\n  - a.swift\n---\n# \(id) · Title\n\n## Goal\nx\n\n## Report\nBody stays.\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private func flow(_ p: ProjectConfig, writer: CardWriting = CardWriter()) -> StartTaskFlow {
        StartTaskFlow(project: p, scripts: scripts, commander: commander, writer: writer, log: ActionLog(fileURL: dir.url.appendingPathComponent("log")),
                      roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("base")), teamStore: TeamChartStore(), runningCards: { [] })
    }

    private func authority(_ c: TaskCard, _ p: ProjectConfig) throws -> StartAuthority { try flow(p).plan(for: c).authority }

    func testARepeatedFromLineMakesTheCardRefuseToPlan() throws {
        try dir.write("p/team.json", standard)
        let url = try dir.write("data/tasks/R1.md", "---\nid: R1\nproject: demo\nstatus: todo\nagent:\nbranch: feat/r1\nroles: [dev]\nfrom: pm\nfrom: dev\nfiles:\n  - a.swift\n---\n# R1\n")
        let c = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        XCTAssertThrowsError(try flow(try project()).plan(for: c)) { guard case .invalid = $0 as? StartError else { return XCTFail("\($0)") } }
        XCTAssertEqual(scripts.calls, [])
    }

    func testCardFromParses() throws {
        XCTAssertEqual(try card("A1", from: "reviewer").from, "reviewer")
        XCTAssertNil(try card("A2").from)
        XCTAssertEqual(try card("A3", from: "PM").from, "PM", "an odd value is kept; the plan decides what to do with it")
    }

    func testNoTeamFileMeansNotApplicable() throws {
        XCTAssertEqual(try authority(try card(from: "anything"), try project()), .notApplicable)
    }

    func testAllowedWhenTheGiverIsAboveTheTargetRole() throws {
        try dir.write("p/team.json", standard)
        let p = try project()
        XCTAssertEqual(try authority(try card("A1", from: "pm"), p), .allowed(from: "pm", to: "dev"))
        XCTAssertEqual(try authority(try card("A2", from: "reviewer"), p), .allowed(from: "reviewer", to: "dev"))
        XCTAssertEqual(try authority(try card("A3", from: "user"), p), .allowed(from: "user", to: "dev"))
    }

    func testNoFromMeansTheUserGivesTheTask() throws {
        try dir.write("p/team.json", standard)
        XCTAssertEqual(try authority(try card(), try project()), .allowed(from: "user", to: "dev"))
    }

    func testDeniedForPeersSelfAndUpwards() throws {
        try dir.write("p/team.json", standard)
        let p = try project()
        guard case .denied(let peer) = try authority(try card("A1", from: "ui_dev"), p) else { return XCTFail("peers") }
        XCTAssertTrue(peer.contains("ui_dev") && peer.contains("dev"), peer)
        guard case .denied = try authority(try card("A2", from: "dev"), p) else { return XCTFail("self") }
        guard case .denied(let up) = try authority(try card("A3", from: "dev", roles: "[pm]"), p) else { return XCTFail("upwards") }
        XCTAssertTrue(up.contains("pm"), up)
    }

    func testFromNotInTheChartIsDenied() throws {
        try dir.write("p/team.json", standard)
        guard case .denied(let m) = try authority(try card(from: "analyst"), try project()) else { return XCTFail("denied") }
        XCTAssertTrue(m.contains("not in the team chart"), m)
    }

    func testTargetNotInTheChartIsUserOnly() throws {
        try dir.write("p/team.json", standard)
        let p = try project()
        guard case .denied(let m) = try authority(try card("A1", from: "pm", roles: "[analyst]"), p) else { return XCTFail("denied") }
        XCTAssertTrue(m.contains("analyst") && m.contains("only you"), m)
        XCTAssertEqual(try authority(try card("A2", roles: "[analyst]"), p), .allowed(from: "user", to: "analyst"))
    }

    func testOnlyTheFirstRoleIsChecked() throws {
        try dir.write("p/team.json", standard)
        XCTAssertEqual(try authority(try card(from: "reviewer", roles: "[dev, pm]"), try project()), .allowed(from: "reviewer", to: "dev"))
    }

    func testHostileFromValuesAreRefusedBeforeAnyScript() throws {
        try dir.write("p/team.json", standard)
        let p = try project()
        for bad in ["../x", "a b", "--force", "PM", "a-b"] {
            XCTAssertThrowsError(try flow(p).plan(for: try card("H\(bad.count)", from: bad)), bad) { guard case .invalid = $0 as? StartError else { return XCTFail("\($0)") } }
        }
        XCTAssertEqual(scripts.calls, [])
    }

    func testAnInvalidChartStopsTheStartWithItsReasons() throws {
        try dir.write("p/team.json", #"{"version":1,"members":[{"role":"a","reportsTo":"b"},{"role":"b","reportsTo":"a"}]}"#)
        XCTAssertThrowsError(try flow(try project()).plan(for: try card())) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("team.json") && m.contains("cycle"), m)
        }
        XCTAssertEqual(scripts.calls, [])
    }

    func testAMemberWithoutARoleFileIsNotAnError() throws {
        try dir.write("p/team.json", #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"dev","reportsTo":"pm"},{"role":"tester","reportsTo":"pm"}]}"#)
        XCTAssertEqual(try authority(try card(from: "pm"), try project()), .allowed(from: "pm", to: "dev"))
    }

    // MARK: start

    func testADeniedStartRunsNoScriptAndLeavesTheCard() async throws {
        try dir.write("p/team.json", standard)
        let p = try project(), c = try card(from: "ui_dev")
        let before = try String(contentsOf: c.url, encoding: .utf8)
        let f = flow(p)
        let plan = try f.plan(for: c)
        do { _ = try await f.start(plan); XCTFail("should throw") }
        catch let error as StartError { guard case .notAuthorized(let m) = error else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("ui_dev"), m) }
        XCTAssertEqual(scripts.calls, [])
        XCTAssertEqual(try String(contentsOf: c.url, encoding: .utf8), before)
    }

    func testGivingItMyselfStartsAndWritesFromUserInTheSameCardUpdate() async throws {
        try dir.write("p/team.json", standard)
        let p = try project(), c = try card(from: "ui_dev")
        let f = flow(p)
        let plan = try f.plan(for: c)
        _ = try await f.start(plan, givingItMyself: true)
        let after = try CardParser.parse(try String(contentsOf: c.url, encoding: .utf8), url: c.url)
        XCTAssertEqual(after.from, "user")
        XCTAssertEqual(after.status, .doing)
        XCTAssertEqual(after.agent, "dev-t1")
        XCTAssertEqual(after.sections["Report"], "Body stays.", "only front matter lines changed")
        XCTAssertEqual(try XCTUnwrap(scripts.calls(of: .spawn).first).args[3], "feat/t1")
    }

    func testGivingItMyselfWhenAlreadyAllowedChangesNothingExtra() async throws {
        try dir.write("p/team.json", standard)
        let p = try project(), c = try card(from: "pm")
        let f = flow(p)
        _ = try await f.start(try f.plan(for: c), givingItMyself: true)
        XCTAssertEqual(try CardParser.parse(try String(contentsOf: c.url, encoding: .utf8), url: c.url).from, "pm", "an allowed card keeps its giver")
    }

    func testGivingItMyselfIsRefusedWhenTheCardChangedSincePlan() async throws {
        try dir.write("p/team.json", standard)
        let p = try project(), c = try card(from: "ui_dev")
        let f = flow(p)
        let plan = try f.plan(for: c)
        try String(contentsOf: c.url, encoding: .utf8).replacingOccurrences(of: "from: ui_dev", with: "from: reviewer").write(to: c.url, atomically: true, encoding: .utf8)
        do { _ = try await f.start(plan, givingItMyself: true); XCTFail("should throw") }
        catch let error as StartError { guard case .notStartable = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(scripts.calls, [])
    }

    func testAFromWriteFailureCleansUpLikeAnyFailedStart() async throws {
        try dir.write("p/team.json", standard)
        let p = try project(), c = try card(from: "ui_dev")
        let f = flow(p, writer: FailingWriter())
        let plan = try f.plan(for: c)
        do { _ = try await f.start(plan, givingItMyself: true); XCTFail("should throw") }
        catch let error as StartError { guard case .cardWriteFailed = error else { return XCTFail("\(error)") } }
        XCTAssertFalse(scripts.calls(of: .stop).isEmpty, "the agent that was started is stopped again")
    }

    func testASecondStartWhileTheFirstRunsIsRefused() async throws {
        try dir.write("p/team.json", standard)
        let p = try project(), c = try card(from: "ui_dev")
        let gate = TestGate()
        let inner = scripts.handler
        scripts.handler = { s, a in if s == .spawn { await gate.wait() }; return try await inner(s, a) }
        let f = flow(p)
        let plan = try f.plan(for: c)
        let first = Task { try await f.start(plan, givingItMyself: true) }
        try await Task.sleep(for: .milliseconds(200))
        do { _ = try await f.start(plan, givingItMyself: true); XCTFail("should throw") }
        catch let error as StartError { XCTAssertEqual(error, .alreadyStarting) }
        await gate.release()
        _ = try await first.value
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1)
    }

    func testTheSheetFieldsShowTheAuthorityLine() throws {
        try dir.write("p/team.json", standard)
        let p = try project()
        let ok = try flow(p).plan(for: try card("A1", from: "pm"))
        XCTAssertEqual(startSheetFields(plan: ok, project: p).first { $0.label == "Given by" }?.value, "pm → dev ✓")
        let denied = try flow(p).plan(for: try card("A2", from: "ui_dev"))
        XCTAssertTrue(startSheetFields(plan: denied, project: p).first { $0.label == "Given by" }?.value.hasPrefix("✗") == true)
        let none = ProjectConfig(id: "d", name: "D", repoPath: "/r", dataDir: "/d", maxParallel: 2, buildCommand: "b", xcodeProject: nil, simulator: .init(baseDevice: "x"), sharedFiles: [], openWith: "Xcode")
        XCTAssertNil(startSheetFields(plan: StartPlan(card: try card("A3"), agentName: "dev-a3", branch: "b", rolePath: "/x", worktreePath: "/w", commandPreview: "c"), project: none).first { $0.label == "Given by" })
    }
}
