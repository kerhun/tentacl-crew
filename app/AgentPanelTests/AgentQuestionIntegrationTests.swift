import XCTest
@testable import AgentPanel

/// The question path against the fake terminal script (through `term.sh`'s verbs), a screen captured from a real agent.
@MainActor
final class AgentQuestionIntegrationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var dir: TempDir!
    private var state: URL!

    override func setUpWithError() throws {
        dir = try TempDir()
        state = dir.url.appendingPathComponent("term-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        setenv("FAKE_TERM_STATE", state.path, 1)
    }
    override func tearDown() { unsetenv("FAKE_TERM_STATE") }

    private var terminal: ScriptTerminal { ScriptTerminal(fixtures: root.appendingPathComponent("tests/fixtures")) }
    private func calls() -> String { (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }

    private func setScreen(_ name: String) throws {
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), to: state.appendingPathComponent("screen"))
    }

    private func inbox(state: AgentState = .blocked) -> AgentInboxModel {
        let commander = terminal
        var a = AgentStatus(paneID: "wZ:p1", workspaceID: "wZ", state: state, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "ui_dev-v1"
        return AgentInboxModel(reader: commander, keys: commander, commander: commander,
                               adapter: FakeTerminal(agentsResult: .success([a])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
    }

    private func card() -> TaskCard {
        TaskCard(id: "V1", project: "d", status: .doing, agent: "ui_dev-v1", branch: "test/v1", kind: nil, files: [], title: "V1", sections: [:], url: URL(fileURLWithPath: "/tmp/V1.md"))
    }

    private func agent(_ state: AgentState) -> AgentStatus {
        var a = AgentStatus(paneID: "wZ:p1", workspaceID: "wZ", state: state, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "ui_dev-v1"
        return a
    }

    func testAMenuIsReadAndAnOptionPressedThroughTheTerminalScript() async throws {
        try setScreen("choice-before.txt")
        let m = inbox()
        await m.refresh(agents: [agent(.blocked)], cards: [card()], projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), label: { _ in "Pixel · V1" })
        XCTAssertTrue(calls().contains("read wZ:p1 \(AgentInboxModel.screenLines)"), calls())
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: try XCTUnwrap(q.question.options.first { $0.label == "Green" }))
        XCTAssertTrue(ok)
        XCTAssertTrue(calls().contains("keys wZ:p1 2"), calls())
    }

    func testATypedAnswerGoesThroughAgentPrompt() async throws {
        try setScreen("freetext-before.txt")
        let m = inbox(state: .done)
        await m.refresh(agents: [agent(.done)], cards: [card()], projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), label: { _ in "Pixel · V1" })
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(q.question.kind, .freeText)
        let ok = await m.answer(q, text: "The home screen.")
        XCTAssertTrue(ok)
        XCTAssertTrue(calls().contains("prompt wZ:p1 The home screen."), calls())
    }
}
