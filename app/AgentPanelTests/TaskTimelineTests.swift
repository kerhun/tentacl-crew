import XCTest
@testable import AgentPanel

final class TaskTimelineTests: XCTestCase {
    private func ev(_ minute: Int, _ text: String) -> ActionLogEvent { ActionLogEvent(time: Date(timeIntervalSince1970: Double(minute) * 60), text: text) }
    private func card(modified: Date? = nil) -> TaskCard {
        TaskCard(id: "N1", project: "p", status: .doing, agent: nil, branch: nil, kind: nil, files: [], title: "T", sections: [:],
                 url: URL(fileURLWithPath: "/x/N1.md"), modified: modified)
    }

    func testTheTimelineListsTheStepsOfOneCardInOrder() {
        let events = [
            ev(5, "answered N1 (w1:p1)"), ev(1, "start N1 agent=a branch=b pane=w1:p1"), ev(2, "start N2 agent=x branch=y pane=w2:p1"),
            ev(9, "review packet prepared for N1"), ev(12, "fix request sent to w1:p1 for N1"), ev(15, "fix request (passed on) sent to w1:p1 for N1"),
            ev(20, "approved N1"), ev(3, "command to w1:p1: hi"),
        ]
        let t = TaskTimeline.build(card: card(), events: events)
        XCTAssertEqual(t.map(\.kind), [.started, .answered, .reviewPrepared, .fixRequested, .fixRequested, .approved])
        XCTAssertEqual(t.map(\.time), [1, 5, 9, 12, 15, 20].map { Date(timeIntervalSince1970: Double($0) * 60) })
    }

    func testAskedAndAnsweredBothShow() {
        let t = TaskTimeline.build(card: card(), events: [ev(1, "asked N1 (choice)"), ev(2, "answered N1 (w1:p1)")])
        XCTAssertEqual(t.map(\.kind), [.asked, .answered])
        XCTAssertEqual(t.first?.title, "Question asked")
    }

    func testLinesOfAnotherProjectAreLeftOutAndOldLinesStillMatch() {
        func tagged(_ m: Int, _ project: String?, _ text: String) -> ActionLogEvent { ActionLogEvent(time: Date(timeIntervalSince1970: Double(m) * 60), text: text, project: project) }
        let t = TaskTimeline.build(card: card(), events: [tagged(1, "other", "approved N1"), tagged(2, "p", "asked N1 (plan)"), tagged(3, nil, "answered N1 (w1:p1)")])
        XCTAssertEqual(t.map(\.kind), [.asked, .answered])
    }

    func testFailedAndOtherCardsAreLeftOut() {
        let events = [ev(1, "start N1 FAILED: no"), ev(2, "start N10 agent=a branch=b pane=p"), ev(3, "approved N10"), ev(4, "fix request for N1 NOT SENT: x")]
        XCTAssertEqual(TaskTimeline.build(card: card(), events: events), [])
    }

    func testClosedAndTheCardsLastChangeCloseTheList() {
        let t = TaskTimeline.build(card: card(modified: Date(timeIntervalSince1970: 3600)), events: [ev(1, "closed N1 without merge")])
        XCTAssertEqual(t.map(\.kind), [.closed, .cardChanged])
    }
}

@MainActor
final class AgentScreenPollerTests: XCTestCase {
    final class Fake: TerminalReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _targets: [String] = []
        var targets: [String] { lock.lock(); defer { lock.unlock() }; return _targets }
        func screen(of target: String, lines: Int) async throws -> String { lock.lock(); _targets.append(target); let n = _targets.count; lock.unlock(); return "screen \(n)" }
    }
    private func settle(_ c: () -> Bool) async { for _ in 0..<300 where !c() { try? await Task.sleep(for: .milliseconds(10)) } }

    func testNothingIsReadUntilTheTabIsOpen() async {
        let fake = Fake()
        let p = AgentScreenPoller(reader: fake, target: "w1:p1", interval: .milliseconds(10))
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fake.targets, [])
        p.appear()
        await settle { fake.targets.count >= 3 }
        XCTAssertGreaterThanOrEqual(fake.targets.count, 3, "it keeps refreshing while open")
        XCTAssertEqual(Set(fake.targets), ["w1:p1"])
        XCTAssertTrue(p.text.hasPrefix("screen"))
    }

    func testReadingStopsWhenTheTabCloses() async {
        let fake = Fake()
        let p = AgentScreenPoller(reader: fake, target: "w1:p1", interval: .milliseconds(10))
        p.appear()
        await settle { fake.targets.count >= 2 }
        p.disappear()
        try? await Task.sleep(for: .milliseconds(40))
        let n = fake.targets.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fake.targets.count, n)
    }

    func testNoAgentMeansNoRead() async {
        let fake = Fake()
        let p = AgentScreenPoller(reader: fake, target: nil, interval: .milliseconds(10))
        p.appear()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fake.targets, [])
        XCTAssertNotNil(p.error)
    }
}

final class CardOverviewTests: XCTestCase {
    private func card(_ sections: [String: String]) -> TaskCard {
        TaskCard(id: "N1", project: "p", status: .doing, agent: nil, branch: nil, kind: nil, files: [], title: "T", sections: sections,
                 url: URL(fileURLWithPath: "/x/N1.md"), modified: nil)
    }

    func testEverySectionIsShownInCardOrderEvenWhenEmpty() {
        let o = CardOverview.sections(for: card(["Goal": "A long goal\nover lines", "Scope": "only x", "Decision": "Approved."]))
        XCTAssertEqual(o.map(\.title), ["Goal", "Scope", "Acceptance criteria", "Dependencies", "Fix notes", "Decision"])
        XCTAssertEqual(o[0].entries, ["A long goal\nover lines"], "the goal in full")
        XCTAssertEqual(o[2].entries, [])
        XCTAssertEqual(o[5].entries, ["Approved."])
    }

    func testFixNotesEntriesComeInOrder() {
        let h = CardOverview.sections(for: card(["Fix notes": "### Round 1\nchange X\n\n### Round 2\nand Y"]))[4]
        XCTAssertEqual(h.entries, ["### Round 1\nchange X", "### Round 2\nand Y"])
        let b = CardOverview.sections(for: card(["Fix notes": "- First: X.\n\n- Second: Y."]))[4]
        XCTAssertEqual(b.entries, ["- First: X.", "- Second: Y."])
    }

    func testDecisionsLandInTheTimelineAtTheirTime() {
        func rec(_ m: Int, _ id: String, _ by: DecisionRecord.By, _ r: DecisionRecord.Result, card: String = "N1") -> DecisionRecord {
            DecisionRecord(id: id, time: Date(timeIntervalSince1970: Double(m) * 60), cardID: card, agent: "a", kind: "choice", question: "Which?", by: by, result: r, answer: "A", why: "")
        }
        let events = [ActionLogEvent(time: Date(timeIntervalSince1970: 60), text: "asked N1 (choice)"), ActionLogEvent(time: Date(timeIntervalSince1970: 300), text: "approved N1")]
        let t = TaskTimeline.build(card: TaskCard(id: "N1", project: "p", status: .doing, agent: nil, branch: nil, kind: nil, files: [], title: "T", sections: [:], url: URL(fileURLWithPath: "/x"), modified: nil),
                                   events: events, decisions: [rec(2, "d1", .pm, .answered), rec(3, "d2", .you, .answered), rec(4, "d3", .pm, .answered, card: "N2")])
        XCTAssertEqual(t.map(\.kind), [.asked, .decision, .decision, .approved])
        XCTAssertEqual(t.map(\.title), ["Question asked", "PM answered", "You answered", "Approved"])
        XCTAssertEqual(t[1].detail, "Which? → A")
    }
}

@MainActor
final class CardTabSnapshotTests: XCTestCase {
    func testTheCardTabRendersEverySection() throws {
        let card = TaskCard(id: "N1", project: "p", status: .doing, agent: nil, branch: nil, kind: nil, files: [], title: "A task",
                            sections: ["Goal": "Do **the thing** in full.\n\nSecond paragraph.", "Scope": "- `a.swift`\n- `b.swift`", "Acceptance criteria": "Tests green.",
                                       "Fix notes": "### Round 1\nChange X.\n\n### Round 2\nAnd Y.", "Decision": "Approved."],
                            url: URL(fileURLWithPath: "/x/N1.md"), modified: nil)
        let view = TaskDetailView(card: card, shots: [], opener: nil, startState: StartButtonState(enabled: false, help: ""),
                                  reviewState: reviewButtonStates(card: card, canAct: false, reason: "x", worktreeExists: false, busy: false, agentWorking: false),
                                  onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}, startTab: .card)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 700, height: 900)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }
}
