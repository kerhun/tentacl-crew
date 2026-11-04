import XCTest
@testable import AgentPanel

/// Codex screens captured by N150 (tests/fixtures/agent-screens/codex-*). The Claude screens are in AgentScreenTests.
final class QuestionDetectorTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private func detect(_ name: String, _ state: AgentState) throws -> AgentQuestion? { QuestionDetector.detect(screen: try fixture(name), state: state) }

    func testCommandApprovalIsAPermissionWithTheReasonAndCommand() throws {
        let q = try XCTUnwrap(detect("codex-approval-command.txt", .blocked))
        XCTAssertEqual(q.kind, .permission)
        XCTAssertTrue(q.text.hasPrefix("Would you like to run the following command?"))
        XCTAssertTrue(q.text.contains("$ touch made-by-codex.txt"))
        XCTAssertFalse(q.text.contains("Running touch"), "the conversation above the dialog is not part of it")
        XCTAssertEqual(q.options.map(\.label), ["Yes, proceed", "Yes, and don't ask again for commands that start with `touch`", "No, and tell Codex what to do differently (esc)"])
        XCTAssertEqual(q.options.map(\.role), [.allow, .allowAlways, .deny])
        XCTAssertEqual(q.options.map(\.keys), [["1"], ["2"], ["esc"]])
        XCTAssertEqual(q.feedbackPath, .escapeThenPrompt)
        XCTAssertFalse(q.terminalOnly)
    }

    func testEditApprovalIsAPermissionForTheFile() throws {
        let q = try XCTUnwrap(detect("codex-approval-edit.txt", .blocked))
        XCTAssertEqual(q.kind, .permission)
        XCTAssertTrue(q.text.hasPrefix("Would you like to make the following edits?"))
        XCTAssertTrue(q.text.contains("Destination:") && q.text.contains("notes.txt"))
        XCTAssertEqual(q.options.map(\.role), [.allow, .allowAlways, .deny])
        XCTAssertEqual(q.options[1].label, "Yes, and don't ask again for these files")
    }

    func testRequestUserInputMenuIsAChoiceWithDetails() throws {
        let q = try XCTUnwrap(detect("codex-question-menu.txt", .blocked))
        XCTAssertEqual(q.kind, .choice)
        XCTAssertEqual(q.text, "Which greeting should be added to notes.txt?")
        XCTAssertEqual(q.options.map(\.label), ["hi", "hello", "None of the above"])
        XCTAssertEqual(q.options.map(\.detail), ["Add the line \"hi\".", "Add the line \"hello\".", "Optionally, add details in notes (tab)"])
        XCTAssertEqual(q.options.map(\.keys), [["1"], ["2"], ["3"]])
        XCTAssertFalse(q.terminalOnly)
    }

    func testSeveralQuestionsAreAnsweredInTheTerminal() {
        let screen = "\n\n\n\n  Question 1/2 (2 unanswered)\n  Which one?\n\n  › 1. a   A\n    2. b   B\n\n  tab to add notes | enter to submit answer | esc to interrupt\n"
        XCTAssertEqual(QuestionDetector.detect(screen: screen, state: .blocked)?.terminalOnly, true)
    }

    func testPlanApprovalIsFoundWhileTheAgentIsDone() throws {
        for state in [AgentState.done, .idle] {
            let q = try XCTUnwrap(detect("codex-plan-approval.txt", state))
            XCTAssertEqual(q.kind, .plan)
            XCTAssertEqual(q.text, "Implement this plan?")
            XCTAssertEqual(q.options.map(\.label), ["Yes, implement this plan", "Yes, clear context and implement", "No, stay in Plan mode"])
            XCTAssertEqual(q.options.map(\.role), [.allow, .allow, .deny])
            XCTAssertTrue(q.context.contains("Add greeting to notes.txt") && q.context.contains("Append a new line containing hello"))
            XCTAssertFalse(q.context.contains("Worked for"))
        }
    }

    func testAPlainQuestionOfAFinishedTurnIsAFreeTextQuestion() throws {
        let q = try XCTUnwrap(detect("codex-question.txt", .done))
        XCTAssertEqual(q.kind, .freeText)
        XCTAssertEqual(q.text, "Which color do you prefer: red or blue?")
    }

    func testStartupMenusAreChoices() throws {
        let hooks = try XCTUnwrap(detect("codex-hooks-review.txt", .blocked))
        XCTAssertEqual(hooks.kind, .choice)
        XCTAssertEqual(hooks.options.map(\.label), ["Review hooks", "Trust all and continue", "Continue without trusting (hooks won't run)"])
        XCTAssertTrue(hooks.text.hasPrefix("Hooks need review"))
        let trust = try XCTUnwrap(detect("codex-trust-0.147.txt", .blocked))
        XCTAssertEqual(trust.kind, .permission)
        XCTAssertEqual(trust.options.map(\.role), [.allow, .deny])
        let update = try XCTUnwrap(detect("codex-update-0.147.txt", .blocked))
        XCTAssertEqual(update.kind, .choice)
        XCTAssertEqual(update.options.count, 3)
        XCTAssertTrue(update.text.contains("Update available"))
    }

    func testScreensWithoutAQuestionYieldNothing() throws {
        XCTAssertNil(try detect("codex-working.txt", .working))
        XCTAssertNil(try detect("codex-idle.txt", .idle))
        XCTAssertNil(try detect("codex-done.txt", .done))
        XCTAssertNil(try detect("codex-readonly-refusal.txt", .done))
        XCTAssertEqual(try detect("codex-auth-error-0.147.txt", .done)?.signInTool, .codex, "a real login error is a sign-in item, not a question")
        XCTAssertNil(try detect("codex-approval-command-after.txt", .done))
        XCTAssertNil(try detect("codex-approval-edit-after-esc.txt", .done))
        XCTAssertNil(try detect("codex-question-menu-after-2.txt", .working))
    }

    func testAMenuIsNotAskedWhileTheAgentWorks() throws {
        XCTAssertNil(try detect("codex-approval-command.txt", .working))
        XCTAssertNil(try detect("codex-approval-command.txt", .done), "a permission menu counts only while blocked")
    }

    // MARK: several questions in tabs (N187; screens captured from Claude Code with a two- and a three-question AskUserQuestion)

    func testEachTabOfAThreeQuestionCallIsItsOwnAnswerableQuestion() throws {
        let expect: [(file: String, text: String, step: Int, options: [String])] = [
            ("choice-tabs3-1.txt", "Colour?", 1, ["Red", "Green"]),
            ("choice-tabs3-2.txt", "Size?", 2, ["Small", "Large"]),
            ("choice-tabs3-3.txt", "Shape?", 3, ["Round", "Square"]),
        ]
        var signatures: Set<String> = []
        for e in expect {
            let q = try XCTUnwrap(detect(e.file, .blocked), e.file)
            XCTAssertEqual(q.kind, .choice)
            XCTAssertEqual(q.text, e.text)
            XCTAssertEqual(q.tabs, ["Colour", "Size", "Shape"])
            XCTAssertEqual(q.step, e.step)
            XCTAssertFalse(q.isReview)
            XCTAssertEqual(q.title, "Question \(e.step) of 3 · Colour · Size · Shape")
            XCTAssertEqual(q.options.filter { !$0.isSpecial }.map(\.label), e.options)
            XCTAssertEqual(q.options.filter { !$0.isSpecial }.map(\.keys), [["1"], ["2"]])
            XCTAssertEqual(q.options.filter(\.isSpecial).map(\.label), ["Type something.", "Chat about this"])
            XCTAssertFalse(q.terminalOnly, e.file)
            signatures.insert(q.signature)
        }
        XCTAssertEqual(signatures.count, 3, "each step has its own signature")
    }

    func testTheSubmitStepIsItsOwnQuestionWithSubmitAndCancel() throws {
        for file in ["choice-tabs3-4-submit.txt", "choice-tabs2-3-submit.txt"] {
            let q = try XCTUnwrap(detect(file, .blocked), file)
            XCTAssertEqual(q.kind, .choice)
            XCTAssertTrue(q.isReview)
            XCTAssertNil(q.step)
            XCTAssertFalse(q.text.contains("Review your answers"), "the heading is in the title")
            XCTAssertTrue(q.text.contains("Colour?") && q.text.contains("→ "))
            XCTAssertEqual(q.options.map(\.label), ["Submit answers", "Cancel"])
            XCTAssertEqual(q.options.map(\.keys), [["1"], ["2"]])
            XCTAssertFalse(q.terminalOnly)
            XCTAssertTrue(q.title.hasPrefix("Review your answers · Colour"))
        }
    }

    func testATwoQuestionCallAndTheFirstOneQuestionTabsFixture() throws {
        let q = try XCTUnwrap(detect("choice-tabs2-1.txt", .blocked))
        XCTAssertEqual(q.tabs, ["Colour", "Size"])
        XCTAssertEqual(q.step, 1)
        XCTAssertEqual(q.title, "Question 1 of 2 · Colour · Size")
        let second = try XCTUnwrap(detect("choice-tabs2-2.txt", .blocked))
        XCTAssertEqual(second.step, 2)
        XCTAssertEqual(second.text, "Size?")
        let old = try XCTUnwrap(detect("choice-tabs.txt", .blocked))
        XCTAssertFalse(old.terminalOnly)
        XCTAssertEqual(old.step, 1)
    }

    func testTabNamesWithSeveralWordsStayWhole() {
        let screen = "────────\n← ☐ Pass on ☐ Kurulum ☐ Test kartı ✔ Submit →\n\nTest kartı nasıl?\n\n❯ 1. A\n  2. B\n  3. Type something.\n────────────────────\n  4. Chat about this\n\nEnter to select · Tab/Arrow keys to navigate · Esc to cancel\n"
        let q = QuestionDetector.detect(screen: screen, state: .blocked)
        XCTAssertEqual(q?.tabs, ["Pass on", "Kurulum", "Test kartı"])
        XCTAssertEqual(q?.step, 3, "the tab whose name the question carries")
        XCTAssertEqual(q?.terminalOnly, false)
    }

    func testATypedAnswerKeepsTheTabAnAnswerableMenu() throws {
        let q = try XCTUnwrap(detect("choice-tabs2-typed.txt", .blocked))
        XCTAssertEqual(q.text, "Colour?")
        XCTAssertFalse(q.terminalOnly)
    }
}
