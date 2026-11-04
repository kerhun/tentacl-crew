import XCTest
@testable import AgentPanel

@MainActor
final class AgentStatusLineTests: XCTestCase {
    private func ask(_ kind: AgentQuestion.Kind, title: String = "", text: String = "", command: String? = nil) -> AgentQuestion {
        var q = AgentQuestion(kind: kind, title: title, text: text, options: [])
        q.command = command
        return q
    }

    func testSourceOrderIsLiveThenTranscriptThenState() {
        XCTAssertEqual(AgentStatusLine.make(question: nil, live: "Running tests", transcript: "Edit A.swift", state: "working · x"), "Running tests")
        XCTAssertEqual(AgentStatusLine.make(question: nil, live: nil, transcript: "Edit A.swift", state: "working · x"), "Edit A.swift")
        XCTAssertEqual(AgentStatusLine.make(question: nil, live: " \n", transcript: "", state: "working · x"), "working · x")
    }

    func testAWaitingAgentShowsWhatItWaitsFor() {
        XCTAssertEqual(AgentStatusLine.make(question: ask(.choice, title: "Colour", text: "Which colour?"), live: "Running", transcript: "Edit", state: "blocked"), "asks: Colour")
        XCTAssertEqual(AgentStatusLine.make(question: ask(.freeText, text: "What name?"), live: nil, transcript: nil, state: "blocked"), "asks: What name?")
        XCTAssertEqual(AgentStatusLine.make(question: ask(.permission, text: "Do you want to proceed?", command: "npm test\n"), live: nil, transcript: nil, state: "blocked"), "permission: Bash npm test")
        XCTAssertEqual(AgentStatusLine.make(question: ask(.permission, text: "Allow edits to notes.txt?"), live: nil, transcript: nil, state: "blocked"), "permission: Allow edits to notes.txt?")
        XCTAssertEqual(AgentStatusLine.make(question: ask(.plan), live: nil, transcript: nil, state: "blocked"), "approval: plan")
    }

    func testTheLineIsOneShortLine() {
        XCTAssertEqual(AgentStatusLine.make(question: nil, live: "\n  First   line \nsecond", transcript: nil, state: ""), "First line")
        let long = AgentStatusLine.make(question: nil, live: String(repeating: "x", count: 500), transcript: nil, state: "")
        XCTAssertEqual(long.count, AgentStatusLine.limit)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testTheSidebarRowsCarryTheLineButUserShellsNone() {
        let agents = [AgentStatus(paneID: "pm", workspaceID: "pm", state: .working, cwd: "/r", title: "pm"),
                      AgentStatus(paneID: "my-shell-1", workspaceID: "my-shell-1", state: .idle, cwd: "/r", title: "my-shell-1"),
                      AgentStatus(paneID: "other", workspaceID: "other", state: .idle, cwd: "/r", title: "other")]
        let tabs = TerminalTabs.make(agents: agents, pmPane: "pm", card: { _ in nil }, phase: { _ in nil }, questions: [], line: { "line " + $0.paneID })
        XCTAssertEqual(tabs.map(\.statusLine), ["line pm", "line other", ""])
    }

    // MARK: snapshots (AGENT_PANEL_SNAPSHOT_DIR)

    private func save(_ data: Data, _ name: String) throws {
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    private var snapshotAgents: [AgentStatus] {
        [AgentStatus(paneID: "pm", workspaceID: "pm", state: .working, cwd: "/repo", title: "pm"),
         AgentStatus(paneID: "dev-n7", workspaceID: "dev-n7", state: .blocked, cwd: "/repo/.agent-worktrees/task-n7", title: "dev-n7"),
         AgentStatus(paneID: "dev-n8", workspaceID: "dev-n8", state: .idle, cwd: "/repo/.agent-worktrees/task-n8", title: "dev-n8"),
         AgentStatus(paneID: "my-shell-1", workspaceID: "my-shell-1", state: .idle, cwd: "/repo", title: "my-shell-1")]
    }

    private let snapshotLines = ["pm": "Reading tasks/N251.md", "dev-n7": "permission: Bash npm test --watch=false", "dev-n8": "idle · .agent-worktrees/task-n8"]

    func testSnapshotOfTheAgentsPaneWithAWorkingAWaitingAndAnIdleAgent() throws {
        let view = AgentsPane(state: .available(Array(snapshotAgents.dropLast())), statusLine: { [snapshotLines] in snapshotLines[$0.paneID] ?? "" })
        try save(try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 360, height: 320))), "N251-agents-pane.png")
    }

    func testSnapshotOfTheTerminalsSidebarWithStatusLines() throws {
        let tabs = TerminalTabs.make(agents: snapshotAgents, pmPane: "pm", card: { _ in nil }, phase: { _ in nil }, questions: [], line: { [snapshotLines] in snapshotLines[$0.paneID] ?? "" })
        XCTAssertEqual(tabs.last?.statusLine, "")
        let sidebar = TerminalSidebar(tabs: tabs, paneNumbers: [:], focusedTerminal: "pm", collapsed: false, localPages: [],
                                      info: { _ in TerminalAgentInfo(role: "", branch: "", model: "", restart: .init(enabled: false, help: ""), stop: .init(enabled: false, help: ""),
                                                                     onOpenCard: nil, onOpenChanges: nil, onRestart: {}, onStop: {}) },
                                      onPick: { _ in }, onToggle: {}, onDragStart: { _ in }, onOpenPage: { _ in })
        try save(try XCTUnwrap(SnapshotRenderer.render(view: sidebar, size: CGSize(width: TerminalSidebar.width, height: 420))), "N251-terminals-sidebar.png")
    }
}
