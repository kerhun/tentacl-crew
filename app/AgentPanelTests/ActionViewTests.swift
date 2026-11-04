import XCTest
import AppKit
@testable import AgentPanel

@MainActor
final class ActionViewTests: XCTestCase {
    private func card(_ status: TaskStatus) -> TaskCard {
        TaskCard(id: "A5", project: "demo", status: status, agent: nil, branch: "pilot/a5", kind: nil, files: ["a"], title: "A5", sections: [:],
                 url: URL(fileURLWithPath: "/tmp/A5.md"))
    }

    func testStartButtonEnabledOnlyForStartableStatuses() {
        for status: TaskStatus in [.todo, .awaitingStartApproval] {
            XCTAssertTrue(startButtonState(card: card(status), canStart: true, reason: nil).enabled, "\(status)")
        }
        for status: TaskStatus in [.doing, .review, .needsFix, .done, .blocked, .unknown("x")] {
            XCTAssertFalse(startButtonState(card: card(status), canStart: true, reason: nil).enabled, "\(status)")
        }
    }

    func testStartButtonExplainsWhyDisabled() {
        let setup = startButtonState(card: card(.todo), canStart: false, reason: "Set scriptsDir.")
        XCTAssertEqual(setup, StartButtonState(enabled: false, help: "Set scriptsDir."))
        let status = startButtonState(card: card(.done), canStart: true, reason: nil)
        XCTAssertFalse(status.enabled)
        XCTAssertTrue(status.help.contains("todo"))
        XCTAssertFalse(startButtonState(card: card(.todo), canStart: false, reason: nil).help.isEmpty)
    }

    func testSendButtonDisabledForEmptyText() {
        XCTAssertFalse(canSend(text: "", target: "w2:pA", busy: false))
        XCTAssertFalse(canSend(text: "  \n", target: "w2:pA", busy: false))
        XCTAssertFalse(canSend(text: "hello", target: nil, busy: false))
        XCTAssertFalse(canSend(text: "hello", target: "w2:pA", busy: true))
        XCTAssertTrue(canSend(text: "hello", target: "w2:pA", busy: false))
    }

    private func plan(source: String = "/Users/me/My Projects/project.json") throws -> (StartPlan, ProjectConfig, TempDir) {
        let dir = try TempDir()
        let role = try dir.write("roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\"}")
        let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 3, buildCommand: "b", xcodeProject: nil,
                                    simulator: .init(baseDevice: "iPhone 17 Pro"), sharedFiles: [], openWith: "Xcode",
                                    roles: ["dev": role.path], sourcePath: source)
        let flow = StartTaskFlow(project: project, scripts: FakeScripts(), commander: FakeCommander(), writer: CardWriter(),
                                 log: ActionLog(fileURL: dir.url.appendingPathComponent("log")), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: { [] })
        let url = try dir.write("tasks/A5.md", "---\nid: A5\nstatus: awaiting-start-approval\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5\n")
        let c = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        return (try flow.plan(for: c), project, dir)
    }

    func testCommandPreviewShowsArgumentsOneByOne() throws {
        let (plan, _, dir) = try plan()
        _ = dir
        XCTAssertTrue(plan.commandPreview.hasPrefix("spawn-agent.sh '/Users/me/My Projects/project.json' "), plan.commandPreview)
        XCTAssertTrue(plan.commandPreview.hasSuffix(" A5 pilot/a5"), plan.commandPreview)
    }

    func testSheetShowsEveryFieldOfThePlan() throws {
        let (plan, project, dir) = try plan()
        _ = dir
        let fields = startSheetFields(plan: plan, project: project)
        XCTAssertEqual(fields.map(\.label), ["Agent", "Role", "Model", "Branch", "Worktree", "Simulator", "Command"])
        let byLabel = Dictionary(uniqueKeysWithValues: fields.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["Agent"], "dev-a5-demo")
        XCTAssertEqual(byLabel["Role"], "dev")
        XCTAssertTrue(byLabel["Model"]?.contains("sonnet") ?? false)
        XCTAssertEqual(byLabel["Branch"], "pilot/a5")
        XCTAssertEqual(byLabel["Worktree"], "/repo/.agent-worktrees/pilot-a5")
        XCTAssertTrue(byLabel["Simulator"]?.contains("iPhone 17 Pro") ?? false)
        XCTAssertEqual(byLabel["Command"], plan.commandPreview)
    }

    func testRailAndTabHitAreasAreBigEnough() {
        XCTAssertGreaterThanOrEqual(ClickTargets.railItem.width, 44)
        XCTAssertGreaterThanOrEqual(ClickTargets.railItem.height, 44)
        XCTAssertGreaterThanOrEqual(ClickTargets.railWidth, ClickTargets.railItem.width)
        XCTAssertGreaterThanOrEqual(ClickTargets.tabHeight, 30)
    }

    func testEveryRailItemHasAHelpText() {
        for screen in ShellScreen.railOrder { XCTAssertFalse(screen.railHelp.isEmpty, "\(screen)") }
        XCTAssertTrue(ShellScreen.tasks.railHelp.hasPrefix("Tasks"))
    }

    func testCommandDigitsMapToTheRailScreens() {
        XCTAssertEqual(ShellScreen.railOrder, [.dashboard, .tasks, .terminals, .timeline, .team, .plan, .git, .stats, .settings])
        for (index, screen) in ShellScreen.railOrder.enumerated() {
            XCTAssertEqual(screen.shortcutDigit, index + 1)
            XCTAssertEqual(ShellScreen(shortcutDigit: index + 1), screen)
        }
        XCTAssertEqual(ShellScreen.dashboard.railHelp, "Dashboard (⌘1)")
        XCTAssertEqual(ShellScreen.tasks.railHelp, "Tasks (⌘2)")
        XCTAssertNil(ShellScreen(shortcutDigit: 0))
        XCTAssertNil(ShellScreen(shortcutDigit: 10))
    }

    func testANewInstallOpensOnTheDashboardAndTheLastScreenIsRemembered() {
        XCTAssertEqual(ShellScreen(stored: ""), .dashboard)
        XCTAssertEqual(ShellScreen(stored: "nonsense"), .dashboard)
        for screen in ShellScreen.railOrder { XCTAssertEqual(ShellScreen(stored: screen.rawValue), screen) }
    }

    func testSnapshotsOfTheRailAndTheTabBar() throws {
        let rail = try XCTUnwrap(SnapshotRenderer.render(view: Rail(screen: .team, onSelect: { _ in }), size: CGSize(width: 56, height: 360)))
        let view = TaskDetailView(card: card(.review), shots: [], opener: nil, startState: StartButtonState(enabled: false, help: ""),
                                  reviewState: reviewButtonStates(card: card(.review), canAct: true, reason: nil),
                                  onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {})
        let tabs = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 900, height: 300)))
        XCTAssertGreaterThan(rail.count, 1_000)
        XCTAssertGreaterThan(tabs.count, 5_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try rail.write(to: URL(fileURLWithPath: dir).appendingPathComponent("rail.png"))
            try tabs.write(to: URL(fileURLWithPath: dir).appendingPathComponent("detail-tabs.png"))
        }
    }

    func testSnapshotWithCommandBarRenders() async throws {
        let model = await DemoSupport.makeModel()
        let data = try XCTUnwrap(SnapshotRenderer.render(model: model, size: CGSize(width: 1440, height: 860)))
        XCTAssertGreaterThan(data.count, 20_000)
    }

    /// Writes the command bar and the start sheet of the demo to PNGs for a visual check (TEST_RUNNER_AGENT_PANEL_SNAPSHOT_DIR).
    func testDemoSheetAndShellSnapshots() async throws {
        let model = await DemoSupport.makeModel()
        let b1 = try XCTUnwrap(model.cards.compactMap { r -> TaskCard? in if case .card(let c) = r, c.id == "B1" { return c } else { return nil } }.first)
        model.selectedCardID = "B1"
        guard case .success(let plan) = model.startPlan(for: b1) else { return XCTFail("the demo should be able to plan B1") }
        let sheet = try XCTUnwrap(SnapshotRenderer.render(view: StartTaskSheet(plan: plan, project: try XCTUnwrap(model.selectedProject), state: .idle, onConfirm: {}, onCancel: {}), size: CGSize(width: 560, height: 560)))
        let shell = try XCTUnwrap(SnapshotRenderer.render(model: model, size: CGSize(width: 1440, height: 860)))
        XCTAssertGreaterThan(sheet.count, 8_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try sheet.write(to: URL(fileURLWithPath: dir).appendingPathComponent("start-sheet.png"))
            try shell.write(to: URL(fileURLWithPath: dir).appendingPathComponent("shell-b1.png"))
        }
    }

    func testSnapshotOfStartSheetRenders() throws {
        let (plan, project, dir) = try plan()
        _ = dir
        let view = StartTaskSheet(plan: plan, project: project, state: .idle, onConfirm: {}, onCancel: {})
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 560, height: 520)))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 1120)
        XCTAssertGreaterThan(data.count, 8_000)
    }

    // MARK: N90 next step by phase

    private func review(_ c: TaskCard, busy: Bool = false, agentWorking: Bool = false) -> ReviewButtonStates {
        reviewButtonStates(card: c, canAct: true, reason: nil, busy: busy, agentWorking: agentWorking)
    }
    private let startOK = StartButtonState(enabled: true, help: "Start")
    private let startOff = StartButtonState(enabled: false, help: "Only tasks that are todo or awaiting approval can be started.")

    private func withPacket(_ status: TaskStatus, build: String = "passed") -> TaskCard {
        TaskCard(id: "A5", project: "demo", status: status, agent: "dev-a5", branch: "pilot/a5", kind: nil, files: ["a"], title: "A5",
                 sections: ["Review packet": "Head: abc\n\nBuild: \(build) (`b`), log: /l\n\nScreenshots:\n- tasks/A5/shots/a.png\n"],
                 url: URL(fileURLWithPath: "/tmp/A5.md"))
    }

    func testTodoCardsOfferStartAndSayWhyItIsBlocked() {
        for status: TaskStatus in [.todo, .awaitingStartApproval] {
            XCTAssertEqual(nextStep(card: card(status), phase: nil, start: startOK, review: review(card(status))), .action(.start, blocked: nil))
        }
        let waiting = startButtonState(card: card(.todo), canStart: true, reason: nil, dependencies: .waiting(["N86"]))
        guard case .action(.start, let reason?) = nextStep(card: card(.todo), phase: nil, start: waiting, review: review(card(.todo))) else { return XCTFail() }
        XCTAssertTrue(reason.contains("Waiting for N86"), reason)
    }

    func testRunningAgentsShowAStatusLineInsteadOfAButton() {
        let doing = card(.doing)
        XCTAssertEqual(nextStep(card: doing, phase: .working, start: startOff, review: review(doing, agentWorking: true)), .status("Agent is working"))
        XCTAssertEqual(nextStep(card: doing, phase: .starting, start: startOff, review: review(doing)), .status("Agent is working"))
        let fix = card(.needsFix)
        XCTAssertEqual(nextStep(card: fix, phase: .needsFix, start: startOff, review: review(fix)), .status("Agent is fixing"))
        for phase: TaskPhase in [.waitingForYou, .pmHandling, .idle, .blocked] {
            guard case .status(let text) = nextStep(card: doing, phase: phase, start: startOff, review: review(doing)) else { return XCTFail("\(phase)") }
            XCTAssertFalse(text.isEmpty)
        }
    }

    func testFinishedOffersPrepareAndReviewOffersApprove() {
        let doing = card(.doing)
        XCTAssertEqual(nextStep(card: doing, phase: .finished, start: startOff, review: review(doing)), .action(.prepare, blocked: nil))
        let noPacket = card(.review)
        XCTAssertEqual(nextStep(card: noPacket, phase: .inReview, start: startOff, review: review(noPacket)), .action(.prepare, blocked: nil))
        let ready = withPacket(.review)
        XCTAssertEqual(nextStep(card: ready, phase: .inReview, start: startOff, review: review(ready)), .action(.approve, blocked: nil))
        let failed = withPacket(.review, build: "failed")
        XCTAssertEqual(nextStep(card: failed, phase: .inReview, start: startOff, review: review(failed)), .action(.approve, blocked: "The build in the review packet did not pass."))
    }

    func testFinishedCardsHaveNoNextStep() {
        for status: TaskStatus in [.done, .cancelled, .unknown("x")] {
            XCTAssertEqual(nextStep(card: card(status), phase: nil, start: startOff, review: review(card(status))), NextStep.none, "\(status)")
        }
    }

    func testMoreMenuHoldsEveryOtherActionWithTodaysRules() {
        let ready = withPacket(.review)
        let states = review(ready)
        let step = nextStep(card: ready, phase: .inReview, start: startOff, review: states)
        let items = moreItems(card: ready, step: step, start: startOff, review: states, canEdit: true)
        XCTAssertEqual(items.map(\.action), [.requestFix, .prepare, .start])
        XCTAssertEqual(items.first { $0.action == .prepare }?.title, "Prepare review again")
        XCTAssertEqual(items.first { $0.action == .prepare }?.state, states.prepare)
        XCTAssertEqual(items.first { $0.action == .start }?.state, startOff)

        let todo = card(.todo)
        let todoItems = moreItems(card: todo, step: .action(.start, blocked: nil), start: startOK, review: review(todo), canEdit: true)
        XCTAssertEqual(todoItems.map(\.action), [.approve, .requestFix, .prepare, .edit])
        XCTAssertEqual(todoItems.first { $0.action == .prepare }?.title, "Prepare review")
        XCTAssertFalse(todoItems.first { $0.action == .approve }!.state.enabled)
        XCTAssertFalse(moreItems(card: todo, step: .action(.start, blocked: nil), start: startOK, review: review(todo), canEdit: false).contains { $0.action == .edit })

        // A card whose agent is gone still offers Close task; a running agent's status line leaves every action in the menu.
        let orphan = TaskCard(id: "A5", project: "demo", status: .doing, agent: nil, branch: "pilot/a5", kind: nil, files: [], title: "A5", sections: [:],
                              url: URL(fileURLWithPath: "/tmp/A5.md"))
        let orphanItems = moreItems(card: orphan, step: .status("Agent is working"), start: startOff, review: review(orphan), canEdit: true)
        XCTAssertEqual(orphanItems.map(\.action), [.approve, .requestFix, .prepare, .close, .start])
    }

    func testOpeningTabFollowsThePhase() {
        // Design B (N135): every card opens on the Overview.
        for status in [TaskStatus.todo, .doing, .needsFix, .review, .done, .cancelled] { XCTAssertEqual(openingTab(card: card(status)), .overview) }
    }

    func testReturnNeverTriggersTheNextStep() {
        XCTAssertNil(NextStepBar.primaryShortcut)
    }

    // MARK: N54 sheet safety

    func testReturnNeverMergesOrStartsARound() {
        XCTAssertEqual(ApproveSheet.defaultButton, .cancel)
        XCTAssertEqual(ApproveSheet.confirmShortcut, .commandReturn)
        XCTAssertEqual(ApproveRoundSheet.defaultButton, .cancel)
        XCTAssertEqual(ApproveRoundSheet.confirmShortcut, .commandReturn)
        XCTAssertEqual(RoundSheet.defaultButton(for: .ready(RoundModel.Round(items: [], dropped: []))), .cancel)
        XCTAssertEqual(RoundSheet.startShortcut, .commandReturn)
    }

    func testCloseAllCoversEverySheetTheWindowCanShow() {
        let names = Set(PanelSheet.allCases.map(\.rawValue))
        XCTAssertEqual(names, ["startPlan", "approve", "approveRound", "fixRequest", "closeTask", "leavingTeam", "switchingProject", "missingRole", "addProject",
                               "editProject", "newTask", "updateStable", "cleanup", "round", "autopilotRules", "autopilotOn", "roleTemplate", "setup", "gitInit", "gitPush", "questionFocus"])
    }

    func testQuitClosesTheSheetsFirst() {
        var closed = 0
        SheetCloser.shared.closeAll = { closed += 1 }
        XCTAssertEqual(AppQuit.shouldTerminate(), .terminateNow)
        XCTAssertEqual(closed, 1)
        SheetCloser.shared.closeAll = {}
    }

    func testSnapshotsOfTheApproveAndRoundSheets() async throws {
        let model = await DemoSupport.makeModel()
        let b1 = try XCTUnwrap(model.cards.compactMap { r -> TaskCard? in if case .card(let c) = r, c.id == "B1" { return c } else { return nil } }.first)
        let approval = ApprovalPlan(card: b1, agentName: "dev-b1", branch: "feat/b1", worktreePath: "/repo/.agent-worktrees/feat-b1", base: "main",
                                    head: "0123456789abcdef0123456789abcdef01234567", ahead: 2, filesChanged: 3, screenshotCount: 1, isAnalysis: false, commandPreview: "merge-task.sh")
        let approve = try XCTUnwrap(SnapshotRenderer.render(view: ApproveSheet(plan: approval, state: .idle, onConfirm: {}, onCancel: {}), size: CGSize(width: 560, height: 480)))
        let round = try XCTUnwrap(SnapshotRenderer.render(view: RoundSheet(model: model.round, onClose: {}), size: CGSize(width: 600, height: 300)))
        XCTAssertGreaterThan(approve.count, 8_000)
        XCTAssertGreaterThan(round.count, 4_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try approve.write(to: URL(fileURLWithPath: dir).appendingPathComponent("approve-sheet.png"))
            try round.write(to: URL(fileURLWithPath: dir).appendingPathComponent("round-sheet.png"))
        }
    }
}
