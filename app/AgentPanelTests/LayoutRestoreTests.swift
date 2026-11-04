import SwiftUI
import XCTest
@testable import AgentPanel

/// Relaunch opens where the user left it (N260): the screen, each project's open card and tab, the Terminals panes; what is gone
/// falls back quietly.
@MainActor
final class LayoutRestoreTests: XCTestCase {
    private func project(_ id: String, dataDir: URL) -> String {
        """
        {"id":"\(id)","name":"Project \(id)","repoPath":"/tmp/\(id)","dataDir":"\(dataDir.path)","maxParallel":4,
         "buildCommand":"build","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"}
        """
    }

    private func card(_ id: String, _ status: String, report: String = "") -> String {
        "---\nid: \(id)\nstatus: \(status)\n---\n# \(id)\n\n## Report\n\(report)\n"
    }

    private func makeSettings(_ dir: TempDir) throws -> URL {
        try dir.write("one/data/tasks/A1.md", card("A1", "todo"))
        try dir.write("one/data/tasks/A2.md", card("A2", "review", report: "Done, shots attached."))
        try dir.write("two/data/tasks/Z1.md", card("Z1", "todo"))
        let p1 = try dir.write("one/project.json", project("one", dataDir: dir.url.appendingPathComponent("one/data")))
        let p2 = try dir.write("two/project.json", project("two", dataDir: dir.url.appendingPathComponent("two/data")))
        return try dir.write("settings.json", "{\"projects\":[\"\(p1.path)\",\"\(p2.path)\"]}")
    }

    /// A model as one launch of the app builds it; `iso` is shared between launches like the user's defaults.
    private func launch(_ settings: URL, _ iso: TestIsolation) async -> PanelModel {
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        await m.reload()
        return m
    }

    // MARK: the open card and its tab

    func testTheOpenCardAndItsTabComeBackAfterARelaunch() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let first = await launch(settings, iso)
        first.selectedCardID = "A2"
        first.saveOpenTab(.report, card: "A2")
        let next = await launch(settings, iso)
        XCTAssertEqual(next.selectedProjectID, "one")
        XCTAssertEqual(next.selectedCardID, "A2")
        let a2 = try XCTUnwrap(next.card(id: "A2"))
        XCTAssertEqual(next.savedTab(for: a2, shots: 0), .report)
    }

    func testEveryProjectKeepsItsOwnOpenCard() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let m = await launch(settings, iso)
        m.selectedCardID = "A1"
        await m.selectProject("two")
        XCTAssertNil(m.selectedCardID, "the other project opens on its own record, which is empty")
        m.selectedCardID = "Z1"
        await m.selectProject("one")
        XCTAssertEqual(m.selectedCardID, "A1")
        let next = await launch(settings, iso)
        XCTAssertEqual(next.selectedProjectID, "one")
        XCTAssertEqual(next.selectedCardID, "A1")
        await next.selectProject("two")
        XCTAssertEqual(next.selectedCardID, "Z1")
    }

    func testAClosedCardIsNotOpenedAgain() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let first = await launch(settings, iso)
        first.selectedCardID = "A1"
        first.selectedCardID = nil
        let next = await launch(settings, iso)
        XCTAssertNil(next.selectedCardID)
    }

    func testACardThatIsGoneFallsBackQuietly() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let first = await launch(settings, iso)
        first.selectedCardID = "A1"
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("one/data/tasks/A1.md"))
        let next = await launch(settings, iso)
        XCTAssertEqual(next.selectedProjectID, "one")
        XCTAssertNil(next.selectedCardID)
        XCTAssertEqual(next.actionState, .idle, "no error for a card that is gone")
    }

    func testAProjectThatIsGoneFallsBackToTheFirstWithItsOwnCard() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let first = await launch(settings, iso)
        first.selectedCardID = "A2"
        await first.selectProject("two")
        first.selectedCardID = "Z1"
        // Project "two" is taken off the list.
        let p1 = dir.url.appendingPathComponent("one/project.json").path
        try "{\"projects\":[\"\(p1)\"]}".write(to: settings, atomically: true, encoding: .utf8)
        let next = await launch(settings, iso)
        XCTAssertEqual(next.selectedProjectID, "one")
        XCTAssertEqual(next.selectedCardID, "A2")
        XCTAssertTrue(next.problems.isEmpty)
    }

    func testACardOpenedBeforeTheCardsLoadWinsAndIsSaved() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let first = await launch(settings, iso)
        first.selectedCardID = "A1"
        // A notification click opens A2 while the relaunched model has not read the cards yet.
        let next = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        next.reloadProjects()
        next.selectedCardID = "A2"
        await next.reloadCards()
        XCTAssertEqual(next.selectedCardID, "A2")
        let third = await launch(settings, iso)
        XCTAssertEqual(third.selectedCardID, "A2")
    }

    func testTheTabBelongsToItsCard() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let m = await launch(settings, iso)
        m.selectedCardID = "A2"
        m.saveOpenTab(.report, card: "A2")
        m.selectedCardID = "A1"
        m.selectedCardID = "A2"
        XCTAssertNil(m.savedTab(for: try XCTUnwrap(m.card(id: "A2")), shots: 0), "another card was opened in between")
        m.saveOpenTab(.report, card: "A1")   // a detail that is no longer open saves nothing
        XCTAssertNil(m.savedTab(for: try XCTUnwrap(m.card(id: "A1")), shots: 0))
    }

    func testATabTheCardCannotShowNowFallsBack() throws {
        let card = TaskCard(id: "A1", project: "one", status: .todo, agent: nil, branch: nil, kind: nil, files: [], title: "A1", sections: [:],
                            url: URL(fileURLWithPath: "/tmp/A1.md"))
        func tab(_ raw: String) -> TaskDetailView.Tab? {
            LayoutRestore.tab(.init(card: "A1", tab: raw), card: card, shots: 0)
        }
        XCTAssertEqual(tab("Card"), .card)
        XCTAssertNil(tab("Agent screen"), "the tab is gone; an old saved one falls back")
        XCTAssertNil(tab("Report"), "the card has no report")
        XCTAssertNil(tab("Screenshots"))
        XCTAssertNil(tab("Gone tab"))
        XCTAssertNil(LayoutRestore.tab(.init(card: "A9", tab: "Card"), card: card, shots: 0))
    }

    func testAnUnreadableRecordIsIgnored() throws {
        let iso = TestIsolation(folder: try TempDir().url, owner: self)
        iso.defaults.set(Data("not json".utf8), forKey: LayoutRestore.projectKey("one"))
        XCTAssertNil(LayoutRestore.record(iso.defaults, project: "one"))
        LayoutRestore.save(iso.defaults, project: "one", .init(card: "A1", tab: "Card"))
        XCTAssertEqual(LayoutRestore.record(iso.defaults, project: "one"), .init(card: "A1", tab: "Card"))
    }

    // MARK: the screen

    func testTheScreenRoundTripsAndAnUnknownOneOpensTheDashboard() throws {
        let iso = TestIsolation(folder: try TempDir().url, owner: self)
        XCTAssertEqual(LayoutRestore.screen(iso.defaults), .dashboard, "a new install")
        for screen in ShellScreen.railOrder {
            LayoutRestore.saveScreen(iso.defaults, screen)
            XCTAssertEqual(LayoutRestore.screen(iso.defaults), screen)
        }
        iso.defaults.set("removed-screen", forKey: LayoutRestore.screenKey)
        XCTAssertEqual(LayoutRestore.screen(iso.defaults), .dashboard)
    }

    func testTheWindowOpensOnTheSavedScreenAndSavesEveryChange() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let m = await launch(settings, iso)
        LayoutRestore.saveScreen(iso.defaults, .terminals)
        var told: [ShellScreen] = []
        let view = ShellView(model: m, onScreen: { told.append($0) })
        let host = NSHostingView(rootView: view.environment(\.snapshotMode, true))
        host.frame = CGRect(x: 0, y: 0, width: 1440, height: 860)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(LayoutRestore.screen(iso.defaults), .terminals, "opening does not overwrite the saved screen")
        XCTAssertTrue(told.isEmpty)
    }

    // MARK: snapshots of a relaunched window

    private func render(_ model: PanelModel, name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: ShellView(model: model), size: CGSize(width: 1440, height: 860)))
        XCTAssertGreaterThan(data.count, 40_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    /// The first run leaves the Tasks screen with A2 open on its Report tab; the relaunched window opens there.
    func testSnapshotRelaunchedOnTheTasksScreenWithTheCardAndTab() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let first = await launch(settings, iso)
        LayoutRestore.saveScreen(iso.defaults, .tasks)
        first.selectedCardID = "A2"
        first.saveOpenTab(.report, card: "A2")
        let next = await launch(settings, iso)
        try render(next, name: "N260-restored")
    }

    /// The card open at quit was deleted: the Tasks screen opens with no card and no error.
    func testSnapshotRelaunchedWithTheOpenCardGone() async throws {
        let dir = try TempDir(), settings = try makeSettings(dir), iso = TestIsolation(dir, owner: self)
        let first = await launch(settings, iso)
        LayoutRestore.saveScreen(iso.defaults, .tasks)
        first.selectedCardID = "A2"
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("one/data/tasks/A2.md"))
        let next = await launch(settings, iso)
        try render(next, name: "N260-card-gone")
    }

    // MARK: Terminals panes (N245) after a relaunch

    func testSavedPanesReattachToTheTerminalsThatAreStillThere() throws {
        let iso = TestIsolation(folder: try TempDir().url, owner: self)
        var layout = TerminalPaneLayout(terminal: "pm")
        XCTAssertTrue(layout.split(1, .right, with: "dev-a1"))
        TerminalPaneStore.save(iso.defaults, project: "one", layout)
        let saved = try XCTUnwrap(TerminalPaneStore.load(iso.defaults, project: "one"))
        XCTAssertEqual(saved.terminals, ["pm", "dev-a1"])
        XCTAssertEqual(saved.reconciled(with: ["pm", "dev-a1"])?.terminals, ["pm", "dev-a1"], "both sessions live: the same panes")
        XCTAssertEqual(saved.reconciled(with: ["pm"])?.terminals, ["pm"], "a session that is gone leaves no blank pane")
        XCTAssertEqual(saved.reconciled(with: ["pm", "my-shell-1"])?.terminals, ["pm", "my-shell-1"], "its pane takes a free terminal")
        XCTAssertNil(saved.reconciled(with: []), "no terminal: the screen's No terminals state")
        XCTAssertNil(TerminalPaneStore.load(iso.defaults, project: "two"), "every project has its own panes")
    }
}
