import XCTest
@testable import AgentPanel

final class NotifierTests: XCTestCase {
    func testSoundPathPerKind() {
        XCTAssertNotNil(NotificationSound.standard.systemSound)
        XCTAssertFalse(NotificationSound.standard.playsLocally)
        for s in [NotificationSound.crew, .named("Glass")] { XCTAssertNil(s.systemSound); XCTAssertTrue(s.playsLocally) }
        XCTAssertNil(NotificationSound.silent.systemSound)
        XCTAssertFalse(NotificationSound.silent.playsLocally)
    }

    private func question(_ kind: AgentQuestion.Kind, pane: String = "p1", text: String = "Proceed?") -> PendingQuestion {
        PendingQuestion(paneID: pane, sessionID: nil, agentLabel: "dev N1", cardID: "N1",
                        question: AgentQuestion(kind: kind, title: "", text: text, options: []))
    }

    private func card(_ id: String, _ title: String = "Do it") -> TaskCard { TaskCard(id: id, project: "d", status: .review, agent: nil, branch: nil, kind: nil, files: [], title: title, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md")) }

    private func primed() -> NotificationPlanner {
        var p = NotificationPlanner()
        _ = p.plan(questions: [], reviewCards: [], enabled: true, focused: false)
        return p
    }

    private func pmQuestion() -> PendingQuestion {
        var q = question(.choice, pane: "pm")
        q.isPM = true
        return q
    }

    func testPMQuestionOpen30sNotifiesOnceInFocusedWindowOffDashboard() {
        var p = primed()
        let t0 = Date(timeIntervalSince1970: 1000), q = pmQuestion()
        func look(_ dt: TimeInterval, dash: Bool = false) -> Int {
            p.plan(questions: [q], reviewCards: [], enabled: true, focused: true, onDashboard: dash, now: t0 + dt).count
        }
        XCTAssertEqual(look(0), 0)
        XCTAssertEqual(look(29), 0, "before 30 s")
        XCTAssertEqual(look(31, dash: true), 0, "on the Dashboard the card is visible")
        XCTAssertEqual(look(32), 1)
        XCTAssertEqual(look(60), 0, "never twice")
    }

    func testPMQuestionNotifiedWhileAwayIsNotRepeatedAfter30s() {
        var p = primed()
        let t0 = Date(timeIntervalSince1970: 1000), q = pmQuestion()
        XCTAssertEqual(p.plan(questions: [q], reviewCards: [], enabled: true, focused: false, now: t0).count, 1)
        XCTAssertEqual(p.plan(questions: [q], reviewCards: [], enabled: true, focused: true, onDashboard: false, now: t0 + 40).count, 0)
    }

    func testCardAgentQuestionIsNotNotifiedInFocusedWindow() {
        var p = primed()
        let t0 = Date(timeIntervalSince1970: 1000), q = question(.choice)
        _ = p.plan(questions: [q], reviewCards: [], enabled: true, focused: true, onDashboard: false, now: t0)
        XCTAssertEqual(p.plan(questions: [q], reviewCards: [], enabled: true, focused: true, onDashboard: false, now: t0 + 60).count, 0)
    }

    func testFirstLookOnlyRecordsWhatIsAlreadyThere() {
        var p = NotificationPlanner()
        XCTAssertTrue(p.plan(questions: [question(.permission)], reviewCards: [card("N1")], enabled: true, focused: false).isEmpty)
        XCTAssertTrue(p.plan(questions: [question(.permission)], reviewCards: [card("N1")], enabled: true, focused: false).isEmpty)
    }

    func testNewQuestionNotifiesOnceWhateverTheKind() {
        var p = primed()
        for kind in [AgentQuestion.Kind.choice, .freeText, .permission, .plan] {
            let q = question(kind, pane: "pane-\(kind)")
            XCTAssertEqual(p.plan(questions: [q], reviewCards: [], enabled: true, focused: false).count, 1)
            XCTAssertTrue(p.plan(questions: [q], reviewCards: [], enabled: true, focused: false).isEmpty)
            _ = p.plan(questions: [], reviewCards: [], enabled: true, focused: false)
        }
    }

    func testTaskReadyForReviewNotifiesOnce() {
        var p = primed()
        let n = p.plan(questions: [], reviewCards: [card("N2", "Notify")], enabled: true, focused: false)
        XCTAssertEqual(n.map(\.cardID), ["N2"])
        XCTAssertTrue(n[0].body.contains("Notify"))
        XCTAssertTrue(p.plan(questions: [], reviewCards: [card("N2")], enabled: true, focused: false).isEmpty)
    }

    func testEventSeenWhileFocusedNeverNotifies() {
        var p = primed()
        XCTAssertTrue(p.plan(questions: [question(.plan)], reviewCards: [card("N2")], enabled: true, focused: true).isEmpty)
        XCTAssertTrue(p.plan(questions: [question(.plan)], reviewCards: [card("N2")], enabled: true, focused: false).isEmpty)
    }

    func testNothingWhileOffAndTurningOnDoesNotReplayOldEvents() {
        var p = primed()
        XCTAssertTrue(p.plan(questions: [question(.plan)], reviewCards: [card("N2")], enabled: false, focused: false).isEmpty)
        XCTAssertTrue(p.plan(questions: [question(.plan)], reviewCards: [card("N2")], enabled: true, focused: false).isEmpty)
    }

    func testAnEventThatCameBackNotifiesAgain() {
        var p = primed()
        XCTAssertEqual(p.plan(questions: [question(.permission)], reviewCards: [], enabled: true, focused: false).count, 1)
        _ = p.plan(questions: [], reviewCards: [], enabled: true, focused: false)
        XCTAssertEqual(p.plan(questions: [question(.permission)], reviewCards: [], enabled: true, focused: false).count, 1)
    }

    func testTwoEventsAtOnceGiveTwoNotifications() {
        var p = primed()
        XCTAssertEqual(p.plan(questions: [question(.permission)], reviewCards: [card("N2")], enabled: true, focused: false).count, 2)
    }

    private func extras(round: [String] = [], fixes: [(String, String)] = [], limit: String? = nil, reply: (String, String)? = nil, stuck: [(String, String)] = []) -> NotificationExtras {
        NotificationExtras(roundCardIDs: round, escalatedFixes: fixes.map { .init(cardID: $0.0, reason: $0.1) }, costLimitDay: limit, pmReply: reply.map { .init(id: $0.0, text: $0.1) },
                           stuckAgents: stuck.map { .init(cardID: $0.0, since: $0.1) })
    }

    func testAStuckAgentNotifiesOnceAndAgainWhenItStopsAnotherTime() {
        var p = primed()
        let n = p.plan(questions: [], reviewCards: [], extras: extras(stuck: [("N85", "t1")]), enabled: true, focused: false)
        XCTAssertEqual(n.map(\.cardID), ["N85"])
        XCTAssertTrue(n[0].title.contains("N85") && n[0].title.contains("stuck"), n[0].title)
        XCTAssertTrue(p.plan(questions: [], reviewCards: [], extras: extras(stuck: [("N85", "t1")]), enabled: true, focused: false).isEmpty)
        XCTAssertEqual(p.plan(questions: [], reviewCards: [], extras: extras(stuck: [("N85", "t2")]), enabled: true, focused: false).count, 1, "stopped again after a nudge")
    }

    func testTheStuckSwitchIsOnByDefaultAndCanBeTurnedOff() {
        XCTAssertTrue(NotificationPrefs().events.contains(.agentStuck))
        XCTAssertFalse(NotificationEvent.agentStuck.title.isEmpty)
        var p = primed()
        var prefs = NotificationPrefs()
        prefs.events.remove(.agentStuck)
        XCTAssertTrue(p.plan(questions: [], reviewCards: [], extras: extras(stuck: [("N85", "t1")]), prefs: prefs, enabled: true, focused: false).isEmpty)
    }

    func testEachNewEventNotifiesOnceWithAStableKey() {
        var p = primed()
        let e = extras(round: ["N1", "N2"], fixes: [("N3", "touches the autopilot")], limit: "2026-10-18", reply: ("r1", "Round done"))
        let n = p.plan(questions: [], reviewCards: [], extras: e, enabled: true, focused: false)
        XCTAssertEqual(n.count, 4)
        XCTAssertEqual(Set(n.map(\.id)).count, 4)
        XCTAssertTrue(n.contains { $0.title.contains("round") })
        XCTAssertTrue(n.contains { $0.cardID == "N3" && $0.body.contains("autopilot") })
        XCTAssertTrue(n.contains { $0.title.lowercased().contains("limit") })
        XCTAssertTrue(n.contains { $0.body == "Round done" })
        XCTAssertTrue(p.plan(questions: [], reviewCards: [], extras: e, enabled: true, focused: false).isEmpty)
    }

    func testANewPMReplyAndANewRoundNotifyAgain() {
        var p = primed()
        XCTAssertEqual(p.plan(questions: [], reviewCards: [], extras: extras(round: ["N1"], reply: ("r1", "a")), enabled: true, focused: false).count, 2)
        XCTAssertEqual(p.plan(questions: [], reviewCards: [], extras: extras(round: ["N1", "N5"], reply: ("r2", "b")), enabled: true, focused: false).count, 2)
    }

    func testOnlyEnabledEventsNotify() {
        var p = primed()
        var prefs = NotificationPrefs()
        prefs.events = [.pmReply]
        let e = extras(round: ["N1"], fixes: [("N3", "x")], limit: "d", reply: ("r1", "hi"))
        let n = p.plan(questions: [question(.plan)], reviewCards: [card("N2")], extras: e, prefs: prefs, enabled: true, focused: false)
        XCTAssertEqual(n.map(\.body), ["hi"])
    }

    func testEachSwitchControlsItsOwnEvent() {
        let all = extras(round: ["N1"], fixes: [("N3", "x")], limit: "d", reply: ("r1", "hi"), stuck: [("N4", "t")])
        for event in NotificationEvent.allCases where event != .updateAvailable {   // sent by PanelModel.notifyUpdate, not the planner
            var p = NotificationPlanner()
            var prefs = NotificationPrefs()
            prefs.events.remove(event)
            _ = p.plan(questions: [], reviewCards: [], prefs: prefs, enabled: true, focused: false)
            let n = p.plan(questions: [question(.permission)], reviewCards: [card("N2")], extras: all, prefs: prefs, enabled: true, focused: false)
            XCTAssertEqual(n.count, NotificationEvent.allCases.count - 2, "\(event)")
        }
    }

    func testTurningAnEventOnDoesNotReplayWhatHappenedWhileItWasOff() {
        var p = primed()
        var off = NotificationPrefs()
        off.events.remove(.pmReply)
        XCTAssertTrue(p.plan(questions: [], reviewCards: [], extras: extras(reply: ("r1", "hi")), prefs: off, enabled: true, focused: false).isEmpty)
        XCTAssertTrue(p.plan(questions: [], reviewCards: [], extras: extras(reply: ("r1", "hi")), enabled: true, focused: false).isEmpty)
    }

    func testSoundFlagIsCarriedOnTheNotification() {
        var p = primed()
        var quiet = NotificationPrefs()
        quiet.sound = false
        XCTAssertEqual(p.plan(questions: [question(.permission)], reviewCards: [], prefs: quiet, enabled: true, focused: false).map(\.sound), [.silent])
        _ = p.plan(questions: [], reviewCards: [], enabled: true, focused: false)
        XCTAssertEqual(p.plan(questions: [question(.permission)], reviewCards: [], enabled: true, focused: false).map(\.sound), [.crew])
    }

    func testEachEventPlaysItsOwnSoundAndMuteSilencesAll() {
        var p = primed()
        var prefs = NotificationPrefs()
        prefs.sounds[.agentAsks] = .named("Glass")
        prefs.sounds[.reviewReady] = .silent
        let n = p.plan(questions: [question(.permission)], reviewCards: [card("N2")], prefs: prefs, enabled: true, focused: false)
        XCTAssertEqual(n.map(\.sound), [.named("Glass"), .silent])
        prefs.sound = false
        _ = p.plan(questions: [], reviewCards: [], enabled: true, focused: false)
        XCTAssertEqual(p.plan(questions: [question(.permission)], reviewCards: [], prefs: prefs, enabled: true, focused: false).map(\.sound), [.silent])
    }

    func testOnlyAnAgentQuestionBouncesTheDock() {
        var p = primed()
        var prefs = NotificationPrefs()
        let n = p.plan(questions: [question(.permission)], reviewCards: [card("N2")], prefs: prefs, enabled: true, focused: false)
        XCTAssertEqual(n.map(\.bounce), [true, false])
        _ = p.plan(questions: [], reviewCards: [], enabled: true, focused: false)
        prefs.dockBounce = false
        XCTAssertEqual(p.plan(questions: [question(.permission)], reviewCards: [], prefs: prefs, enabled: true, focused: false).map(\.bounce), [false])
    }

    func testOldSoundSwitchMigratesToDefaultForEveryEvent() {
        let defaults = makeTestDefaults(prefix: "notify-migrate")
        defaults.set(true, forKey: "notifySound")
        let on = NotificationPrefs.load(defaults)
        XCTAssertTrue(on.sound)
        for event in NotificationEvent.allCases { XCTAssertEqual(on.sound(for: event), .crew) }
        defaults.set(false, forKey: "notifySound")
        let off = NotificationPrefs.load(defaults)
        XCTAssertEqual(off.sound(for: .agentAsks), .silent, "muted")
        XCTAssertEqual(off.sounds[.agentAsks] ?? .crew, .crew, "the picker keeps Tentacl Crew under the mute")
    }

    func testPickedSoundsAndDockSettingsSurviveARestart() {
        let defaults = makeTestDefaults(prefix: "notify-sounds")
        var prefs = NotificationPrefs.load(defaults)
        XCTAssertTrue(prefs.dockBadge); XCTAssertTrue(prefs.dockBounce)
        prefs.sounds[.costLimit] = .named("Basso"); prefs.sounds[.pmReply] = .silent
        prefs.dockBadge = false; prefs.dockBounce = false
        prefs.save(defaults)
        let again = NotificationPrefs.load(defaults)
        XCTAssertEqual(again.sound(for: .costLimit), .named("Basso"))
        XCTAssertEqual(again.sound(for: .pmReply), .silent)
        XCTAssertEqual(again.sound(for: .agentAsks), .crew)
        XCTAssertFalse(again.dockBadge); XCTAssertFalse(again.dockBounce)
    }

    func testPMReplyIsPlainAndCheckMarkRepliesStaySilent() {
        func replies(_ text: String) -> [AppNotification] {
            var p = primed()
            return p.plan(questions: [], reviewCards: [], extras: NotificationExtras(pmReply: .init(id: "r1", text: text)), enabled: true, focused: false)
        }
        XCTAssertEqual(replies("- **N334:** curl (`install.sh`)").map(\.body), ["• N334: curl (install.sh)"])
        for s in ["✓", " ✓. ", "✅"] { XCTAssertTrue(replies(s).isEmpty, s) }
        XCTAssertEqual(replies("✓ merged N333").count, 1)
    }

    func testCrewSoundIsDefaultStoredChoicesStayAndTheCafIsBundled() {
        XCTAssertEqual(NotificationPrefs().sound(for: .pmReply), .crew)
        let d = makeTestDefaults(prefix: "notify-crew")
        var prefs = NotificationPrefs.load(d); prefs.sounds[.pmReply] = .named("Glass"); prefs.sounds[.costLimit] = .standard; prefs.save(d)
        let again = NotificationPrefs.load(d)
        XCTAssertEqual(again.sound(for: .pmReply), .named("Glass")); XCTAssertEqual(again.sound(for: .costLimit), .standard)
        XCTAssertNotNil(NotificationSound.crewURL, "TentaclCrew.caf is in the app bundle")
    }

    func testSoundStoredFormRoundTrips() {
        for s in [NotificationSound.silent, .standard, .crew, .named("Glass")] { XCTAssertEqual(NotificationSound(stored: s.stored), s) }
        XCTAssertTrue(NotificationSound.systemSounds().contains("Glass") || !FileManager.default.fileExists(atPath: "/System/Library/Sounds/Glass.aiff"))
    }

    func testPrefsDefaultToOnAndSurviveARestart() throws {
        let defaults = makeTestDefaults(prefix: "notify-prefs")
        var prefs = NotificationPrefs.load(defaults)
        XCTAssertEqual(prefs.events, Set(NotificationEvent.allCases))
        XCTAssertTrue(prefs.sound)
        prefs.events.remove(.roundReady)
        prefs.sound = false
        prefs.save(defaults)
        let again = NotificationPrefs.load(defaults)
        XCTAssertEqual(again.events, prefs.events); XCTAssertEqual(again.sound, prefs.sound)
        XCTAssertFalse(again.events.contains(.roundReady))
    }

    @MainActor func testTurningOnAsksForPermissionAndDenialSwitchesItOff() async {
        let sender = FakeSender(granted: false)
        let on = await Notifier.enable(sender)
        XCTAssertFalse(on)
        XCTAssertEqual(sender.authorizationRequests, 1)
        sender.granted = true
        let again = await Notifier.enable(sender)
        XCTAssertTrue(again)
    }
}

final class QuestionNoticeTests: XCTestCase {
    private func opt(_ n: Int, _ label: String, _ role: OptionRole = .plain, special: Bool = false) -> QuestionOption { QuestionOption(number: n, label: label, detail: "", isSpecial: special, role: role) }
    private func ask(_ kind: AgentQuestion.Kind, _ options: [QuestionOption] = []) -> AgentQuestion { AgentQuestion(kind: kind, title: "", text: "Q?", options: options) }
    private func ids(_ q: AgentQuestion, letPM: Bool = false) -> [String] { QuestionNotice.actions(for: q, letPM: letPM).map(\.id) }

    func testMenuHasUpToThreeOptionsAndOpen() {
        let q = ask(.choice, [opt(1, "A"), opt(2, "B"), opt(3, "C"), opt(4, "D"), opt(5, "Type something.", special: true)])
        XCTAssertEqual(ids(q), ["opt:1", "opt:2", "opt:3", "open"])
        XCTAssertEqual(QuestionNotice.actions(for: q)[0].title, "1 · A")
    }

    func testFreeQuestionHasAReplyField() {
        let a = QuestionNotice.actions(for: ask(.freeText))
        XCTAssertEqual(a.map(\.id), ["reply", "open"])
        XCTAssertTrue(a[0].textInput)
    }

    func testPermissionOffersAllowOnceAndDenyNeverAlways() {
        let q = ask(.permission, [opt(1, "Yes", .allow), opt(2, "Yes, and don't ask again for ls commands", .allowAlways), opt(3, "No", .deny)])
        XCTAssertEqual(ids(q), ["allow", "deny", "open"])
        XCTAssertEqual(QuestionNotice.answer(action: "allow", text: "", for: q), .option(q.options[0]))
        XCTAssertEqual(QuestionNotice.answer(action: "deny", text: "", for: q), .option(q.options[2]))
        XCTAssertNil(QuestionNotice.answer(action: "opt:2", text: "", for: q), "never don't-ask-again")
    }

    func testPlanAndSignInOnlyOpen() {
        XCTAssertEqual(ids(ask(.plan, [opt(1, "Yes")])), ["open"])
        XCTAssertEqual(ids(ask(.signIn)), ["open"])
    }

    func testLetThePMDecideOnlyWhenAsked() {
        XCTAssertEqual(ids(ask(.freeText), letPM: true), ["reply", "pm", "open"])
        XCTAssertEqual(QuestionNotice.answer(action: "pm", text: "", for: ask(.freeText)), .passToPM)
    }

    func testReplyTextReachesTheAnswerPath() {
        XCTAssertEqual(QuestionNotice.answer(action: "reply", text: "  blue \n", for: ask(.freeText)), .text("blue"))
        XCTAssertNil(QuestionNotice.answer(action: "reply", text: "  ", for: ask(.freeText)))
        let typed = ask(.choice, [opt(1, "A"), opt(2, "Type something.", special: true)])
        XCTAssertEqual(QuestionNotice.answer(action: "reply", text: "red", for: typed), .typed("red"))
        XCTAssertEqual(QuestionNotice.answer(action: "opt:1", text: "", for: typed), .option(typed.options[0]))
        XCTAssertNil(QuestionNotice.answer(action: "opt:2", text: "", for: typed), "special options are answered in the terminal")
    }

    func testPlannerAttachesTheButtonsToAQuestionNotification() {
        var p = NotificationPlanner()
        _ = p.plan(questions: [], reviewCards: [], enabled: true, focused: false)
        let q = PendingQuestion(paneID: "p", sessionID: "s", agentLabel: "dev N1", cardID: "N1", question: ask(.choice, [opt(1, "A")]))
        let notes = p.plan(questions: [q], reviewCards: [], enabled: true, focused: false)
        XCTAssertEqual(notes.first?.questionID, q.id)
        XCTAssertEqual(notes.first?.actions.map(\.id), ["opt:1", "open"])
        XCTAssertEqual(QuestionNotice.categoryID(notes[0].actions), "question:opt:1=1 · A|open=Open")
    }
}

private final class FakeSender: NotificationSending, @unchecked Sendable {
    var granted: Bool
    var authorizationRequests = 0
    var sent: [AppNotification] = []
    init(granted: Bool) { self.granted = granted }
    func requestAuthorization() async -> Bool { authorizationRequests += 1; return granted }
    func send(_ notification: AppNotification) async { sent.append(notification) }
}
