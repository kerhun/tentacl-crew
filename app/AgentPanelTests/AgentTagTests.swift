import XCTest
@testable import AgentPanel

@MainActor
final class AgentTagTests: XCTestCase {
    private func card(_ status: TaskStatus, agent: String? = "dev-n12", roles: [String] = ["dev"], decision: String? = nil) -> TaskCard {
        var sections: [String: String] = [:]
        if let decision { sections["Decision"] = decision }
        return TaskCard(id: "N12", project: "d", status: status, agent: agent, branch: nil, kind: nil, files: [], title: "T",
                        sections: sections, url: URL(fileURLWithPath: "/data/tasks/N12.md"), roles: roles)
    }

    func testTextUsesTheRolesDisplayNameAndTheAgent() {
        let tag = AgentTagInfo.make(card(.doing), displayNames: ["dev": "Developer"], phase: .working)
        XCTAssertEqual(tag?.text, "Developer · dev-n12")
    }

    func testTextFallsBackToTheRoleNameAndToDevWhenTheCardHasNoRoles() {
        XCTAssertEqual(AgentTagInfo.make(card(.doing, roles: ["ui_dev"]), displayNames: [:], phase: .working)?.text, "ui_dev · dev-n12")
        XCTAssertEqual(AgentTagInfo.make(card(.doing, roles: []), displayNames: [:], phase: .working)?.text, "dev · dev-n12")
    }

    func testRunningTagTakesThePhaseColourAndOpensTheTerminal() {
        let tag = AgentTagInfo.make(card(.doing), displayNames: [:], phase: .waitingForYou)
        XCTAssertEqual(tag?.style, .running(.waitingForYou))
        XCTAssertEqual(tag?.opensTerminal, true)
        XCTAssertNil(tag?.date)
    }

    func testFinishedTagIsGreyWithTheApprovalDateAndIsNotClickable() {
        let tag = AgentTagInfo.make(card(.done, decision: "Approved 2026-10-18 14:25 by the user. Merged into main."), displayNames: [:], phase: nil)
        XCTAssertEqual(tag?.style, .finished)
        XCTAssertEqual(tag?.date, "2026-10-18")
        XCTAssertEqual(tag?.opensTerminal, false)
        XCTAssertEqual(tag?.text, "dev · dev-n12")
        XCTAssertEqual(tag?.label, "dev · dev-n12 · 2026-10-18")
    }

    func testCancelledCardKeepsItsAgentAndMissingDecisionMeansNoDate() {
        let tag = AgentTagInfo.make(card(.cancelled), displayNames: [:], phase: nil)
        XCTAssertEqual(tag?.style, .finished)
        XCTAssertNil(tag?.date)
        XCTAssertEqual(tag?.label, "dev · dev-n12")
    }

    func testNoTagWithoutAnAgent() {
        XCTAssertNil(AgentTagInfo.make(card(.todo, agent: nil), displayNames: [:], phase: nil))
        XCTAssertNil(AgentTagInfo.make(card(.done, agent: ""), displayNames: [:], phase: nil))
    }

    /// For visual checks: TEST_RUNNER_AGENT_PANEL_SNAPSHOT_DIR=<dir> scripts/app-test.sh -only-testing:AgentPanelTests/AgentTagTests
    func testSnapshotsOfTheListAndTheDetailHeaderWithTags() async throws {
        let model = await DemoSupport.makeModel()
        let list = try XCTUnwrap(SnapshotRenderer.render(view: TaskListView(model: model), size: CGSize(width: 420, height: 760)))
        let doing = try XCTUnwrap(model.cards.compactMap { c -> TaskCard? in if case .card(let k) = c, k.agent != nil { return k } else { return nil } }.first)
        let detail = try XCTUnwrap(SnapshotRenderer.render(
            view: TaskDetailView(card: doing, shots: [], opener: nil, phase: .working,
                                 agentTag: AgentTagInfo.make(doing, displayNames: ["dev": "Developer"], phase: .working),
                                 startState: startButtonState(card: doing, canStart: true, reason: nil, busy: false, dependencies: .clear),
                                 reviewState: reviewButtonStates(card: doing, canAct: true, reason: nil, worktreeExists: true, busy: false, agentWorking: true),
                                 onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}),
            size: CGSize(width: 760, height: 420)))
        XCTAssertGreaterThan(list.count, 5_000)
        XCTAssertGreaterThan(detail.count, 5_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try list.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n76-list.png"))
            try detail.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n76-detail.png"))
        }
    }

    /// N282: the task detail's tab row of a todo and a running card, neither with an Agent screen tab (n282-tabs-<kind>.png).
    func testSnapshotsOfTheTabsOfATodoAndARunningCard() async throws {
        let model = await DemoSupport.makeModel()
        let running = try XCTUnwrap(model.cards.compactMap { c -> TaskCard? in if case .card(let k) = c, k.agent != nil { return k } else { return nil } }.first)
        let todo = card(.todo, agent: nil)
        for (name, card, phase) in [("todo", todo, nil), ("running", running, TaskPhase.working)] {
            let png = try XCTUnwrap(SnapshotRenderer.render(
                view: TaskDetailView(card: card, shots: [], opener: nil, phase: phase,
                                     agentTag: AgentTagInfo.make(card, displayNames: [:], phase: phase),
                                     startState: startButtonState(card: card, canStart: true, reason: nil, busy: false, dependencies: .clear),
                                     reviewState: reviewButtonStates(card: card, canAct: true, reason: nil, worktreeExists: true, busy: false, agentWorking: true),
                                     onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}),
                size: CGSize(width: 760, height: 320)))
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n282-tabs-\(name).png")) }
        }
    }
}
