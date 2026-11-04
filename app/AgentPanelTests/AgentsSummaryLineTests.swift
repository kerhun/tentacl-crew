import XCTest
@testable import AgentPanel

final class AgentsSummaryLineTests: XCTestCase {
    func testMixedPhasesAreCountedInAFixedOrder() {
        XCTAssertEqual(AgentsPane.summaryLine(phases: [.working, .idle, .waitingForYou, .starting]), "4 agents · 2 working · 1 waiting · 1 idle")
    }

    func testWaitingCountsTheSamePhasesAsTheHeaderChip() {
        let phases: [TaskPhase?] = [.waitingForYou, .pmHandling, .blocked, .working]
        XCTAssertEqual(AgentsPane.summaryLine(phases: phases), "4 agents · 1 working · \(agentsWaitingCount(phases: phases)) waiting")
    }

    func testEveryOtherPhaseHasItsOwnWord() {
        XCTAssertEqual(AgentsPane.summaryLine(phases: [.needsFix, .inReview, .finished, .finished]), "4 agents · 1 needs fix · 1 in review · 2 finished")
    }

    func testZeroPartsAreLeftOut() {
        XCTAssertEqual(AgentsPane.summaryLine(phases: [.working, .working]), "2 agents · 2 working")
    }

    func testOneAgentIsSingular() {
        XCTAssertEqual(AgentsPane.summaryLine(phases: [.idle]), "1 agent · 1 idle")
    }

    func testAnAgentWithoutAPhaseCountsOnlyInTheTotal() {
        XCTAssertEqual(AgentsPane.summaryLine(phases: [nil, .working]), "2 agents · 1 working")
        XCTAssertEqual(AgentsPane.summaryLine(phases: [nil]), "1 agent")
    }

    func testNoAgentsGiveNoLine() {
        XCTAssertNil(AgentsPane.summaryLine(phases: []))
    }

    @MainActor
    func testThePaneHeaderShowsTheLineForMixedPhases() throws {
        let phases: [String: TaskPhase] = ["w1:p1": .working, "w2:p1": .working, "w3:p1": .waitingForYou, "w4:p1": .idle]
        let agents = phases.keys.sorted().map { AgentStatus(paneID: $0, workspaceID: "w", state: .working, cwd: "/tmp/\($0)", title: "dev-\($0.prefix(2))") }
        let state = AgentsState.available(agents)
        let phase: (AgentStatus) -> TaskPhase? = { phases[$0.paneID] }
        XCTAssertEqual(AgentsPane.summaryLine(state: state, phase: phase), "4 agents · 2 working · 1 waiting · 1 idle")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AgentsPane(state: state, phase: phase), size: CGSize(width: 420, height: 520)))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("agents-summary.png")) }
    }

    func testTheLineIsOnlyShownForAvailableAgents() {
        XCTAssertNil(AgentsPane.summaryLine(state: .loading))
        XCTAssertNil(AgentsPane.summaryLine(state: .unavailable("terminal is not running")))
        XCTAssertNil(AgentsPane.summaryLine(state: .available([])))
    }
}
