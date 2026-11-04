import XCTest
@testable import AgentPanel

@MainActor
final class DependencyGraphTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus = .todo, deps: String? = nil) -> TaskCard {
        TaskCard(id: id, project: "demo", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id,
                 sections: deps.map { ["Dependencies": $0] } ?? [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    func testCardWithoutDependenciesHasNoState() {
        let graph = DependencyGraph(cards: [card("N1", deps: "None.")])
        XCTAssertEqual(graph.state(of: "N1"), .clear)
    }

    func testWaitingForUnfinishedDependency() {
        let graph = DependencyGraph(cards: [card("N1", .doing), card("N2", deps: "N1 and N3"), card("N3", .done)])
        XCTAssertEqual(graph.state(of: "N2"), .waiting(["N1"]))
        XCTAssertEqual(graph.state(of: "N2").label, "waiting for N1")
    }

    func testReadyWhenEveryDependencyIsDone() {
        let graph = DependencyGraph(cards: [card("N1", .done), card("N2", deps: "N1")])
        XCTAssertEqual(graph.state(of: "N2"), .ready)
        XCTAssertEqual(graph.state(of: "N2").label, "ready to start")
    }

    func testCycleIsAProblem() {
        let graph = DependencyGraph(cards: [card("N1", deps: "N2"), card("N2", deps: "N3"), card("N3", deps: "N1"), card("N4", deps: "N1")])
        for id in ["N1", "N2", "N3"] {
            guard case .problem(let text) = graph.state(of: id) else { return XCTFail("\(id) should have a problem") }
            XCTAssertTrue(text.contains("cycle"), text)
        }
        XCTAssertEqual(graph.state(of: "N4"), .waiting(["N1"]))
    }

    func testUnknownIDIsAProblem() {
        let graph = DependencyGraph(cards: [card("N1", deps: "- N99 (the old one)\n- N2"), card("N2", .done), card("N3", deps: "N2 and M7.")])
        XCTAssertEqual(graph.state(of: "N1"), .problem("unknown card N99"))
        XCTAssertEqual(graph.state(of: "N3"), .problem("unknown card M7"))
    }

    func testOnlyListItemsCount() {
        let cards = [card("N1", .doing), card("N2", .done), card("N4", .doing),
                     card("N3", deps: "- N1 (same files)\n- N2\nRuns next to N4.")]
        XCTAssertEqual(DependencyGraph(cards: cards).state(of: "N3"), .waiting(["N1"]))
    }

    func testNotesAndNoneMentioningIDsAreNotDependencies() {
        let cards = [card("N1", .doing), card("N10", .doing), card("N12", .doing),
                     card("N2", deps: "None left: N1 and N10 are done. Runs next to N12 and N4."),
                     card("N3", deps: "N12 (same files)"),
                     card("N5", deps: "Runs after N1, see M7.")]
        let graph = DependencyGraph(cards: cards)
        for id in ["N2", "N3", "N5"] { XCTAssertEqual(graph.state(of: id), .clear, id) }
    }

    func testOldOneLineIDListStillCounts() {
        let cards = [card("N20", .done), card("N22", .doing), card("N23", deps: "N20 and N22."), card("N24", deps: "N20, N22")]
        let graph = DependencyGraph(cards: cards)
        XCTAssertEqual(graph.state(of: "N23"), .waiting(["N22"]))
        XCTAssertEqual(graph.state(of: "N24"), .waiting(["N22"]))
    }

    func testBacklogReadsTheSameDependencies() {
        let known: Set<String> = ["N1", "N2", "N3"]
        XCTAssertEqual(RoundModel.mentioned(in: "- N1 (why)\n- N3", known: known, except: "N2"), ["N1", "N3"])
        XCTAssertEqual(RoundModel.mentioned(in: "None left: N1 is done. Next to N3.", known: known, except: "N2"), [])
    }

    func testFinishedCardsShowNothing() {
        let graph = DependencyGraph(cards: [card("N1", .doing), card("N2", .done, deps: "N1"), card("N3", .cancelled, deps: "N1")])
        XCTAssertEqual(graph.state(of: "N2"), .clear)
        XCTAssertEqual(graph.state(of: "N3"), .clear)
    }

    func testStartButtonShowsTheReason() {
        let todo = card("N2", deps: "N1")
        let waiting = startButtonState(card: todo, canStart: true, reason: nil, dependencies: .waiting(["N1"]))
        XCTAssertEqual(waiting, StartButtonState(enabled: false, help: "Waiting for N1: it is not done yet."))
        let problem = startButtonState(card: todo, canStart: true, reason: nil, dependencies: .problem("unknown card N99"))
        XCTAssertFalse(problem.enabled)
        XCTAssertTrue(problem.help.contains("N99"))
        XCTAssertTrue(startButtonState(card: todo, canStart: true, reason: nil, dependencies: .ready).enabled)
        XCTAssertTrue(startButtonState(card: todo, canStart: true, reason: nil, dependencies: nil).enabled)
    }
}
