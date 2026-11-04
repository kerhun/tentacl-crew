import SwiftUI
import XCTest
@testable import AgentPanel

/// The Agents pane's compact rows (design A, N283): status chip, display name, header line. Snapshots → tasks/assets/N283-*.png.
@MainActor
final class AgentsPaneTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, _ status: TaskStatus, _ title: String, agent: String) -> TaskCard {
        TaskCard(id: id, project: "d", status: status, agent: agent, branch: "task/\(id.lowercased())", kind: nil, files: [], title: "\(id) · \(title)", sections: [:],
                 url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func summary(_ status: TaskStatus = .doing, phase: TaskPhase?, stopped: Bool = false) -> AgentSummary {
        .make(card: card("N1", status, "A", agent: "dev-n1"), phase: phase, lastAction: nil, fallback: "", startedAt: nil, cost: nil,
              stoppedSince: stopped ? t0 - 600 : nil, now: t0)
    }

    private func agent(_ id: String, _ state: AgentState, title: String? = nil) -> AgentStatus {
        AgentStatus(paneID: "w\(id):p1", workspaceID: "w\(id)", state: state, cwd: "/r/\(id)", title: title ?? "dev-\(id.lowercased())")
    }

    func testTheStatusChipOfACardAgent() {
        XCTAssertEqual(AgentRowStatus.of(summary(phase: .working)), .working)
        XCTAssertEqual(AgentRowStatus.of(summary(phase: .starting)), .working)
        XCTAssertEqual(AgentRowStatus.of(summary(phase: .waitingForYou)), .waitingForYou)
        XCTAssertEqual(AgentRowStatus.of(summary(phase: .blocked)), .waitingForYou)
        XCTAssertEqual(AgentRowStatus.of(summary(.needsFix, phase: .working)), .fixing)
        XCTAssertEqual(AgentRowStatus.of(summary(.needsFix, phase: .waitingForYou)), .waitingForYou, "a fixing agent that asks waits for you")
        for phase: TaskPhase? in [.idle, .finished, .inReview, .pmHandling, nil] { XCTAssertEqual(AgentRowStatus.of(summary(phase: phase)), .idle, "\(String(describing: phase))") }
        XCTAssertEqual(AgentRowStatus.of(summary(phase: .idle, stopped: true)), .stopped)
    }

    func testTheStatusChipOfAnAgentOnNoCardAndTheLabels() {
        XCTAssertEqual(AgentRowStatus.of(AgentState.working), .working)
        XCTAssertEqual(AgentRowStatus.of(AgentState.blocked), .waitingForYou)
        XCTAssertEqual([AgentState.idle, .done, .unknown("?")].map(AgentRowStatus.of), [.idle, .idle, .idle])
        XCTAssertEqual(AgentRowStatus.allCases.map(\.label), ["Working", "Waiting for you", "Fixing", "Idle", "Asleep", "Stopped"])
    }

    func testTheProgressLineFillsUpToTheCurrentStep() {
        XCTAssertEqual(AgentRowStatus.fraction(StepProgress(current: .start, state: .working)), 1.0 / 6, accuracy: 0.001)
        XCTAssertEqual(AgentRowStatus.fraction(StepProgress(current: .merge, state: .working)), 1, accuracy: 0.001)
    }

    func testTheDisplayNameElseTheRoleCapitalised() {
        XCTAssertEqual(AgentRowName.make(role: "dev", displayNames: ["dev": "EGE"]), AgentRowName(name: "EGE", role: "dev"))
        XCTAssertEqual(AgentRowName.make(role: "ui_dev", displayNames: [:]), AgentRowName(name: "Ui_dev", role: "ui_dev"))
        XCTAssertEqual(AgentRowName.make(role: "reviewer", displayNames: ["reviewer": "  "]).name, "Reviewer", "a blank display name counts as none")
        XCTAssertEqual(AgentRowName(name: "ege", role: "dev").initial, "E")
        XCTAssertEqual(AgentRowName.role(ofAgent: "dev-n280-agent-panel"), "dev")
        XCTAssertNil(AgentRowName.role(ofAgent: "pm"))
    }

    func testTheHeaderCountsRunningAgentsAndThoseWaitingForYou() {
        XCTAssertEqual(AgentsPane.headerLine(running: 4, waiting: 1), "4 running · 1 waiting for you")
        XCTAssertEqual(AgentsPane.headerLine(running: 2, waiting: 0), "2 running")
        let asks = agent("N2", .blocked), works = agent("N3", .working), pm = agent("P", .blocked, title: "pm")
        let summaries = ["wN2:p1": summary(phase: .waitingForYou), "wN3:p1": summary(phase: .working)]
        let pane = AgentsPane(state: .available([works, asks, pm]), cards: AgentCardSource(summary: { summaries[$0.paneID] }, select: { _ in }, nudge: { _ in }, isNudging: { _ in false }),
                              isPM: { $0.paneID == pm.paneID })
        XCTAssertEqual(pane.headerLine(), "3 running · 2 waiting for you")
        XCTAssertEqual(pane.rowAgents.map(\.paneID), ["wP:p1", "wN3:p1", "wN2:p1"], "the PM first")
        XCTAssertNil(AgentsPane(state: .loading).headerLine())
        XCTAssertNil(AgentsPane(state: .unavailable("down")).headerLine())
    }

    func testOnlyTheGivenActionsAreOnARow() {
        let a = agent("N1", .idle)
        var pane = AgentsPane(state: .available([a]))
        XCTAssertEqual(pane.actions(a, onCard: true).map(\.title), [])
        pane.onOpenTerminal = { _ in }
        pane.onSleep = { _ in }
        pane.sleepWhy = { _ in "It is working" }
        pane.onStop = { _ in }
        pane.canStop = { _ in true }
        XCTAssertEqual(pane.actions(a, onCard: true).map(\.title), ["Terminal", "Sleep", "Stop"])
        XCTAssertEqual(pane.actions(a, onCard: true).map(\.disabled), [false, true, false])
        XCTAssertEqual(pane.actions(a, onCard: false).map(\.title), ["Terminal", "Stop"], "no Sleep for an agent on no card")
    }

    // MARK: snapshots

    private let names = ["pm": "IBRAHIM", "dev": "EGE", "ui_dev": "BEDO", "reviewer": "UMUT"]
    private let tints = ["dev": 0, "pm": 1, "reviewer": 2, "ui_dev": 3]

    private func pane(_ rows: [(AgentStatus, AgentSummary?)], sleeping: [SleepingAgent] = []) -> some View {
        let summaries = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.1.map { (row.0.paneID, $0) } })
        let pm = rows.first { $0.0.title == "pm" }?.0.paneID
        return AgentsPane(state: .available(rows.map(\.0)), feedOnly: true, cards: AgentCardSource(summary: { summaries[$0.paneID] }, select: { _ in }, nudge: { _ in }, isNudging: { _ in false }),
                          onOpenCard: { _ in }, statusLine: { _ in "Reviewing N281" }, sleeping: sleeping, onWake: { _ in }, displayNames: names,
                          roleTint: { [tints] in RosterView.tint(tints[$0]) }, isPM: { $0.paneID == pm }, onOpenTerminals: {})
            .frame(width: 380).preferredColorScheme(.dark)
    }

    private func write(_ view: some View, _ size: CGSize, _ name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        XCTAssertGreaterThan(data.count, 5_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    private func make(_ c: TaskCard, _ phase: TaskPhase, stopped: Bool = false) -> AgentSummary {
        .make(card: c, phase: phase, lastAction: "Edit", fallback: "", startedAt: nil, cost: nil, stoppedSince: stopped ? t0 - 12 * 60 : nil, now: t0)
    }

    func testSnapshotOfThePMAndThreeAgentsAndOneAsleep() throws {
        let rows: [(AgentStatus, AgentSummary?)] = [
            (agent("P", .working, title: "pm"), nil),
            (agent("N280", .working), make(card("N280", .doing, "PM key in the environment", agent: "dev-n280-agent-panel"), .working)),
            (agent("N281", .blocked), make(card("N281", .doing, "Activity colours", agent: "ui_dev-n281-agent-panel"), .waitingForYou)),
            (agent("N282", .working), make(card("N282", .needsFix, "Remove Agent screen tab", agent: "dev-n282-agent-panel"), .working)),
        ]
        try write(pane(rows, sleeping: [SleepingAgent(cardID: "N279", title: "N279 · Sleep agents", agent: "reviewer-n279-agent-panel")]),
                  CGSize(width: 380, height: 420), "N283-agents.png")
    }

    func testSnapshotOfAStoppedAgent() throws {
        let rows: [(AgentStatus, AgentSummary?)] = [
            (agent("P", .idle, title: "pm"), nil),
            (agent("N285", .idle), make(card("N285", .doing, "Error analysis", agent: "dev-n285-agent-panel"), .idle, stopped: true)),
            (agent("N280", .working), make(card("N280", .doing, "PM key in the environment", agent: "dev-n280-agent-panel"), .working)),
        ]
        try write(pane(rows), CGSize(width: 380, height: 340), "N283-agents-stopped.png")
    }

    func testSnapshotOfHoveredRows() throws {
        let s = make(card("N280", .doing, "PM key in the environment", agent: "dev-n280-agent-panel"), .working)
        let view = VStack(spacing: 6) {
            AgentRow(name: .make(role: "pm", displayNames: names), task: "Reviewing N281", status: .working, tint: RosterView.tint(1),
                     actions: [.init(title: "Terminal", help: "") {}, .init(title: "Stop", help: "") {}], hovering: true)
            AgentRow(name: .make(role: "dev", displayNames: names), task: "N280 · \(s.title)", status: .of(s), tint: RosterView.tint(0),
                     progress: s.progress.map(AgentRowStatus.fraction), onOpen: {},
                     actions: [.init(title: "Terminal", help: "") {}, .init(title: "Sleep", help: "", disabled: true) {}, .init(title: "Stop", help: "") {}], hovering: true)
            AgentRow(name: .make(role: "reviewer", displayNames: names), task: "N279 · Sleep agents", status: .asleep, tint: RosterView.tint(2),
                     actions: [.init(title: "Wake", help: "") {}], hovering: true)
        }
        .padding(12).frame(width: 380, height: 230, alignment: .top).background(Tok.pane).preferredColorScheme(.dark)
        try write(view, CGSize(width: 380, height: 230), "N283-agents-hover.png")
    }
}
