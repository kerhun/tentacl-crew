import SwiftUI
import XCTest
@testable import AgentPanel

struct FakeTerminal: TerminalListing {
    var agentsResult: Result<[AgentStatus], BackendError> = .success([])
    func agents() async throws -> [AgentStatus] { try agentsResult.get() }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

@MainActor
final class PanelModelTests: XCTestCase {
    private func project(_ id: String, dataDir: URL) -> String {
        """
        {"id":"\(id)","name":"Project \(id)","repoPath":"/tmp/\(id)","dataDir":"\(dataDir.path)","maxParallel":4,
         "buildCommand":"build","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"}
        """
    }

    private func card(_ id: String, _ status: String) -> String { "---\nid: \(id)\nstatus: \(status)\n---\n# \(id)\n" }

    /// Two projects, "one" with cards in several states, "two" with a single card.
    private func makeSettings(_ dir: TempDir) throws -> URL {
        try dir.write("one/data/tasks/A1.md", card("A1", "done"))
        try dir.write("one/data/tasks/A2.md", card("A2", "review"))
        try dir.write("one/data/tasks/A3.md", card("A3", "todo"))
        try dir.write("one/data/tasks/A4.md", card("A4", "doing"))
        try dir.write("one/data/tasks/A5.md", card("A5", "awaiting-start-approval"))
        try dir.write("one/data/tasks/A6.md", card("A6", "needs-fix"))
        try dir.write("two/data/tasks/Z1.md", card("Z1", "blocked"))
        let p1 = try dir.write("one/project.json", project("one", dataDir: dir.url.appendingPathComponent("one/data")))
        let p2 = try dir.write("two/project.json", project("two", dataDir: dir.url.appendingPathComponent("two/data")))
        return try dir.write("settings.json", "{\"projects\":[\"\(p1.path)\",\"\(p2.path)\"]}")
    }

    private func model(_ settings: URL, terminal: FakeTerminal = FakeTerminal()) -> PanelModel {
        let iso = TestIsolation(folder: settings.deletingLastPathComponent(), owner: self)
        return PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
    }

    func testReloadSelectsFirstProjectAndLoadsCards() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir))
        await m.reload()
        XCTAssertEqual(m.projects.map(\.id), ["one", "two"])
        XCTAssertEqual(m.selectedProjectID, "one")
        XCTAssertEqual(m.cards.count, 6)
    }

    func testCardsGroupedByStatusInOrder() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir))
        await m.reload()
        let order = m.cardsByStatus.map { $0.0 }
        XCTAssertEqual(order, [.review, .needsFix, .doing, .awaitingStartApproval, .todo, .done])
        XCTAssertEqual(m.cardsByStatus.first?.1.map(\.id), ["A2"])
    }

    func testPendingApprovalCountsReviewAndAwaitingStart() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir))
        await m.reload()
        XCTAssertEqual(m.pendingApprovalCount, 2)   // A2 (review) and A5 (awaiting-start-approval)
    }

    func testTerminalNotRunningGivesUnavailableAndKeepsCards() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir), terminal: FakeTerminal(agentsResult: .failure(.notRunning("no terminal server"))))
        await m.reload()
        guard case .unavailable(let message) = m.agents else { return XCTFail("expected unavailable, got \(m.agents)") }
        XCTAssertTrue(message.contains("no terminal server"))
        XCTAssertEqual(m.cards.count, 6)
    }

    func testTerminalNotInstalledGivesUnavailable() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir), terminal: FakeTerminal(agentsResult: .failure(.notInstalled)))
        await m.reload()
        guard case .unavailable(let message) = m.agents else { return XCTFail("expected unavailable") }
        XCTAssertTrue(message.lowercased().contains("not installed"))
    }

    func testAvailableAgentsAreExposed() async throws {
        let dir = try TempDir()
        let agent = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .working, cwd: "/x", title: "t")
        let m = model(try makeSettings(dir), terminal: FakeTerminal(agentsResult: .success([agent])))
        await m.reload()
        XCTAssertEqual(m.agents, .available([agent]))
    }

    func testSwitchingProjectReloadsCards() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir))
        await m.reload()
        await m.selectProject("two")
        XCTAssertEqual(m.selectedProjectID, "two")
        XCTAssertEqual(m.cards.count, 1)
        XCTAssertEqual(m.pendingApprovalCount, 0)
    }

    func testNoProjectsGivesEmptyStateWithProblems() async throws {
        let dir = try TempDir()
        let m = model(dir.url.appendingPathComponent("missing-settings.json"))
        await m.reload()
        XCTAssertEqual(m.projects, [])
        XCTAssertNil(m.selectedProjectID)
        XCTAssertEqual(m.cards, [])
        XCTAssertFalse(m.problems.isEmpty)
    }

    /// Lets a test hold a card load until it decides to release it.
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    func testStaleLoadDoesNotOverwriteNewerProject() async throws {
        let dir = try TempDir()
        let settings = try makeSettings(dir)
        let gate = Gate()
        let stale = CardLoadResult.card(TaskCard(id: "STALE", project: "one", status: .todo, agent: nil, branch: nil, kind: nil,
                                                 files: [], title: "stale", sections: [:], url: URL(fileURLWithPath: "/tmp/stale.md")))
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(),
                           loadCards: { url in
                               if url.path.hasSuffix("one/data") { await gate.wait(); return [stale] }
                               return CardRepository(dataDir: url).loadAll()
                           }, log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        let slow = Task { await m.reload() }
        for _ in 0..<200 where m.projects.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await m.selectProject("two")
        await gate.release()
        await slow.value
        XCTAssertEqual(m.selectedProjectID, "two")
        XCTAssertEqual(m.cards.compactMap { if case .card(let c) = $0 { return c.id } else { return nil } }, ["Z1"],
                       "project one's late answer must not replace project two's cards")
    }

    /// terminal can hang; the task list must keep refreshing anyway.
    func testCardsKeepRefreshingWhileTerminalHangs() async throws {
        struct HangingTerminal: TerminalListing {
            func agents() async throws -> [AgentStatus] { try await Task.sleep(for: .seconds(3600)); return [] }
            func workspaces() async throws -> [WorkspaceInfo] { [] }
        }
        let dir = try TempDir()
        let settings = try makeSettings(dir)
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: settings, makeTerminal: { HangingTerminal() }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        m.reloadProjects()
        await m.reloadCards()
        XCTAssertEqual(m.cards.count, 6)
        m.startPolling(interval: .milliseconds(30))
        try dir.write("one/data/tasks/A7.md", card("A7", "todo"))
        var seen = false
        for _ in 0..<100 { if m.cards.count == 7 { seen = true; break }; try await Task.sleep(for: .milliseconds(30)) }
        m.stopPolling()
        XCTAssertTrue(seen, "cards stopped refreshing while terminal was hanging")
    }

    func testReloadKeepsSelectionWhenProjectStillExists() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir))
        await m.reload()
        await m.selectProject("two")
        await m.reload()
        XCTAssertEqual(m.selectedProjectID, "two")
    }

    // MARK: the last project and the order (N132)

    func testTheSelectedProjectOpensAgainInANewModelWithTheSameDefaults() async throws {
        let dir = try TempDir()
        let settings = try makeSettings(dir)
        let iso = TestIsolation(dir, owner: self)
        let first = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        await first.reload()
        await first.selectProject("two")
        let next = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        await next.reload()
        XCTAssertEqual(next.selectedProjectID, "two")
        XCTAssertEqual(next.cards.count, 1)
    }

    func testASavedProjectThatIsGoneFallsBackToTheFirst() async throws {
        let dir = try TempDir()
        let settings = try makeSettings(dir)
        let iso = TestIsolation(dir, owner: self)
        iso.defaults.set("removed", forKey: PanelModel.selectedProjectKey)
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        await m.reload()
        XCTAssertEqual(m.selectedProjectID, "one")
        XCTAssertEqual(m.actionState, .idle)
    }

    func testMovingAProjectWritesTheOrderAndKeepsTheSelection() async throws {
        let dir = try TempDir()
        let settings = try makeSettings(dir)
        let m = model(settings)
        await m.reload()
        m.moveProject("two", to: 0)
        XCTAssertEqual(m.projects.map(\.id), ["two", "one"])
        XCTAssertEqual(m.selectedProjectID, "one")
        XCTAssertEqual(ProjectStore.load(settingsURL: settings).projects.map(\.id), ["two", "one"])
    }

    func testTheContextMenuMovesUpAndDownAndStopsAtTheEnds() async throws {
        let dir = try TempDir()
        let settings = try makeSettings(dir)
        let m = model(settings)
        await m.reload()
        let list = ProjectOrderList(model: m)
        XCTAssertEqual(list.menu(for: "one").map(\.title), ["Move up", "Move down"])
        XCTAssertEqual(list.menu(for: "one").map(\.enabled), [false, true])
        list.menu(for: "one")[1].action()
        XCTAssertEqual(m.projects.map(\.id), ["two", "one"])
        XCTAssertEqual(list.menu(for: "one").map(\.enabled), [true, false])
        list.menu(for: "one")[0].action()
        XCTAssertEqual(ProjectStore.load(settingsURL: settings).projects.map(\.id), ["one", "two"])
    }

    func testADropPutsTheDraggedProjectInTheTargetsPlace() async throws {
        let dir = try TempDir()
        let settings = try makeSettings(dir)
        let m = model(settings)
        await m.reload()
        XCTAssertTrue(ProjectOrderList(model: m).drop(["one"], on: "two"))
        XCTAssertEqual(m.projects.map(\.id), ["two", "one"])
        XCTAssertFalse(ProjectOrderList(model: m).drop(["nope"], on: "two"))
    }

    func testSnapshotOfTheProjectOrderDuringADrag() async throws {
        let dir = try TempDir()
        let m = model(try makeSettings(dir))
        await m.reload()
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = ProjectOrderList(model: m, target: "one").frame(maxHeight: .infinity, alignment: .top).background(Tok.pane).environment(\.colorScheme, scheme)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 280, height: 132)))
            XCTAssertGreaterThan(data.count, 5_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("project-order-\(name).png")) }
        }
    }
}
