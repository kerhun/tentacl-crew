import AppKit
import XCTest
import SwiftUI
@testable import AgentPanel

/// The top bar of design B (N133): path, usage ring, autopilot icon and one Inbox.
@MainActor
final class TopBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func question(_ pane: String, card: String, label: String, title: String, project: String?, isPM: Bool = false) -> PendingQuestion {
        PendingQuestion(paneID: pane, sessionID: "s", agentLabel: label, cardID: card,
                        question: AgentQuestion(kind: .choice, title: title, text: "Which one?", options: []), project: project, isPM: isPM)
    }

    private func card(_ id: String, _ title: String, packet: String? = "Build ok") -> TaskCard {
        TaskCard(id: id, project: "a", status: .review, agent: nil, branch: nil, kind: nil, files: [], title: title,
                 sections: packet.map { ["Review packet": $0] } ?? [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func usage(five: Double?, week: Double?) -> PlanUsage {
        PlanUsage(fiveHour: five.map { .init(percent: $0, resetsAt: now.addingTimeInterval(3600)) },
                  week: week.map { .init(percent: $0, resetsAt: now.addingTimeInterval(86_400)) }, todayCost: 0)
    }

    /// Two projects: "a" (selected) with a card question and the PM's, "b" with one card question.
    private var sources: [TopBarInbox.Source] {
        let a1 = question("w1:p1", card: "A2", label: "ui_dev", title: "Keep the old ids on reload?", project: "a")
        let pm = question("w1:p9", card: "", label: "PM", title: "Plan the next round?", project: "a", isPM: true)
        let b1 = question("w2:p1", card: "B1", label: "dev", title: "Pick a colour", project: "b")
        return [TopBarInbox.Source(id: "b", name: "Orchard", questions: [b1], askedAt: [b1.id: now.addingTimeInterval(-14 * 60)]),
                TopBarInbox.Source(id: "a", name: "Tentacl", questions: [a1, pm], askedAt: [a1.id: now.addingTimeInterval(-120)])]
    }

    // MARK: Inbox

    func testTheInboxCountsQuestionsOfAllProjectsAndTheReadyCardsOfThisOne() {
        let c = TopBarInbox.content(sources: sources, selected: "a", ready: [card("A3", "Screen switches"), card("A4", "Last project opens")], now: now)
        XCTAssertEqual(c.count, 5, "3 questions + 2 ready")
        XCTAssertEqual(c.questions.count, 3)
        XCTAssertEqual(c.ready.map(\.id), ["A3", "A4"])
    }

    func testTheSelectedProjectsQuestionsComeFirstAndOtherProjectsAreMarked() {
        let c = TopBarInbox.content(sources: sources, selected: "a", ready: [], now: now)
        XCTAssertEqual(c.questions.map(\.title), ["A2 asks: Keep the old ids on reload?", "PM asks: Plan the next round?", "Orchard · B1 asks: Pick a colour"])
        XCTAssertEqual(c.questions.map(\.detail), ["ui_dev · 2 min", "PM", "dev · 14 min"])
        XCTAssertEqual(c.questions.map(\.projectID), ["a", "a", "b"])
        XCTAssertEqual(c.questions.map(\.cardID), ["A2", nil, "B1"], "a PM question opens no card")
        XCTAssertEqual(c.questions.map(\.otherProject), [false, false, true])
    }

    func testOneReadyCardIsApprovedAloneSeveralAsARound() {
        let one = TopBarInbox.content(sources: [], selected: "a", ready: [card("A3", "Screen switches")], now: now)
        XCTAssertEqual(one.approveTitle, "Approve")
        XCTAssertEqual(one.readyLine, "A3 · Screen switches")
        let two = TopBarInbox.content(sources: [], selected: "a", ready: [card("A3", "Screen switches"), card("A4", "A4 Last project opens")], now: now)
        XCTAssertEqual(two.approveTitle, "Approve round")
        XCTAssertEqual(two.readyLine, "A3 · Screen switches · A4 Last project opens")
    }

    func testAnEmptyInboxCountsZero() {
        let c = TopBarInbox.content(sources: [TopBarInbox.Source(id: "a", name: "A", questions: [])], selected: "a", ready: [], now: now)
        XCTAssertEqual(c.count, 0)
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(TopBarInbox.buttonLabel(c.count), "Inbox, nothing waiting")
        XCTAssertEqual(TopBarInbox.buttonLabel(5), "Inbox, 5 waiting")
    }

    func testTheReadyCardsAreTheApproveRoundCardsOfTheSelectedProject() async {
        let model = await DemoSupport.makeModel()
        let c = model.topBarInbox()
        XCTAssertEqual(c.ready.map(\.id), model.approveRoundCards.map(\.id))
        XCTAssertEqual(c.count, c.questions.count + model.approveRoundCards.count)
    }

    /// The real wiring: a blocked agent in each of two projects and a review card in the selected one.
    func testAModelWithQuestionsInTwoProjectsAndAReviewCard() async throws {
        let dir = try TempDir()
        let reader = AgentInboxTests.FakeReader(), sender = AutopilotModelTests.Sender()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/choice-before.txt"), encoding: .utf8)
        reader.screens["w1:p1"] = screen; reader.screens["w2:p1"] = screen
        func project(_ id: String, _ repo: String) throws -> URL {
            try dir.write("\(id)/project.json", "{\"id\":\"\(id)\",\"name\":\"Project \(id.uppercased())\",\"repoPath\":\"\(repo)\",\"dataDir\":\"\(dir.url.appendingPathComponent("data-\(id)").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        }
        let a = try project("a", "/repoA"), b = try project("b", "/repoB")
        _ = try dir.write("data-a/tasks/A1.md", "---\nid: A1\nproject: a\nstatus: doing\nagent: dev-a1\nbranch: test/a1\nfiles:\n  - x\n---\n# A1\n")
        _ = try dir.write("data-a/tasks/A2.md", "---\nid: A2\nproject: a\nstatus: review\nfiles:\n  - x\n---\n# A2 Ready one\n## Review packet\nBuild ok\n")
        _ = try dir.write("data-b/tasks/B1.md", "---\nid: B1\nproject: b\nstatus: doing\nagent: dev-b1\nbranch: test/b1\nfiles:\n  - x\n---\n# B1\n")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(a.path)\",\"\(b.path)\"]}")
        func agent(_ pane: String, _ ws: String, _ cwd: String, _ name: String) -> AgentStatus {
            var s = AgentStatus(paneID: pane, workspaceID: ws, state: .blocked, cwd: cwd, title: "t", sessionID: "s-" + ws); s.changeSeq = 1; s.name = name; return s
        }
        let agents = [agent("w1:p1", "w1", "/repoA/.agent-worktrees/test-a1", "dev-a1"), agent("w2:p1", "w2", "/repoB/.agent-worktrees/test-b1", "dev-b1")]
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var off = AutopilotPolicy(); off.mode = .off
        try store.save(off, for: "a"); try store.save(off, for: "b")
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(agents)) }, opener: RecordingOpener(),
                           makeCommander: { sender }, log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore, makeReader: { reader },
                           makeKeySender: { sender }, autopilotStore: store, isWindowFocused: { false })
        await m.reload()
        for _ in 0..<300 where m.topBarInbox().questions.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.selectedProjectID, "a")
        let c = m.topBarInbox()
        XCTAssertEqual(c.questions.map(\.projectID), ["a", "b"])
        XCTAssertEqual(c.questions.map(\.otherProject), [false, true])
        guard c.questions.count == 2 else { return }
        XCTAssertTrue(c.questions[1].title.hasPrefix("Project B · B1 asks: "), c.questions[1].title)
        XCTAssertEqual(c.ready.map(\.id), ["A2"])
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(m.waitingInOtherProjects, m.waitingCount(forProject: "b"))
        XCTAssertEqual(m.waitingInOtherProjects, 1)
    }

    // MARK: Usage ring

    func testTheRingsAreFilledToTheirShareOuterWeekInnerFiveHours() throws {
        let c = try XCTUnwrap(UsageRing.content(usage(five: 78, week: 90), now: now))
        XCTAssertEqual(c.week?.fraction ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(c.fiveHour?.fraction ?? 0, 0.78, accuracy: 0.0001)
        XCTAssertEqual(c.week?.warn, true)
        XCTAssertEqual(c.fiveHour?.warn, false)
        XCTAssertEqual(c.percentText, "90%")
        XCTAssertTrue(c.warn)
    }

    func testTheTextIsTheHigherPercentAndWarnsLikeTheGauge() throws {
        let calm = try XCTUnwrap(UsageRing.content(usage(five: 80, week: 41), now: now))
        XCTAssertEqual(calm.percentText, "80%")
        XCTAssertFalse(calm.warn, "80 is not above the warn line")
        XCTAssertEqual(UsageRing.color(warn: false), Tok.ink2)
        XCTAssertEqual(UsageRing.color(warn: true), Tok.ask)
        let five = try XCTUnwrap(UsageRing.content(usage(five: 95, week: 10), now: now))
        XCTAssertEqual(five.percentText, "95%")
        XCTAssertTrue(five.warn)
        XCTAssertNil(UsageRing.content(usage(five: 20, week: nil), now: now)?.week)
        XCTAssertNil(UsageRing.content(nil))
    }

    func testTheRingsHoverTextAndVoiceAreTheChipsOfToday() throws {
        let u = usage(five: 23.4, week: 41.2)
        let c = try XCTUnwrap(UsageRing.content(u, now: now))
        XCTAssertEqual(c.help, UsageChip.content(u, now: now)?.help)
        XCTAssertEqual(c.accessibilityValue, UsageChip.content(u, now: now)?.accessibilityValue)
    }

    // MARK: Autopilot icon

    func testTheAutopilotIconCarriesTheModeAndTheDailyLimit() {
        let on = AutopilotIcon.look(mode: .on, limitReached: false, dailyLimit: 5)
        XCTAssertEqual(on.tint, .on)
        XCTAssertEqual(on.accessibilityValue, "On")
        XCTAssertEqual(on.help, "PM autopilot · on. " + AutopilotMode.on.explanation)
        XCTAssertEqual(AutopilotIcon.look(mode: .off, limitReached: false, dailyLimit: nil).tint, .off)
        XCTAssertEqual(AutopilotIcon.look(mode: .shadow, limitReached: false, dailyLimit: nil).tint, .shadow)
        let paused = AutopilotIcon.look(mode: .on, limitReached: true, dailyLimit: 5)
        XCTAssertEqual(paused.tint, .paused)
        XCTAssertEqual(paused.help, "PM paused: daily limit $5.00 reached. Today's estimated cost reached the limit in the autopilot rules. Questions come to you until tomorrow or until you raise the limit.")
        XCTAssertEqual(paused.accessibilityValue, "On, PM paused: daily limit $5.00 reached")
        XCTAssertEqual(AutopilotIcon.Tint.on.color, Tok.go)
        XCTAssertEqual(AutopilotIcon.Tint.off.color, Tok.ink3)
        XCTAssertEqual(AutopilotIcon.Tint.paused.color, Tok.ask)
    }

    func testTheRightSideIsRingAutopilotCoffee() {
        XCTAssertEqual(TopBarExtras.items(autopilotAvailable: true), [.usage, .autopilot, .caffeinate])
        XCTAssertEqual(TopBarExtras.items(autopilotAvailable: false), [.usage, .caffeinate])
    }

    // MARK: Path and layout

    func testThePathEndsWithTheScreenTitleUnlessTheWindowIsNarrow() {
        XCTAssertEqual(TopBarLayout(width: 1440).screenTitle(.plan), "Plan")
        XCTAssertEqual(TopBarLayout(width: 1440).screenTitle(.dashboard), "Dashboard")
        XCTAssertNil(TopBarLayout(width: 1024).screenTitle(.plan))
        XCTAssertEqual(TopBarLayout.height, 52)
        XCTAssertEqual(TopBarLayout(width: 1440).middle, 520)
        XCTAssertLessThan(TopBarLayout(width: 1024).middle, 520)
    }

    func testTheProjectBadgeIsHiddenAtZero() {
        XCTAssertNil(TopBarLayout.otherProjectsBadge(0))
        XCTAssertEqual(TopBarLayout.otherProjectsBadge(2), "2")
    }

    // MARK: Snapshots

    private var fullInbox: TopBarInbox.Content {
        TopBarInbox.content(sources: sources, selected: "a", ready: [card("A3", "Screen switches"), card("A4", "Last project opens")], now: now)
    }

    private func bar(_ model: PanelModel, inbox: TopBarInbox.Content, look: AutopilotIcon.Look?, usage u: PlanUsage?, open: Bool = false) -> some View {
        VStack(spacing: 0) {
            TopBar(model: model, screen: .dashboard, inbox: inbox, autopilotLook: look, usage: u, inboxOpen: open)
            Spacer(minLength: 0)
        }
        .background(Tok.bg)
    }

    func testSnapshotsOfTheBarAtBothWidths() async throws {
        let model = await DemoSupport.makeModel()
        let on = AutopilotIcon.look(mode: .on, limitReached: false, dailyLimit: nil)
        let paused = AutopilotIcon.look(mode: .on, limitReached: true, dailyLimit: 5)
        let empty = TopBarInbox.content(sources: [], selected: "demo", ready: [], now: now)
        let shots: [(String, AnyView, CGFloat)] = [
            ("normal", AnyView(bar(model, inbox: fullInbox, look: on, usage: usage(five: 78, week: 90))), 52),
            ("inbox-open", AnyView(bar(model, inbox: fullInbox, look: on, usage: usage(five: 78, week: 90), open: true)), 400),
            ("limit-reached", AnyView(bar(model, inbox: fullInbox, look: paused, usage: usage(five: 40, week: 60))), 52),
            ("empty-inbox", AnyView(bar(model, inbox: empty, look: on, usage: usage(five: 12, week: 30))), 52),
        ]
        for (name, view, height) in shots {
            for width in [1440, 1024] as [CGFloat] {
                let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: width, height: height)), name)
                XCTAssertGreaterThan(data.count, 3_000, name)
                if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                    try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("topbar-\(name)-\(Int(width)).png"))
                }
            }
        }
    }

    // MARK: Every item showing (N388)

    /// The demo model with both plan rings (Claude and a Codex run of the last 5 hours) and the autopilot.
    private func crowdedModel() async throws -> PanelModel {
        let model = DemoSupport.makeUnloadedModel()
        let t = Date()
        model.codexUsageSource = { PlanUsage(fiveHour: .init(percent: 34, resetsAt: t.addingTimeInterval(5400)), week: .init(percent: 12, resetsAt: t.addingTimeInterval(86400)),
                                             todayCost: 0, seenAt: t.addingTimeInterval(-600)) }
        await model.reload()
        for _ in 0..<200 where model.shownCodexUsage == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.shownCodexUsage)
        return model
    }

    /// The bar with the usage ring and the Codex ring, autopilot, coffee, the tour button, "1 waiting" with "1 with PM" and the Inbox.
    private func crowdedBar(_ model: PanelModel) -> some View {
        VStack(spacing: 0) {
            TopBar(model: model, screen: .dashboard, inbox: fullInbox, autopilotLook: AutopilotIcon.look(mode: .on, limitReached: false, dailyLimit: nil),
                   usage: usage(five: 78, week: 90), waitingOnYou: 1, withPM: 1)
            Spacer(minLength: 0)
        }
        .background(Tok.bg)
        .environment(TutorialModel(store: TutorialStore(defaults: makeTestDefaults(prefix: "topbar-crowded")), screen: .dashboard))
    }

    /// For every width the window allows up to 1800 pt, with every item showing: the path, the ⌘K field and the right group (rings
    /// and pills) never overlap, the field keeps its smallest width, and the right group fits the bar (N388). The widths are the hosted
    /// views' own; the placing is `TopBarRow`'s.
    func testNothingInTheBarOverlapsAtAnyWidth() async throws {
        let model = try await crowdedModel()
        let tutorial = TutorialModel(store: TutorialStore(defaults: makeTestDefaults(prefix: "topbar-crowded")), screen: .dashboard)
        let bar = TopBar(model: model, screen: .dashboard, inbox: fullInbox, autopilotLook: AutopilotIcon.look(mode: .on, limitReached: false, dailyLimit: nil),
                         usage: usage(five: 78, week: 90), waitingOnYou: 1, withPM: 1)
        func measured(_ v: some View) -> CGFloat { NSHostingView(rootView: v).fittingSize.width }
        let steps = TopBarStep.allCases.map { measured(bar.rightRow($0, tutorial: tutorial)) }
        XCTAssertEqual(steps, steps.sorted(by: >), "each step is narrower than the one before")
        var stepsUsed = Set<Int>()
        for width in stride(from: TopBarLayout.narrowestWindow, through: 1800, by: 10) {
            let layout = TopBarLayout(width: width)
            let left = measured(bar.path(layout))
            let step = TopBarLayout.step(steps, room: layout.rightRoom(left: left))
            stepsUsed.insert(step)
            let f = layout.frames(left: left, right: steps[step])
            XCTAssertEqual(f.left.width, left, "the path is never cut at \(width)")
            XCTAssertLessThanOrEqual(f.left.maxX + TopBarLayout.spacing, f.field.minX, "path and field at \(width)")
            XCTAssertLessThanOrEqual(f.field.maxX + TopBarLayout.spacing, f.right.minX, "field and right group at \(width)")
            XCTAssertGreaterThanOrEqual(f.field.width, TopBarLayout.fieldMin, "the field keeps its smallest width at \(width)")
            XCTAssertLessThanOrEqual(f.right.maxX, width - TopBarLayout.padding, "the right group fits at \(width)")
            XCTAssertEqual(f.right.width, steps[step], accuracy: 0.5)
        }
        XCTAssertTrue(stepsUsed.contains(0), "a wide window shows the full right group")
    }

    func testTheFieldStaysCentredWhenThereIsRoomAndShrinksFirst() {
        let wide = TopBarLayout(width: 1800).frames(left: 300, right: 500)
        XCTAssertEqual(wide.field.midX, 900)
        XCTAssertEqual(wide.field.width, 520)
        let tight = TopBarLayout(width: 1440).frames(left: 300, right: 700)
        XCTAssertEqual(tight.field.maxX + TopBarLayout.spacing, tight.right.minX, "pushed left of the right group")
        XCTAssertLessThan(tight.field.width, 520)
        XCTAssertEqual(TopBarLayout.step([900, 700, 500], room: 750), 1)
        XCTAssertEqual(TopBarLayout.step([900, 700, 500], room: 100), 2, "the last step when none fits")
    }

    /// Live window shots (not ImageRenderer) at 1440 pt and at the window's narrowest width, light and dark. Runs only when
    /// `AGENT_PANEL_TOPBAR_SHOTS` names a folder; needs an unlocked screen.
    func testLiveWindowShotsWithEveryItem() async throws {
        guard let out = ProcessInfo.processInfo.environment["AGENT_PANEL_TOPBAR_SHOTS"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("AGENT_PANEL_TOPBAR_SHOTS is not set")
        }
        let model = try await crowdedModel()
        for width in [1440, TopBarLayout.narrowestWindow] as [CGFloat] {
            for dark in [false, true] {
                let theme = AppTheme.current
                AppTheme.current = dark ? .dark : .light
                defer { AppTheme.current = theme }
                let size = CGSize(width: width, height: 96)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = NSHostingView(rootView: crowdedBar(model).environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: size.height))
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(1500))
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try data.write(to: out.appendingPathComponent("topbar-\(Int(width))\(dark ? "-dark" : "").png"))
            }
        }
    }
}
