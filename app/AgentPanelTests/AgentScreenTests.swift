import XCTest
@testable import AgentPanel

final class AgentScreenTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }

    // MARK: detecting (screens captured from a real agent)

    func testChoiceMenuYieldsTheQuestionAndItsOptions() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-before.txt"), state: .blocked))
        XCTAssertEqual(q.kind, .choice)
        XCTAssertEqual(q.title, "Colour")
        XCTAssertEqual(q.text, "Which colour do you prefer?")
        XCTAssertEqual(q.options.filter { !$0.isSpecial }.map(\.label), ["Red", "Green", "Blue"])
        XCTAssertEqual(q.options.filter { !$0.isSpecial }.map(\.keys), [["1"], ["2"], ["3"]])
        XCTAssertEqual(q.options.first?.detail, "Red")
        XCTAssertEqual(q.options.filter(\.isSpecial).map(\.label), ["Type something.", "Chat about this"], "options the panel cannot answer are marked")
    }

    func testTheBoxBorderIsNotPartOfTheHeadingOrTheQuestion() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-bordered.txt"), state: .blocked))
        XCTAssertEqual(q.title, "Colour")
        XCTAssertEqual(q.text, "Which colour should the welcome banner use?")
        XCTAssertEqual(q.options.filter { !$0.isSpecial }.map(\.label), ["Red", "Green"])
    }

    func testABorderCharacterInsideTheTextStays() throws {
        let screen = " ☐ Pick\n│ Is a │ b the pipe? │\n❯ 1. Yes\n  2. No\n  3. Type something.\nEnter to select"
        XCTAssertEqual(QuestionDetector.detect(screen: screen, state: .blocked)?.text, "Is a │ b the pipe?")
    }

    func testAPlainQuestionAtTheEndOfAFinishedTurnIsAFreeTextQuestion() throws {
        for state in [AgentState.done, .idle] {
            let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("freetext-before.txt"), state: state))
            XCTAssertEqual(q.kind, .freeText)
            XCTAssertEqual(q.text, "Which screen do you mean?")
            XCTAssertEqual(q.options, [])
        }
    }

    func testTheSecondQuestionAfterAMenuAnswerIsFound() throws {
        // captured right after a menu was answered: the "User answered Claude's questions" block, then a plain question
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("freetext-after-menu.txt"), state: .done))
        XCTAssertEqual(q.kind, .freeText)
        XCTAssertEqual(q.text, "Should the tab get an icon too?")
    }

    func testTheGhostSuggestionInThePromptBoxIsNeverTheQuestion() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("freetext-before.txt"), state: .done))
        XCTAssertFalse(q.text.contains("home screen"))
    }

    func testNothingIsAskedWhileTheAgentWorks() throws {
        XCTAssertNil(QuestionDetector.detect(screen: try fixture("freetext-before.txt"), state: .working))
        XCTAssertNil(QuestionDetector.detect(screen: try fixture("choice-before.txt"), state: .working))
    }

    func testANumberedListInAFinishedReportIsNotAChoiceMenu() throws {
        XCTAssertNil(QuestionDetector.detect(screen: try fixture("choice-before.txt"), state: .done), "a numbered list is a menu only while the agent is blocked")
    }

    func testAFinishedReportWithoutAQuestionIsNotAQuestion() {
        let screen = "⏺ I checked the tab bar. All five items have labels.\n✻ Brewed for 9s\n────\n❯\n────\n  ⏵⏵ accept edits on\n"
        XCTAssertNil(QuestionDetector.detect(screen: screen, state: .done))
    }

    func testAMultiLineMessageThatEndsWithAQuestionCounts() {
        let screen = "⏺ I found two candidates:\n  the Home tab and the Feed tab.\n  Which one should I use?\n✻ Brewed for 3s\n────\n❯\n────\n"
        let q = QuestionDetector.detect(screen: screen, state: .idle)
        XCTAssertEqual(q?.kind, .freeText)
        XCTAssertTrue(q?.text.contains("Which one should I use?") == true)
        XCTAssertTrue(q?.text.contains("Home tab") == true)
    }

    func testALongFinishedReportThatEndsInAQuestionMarkIsNotACard() {
        let long = String(repeating: "This part of the report explains what was done. ", count: 12)
        let screen = "⏺ \(long)\n  Is that not what you would expect?\n✻ Brewed for 3s\n────\n❯\n────\n"
        XCTAssertNil(QuestionDetector.detect(screen: screen, state: .done))
        XCTAssertEqual(QuestionDetector.detect(screen: screen, state: .idle)?.kind, .freeText, "an idle agent is still waiting for the user")
    }

    func testTheMarkerWithAVariationSelectorStillMatches() {
        let screen = "⏺\u{fe0f} Which one do you mean?\n✻ Brewed for 3s\n────\n❯\n────\n"
        XCTAssertEqual(QuestionDetector.detect(screen: screen, state: .idle)?.text, "Which one do you mean?")
    }

    func testOnlyTheLastMessageBlockIsLookedAt() {
        let screen = "⏺ Do you want a summary?\n⏺ Here is the summary: it is fine.\n✻ Brewed for 3s\n────\n❯\n────\n"
        XCTAssertNil(QuestionDetector.detect(screen: screen, state: .done), "the older question was already answered by the later message")
    }

    func testABlockedScreenWithoutNumberedOptionsIsNotAChoice() {
        XCTAssertNil(QuestionDetector.detect(screen: "Some output\nmore output\n", state: .blocked))
    }

    func testOptionNumbersAboveNineAreMarkedSpecial() {
        let screen = "────\n ☐ Pick\n\nWhich?\n\n❯ 1. A\n  2. B\n  3. C\n  4. D\n  5. E\n  6. F\n  7. G\n  8. H\n  9. I\n  10. Ten\n────\nEnter to select\n"
        let q = QuestionDetector.detect(screen: screen, state: .blocked)
        XCTAssertEqual(q?.options.filter { !$0.isSpecial }.map(\.label), ["A", "B", "C", "D", "E", "F", "G", "H", "I"])
        XCTAssertEqual(q?.options.last?.isSpecial, true, "a two-digit number has no single key")
    }

    func testTheSignatureChangesWithTheQuestion() throws {
        let a = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-before.txt"), state: .blocked))
        let b = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("freetext-before.txt"), state: .done))
        XCTAssertNotEqual(a.signature, b.signature)
        XCTAssertEqual(a.signature, try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-before.txt"), state: .blocked)).signature)
    }

    // MARK: sending keys

    func testOnlyDigitsEnterEscTabUpAndDownAreAllowed() {
        for ok in ["0", "5", "9", "enter", "esc", "tab", "up", "down", "left", "right"] { XCTAssertTrue(TerminalKeys.isAllowed(ok), ok) }
        for bad in ["", "a", "ctrl-c", "10", ";", "$(id)", "enter;ls", "backspace", "1 2", "escape\n"] { XCTAssertFalse(TerminalKeys.isAllowed(bad), bad) }
    }

    // MARK: review fixes

    private let footer = "Enter to select · ↑/↓ to navigate · Esc to cancel"

    func testANumberedListAboveAMenuIsNotPartOfTheMenu() {
        let screen = "⏺ Plan:\n  1. Add model\n  2. Add view\n  3. Wire tests\n────────────────────────\n ☐ Colour\nWhich colour?\n❯ 1. Red\n     Red\n  2. Green\n     Green\n\(footer)\n"
        let q = QuestionDetector.detect(screen: screen, state: .blocked)
        XCTAssertEqual(q?.options.map(\.label), ["Red", "Green"])
        XCTAssertEqual(q?.text, "Which colour?")
    }

    func testABlockedAgentWithOnlyANumberedListInItsOutputAsksNothing() {
        let screen = "⏺ Found issues:\n  1. Crash on launch\n  2. Memory leak\n"
        XCTAssertNil(QuestionDetector.detect(screen: screen, state: .blocked))
    }

    func testARealPermissionPromptIsAPermissionQuestionWithRolesAndKeys() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("permission-fetch-before.txt"), state: .blocked))
        XCTAssertEqual(q.kind, .permission)
        XCTAssertTrue(q.context.contains("example.com") && q.code?.contains("url: https://example.com/") == true, "the why and the request are apart from the question")
        XCTAssertEqual(q.options.map(\.role), [.allow, .allowAlways, .deny])
        XCTAssertEqual(q.options.map(\.keys), [["1"], ["2"], ["esc"]], "No is answered with Escape, as its label says")
    }

    func testAPlanApprovalIsAPlanQuestionAndFeedbackNeedsTheTerminal() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("plan-approval-before.txt"), state: .blocked))
        XCTAssertEqual(q.kind, .plan)
        XCTAssertTrue(q.text.contains("Would you like to proceed?"))
        XCTAssertTrue(q.context.contains("Step remaining"))
        XCTAssertEqual(q.options.map(\.isSpecial), [false, false, true])
    }

    func testAMenuWithoutACursorLineIsNotAMenu() {
        XCTAssertNil(QuestionDetector.detect(screen: "Pick one\n  1. Red\n  2. Green\n", state: .blocked))
    }

    func testTheAskUserQuestionMenuStaysAChoice() throws {
        XCTAssertEqual(QuestionDetector.detect(screen: try fixture("choice-before.txt"), state: .blocked)?.kind, .choice)
    }

    func testMenuNumbersThatDoNotRunFromOneAreNotAMenu() {
        let screen = "Pick one\n❯ 1. Red\n  3. Green\n\(footer)\n"
        XCTAssertNil(QuestionDetector.detect(screen: screen, state: .blocked))
    }

    // MARK: N239 · readable questions

    func testABashPermissionSeparatesTheQuestionTheWhyAndTheCommand() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("permission-bash-multiline.txt"), state: .blocked))
        XCTAssertEqual(q.kind, .permission)
        XCTAssertEqual(q.text, "Do you want to proceed?", "the question alone, not the heading, the why and the command glued together")
        XCTAssertEqual(q.command, "for f in src/*.swift; do\n  if grep -q \"TODO\" \"$f\"; then\n    echo \"$f has a TODO\"\n  fi\ndone", "line breaks and indentation kept")
        XCTAssertEqual(q.context, "Check every Swift file under src for TODO markers and print the names of the files that have one so the list can be pasted into the card's Report section under the heading Findings", "the soft-wrapped lines are one paragraph")
        XCTAssertFalse(q.text.contains("╌") || q.context.contains("╌"))
    }

    func testAPlansWrappedParagraphsAreJoinedAndItsCodeKeepsItsIndentation() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("plan-wrapped.txt"), state: .blocked))
        XCTAssertEqual(q.kind, .plan)
        XCTAssertTrue(q.context.contains("so a reader has to open the file to find out what it returns. Rename it and update the callers in one commit."), q.context)
        XCTAssertTrue(q.context.contains("\n     let cards = try repo.loadCards()\n     for card in cards { show(card) }"), "the code lines stay separate and indented:\n\(q.context)")
        XCTAssertTrue(q.context.contains("1. Rename `loadStuff`") && q.context.contains("\n2. Update the three callers:"), "list items stay separate")
    }

    func testTheCommandOfAPermissionStillReachesTheAutopilotsOutwardCheck() throws {
        let screen = try fixture("permission-bash-multiline.txt").replacingOccurrences(of: "    echo \"$f has a TODO\"", with: "    gh pr create")
        let q = try XCTUnwrap(QuestionDetector.detect(screen: screen, state: .blocked))
        XCTAssertNotNil(AutopilotRules.mustEscalate(q), "the question text alone is \"Do you want to proceed?\"; the command is checked too")
    }

    func testTwoPermissionsThatDifferOnlyInTheirCommandOrWhyHaveDifferentSignatures() throws {
        let base = try fixture("permission-bash-multiline.txt")
        let a = try XCTUnwrap(QuestionDetector.detect(screen: base, state: .blocked))
        let other = try XCTUnwrap(QuestionDetector.detect(screen: base.replacingOccurrences(of: "echo \"$f has a TODO\"", with: "rm -rf \"$f\""), state: .blocked))
        XCTAssertEqual(a.text, other.text)
        XCTAssertNotEqual(a.signature, other.signature, "the command is part of what the user decided on")
        let why = try XCTUnwrap(QuestionDetector.detect(screen: base.replacingOccurrences(of: "Findings", with: "Elsewhere"), state: .blocked))
        XCTAssertNotEqual(a.signature, why.signature)
    }
}
