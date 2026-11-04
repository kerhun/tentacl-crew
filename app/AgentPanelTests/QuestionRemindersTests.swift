import XCTest
@testable import AgentPanel

final class QuestionRemindersTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func q(_ text: String = "Proceed?", pane: String = "p1") -> PendingQuestion {
        PendingQuestion(paneID: pane, sessionID: "s", agentLabel: "dev", cardID: "N1",
                        question: AgentQuestion(kind: .choice, title: "", text: text, options: [QuestionOption(number: 1, label: "Yes", detail: "", isSpecial: false)]))
    }

    private func stages(_ r: inout QuestionReminders, _ question: PendingQuestion, at minutes: Double) -> [QuestionReminders.Stage] {
        r.step(questions: [question], now: t0 + minutes * 60).due.map(\.stage)
    }

    func testScheduleIsZeroFiveFifteenThirtyEachOnce() {
        var r = QuestionReminders(), question = q()
        XCTAssertEqual(stages(&r, question, at: 0), [])
        XCTAssertEqual(stages(&r, question, at: 4.9), [])
        XCTAssertEqual(stages(&r, question, at: 5), [.five])
        XCTAssertEqual(stages(&r, question, at: 6), [], "no duplicate after another poll")
        XCTAssertEqual(stages(&r, question, at: 15), [.fifteen])
        XCTAssertEqual(stages(&r, question, at: 29), [])
        XCTAssertEqual(stages(&r, question, at: 30), [.thirty])
        XCTAssertEqual(stages(&r, question, at: 90), [], "nothing after the 30-min notice")
    }

    func testStalledPollFiresOnlyTheLatestStage() {
        var r = QuestionReminders(), question = q()
        _ = stages(&r, question, at: 0)
        XCTAssertEqual(stages(&r, question, at: 20), [.fifteen])
        XCTAssertEqual(stages(&r, question, at: 21), [])
    }

    func testAnsweredQuestionIsCancelledAndNeverReminded() {
        var r = QuestionReminders(), question = q()
        _ = stages(&r, question, at: 0)
        let gone = r.step(questions: [], now: t0 + 60)
        XCTAssertEqual(gone.cancelled, [question.id])
        XCTAssertEqual(gone.due, [])
        XCTAssertEqual(r.step(questions: [], now: t0 + 600).cancelled, [], "cancelled once")
        XCTAssertEqual(QuestionReminders.notificationIDs(question.id).count, 3)
    }

    func testEachQuestionHasItsOwnClock() {
        var r = QuestionReminders()
        let a = q(pane: "a"), b = q(pane: "b")
        _ = r.step(questions: [a], now: t0)
        let out = r.step(questions: [a, b], now: t0 + 300)
        XCTAssertEqual(out.due.map(\.question.id), [a.id])
    }

    func testReminderNotificationTextAndPMButton() {
        let due = QuestionReminders.Due(question: q(), stage: .fifteen)
        let n = QuestionReminders.notification(for: due, prefix: "", sound: .crew, bounce: true, letPM: true)
        XCTAssertEqual(n.title, "Still waiting · dev · N1 (15 min)")
        XCTAssertTrue(n.actions.contains { $0.id == "pm" })
        XCTAssertFalse(n.bounce, "only the 5-min reminder bounces")
        let five = QuestionReminders.notification(for: .init(question: q(), stage: .five), prefix: "", sound: .crew, bounce: true, letPM: true)
        XCTAssertTrue(five.bounce)
        XCTAssertFalse(five.actions.contains { $0.id == "pm" }, "Let the PM decide only at 15 min")
    }

    func testPMLineIsOneLineAndShort() {
        let line = QuestionReminders.pmLine(q("Which colour?\nBlue or red?"))
        XCTAssertEqual(line, "dev · N1 has waited 30 min for the user's answer: “Which colour? Blue or red?”")
    }

    func testPMNoticeDeliversTheLineWhenIdleAndDropsItWhenOff() async {
        var notice = PMNotice(told: [:])
        notice.add("dev · N1 has waited 30 min for the user's answer: “x”")
        var sent: [String] = []
        await notice.deliver(enabled: false, agents: []) { _, _, text in sent.append(text) }
        XCTAssertTrue(notice.pending.isEmpty)
        XCTAssertTrue(sent.isEmpty)
    }
}
