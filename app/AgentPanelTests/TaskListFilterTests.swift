import SwiftUI
import XCTest
@testable import AgentPanel

final class TaskListFilterTests: XCTestCase {
    /// N308: a project with no cards shows New task… and Plan a round, light and dark.
    @MainActor func testSnapshotOfAnEmptyProject() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n308-demo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: DemoSupport.demoDir, to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tasks = dir.appendingPathComponent("data/tasks")
        for file in try FileManager.default.contentsOfDirectory(at: tasks, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: file) }
        let previous = ProcessInfo.processInfo.environment["AGENT_PANEL_DEMO_DIR"]
        setenv("AGENT_PANEL_DEMO_DIR", dir.path, 1)
        defer { if let previous { setenv("AGENT_PANEL_DEMO_DIR", previous, 1) } else { unsetenv("AGENT_PANEL_DEMO_DIR") } }
        let model = await DemoSupport.makeModel()
        XCTAssertNotNil(model.selectedProject)
        XCTAssertTrue(model.cards.isEmpty)
        // The tokens are one dark palette (no light theme): both schemes render the same, kept as the other snapshot tests do.
        for (scheme, name) in [(ColorScheme.light, "N308-empty-tasks-light"), (.dark, "N308-empty-tasks-dark")] {
            let view = TaskListView(model: model, startMode: .byRound).frame(width: 420, height: 360).background(Tok.pane).environment(\.colorScheme, scheme)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 420, height: 360)))
            XCTAssertGreaterThan(data.count, 6_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
        }
    }

    private func card(_ id: String, _ title: String, _ status: TaskStatus = .todo, roles: [String] = []) -> TaskCard {
        var c = TaskCard(id: id, project: "demo", status: status, agent: nil, branch: nil, kind: nil, files: [], title: title,
                         sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        c.roles = roles
        return c
    }

    private func ids(_ results: [CardLoadResult]) -> [String] {
        results.compactMap { if case .card(let c) = $0 { return c.id } else { return nil } }
    }

    private var all: [CardLoadResult] {
        [.card(card("N1", "Fix login", .doing, roles: ["dev"])), .card(card("N2", "Polish icons", .review, roles: ["ui_dev"])),
         .card(card("N3", "Old chore", .done)), .unreadable(url: URL(fileURLWithPath: "/tmp/broken.md"), reason: "bad front matter")]
    }

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(TaskListFilter.filter(all, query: "  ").count, 4)
    }

    func testMatchesID() { XCTAssertEqual(ids(TaskListFilter.filter(all, query: "n2")), ["N2"]) }
    func testMatchesTitle() { XCTAssertEqual(ids(TaskListFilter.filter(all, query: "LOGIN")), ["N1"]) }
    func testMatchesRole() { XCTAssertEqual(ids(TaskListFilter.filter(all, query: "ui_dev")), ["N2"]) }
    func testMatchesStatus() { XCTAssertEqual(ids(TaskListFilter.filter(all, query: "review")), ["N2"]) }
    func testDefaultRoleMatchesDev() { XCTAssertTrue(ids(TaskListFilter.filter(all, query: "dev")).contains("N3")) }
    func testUnreadableMatchesByFileName() {
        XCTAssertEqual(TaskListFilter.filter(all, query: "broken").count, 1)
        XCTAssertEqual(TaskListFilter.filter(all, query: "zzz").count, 0)
    }

    func testDoneAndCancelledCollapsedByDefault() {
        XCTAssertTrue(TaskListFilter.isCollapsed("Done", expanded: [], query: ""))
        XCTAssertTrue(TaskListFilter.isCollapsed("Cancelled", expanded: [], query: ""))
        XCTAssertFalse(TaskListFilter.isCollapsed("Doing", expanded: [], query: ""))
    }

    func testExpandedAndSearchingOpenDone() {
        XCTAssertFalse(TaskListFilter.isCollapsed("Done", expanded: ["Done"], query: ""))
        XCTAssertFalse(TaskListFilter.isCollapsed("Done", expanded: [], query: "old"))
    }

    func testArrowsMoveSelection() {
        let list = ["N1", "N2", "N3"]
        XCTAssertEqual(TaskListFilter.move(from: "N1", in: list, by: 1), "N2")
        XCTAssertEqual(TaskListFilter.move(from: "N2", in: list, by: -1), "N1")
        XCTAssertEqual(TaskListFilter.move(from: "N3", in: list, by: 1), "N3")
        XCTAssertEqual(TaskListFilter.move(from: "N1", in: list, by: -1), "N1")
    }

    func testArrowsWithNoSelectionPickAnEnd() {
        let list = ["N1", "N2"]
        XCTAssertEqual(TaskListFilter.move(from: nil, in: list, by: 1), "N1")
        XCTAssertEqual(TaskListFilter.move(from: "gone", in: list, by: -1), "N2")
        XCTAssertNil(TaskListFilter.move(from: nil, in: [], by: 1))
    }

    func testVisibleIDsSkipCollapsedSections() {
        let sections = TaskGrouping.sections(from: all)
        XCTAssertEqual(TaskListFilter.visibleCardIDs(sections, expanded: [], query: ""), ["N2", "N1"])
        XCTAssertEqual(TaskListFilter.visibleCardIDs(sections, expanded: ["Done"], query: ""), ["N2", "N1", "N3"])
    }
}
