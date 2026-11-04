import XCTest
import SwiftUI
@testable import AgentPanel

@MainActor
final class DashboardPolishTests: XCTestCase {
    func testTheAgentsHeaderCountsAgentsWaitingOnSomeoneInsteadOfTheAutopilotPill() {
        XCTAssertEqual(agentsWaitingCount(phases: [.working, .waitingForYou, .pmHandling, .blocked, .finished, nil]), 3)
        XCTAssertEqual(agentsWaitingCount(phases: []), 0)
        XCTAssertEqual(AgentsPane.headerChip(waiting: 0), "Tentacl")
        XCTAssertEqual(AgentsPane.headerChip(waiting: 2), "2 waiting")
    }

    func testTheAutopilotIconAndTheUsageRingShowOnceInTheTopBar() {
        XCTAssertEqual(TopBarExtras.items(autopilotAvailable: true), [.usage, .autopilot, .caffeinate])
        XCTAssertEqual(TopBarExtras.items(autopilotAvailable: false), [.usage, .caffeinate])
    }

    /// The waiting badge is in the top bar only (N103).
    /// N346: PM authority went to the chat header and the cost to its tile; the strip keeps Plan a round and its reason.
    func testTheDashboardStripKeepsOnlyPlanARound() {
        XCTAssertEqual(DashboardStripItem.items(planEnabled: true), [.planRound])
        XCTAssertEqual(DashboardStripItem.items(planEnabled: false), [.planRound, .planReason])
    }

    /// The PM authority chip is a button to the same Autopilot rules sheet as the top bar's pill (N103).
    func testThePMAuthorityChipOpensTheAutopilotRules() {
        let model = PanelModel.isolatedForTests()
        XCTAssertFalse(model.autopilot.rulesOpen)
        model.openAuthorityRules()
        XCTAssertTrue(model.autopilot.rulesOpen)
        XCTAssertEqual(PMChatHeader.authorityHelp, "Change PM authority in the Autopilot rules")
    }

    /// The top bar and the Dashboard's list show the same number (N103).
    func testTheTopBarAndTheWaitingListCountTheSame() async {
        let model = await DemoSupport.makeModel()
        XCTAssertEqual(model.waitingForYouCount, waitingDecisionCount(model.dashboardWaiting))
        XCTAssertGreaterThan(model.waitingForYouCount, 0)
    }

    func testTheChatIsTitledChatAndAddressesThePM() {
        XCTAssertEqual(CommandBar.title(pmOnly: true), "Chat")
        XCTAssertEqual(CommandBar.placeholder(pmOnly: true), "Message the PM…")
        XCTAssertEqual(CommandBar.placeholder(pmOnly: false), "Message to the agent…")
    }

    func testTheDashboardShowsRichAgentCards() {
        XCTAssertNotNil(DashboardView.agentsPane(PanelModel.isolatedForTests()).cards)
    }

    /// The Tasks screen lost the Chat tab's unread dot: a PM reply that arrives elsewhere marks the Dashboard in the rail.
    func testTheRailMarksTheDashboardWhenThePMRepliedWhileElsewhere() {
        XCTAssertTrue(ShellScreen.dashboard.railDot(current: .tasks, unreadReply: true))
        XCTAssertFalse(ShellScreen.dashboard.railDot(current: .dashboard, unreadReply: true), "the user is looking at it")
        XCTAssertFalse(ShellScreen.dashboard.railDot(current: .tasks, unreadReply: false))
        XCTAssertFalse(ShellScreen.tasks.railDot(current: .team, unreadReply: true))
    }
}

final class DashboardLogicTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus) -> TaskCard {
        TaskCard(id: id, project: "d", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    func testWaitingForYouListsEveryDecisionOnceInOrder() {
        let cards = [card("A1", .review), card("A2", .doing), card("A3", .awaitingStartApproval), card("A4", .review), card("A5", .todo)]
        let items = dashboardWaitingItems(questions: ["w1:p1|q"], fixes: ["A2"], cards: cards, roundWaiting: ["A5"], approveRound: 2)
        XCTAssertEqual(items.map(\.kind), [.question("w1:p1|q"), .approveRound(2), .review("A1"), .review("A4"), .fix("A2"), .round(["A5"]), .startApproval("A3")])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ids are unique")
    }

    private func card(_ id: String, _ status: TaskStatus, modified: TimeInterval) -> TaskCard {
        var c = card(id, status); c.modified = Date(timeIntervalSince1970: modified); return c
    }

    /// N182: questions (an agent is blocked), then reviews, fixes, starts and rounds, git last.
    func testWaitingForYouPutsQuestionsFirstAndGitLast() {
        let cards = [card("A1", .review), card("A2", .doing), card("A3", .awaitingStartApproval), card("A4", .review)]
        let items = dashboardWaitingItems(questions: ["q1"], fixes: ["A2"], cards: cards, roundWaiting: ["A5"], approveRound: 2,
                                          git: [.initializeGit], planRound: "2")
        XCTAssertEqual(items.map(\.kind), [.question("q1"), .approveRound(2), .review("A1"), .review("A4"), .fix("A2"),
                                           .planRound("2"), .round(["A5"]), .startApproval("A3"), .git(.initializeGit)])
        XCTAssertEqual(items.map(\.tint), [.question, .review, .review, .review, .fix, .start, .start, .start, .git])
    }

    func testWithinAKindTheOldestComesFirst() {
        let cards = [card("R1", .review, modified: 300), card("R2", .review, modified: 100), card("F1", .doing, modified: 50), card("F2", .doing, modified: 20),
                     card("S1", .awaitingStartApproval, modified: 90), card("S2", .awaitingStartApproval, modified: 10), card("R3", .review)]
        let asked = ["q-new": Date(timeIntervalSince1970: 500), "q-old": Date(timeIntervalSince1970: 5)]
        let items = dashboardWaitingItems(questions: ["q-new", "q-old", "q-unknown"], fixes: ["F1", "F2"], cards: cards, roundWaiting: [], approveRound: 0,
                                          questionAsked: asked)
        XCTAssertEqual(items.map(\.id), ["question|q-old", "question|q-new", "question|q-unknown", "review|R2", "review|R1", "review|R3",
                                         "fix|F2", "fix|F1", "start|S2", "start|S1"], "an unknown age goes after the known ones, in the order given")
    }

    func testTheWaitingCountsDoNotChangeWithTheOrder() {
        let cards = [card("A1", .review), card("A3", .awaitingStartApproval), card("A4", .review)]
        let items = dashboardWaitingItems(questions: ["q"], fixes: ["A2"], cards: cards, roundWaiting: ["A5"], approveRound: 2, git: [.initializeGit], planRound: "1")
        XCTAssertEqual(waitingDecisionCount(items), 8)
    }

    /// Each kind's colour keeps 4.5:1 on the row background and on its own chip (the app has one theme: dark).
    func testEveryWaitingColourIsReadableOnTheRowAndItsChip() {
        func lin(_ c: UInt32) -> Double { let v = Double(c) / 255; return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func lum(_ h: UInt32) -> Double { 0.2126 * lin((h >> 16) & 0xFF) + 0.7152 * lin((h >> 8) & 0xFF) + 0.0722 * lin(h & 0xFF) }
        func mix(_ a: UInt32, over b: UInt32, _ t: Double) -> UInt32 {
            [16, 8, 0].reduce(0) { $0 | UInt32((Double((a >> $1) & 0xFF) * t + Double((b >> $1) & 0xFF) * (1 - t)).rounded()) << $1 }
        }
        func ratio(_ a: UInt32, _ b: UInt32) -> Double { let x = lum(a), y = lum(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
        for tint in [WaitingTint.question, .review, .fix, .start, .git] {
            for row in [Tok.Hex.raise, Tok.Hex.bg] {
                XCTAssertGreaterThanOrEqual(ratio(tint.hex, row), 4.5, "\(tint) on the row")
                XCTAssertGreaterThanOrEqual(ratio(tint.hex, mix(tint.hex, over: row, WaitingTint.chipOpacity)), 4.5, "\(tint) on its chip")
            }
        }
        XCTAssertEqual(Set([WaitingTint.question, .review, .fix, .start, .git].map(\.hex)).count, 5, "one colour per kind")
    }

    func testNothingWaitingMeansAnEmptyList() {
        XCTAssertEqual(dashboardWaitingItems(questions: [], fixes: [], cards: [card("A1", .doing)], roundWaiting: [], approveRound: 0), [])
    }

    func testApproveRoundShowsOnlyForMoreThanOneCardLikeTheTopBar() {
        let one = dashboardWaitingItems(questions: [], fixes: [], cards: [card("A1", .review)], roundWaiting: [], approveRound: 1)
        XCTAssertEqual(one.map(\.kind), [.review("A1")])
    }

    /// Every decision counts once: the Approve round entry only bundles the reviews already listed (N103).
    func testTheWaitingCountSkipsTheApproveRoundShortcut() {
        let cards = [card("A1", .review), card("A3", .awaitingStartApproval), card("A4", .review)]
        let items = dashboardWaitingItems(questions: ["w1:p1|q"], fixes: ["A2"], cards: cards, roundWaiting: ["A5"], approveRound: 2)
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(waitingDecisionCount(items), 6, "round, question, fix, two reviews, one start approval")
        XCTAssertEqual(waitingDecisionCount([]), 0)
    }

    func testAWaitingRowShowsTheCardIDOnce() {
        XCTAssertEqual(waitingRowTitle(id: "A1", title: "Clean up the logs"), "A1 · Clean up the logs")
        XCTAssertEqual(waitingRowTitle(id: "A1", title: "A1 · Clean up the logs"), "A1 · Clean up the logs")
        XCTAssertEqual(waitingRowTitle(id: "B1", title: "B1 Test infrastructure"), "B1 Test infrastructure")
        XCTAssertEqual(waitingRowTitle(id: "A1", title: "A10 · Other"), "A1 · A10 · Other", "a longer id is not the same id")
        XCTAssertEqual(waitingRowTitle(id: "A1", title: "A1"), "A1")
    }

    func testPlanARoundFollowsTheTasksScreenRuleAndSaysWhyWhenOff() {
        XCTAssertTrue(planRoundButtonState(autopilotAvailable: true, mode: .shadow, canStart: true, startReason: nil).enabled)
        XCTAssertTrue(planRoundButtonState(autopilotAvailable: true, mode: .on, canStart: true, startReason: nil).enabled)
        let off = planRoundButtonState(autopilotAvailable: true, mode: .off, canStart: true, startReason: nil)
        XCTAssertFalse(off.enabled)
        XCTAssertTrue(off.help.contains("autopilot is Off"), off.help)
        let noStart = planRoundButtonState(autopilotAvailable: true, mode: .on, canStart: false, startReason: "No project selected.")
        XCTAssertFalse(noStart.enabled)
        XCTAssertEqual(noStart.help, "No project selected.")
        XCTAssertFalse(planRoundButtonState(autopilotAvailable: false, mode: .on, canStart: true, startReason: nil).enabled)
    }

    func testTheStripTexts() {
        XCTAssertEqual(dashboardCostText(today: 4.123, limit: 20), "$4.12 of $20.00 today")
        XCTAssertEqual(dashboardCostText(today: 4.1, limit: nil), "$4.10 today")
        XCTAssertNil(dashboardCostText(today: nil, limit: 20))
        XCTAssertEqual(dashboardAuthorityText(enabled: true, startedToday: 2, perDay: 6), "PM authority · 2 of 6 today")
        XCTAssertEqual(dashboardAuthorityText(enabled: false, startedToday: 0, perDay: 6), "PM authority · off")
    }

    func testTheCurrentRoundIsTheFirstUnfinishedOne() {
        let plan = PlanFile(rounds: [PlanRound(name: "R1", cards: ["A1"], reason: "", status: ""), PlanRound(name: "R2", cards: ["A2", "A3"], reason: "", status: "")], questions: [])
        let cards = [card("A1", .done), card("A2", .done), card("A3", .doing)]
        XCTAssertEqual(currentRound(in: plan, cards: cards)?.name, "R2")
        XCTAssertEqual(currentRound(in: plan, cards: cards.map { card($0.id, .done) })?.name, "R2", "all done: the last round")
        XCTAssertNil(currentRound(in: PlanFile(rounds: [], questions: []), cards: cards))
    }

    private func rounds(_ spec: [(String, String, [String])]) -> PlanFile {
        PlanFile(rounds: spec.map { PlanRound(name: $0.0, cards: $0.2, reason: "", status: $0.1) }, questions: [])
    }

    func testTheDefaultRoundIsRunningNotAnEarlierLaterOne() {
        let cards = [card("A", .todo), card("B", .doing), card("C", .done)]
        let plan = rounds([("Notch", "later", ["A"]), ("T", "running", ["B"]), ("S", "done", ["C"])])
        XCTAssertEqual(currentRound(in: plan, cards: cards)?.name, "T")
        XCTAssertEqual(currentRound(in: rounds([("Notch", "later", ["A"]), ("P", "planned", ["B"])]), cards: cards)?.name, "P")
        XCTAssertEqual(currentRound(in: rounds([("S", "done", ["C"]), ("S2", "done", ["C"])]), cards: cards)?.name, "S2")
    }

    func testThePickIsKeptUntilAnOpenPickIsDone() {
        let plan = rounds([("Notch", "later", ["A"]), ("T", "running", ["B"]), ("S", "done", ["C"])])
        let open = [card("A", .todo), card("B", .doing), card("C", .done)]
        XCTAssertEqual(goalRound(in: plan, cards: open, pick: GoalPick(name: "Notch", wasOpen: true))?.name, "Notch")
        XCTAssertEqual(goalRound(in: plan, cards: open, pick: GoalPick(name: "S", wasOpen: false))?.name, "S", "a done round picked from Done is shown")
        XCTAssertEqual(goalRound(in: plan, cards: [card("A", .done), card("B", .doing), card("C", .done)], pick: GoalPick(name: "Notch", wasOpen: true))?.name, "T", "finished: default")
        XCTAssertEqual(goalRound(in: plan, cards: open, pick: GoalPick(name: "Gone", wasOpen: true))?.name, "T")
        XCTAssertEqual(goalRoundGroups(in: plan, cards: open).map(\.title), ["", "Later", "Done"])
    }

    @MainActor func testThePickIsStoredWithWhetherItWasOpen() {
        let m = PanelModel.isolatedForTests()
        let plan = PlanLoad.plan(rounds([("Notch", "later", ["A"]), ("S", "done", ["C"])]))
        let cs = [card("A", .todo), card("C", .done)]
        m.setGoalRoundPick("S", project: "p", cards: cs, plan: plan)
        XCTAssertEqual(m.goalRoundPick("p"), GoalPick(name: "S", wasOpen: false))
        m.setGoalRoundPick("Notch", project: "p", cards: cs, plan: plan)
        XCTAssertEqual(m.goalRoundPick("p"), GoalPick(name: "Notch", wasOpen: true))
        m.setGoalRoundPick(nil, project: "p", cards: cs, plan: plan)
        XCTAssertNil(m.goalRoundPick("p"))
    }

    /// N284 shots (AGENT_PANEL_SNAPSHOT_DIR): round T over the later Notch, and a done round picked.
    @MainActor func testGoalCardSnapshots() throws {
        let plan = PlanLoad.plan(rounds([("Notch", "later", ["N196", "N197"]), ("S", "done", ["N190"]), ("T", "running", ["N280", "N284"])]))
        let cs = [card("N196", .todo), card("N197", .todo), card("N190", .done), card("N280", .review), card("N284", .doing)]
        for (name, pick) in [("goal", nil), ("goal-picked-done", GoalPick(name: "S", wasOpen: false))] as [(String, GoalPick?)] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: GoalCard(goal: "Run a multi-agent team from one panel.", plan: plan, cards: cs, pick: pick)
                .padding(16).frame(width: 320).background(Tok.raise), size: CGSize(width: 320, height: 220)))
            XCTAssertGreaterThan(data.count, 4_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N284-\(name).png")) }
        }
    }
}

@MainActor
final class PMDraftTests: XCTestCase {
    func testAQuickPromptWithoutAPMFillsNothingAndSendsNothing() {
        let model = PanelModel.isolatedForTests()
        XCTAssertFalse(model.fillPMDraft("status"))
        XCTAssertEqual(model.actionState, .idle)
    }

    func testAQuickPromptReplacesTheDraftOfThePMConversation() {
        let model = PanelModel.isolatedForTests()
        let session = model.chats.session(project: "demo", pane: "w9:p1")
        session.text = "half a thought"
        PanelModel.fillDraft(session, with: "what failed today")
        XCTAssertEqual(session.text, "what failed today")
    }
}

@MainActor
final class PendingRoundCardTests: XCTestCase {
    private func card(_ id: String) -> TaskCard {
        TaskCard(id: id, project: "d", status: .todo, agent: nil, branch: nil, kind: nil, files: ["App/\(id).swift"], title: id, sections: ["Goal": "g"], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }
    private func round() -> RoundModel {
        let cards = ["N34", "N37"].map(card)
        return RoundModel(enabled: { true }, cards: { cards }, maxParallel: { 3 }, projectName: { "Demo" },
                          propose: { _ in throw CancellationError() },
                          planStart: { c in .success(StartPlan(card: c, agentName: "dev", branch: "task/x", rolePath: "/r", worktreePath: "/w", commandPreview: "", roleName: "dev")) },
                          conflict: { _, _ in nil }, start: { _ in nil }, record: { _ in })
    }

    func testAWaitingRoundShowsOneCard() async throws {
        let m = round()
        XCTAssertEqual(m.waitingIDs, [])
        _ = await m.fulfil(ids: ["N34", "N37"], words: "start them", startNow: false)
        XCTAssertEqual(m.waitingIDs, ["N34", "N37"])
        XCTAssertEqual(RoundWaitingCard.title(m.waitingIDs), "Round waiting: N34, N37")
    }

    func testTheWaitingCardRenders() throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: RoundWaitingCard(ids: ["N34", "N37"]).padding(12).background(Tok.pane), size: CGSize(width: 340, height: 70)))
        XCTAssertGreaterThan(data.count, 1_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("round-waiting-card.png")) }
    }

    func testStartingOrClosingRemovesIt() async throws {
        let m = round()
        _ = await m.fulfil(ids: ["N34"], words: "x", startNow: false)
        await m.start()
        XCTAssertEqual(m.waitingIDs, [])
        _ = await m.fulfil(ids: ["N34"], words: "x", startNow: false)
        XCTAssertEqual(m.waitingIDs, ["N34"])
        m.close()
        XCTAssertEqual(m.waitingIDs, [])
    }

    func testCancelHidesAReadyRoundAndTheCardReopensIt() async {
        let m = round()
        _ = await m.fulfil(ids: ["N34", "N37"], words: "start them", startNow: false)
        XCTAssertTrue(m.showsSheet)
        m.cancel()
        XCTAssertFalse(m.showsSheet, "hidden")
        XCTAssertEqual(m.waitingIDs, ["N34", "N37"], "the proposal is kept")
        m.reopen()
        XCTAssertTrue(m.showsSheet)
        XCTAssertEqual(m.waitingIDs, ["N34", "N37"])
    }

    func testDiscardThrowsTheProposalAway() async {
        let m = round()
        _ = await m.fulfil(ids: ["N34"], words: "go", startNow: false)
        m.cancel()
        m.close()
        XCTAssertEqual(m.waitingIDs, [])
        XCTAssertFalse(m.showsSheet)
        m.reopen()
        XCTAssertFalse(m.showsSheet, "nothing to reopen")
    }

    func testCancelOnTheQuestionStepJustCloses() {
        let m = round()
        m.begin()
        XCTAssertTrue(m.showsSheet)
        m.cancel()
        XCTAssertFalse(m.isOpen)
    }

    func testPlanRoundOnAHiddenProposalReopensIt() async {
        let m = round()
        _ = await m.fulfil(ids: ["N34"], words: "go", startNow: false)
        m.cancel()
        m.begin()
        XCTAssertTrue(m.showsSheet)
    }
}

/// N342: the focus card's buttons per kind, its place in the list after an answer, the empty state and the header's summary line.
@MainActor
final class DashboardFocusTests: XCTestCase {
    private typealias Item = DashboardWaitingItem

    func testTheFocusCardShowsTheRightButtonsPerKind() {
        XCTAssertEqual(DecisionFocusAction.actions(for: .question("q"), pmMayDecide: true), [.openCard, .terminal, .letPMDecide])
        XCTAssertEqual(DecisionFocusAction.actions(for: .question("q"), pmMayDecide: false), [.openCard, .terminal], "Let the PM decide only where the question may go to the PM")
        XCTAssertEqual(DecisionFocusAction.actions(for: .question("q"), isPMQuestion: true), [.terminal], "the PM's own question has no card")
        XCTAssertEqual(DecisionFocusAction.actions(for: .review("A1")), [.openCard, .screenshot, .fixNotes, .approveMerge])
        XCTAssertEqual(DecisionFocusAction.actions(for: .fix("A1")), [.openCard, .terminal], "the fix's own card keeps its buttons")
        XCTAssertEqual(DecisionFocusAction.actions(for: .startApproval("A1")), [.openCard, .start])
        XCTAssertEqual(DecisionFocusAction.actions(for: .approveRound(2)), [.approveRound])
        XCTAssertEqual(DecisionFocusAction.actions(for: .round(["A1"])), [.openRoundSheet])
        XCTAssertEqual(DecisionFocusAction.actions(for: .planRound("2")), [.editPlan, .notNow, .approvePlan])
        XCTAssertEqual(DecisionFocusAction.actions(for: .git(.initializeGit)), [.initGit])
        XCTAssertEqual(DecisionFocusAction.actions(for: .git(.pushToGitHub(.unpushed(3)))), [.notNow, .pushGit])
        XCTAssertEqual(DecisionFocusAction.actions(for: .undelivered("u")), [.dismiss, .retry])
        XCTAssertEqual(DecisionFocusAction.approveMerge.title, "Approve and merge")
        XCTAssertEqual(DecisionFocusAction.letPMDecide.title, "Let the PM decide")
    }

    func testAnsweringMovesToTheNextItem() {
        let items = [Item(kind: .question("a")), Item(kind: .review("B1")), Item(kind: .startApproval("C1"))]
        var state = DecisionFocusState(opening: items[0].id, in: items)
        XCTAssertEqual(state.position(in: items), "1 of 3")
        state.sync(Array(items.dropFirst()))
        XCTAssertEqual(state.current(in: Array(items.dropFirst())), items[1], "the answered question leaves; the next shows")
        XCTAssertEqual(state.position(in: Array(items.dropFirst())), "1 of 2")
        state.move(by: -1, in: Array(items.dropFirst()))
        XCTAssertEqual(state.currentID, items[2].id, "‹ wraps around")
        state.sync([items[1]])
        XCTAssertEqual(state.currentID, items[1].id, "the last one answered: the one before it shows")
        state.sync([items[1], items[2]])
        XCTAssertEqual(state.currentID, items[1].id, "a new item does not move the card")
    }

    func testWithNothingLeftTheCardSaysNothingNeedsYou() {
        let items = [Item(kind: .question("a"))]
        var state = DecisionFocusState(opening: items[0].id, in: items)
        state.sync([])
        XCTAssertNil(state.current(in: []))
        XCTAssertNil(state.position(in: []))
        XCTAssertEqual(DecisionFocusCard.emptyText, "Nothing needs you.")
    }

    func testTheSummaryLine() {
        XCTAssertEqual(DashboardSummary(waiting: 2, working: 3, round: (1, 4)).text, "2 things need you · 3 agents working · round 1 of 4 merged")
        XCTAssertEqual(DashboardSummary(waiting: 2, working: 3, round: (1, 4)).need, "2 things need you")
        XCTAssertEqual(DashboardSummary(waiting: 1, working: 1, round: nil).text, "1 thing needs you · 1 agent working")
        let calm = DashboardSummary(waiting: 0, working: 0, round: (0, 0))
        XCTAssertNil(calm.need)
        XCTAssertEqual(calm.text, "Nothing needs you")
        XCTAssertEqual(dashboardGreeting(hour: 9), "Good morning")
        XCTAssertEqual(dashboardGreeting(hour: 14), "Good afternoon")
        XCTAssertEqual(dashboardGreeting(hour: 21), "Good evening")
    }

    func testHighlightsKeepOnlyStartsReviewsMergesFailuresAndQuestions() {
        let t = Date(timeIntervalSince1970: 1_000)
        let log = ["start N341 agent=ui_dev-n341", "review packet started for N341", "review packet prepared for N341", "merged task/n337 into main at stable-268 for N337",
                   "asked N339 (choice)", "asked PM (choice)", "fix request sent for N338", "autopilot: fix request for N340 from the autopilot", "panel message to w1 retried: hi"]
        let events = log.enumerated().map { ActionLogEvent(time: t.addingTimeInterval(Double($0.offset)), text: $0.element, project: "p") }
        let h = DashboardHighlight.from(events, project: "p", limit: 10)
        XCTAssertEqual(h.map { "\($0.card) \($0.text)" }, ["N340 fix sent by the autopilot", "N338 fix requested", "N339 asked you a question", "N337 merged · stable-268",
                                                         "N341 ready for review", "N341 started"])
        XCTAssertEqual(DashboardHighlight.from(events, project: "p").count, 6)
        XCTAssertEqual(DashboardHighlight.from(events, project: "other").count, 0)
    }

    func testTheReviewSummaryReadsResultTestsAndFiles() {
        let report = "### Result\nThe grid is in.\n\n### Commit\nabc123\n\n### Tests\n`scripts/app-test.sh` 2745/0\n\n### Files\n4 files, +124 −12"
        XCTAssertEqual(reviewReportSummary(report).map { "\($0.label): \($0.text)" }, ["Result: The grid is in.", "Tests: `scripts/app-test.sh` 2745/0", "Files: 4 files, +124 −12"])
        XCTAssertEqual(reviewReportSummary("- Tests: 10/0\n- Files: two").map(\.text), ["10/0", "two"])
        XCTAssertEqual(lastTerminalLines("a\n\nb\nc\nd\ne\n   \n"), ["b", "c", "d", "e"])
    }
}

private final class ScreenReader: TerminalReading, @unchecked Sendable {
    let screens: [String: String]
    init(_ s: [String: String]) { screens = s }
    func screen(of target: String, lines: Int) async throws -> String { screens[target] ?? "" }
}
private struct NoKeys: TerminalKeySending, TerminalCommanding {
    func sendKeys(target: String, keys: [String]) async throws {}
    func prompt(target: String, text: String) async throws {}
}
private struct NoDecider: PMDeciding {
    func decide(_ request: DecisionRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
    func decide(_ request: FixRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
}

@MainActor
final class DashboardSnapshotTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func makeModel(_ dir: TempDir, settings: URL? = nil) async throws -> PanelModel { try await Self.makeModel(dir, owner: self, settings: settings) }

    /// A panel with three agents (one asking a question) and a fix card waiting for the user (N342's grid shots use it too).
    static func makeModel(_ dir: TempDir, owner: XCTestCase, settings: URL? = nil) async throws -> PanelModel {
        let screen = try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/choice-before.txt"), encoding: .utf8)
        var a = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .blocked, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "dev-v1"
        let b = AgentStatus(paneID: "w2:p1", workspaceID: "w2", state: .working, cwd: "/repo/.agent-worktrees/test-v2", title: "dev-v2")
        let c = AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .done, cwd: "/repo/.agent-worktrees/test-v3", title: "dev-v3")
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var policy = AutopilotPolicy(); policy.mode = .shadow
        let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
        try store.save(policy, for: project.id)
        let iso = TestIsolation(dir, owner: owner)
        let model = PanelModel(settingsURL: settings ?? dir.url.appendingPathComponent("projects.json"), makeTerminal: { FakeTerminal(agentsResult: .success([a, b, c])) }, opener: WorkspaceURLOpener(),
                               log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore,
                               makeReader: { ScreenReader(["w1:p1": screen]) }, makeKeySender: { NoKeys() }, autopilotStore: store, makeDecider: { _ in NoDecider() })
        if settings != nil { await model.reload() }
        await model.refreshAgents()
        let cards = ["V1", "V3"].map { id in TaskCard(id: id, project: "d", status: .doing, agent: "dev-\(id.lowercased())", branch: "test/\(id.lowercased())", kind: nil, files: [], title: id,
                                                      sections: ["Report": "0 failures."], url: dir.url.appendingPathComponent("\(id).md")) }
        await model.inbox.refresh(agents: [a, b, c], cards: cards, projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), label: { $0.paneID == "w1:p1" ? "Pixel · V1" : $0.title })
        model.autopilot.setProject(project)
        model.autopilot.isFinished = { _ in true }
        model.autopilot.preparePacket = { _ in .failed("EVIDENCE MISSING: build failed\n** TEST FAILED **") }
        model.autopilot.process([], cards: [cards[1]])
        for _ in 0..<200 where model.autopilot.fixesForYou.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        return model
    }

    func testTheDashboardShowsTheWaitingDecisionsAgentsAndChat() async throws {
        let dir = try TempDir()
        let model = try await makeModel(dir)
        XCTAssertEqual(model.questionsForYou.count, 1)
        XCTAssertEqual(model.autopilot.fixesForYou.count, 1)
        let items = model.dashboardWaiting
        XCTAssertEqual(items.filter { if case .question = $0.kind { true } else { false } }.count, 1)
        XCTAssertEqual(items.filter { if case .fix = $0.kind { true } else { false } }.count, 1)
        for (name, size) in [("dashboard", CGSize(width: 1376, height: 860)), ("dashboard-min", CGSize(width: 1035, height: 600)), ("dashboard-narrow", CGSize(width: 760, height: 900))] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: DashboardView(model: model), size: size))
            XCTAssertGreaterThan(data.count, 20_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
        }
    }

    /// N182: every kind in Waiting for you, each in its colour, questions first and git last (the demo cards give two reviews,
    /// so Approve round, and a start approval).
    func testWaitingForYouShowsEveryKindInItsColour() async throws {
        let dir = try TempDir()
        let model = try await makeModel(dir, settings: DemoSupport.prepareSettings())
        model.gitSetup.probe = { _ in var facts = RepoFacts(); facts.isGitRepo = false; return ProjectProbe(facts: facts) }
        await model.refreshGitState(force: true)
        let tints = model.dashboardWaiting.map(\.tint)
        XCTAssertEqual(tints, tints.sorted { $0.rawValue < $1.rawValue }, "grouped by kind in the list's order")
        XCTAssertEqual(Set(tints), [.question, .review, .fix, .start, .git], "\(model.dashboardWaiting.map(\.id))")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: DashboardView(model: model), size: CGSize(width: 1376, height: 1500)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("waiting-every-kind.png")) }
        let round = PlanRound(name: "2", cards: ["A5"], reason: "The widget next.", status: "waiting")
        let extras = VStack(spacing: Tok.Space.s) {
            PlanRoundApproval(round: round, blocker: nil, message: nil, onApprove: {}, onEdit: {}, onNotNow: {}, tint: .start)
            RoundWaitingCard(ids: ["A5"])
        }.padding(12).frame(width: 340).background(Tok.pane)
        let more = try XCTUnwrap(SnapshotRenderer.render(view: extras, size: CGSize(width: 340, height: 230)))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try more.write(to: URL(fileURLWithPath: out).appendingPathComponent("waiting-rounds.png")) }
    }

    /// The whole window on Tasks (list and detail, no right column) and on the Dashboard.
    func testTheTasksScreenAndTheDashboardRenderInTheWindow() async throws {
        let model = await DemoSupport.makeModel()
        model.selectedCardID = "B1"
        for screen in [ShellScreen.tasks, .dashboard] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: ShellView(model: model, screen: screen), size: CGSize(width: 1440, height: 860)))
            XCTAssertGreaterThan(data.count, 20_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("shell-\(screen.rawValue).png")) }
        }
    }
}

/// N305: one Activity row per question, no empty round, no bare ✓ on the PM row, the Inbox says what it counts.
@MainActor
final class DashboardPolishN305Tests: XCTestCase {
    private func rec(_ id: String, _ t: TimeInterval, q: String = "Bash command: Do you want to proceed? npm test", kind: String = "permission",
                     by: DecisionRecord.By = .pm, result: DecisionRecord.Result, answer: String = "", why: String = "") -> DecisionRecord {
        DecisionRecord(id: id, time: Date(timeIntervalSince1970: t), cardID: "N1", agent: "dev-n1", kind: kind, question: q, by: by, result: result, answer: answer, why: why)
    }

    func testOneActivityRowPerQuestion() {
        let records = [rec("s", 1, result: .suggested, answer: "Yes"), rec("e", 2, result: .escalated, answer: "Yes", why: "outward step"),
                       rec("a", 3, by: .you, result: .answered, answer: "Yes"),
                       rec("f", 4, kind: "fix", result: .answered),
                       rec("again", 5, by: .you, result: .answered, answer: "No")]
        let merged = historyMergedQuestions(records)
        XCTAssertEqual(merged.map(\.id), ["a", "f", "again"], "suggested, sent and answered are one row; the same words asked after the answer are a new one")
        XCTAssertEqual(merged[0].by, .you)
        XCTAssertEqual(merged[0].result, .answered)
        XCTAssertEqual(merged[0].why, "outward step", "the reason it reached you is kept")
        XCTAssertEqual(historyDays(records, filter: HistoryFilter()).flatMap(\.rows).count, 3)
        XCTAssertEqual(historyMergedQuestions([rec("e", 1, result: .escalated)]).map(\.result), [.escalated], "an open question stays one row")
    }

    func testTheRowSaysWhoTheShortQuestionAndTheAnswer() {
        let long = "Bash command: Do you want to proceed? git push origin task/n305 --force-with-lease and then some more words here"
        let answered = DecisionFeed.summary(rec("a", 1, q: long, by: .you, result: .answered, answer: "Yes"))
        XCTAssertEqual(answered, "dev-n1: \"Bash command: Do you want to proceed? git push origin task/n305…\" → Yes")
        XCTAssertEqual(DecisionFeed.summary(rec("e", 1, q: "Colour?", kind: "choice", result: .escalated)), "dev-n1: \"Colour?\" · sent to you")
        XCTAssertEqual(DecisionFeed.cutAtWord("Do you want to proceed", 18), "Do you want to…")
        XCTAssertEqual(DecisionFeed.cutAtWord("Short", 18), "Short")
        XCTAssertTrue(historyIsQuestion("permission") && historyIsQuestion("plan") && !historyIsQuestion("fix"))
    }

    func testAnEmptyRoundIsNotShown() {
        let cards = [TaskCard(id: "A1", project: "d", status: .done, agent: nil, branch: nil, kind: nil, files: [], title: "A1", sections: [:], url: URL(fileURLWithPath: "/tmp/A1.md"))]
        let empty = PlanFile(rounds: [PlanRound(name: "R1", cards: ["A1"], reason: "", status: ""), PlanRound(name: "Sharing", cards: [], reason: "", status: "")], questions: [])
        XCTAssertNotEqual(GoalCard.shownRound(in: empty, cards: cards, pick: nil)?.name, "Sharing")
        XCTAssertNil(GoalCard.shownRound(in: PlanFile(rounds: [PlanRound(name: "S", cards: [], reason: "", status: "")], questions: []), cards: cards, pick: nil))
        XCTAssertNotEqual(GoalCard.shownRound(in: empty, cards: cards, pick: GoalPick(name: "Sharing", wasOpen: false))?.name, "Sharing")
    }

    func testThePMRowSkipsControlReplies() {
        let memory = PMActivityLine()
        XCTAssertEqual(memory.line("✓", pane: "p1"), "", "nothing real yet")
        XCTAssertEqual(memory.line("Reading N305", pane: "p1"), "Reading N305")
        XCTAssertEqual(memory.line("✓", pane: "p1"), "Reading N305")
        XCTAssertEqual(memory.line(" ✔. ", pane: "p1"), "Reading N305")
        XCTAssertEqual(memory.line("OK", pane: "p1"), "Reading N305")
        XCTAssertEqual(memory.line("✓", pane: "p2"), "", "per pane")
        XCTAssertFalse(PMActivityLine.isControlReply("✓ N305 merged"))
    }

    func testTheInboxSaysWhatItCounts() {
        XCTAssertTrue(InboxButton.help(active: true).contains("questions and cards waiting for your approval"))
        XCTAssertTrue(InboxButton.help(active: false).contains("Push to GitHub"))
    }
}

/// Snapshots → tasks/assets/N305-*.png (AGENT_PANEL_SNAPSHOT_DIR): Activity, the Agents pane and the Goal card (Tok has one, dark, palette).
@MainActor
final class DashboardPolishN305SnapshotTests: XCTestCase {
    private func activity() -> some View {
        let t = Date()
        func r(_ id: String, _ s: TimeInterval, _ kind: String, _ q: String, by: DecisionRecord.By = .pm, _ result: DecisionRecord.Result, _ answer: String = "", why: String = "") -> DecisionRecord {
            DecisionRecord(id: id, time: t.addingTimeInterval(s), cardID: "N305", agent: "ui_dev-n305", kind: kind, question: q, by: by, result: result, answer: answer, why: why)
        }
        let perm = "Bash command: Do you want to proceed? git push origin task/n305 --force-with-lease && scripts/app-test.sh"
        let records = [r("1", -300, "permission", perm, .suggested, "Yes"), r("2", -290, "permission", perm, .escalated, "Yes", why: "An outward step: the user decides."),
                       r("3", -200, "permission", perm, by: .you, .answered, "Yes"),
                       r("4", -100, "choice", "Which colour should the Activity chip use for questions?", .answered, "Amber (Recommended)", why: "Matches Waiting for you."),
                       r("5", -50, "plan", "Plan: merge the question rows and hide the empty round", .escalated)]
        return HistoryView(records: records, deciding: [], select: { _ in }).background(Tok.pane)
    }

    private func agents() -> some View {
        let pm = AgentStatus(paneID: "w9:pPM", workspaceID: "w9", state: .idle, cwd: "/repo", title: "PM")
        _ = PMActivityLine.shared.line("Reviewing N305's packet", pane: pm.paneID)
        return AgentsPane(state: .available([pm]), statusLine: { _ in "✓" }, isPM: { $0.paneID == pm.paneID }).background(Tok.pane)
    }

    private func goal() -> some View {
        let plan = PlanFile(rounds: [PlanRound(name: "Sharing (last)", cards: [], reason: "", status: "")], questions: [])
        return GoalCard(goal: "", plan: .plan(plan), cards: []).padding(16).background(Tok.bg)
    }

    private func write(_ view: some View, _ name: String, _ size: CGSize) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        XCTAssertGreaterThan(data.count, 5_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N305-\(name).png")) }
    }

    func testActivitySnapshot() throws { try write(activity(), "activity", CGSize(width: 380, height: 420)) }
    func testAgentsSnapshot() throws { try write(agents(), "agents", CGSize(width: 380, height: 140)) }
    func testGoalSnapshot() throws { try write(goal(), "goal", CGSize(width: 380, height: 180)) }
}
