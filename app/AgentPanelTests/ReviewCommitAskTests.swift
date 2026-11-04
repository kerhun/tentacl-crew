import XCTest
@testable import AgentPanel

private final class AgentList: @unchecked Sendable { var agents: [AgentStatus] = [] }
private struct ListedTerminal: TerminalListing {
    let list: AgentList
    func agents() async throws -> [AgentStatus] { list.agents }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

@MainActor
final class ReviewCommitAskTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!
    private var list: AgentList!
    private let dirty = "EVIDENCE MISSING: uncommitted work in the agent's worktree (ask the agent to commit or discard it)\n M a.txt\n"

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
        list = AgentList()
    }

    private func agent(session: String) -> AgentStatus {
        var a = AgentStatus(paneID: "wA:p1", workspaceID: "wA", state: .idle, cwd: "/repo/.agent-worktrees/pilot-a5", title: "a5", sessionID: session)
        a.name = "dev-a5"
        return a
    }

    private func makeModel(packetOutput: String) throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: doing\nagent: dev-a5\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5 · T\n\n## Report\nDone.\n")
        let project = try dir.write("p/demo.json", """
        {"id":"demo","name":"Demo","repoPath":"/repo","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"b","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        scripts.handler = { script, _ in
            script == .reviewPacket ? ScriptResult(status: 1, stdout: packetOutput, stderr: "") : ScriptResult(status: 0, stdout: "UDID-1\n", stderr: "")
        }
        let terminal = ListedTerminal(list: list), s = scripts!, c = commander!
        return PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: RecordingOpener(), makeScripts: { _ in s }, makeCommander: { c },
                          log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                          defaults: makeTestDefaults(),
                          roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-roles")))
    }

    private func a5(_ m: PanelModel) throws -> TaskCard {
        try XCTUnwrap(m.cards.compactMap { r -> TaskCard? in if case .card(let c) = r { return c } else { return nil } }.first)
    }

    func testButtonAppearsOnlyForTheUncommittedWorkError() async throws {
        list.agents = [agent(session: "s1")]
        let m = try makeModel(packetOutput: dirty)
        await m.reload()
        XCTAssertFalse(m.canAskToCommit)
        await m.prepareReview(try a5(m))
        XCTAssertTrue(m.canAskToCommit)

        let other = try makeModel(packetOutput: "EVIDENCE MISSING: build failed, see /l\n")
        await other.reload()
        await other.prepareReview(try a5(other))
        XCTAssertFalse(other.canAskToCommit)
    }

    func testButtonGoesWhenAnotherActionReplacesTheMessage() async throws {
        list.agents = [agent(session: "s1")]
        let m = try makeModel(packetOutput: dirty)
        await m.reload()
        await m.prepareReview(try a5(m))
        m.clearActionState()
        XCTAssertFalse(m.canAskToCommit)
    }

    func testAskSendsExactlyOnePromptToTheCardsAgent() async throws {
        list.agents = [agent(session: "s1")]
        let m = try makeModel(packetOutput: dirty)
        await m.reload()
        await m.prepareReview(try a5(m))
        await m.askAgentToCommit()
        XCTAssertEqual(commander.prompts.map(\.target), ["wA:p1"])
        XCTAssertTrue(commander.prompts[0].text.contains("commit"))
        XCTAssertTrue(commander.prompts[0].text.contains("Report"))
        XCTAssertTrue(commander.prompts[0].text.contains("pilot/a5"))
        guard case .done(let message) = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertTrue(message.contains("dev-a5"), message)
        XCTAssertFalse(m.canAskToCommit)
        await m.askAgentToCommit()
        XCTAssertEqual(commander.prompts.count, 1, "a second tap must not send again")
    }

    func testAskRefusesWhenTheSessionChanged() async throws {
        list.agents = [agent(session: "s1")]
        let m = try makeModel(packetOutput: dirty)
        await m.reload()
        await m.prepareReview(try a5(m))
        list.agents = [agent(session: "s2")]
        await m.askAgentToCommit()
        XCTAssertEqual(commander.prompts.count, 0)
        guard case .failed = m.actionState else { return XCTFail("\(m.actionState)") }
    }

    func testNoButtonWhenTheAgentIsGone() async throws {
        let m = try makeModel(packetOutput: dirty)
        await m.reload()
        await m.prepareReview(try a5(m))
        XCTAssertFalse(m.canAskToCommit)
    }
}
