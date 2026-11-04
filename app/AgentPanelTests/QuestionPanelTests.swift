import XCTest
@testable import AgentPanel

/// The floating question panel's show/hide rules (N373).
final class QuestionPanelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func q(_ pane: String, _ text: String = "Proceed?") -> PendingQuestion {
        PendingQuestion(paneID: pane, sessionID: "s", agentLabel: "dev", cardID: "N1",
                        question: AgentQuestion(kind: .choice, title: "", text: text, options: [QuestionOption(number: 1, label: "Yes", detail: "", isSpecial: false)]))
    }

    private func step(_ r: inout QuestionPanelRules, _ qs: [PendingQuestion], enabled: Bool = true, active: Bool = false, at minutes: Double = 0,
                      askedAt: [String: Date] = [:]) -> QuestionPanelRules.Decision {
        r.step(questions: qs, askedAt: askedAt, enabled: enabled, appActive: active, now: t0 + minutes * 60)
    }

    func testHiddenWhileTheSettingIsOff() {
        var r = QuestionPanelRules()
        XCTAssertFalse(step(&r, [q("a")], enabled: false).visible)
        XCTAssertTrue(step(&r, [q("a")], enabled: true).visible)
    }

    func testOffByDefault() {
        let defaults = makeTestDefaults(prefix: "question-panel")
        XCTAssertFalse(defaults.bool(forKey: QuestionPanelRules.settingKey))
    }

    func testHiddenWhileTentaclIsTheActiveApp() {
        var r = QuestionPanelRules()
        XCTAssertFalse(step(&r, [q("a")], active: true).visible)
        XCTAssertTrue(step(&r, [q("a")], active: false).visible, "shows again when another app is in front")
    }

    func testHiddenWhenNothingIsOpen() {
        var r = QuestionPanelRules()
        XCTAssertTrue(step(&r, [q("a")]).visible)
        XCTAssertEqual(step(&r, [], at: 1), QuestionPanelRules.Decision(), "closes by itself once answered")
    }

    func testOldestFirstAndCountsTheRest() {
        var r = QuestionPanelRules()
        _ = step(&r, [q("b")], at: 0)
        let d = step(&r, [q("a"), q("b"), q("c")], at: 1)
        XCTAssertEqual(d.shown?.paneID, "b", "seen first")
        XCTAssertEqual(d.more, 2)
        var r2 = QuestionPanelRules(), r3 = QuestionPanelRules()
        let asked = step(&r2, [q("a"), q("b")], askedAt: [q("b").id: t0 - 60, q("a").id: t0 - 30])
        XCTAssertEqual(asked.shown?.paneID, "b", "the inbox's ask time wins")
        let sameTime = step(&r3, [q("x"), q("y")])
        XCTAssertEqual(sameTime.shown?.paneID, "x", "same time: the given order")
    }

    func testClosedByUserStaysHiddenUntilANewQuestion() {
        var r = QuestionPanelRules()
        let open = [q("a"), q("b")]
        XCTAssertTrue(step(&r, open).visible)
        r.close(open: open)
        XCTAssertFalse(step(&r, open, at: 1).visible)
        XCTAssertFalse(step(&r, [q("b")], at: 2).visible, "answering one does not reopen it")
        XCTAssertFalse(step(&r, [q("b")], at: 6).visible, "the 5-min mark does not reopen a closed panel")
        let d = step(&r, [q("b"), q("c")], at: 7)
        XCTAssertTrue(d.visible, "a new question opens it again")
        XCTAssertEqual(d.shown?.paneID, "b", "still oldest first")
    }

    func testClosedThenAllAnsweredThenANewOneOpensIt() {
        var r = QuestionPanelRules()
        _ = step(&r, [q("a")])
        r.close(open: [q("a")])
        XCTAssertFalse(step(&r, [], at: 1).visible)
        XCTAssertTrue(step(&r, [q("z")], at: 2).visible)
    }

    func testComesToFrontOnceAtFiveMinutes() {
        var r = QuestionPanelRules()
        XCTAssertFalse(step(&r, [q("a")], at: 0).raise)
        XCTAssertFalse(step(&r, [q("a")], at: 4.9).raise)
        XCTAssertTrue(step(&r, [q("a")], at: 5).raise)
        XCTAssertFalse(step(&r, [q("a"), q("b")], at: 6).raise, "once per question")
        XCTAssertTrue(step(&r, [q("a"), q("b")], at: 11).raise, "the second question's own 5 min")
    }

    func testFiveMinutesReachedWhileHiddenDoesNotRaiseLater() {
        var r = QuestionPanelRules()
        _ = step(&r, [q("a")], active: true, at: 0)
        XCTAssertFalse(step(&r, [q("a")], active: true, at: 5).raise)
        let d = step(&r, [q("a")], active: false, at: 6)
        XCTAssertTrue(d.visible); XCTAssertFalse(d.raise)
    }

    func testHeadline() {
        XCTAssertEqual(QuestionPanel.headline(total: 1), "1 agent waiting · stays on top")
        XCTAssertEqual(QuestionPanel.headline(total: 3), "3 agents waiting · stays on top")
    }
}
