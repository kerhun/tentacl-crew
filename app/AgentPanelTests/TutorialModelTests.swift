import XCTest
@testable import AgentPanel

/// N311: Next/Back/Skip, steps whose target is missing, Done, screens, the example and alone steps, the welcome card and the nudge.
@MainActor
final class TutorialModelTests: XCTestCase {
    private var defaults: UserDefaults!
    override func setUp() { defaults = makeTestDefaults(prefix: "tutorial-model") }

    private func model(screen: ShellScreen = .dashboard, autoOffer: Bool = false, anchors: Set<TutorialAnchorID> = Set(TutorialAnchorID.allCases)) -> TutorialModel {
        let m = TutorialModel(store: TutorialStore(defaults: defaults), autoOffer: autoOffer, screen: screen)
        m.anchorsChanged(host: TutorialOverlay.windowHost, anchors)
        return m
    }

    func testNextBackSkip() {
        let m = model()
        m.start(.dashboard)
        XCTAssertEqual(m.active, .dashboard)
        XCTAssertEqual(m.index, 0)
        XCTAssertEqual(m.position.n, 1)
        XCTAssertEqual(m.position.of, 8)
        m.next()
        XCTAssertEqual(m.index, 1)
        m.back()
        XCTAssertEqual(m.index, 0)
        m.next(); m.next()
        m.skip()
        XCTAssertNil(m.active)
        XCTAssertEqual(m.progress(.dashboard).state, .skipped)
    }

    func testMissingTargetIsSkippedAndTheCounterShrinks() {
        var anchors = Set(TutorialAnchorID.allCases)
        anchors.remove(.projectPicker)
        let m = model(anchors: anchors)
        m.start(.dashboard)
        m.next()
        XCTAssertEqual(m.step?.anchor, .dashboardWaiting)
        XCTAssertEqual(m.position.n, 2)
        XCTAssertEqual(m.position.of, 7)
        m.back()
        XCTAssertEqual(m.step?.anchor, .rail, "Back passes over the missing step too")
    }

    func testTargetThatGoesAwaySkipsForward() {
        let m = model()
        m.start(.chat, at: 4)
        XCTAssertEqual(m.step?.anchor, .chatStop)
        var anchors = Set(TutorialAnchorID.allCases)
        anchors.remove(.chatStop)
        m.anchorsChanged(host: TutorialOverlay.windowHost, anchors)
        XCTAssertEqual(m.step?.anchor, .chatShowAll, "The PM went idle: Stop is skipped")
    }

    func testDoneMarksFinishedAndFirstLaunchOffersTheDashboard() {
        let m = model(screen: .tasks)
        m.start(.firstLaunch)
        for _ in 0..<10 where m.active != nil { m.next() }
        XCTAssertNil(m.active)
        XCTAssertEqual(m.progress(.firstLaunch).state, .finished)
        XCTAssertEqual(m.card, .offerDashboard)

        m.start(.plan)
        while m.active != nil { m.next() }
        XCTAssertEqual(m.progress(.plan).state, .finished)
        XCTAssertEqual(TutorialStore(defaults: defaults).load().progress(.plan).state, .finished, "saved")
    }

    func testStepOnAnotherScreenGoesThereAndALeaveIsAPause() {
        let m = model(screen: .dashboard)
        var opened: [ShellScreen] = []
        m.navigate = { opened.append($0); m.screenChanged(to: $0) }
        m.start(.tasks)
        XCTAssertEqual(opened, [.tasks])
        m.next(); m.next()
        m.screenChanged(to: .git)
        XCTAssertNil(m.active)
        XCTAssertEqual(m.progress(.tasks).state, .inProgress)
        XCTAssertEqual(m.progress(.tasks).step, 2)
        XCTAssertEqual(m.resumable, .tasks)
        XCTAssertEqual(m.stateLabel(.tasks), "resume · step 3 of 7")
        m.open(.tasks)
        XCTAssertEqual(m.index, 2, "Resume goes on at the saved step")
    }

    func testExampleQuestionWhenNoneIsOpen() {
        var anchors = Set(TutorialAnchorID.allCases)
        anchors.remove(.chatQuestion)
        let m = model(anchors: anchors)
        m.start(.chat, at: 3)
        XCTAssertEqual(m.step?.anchor, .chatQuestion)
        XCTAssertTrue(m.showsExample)
        XCTAssertEqual(m.highlighted, .chatMessage)
    }

    func testPreviewWithoutAPageIsOneStep() {
        var anchors = Set(TutorialAnchorID.allCases)
        anchors.subtract([.previewButton, .previewAddress, .previewPick, .previewScreenshot])
        let m = model(anchors: anchors)
        m.start(.preview)
        XCTAssertTrue(m.isAlone)
        XCTAssertEqual(m.position.n, 1)
        XCTAssertEqual(m.position.of, 1)
        XCTAssertEqual(m.highlighted, .pmChat)
        XCTAssertEqual(m.text, "The Preview opens when the PM shares a page.")
        m.next()
        XCTAssertEqual(m.progress(.preview).state, .finished)
    }

    func testOpeningTheSheetMovesOn() {
        let m = model(screen: .tasks, anchors: [.setupButton, .addProject, .rail])
        m.start(.firstLaunch, at: 1)
        m.anchorsChanged(host: "addProject", [.addProjectKind, .addProjectStartsPM, .addProjectCreate])
        XCTAssertEqual(m.step?.anchor, .addProjectKind)
    }

    func testTheTourNeverDependsOnAButtonPress() {
        // The steps only name anchors; nothing in a tour holds an action.
        for tour in TutorialTours.all { XCTAssertFalse(tour.steps.isEmpty) }
        XCTAssertEqual(TutorialTours.all.map(\.steps.count), [6, 8, 7, 7, 4, 4, 3])
    }

    func testWelcomeOnceAndNotNowSkips() {
        let m = model(screen: .tasks, autoOffer: true)
        m.offerFirstLaunch(noProjects: true, sheetOpen: true)
        XCTAssertNil(m.card, "never over an open sheet")
        m.offerFirstLaunch(noProjects: true, sheetOpen: false)
        XCTAssertEqual(m.card, .welcome)
        m.declineWelcome()
        XCTAssertEqual(m.progress(.firstLaunch).state, .skipped)
        m.offerFirstLaunch(noProjects: true, sheetOpen: false)
        XCTAssertNil(m.card)
    }

    func testNudgeOncePerScreenAfterFirstLaunch() {
        let m = model(screen: .tasks, autoOffer: true)
        m.screenChanged(to: .plan)
        XCTAssertNil(m.nudge, "not before first launch is done or skipped")
        m.declineWelcome()
        m.screenChanged(to: .plan)
        XCTAssertEqual(m.nudge, .plan)
        m.nudge = nil
        m.screenChanged(to: .git)
        m.screenChanged(to: .plan)
        XCTAssertNil(m.nudge, "once per screen, none on a screen without a tour")
        m.setOfferOnNewScreen(false)
        m.screenChanged(to: .tasks)
        XCTAssertNil(m.nudge)
    }

    func testDismissNudgeClearsItAndKeepsTheScreenSeen() {
        let m = model(screen: .tasks, autoOffer: true)
        m.declineWelcome()
        m.screenChanged(to: .plan)
        XCTAssertEqual(m.nudge, .plan)
        m.dismissNudge()
        XCTAssertNil(m.nudge)
        let reloaded = TutorialModel(store: TutorialStore(defaults: defaults), autoOffer: true, screen: .tasks)
        reloaded.screenChanged(to: .plan)
        XCTAssertNil(reloaded.nudge, "the screen stays seen after a restart")
        m.dismissNudge()
        XCTAssertNil(m.nudge, "a second dismiss does nothing")
    }

    func testResetClearsProgress() {
        let m = model()
        m.start(.dashboard); m.skip()
        m.reset()
        XCTAssertEqual(m.progress(.dashboard).state, .notStarted)
        XCTAssertEqual(m.summary, "0 of 7 finished")
    }

    func testCommandSearchListsTours() {
        let tours = CommandSearch.Tours(here: .plan, screen: "Plan", resume: (id: .tasks, step: 4, of: 7))
        let rows = CommandSearch.rows(query: "tour", cards: [], projects: [], notes: [], tours: tours, pmMissing: nil)
        XCTAssertEqual(rows.filter { $0.kind == .tour }.map(\.title), ["Tour this screen", "Resume Tasks tour", "All tours…"])
        XCTAssertEqual(rows.first { $0.id == "tour:resume" }?.detail, "step 4 of 7")
        let help = CommandSearch.rows(query: "help", cards: [], projects: [], notes: [], tours: tours, pmMissing: nil)
        XCTAssertEqual(help.filter { $0.kind == .tour }.count, 3)
        let other = CommandSearch.rows(query: "zzz", cards: [], projects: [], notes: [], tours: tours, pmMissing: nil)
        XCTAssertTrue(other.allSatisfy { $0.kind != .tour })
    }
}
