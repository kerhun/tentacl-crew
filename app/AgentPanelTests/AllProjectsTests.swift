import XCTest
@testable import AgentPanel

/// The panel watches every project, not only the selected one (N35): questions, autopilot, the menu count and notifications.
@MainActor
final class AllProjectsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var dir: TempDir!
    private var reader: AgentInboxTests.FakeReader!
    private var sender: AutopilotModelTests.Sender!
    private let terminal = AgentList()

    private final class AgentList: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AgentStatus] = []
        var agents: [AgentStatus] { get { lock.withLock { list } } set { lock.withLock { list = newValue } } }
    }

    override func setUpWithError() throws { dir = try TempDir(); reader = AgentInboxTests.FakeReader(); sender = AutopilotModelTests.Sender() }

    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }

    private final class Notes: NotificationSending, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AppNotification] = []
        var sent: [AppNotification] { lock.withLock { items } }
        func requestAuthorization() async -> Bool { true }
        func send(_ notification: AppNotification) async { lock.withLock { items.append(notification) } }
    }

    private func agentB(_ state: AgentState = .blocked) -> AgentStatus {
        var a = AgentStatus(paneID: "w2:p1", workspaceID: "w2", state: state, cwd: "/repoB/.agent-worktrees/test-b1", title: "t", sessionID: "s2"); a.changeSeq = 1; a.name = "dev-b1"
        return a
    }

    /// Project "a" is selected and has no agents; project "b" has a running task whose agent is blocked on a menu.
    private func panel(modeB: AutopilotMode, notes: Notes = Notes(), decider: AutopilotModelTests.Decider? = nil) throws -> PanelModel {
        func project(_ id: String, _ repo: String) throws -> URL {
            try dir.write("\(id)/project.json", "{\"id\":\"\(id)\",\"name\":\"Project \(id.uppercased())\",\"repoPath\":\"\(repo)\",\"dataDir\":\"\(dir.url.appendingPathComponent("data-\(id)").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        }
        let a = try project("a", "/repoA"), b = try project("b", "/repoB")
        _ = try dir.write("data-a/tasks/A1.md", "---\nid: A1\nproject: a\nstatus: todo\nfiles:\n  - x\n---\n# A1\n")
        _ = try dir.write("data-b/tasks/B1.md", "---\nid: B1\nproject: b\nstatus: doing\nagent: dev-b1\nbranch: test/b1\nfiles:\n  - x\n---\n# B1\n## Goal\nPick green.\n")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(a.path)\",\"\(b.path)\"]}")
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var off = AutopilotPolicy(); off.mode = .off
        try store.save(off, for: "a")
        var onB = AutopilotPolicy(); onB.mode = modeB
        try store.save(onB, for: "b")
        terminal.agents = [agentB()]
        let list = terminal, r = reader!, s = sender!
        let iso = TestIsolation(dir, owner: self)
        let decider = decider ?? AutopilotModelTests.Decider(.success(PMReply(decision: PMDecision(verdict: .answer, option: 2, text: nil, why: "Card picks green.", confidence: .high), costUSD: 0.01)))
        return PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(list.agents)) }, opener: RecordingOpener(),
                          makeCommander: { s }, log: iso.log, defaults: iso.defaults,
                          roleStore: iso.roleStore, makeReader: { r }, makeKeySender: { s },
                          autopilotStore: store, makeDecider: { _ in decider }, notifications: notes, isWindowFocused: { false })
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAQuestionInAnotherProjectIsFoundAndCountedInTheMenu() async throws {
        reader.screens["w2:p1"] = try fixture("choice-before.txt")
        let m = try panel(modeB: .shadow)
        await m.reload()
        XCTAssertEqual(m.selectedProjectID, "a")
        XCTAssertEqual(m.inbox.questions, [], "the selected project has none")
        await settle { m.waitingCount(forProject: "b") == 1 }
        XCTAssertEqual(m.waitingCount(forProject: "b"), 1)
        XCTAssertEqual(m.waitingCount(forProject: "a"), 0)
    }

    func testAnotherProjectsAutopilotAnswersWithItsOwnPolicy() async throws {
        reader.screens["w2:p1"] = try fixture("choice-before.txt")
        let m = try panel(modeB: .on)
        await m.reload()
        await settle { !self.sender.keys.isEmpty }
        XCTAssertEqual(sender.keys, [["2"]], "project b is on, so its PM answered")
        XCTAssertEqual(m.selectedProjectID, "a")
        XCTAssertEqual(m.autopilot.policy.mode, .off, "the selected project keeps its own policy")
    }

    func testAProjectWhoseAutopilotIsOffIsNotAnswered() async throws {
        reader.screens["w2:p1"] = try fixture("choice-before.txt")
        let m = try panel(modeB: .off)
        await m.reload()
        XCTAssertEqual(m.waitingCount(forProject: "b"), 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sender.keys, [])
    }

    func testSwitchingProjectsKeepsEachProjectsState() async throws {
        reader.screens["w2:p1"] = try fixture("choice-before.txt")
        let m = try panel(modeB: .shadow)
        await m.reload()
        await settle { m.waitingCount(forProject: "b") == 1 }
        let reads = reader.reads
        await m.selectProject("b")
        XCTAssertEqual(m.inbox.questions.count, 1)
        XCTAssertEqual(m.autopilot.policy.mode, .shadow)
        await m.selectProject("a")
        XCTAssertEqual(m.inbox.questions, [])
        XCTAssertEqual(m.autopilot.policy.mode, .off)
        await m.selectProject("b")
        XCTAssertEqual(m.inbox.questions.count, 1)
        XCTAssertEqual(reader.reads, reads, "switching does not read the screen again")
    }

    func testANotificationNamesTheProjectAndCarriesItsId() async throws {
        let notes = Notes()
        let m = try panel(modeB: .off, notes: notes)
        await m.setNotifications(true)
        terminal.agents = [agentB(.working)]
        await m.reload()  // the first look only records
        reader.screens["w2:p1"] = try fixture("choice-before.txt")
        var blocked = agentB(); blocked.changeSeq = 2
        terminal.agents = [blocked]
        await m.refreshAgents()
        let note = try XCTUnwrap(notes.sent.first)
        XCTAssertEqual(notes.sent.count, 1)
        XCTAssertEqual(note.projectID, "b")
        XCTAssertTrue(note.title.contains("Project B"), note.title)
        XCTAssertEqual(note.cardID, "B1")
    }

    func testClickingANotificationSwitchesToItsProjectAndSelectsTheCard() async throws {
        let m = try panel(modeB: .off)
        await m.reload()
        XCTAssertEqual(m.selectedProjectID, "a")
        await m.open(projectID: "b", cardID: "B1")
        XCTAssertEqual(m.selectedProjectID, "b")
        XCTAssertEqual(m.selectedCardID, "B1")
    }
}
