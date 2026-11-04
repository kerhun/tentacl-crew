import XCTest
import SwiftUI
import AppKit
@testable import AgentPanel

final class TaskPhaseTests: XCTestCase {
    private func phase(_ status: TaskStatus = .doing, agent: AgentState? = .working, begun: Bool = true, report: Bool = false,
                       waiting: Int = 0, quiet: Int = 0, pm: Bool = false, changed: Bool = false) -> TaskPhase? {
        TaskPhase.of(TaskPhaseInput(status: status, agent: agent, turnBegun: begun, hasReport: report, waiting: waiting, quiet: quiet, pmHandling: pm, reportChangedSinceFix: changed))
    }

    /// N53: after a fix request the agent ends a new turn and changes its Report; only then is a needs-fix card finished.
    func testANeedsFixCardIsFinishedOnlyAfterTheReportChanged() {
        XCTAssertEqual(phase(.needsFix, agent: .idle, report: true, changed: true), .finished)
        XCTAssertEqual(phase(.needsFix, agent: .done, report: true, changed: true), .finished)
        XCTAssertEqual(phase(.needsFix, agent: .idle, report: true, changed: false), .needsFix)
        XCTAssertEqual(phase(.needsFix, agent: .working, report: true, changed: true), .working)
        XCTAssertEqual(phase(.needsFix, agent: .idle, report: true, quiet: 1, changed: true), .needsFix)
    }

    private func fixCard(_ status: TaskStatus, report: String, id: String = "V1") -> TaskCard {
        TaskCard(id: id, project: "d", status: status, agent: "dev-v1", branch: "test/v1", kind: nil, files: [], title: id,
                 sections: ["Report": report], url: URL(fileURLWithPath: "/data/tasks/\(id).md"))
    }

    func testTheReportBaselineIsTakenWhenTheCardNeedsAFixAndForgottenWhenItLeaves() {
        var tracker = FixReportTracker()
        tracker.note([fixCard(.needsFix, report: "Old report.")])
        XCTAssertFalse(tracker.changed(fixCard(.needsFix, report: "Old report.")))
        XCTAssertTrue(tracker.changed(fixCard(.needsFix, report: "New report.")))
        XCTAssertFalse(tracker.changed(fixCard(.needsFix, report: "Old report.  \n")), "whitespace is not a change")
        tracker.note([fixCard(.needsFix, report: "New report.")])
        XCTAssertTrue(tracker.changed(fixCard(.needsFix, report: "New report.")), "the baseline stays the one from the first look")
        tracker.note([fixCard(.review, report: "New report.")])
        XCTAssertFalse(tracker.changed(fixCard(.needsFix, report: "Newer.")), "a card that left needs-fix starts again")
    }

    func testAWorkingAgentIsWorking() {
        XCTAssertEqual(phase(agent: .working), .working)
        XCTAssertEqual(phase(agent: .working, begun: false), .working)
    }

    func testIdleRightAfterTheStartIsStartingNotFinished() {
        XCTAssertEqual(phase(agent: .idle, begun: false), .starting)
        XCTAssertEqual(phase(agent: .idle, begun: false, report: true), .starting)
    }

    func testFinishedAndIdleAreToldApartByTheReport() {
        XCTAssertEqual(phase(agent: .idle, report: true), .finished)
        XCTAssertEqual(phase(agent: .done, report: true), .finished)
        XCTAssertEqual(phase(agent: .idle, report: false), .idle)
        XCTAssertEqual(phase(agent: .done, report: false), .idle)
    }

    func testADoneAgentHasBegunEvenWithoutAnyRecordedTurn() {
        XCTAssertEqual(phase(agent: .done, begun: false, report: true), .finished)
    }

    func testAQuestionForYouWinsOverEverythingElse() {
        XCTAssertEqual(phase(agent: .blocked, waiting: 1), .waitingForYou)
        XCTAssertEqual(phase(agent: .idle, report: true, waiting: 2), .waitingForYou)
        XCTAssertEqual(phase(agent: .working, waiting: 1), .waitingForYou)
    }

    func testThePMDecidingIsPMHandling() {
        XCTAssertEqual(phase(agent: .blocked, pm: true), .pmHandling)
        XCTAssertEqual(phase(agent: .idle, report: true, pm: true), .pmHandling)
    }

    func testABlockedAgentWithoutAReadableQuestionIsBlocked() {
        XCTAssertEqual(phase(agent: .blocked), .blocked)
        XCTAssertEqual(phase(.blocked, agent: nil), .blocked)
    }

    func testADismissedQuestionIsIdleNotFinished() {
        XCTAssertEqual(phase(agent: .idle, report: true, quiet: 1), .idle)
    }

    func testReviewAndNeedsFixComeFromTheCardStatus() {
        XCTAssertEqual(phase(.review, agent: .idle, report: true), .inReview)
        XCTAssertEqual(phase(.review, agent: nil), .inReview)
        XCTAssertEqual(phase(.needsFix, agent: .idle, report: true), .needsFix)
        XCTAssertEqual(phase(.needsFix, agent: nil), .needsFix)
    }

    func testNeedsFixStillShowsALiveQuestionOrWork() {
        XCTAssertEqual(phase(.needsFix, agent: .blocked, waiting: 1), .waitingForYou)
        XCTAssertEqual(phase(.needsFix, agent: .working), .working)
    }

    func testADoingTaskWithoutAnAgentIsIdle() {
        XCTAssertEqual(phase(agent: nil), .idle)
    }

    func testOtherStatusesHaveNoPhase() {
        for s in [TaskStatus.todo, .awaitingStartApproval, .done, .cancelled] { XCTAssertNil(phase(s, agent: .idle, report: true), "\(s)") }
    }

    func testOnlyWaitingForYouIsOrange() {
        let orange = TaskPhase.allCases.filter { $0.tone == .orange }
        XCTAssertEqual(orange, [.waitingForYou])
        XCTAssertEqual(TaskPhase.pmHandling.tone, .blue)
        XCTAssertEqual(TaskPhase.finished.tone, .green)
        XCTAssertEqual(TaskPhase.idle.tone, .grey)
    }

    func testEveryPhaseHasALabelAndAHelpText() {
        for p in TaskPhase.allCases { XCTAssertFalse(p.label.isEmpty); XCTAssertGreaterThan(p.help.count, 15, "\(p)") }
        XCTAssertEqual(Set(TaskPhase.allCases.map(\.label)).count, TaskPhase.allCases.count)
        XCTAssertFalse(TaskPhase.allCases.map(\.label).contains("agent finished"))
    }

    // MARK: the turn tracker

    private func agent(_ state: AgentState, seq: Int? = nil, session: String? = "s1") -> AgentStatus {
        AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: state, cwd: "/r/.agent-worktrees/t", title: "t", sessionID: session, changeSeq: seq)
    }

    func testATurnHasBegunOnceTheAgentWasSeenWorking() {
        var t = TurnTracker()
        t.note([agent(.idle)], hasReply: { _ in false })
        XCTAssertFalse(t.begun(agent(.idle)))
        t.note([agent(.working)], hasReply: { _ in false })
        XCTAssertTrue(t.begun(agent(.idle)))
    }

    func testATurnHasBegunWhenTheTranscriptHasAReply() {
        var t = TurnTracker()
        t.note([agent(.idle)], hasReply: { _ in true })
        XCTAssertTrue(t.begun(agent(.idle)))
    }

    func testANewSessionInTheSamePaneStartsAgain() {
        var t = TurnTracker()
        t.note([agent(.working)], hasReply: { _ in false })
        XCTAssertFalse(t.begun(agent(.idle, session: "s2")))
    }

    // MARK: snapshot

    @MainActor func testSnapshotOfTheTaskListAndTheAgentsColumnShowsSeveralPhases() throws {
        func card(_ id: String, _ status: TaskStatus) -> TaskCard {
            TaskCard(id: id, project: "d", status: status, agent: "dev-\(id.lowercased())", branch: "t/\(id.lowercased())", kind: nil, files: [], title: "Task \(id)", sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        }
        let rows: [(TaskCard, TaskPhase)] = [(card("A1", .doing), .starting), (card("A2", .doing), .working), (card("A3", .doing), .waitingForYou),
                                             (card("A4", .doing), .pmHandling), (card("A5", .doing), .finished), (card("A6", .doing), .idle),
                                             (card("A7", .blocked), .blocked), (card("A8", .review), .inReview), (card("A9", .needsFix), .needsFix)]
        let view = HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) { ForEach(rows, id: \.0.id) { RoundRow(card: $0.0, selected: false, state: TaskGrouping.rowState($0.0, phase: $0.1, dependency: .clear, startedAt: nil, now: Date())) {} } }.frame(width: 360)
            VStack(spacing: 6) { ForEach(rows, id: \.0.id) { AgentCard(agent: AgentStatus(paneID: "w\($0.0.id):p1", workspaceID: "w", state: .working, cwd: "/r", title: "dev-\($0.0.id)"), label: "dev · \($0.0.id)", phase: $0.1) } }
                .padding(8).frame(width: 300)
        }
        .background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 660, height: 560)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_PHASE_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }
}
