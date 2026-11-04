import XCTest
import SwiftUI
@testable import AgentPanel

/// N359: the Terminal widget: in the gallery, its picker (PM and the project's agents), the choice saved per project, the shots.
@MainActor
final class DashboardTerminalTileTests: XCTestCase {
    private func agent(_ pane: String, title: String, cwd: String, name: String? = nil) -> AgentStatus {
        var a = AgentStatus(paneID: pane, workspaceID: pane, state: .working, cwd: cwd, title: title); a.name = name; return a
    }

    func testTheTerminalIsInTheGalleryAddedAt3x2AndInNoPreset() {
        XCTAssertTrue(WidgetGallery.widgets.contains(.terminal))
        XCTAssertEqual(DashboardWidget.terminal.title, "Terminal")
        XCTAssertFalse(DashboardWidget.terminal.blurb.isEmpty)
        let base = DashboardGridLayout([DashboardGridTests.t(.chat, 0, 0, 3, 4)])
        XCTAssertTrue(base.missing.contains(.terminal))
        let added = base.applying(.add(.terminal))
        XCTAssertEqual(added.rect(of: .terminal), DashboardCellRect(column: 3, row: 0, width: 3, height: 2))
        XCTAssertFalse(DashboardGridLayout.default.contains(.terminal))
        for preset in DashboardPreset.allCases { XCTAssertFalse(preset.layout.contains(.terminal), preset.rawValue) }
        XCTAssertEqual(DashboardWidget.terminal.minColumns, 2)
    }

    func testThePickerListsThePMFirstThenTheAgentsAndNoUserShells() {
        let agents = [agent("w2:p1", title: "dev", cwd: "/repo/.agent-worktrees/n2", name: "dev-n2"),
                      agent("w1:p1", title: "✳ PM", cwd: "/repo"),
                      agent("w3:p1", title: "claude", cwd: "/repo"),
                      agent(TerminalShells.prefix + "1", title: "zsh", cwd: "/repo")]
        let card = TaskCard(id: "N2", project: "d", status: .doing, agent: "dev-n2", branch: "task/n2", kind: nil, files: [], title: "Widget", sections: [:],
                            url: URL(fileURLWithPath: "/tmp/N2.md"))
        let options = DashboardTerminalPick.options(agents: agents, pmPane: "w1:p1", card: { $0.paneID == "w2:p1" ? card : nil })
        XCTAssertEqual(options.map(\.pane), ["w1:p1", "w2:p1", "w3:p1"])
        XCTAssertEqual(options.map(\.name), ["PM", "N2 · Widget", "\(options[2].label) · claude"])
        XCTAssertTrue(options[0].isPM)
    }

    func testTheShownTerminalFollowsTheSavedChoice() {
        let pm = DashboardTerminalOption(pane: "w1:p1", label: "PM", title: "pm", isPM: true)
        let dev = DashboardTerminalOption(pane: "w2:p1", label: "N2", title: "Widget", isPM: false)
        XCTAssertEqual(DashboardTerminalPick.shown(saved: nil, options: []), .empty)
        XCTAssertEqual(DashboardTerminalPick.shown(saved: nil, options: [dev, pm]), .showing(pm), "the PM by default")
        XCTAssertEqual(DashboardTerminalPick.shown(saved: nil, options: [dev]), .showing(dev), "the first agent without a PM")
        XCTAssertEqual(DashboardTerminalPick.shown(saved: dev.choice, options: [pm, dev]), .showing(dev))
        XCTAssertEqual(DashboardTerminalPick.shown(saved: dev.choice, options: [pm]), .ended("N2 · Widget"), "an ended agent is named")
        XCTAssertEqual(DashboardTerminalPick.endedText("N2 · Widget"), "N2 · Widget ended. Pick another terminal above.")
    }

    func testTheChoiceIsSavedPerProject() {
        let store = DashboardLayoutStore(defaults: TestDefaults.make(self, prefix: "dashboard-terminal"))
        XCTAssertNil(store.terminalChoice(project: "a"))
        store.setTerminalChoice(DashboardTerminalChoice(pane: "w1:p1", label: "PM"), project: "a")
        store.setTerminalChoice(DashboardTerminalChoice(pane: "w2:p1", label: "N2"), project: "b")
        XCTAssertEqual(store.terminalChoice(project: "a")?.pane, "w1:p1")
        XCTAssertEqual(store.terminalChoice(project: "b")?.pane, "w2:p1")
        XCTAssertEqual(DashboardLayoutStore(defaults: store.defaults).terminalChoice(project: "b")?.label, "N2", "read again after a restart")
        store.setTerminalChoice(nil, project: "a")
        XCTAssertNil(store.terminalChoice(project: "a"))
        XCTAssertNotNil(store.terminalChoice(project: "b"))
    }

    // MARK: shots

    private func makeModel(_ agents: (String) -> [AgentStatus]) async throws -> PanelModel {
        let dir = try TempDir()
        let settings = DemoSupport.prepareSettings()
        let repo = settings.deletingLastPathComponent().appendingPathComponent("repo").path
        let list = agents(repo)
        let iso = TestIsolation(dir, owner: self)
        let model = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(list)) }, opener: WorkspaceURLOpener(),
                               log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        await model.reload()
        await model.refreshAgents()
        return model
    }

    private static var layout: DashboardGridLayout {
        DashboardGridLayout([DashboardGridTests.t(.chat, 0, 0, 3, 4), DashboardGridTests.t(.terminal, 3, 0, 3, 2), DashboardGridTests.t(.waiting, 3, 2, 3, 2)])
    }

    /// Live-window shot → N359-terminal-tile.png: the tile attached to a temp tentacld session standing in for the PM.
    func testTheTerminalTileShot() async throws {
        let folder = "/tmp/n359-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let client = TentacldClient(socketPath: folder + "/s.sock")
        let daemon = Process()
        daemon.executableURL = client.helper
        daemon.arguments = ["--socket", client.socketPath]
        try daemon.run()
        defer { stopDaemon(daemon) }
        for _ in 0..<160 where !(await client.ping()) { try await Task.sleep(for: .milliseconds(50)) }
        let screen = #"printf '\033[1m✻ Tentacl PM\033[0m  · agent-panel\n\n> N359 started on task/n359 (ui_dev)\n  N358 merged · tests 1774/0\n\n\033[2m? for shortcuts\033[0m\n'; exec cat"#
        _ = try await client.spawn(id: "w1:p1", argv: ["/bin/sh", "-c", screen], cwd: folder, cols: 80, rows: 20)
        let model = try await makeModel { repo in [self.agent("w1:p1", title: "✳ PM", cwd: repo)] }
        XCTAssertEqual(model.selectedProjectID.flatMap { model.pmAgent(forProject: $0)?.paneID }, "w1:p1")
        let view = DashboardView(model: model, layout: Self.layout, terminalClient: client)
        try await Self.layerShot(view, "N359-terminal-tile.png")
        XCTAssertTrue(model.liveTerminals.session(id: "w1:p1", client: client).isLive, "the tile attached to the session")
        model.liveTerminals.removeAll()
    }

    /// Like `DashboardGridSnapshotTests.liveWindowShot`, but taken with `screencapture` from the window: the live terminal paints its
    /// background on its layer, which `cacheDisplay` leaves white.
    static func layerShot(_ root: some View, _ file: String) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.animationBehavior = .none
        let host = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        host.wantsLayer = true
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(2500))
        host.layoutSubtreeIfNeeded()
        // The window's real pixels (needs no permission for the test host's own window).
        let tmp = NSTemporaryDirectory() + "n359-\(UUID().uuidString).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", tmp]
        try p.run(); p.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: tmp))
        try? FileManager.default.removeItem(atPath: tmp)
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(file)) }
    }

    /// Live-window shot → N359-terminal-empty.png: no agents running.
    func testTheEmptyTerminalTileShot() async throws {
        let model = try await makeModel { _ in [] }
        try await DashboardGridSnapshotTests.liveWindowShot(DashboardView(model: model, layout: Self.layout, terminalClient: nil), dark: true, "N359-terminal-empty.png")
    }
}
