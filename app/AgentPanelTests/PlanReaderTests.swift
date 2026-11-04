import XCTest
import SwiftUI
@testable import AgentPanel

final class PlanReaderTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus) -> TaskCard {
        TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: "Title \(id)", sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesRoundsAndQuestions() {
        let json = #"{"rounds":[{"name":"Round 1","cards":["N1","N2"],"reason":"base first","status":"running"},{"name":"Round 2","cards":["N3"]}],"questions":["Ship v1?"]}"#
        guard case .plan(let plan) = PlanReader.parse(data(json)) else { return XCTFail("not a plan") }
        XCTAssertEqual(plan.rounds.map(\.name), ["Round 1", "Round 2"])
        XCTAssertEqual(plan.rounds[0].cards, ["N1", "N2"])
        XCTAssertEqual(plan.rounds[0].reason, "base first")
        XCTAssertEqual(plan.rounds[1].reason, "")
        XCTAssertEqual(plan.questions, ["Ship v1?"])
    }

    func testBrokenJSONIsBrokenNotACrash() {
        for text in ["", "{not json", "[1,2]", #"{"rounds":"x"}"#] {
            if case .broken = PlanReader.parse(data(text)) {} else { XCTFail("expected broken for \(text)") }
        }
    }

    func testRoundWithoutNameOrWithBadFieldsIsSkippedNotFatal() {
        let json = #"{"rounds":[{"cards":["N1"]},{"name":"Ok","cards":["N2",7]},"junk"]}"#
        guard case .plan(let plan) = PlanReader.parse(data(json)) else { return XCTFail("not a plan") }
        XCTAssertEqual(plan.rounds.map(\.name), ["Ok"])
        XCTAssertEqual(plan.rounds[0].cards, ["N2"])
    }

    func testMissingFileIsMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        XCTAssertEqual(PlanReader.load(dataDir: dir), .missing)
    }

    func testLoadReadsPlanJsonFromTheDataFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data(#"{"rounds":[{"name":"R","cards":[]}]}"#).write(to: dir.appendingPathComponent("plan.json"))
        guard case .plan(let plan) = PlanReader.load(dataDir: dir) else { return XCTFail("not a plan") }
        XCTAssertEqual(plan.rounds.count, 1)
    }

    func testProgressCountsDoneCardsAndUnknownOnesAsNotDone() {
        let round = PlanRound(name: "R", cards: ["A", "B", "C", "Z"], reason: "", status: "")
        let p = PlanReader.progress(of: round, cards: [card("A", .done), card("B", .doing), card("C", .done)])
        XCTAssertEqual(p.done, 2)
        XCTAssertEqual(p.total, 4)
    }

    func testCancelledCardsLeaveTheTotal() {
        let round = PlanRound(name: "R", cards: ["A", "B"], reason: "", status: "")
        let p = PlanReader.progress(of: round, cards: [card("A", .done), card("B", .cancelled)])
        XCTAssertEqual(p.total, 1)
        XCTAssertEqual(p.done, 1)
    }

    func testWaitingListsWaitingRoundsAndQuestions() {
        let plan = PlanFile(rounds: [PlanRound(name: "R1", cards: [], reason: "", status: "running"), PlanRound(name: "R2", cards: [], reason: "", status: "waiting")], questions: ["Q?"])
        XCTAssertEqual(PlanReader.waiting(in: plan), ["Round R2 is waiting for you to start it.", "Q?"])
    }

    func testGoalIsSavedInTheDataFolderAndReadBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goal-\(UUID().uuidString)")
        XCTAssertEqual(GoalStore.read(dataDir: dir), "")
        try GoalStore.write("Ship the panel", dataDir: dir)
        XCTAssertEqual(GoalStore.read(dataDir: dir), "Ship the panel")
    }

    func testGoalMessageForThePM() {
        XCTAssertTrue(GoalStore.pmMessage(goal: "Ship it").contains("Ship it"))
        XCTAssertTrue(GoalStore.pmMessage(goal: "").contains("cleared"))
    }

    @MainActor func testPlanViewRenders() async throws {
        let model = await DemoSupport.makeModel()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AnyView(PlanView(model: model)), size: CGSize(width: 900, height: 700)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("plan.png")) }
    }
}

final class SummaryReaderTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMissingOrBlankSummaryIsNil() throws {
        let dir = try tempDir()
        XCTAssertNil(SummaryReader.load(dataDir: dir))
        try "  \n".write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(SummaryReader.load(dataDir: dir))
    }

    func testLoadReadsSummaryWithItsDate() throws {
        let dir = try tempDir(), url = dir.appendingPathComponent("summary.md")
        try "# Demo\n\nBuild with `make`.\n".write(to: url, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let summary = try XCTUnwrap(SummaryReader.load(dataDir: dir))
        XCTAssertEqual(summary.text, "# Demo\n\nBuild with `make`.")
        XCTAssertEqual(summary.modified, date)
    }

    func testReloadKeepsThePreviousSummaryUntilTheFileChanges() throws {
        let dir = try tempDir(), url = dir.appendingPathComponent("summary.md")
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(SummaryReader.load(dataDir: dir))
        // Same date: the file is not read again, so a stale previous value comes back as is.
        let stale = ProjectSummary(text: "cached", modified: first.modified)
        XCTAssertEqual(SummaryReader.reload(dataDir: dir, previous: stale), stale)
        try "two".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        XCTAssertEqual(SummaryReader.reload(dataDir: dir, previous: stale)?.text, "two")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(SummaryReader.reload(dataDir: dir, previous: stale))
    }

    @MainActor func testPlanViewRendersWithASummaryAndWithout() async throws {
        let model = await DemoSupport.makeModel()
        let summary = ProjectSummary(text: "## Structure\n\nA SwiftUI app in `app/`.\n\n- Build: `xcodebuild build`\n- Test: `scripts/app-test.sh`", modified: Date(timeIntervalSince1970: 1_800_000_000))
        for (name, s) in [("plan-summary.png", summary as ProjectSummary?), ("plan-summary-empty.png", nil)] {
            let view = PlanView(model: model, summary: s)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: AnyView(view), size: CGSize(width: 900, height: 700)))
            XCTAssertGreaterThan(data.count, 10_000)
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        }
    }
}
