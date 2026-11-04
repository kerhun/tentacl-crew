import XCTest
import SwiftUI
@testable import AgentPanel

/// The Plan screen v2 (N223): the grouping into Needs you / Now / Next / Later / History, and its snapshots.
@MainActor
final class PlanGroupsTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus) -> TaskCard {
        TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: "Title \(id)", sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }
    private func round(_ name: String, _ cards: [String], _ status: String = "") -> PlanRound { PlanRound(name: name, cards: cards, reason: "", status: status) }

    func testGroupsARunningRoundTheWaitingOneLaterOnesAndHistory() {
        let plan = PlanFile(rounds: [round("A", ["N1", "N2"], "done"), round("B", ["N3"]), round("C", ["N4", "N5"], "running"), round("D", ["N6"], "waiting"),
                                     round("Notch", ["N7"], "later"), round("Sharing", []), round("E", ["N8"])], questions: ["Licence?"])
        let cards = [card("N1", .done), card("N2", .done), card("N3", .done), card("N4", .done), card("N5", .needsFix), card("N6", .todo), card("N7", .todo), card("N8", .todo)]
        let waiting = RoundModel.waitingRound(in: plan, cards: cards)
        let g = PlanGroups.group(plan, cards: cards, waiting: waiting)
        XCTAssertEqual(waiting?.name, "D")
        XCTAssertEqual(g.waiting?.name, "D")
        XCTAssertEqual(g.questions, ["Licence?"])
        XCTAssertEqual(g.needsYouCount, 2)
        XCTAssertEqual(g.now.map(\.name), ["C"])
        XCTAssertEqual(g.next?.name, "D")
        XCTAssertEqual(g.later.map(\.name), ["Notch", "Sharing", "E"])
        XCTAssertEqual(g.history.map(\.name), ["B", "A"], "newest first")
        XCTAssertEqual(g.historyCards, 3)
    }

    func testSeveralRunningRoundsAreAllNow() {
        let plan = PlanFile(rounds: [round("A", ["N1"]), round("B", ["N2"]), round("C", ["N3"])], questions: [])
        let g = PlanGroups.group(plan, cards: [card("N1", .doing), card("N2", .review), card("N3", .todo)], waiting: nil)
        XCTAssertEqual(g.now.map(\.name), ["A", "B"])
        XCTAssertEqual(g.next?.name, "C", "with no waiting round the first planned one is next")
        XCTAssertTrue(g.history.isEmpty)
        XCTAssertEqual(g.needsYouCount, 0)
    }

    func testNothingRunning() {
        let plan = PlanFile(rounds: [round("A", ["N1"]), round("B", ["N2"]), round("C", ["N3"])], questions: [])
        let g = PlanGroups.group(plan, cards: [card("N1", .done), card("N2", .todo), card("N3", .awaitingStartApproval)], waiting: nil)
        XCTAssertTrue(g.now.isEmpty)
        XCTAssertEqual(g.next?.name, "B")
        XCTAssertEqual(g.later.map(\.name), ["C"], "planned rounds after the next one are later")
        XCTAssertEqual(g.history.map(\.name), ["A"])
    }

    func testAllDone() {
        let plan = PlanFile(rounds: [round("A", ["N1"]), round("B", ["N2", "N3"]), round("Notes", [], "done")], questions: [])
        let g = PlanGroups.group(plan, cards: [card("N1", .done), card("N2", .done), card("N3", .done)], waiting: nil)
        XCTAssertTrue(g.now.isEmpty)
        XCTAssertNil(g.next)
        XCTAssertTrue(g.later.isEmpty)
        XCTAssertEqual(g.history.map(\.name), ["Notes", "B", "A"])
        XCTAssertEqual(g.historyCards, 3)
    }

    func testCancelledCardsDoNotKeepARoundOpenOrCount() {
        let plan = PlanFile(rounds: [round("A", ["N1", "N2"]), round("B", ["N3"]), round("C", ["N4", "N5"])], questions: [])
        let g = PlanGroups.group(plan, cards: [card("N1", .done), card("N2", .cancelled), card("N3", .cancelled), card("N4", .cancelled), card("N5", .doing)], waiting: nil)
        XCTAssertEqual(g.history.map(\.name), ["B", "A"], "a round of only cancelled cards is over")
        XCTAssertEqual(g.historyCards, 1)
        XCTAssertEqual(g.now.map(\.name), ["C"])
        let p = PlanProgress(round: plan.rounds[2], cards: ["N4": card("N4", .cancelled), "N5": card("N5", .doing)])
        XCTAssertEqual([p.merged, p.fix, p.working, p.total], [0, 0, 1, 1])
    }

    func testAPMRunningMarkWithNoStartedCardIsNow() {
        let plan = PlanFile(rounds: [round("A", ["N1"], "running")], questions: [])
        XCTAssertEqual(PlanGroups.group(plan, cards: [card("N1", .todo)], waiting: nil).now.map(\.name), ["A"])
    }

    func testProgressCountsMergedFixAndWorking() {
        let r = round("R", ["A", "B", "C", "D", "Z"])
        let p = PlanProgress(round: r, cards: ["A": card("A", .done), "B": card("B", .needsFix), "C": card("C", .doing), "D": card("D", .todo)])
        XCTAssertEqual([p.merged, p.fix, p.working, p.total], [1, 1, 1, 5])
    }

    func testHistoryCollapse() {
        let rounds = (1...6).map { round("R\($0)", ["N\($0)"]) }
        let g = PlanGroups.group(PlanFile(rounds: rounds, questions: []), cards: (1...6).map { card("N\($0)", .done) }, waiting: nil)
        XCTAssertEqual(PlanGroups.historyShown, 4)
        XCTAssertEqual(Array(g.history.prefix(PlanGroups.historyShown)).map(\.name), ["R6", "R5", "R4", "R3"])
        XCTAssertEqual(PlanBoard.historyHeader(g), "6 rounds done · 6 cards")
    }

    func testTimesFromTheActionLog() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [ActionLogEvent(time: t0, text: "start N1 agent=dev-n1 (fresh)"), ActionLogEvent(time: t0 + 60, text: "start N2 agent=dev-n2"),
                      ActionLogEvent(time: t0 + 600, text: "merged N1 abc123 (script)"), ActionLogEvent(time: t0 + 900, text: "approved N2 def456"),
                      ActionLogEvent(time: t0 + 30, text: "start N9 agent=x"), ActionLogEvent(time: t0 + 5, text: "start-request N1 sheet cards=N1")]
        let times = PlanTimes(events: events, ids: ["N1", "N2"])
        let r = round("R", ["N1", "N2"])
        XCTAssertEqual(times.started(r), t0)
        XCTAssertEqual(times.lastMerge(r), t0 + 900)
        XCTAssertNil(times.started["N9"])
    }

    func testAgeAndSummaryLines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(PlanAge.text(now - 600, now: now), "10 min ago")
        XCTAssertEqual(PlanAge.text(now - 7200, now: now), "2 h ago")
        XCTAssertTrue(PlanAge.started(now - 6000, now: now).hasSuffix("· 1 h 40 min"))
        XCTAssertEqual(PlanAge.firstLines("a\n\nb\nc", count: 2), "a\n\nb")
        XCTAssertEqual(PlanAge.firstLines("a\nb", count: 2), "a\nb")
    }

    func testRowTitleDropsTheIdTheHeadingStartsWith() {
        var c = card("N214", .done)
        XCTAssertEqual(PlanBoard.title(c), "Title N214")
        c = TaskCard(id: "N214", project: "p", status: .done, agent: nil, branch: nil, kind: nil, files: [], title: "N214 · A test", sections: [:], url: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertEqual(PlanBoard.title(c), "A test")
    }

    func testAnswerQuotesTheQuestionAndThePlanRequestNamesTheGoal() {
        XCTAssertEqual(PlanView.answerDraft("Licence?"), "About your question in plan.json, \"Licence?\": ")
        XCTAssertTrue(GoalStore.planRequest(goal: " Ship v1 ").contains("Goal (goal.md): Ship v1\n"))
    }
}

/// Snapshots of the Plan screen from a fixture shaped like this project's plan: a running round, a round waiting for approval, later
/// rounds and a long history (tasks/assets/N223-*.png when AGENT_PANEL_SNAPSHOT_DIR is set).
@MainActor
final class PlanViewSnapshotTests: XCTestCase {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-v2-\(UUID().uuidString)")
        let tasks = dir.appendingPathComponent("data/tasks")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let cards: [(String, String, String)] = [
            ("N214", "done", "A test that also fails on main is not sent as a fix"), ("N215", "needs-fix", "A many-question call never moves the tab while you type"),
            ("N216", "done", "UI smoke test: every screen opens"), ("N217", "doing", "Stats: a Codex section"),
            ("N218", "todo", "Forgotten pbxproj named clearly"), ("N219", "todo", "Safe point per tool"), ("N220", "todo", "Thinking and reply language"),
            ("N221", "todo", "Clean old test lines"), ("N222", "todo", "One page margin"),
            ("N196", "todo", "Notch: status in the notch"), ("N197", "todo", "Notch: hover details"),
        ] + (180...195).map { ("N\($0)", "done", "Earlier work \($0)") }
        for (id, status, title) in cards {
            try "---\nid: \(id)\nproject: demo\nstatus: \(status)\n---\n# \(id) · \(title)\n\n## Goal\nx\n".write(to: tasks.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
        try planJSON.write(to: dir.appendingPathComponent("data/plan.json"), atomically: true, encoding: .utf8)
        return dir
    }

    private let planJSON = """
    {"rounds":[
     {"name":"Waiting for you v2","cards":["N180","N181"],"status":"done"},
     {"name":"App analysis v2","cards":["N182"],"status":"done"},
     {"name":"Timeline","cards":["N183","N184","N185"],"status":"done"},
     {"name":"Notes pad","cards":["N186","N187"],"status":"done"},
     {"name":"A · Less waiting","cards":["N188","N189","N190","N191","N192"],"status":"done"},
     {"name":"B · Several projects and merging","cards":["N193","N194","N195"],"status":"done"},
     {"name":"C · Improvements 1","cards":["N214","N215","N216","N217"],"reason":"Improvements before new features, medium priority first; Stats gets a Codex section.","status":"running"},
     {"name":"D · Improvements 2","cards":["N218","N219","N220","N221","N222"],"reason":"Starts when round C is merged.","status":"waiting"},
     {"name":"Notch","cards":["N196","N197"],"reason":"you said not now","status":"later"},
     {"name":"Sharing","cards":[],"reason":"licence, README, screenshots","status":"later"}],
     "questions":["Which licence, and when to prepare sharing?","Clean the old test lines out of the real action log (with a backup)?"]}
    """

    private func model(_ dir: URL) async -> PanelModel {
        setenv("AGENT_PANEL_DEMO_DIR", dir.path, 1)
        defer { unsetenv("AGENT_PANEL_DEMO_DIR") }
        return await DemoSupport.makeModel()
    }

    private let summary = ProjectSummary(text: "- macOS panel that runs a team of Claude and Codex agents on task cards\n- `main` is stable-156\n- Several projects, merge queue and round summary are in; not tried in the real app yet\n\n## Build\n\n`scripts/app-test.sh`",
                                         modified: Date().addingTimeInterval(-600))

    private func write(_ data: Data, _ name: String) throws {
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
    }

    func testPlanScreenWithARunningRoundAndOneWaiting() async throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = await model(dir)
        let load = PlanReader.load(dataDir: dir.appendingPathComponent("data"))
        guard case .plan(let file) = load else { return XCTFail("fixture plan not read") }
        let cards = model.selectedTaskCards
        XCTAssertEqual(cards.count, 27)
        let g = PlanGroups.group(file, cards: cards, waiting: RoundModel.waitingRound(in: file, cards: cards))
        XCTAssertEqual(g.waiting?.name, "D · Improvements 2")
        XCTAssertEqual(g.now.map(\.name), ["C · Improvements 1"])
        XCTAssertEqual(g.history.count, 6)
        let start = Date().addingTimeInterval(-6000)
        let times = PlanTimes(events: [ActionLogEvent(time: start, text: "start N214 agent=dev-n214"),
                                       ActionLogEvent(time: Date(timeIntervalSince1970: 1_792_540_800), text: "merged N195 abc (script)")], ids: Set(file.rounds.flatMap(\.cards)))
        XCTAssertNotNil(times.lastMerge(g.history[0]), "round B's last merge is in the log")
        XCTAssertNotNil(times.started(g.now[0]))
        for (name, size) in [("N223-plan.png", CGSize(width: 1200, height: 1240)), ("N223-plan-narrow.png", CGSize(width: 760, height: 1700))] {
            let view = PlanView(model: model, summary: summary, plan: load, times: times)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
            XCTAssertGreaterThan(data.count, 20_000)
            try write(data, name)
        }
    }

    func testPlanScreenWithNoPlanYet() async throws {
        let model = await DemoSupport.makeModel()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: PlanView(model: model), size: CGSize(width: 1200, height: 700)))
        XCTAssertGreaterThan(data.count, 10_000)
        try write(data, "N223-plan-empty.png")
    }
}

@MainActor
final class PlanFollowTests: XCTestCase {
    func testPlanIfChangedSeesANewPlanWithTheSameCardCount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("plan.json")
        XCTAssertNil(PlanView.planIfChanged(dataDir: dir, since: nil), "no file, nothing to show")
        try Data(#"{"rounds":[{"name":"A","cards":["N1"]}]}"#.utf8).write(to: file)
        let first = try XCTUnwrap(PlanView.planIfChanged(dataDir: dir, since: nil))
        XCTAssertNil(PlanView.planIfChanged(dataDir: dir, since: first.date))
        try Data(#"{"rounds":[{"name":"B","cards":["N1"]}]}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let second = try XCTUnwrap(PlanView.planIfChanged(dataDir: dir, since: first.date))
        guard case .plan(let p) = second.plan else { return XCTFail("not a plan") }
        XCTAssertEqual(p.rounds.map(\.name), ["B"])
    }
}
