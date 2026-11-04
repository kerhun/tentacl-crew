import XCTest
import SwiftUI
@testable import AgentPanel

/// The Tasks screen detail of design B (N135): progress steps, report in short, the agent box, changed files and the tab row.
final class TaskProgressTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ hm: String, day: String = "2026-10-19") -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) \(hm)")!
    }
    private func card(_ status: TaskStatus, sections: [String: String] = [:], agent: String? = "ui_dev-n1", created: String = "13:05") -> TaskCard {
        var c = TaskCard(id: "N1", project: "p", status: status, agent: agent, branch: "task/n1", kind: nil, files: ["a.swift"], title: "T", sections: sections,
                         url: URL(fileURLWithPath: "/tmp/N1.md"))
        c.created = at(created)
        return c
    }
    private func ev(_ hm: String, _ text: String) -> ActionLogEvent { ActionLogEvent(time: at(hm), text: text, project: "p") }
    private let passedPacket = "Head: abc\n\nBuild: passed (x)\n\nScreenshots: not used in this project\n\nDiff summary:\n```\n a.swift | 2 +\n 1 file changed, 2 insertions(+)\n```"

    private func steps(_ c: TaskCard, _ phase: TaskPhase?, _ events: [ActionLogEvent] = [], now: String = "13:49") -> [ProgressStep] {
        TaskProgress.steps(card: c, phase: phase, events: events, now: at(now), calendar: cal)
    }

    func testATodoCardHasOnlyItsCardStepDone() {
        let s = steps(card(.todo, agent: nil), nil)
        XCTAssertEqual(s.map(\.kind), ProgressStep.Kind.allCases)
        XCTAssertEqual(s.map(\.kind.title), ["Card", "Started", "Work", "Packet", "Your review", "Merged"])
        XCTAssertEqual(s.map(\.tone), [.done, .todo, .todo, .todo, .todo, .todo])
        XCTAssertEqual(s.map(\.when), ["13:05", "—", "—", "—", "—", "—"])
    }

    func testACardFromAnotherDayShowsTheDay() {
        var c = card(.todo, agent: nil); c.created = at("09:00", day: "2026-10-17")
        XCTAssertEqual(steps(c, nil)[0].when, "Oct 17")
    }

    func testACardWaitingForStartApprovalWaitsForTheUser() {
        let s = steps(card(.awaitingStartApproval, agent: nil), nil)
        XCTAssertEqual(s[1].tone, .waiting)
        XCTAssertEqual(s[1].when, "your call")
    }

    func testAWorkingAgentIsBlueWithItsDurationSoFar() {
        let s = steps(card(.doing), .working, [ev("13:08", "start N1 agent=ui_dev-n1 role=ui_dev"), ev("13:09", "start N2 agent=x")])
        XCTAssertEqual(s.map(\.tone), [.done, .done, .working, .todo, .todo, .todo])
        XCTAssertEqual(s[1].when, "13:08")
        XCTAssertEqual(s[2].when, "41 min")
    }

    func testAnAgentAskingTheUserMakesTheWorkStepOrange() {
        let s = steps(card(.doing), .waitingForYou, [ev("13:08", "start N1 agent=ui_dev-n1")])
        XCTAssertEqual(s[2].tone, .waiting)
        XCTAssertEqual(s[2].when, "asks you")
    }

    func testAFinishedAgentWaitsForThePacket() {
        let s = steps(card(.doing, sections: ["Report": "Done."]), .finished, [ev("13:08", "start N1 agent=ui_dev-n1")])
        XCTAssertEqual(s.map(\.tone), [.done, .done, .done, .waiting, .todo, .todo])
        XCTAssertEqual(s[3].when, "prepare")
    }

    func testAReviewCardWithAPassedPacketWaitsForTheUsersReview() {
        let s = steps(card(.review, sections: ["Review packet": passedPacket]), .inReview,
                      [ev("13:08", "start N1 agent=ui_dev-n1"), ev("13:49", "review packet prepared for N1"), ev("13:50", "review packet prepared for N2")], now: "14:10")
        XCTAssertEqual(s.map(\.tone), [.done, .done, .done, .done, .waiting, .todo])
        XCTAssertEqual(s.map(\.when), ["13:05", "13:08", "41 min", "passed 13:49", "now", "—"])
    }

    func testAFailedPacketWithoutALogLineSaysSo() {
        let failed = passedPacket.replacingOccurrences(of: "Build: passed", with: "Build: failed")
        XCTAssertEqual(steps(card(.review, sections: ["Review packet": failed]), .inReview)[3].when, "failed")
    }

    func testAMergedCardIsAllGreenWithTheMergeTimeAndRelease() {
        let decision = "Merged 2026-10-19 by PM (63fef19, stable-80). Cause: x."
        let s = steps(card(.done, sections: ["Review packet": passedPacket, "Decision": decision]), nil,
                      [ev("13:08", "start N1 agent=ui_dev-n1"), ev("13:49", "review packet prepared for N1"), ev("14:30", "approved N1 task/n1 into main")], now: "16:00")
        XCTAssertEqual(s.map(\.tone), [.done, .done, .done, .done, .done, .done])
        XCTAssertEqual(s[4].when, "approved")
        XCTAssertEqual(s[5].when, "14:30 · stable-80")
        XCTAssertEqual(TaskProgress.commit(card(.done, sections: ["Decision": decision])), "63fef19")
        XCTAssertEqual(TaskProgress.release(card(.done, sections: ["Decision": decision])), "stable-80")
    }

    func testACancelledCardEndsClosed() {
        let s = steps(card(.cancelled), nil)
        XCTAssertEqual(s[5].when, "closed")
        XCTAssertEqual(s[5].tone, .todo)
    }

    func testANeedsFixCardIsBackInWork() {
        let s = steps(card(.needsFix, sections: ["Review packet": passedPacket]), .needsFix,
                      [ev("13:08", "start N1 agent=ui_dev-n1"), ev("14:00", "fix request sent to w1 for N1")], now: "14:20")
        XCTAssertEqual(s[2].tone, .working)
        XCTAssertEqual(s[2].when, "fixing")
        XCTAssertEqual(s[4].when, "fix asked 14:00")
    }

    // MARK: Report in short

    func testReportInShortTakesTheFirstThreeBulletsWithTheirBoldLead() {
        let report = """
        Done on `task/n130`, commit e00ccc6.

        - **Cause (measured, not guessed).** It is hit testing. The checkbox `Button` label is clear.
        - **Fix.** `NotesPad.checkbox` adds a content shape. The look does not change.
        - Plain bullet without a lead.
        - **Fourth.** Not shown.
        """
        XCTAssertEqual(ReportSummary.lines("- **Fix:** One sentence only."), [ReportLine(lead: "Fix", text: "One sentence only.")], "the period stays")
        XCTAssertEqual(ReportSummary.lines(report), [
            ReportLine(lead: "Cause (measured, not guessed)", text: "It is hit testing."),
            ReportLine(lead: "Fix", text: "NotesPad.checkbox adds a content shape."),
            ReportLine(lead: nil, text: "Plain bullet without a lead."),
        ])
    }

    func testReportInShortWithoutBulletsTakesTheFirstThreeSentences() {
        XCTAssertEqual(ReportSummary.lines("One is here. Two is **there**! Three? Four."),
                       [ReportLine(lead: nil, text: "One is here."), ReportLine(lead: nil, text: "Two is there!"), ReportLine(lead: nil, text: "Three?")])
        XCTAssertEqual(ReportSummary.lines("  \n"), [])
    }

    // MARK: Agent box

    private func role(model: String = "sonnet", effort: String = "medium") -> RoleConfig {
        RoleConfig(name: "ui_dev", kind: "worker", model: model, effort: effort, permissionMode: "default", outputStyle: "", allowedTools: [], skills: [], instructionFile: "")
    }

    func testModelNamesReadLikeTheProduct() {
        XCTAssertEqual(ModelName.display("claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(ModelName.display("claude-opus-5-5[1m]"), "Opus 5.5")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelName.display("opus"), "Opus")
        XCTAssertEqual(ModelName.display(""), "default")
        XCTAssertEqual(ModelName.display("gpt-5"), "gpt-5")
    }

    func testTheAgentBoxShowsTheModelReallyUsedWithTheConfiguredOneInTheTooltip() {
        var cost = SessionCost()
        cost.byFamily[.sonnet] = TokenUsage(input: 1_000, output: 99_000, cacheWrite: 26_000, cacheRead: 1_974_000)
        cost.models = ["claude-sonnet-5-5": 99_000, "claude-haiku-5-5": 10]
        let f = AgentFacts.make(role: role(model: "opus"), cost: cost, hasAgent: true)
        XCTAssertEqual(f.model, "Sonnet 5.5")
        XCTAssertEqual(f.modelHelp, "Configured for the role: Opus")
        XCTAssertEqual(f.effort, "medium")
        XCTAssertEqual(f.tokens, "2.1 M · 94% cached")
        XCTAssertEqual(f.cost, "$1.45")
    }

    func testTheSameModelHasNoTooltip() {
        var cost = SessionCost()
        cost.byFamily[.sonnet] = TokenUsage(input: 500, output: 300, cacheWrite: 0, cacheRead: 0)
        cost.models = ["claude-sonnet-5-5": 300]
        let f = AgentFacts.make(role: role(model: "claude-sonnet-5-5"), cost: cost, hasAgent: true)
        XCTAssertNil(f.modelHelp)
        XCTAssertEqual(f.tokens, "800 · 0% cached")
    }

    func testACardWithoutAnAgentOrSessionShowsTheConfiguredRoleAndDashes() {
        let none = AgentFacts.make(role: role(), cost: nil, hasAgent: false)
        XCTAssertEqual(none, AgentFacts(model: "Sonnet", modelHelp: nil, effort: "medium", tokens: "—", cost: "—"))
        XCTAssertEqual(AgentFacts.make(role: nil, cost: nil, hasAgent: true), AgentFacts(model: "—", modelHelp: nil, effort: "—", tokens: "—", cost: "—"))
        var unpriced = SessionCost(); unpriced.unpriced = TokenUsage(input: 12_000, output: 0, cacheWrite: 0, cacheRead: 0)
        XCTAssertEqual(AgentFacts.make(role: role(), cost: unpriced, hasAgent: true).cost, "unknown")
        XCTAssertEqual(AgentFacts.make(role: role(), cost: unpriced, hasAgent: true).tokens, "12 k · 0% cached")
    }

    func testCostReaderKeepsTheExactModelNames() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("n135-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let line = { (id: String, model: String, out: Int) in
            #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1,"output_tokens":\#(out)}}}"#
        }
        let file = dir.appendingPathComponent("s.jsonl")
        try [line("a", "claude-sonnet-5-5", 50), line("b", "claude-haiku-5-5", 5), line("c", "claude-sonnet-5-5", 20)].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let cost = try XCTUnwrap(CostReader.read(file))
        XCTAssertEqual(cost.models, ["claude-sonnet-5-5": 70, "claude-haiku-5-5": 5])
        XCTAssertEqual(cost.mainModel, "claude-sonnet-5-5")
    }

    // MARK: Changed files

    func testChangedFilesComeFromTheDiffSummary() {
        let diff = """
         app/AgentPanel/State/NotesModel.swift     | 18 ++++++++++++++++--
         app/AgentPanel/Views/NotesPad.swift       |  2 +
         app/AgentPanelTests/NotesPadTests.swift   | 89 +++++++++++++++++++++++++++++++
         app/Assets/icon.png                       | Bin 0 -> 1234 bytes
         4 files changed, 107 insertions(+), 2 deletions(-)
        """
        let files = ChangedFile.parse(diff)
        XCTAssertEqual(files.map(\.name), ["NotesModel.swift", "NotesPad.swift", "NotesPadTests.swift", "icon.png"])
        XCTAssertEqual(files.map(\.text), ["+16 −2", "+2", "+89", "binary"])
        XCTAssertEqual(ChangedFile.parse(" a.swift | 16 +++++-").map(\.text), ["≈ +13 −3"], "a scaled mixed bar gives only the share")
        XCTAssertEqual(files[0].path, "app/AgentPanel/State/NotesModel.swift")
        XCTAssertEqual(ChangedFile.parse(""), [])
    }

    // MARK: Tabs

    func testTheTabRowGreysOutWhatDoesNotExistYetAndCounts() {
        let bare = card(.todo, agent: nil)
        let t = DetailTab.items(card: TaskCard(id: "N1", project: "p", status: .todo, agent: nil, branch: nil, kind: nil, files: [], title: "T", sections: [:],
                                               url: bare.url), shots: 0)
        XCTAssertEqual(t.map(\.tab), [.overview, .card, .report, .packet, .changes, .screenshots, .timeline, .preview])
        XCTAssertEqual(t.map(\.title), ["Overview", "Card", "Report", "Review packet", "Changes", "Screenshots", "Timeline", "Preview"])
        XCTAssertEqual(t.filter(\.enabled).map(\.tab), [.overview, .card, .timeline, .preview], "Preview is always there: with no page found it offers an address field")
        let full = DetailTab.items(card: card(.review, sections: ["Report": "x", "Review packet": passedPacket]), shots: 2)
        XCTAssertEqual(full.map(\.title), t.map(\.title), "counts are not part of the label")
        XCTAssertEqual(full.map(\.count), [nil, nil, nil, nil, 1, 2, nil, nil])
        XCTAssertEqual(t.map(\.count), [nil, nil, nil, nil, nil, nil, nil, nil])
        XCTAssertTrue(full.allSatisfy(\.enabled))
    }

    func testCommandBracketsMoveBetweenTheEnabledTabs() {
        let t = DetailTab.items(card: card(.review, sections: ["Report": "x"]), shots: 0)
        XCTAssertEqual(DetailTab.move(from: .overview, in: t, by: 1), .card)
        XCTAssertEqual(DetailTab.move(from: .report, in: t, by: 1), .changes, "the empty packet tab is skipped")
        XCTAssertEqual(DetailTab.move(from: .timeline, in: t, by: 1), .preview)
        XCTAssertEqual(DetailTab.move(from: .preview, in: t, by: 1), .preview, "stops at the end")
        XCTAssertEqual(DetailTab.move(from: .overview, in: t, by: -1), .overview)
    }

    func testEveryCardOpensOnTheOverview() {
        for s in [TaskStatus.todo, .doing, .review, .done] { XCTAssertEqual(openingTab(card: card(s)), .overview) }
    }

    // MARK: Design B 1:1 (N142)

    func testOnlyTheApproveButtonIsGreen() {
        XCTAssertEqual(NextStepBar.primaryKind(.approve), .approve)
        XCTAssertEqual(NextStepBar.primaryKind(.prepare), .decision, "Prepare review keeps its orange")
        XCTAssertEqual(NextStepBar.primaryKind(.start), .confirm, "Start keeps its blue")
        XCTAssertEqual(HeaderButtonStyle.Kind.approve.fill, Tok.go)
        XCTAssertEqual(HeaderButtonStyle.Kind.approve.ink, Tok.goInk)
        XCTAssertEqual(HeaderButtonStyle.Kind.decision.fill, Tok.ask)
        XCTAssertEqual(HeaderButtonStyle.Kind.confirm.fill, Tok.work)
        XCTAssertEqual(HeaderButtonStyle.Kind.secondary.fill, Tok.raise)
    }

    func testTheOverviewSplitsTheWidthOneAndAHalfToOne() throws {
        let c = try XCTUnwrap(OverviewColumns.columns(width: 872), "the detail at 1440 wide with the 440 list")
        XCTAssertEqual(c.report, 499.33, accuracy: 0.1)
        XCTAssertEqual(c.side, 356.67, accuracy: 0.1)
        XCTAssertNotNil(OverviewColumns.columns(width: 736))
        XCTAssertNil(OverviewColumns.columns(width: 735), "too narrow for a 300 side column: the boxes stack")
    }

    func testReviewTextIsTheLightOrangeAndTheBarTheStrongOne() {
        XCTAssertEqual(RoundRow.color(.ask), Tok.askText)
        XCTAssertEqual(ProgressStepsRow.ink(.waiting), Tok.askText)
        XCTAssertEqual(ProgressStepsRow.bar(.waiting), Tok.ask)
    }
}

/// Snapshots of the design B detail for a doing and a review card, light and dark (N135); PNGs with TEST_RUNNER_AGENT_PANEL_SNAPSHOT_DIR.
@MainActor
final class TaskDetailBSnapshotTests: XCTestCase {
    private func detail(_ status: TaskStatus, phase: TaskPhase?, packet: Bool) -> TaskDetailView {
        let packetText = "Head: abc\n\nBuild: passed (x)\n\nScreenshots: not used\n\nDiff summary:\n```\n app/NotesPad.swift | 2 +\n app/NotesModel.swift | 18 ++++++++++++++++--\n 2 files changed, 18 insertions(+), 2 deletions(-)\n```"
        var sections = ["Goal": "Every checkbox ticks.",
                        "Report": "- **Cause.** The open box was filled with .clear, so only its outline took clicks. More.\n- **Fix.** The whole box takes the click.\n- **Proof.** Click scan in a real window; 1,509 tests pass."]
        if packet { sections["Review packet"] = packetText }
        var card = TaskCard(id: "N130", project: "p", status: status, agent: "ui_dev-n130", branch: "task/n130", kind: nil, files: ["NotesPad.swift"],
                            title: "Notes pad: every checkbox ticks", sections: sections, url: URL(fileURLWithPath: "/tmp/N130.md"), roles: ["ui_dev"])
        card.created = Date().addingTimeInterval(-3600)
        let events = [ActionLogEvent(time: Date().addingTimeInterval(-3000), text: "start N130 agent=ui_dev-n130", project: "p"),
                      ActionLogEvent(time: Date().addingTimeInterval(-600), text: "review packet prepared for N130", project: "p")]
        return TaskDetailView(card: card, shots: [], opener: nil, phase: phase, startState: StartButtonState(enabled: false, help: ""),
                              reviewState: reviewButtonStates(card: card, canAct: true, reason: nil, worktreeExists: true, busy: false, agentWorking: phase == .working),
                              onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {},
                              logEvents: { packet ? events : Array(events.prefix(1)) }, roundName: "Feedback on stable-77",
                              agentFacts: AgentFacts(model: "Sonnet 5.5", modelHelp: nil, effort: "medium", tokens: "2.1 M · 94% cached", cost: "$1.84"))
    }

    func testDoingAndReviewCardsInLightAndDark() throws {
        for (name, status, phase, packet) in [("doing", TaskStatus.doing, TaskPhase.working, false), ("review", .review, .inReview, true)] {
            for scheme in [ColorScheme.light, .dark] {
                let data = try XCTUnwrap(SnapshotRenderer.render(view: detail(status, phase: phase, packet: packet).environment(\.colorScheme, scheme),
                                                                 size: CGSize(width: 1000, height: 760)))
                XCTAssertGreaterThan(data.count, 20_000)
                if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                    try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n135-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func testANarrowDetailStacksTheBoxes() throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: detail(.review, phase: .inReview, packet: true), size: CGSize(width: 620, height: 1000)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n135-review-narrow.png"))
        }
    }

    func testTheListByRound() async throws {
        let model = await DemoSupport.makeModel()
        let ids = model.selectedTaskCards.map(\.id)
        let plan = PlanFile(rounds: [PlanRound(name: "First round", cards: Array(ids.prefix(3)), reason: "", status: ""),
                                     PlanRound(name: "Next", cards: Array(ids.dropFirst(3).prefix(2)), reason: "", status: "")], questions: [])
        let data = try XCTUnwrap(SnapshotRenderer.render(view: TaskListView(model: model, plan: .constant(plan)), size: CGSize(width: 360, height: 760)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n135-list-by-round.png"))
        }
    }

    /// N142: the whole window on Tasks with a review card, each list view, at the default size and at the narrowest window.
    func testTheTasksScreenAtTheDefaultAndTheNarrowestWindow() async throws {
        let model = await DemoSupport.makeModel()
        let project = try XCTUnwrap(model.selectedProjectID)
        model.selectedCardID = try XCTUnwrap(model.selectedTaskCards.first { $0.status == .review }?.id)
        for mode in TaskListMode.allCases {
            mode.save(model.defaults, project: project)
            for (size, name) in [(CGSize(width: 1440, height: 860), "1440"), (CGSize(width: 1100, height: 600), "narrow")] {
                let data = try XCTUnwrap(SnapshotRenderer.render(view: ShellView(model: model, screen: .tasks), size: size))
                XCTAssertGreaterThan(data.count, 20_000)
                if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                    try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n142-\(mode.rawValue)-\(name).png"))
                }
            }
        }
    }
}
