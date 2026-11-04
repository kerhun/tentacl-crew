import SwiftUI
import XCTest
@testable import AgentPanel

final class AgentSummaryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String = "N98", _ status: TaskStatus = .doing, title: String = "Agent cards", report: String = "") -> TaskCard {
        TaskCard(id: id, project: "d", status: status, agent: nil, branch: "task/\(id.lowercased())", kind: nil, files: [], title: title,
                 sections: report.isEmpty ? [:] : ["Report": report], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func input(_ status: TaskStatus = .doing, agent: AgentState = .idle, hasReport: Bool = false, changed: Bool = false, waiting: Int = 0, pm: Bool = false) -> StoppedInput {
        StoppedInput(status: status, agent: agent, hasReport: hasReport, reportChangedSinceFix: changed, waiting: waiting, pmHandling: pm)
    }

    // MARK: the step bar

    func testTheStepFollowsThePhase() {
        XCTAssertEqual(StepProgress.of(status: .doing, phase: .starting), StepProgress(current: .start, state: .working))
        XCTAssertEqual(StepProgress.of(status: .doing, phase: .working), StepProgress(current: .work, state: .working))
        XCTAssertEqual(StepProgress.of(status: .doing, phase: .waitingForYou), StepProgress(current: .work, state: .waiting))
        XCTAssertEqual(StepProgress.of(status: .doing, phase: .pmHandling), StepProgress(current: .work, state: .waiting))
        XCTAssertEqual(StepProgress.of(status: .doing, phase: .idle), StepProgress(current: .work, state: .waiting))
        XCTAssertEqual(StepProgress.of(status: .doing, phase: .finished), StepProgress(current: .report, state: .waiting))
        XCTAssertEqual(StepProgress.of(status: .review, phase: .inReview), StepProgress(current: .review, state: .waiting))
    }

    func testANeedsFixCardIsFixingAtThePacketStepUntilItWaits() {
        XCTAssertEqual(StepProgress.of(status: .needsFix, phase: .working), StepProgress(current: .packet, state: .fixing))
        XCTAssertEqual(StepProgress.of(status: .needsFix, phase: .needsFix), StepProgress(current: .packet, state: .fixing))
        XCTAssertEqual(StepProgress.of(status: .needsFix, phase: .waitingForYou), StepProgress(current: .packet, state: .waiting))
        XCTAssertEqual(StepProgress.of(status: .needsFix, phase: .finished), StepProgress(current: .packet, state: .waiting))
    }

    func testCardsThatAreNotRunningHaveNoBar() {
        XCTAssertNil(StepProgress.of(status: .todo, phase: nil))
        XCTAssertNil(StepProgress.of(status: .doing, phase: nil))
        XCTAssertEqual(TaskStep.allCases.map(\.label), ["start", "work", "report", "packet", "review", "merge"])
    }

    // MARK: the last action line

    func testTheLastActionIsOneTrimmedLine() {
        XCTAssertEqual(AgentSummary.oneLine("  First\n\n  Running scripts/app-test.sh   (run 2)…  \n"), "Running scripts/app-test.sh (run 2)…")
        XCTAssertEqual(AgentSummary.oneLine(" \n "), "")
    }

    func testTheTitleDropsTheCardIDItStartsWith() {
        XCTAssertEqual(AgentSummary.plainTitle("N98 · Agent cards", id: "N98"), "Agent cards")
        XCTAssertEqual(AgentSummary.plainTitle("Agent cards", id: "N98"), "Agent cards")
        XCTAssertEqual(AgentSummary.plainTitle("N98", id: "N98"), "N98")
    }

    func testTheSummaryUsesTheTranscriptLineElseTheFallback() {
        let a = AgentSummary.make(card: card(), phase: .working, lastAction: "Edit Views/AgentsPane.swift\n", fallback: "working · w/n98", startedAt: t0, cost: 0.84, stoppedSince: nil, now: t0 + 18 * 60)
        XCTAssertEqual(a.cardID, "N98")
        XCTAssertEqual(a.title, "Agent cards")
        XCTAssertEqual(a.lastAction, "Edit Views/AgentsPane.swift")
        XCTAssertEqual(a.progress, StepProgress(current: .work, state: .working))
        XCTAssertEqual(a.metaParts, ["Working", "18 min", "≈ $0.84"])
        let b = AgentSummary.make(card: card(), phase: .working, lastAction: nil, fallback: "working · w/n98", startedAt: nil, cost: nil, stoppedSince: nil, now: t0)
        XCTAssertEqual(b.lastAction, "working · w/n98")
        XCTAssertEqual(b.metaParts, ["Working"], "an unknown start time and cost are left out, not shown as 0")
    }

    func testANeedsFixCardThatIsWorkedOnSaysFixing() {
        let a = AgentSummary.make(card: card("N95", .needsFix), phase: .working, lastAction: "x", fallback: "", startedAt: nil, cost: nil, stoppedSince: nil, now: t0)
        XCTAssertEqual(a.metaParts, ["Fixing"])
    }

    func testAStoppedSummarySaysSinceWhenAndWhy() {
        let a = AgentSummary.make(card: card(), phase: .idle, lastAction: nil, fallback: "idle", startedAt: t0, cost: nil, stoppedSince: t0, now: t0 + 12 * 60)
        XCTAssertEqual(a.warning, "Stopped 12 min ago with an empty Report.")
        let b = AgentSummary.make(card: card("N98", .needsFix, report: "old"), phase: .needsFix, lastAction: nil, fallback: "idle", startedAt: t0, cost: nil, stoppedSince: t0, now: t0 + 6 * 60)
        XCTAssertEqual(b.warning, "Stopped 6 min ago; the Report is unchanged since the fix request.")
        XCTAssertNil(AgentSummary.make(card: card(), phase: .working, lastAction: nil, fallback: "", startedAt: nil, cost: nil, stoppedSince: nil, now: t0).warning)
    }

    // MARK: the stopped rule

    func testAnIdleOrDoneAgentWithAnEmptyReportLooksStopped() {
        XCTAssertTrue(StoppedInput.looksStopped(input(agent: .idle)))
        XCTAssertTrue(StoppedInput.looksStopped(input(agent: .done)))
        XCTAssertFalse(StoppedInput.looksStopped(input(agent: .idle, hasReport: true)), "a Report means it finished")
    }

    func testAWorkingOrAskingAgentNeverLooksStopped() {
        XCTAssertFalse(StoppedInput.looksStopped(input(agent: .working)))
        XCTAssertFalse(StoppedInput.looksStopped(input(agent: .blocked)), "a menu on screen")
        XCTAssertFalse(StoppedInput.looksStopped(input(agent: .idle, waiting: 1)), "a question waits for the user")
        XCTAssertFalse(StoppedInput.looksStopped(input(agent: .idle, pm: true)), "the PM is deciding")
        XCTAssertFalse(StoppedInput.looksStopped(input(agent: .unknown("odd"))))
    }

    func testOnlyDoingAndNeedsFixCardsCanLookStopped() {
        for status in [TaskStatus.review, .todo, .done, .blocked, .awaitingStartApproval] { XCTAssertFalse(StoppedInput.looksStopped(input(status)), "\(status)") }
    }

    func testANeedsFixCardLooksStoppedWhileItsReportIsUnchanged() {
        XCTAssertTrue(StoppedInput.looksStopped(input(.needsFix, hasReport: true, changed: false)))
        XCTAssertFalse(StoppedInput.looksStopped(input(.needsFix, hasReport: true, changed: true)))
    }

    func testStoppedOnlyAfterFiveMinutesInARow() {
        var t = StoppedTracker()
        t.note(["k"], now: t0)
        XCTAssertNil(t.stoppedSince("k", now: t0 + 299))
        t.note(["k"], now: t0 + 299)
        XCTAssertEqual(t.stoppedSince("k", now: t0 + 300), t0)
        XCTAssertEqual(t.stopped(now: t0 + 300), ["k": t0])
    }

    func testWorkingAgainStartsTheClockAgain() {
        var t = StoppedTracker()
        t.note(["k"], now: t0)
        t.note([], now: t0 + 200)
        t.note(["k"], now: t0 + 250)
        XCTAssertNil(t.stoppedSince("k", now: t0 + 400))
        XCTAssertEqual(t.stoppedSince("k", now: t0 + 550), t0 + 250)
    }

    func testANudgeStartsTheClockAgain() {
        var t = StoppedTracker()
        t.note(["k"], now: t0)
        t.reset("k", now: t0 + 600)
        XCTAssertNil(t.stoppedSince("k", now: t0 + 601))
        t.note(["k"], now: t0 + 700)
        XCTAssertNil(t.stoppedSince("k", now: t0 + 800), "still idle right after the nudge: not stopped again before 5 more minutes")
        XCTAssertEqual(t.stoppedSince("k", now: t0 + 900), t0 + 600)
    }

    func testTheStartTimeIsTheLatestStartOfTheCard() {
        let log = """
        2026-10-18T10:00:00Z [demo] start N98 agent=ui_dev-n98 branch=task/n98 pane=w1:p1
        2026-10-18T11:00:00Z [other] start N98 agent=x branch=task/n98 pane=w2:p1
        2026-10-18T12:00:00Z [demo] start N98 agent=ui_dev-n98 branch=task/n98 pane=w3:p1
        2026-10-18T12:30:00Z [demo] start N98 FAILED: nope
        """
        let events = ActionLogEvents.parse(log)
        XCTAssertEqual(AgentSummary.startTime(of: "N98", project: "demo", events: events), ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z"))
        XCTAssertNil(AgentSummary.startTime(of: "N1", project: "demo", events: events))
    }
}

/// The agent cards and the stopped-agent warning, wired into the panel.
@MainActor
final class AgentCardsPanelTests: XCTestCase {
    private var dir: TempDir!
    private var commander: FakeCommander!
    private var terminal: ListTerminal!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    final class ListTerminal: TerminalListing, @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AgentStatus]
        init(_ list: [AgentStatus]) { self.list = list }
        func set(_ list: [AgentStatus]) { lock.lock(); self.list = list; lock.unlock() }
        func agents() async throws -> [AgentStatus] { lock.lock(); defer { lock.unlock() }; return list }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
    }

    override func setUpWithError() throws {
        dir = try TempDir()
        commander = FakeCommander()
        terminal = ListTerminal([])
    }

    private func agent(_ state: AgentState) -> AgentStatus {
        AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: state, cwd: "/repo/.agent-worktrees/task-n98", title: "ui_dev-n98", sessionID: "s1")
    }

    private func panel(status: String = "doing") throws -> PanelModel {
        try dir.write("data/tasks/N98.md", "---\nid: N98\nproject: demo\nstatus: \(status)\nagent: ui_dev-n98\nbranch: task/n98\nfiles:\n  - a\n---\n# N98 · Agent cards\n\n## Report\n")
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")
        let iso = TestIsolation(folder: dir.url, owner: self)
        let h = terminal!, c = commander!
        let m = PanelModel(settingsURL: settings, makeTerminal: { h }, opener: RecordingOpener(), makeCommander: { c }, log: iso.log, defaults: iso.defaults,
                           roleStore: iso.roleStore, makeReader: { AgentInboxTests.FakeReader() }, makeKeySender: { AgentInboxTests.FakeSender() })
        m.claudeProjectsRoot = dir.url.appendingPathComponent("claude-projects")
        m.now = { [unowned self] in clock }
        return m
    }

    func testAnAgentOnACardGetsItsSummary() async throws {
        terminal.set([agent(.working)])
        let m = try panel()
        await m.reload()
        let s = try XCTUnwrap(m.agentSummary(agent(.working)))
        XCTAssertEqual(s.cardID, "N98")
        XCTAssertEqual(s.title, "Agent cards")
        XCTAssertEqual(s.progress, StepProgress(current: .work, state: .working))
        XCTAssertNil(m.agentSummary(AgentStatus(paneID: "w9:p1", workspaceID: "w9", state: .idle, cwd: "/elsewhere", title: "PM")))
    }

    func testClickingACardOpensItsPaneOnTerminals() async throws {
        terminal.set([agent(.working)])
        let m = try panel()
        await m.reload()
        m.agentCards.select(agent(.working))
        XCTAssertEqual(m.terminalFocus?.pane, agent(.working).paneID)
    }

    func testAgentPaneOfACard() async throws {
        terminal.set([agent(.working)])
        let m = try panel()
        await m.reload()
        XCTAssertEqual(m.agentPane(of: try XCTUnwrap(m.card(id: "N98"))), agent(.working).paneID)
        terminal.set([])
        await m.refreshAgents()
        XCTAssertNil(m.agentPane(of: try XCTUnwrap(m.card(id: "N98"))), "no agent runs: nothing to open")
    }

    func testAnIdleAgentWithAnEmptyReportIsStoppedAfterFiveMinutes() async throws {
        terminal.set([agent(.idle)])
        let m = try panel()
        await m.reload()
        XCTAssertNil(m.agentSummary(agent(.idle))?.warning)
        clock += 299; await m.refreshAgents()
        XCTAssertNil(m.agentSummary(agent(.idle))?.warning)
        clock += 1; await m.refreshAgents()
        XCTAssertEqual(m.agentSummary(agent(.idle))?.warning, "Stopped 5 min ago with an empty Report.")
        XCTAssertEqual(m.stuckAgents.map(\.cardID), ["N98"])
    }

    func testAWorkingAgentIsNeverStopped() async throws {
        terminal.set([agent(.working)])
        let m = try panel()
        await m.reload()
        clock += 3600; await m.refreshAgents()
        XCTAssertNil(m.agentSummary(agent(.working))?.warning)
        terminal.set([agent(.blocked)])
        clock += 3600; await m.refreshAgents()
        clock += 3600; await m.refreshAgents()
        XCTAssertNil(m.agentSummary(agent(.blocked))?.warning, "waiting at a menu")
    }

    func testNudgeSendsThePromptOncePerClickAndStartsTheClockAgain() async throws {
        terminal.set([agent(.idle)])
        let m = try panel()
        await m.reload()
        clock += 600; await m.refreshAgents()
        XCTAssertNotNil(m.agentSummary(agent(.idle))?.warning)
        async let first: Void = m.nudge(agent(.idle))
        async let second: Void = m.nudge(agent(.idle))
        _ = await (first, second)
        XCTAssertEqual(commander.prompts.map(\.text), [PanelModel.nudgeText])
        XCTAssertEqual(commander.prompts.map(\.target), ["w1:p1"])
        XCTAssertNil(m.agentSummary(agent(.idle))?.warning, "the warning goes away after the nudge")
        await m.nudge(agent(.idle))
        XCTAssertEqual(commander.prompts.count, 2, "a second click sends again")
    }
}

@MainActor
final class AgentCardViewTests: XCTestCase {
    /// A click on an agent working on a card opens that card on Tasks; an agent on no card does nothing.
    func testAClickOnAnAgentWithACardOpensThatCardOnTasks() {
        let card = TaskCard(id: "N123", project: "d", status: .doing, agent: nil, branch: "task/n123", kind: nil, files: [], title: "N123 · Thing", sections: [:], url: URL(fileURLWithPath: "/tmp/N123.md"))
        let onCard = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .working, cwd: "/r/n123", title: "dev-n123")
        let pm = AgentStatus(paneID: "w2:p1", workspaceID: "w2", state: .idle, cwd: "/repo", title: "PM")
        let summary = AgentSummary.make(card: card, phase: .working, lastAction: "Edit", fallback: "", startedAt: nil, cost: nil, stoppedSince: nil, now: Date())
        var selected: [String] = [], nudged: [String] = [], opened: [String] = []
        let source = AgentCardSource(summary: { $0.paneID == onCard.paneID ? summary : nil }, select: { selected.append($0.paneID) },
                                     nudge: { nudged.append($0.paneID) }, isNudging: { _ in false })
        let pane = AgentsPane(state: .available([onCard, pm]), cards: source, onOpenCard: { opened.append($0) })
        pane.open(onCard)
        pane.open(pm)
        XCTAssertEqual(opened, ["N123"])
        XCTAssertEqual(selected, [], "the Tasks screen, not its terminal")
        XCTAssertEqual(nudged, [])
        XCTAssertEqual(AgentsPane.openHelp(cardID: "N123"), "Open N123 on Tasks")
    }

    func testWithoutOnOpenCardAClickStillSelectsTheAgent() {
        let agent = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .working, cwd: "/r", title: "dev")
        let card = TaskCard(id: "N1", project: "d", status: .doing, agent: nil, branch: "task/n1", kind: nil, files: [], title: "N1 · A", sections: [:], url: URL(fileURLWithPath: "/tmp/N1.md"))
        let summary = AgentSummary.make(card: card, phase: .working, lastAction: "Edit", fallback: "", startedAt: nil, cost: nil, stoppedSince: nil, now: Date())
        var selected: [String] = []
        let pane = AgentsPane(state: .available([agent]), cards: AgentCardSource(summary: { _ in summary }, select: { selected.append($0.paneID) }, nudge: { _ in }, isNudging: { _ in false }))
        pane.open(agent)
        XCTAssertEqual(selected, ["w1:p1"])
    }

    func testSnapshotOfAHoveredAgentCardThatOpensOnTasks() throws {
        let card = TaskCard(id: "N123", project: "d", status: .doing, agent: nil, branch: "task/n123", kind: nil, files: [], title: "N123 · Dashboard agent click", sections: [:], url: URL(fileURLWithPath: "/tmp/N123.md"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = AgentSummary.make(card: card, phase: .working, lastAction: "Edit Views/AgentsPane.swift", fallback: "", startedAt: t0 - 7 * 60, cost: 0.32, stoppedSince: nil, now: t0)
        let agent = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .working, cwd: "/r/n123", title: "ui_dev-n123")
        let view = VStack(spacing: 8) {
            AgentsPane(state: .available([agent]), cards: AgentCardSource(summary: { _ in summary }, select: { _ in }, nudge: { _ in }, isNudging: { _ in false }), onOpenCard: { _ in })
                .row(agent)
            AgentRow(name: .make(role: summary.role ?? "dev", displayNames: [:]), task: "N123 · Dashboard agent click", status: .of(summary), tint: Tok.work,
                     progress: summary.progress.map(AgentRowStatus.fraction), onOpen: {}, actions: [.init(title: "Terminal", help: "") {}], hovering: true)
        }.padding(12).background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 360, height: 220)))
        XCTAssertGreaterThan(data.count, 5_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("agent-card-hover.png")) }
    }

    func testTheRoleComesFromTheCardsAgentElseItsFirstRole() {
        func card(agent: String?, roles: [String]) -> TaskCard {
            var c = TaskCard(id: "N1", project: "d", status: .doing, agent: agent, branch: "task/n1", kind: nil, files: [], title: "N1 · A", sections: [:], url: URL(fileURLWithPath: "/tmp/N1.md"))
            c.roles = roles
            return c
        }
        func role(_ c: TaskCard) -> String? { AgentSummary.make(card: c, phase: .working, lastAction: nil, fallback: "", startedAt: nil, cost: nil, stoppedSince: nil, now: Date()).role }
        XCTAssertEqual(role(card(agent: "ui_dev-n283-agent-panel", roles: ["dev"])), "ui_dev")
        XCTAssertEqual(role(card(agent: nil, roles: ["reviewer"])), "reviewer")
        XCTAssertNil(role(card(agent: nil, roles: [])))
    }

    func testTheDashboardsAgentsOpenTheirCardThroughOnOpen() {
        var opened: [String] = []
        let pane = DashboardView.agentsPane(PanelModel.isolatedForTests(), onOpen: { opened.append($0) })
        pane.onOpenCard?("N7")
        XCTAssertEqual(opened, ["N7"])
    }

    func testSnapshotOfWorkingFixingAndStoppedAgentCards() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func card(_ id: String, _ status: TaskStatus, _ title: String) -> TaskCard {
            TaskCard(id: id, project: "d", status: status, agent: nil, branch: "task/\(id.lowercased())", kind: nil, files: [], title: "\(id) · \(title)", sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        }
        func agent(_ id: String, _ state: AgentState) -> AgentStatus { AgentStatus(paneID: "w\(id):p1", workspaceID: "w", state: state, cwd: "/r/\(id)", title: "dev-\(id)") }
        let summaries: [String: AgentSummary] = [
            "wN95:p1": .make(card: card("N95", .needsFix, "No merge with an open fix"), phase: .working, lastAction: "Running scripts/app-test.sh (run 2 of 3)…", fallback: "", startedAt: t0 - 18 * 60, cost: 0.84, stoppedSince: nil, now: t0),
            "wN89:p1": .make(card: card("N89", .doing, "Plan screen"), phase: .working, lastAction: "Edit Views/PlanView.swift", fallback: "", startedAt: t0 - 9 * 60, cost: 0.41, stoppedSince: nil, now: t0),
            "wN92:p1": .make(card: card("N92", .doing, "Notification switches"), phase: .waitingForYou, lastAction: nil, fallback: "blocked · tentacl/n92", startedAt: t0 - 3 * 60, cost: nil, stoppedSince: nil, now: t0),
            "wN85:p1": .make(card: card("N85", .doing, "Error analysis"), phase: .idle, lastAction: nil, fallback: "idle", startedAt: t0 - 40 * 60, cost: 1.2, stoppedSince: t0 - 12 * 60, now: t0),
        ]
        let agents = [agent("N95", .working), agent("N89", .working), agent("N92", .blocked), agent("N85", .idle),
                      AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: "/repo", title: "PM")]
        let source = AgentCardSource(summary: { summaries[$0.paneID] }, select: { _ in }, nudge: { _ in }, isNudging: { _ in false })
        // No Open terminal links: ImageRenderer draws link buttons as placeholders.
        let view = AgentsPane(state: .available(agents), cards: source)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 360, height: 700)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("agent-cards.png")) }
    }

    /// N294: the PM's row shows a dot while a PM question is open.
    func testPMRowDotShowsOnlyWhileAskingSnapshot() throws {
        let pm = AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .blocked, cwd: "/repo", title: "PM")
        func render(_ asking: Bool) throws -> Data {
            let view = AgentsPane(state: .available([pm]), isPM: { $0.paneID == pm.paneID }, pmAsking: asking).frame(width: 360, height: 120)
            return try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 360, height: 120)))
        }
        let on = try render(true)
        XCTAssertNotEqual(on, try render(false))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try on.write(to: URL(fileURLWithPath: out).appendingPathComponent("N294-agents.png")) }
    }
}
