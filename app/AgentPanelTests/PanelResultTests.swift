import XCTest
@testable import AgentPanel

private final class Agents: @unchecked Sendable { var list: [AgentStatus] = [] }
private struct ListedTerminal: TerminalListing {
    let agents: Agents
    func agents() async throws -> [AgentStatus] { agents.list }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// N49: Prepare review, Approve, Ask-to-commit and the round start answer with a result, not through `actionState`.
@MainActor
final class PanelResultTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!
    private var agents: Agents!
    private let dirty = "EVIDENCE MISSING: uncommitted work in the agent's worktree (ask the agent to commit or discard it)\n M a.txt\n"

    override func setUpWithError() throws {
        dir = try TempDir(); scripts = FakeScripts(); commander = FakeCommander(); agents = Agents()
    }

    private func makeModel(packetOutput: String = "") throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: doing\nagent: dev-a5\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5 · T\n\n## Report\nDone.\n")
        let project = try dir.write("p/demo.json", """
        {"id":"demo","name":"Demo","repoPath":"/repo","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"b","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        scripts.handler = { script, _ in
            script == .reviewPacket && !packetOutput.isEmpty ? ScriptResult(status: 1, stdout: packetOutput, stderr: "") : ScriptResult(status: 0, stdout: "UDID-1\n", stderr: "")
        }
        let terminal = ListedTerminal(agents: agents), s = scripts!, c = commander!
        return PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: RecordingOpener(), makeScripts: { _ in s }, makeCommander: { c },
                          log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                          defaults: makeTestDefaults(),
                          roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-roles")))
    }

    private func a5(_ m: PanelModel) throws -> TaskCard {
        try XCTUnwrap(m.cards.compactMap { r -> TaskCard? in if case .card(let c) = r { return c } else { return nil } }.first)
    }

    func testABusyPanelMakesReviewAndApproveFailNotSucceed() async throws {
        let m = try makeModel()
        await m.reload()
        let card = try a5(m)
        let plan = ApprovalPlan(card: card, agentName: "dev-a5", branch: "pilot/a5", worktreePath: "/wt", base: "main", head: "abc", ahead: 1, filesChanged: 1,
                                screenshotCount: 1, isAnalysis: false, commandPreview: "merge-task.sh")
        m.setActionState(.running("Starting something else…"))
        let prepare = await m.prepareReview(card)
        XCTAssertEqual(prepare, .busy)
        let approve = await m.confirmApprove(plan)
        XCTAssertEqual(approve, .busy)
        let forPrepare = await m.prepareForRequest(card)
        XCTAssertNotNil(forPrepare, "a request must not read a busy panel as success")
        let forApprove = await m.approveForRequest(plan)
        XCTAssertNotNil(forApprove)
        XCTAssertTrue(scripts.calls.isEmpty, "nothing ran: \(scripts.calls)")
    }

    func testAnIdlePanelReturnsOkAndAFailureCarriesItsMessage() async throws {
        let ok = try makeModel()
        await ok.reload()
        let result = await ok.prepareReview(try a5(ok))
        XCTAssertEqual(result, .ok)
        let readyForRequest = await ok.prepareForRequest(try a5(ok))
        XCTAssertNil(readyForRequest)
        let bad = try makeModel(packetOutput: "EVIDENCE MISSING: build failed, see /l\n")
        await bad.reload()
        let failed = await bad.prepareReview(try a5(bad))
        guard case .failed(let message) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(message.contains("build failed"), message)
    }

    func testAskToCommitReturnsOkOnlyWhenItWasSent() async throws {
        var pane = AgentStatus(paneID: "wA:p1", workspaceID: "wA", state: .idle, cwd: "/repo/.agent-worktrees/pilot-a5", title: "a5", sessionID: "s1"); pane.name = "dev-a5"
        agents.list = [pane]
        let m = try makeModel(packetOutput: dirty)
        await m.reload()
        await m.prepareReview(try a5(m))
        let first = await m.askAgentToCommit()
        XCTAssertEqual(first, .ok)
        let second = await m.askAgentToCommit()
        XCTAssertNotEqual(second, .ok, "the earlier .done must not count")
        XCTAssertEqual(commander.prompts.count, 1)
    }

    func testARoundStartRefusesABusyPanel() async throws {
        let m = try makeModel()
        await m.reload()
        let plan = StartPlan(card: try a5(m), agentName: "dev-a5", branch: "pilot/a5", rolePath: "/r.json", worktreePath: "/wt", commandPreview: "spawn", roleName: "dev")
        m.setActionState(.running("Merging…"))
        let refusal = await m.startInRound(plan)
        XCTAssertTrue(refusal?.contains("busy") == true, refusal ?? "nil")
        XCTAssertTrue(scripts.calls.isEmpty)
    }

    func testOnlyAMessageToTheProjectsPMPaneBacksARequest() async throws {
        agents.list = [AgentStatus(paneID: "wA:p1", workspaceID: "wA", state: .idle, cwd: "/repo", title: "pm", sessionID: "s1"),
                       AgentStatus(paneID: "wA:p2", workspaceID: "wA", state: .idle, cwd: "/repo/.agent-worktrees/pilot-a5", title: "a5", sessionID: "s2")]
        let m = try makeModel()
        await m.reload()
        await m.refreshAgents()
        await m.sendCommand("please start A5 right now", to: "wA:p2", session: "s2")
        XCTAssertNil(m.commandMemory.take(project: "demo", ids: ["A5"], words: "please start A5 right now"), "a dev pane is not the PM")
        await m.sendCommand("please start A5 right now", to: "wA:p1", session: "s1")
        XCTAssertNotNil(m.commandMemory.take(project: "demo", ids: ["A5"], words: "please start A5 right now"))
        await m.sendCommand("please start A5 right now", to: "wA:p1", session: "s1")
        XCTAssertNil(m.commandMemory.take(project: "other", ids: ["A5"], words: "please start A5 right now"), "another project's memory")
    }
}
