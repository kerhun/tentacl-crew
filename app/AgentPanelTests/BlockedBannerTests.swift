import XCTest
import SwiftUI
@testable import AgentPanel

/// The floating question card under the waiting pill (N371, N376) and the top bar's pill.
@MainActor
final class BlockedBannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func question(_ pane: String, label: String = "Dev · N12", card: String = "N12", title: String = "Keep the old ids?", isPM: Bool = false) -> PendingQuestion {
        PendingQuestion(paneID: pane, sessionID: "s", agentLabel: label, cardID: card,
                        question: AgentQuestion(kind: .choice, title: title, text: "Which one?", options: []), isPM: isPM)
    }

    private func content(_ qs: [PendingQuestion], askedAt: [String: Date] = [:], at: Date? = nil, onDashboard: Bool = false, tile: Bool = false,
                         hidden: BlockedBanner.Hidden = .init(), suggestion: PMSuggestion? = nil) -> BlockedBanner.Content? {
        BlockedBanner.content(questions: qs, askedAt: askedAt, now: at ?? now, onDashboard: onDashboard, waitingTileShown: tile,
                              hidden: hidden, role: { $0.isPM ? "PM" : "dev" }, suggestion: { _ in suggestion })
    }

    func testHiddenWithoutQuestions() {
        XCTAssertNil(content([]))
    }

    func testShownOnAnotherScreen() {
        let q = question("w1:p1")
        let c = content([q], askedAt: [q.id: now.addingTimeInterval(-7 * 60)], tile: true)
        XCTAssertEqual(c?.heading, WaitingQuestionRowText.make(q, role: "dev", askedAt: now.addingTimeInterval(-7 * 60), now: now).heading,
                       "the Waiting for you row's heading")
        XCTAssertTrue(c?.heading.hasPrefix("Question · dev · N12 · ") == true, c?.heading ?? "")
        XCTAssertEqual(c?.question, "Keep the old ids?")
        XCTAssertEqual(c?.fullQuestion, "Keep the old ids?\n\nWhich one?")
        XCTAssertNil(c?.moreText)
        XCTAssertNil(c?.pmDecide)
    }

    func testDashboardHidesItOnlyWithTheWaitingTile() {
        let q = question("w1:p1")
        XCTAssertNil(content([q], onDashboard: true, tile: true))
        XCTAssertNotNil(content([q], onDashboard: true, tile: false))
    }

    func testOldestFirstAndMore() {
        let a = question("w1:p1", label: "Dev · N1", title: "Newer")
        let b = question("w1:p2", label: "UI · N2", title: "Older")
        let c = question("w1:p3", label: "QA · N3", title: "Middle")
        let asked = [a.id: now.addingTimeInterval(-60), b.id: now.addingTimeInterval(-600), c.id: now.addingTimeInterval(-300)]
        XCTAssertEqual(BlockedBanner.oldestFirst([a, b, c], askedAt: asked, now: now).map(\.paneID), ["w1:p2", "w1:p3", "w1:p1"])
        let shown = content([a, b, c], askedAt: asked)
        XCTAssertEqual(shown?.questionID, b.id)
        XCTAssertEqual(shown?.moreText, "+2 more")
    }

    func testTwoLineQuestionIsCutAt240() {
        let long = String(repeating: "word ", count: 80)
        let c = content([question("w1:p1", title: long)])
        XCTAssertEqual(c?.question.count, 240)
        XCTAssertTrue(c?.question.hasSuffix("…") == true)
        XCTAssertTrue(c?.fullQuestion.hasPrefix(long.trimmingCharacters(in: .whitespaces)) == true, "the tooltip keeps all of it")
    }

    func testLaterHidesForFiveMinutesThenItComesBack() {
        var clock = now
        let model = BlockedBannerModel(clock: { clock })
        let q = question("w1:p1")
        func shown() -> Bool { model.content(questions: [q], askedAt: [:], onDashboard: false, waitingTileShown: false, suggestion: { _ in nil }) != nil }
        XCTAssertTrue(shown())
        model.later(open: [q.id])
        XCTAssertFalse(shown())
        clock = now.addingTimeInterval(4 * 60 + 59)
        XCTAssertFalse(shown())
        clock = now.addingTimeInterval(5 * 60)
        XCTAssertTrue(shown())
    }

    func testLetThePMDecideFromFifteenMinutesOnlyWithASuggestion() {
        let q = question("w1:p1")
        let asked = [q.id: now.addingTimeInterval(-15 * 60)]
        let s = PMSuggestion(option: 2, text: nil, why: "safe", optionLabel: "Keep them")
        XCTAssertEqual(content([q], askedAt: asked, suggestion: s)?.pmDecide, "Let the PM decide (it suggests 2)")
        XCTAssertNil(content([q], askedAt: asked)?.pmDecide, "no suggestion, no button")
        XCTAssertNil(content([q], askedAt: [q.id: now.addingTimeInterval(-14 * 60)], suggestion: s)?.pmDecide, "before 15 min")
        let typed = PMSuggestion(option: nil, text: "Use v2", why: "")
        XCTAssertEqual(content([q], askedAt: asked, suggestion: typed)?.pmDecide, "Let the PM decide (it suggests “Use v2”)")
    }

    func testPMQuestionAndOneLine() {
        let pm = question("w1:p9", label: "PM", card: "", title: "", isPM: true)
        XCTAssertEqual(content([pm])?.heading, "Question · PM")
        XCTAssertEqual(content([pm])?.question, "Which one?")
        XCTAssertEqual(BlockedBanner.oneLine(AgentQuestion(kind: .choice, title: "", text: "Line one\n\n  line two", options: [])), "Line one line two")
        XCTAssertEqual(BlockedBanner.minutes(30), "under 1 min")
        XCTAssertEqual(BlockedBanner.minutes(75 * 60), "1 h 15 min")
    }

    // MARK: N376 visibility rules

    private func shown(_ m: BlockedBannerModel, _ qs: [PendingQuestion], onDashboard: Bool = false, tile: Bool = false) -> Bool {
        m.content(questions: qs, askedAt: [:], onDashboard: onDashboard, waitingTileShown: tile, suggestion: { _ in nil }) != nil
    }

    func testLaterComesBackForANewQuestion() {
        let m = BlockedBannerModel(clock: { self.now })
        let a = question("w1:p1"), b = question("w1:p2")
        m.later(open: [a.id])
        XCTAssertFalse(shown(m, [a]))
        XCTAssertTrue(shown(m, [a, b]), "a new question brings the card back before the 5 min")
    }

    func testEscClosesUntilTheNextNewQuestion() {
        var clock = now
        let m = BlockedBannerModel(clock: { clock })
        let a = question("w1:p1"), b = question("w1:p2")
        m.close(open: [a.id])
        clock = now.addingTimeInterval(3600)
        XCTAssertFalse(shown(m, [a]), "closed stays closed, no timer")
        XCTAssertFalse(shown(m, []))
        XCTAssertTrue(shown(m, [a, b]), "a new question opens it")
        XCTAssertTrue(shown(m, [b]), "also when the old one was answered meanwhile")
    }

    func testPillTogglesTheCard() {
        let m = BlockedBannerModel(clock: { self.now })
        let a = question("w1:p1")
        XCTAssertTrue(shown(m, [a]))
        m.togglePill(shown: true, open: [a.id])
        XCTAssertFalse(shown(m, [a]), "a click on an open card closes it")
        m.togglePill(shown: false, open: [a.id])
        XCTAssertTrue(shown(m, [a]), "a second click opens it")
        m.later(open: [a.id])
        m.togglePill(shown: false, open: [a.id])
        XCTAssertTrue(shown(m, [a]), "the pill opens it over Later")
        XCTAssertTrue(shown(m, [a], onDashboard: true, tile: true), "and on the Dashboard with its tile: it was asked for")
        XCTAssertFalse(shown(m, []), "nothing to show without a question")
    }

    func testDashboardTileHidesEvenANewQuestion() {
        let m = BlockedBannerModel(clock: { self.now })
        let a = question("w1:p1"), b = question("w1:p2")
        m.close(open: [a.id])
        XCTAssertFalse(shown(m, [a, b], onDashboard: true, tile: true), "the tile shows it")
        XCTAssertTrue(shown(m, [a, b], onDashboard: true, tile: false))
    }

    func testEscOnlyWhenNothingElseWantsIt() {
        XCTAssertTrue(BlockedBanner.escCloses(cardShown: true, responderTakesText: false, sheetOpen: false))
        XCTAssertFalse(BlockedBanner.escCloses(cardShown: true, responderTakesText: true, sheetOpen: false), "the Command box or a terminal keeps Esc")
        XCTAssertFalse(BlockedBanner.escCloses(cardShown: true, responderTakesText: false, sheetOpen: true), "a sheet keeps Esc")
        XCTAssertFalse(BlockedBanner.escCloses(cardShown: false, responderTakesText: false, sheetOpen: false))
    }

    // MARK: N376 live-window shots

    /// The Tasks and Terminals screens with the card, dark and light (N376-card-*.png, Terminals as N376-card-*-terminals.png), and
    /// the same screens with the card closed (…-none.png): the content sits at the same place in both, nothing is pushed down.
    func testTheLiveCardShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self, settings: DemoSupport.prepareSettings())
        let open = model.autopilot.forUser(model.inbox.questions)
        XCTAssertEqual(open.count, 1)
        for dark in [true, false] {
            let theme = AppTheme.current
            AppTheme.current = dark ? .dark : .light
            defer { AppTheme.current = theme }
            let name = dark ? "dark" : "light"
            for (screen, suffix) in [(ShellScreen.tasks, ""), (.terminals, "-terminals")] {
                try await DashboardGridSnapshotTests.liveWindowShot(ShellView(model: model, screen: screen).environment(\.questionGlowFixedStrength, 1),
                                                                    dark: dark, "N376-card-\(name)\(suffix).png")
                let closed = BlockedBannerModel()
                closed.close(open: open.map(\.id))
                try await DashboardGridSnapshotTests.liveWindowShot(ShellView(model: model, screen: screen, blockedCard: closed), dark: dark,
                                                                    "N376-card-\(name)\(suffix)-none.png")
            }
        }
    }

    /// The card alone in a real window: +N more with a two-line question (N376-more.png) and Let the PM decide (N376-pm.png).
    func testTheLiveCardVariantShots() async throws {
        let long = "Should the migration keep the old numeric ids as an alias column for one release, so the exports that still read them "
            + "keep working, or drop them now and bump the export format version?"
        let more = BlockedBanner.Content(questionID: "q1", heading: "Question · dev · N377 · 6 min", question: BlockedBanner.oneLine(
            AgentQuestion(kind: .choice, title: long, text: "", options: []), limit: 240), fullQuestion: long, more: 2, pmDecide: nil)
        try await Self.cardShot(more, dark: true, "N376-more.png")
        let s = PMSuggestion(option: 2, text: nil, why: "safe", optionLabel: "Keep them")
        let pm = BlockedBanner.Content(questionID: "q2", heading: "Question · ui_dev · N376 · 17 min", question: "Keep the old ids?",
                                       fullQuestion: "Keep the old ids?", more: 0, pmDecide: BlockedBanner.pmDecideTitle(s))
        try await Self.cardShot(pm, dark: true, "N376-pm.png")
    }

    private static func cardShot(_ content: BlockedBanner.Content, dark: Bool, _ file: String) async throws {
        let root = BlockedBannerView(content: content, notchX: BlockedBanner.cardWidth - 70, onLetPMDecide: content.pmDecide.map { _ in {} })
            .padding(.top, 30).padding([.horizontal, .bottom], 40)
            .frame(width: BlockedBanner.cardWidth + 80, alignment: .top)
            .background(Tok.bg)
            .environment(\.questionGlowFixedStrength, 1)
            .environment(\.colorScheme, dark ? .dark : .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: BlockedBanner.cardWidth + 80, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(file)) }
    }

    func testPillTitle() {
        XCTAssertNil(BlockedBanner.pillTitle(0))
        XCTAssertEqual(BlockedBanner.pillTitle(1), "1 agent waiting on you")
        XCTAssertEqual(BlockedBanner.pillTitle(3), "3 agents waiting on you")
    }

    // MARK: N380: questions the PM is answering

    func testHeldQuestionsShowOnlyWhenThePillOpensTheCard() {
        let h = HeldQuestion(question: question("w1:p2", card: "N13"), since: now)
        XCTAssertNil(BlockedBanner.content(questions: [], askedAt: [:], now: now, onDashboard: false, waitingTileShown: false, suggestion: { _ in nil }, held: [h]),
                     "a held question never brings the card up by itself")
        let opened = BlockedBanner.content(questions: [], askedAt: [:], now: now, onDashboard: true, waitingTileShown: true, hidden: .init(opened: true),
                                           suggestion: { _ in nil }, held: [h])
        XCTAssertEqual(opened?.hasQuestion, false)
        XCTAssertEqual(opened?.held.map(\.id), [h.id])
        let both = BlockedBanner.content(questions: [question("w1:p1")], askedAt: [:], now: now, onDashboard: false, waitingTileShown: false,
                                         suggestion: { _ in nil }, held: [h])
        XCTAssertEqual(both?.hasQuestion, true)
        XCTAssertEqual(both?.held.count, 1, "listed under the question")
        XCTAssertEqual(both?.more, 0, "not counted as waiting on the user")
    }

    func testThePillShowsHeldQuestionsApart() {
        XCTAssertEqual(BlockedBanner.pillTitle(0, withPM: 1), "1 with PM", "visible with only a held question")
        XCTAssertEqual(BlockedBanner.pillTitle(2, withPM: 1), "2 agents waiting on you · 1 with PM")
        XCTAssertEqual(BlockedBanner.pillTitle(1, withPM: 0), "1 agent waiting on you")
        XCTAssertNil(BlockedBanner.pillTitle(0, withPM: 0))
    }

    func testTheHeldRowReadsLikeANormalRow() {
        let h = HeldQuestion(question: question("w1:p2", card: "N13"), since: now)
        let text = HeldQuestionRowText.make(h, role: "ui_dev", now: now.addingTimeInterval(60))
        XCTAssertEqual(text.heading, "Question · ui_dev · N13")
        XCTAssertEqual(text.question, WaitingQuestionRowText.make(h.question, role: "ui_dev", askedAt: nil, now: now).question, "the same title as a normal row")
        XCTAssertEqual(text.status, "PM is answering · comes to you in 9 min")
        var answered = h; answered.answer = "Yes"; answered.byPM = true
        XCTAssertEqual(HeldQuestionRowText.make(answered, role: "ui_dev", now: now).status, "PM answered: Yes")
        answered.byPM = false
        XCTAssertEqual(answered.status(now: now), "Answered: Yes")
    }

    // MARK: N380 live-window shots

    /// The demo's question held by the PM: Waiting for you with the muted row (N380-waiting-*), the pill alone with "1 with PM" and the
    /// card it opens (N380-card-*), and the "PM answered" moment on both (N380-answered-*), dark and light.
    func testTheLiveHeldQuestionShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self, settings: DemoSupport.prepareSettings())
        var a = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .blocked, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "dev-v1"
        let cards = ["V1", "V3"].map { id in TaskCard(id: id, project: "d", status: .doing, agent: "dev-\(id.lowercased())", branch: "test/\(id.lowercased())", kind: nil, files: [], title: id,
                                                      sections: ["Report": "0 failures."], url: dir.url.appendingPathComponent("\(id).md")) }
        model.inbox.routing = QuestionRouting(mode: .pmCritical, pmPane: "pm1")
        await model.inbox.refresh(agents: [a], cards: cards, projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), label: { _ in "Pixel · V1" })
        XCTAssertTrue(model.inbox.questions.isEmpty)
        XCTAssertEqual(model.inbox.withPM.count, 1)
        let opened = BlockedBannerModel()
        opened.togglePill(shown: false, open: [])
        func shots(_ tag: String) async throws {
            for dark in [true, false] {
                let theme = AppTheme.current
                AppTheme.current = dark ? .dark : .light
                defer { AppTheme.current = theme }
                let name = dark ? "dark" : "light"
                try await DashboardGridSnapshotTests.liveWindowShot(ShellView(model: model, screen: .dashboard), dark: dark, "N380-\(tag == "held" ? "waiting" : "answered-waiting")-\(name).png")
                try await DashboardGridSnapshotTests.liveWindowShot(ShellView(model: model, screen: .tasks, blockedCard: opened), dark: dark, "N380-\(tag == "held" ? "card" : "answered-card")-\(name).png")
                if tag == "held" {
                    let closed = BlockedBannerModel()
                    closed.close(open: [])
                    try await DashboardGridSnapshotTests.liveWindowShot(ShellView(model: model, screen: .tasks, blockedCard: closed), dark: dark, "N380-pill-only-\(name).png")
                }
            }
        }
        try await shots("held")
        model.inbox.answeredShownFor = .seconds(120)
        _ = try await model.inbox.answerForPM(question: "V1-q1", answer: "2").get()
        XCTAssertEqual(model.inbox.heldRows.first?.status(now: Date()), "PM answered: Green")
        try await shots("answered")
    }
}
