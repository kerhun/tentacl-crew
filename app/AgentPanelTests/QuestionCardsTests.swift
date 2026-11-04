import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

/// N206: own words on a one-question card, and "Plan a round" that says why it is off.
@MainActor
final class QuestionCardsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private var dir: TempDir!

    override func setUpWithError() throws { dir = try TempDir() }

    private final class Sender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        var steps: [String] = []
        func sendKeys(target: String, keys: [String]) async throws { steps.append("keys " + keys.joined(separator: " ")) }
        func sendText(target: String, text: String) async throws { steps.append("text " + text) }
        func prompt(target: String, text: String) async throws { steps.append("prompt " + text) }
    }
    private final class Reader: TerminalReading, @unchecked Sendable {
        let screen: String
        init(_ s: String) { screen = s }
        func screen(of target: String, lines: Int) async throws -> String { screen }
    }

    private var agent: AgentStatus {
        var a = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .blocked, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1")
        a.changeSeq = 1; a.name = "ui_dev-v1"
        return a
    }

    private func inbox(_ screen: String, sender: Sender = Sender()) -> AgentInboxModel {
        AgentInboxModel(reader: Reader(screen), keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([agent])),
                        log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
    }

    /// The one question a real Claude Code (v2.1.304) asked in a scratch pane: "☐ Renk", three options, Type something., Chat about this.
    private func single() throws -> PendingQuestion {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("ask1-single.txt"), state: .blocked))
        return PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "ui_dev · V1", cardID: "V1", question: q)
    }

    private func save(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    // MARK: own words on one question

    func testARealOneQuestionMenuOffersOwnWordsAndNoTerminalNote() throws {
        let p = try single()
        let q = p.question
        XCTAssertEqual(q.kind, .choice)
        XCTAssertEqual(q.title, "Renk")
        XCTAssertEqual(q.tabs, [], "one question: no tab bar")
        XCTAssertFalse(q.isCall)
        XCTAssertEqual(q.options.filter { !$0.isSpecial }.map(\.label), ["Kırmızı", "Yeşil", "Mavi"])
        XCTAssertEqual(q.typeNumber, 4)
        XCTAssertNil(QuestionCard.otherAnswersNote(q), "own words, not the terminal")
        XCTAssertEqual(QuestionFocusContent(p).ownWords, .typed, "the question window has the box too")
    }

    func testTheTerminalNoteStaysOnlyWhereThePanelCannotAnswer() throws {
        let noType = AgentQuestion(kind: .choice, title: "Colour", text: "Which?", options: [
            QuestionOption(number: 1, label: "Red", detail: "", isSpecial: false), QuestionOption(number: 2, label: "Blue", detail: "", isSpecial: false),
            QuestionOption(number: 3, label: "Chat about this", detail: "", isSpecial: true),
        ])
        XCTAssertEqual(QuestionCard.otherAnswersNote(noType), "Other answers: use the agent's terminal.")
        let plain = AgentQuestion(kind: .choice, title: "Colour", text: "Which?", options: Array(noType.options.prefix(2)))
        XCTAssertNil(QuestionCard.otherAnswersNote(plain), "nothing the panel cannot answer")
        let plan = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("plan-approval-before.txt"), state: .blocked))
        XCTAssertNil(QuestionCard.otherAnswersNote(plan), "Tell Claude what to change has its feedback box")
    }

    /// The card's Send: the number of "Type something.", the words, Enter; the screen is checked between steps.
    func testOwnWordsOnOneQuestionTypeIntoTypeSomething() async throws {
        let sender = Sender()
        let m = inbox(try fixture("ask1-single.txt"), sender: sender)
        let sent = await m.answerTyped(try single(), text: "Mor olsun\n  lütfen ")
        XCTAssertTrue(sent, m.error ?? "")
        XCTAssertEqual(sender.steps, ["keys 4", "text Mor olsun lütfen", "keys enter"])
    }

    func testSnapshotOneQuestionCardWithOwnWords() throws {
        let view = QuestionCard(inbox: inbox(""), question: try single()).padding(Tok.Space.m).frame(width: 340, alignment: .top).background(Tok.list)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.frame(height: 420, alignment: .top), size: CGSize(width: 340, height: 420)))
        XCTAssertGreaterThan(data.count, 8_000)
        try save(data, "N206-one-question-card.png")
    }

    func testSnapshotOneQuestionWindowWithOwnWords() throws {
        let p = try single()
        let view = QuestionFocusSheet(inbox: inbox(""), questions: [p], shown: p)
        let size = CGSize(width: QuestionFocusSheet.width, height: QuestionFocusSheet.height)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.frame(width: size.width, height: size.height), size: size))
        XCTAssertGreaterThan(data.count, 20_000)
        try save(data, "N206-one-question-window.png")
    }

    // MARK: Plan a round

    func testPlanARoundWithTheAutopilotOffSaysWhyAndOffersShadow() async throws {
        // The demo projects with an autopilot settings folder, so the autopilot is there and only Off.
        let iso = TestIsolation(dir, owner: self)
        let model = PanelModel(settingsURL: DemoSupport.prepareSettings(), makeTerminal: { DemoTerminal() }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() }, log: iso.log, writer: DemoCardWriter(),
                               defaults: iso.defaults, roleStore: iso.roleStore, autopilotStore: AutopilotStore(folder: dir.url.appendingPathComponent("autopilot")))
        await model.reload()
        model.autopilot.setMode(.off)
        XCTAssertTrue(model.autopilot.isAvailable)
        let state = model.planRoundState
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.help, "The PM autopilot is Off. Switch it to Shadow or On to let the PM plan a round.")
        let list = try XCTUnwrap(SnapshotRenderer.render(view: TaskListView(model: model), size: CGSize(width: 420, height: 240)))
        try save(list, "N206-plan-round-off.png")
        let why = PlanRoundWhy(autopilot: model.autopilot, reason: state.help).frame(height: 128, alignment: .top).background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: why, size: CGSize(width: 320, height: 128)))
        XCTAssertGreaterThan(data.count, 4_000)
        try save(data, "N206-plan-round-why.png")
        // Switch to Shadow (the popover's first button) turns the icon on.
        model.autopilot.setMode(.shadow)
        XCTAssertTrue(model.planRoundState.enabled, model.planRoundState.help)
        try save(try XCTUnwrap(SnapshotRenderer.render(view: TaskListView(model: model), size: CGSize(width: 420, height: 240))), "N206-plan-round-on.png")
    }
}
