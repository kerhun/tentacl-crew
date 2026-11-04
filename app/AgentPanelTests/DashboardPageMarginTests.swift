import XCTest
import SwiftUI
@testable import AgentPanel

/// N347: the Dashboard's page edge is Team's and Plan's, the no-PM text is never cut in a small chat tile, and the chat thread lines
/// up with the composer and the PM bar. Shots (dark) → N347-team-1280.png, N347-dash.png, N347-team.png, N347-chat-wide.png, N347-chat-narrow.png.
@MainActor
final class DashboardPageMarginTests: XCTestCase {
    func testTheDashboardUsesThePageMargin() {
        XCTAssertEqual(DashboardView.padding, Tok.Space.page)
    }

    func testTheGridStillFitsWithoutScrolling() {
        for window in [CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900)] {
            let room = DashboardView.gridSize(window)
            XCTAssertEqual(room.width, window.width - 2 * Tok.Space.page)
            XCTAssertFalse(DashboardGrid<EmptyView>.isNarrow(size: room), "\(window)")
        }
    }

    func testTheChatColumnSpansTheTileUpToTheCap() {
        XCTAssertEqual(ChatThread.readingWidth, 960)
        XCTAssertEqual(CommandBar.inset, Tok.Space.l)
        XCTAssertEqual(UserRow.maxWidth(column: 800), 600, "a bubble is at most three quarters of the column")
        XCTAssertEqual(UserRow.maxWidth(column: 0), UserRow.maxWidth, "before the column is measured")
    }

    /// N350: the thread's rows sit `contentInset` inside the composer, which stays at `CommandBar.inset` from the tile edge.
    func testTheThreadContentSitsInsideTheComposer() {
        XCTAssertEqual(ChatThread.contentInset, Tok.Space.m)
        XCTAssertEqual(CommandBar.inset, Tok.Space.l, "the composer does not move")
        XCTAssertEqual(ChatThread.contentEdge, CommandBar.inset + ChatThread.contentInset)
        XCTAssertEqual(ChatThread.contentEdge, 28)
        XCTAssertEqual(UserRow.maxWidth(column: 600 - 2 * ChatThread.contentInset), 432, "bubbles take 75% of the inset column")
    }

    // MARK: shots

    private struct Listing: TerminalListing {
        let list: [AgentStatus]
        func agents() async throws -> [AgentStatus] { list }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
    }

    private func model(withPM: Bool) async -> PanelModel {
        let settings = DemoSupport.prepareSettings()
        let repo = settings.deletingLastPathComponent().appendingPathComponent("repo").path
        let pm = AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: repo, title: "PM")
        let dev = AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .working, cwd: repo + "/.agent-worktrees/task-a1", title: "dev-a1")
        let model = PanelModel(settingsURL: settings, makeTerminal: { Listing(list: withPM ? [pm, dev] : [dev]) }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                               log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-n347-shots.log")),
                               writer: DemoCardWriter(), defaults: makeTestDefaults(prefix: "agent-panel-n347-shots"), roleStore: RoleStore())
        await model.reload()
        return model
    }

    private func write(_ view: some View, _ name: String, size: CGSize) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N347-\(name).png")) }
    }

    /// The whole window (rail included) with `layout` as the stored Dashboard layout; the stored one is put back afterwards.
    private func withStoredLayout(_ layout: DashboardGridLayout, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let old = defaults.data(forKey: DashboardLayoutStore.key)
        DashboardLayoutStore().save(layout)
        defer { if let old { defaults.set(old, forKey: DashboardLayoutStore.key) } else { defaults.removeObject(forKey: DashboardLayoutStore.key) } }
        try body()
    }

    static let longAnswer = "N345 is waiting for its last screenshot: the reviewer asked for the Undo toast in light mode, and the developer is taking it now. "
        + "Once it is merged I will start N347 (the Dashboard's page margin, the no-PM text in a small chat tile and the chat's side gaps). "
        + "N349 can run beside it because it only touches the grid logic, so the two cards do not share a file."

    /// F1: a long PM answer wraps in a narrow column, on screen and in a snapshot, even when the thread is shorter than its rows.
    func testALongAnswerWrapsInANarrowColumn() {
        let entry = ChatEntry(id: "t1", kind: .agent, text: Self.longAnswer, time: nil, pending: nil, tools: [], toolSummary: "")
        let row = NSHostingView(rootView: TurnRow(entry: entry, label: "PM").frame(width: 420))
        XCTAssertGreaterThan(row.fittingSize.height, 24 + 3 * 15, "the answer takes at least four lines at 420 pt")
        // Offered less height than it needs (a short thread), a row keeps its full height: the thread clips or scrolls, the text is not cut.
        let squeezed = NSHostingController(rootView: ChatThread.unsqueezed(TurnRow(entry: entry, label: "PM")))
        XCTAssertGreaterThan(squeezed.sizeThatFits(in: CGSize(width: 420, height: 40)).height, 24 + 3 * 15)
    }

    /// The Dashboard in a real window (AppKit hosting, the on-screen ScrollView thread, not ImageRenderer), dark, with `layout` stored.
    private func liveShot(_ layout: DashboardGridLayout, size: CGSize, _ file: String) async throws {
        let pm = await model(withPM: true)
        if let id = pm.selectedProjectID {
            let chat = pm.chats.session(project: id, pane: "w2:pA").chat
            chat.addPending("Can you check why the review of N345 is still open, and start N347 when it is merged?", kind: .user)
            chat.addPending(Self.longAnswer, kind: .agent)
        }
        let defaults = UserDefaults.standard
        let old = defaults.data(forKey: DashboardLayoutStore.key)
        DashboardLayoutStore().save(layout)
        defer { if let old { defaults.set(old, forKey: DashboardLayoutStore.key) } else { defaults.removeObject(forKey: DashboardLayoutStore.key) } }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ShellView(model: pm, screen: .dashboard).environment(\.colorScheme, .dark))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(1500))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(file)) }
    }

    /// F1: Team watch at 1280×800 (chat 3×2).
    func testTheLiveNarrowChatShot() async throws {
        try await liveShot(DashboardPreset.team.layout, size: CGSize(width: 1280, height: 800), "N347-chat-narrow-live.png")
    }

    /// N350: the rows' gap to the composer's edges, chat 4×4 at 1800×1100 and chat 3×2 at 1280×800.
    func testTheN350LiveShots() async throws {
        try await liveShot(DashboardPreset.focus.layout, size: CGSize(width: 1800, height: 1100), "N350-chat-wide.png")
        try await liveShot(DashboardPreset.team.layout, size: CGSize(width: 1280, height: 800), "N350-chat-narrow.png")
    }

    func testTheShots() async throws {
        let none = await model(withPM: false)
        XCTAssertEqual(none.pmStatus, .missing)
        try withStoredLayout(DashboardPreset.team.layout) {
            try write(ShellView(model: none, screen: .dashboard), "team-1280", size: CGSize(width: 1280, height: 800))
            try write(ShellView(model: none, screen: .dashboard), "team-1440-nopm", size: CGSize(width: 1440, height: 900))
        }
        let pm = await model(withPM: true)
        XCTAssertNotEqual(pm.pmStatus, .missing)
        if let id = pm.selectedProjectID {
            let chat = pm.chats.session(project: id, pane: "w2:pA").chat
            chat.addPending("Can you check why the review of N345 is still open, and start N347 when it is merged?", kind: .user)
            chat.addPending(Self.longAnswer, kind: .agent)
        }
        try withStoredLayout(.default) {
            try write(ShellView(model: pm, screen: .dashboard), "dash", size: CGSize(width: 1440, height: 900))
            try write(ShellView(model: pm, screen: .team), "team", size: CGSize(width: 1440, height: 900))
            try write(ShellView(model: pm, screen: .dashboard), "chat-wide", size: CGSize(width: 1800, height: 1100))
        }
        try withStoredLayout(DashboardPreset.team.layout) {
            try write(ShellView(model: pm, screen: .dashboard), "chat-narrow", size: CGSize(width: 1280, height: 800))
        }
    }
}
