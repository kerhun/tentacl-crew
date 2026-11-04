import XCTest
@testable import AgentPanel

/// Each project has its own PM (N110): a PM never serves another project, and a project without one offers Start PM.
@MainActor
final class ProjectPMTests: XCTestCase {
    private var dir: TempDir!
    private var iso: TestIsolation!

    override func setUpWithError() throws { dir = try TempDir(); iso = TestIsolation(dir, owner: self) }

    private let pmA = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .idle, cwd: "/repoA", title: "PM", sessionID: "sA")
    private let orchard = AgentStatus(paneID: "w5:p1", workspaceID: "w5", state: .idle, cwd: "/elsewhere/orchard", title: "◐ Tentacl PM", sessionID: "sF")

    private func panel(agents: [AgentStatus]) throws -> PanelModel {
        func project(_ id: String, _ repo: String) throws -> URL {
            try dir.write("\(id)/project.json", "{\"id\":\"\(id)\",\"name\":\"Project \(id.uppercased())\",\"repoPath\":\"\(repo)\",\"dataDir\":\"\(dir.url.appendingPathComponent("data-\(id)").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        }
        let a = try project("a", "/repoA"), b = try project("b", "/repoB")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(a.path)\",\"\(b.path)\"]}")
        return PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(agents)) }, opener: RecordingOpener(),
                          log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
    }

    func testAPMInsideOneRepoIsNotAnotherProjectsPM() async throws {
        let m = try panel(agents: [pmA])
        await m.reload()
        XCTAssertEqual(m.pmAgent(forProject: "a")?.paneID, "w1:p1")
        XCTAssertNil(m.pmAgent(forProject: "b"))
    }

    func testTheLastCommandTargetNoLongerMakesAPM() async throws {
        iso.defaults.set("w5:p1|sF", forKey: "commandTarget.b")
        let m = try panel(agents: [orchard])
        await m.reload()
        XCTAssertNil(m.pmSession(forProject: "b"))
        XCTAssertNil(m.pmAgent(forProject: "b"))
    }

    func testAChosenPMServesOnlyItsProjectAndStaysOutOfTheOthersAgents() async throws {
        let m = try panel(agents: [orchard])
        iso.defaults.set("sF", forKey: "pmSession.a")   // chosen before N129: kept working
        await m.reload()
        XCTAssertEqual(m.pmAgent(forProject: "a")?.paneID, "w5:p1")
        XCTAssertNil(m.pmAgent(forProject: "b"))
        await m.selectProject("b")
        XCTAssertEqual(m.pmStatus, .missing, "project b offers Start PM")
        guard case .available(let shown) = m.visibleAgents else { return XCTFail() }
        XCTAssertEqual(shown, [], "project a's PM is not in b's Agents list")
    }

    func testChoosingAClaimedPMAsksFirstThenMovesIt() async throws {
        let inB = AgentStatus(paneID: "w6:p1", workspaceID: "w6", state: .idle, cwd: "/repoB", title: "PM", sessionID: "sB")
        let m = try panel(agents: [inB])
        iso.defaults.set("sB", forKey: "pmSession.a")
        await m.reload()
        m.choosePM(inB, forProject: "b")
        XCTAssertEqual(m.pendingPMChoice?.projectID, "b")
        XCTAssertEqual(m.pendingPMChoice?.fromName, "Project A")
        XCTAssertEqual(m.pmSession(forProject: "b"), nil, "nothing moves before the confirmation")
        m.cancelPMChoice()
        XCTAssertNil(m.pendingPMChoice)
        XCTAssertEqual(m.pmSession(forProject: "a"), "sB")
        m.choosePM(inB, forProject: "b")
        m.confirmPMChoice()
        XCTAssertEqual(m.pmSession(forProject: "b"), "sB")
        XCTAssertNil(m.pmSession(forProject: "a"), "one PM session belongs to one project")
        XCTAssertNil(m.pmAgent(forProject: "a"))
    }

    func testAPMChosenForAnotherProjectIsNotFoundByTitleInsideThisRepo() async throws {
        let m = try panel(agents: [pmA])
        iso.defaults.set("sA", forKey: "pmSession.b")
        await m.reload()
        XCTAssertNil(m.pmAgent(forProject: "a"), "claimed by b, so a's title fallback skips it")
    }

    /// Snapshot of the Dashboard chat's empty state for a project without a PM (N346) (set AGENT_PANEL_SNAPSHOT_DIR to save it).
    func testSnapshotOfTheNoPMBar() throws {
        let view = PMNoPMState(projectName: "Project B", candidates: [orchard], resumeHelp: "").frame(width: 640, height: 220).background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 640, height: 220)))
        XCTAssertGreaterThan(data.count, 1_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("no-pm-bar.png")) }
    }
}
