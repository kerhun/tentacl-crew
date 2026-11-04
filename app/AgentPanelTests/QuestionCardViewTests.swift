import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class QuestionCardViewTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }

    private final class Sender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        var keys: [[String]] = []
        func sendKeys(target: String, keys: [String]) async throws { self.keys.append(keys) }
        func prompt(target: String, text: String) async throws {}
    }

    private func model(agents: [AgentStatus], screens: [String: String], sender: Sender = Sender()) throws -> (AgentInboxModel, TempDir) {
        final class Reader: TerminalReading, @unchecked Sendable { let screens: [String: String]; init(_ s: [String: String]) { screens = s }; func screen(of target: String, lines: Int) async throws -> String { screens[target] ?? "" } }
        let dir = try TempDir()
        return (AgentInboxModel(reader: Reader(screens), keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success(agents)), log: ActionLog(fileURL: dir.url.appendingPathComponent("log"))), dir)
    }

    private func agent(_ n: Int, state: AgentState = .blocked) -> AgentStatus {
        var a = AgentStatus(paneID: "w\(n):p1", workspaceID: "w\(n)", state: state, cwd: "/repo/.agent-worktrees/test-v\(n)", title: "t", sessionID: "s\(n)")
        a.changeSeq = 1; a.name = "ui_dev-v\(n)"
        return a
    }
    private func cards(_ n: Int) -> [TaskCard] {
        (1...n).map { i in TaskCard(id: "V\(i)", project: "d", status: .doing, agent: "ui_dev-v\(i)", branch: "test/v\(i)", kind: nil, files: [], title: "Card \(i)", sections: [:], url: URL(fileURLWithPath: "/tmp/V\(i).md")) }
    }

    /// One pending question read from a recorded screen.
    private func pending(_ file: String, state: AgentState = .blocked, id n: Int = 1) throws -> PendingQuestion {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture(file), state: state), file)
        return PendingQuestion(paneID: "w\(n):p1", sessionID: "s\(n)", agentLabel: "ui_dev · V\(n)", cardID: "V\(n)", question: q)
    }

    private func save(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    func testAgentsPaneShowsNeedsYourAnswerCardsAboveTheAgents() async throws {
        let a = agent(1), b = agent(2, state: .done)
        let (inbox, _) = try model(agents: [a, b], screens: ["w1:p1": try fixture("choice-before.txt"), "w2:p1": try fixture("freetext-before.txt")])
        await inbox.refresh(agents: [a, b], cards: cards(2), projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), label: { $0.paneID == "w1:p1" ? "Pixel · V1" : "Pixel · V2" })
        XCTAssertEqual(inbox.questions.count, 2)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AgentsPane(state: .available([a, b]), inbox: inbox).frame(width: 340, height: 720), size: CGSize(width: 340, height: 720)))
        XCTAssertGreaterThan(data.count, 6_000)
        try save(data, "questions.png")
    }

    func testTheAlwaysAllowWarningSaysItIsPermanentAndChangedInClaudeCode() {
        XCTAssertEqual(alwaysAllowWarning, "Permanent: Claude will not ask again for this. You can only undo it in Claude Code's permission settings.")
    }

    func testAnswerButtonsAreOffWhileSendingAndForBlankText() {
        XCTAssertTrue(canSendAnswer(text: "x", sending: false))
        XCTAssertFalse(canSendAnswer(text: "  \n", sending: false))
        XCTAssertFalse(canSendAnswer(text: "x", sending: true))
    }

    // MARK: the question window (N183)

    func testTheWindowShowsAPlanWithItsWholeContextItsAnswersAndRequestChanges() throws {
        let p = try pending("plan-approval-before.txt")
        let c = QuestionFocusContent(p)
        XCTAssertEqual(c.kindLabel, "Plan approval")
        XCTAssertEqual(c.contextLabel, "The plan")
        XCTAssertEqual(c.context, p.question.context, "the whole plan, not a cut")
        XCTAssertFalse(c.context.isEmpty)
        XCTAssertFalse(c.mono)
        XCTAssertEqual(c.answers.map(\.number), p.question.options.filter { !$0.isSpecial }.map(\.number))
        XCTAssertEqual(c.ownWords, p.question.feedbackPath == nil ? .none : .feedback)
        XCTAssertFalse(c.terminalOnly)
    }

    func testTheWindowShowsAPermissionsCommandInMonospaceAndDenyWithAReason() throws {
        let p = try pending("permission-fetch-before.txt")
        let c = QuestionFocusContent(p)
        XCTAssertEqual(c.kindLabel, "Permission")
        XCTAssertNotNil(c.code, "the request (a command, a url, a diff) is shown as code")
        XCTAssertFalse(c.mono, "the question itself is prose")
        XCTAssertFalse(c.answers.isEmpty)
        XCTAssertEqual(c.ownWords, p.question.feedbackPath == nil ? .none : .feedback)
        XCTAssertEqual(c.keyHint(questions: 3), "1–\(c.answers.count) answers · ←/→ next question · Esc later")
    }

    func testTheWindowShowsAChoiceWithNumberedAnswersAndAnOwnWordsBoxTypedIntoTypeSomething() throws {
        let c = QuestionFocusContent(try pending("choice-before.txt"))
        XCTAssertEqual(c.kindLabel, "Question")
        XCTAssertFalse(c.mono)
        XCTAssertGreaterThan(c.answers.count, 1)
        XCTAssertEqual(c.ownWords, .typed, "the menu offers Type something.")
        XCTAssertEqual(c.keyHint(questions: 1), "1–\(c.answers.count) answers · Esc later", "no ←/→ with one question")
    }

    func testTheWindowShowsAFreeTextQuestionWithAReplyBoxOnly() throws {
        let c = QuestionFocusContent(try pending("freetext-before.txt", state: .done))
        XCTAssertEqual(c.kindLabel, "Question")
        XCTAssertTrue(c.answers.isEmpty)
        XCTAssertEqual(c.ownWords, .reply)
        XCTAssertEqual(c.keyHint(questions: 2), "Type your answer · ←/→ next question · Esc later")
    }

    func testATerminalOnlyQuestionShowsItsTextAndOnlyOpenTerminal() throws {
        let p = try pending("choice-multiselect.txt")
        XCTAssertTrue(p.question.terminalOnly)
        let c = QuestionFocusContent(p)
        XCTAssertTrue(c.terminalOnly)
        XCTAssertTrue(c.answers.isEmpty)
        XCTAssertEqual(c.ownWords, .none)
        XCTAssertEqual(c.keyHint(questions: 1), "Esc later")
    }

    func testATabbedQuestionShowsRealAnswersAndTheProgress() throws {
        let c = QuestionFocusContent(try pending("choice-tabs3-2.txt"))
        XCTAssertFalse(c.terminalOnly)
        XCTAssertEqual(c.answers.map(\.label), ["Small", "Large"])
        XCTAssertTrue(c.text.hasPrefix("Question 2 of 3 · Colour · Size · Shape"))
        XCTAssertTrue(c.text.hasSuffix("Size?"))
        XCTAssertEqual(c.keyHint(questions: 1), "1–2 answers · Esc later")
        let review = QuestionFocusContent(try pending("choice-tabs3-4-submit.txt"))
        XCTAssertEqual(review.answers.map(\.label), ["Submit answers", "Cancel"])
        XCTAssertFalse(review.terminalOnly)
    }

    func testTheListItemShowsTheFirstLineOfTheContext() {
        XCTAssertEqual(QuestionFocusContent.firstLine("\n  Goal: a Git screen.\n\n1. GitDetails"), "Goal: a Git screen.")
        XCTAssertEqual(QuestionFocusContent.firstLine(""), "")
    }

    func testNextAndPreviousWrapAroundAndShowNOfM() throws {
        let qs = try [pending("choice-before.txt", id: 1), pending("permission-fetch-before.txt", id: 2), pending("plan-approval-before.txt", id: 3)]
        var f = try XCTUnwrap(QuestionFocus(opening: qs[1], in: qs))
        XCTAssertEqual(f.position(in: qs), "2 of 3")
        f.move(by: 1, in: qs); XCTAssertEqual(f.currentID, qs[2].id)
        f.move(by: 1, in: qs); XCTAssertEqual(f.currentID, qs[0].id, "› after the last goes to the first")
        f.move(by: -1, in: qs); XCTAssertEqual(f.currentID, qs[2].id, "‹ before the first goes to the last")
        XCTAssertEqual(f.position(in: qs), "3 of 3")
    }

    func testAQuestionGoneWhileOpenIsDroppedWithANoteAndTheNextOpens() throws {
        let qs = try [pending("choice-before.txt", id: 1), pending("permission-fetch-before.txt", id: 2), pending("plan-approval-before.txt", id: 3)]
        var f = try XCTUnwrap(QuestionFocus(opening: qs[1], in: qs))
        XCTAssertTrue(f.sync([qs[0], qs[2]]))
        XCTAssertEqual(f.currentID, qs[2].id)
        XCTAssertEqual(f.note, "ui_dev · V2's question was answered in its terminal or is no longer asked.")
        f.move(by: 1, in: [qs[0], qs[2]]); XCTAssertNil(f.note, "moving on clears the note")
        XCTAssertFalse(f.sync([]), "nothing left: the window closes")
    }

    func testAfterAnAnswerTheNextUnansweredQuestionOpensAndTheWindowClosesWhenNoneIsLeft() async throws {
        let a = agent(1), b = agent(2)
        let sender = Sender()
        let (inbox, _) = try model(agents: [a, b], screens: ["w1:p1": try fixture("choice-before.txt"), "w2:p1": try fixture("permission-fetch-before.txt")], sender: sender)
        await inbox.refresh(agents: [a, b], cards: cards(2), projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), label: { $0.paneID == "w1:p1" ? "V1" : "V2" })
        XCTAssertEqual(inbox.questions.count, 2)
        let first = inbox.questions[0], second = inbox.questions[1]
        inbox.openFocus(first, in: inbox.questions)
        let option = try XCTUnwrap(first.question.options.first { !$0.isSpecial })
        let sent = await inbox.answer(first, option: option)
        XCTAssertTrue(sent)
        XCTAssertEqual(sender.keys, [option.keys], "the same key as the list's answer")
        inbox.syncFocus(inbox.questions)
        XCTAssertEqual(inbox.focus?.currentID, second.id)
        XCTAssertNil(inbox.focus?.note, "answered here: no note")
        let allow = try XCTUnwrap(second.question.options.first { !$0.isSpecial })
        _ = await inbox.answer(second, option: allow)
        inbox.syncFocus(inbox.questions)
        XCTAssertNil(inbox.focus, "none left: the window closes")
    }

    // MARK: snapshots of the window and the list item

    private func sheetShot(_ file: String, state: AgentState = .blocked, name: String) throws {
        let p = try pending(file, state: state)
        let (inbox, _) = try model(agents: [], screens: [:])
        let others = try [p, pending("choice-before.txt", id: 2), pending("freetext-before.txt", state: .done, id: 3)]
        let view = QuestionFocusSheet(inbox: inbox, questions: others, shown: p, cardTitle: { _ in "Git screen in the rail" }, waited: { _ in "4 min" }, onPassOn: { _ in })
        let size = CGSize(width: QuestionFocusSheet.width, height: QuestionFocusSheet.height)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.frame(width: size.width, height: size.height), size: size))
        XCTAssertGreaterThan(data.count, 20_000)
        try save(data, name)
    }

    func testSnapshotPlanWindow() throws { try sheetShot("plan-approval-before.txt", name: "question-window-plan.png") }
    func testSnapshotPermissionWindow() throws { try sheetShot("permission-fetch-before.txt", name: "question-window-permission.png") }
    func testSnapshotChoiceWindow() throws { try sheetShot("choice-before.txt", name: "question-window-choice.png") }
    func testSnapshotFreeTextWindow() throws { try sheetShot("freetext-before.txt", state: .done, name: "question-window-freetext.png") }
    func testSnapshotTerminalOnlyWindow() throws { try sheetShot("choice-multiselect.txt", name: "question-window-terminal-only.png") }

    func testSnapshotTabbedWindowFirstOfThree() throws { try sheetShot("choice-tabs3-1.txt", name: "N187-tab-1-of-3.png") }
    func testSnapshotTabbedWindowSubmitStep() throws { try sheetShot("choice-tabs3-4-submit.txt", name: "N187-submit-step.png") }

    /// A three-question call as the panel builds it: all questions from the session file, one item.
    private func callShot(name: String, picks: [AskCall.Answer]) throws {
        let screen = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-tabs3-1.txt"), state: .blocked))
        let call = try XCTUnwrap(AskCallReader.parse(AskCallTests.three))
        let p = PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "ui_dev · V1", cardID: "V1", question: .call(call, from: screen))
        let (inbox, _) = try model(agents: [], screens: [:])
        for pick in picks { inbox.chooseInCall(p, pick) }
        let others = try [p, pending("choice-before.txt", id: 2)]
        let view = QuestionFocusSheet(inbox: inbox, questions: others, shown: p, cardTitle: { _ in "Git screen in the rail" }, waited: { _ in "4 min" }, onPassOn: { _ in })
        let size = CGSize(width: QuestionFocusSheet.width, height: QuestionFocusSheet.height)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.frame(width: size.width, height: size.height), size: size))
        XCTAssertGreaterThan(data.count, 20_000)
        try save(data, name)
        let item = QuestionCard(inbox: inbox, question: p, tint: .question, onOpen: { _ in }).padding(Tok.Space.l).frame(width: 420, alignment: .top).background(Tok.pane)
        XCTAssertGreaterThan(try XCTUnwrap(SnapshotRenderer.render(view: item.frame(height: 200, alignment: .top), size: CGSize(width: 420, height: 200))).count, 5_000)
    }

    func testSnapshotCallMiddleQuestion() throws { try callShot(name: "N188-middle-question.png", picks: [.option(2)]) }
    func testSnapshotCallSummary() throws { try callShot(name: "N188-summary.png", picks: [.option(2), .text("Large and a bit more"), .option(1)]) }

    /// The real call of N192: three Turkish questions read from the screen's tabs, one item, own words on every question.
    private func steppedCall() throws -> PendingQuestion {
        let tabs = try ["ask3-tab1.txt", "ask3-tab2.txt", "ask3-tab3.txt"].map { try XCTUnwrap(QuestionDetector.detect(screen: try fixture($0), state: .blocked)) }
        let call = try XCTUnwrap(AskCall.read(headers: tabs[0].tabs, tabs: tabs))
        return PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "PM", cardID: "", question: .call(call, from: tabs[0]), isPM: true)
    }

    private func windowShot(_ p: PendingQuestion, picks: [AskCall.Answer], name: String) throws {
        let (inbox, _) = try model(agents: [], screens: [:])
        for pick in picks { inbox.chooseInCall(p, pick) }
        let view = QuestionFocusSheet(inbox: inbox, questions: [p], shown: p)
        let size = CGSize(width: QuestionFocusSheet.width, height: QuestionFocusSheet.height)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.frame(width: size.width, height: size.height), size: size))
        XCTAssertGreaterThan(data.count, 20_000)
        try save(data, name)
    }

    func testSnapshotSteppedCallFirstQuestionWithOwnWords() throws { try windowShot(try steppedCall(), picks: [], name: "N192-call-first-question.png") }
    func testSnapshotSteppedCallSummaryWithOwnWords() throws { try windowShot(try steppedCall(), picks: [.text("Kendi sözlerim"), .option(1), .option(2)], name: "N192-call-summary.png") }
    func testSnapshotSingleTabOwnWords() throws { try sheetShot("ask3-tab2-after-text.txt", name: "N192-single-tab-own-words.png") }

    func testSnapshotListItem() throws {
        let (inbox, _) = try model(agents: [], screens: [:])
        let items = try [pending("plan-approval-before.txt", id: 1), pending("permission-fetch-before.txt", id: 2)]
        let view = VStack(spacing: Tok.Space.s) {
            ForEach(items) { QuestionCard(inbox: inbox, question: $0, tint: .question, onOpen: { _ in }) }
        }.padding(Tok.Space.l).frame(width: 420, alignment: .top).background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.frame(height: 440, alignment: .top).background(Tok.pane), size: CGSize(width: 420, height: 440)))
        XCTAssertGreaterThan(data.count, 10_000)
        try save(data, "question-list-item.png")
    }
}
