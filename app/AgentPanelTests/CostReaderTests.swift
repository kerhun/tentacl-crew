import XCTest
import SwiftUI
@testable import AgentPanel

final class CostReaderTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var fixture: URL { root.appendingPathComponent("tests/fixtures/transcripts/cost-session.jsonl") }

    private func temp() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testSumsTokensOncePerMessageEvenWhenStreamedInSeveralLines() throws {
        let c = try XCTUnwrap(CostReader.read(fixture))
        // m1 is written twice (the later line wins); m2 once; the synthetic line is ignored.
        XCTAssertEqual(c.usage, TokenUsage(input: 110, output: 220, cacheWrite: 1300, cacheRead: 6000))
    }

    func testDetectsTheModelFamilyWithMostOutput() throws {
        let c = try XCTUnwrap(CostReader.read(fixture))
        XCTAssertEqual(c.model, .opus)
        XCTAssertEqual(ModelFamily.detect("claude-sonnet-4-5-20250929"), .sonnet)
        XCTAssertEqual(ModelFamily.detect("claude-haiku-4-5"), .haiku)
        XCTAssertNil(ModelFamily.detect("gpt-5"))
    }

    func testDollarsComeFromThePriceTable() throws {
        let c = try XCTUnwrap(CostReader.read(fixture))
        let o = PriceTable.estimate[.opus]!, s = PriceTable.estimate[.sonnet]!
        let opus = (100 * o.input + 200 * o.output + 1000 * o.cacheWrite + 2000 * o.cacheRead) / 1_000_000
        let sonnet = (10 * s.input + 20 * s.output + 300 * s.cacheWrite + 4000 * s.cacheRead) / 1_000_000
        XCTAssertEqual(try XCTUnwrap(c.dollars), opus + sonnet, accuracy: 1e-9)
    }

    func testUnknownModelMakesDollarsUnknownNotZero() throws {
        let dir = try temp()
        let f = dir.appendingPathComponent("s.jsonl")
        try #"{"type":"assistant","message":{"id":"x","model":"mystery-1","usage":{"input_tokens":5,"output_tokens":5}}}"#.write(to: f, atomically: true, encoding: .utf8)
        let c = try XCTUnwrap(CostReader.read(f))
        XCTAssertEqual(c.usage.input, 5)
        XCTAssertNil(c.dollars)
    }

    func testMissingOrUnreadableFileIsUnknownNotZero() throws {
        let dir = try temp()
        XCTAssertNil(CostReader.read(dir.appendingPathComponent("none.jsonl")))
        XCTAssertNil(CostReader.read(dir))   // a folder cannot be read as a session
        let locked = dir.appendingPathComponent("locked.jsonl")
        try Data("{}".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        XCTAssertNil(CostReader.read(locked))
    }

    func testTaskCostSumsTheSessionsOfTheWorktreeFolderStartedAfterTheStart() throws {
        let projects = try temp()
        let worktree = "/work/demo/.agent-worktrees/feat-x"
        let folder = projects.appendingPathComponent("-work-demo--agent-worktrees-feat-x")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("new.jsonl"))
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("old.jsonl"))
        let start = Date()
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: folder.appendingPathComponent("new.jsonl").path)   // a copy keeps the fixture's checkout time
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-86_400)], ofItemAtPath: folder.appendingPathComponent("old.jsonl").path)
        let one = try XCTUnwrap(CostReader.read(fixture)).dollars!
        XCTAssertEqual(try XCTUnwrap(CostReader.taskCost(projectsRoot: projects, worktree: worktree, since: start.addingTimeInterval(-3600))?.dollars), one, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CostReader.taskCost(projectsRoot: projects, worktree: worktree, since: nil)?.dollars), 2 * one, accuracy: 1e-9)
        XCTAssertNil(CostReader.taskCost(projectsRoot: projects, worktree: "/work/demo/.agent-worktrees/other", since: nil))
    }

    // MARK: Stats

    private func card(_ id: String) -> TaskCard {
        var c = TaskCard(id: id, project: "p", status: .done, agent: nil, branch: "feat/\(id)", kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        c.modified = nil
        return c
    }

    func testStatsCostsPerTaskPerDayAndTotal() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let f = ISO8601DateFormatter()
        let events = ActionLogEvents.parse("2026-10-16T09:00:00Z approved A\n2026-10-17T09:00:00Z approved B\n2026-10-17T10:00:00Z approved C")
        let costs = ["A": CardCost(agent: 1.5, pm: 0.25), "B": CardCost(agent: nil, pm: 0.1), "C": CardCost(agent: 2, pm: 0)]
        let s = Stats.compute(cards: [card("A"), card("B"), card("C")], events: events, costs: costs, calendar: utc, now: f.date(from: "2026-10-17T12:00:00Z")!, days: 3)
        XCTAssertEqual(s.taskCosts.first { $0.cardID == "A" }?.dollars, 1.75)
        XCTAssertNil(s.taskCosts.first { $0.cardID == "B" }?.dollars)
        XCTAssertEqual(s.costPerDay.map(\.dollars), [0, 1.75, 2])
        XCTAssertEqual(s.totalCost, 3.75, accuracy: 1e-9)
        XCTAssertEqual(s.unknownCostTasks, 1)
    }

    func testCostTextShowsEstimateOrUnknown() {
        XCTAssertEqual(Stats.costText(1.754), "≈ $1.75")
        XCTAssertEqual(Stats.costText(0.004), "≈ < $0.01")
        XCTAssertEqual(Stats.costText(nil), "unknown")
    }
}
