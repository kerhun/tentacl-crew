import XCTest
import SwiftUI
@testable import AgentPanel

/// Every project runs, not only the open one (N208): packets, PM notices, requests, the Inbox and the PM hand-off of a project that is not open.
/// Two temporary projects: "a" is open and idle, "b" is closed and has the work.
@MainActor
final class MultiProjectAutopilotTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!
    private var iso: TestIsolation!
    private let terminal = AgentList()

    private final class AgentList: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AgentStatus] = []
        var agents: [AgentStatus] { get { lock.withLock { list } } set { lock.withLock { list = newValue } } }
    }

    override func setUpWithError() throws {
        dir = try TempDir(); scripts = FakeScripts(); commander = FakeCommander(); iso = TestIsolation(dir, owner: self)
    }

    private func card(_ id: String, _ status: String, report: Bool = false) -> String {
        "---\nid: \(id)\nproject: b\nstatus: \(status)\nagent: dev-\(id.lowercased())\nbranch: test/\(id.lowercased())\nfiles:\n  - App/\(id).swift\n---\n# \(id) · Title \(id)\n\n## Goal\nGoal.\n"
            + (report ? "\n## Report\nDone, 0 failures.\n" : "")
    }

    private func agentB(_ state: AgentState, card id: String = "B1") -> AgentStatus {
        var a = AgentStatus(paneID: "w2:p1", workspaceID: "w2", state: state, cwd: "/repoB/.agent-worktrees/test-\(id.lowercased())", title: "t", sessionID: "s2"); a.changeSeq = 1; a.name = "dev-\(id.lowercased())"
        return a
    }

    private var pmB: AgentStatus {
        AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .idle, cwd: "/repoB", title: "pm", sessionID: "pm-b", name: "pm")
    }

    /// Project "a" is open (one todo card); project "b" is closed, with a PM and the cards given. Both autopilots are on; b's hand-off rule is on too.
    private func panel(bCards: [(String, String)], modeB: AutopilotMode = .on, freshB: Bool = false) throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\"}")
        let roles = ",\"roles\":{\"dev\":\"\(dir.url.appendingPathComponent("roles/dev.json").path)\"}"
        func project(_ id: String, _ repo: String) throws -> URL {
            try dir.write("\(id)/project.json", "{\"id\":\"\(id)\",\"name\":\"Project \(id.uppercased())\",\"repoPath\":\"\(repo)\",\"dataDir\":\"\(dir.url.appendingPathComponent("data-\(id)").path)\",\"maxParallel\":3,\"buildCommand\":\"b\",\"sharedFiles\":[],\"openWith\":\"Xcode\"\(roles)}")
        }
        let a = try project("a", "/repoA"), b = try project("b", "/repoB")
        try dir.write("data-a/tasks/A1.md", "---\nid: A1\nproject: a\nstatus: todo\nfiles:\n  - x\n---\n# A1\n")
        for (id, text) in bCards { try dir.write("data-b/tasks/\(id).md", text) }
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(a.path)\",\"\(b.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var pa = AutopilotPolicy(); pa.mode = .on; pa.freshConversation = false
        try store.save(pa, for: "a")
        var pb = AutopilotPolicy(); pb.mode = modeB; pb.freshConversation = freshB
        try store.save(pb, for: "b")
        // The first round of a project always waits for the user's click; b's has been started already.
        iso.defaults.set(true, forKey: RoundModel.firstRoundKey + "b")
        let list = terminal, s = scripts!, c = commander!
        let model = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(list.agents)) }, opener: RecordingOpener(),
                               makeScripts: { _ in s }, makeCommander: { c }, log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore,
                               makeReader: { AgentInboxTests.FakeReader() }, makeKeySender: { AutopilotModelTests.Sender() },
                               autopilotStore: store, makeDecider: { _ in AutopilotModelTests.Decider(.failure(PMDecisionError.failed("not used"))) },
                               notifications: NoNotes(), isWindowFocused: { false })
        model.claudeProjectsRoot = dir.url.appendingPathComponent("no-claude")
        return model
    }

    private final class NoNotes: NotificationSending, @unchecked Sendable {
        func requestAuthorization() async -> Bool { true }
        func send(_ notification: AppNotification) async {}
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAFinishedCardInTheClosedProjectGetsItsPacketAndItsPMIsTold() async throws {
        let m = try panel(bCards: [("B1", card("B1", "doing", report: true))])
        terminal.agents = [agentB(.working), pmB]
        await m.reload()   // the PM notice learns what the card looked like (the agent works)
        XCTAssertEqual(m.selectedProjectID, "a", "project b stays closed")
        terminal.agents = [agentB(.done), pmB]
        await m.refreshAgents()
        await settle { !self.scripts.calls(of: .reviewPacket).isEmpty && !self.commander.prompts.isEmpty }
        let packets = scripts.calls(of: .reviewPacket)
        XCTAssertEqual(packets.count, 1, "the packet of the closed project's finished card ran")
        XCTAssertTrue(packets[0].args.first?.hasSuffix("data-b/tasks/B1.md") == true, "\(packets[0].args)")
        let told = try XCTUnwrap(commander.prompts.first { $0.target == "w3:p1" }, "\(commander.prompts)")
        XCTAssertTrue(told.text.contains("B1 finished its work"), told.text)
        XCTAssertEqual(m.selectedProjectID, "a")
    }

    func testAStartRequestForTheClosedProjectStartsItWithItsOwnRules() async throws {
        let m = try panel(bCards: [("B2", card("B2", "awaiting-start-approval"))])
        terminal.agents = [pmB]
        await m.reload()
        XCTAssertEqual(m.selectedProjectID, "a")
        m.startRequests.noteCommand("please start B2 right now", to: "w3:p1", project: "b")
        try dir.write("data-b/.tentacl/start-requests/r1.json", #"{"id":"r1","requestedBy":"pm","userWords":"please start B2 right now","cards":["B2"]}"#)
        await m.startRequests.process()
        let spawns = scripts.calls(of: .spawn)
        XCTAssertEqual(spawns.count, 1, "\(scripts.calls)")
        XCTAssertTrue(spawns[0].args.contains { $0.hasSuffix("b/project.json") }, "\(spawns[0].args)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("data-b/.tentacl/start-requests/r1.json").path), "the request is consumed")
        XCTAssertTrue(commander.prompts.contains { $0.target == "w3:p1" && $0.text.contains("started B2") }, "\(commander.prompts)")
        XCTAssertEqual(m.selectedProjectID, "a")
        XCTAssertFalse(m.round.isOpen, "no sheet in the open project")
    }

    func testAnApproveRequestForTheClosedProjectIsHandledWithoutOpeningIt() async throws {
        let m = try panel(bCards: [("B3", card("B3", "review", report: true))])
        terminal.agents = [pmB]
        await m.reload()
        // Under the standing rules of project b nothing is approved without the user's words; the request waits for the project to be opened.
        try dir.write("data-b/.tentacl/approve-requests/r1.json", #"{"id":"r1","requestedBy":"pm","userWords":"approve B3","cards":["B3"]}"#)
        await m.approveRequests.process()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("data-b/.tentacl/approve-requests/r1.json").path), "left waiting, not refused")
        XCTAssertNil(m.approveSheetRequest, "no sheet is opened for another project")
        XCTAssertTrue(scripts.calls(of: .merge).allSatisfy { $0.args.first == "--inspect" }, "only the autopilot's look at how far behind main the card is, no merge: \(scripts.calls)")
    }

    func testTheInboxListsTheClosedProjectsReadyCardsWithItsName() async throws {
        let m = try panel(bCards: [("B3", card("B3", "review", report: true))])
        terminal.agents = [pmB]
        await m.reload()
        await settle { !m.topBarInbox().otherReady.isEmpty }
        let content = m.topBarInbox()
        XCTAssertEqual(content.ownReady, [], "the open project has none")
        XCTAssertEqual(content.otherReady.map(\.title), ["Project B · B3 · Title B3"])
        XCTAssertEqual(content.otherReady.map(\.projectID), ["b"])
        XCTAssertEqual(content.count, 1)
    }

    func testEachProjectKeepsItsOwnPMHandoffState() async throws {
        let m = try panel(bCards: [("B1", card("B1", "doing"))], freshB: true)
        await m.reload()
        m.freshStartRequested(.roundStart, project: "b")
        XCTAssertEqual(m.watches["b"]?.freshPending, .roundStart, "recorded for b")
        XCTAssertNil(m.watches["a"]?.freshPending, "not for the open project")
        XCTAssertNil(m.freshStartPending)
        m.freshStartRequested(.roundStart, project: "a")
        XCTAssertNil(m.watches["a"]?.freshPending, "a's rule is off")
    }

    func testPhaseOfAClosedProjectsCardUsesItsOwnAgents() async throws {
        let m = try panel(bCards: [("B1", card("B1", "doing", report: true))])
        terminal.agents = [agentB(.working)]
        await m.reload()
        let b1 = try XCTUnwrap(m.watches["b"]?.taskCards.first)
        XCTAssertEqual(m.phase(of: b1, in: "b"), .working)
    }

    /// The real test: the model polls by itself (as in the app), two projects were open one after the other, the user switched away, and
    /// the closed project's agent finishes meanwhile: its packet runs and its PM is told with nobody touching the model.
    func testRealPollingTwoProjectsSwitchAwayAndTheClosedOneKeepsRunning() async throws {
        let m = try panel(bCards: [("B1", card("B1", "doing", report: true)), ("B3", card("B3", "review", report: true))])
        terminal.agents = [agentB(.working), pmB]
        await m.reload()
        await m.selectProject("b")
        XCTAssertEqual(m.selectedProjectID, "b")
        await m.selectProject("a")   // switch away: b is closed now
        XCTAssertEqual(m.selectedProjectID, "a")
        m.startPolling(interval: .milliseconds(40))
        defer { m.stopPolling() }
        try await Task.sleep(for: .milliseconds(200))
        terminal.agents = [agentB(.done), pmB]   // b's agent finishes its turn
        await settle { !self.scripts.calls(of: .reviewPacket).isEmpty && self.commander.prompts.contains { $0.text.contains("B1 finished") } }
        XCTAssertEqual(scripts.calls(of: .reviewPacket).count, 1, "b's packet ran while a is open")
        XCTAssertTrue(commander.prompts.contains { $0.target == "w3:p1" && $0.text.contains("B1 finished") }, "\(commander.prompts)")
        XCTAssertEqual(m.selectedProjectID, "a")
        await settle { !m.topBarInbox().otherReady.isEmpty }
        let inbox = m.topBarInbox()
        XCTAssertEqual(inbox.otherReady.map(\.title), ["Project B · B3 · Title B3"])
        // Evidence for the Report: the Inbox as the user sees it with project a open and b closed.
        if let shots = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            let view = VStack(spacing: 0) { InboxPanel(content: inbox, onOpen: { _ in }, onApprove: {}); Spacer(minLength: 0) }.background(Tok.bg)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 420, height: 160)))
            try data.write(to: URL(fileURLWithPath: shots).appendingPathComponent("N208-inbox-closed-project.png"))
        }
    }
}
