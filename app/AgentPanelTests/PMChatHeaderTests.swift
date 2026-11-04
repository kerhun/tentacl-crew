import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

private struct RepoPM: TerminalListing {
    let cwd: String
    func agents() async throws -> [AgentStatus] { [AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: cwd, title: "PM")] }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// N346: the PM chat's one header row, its ⋯ menu, the composer, the no-PM empty state and the Dashboard header's widget menu.
@MainActor
final class PMChatHeaderTests: XCTestCase {
    private var window: NSWindow?
    private var returnSendsBefore: Any?

    override func setUp() async throws { returnSendsBefore = UserDefaults.standard.object(forKey: CommandBar.returnSendsKey) }

    override func tearDown() async throws {
        UserDefaults.standard.set(returnSendsBefore, forKey: CommandBar.returnSendsKey)
        window?.orderOut(nil); window = nil
    }

    // MARK: the header

    func testTheHeaderIsOneRowInEveryPMState() {
        for status in [PMStatus.running, .idle, .missing] {
            for preview in [nil, true] as [Bool?] {
                let header = PMChatHeader(status: status, name: "PM", role: "pm", projectName: "agent-panel", unread: true, waiting: true,
                                          authority: "Authority · 2 of 6 today", authorityOn: true, previewShown: preview)
                let height = NSHostingView(rootView: header.frame(width: 820)).fittingSize.height
                XCTAssertLessThanOrEqual(height, 56, "\(status): one row (avatar 30 pt and its padding)")
                XCTAssertGreaterThanOrEqual(height, 30)
            }
        }
    }

    func testTheStateLineAndDot() {
        XCTAssertEqual(PMChatHeader.stateLine(.running, project: "agent-panel"), "working · agent-panel")
        XCTAssertEqual(PMChatHeader.stateLine(.idle, project: "agent-panel"), "idle · agent-panel")
        XCTAssertEqual(PMChatHeader.stateLine(.missing, project: "agent-panel"), "not running · agent-panel")
        XCTAssertEqual(PMChatHeader.color(.running), Tok.work)
        XCTAssertEqual(PMChatHeader.color(.idle), Tok.go)
        XCTAssertEqual(PMChatHeader.color(.missing), Tok.ink3)
    }

    func testTheAuthorityChipTextOnAndOff() {
        XCTAssertEqual(PMChatHeader.authorityText(dashboardAuthorityText(enabled: false, startedToday: 0, perDay: 6)), "Authority off")
        XCTAssertEqual(PMChatHeader.authorityText(dashboardAuthorityText(enabled: true, startedToday: 2, perDay: 6)), "Authority · 2 of 6 today")
        let model = PanelModel.isolatedForTests()
        XCTAssertEqual(PMChatHeader.authorityText(model.dashboardAuthority), "Authority off")
        model.openAuthorityRules()
        XCTAssertTrue(model.autopilot.rulesOpen, "the chip opens the Autopilot rules")
    }

    // MARK: ⋯

    func testACodexPMMenuHasNoCompact() {
        let titles = PMChatHeader.menuItems(canRestart: true, busy: false, returnSends: true, compact: false).map(\.title)
        XCTAssertEqual(titles, ["New conversation…", "", "Return sends", "PM authority rules…", "", "Stop PM…"])
    }

    func testTheMenuItemsAndTheirDisabledStates() {
        let titles = PMChatHeader.menuItems(canRestart: true, busy: false, returnSends: true).map(\.title)
        XCTAssertEqual(titles, ["New conversation…", "Compact conversation…", "", "Return sends", "PM authority rules…", "", "Stop PM…"])
        func enabled(_ canRestart: Bool, _ busy: Bool) -> [String: Bool] {
            Dictionary(PMChatHeader.menuItems(canRestart: canRestart, busy: busy, returnSends: false).filter { !$0.title.isEmpty }.map { ($0.title, $0.enabled) }) { a, _ in a }
        }
        XCTAssertEqual(enabled(true, false), ["New conversation…": true, "Compact conversation…": true, "Return sends": true, "PM authority rules…": true, "Stop PM…": true])
        XCTAssertEqual(enabled(true, true)["New conversation…"], false, "off while an action runs")
        XCTAssertEqual(enabled(true, true)["Compact conversation…"], false)
        XCTAssertEqual(enabled(false, false)["New conversation…"], false, "off for an agent on a card")
        XCTAssertEqual(enabled(false, false)["Stop PM…"], true)
        let busyHelp = PMChatHeader.menuItems(canRestart: true, busy: true, returnSends: false)[0].help
        XCTAssertEqual(busyHelp, PMStartBlock.busyHelp)
        let stop = PMChatHeader.menuItems(canRestart: true, busy: false, returnSends: false).last
        XCTAssertEqual(stop?.destructive, true)
        XCTAssertEqual(PMChatHeader.menuItems(canRestart: true, busy: false, returnSends: true)[3].kind, .check(true))
        XCTAssertEqual(PMChatHeader.menuItems(canRestart: true, busy: false, returnSends: false)[3].kind, .check(false))
    }

    func testTheMenuActionsRunTheirOwnAction() {
        var ran: [String] = []
        let items = PMChatHeader.menuItems(canRestart: true, busy: false, returnSends: false, onNew: { ran.append("new") }, onCompact: { ran.append("compact") },
                                           onReturnSends: { ran.append("return \($0)") }, onRules: { ran.append("rules") }, onStop: { ran.append("stop") })
        for item in items where item.kind != .divider { item.action() }
        XCTAssertEqual(ran, ["new", "compact", "return true", "rules", "stop"])
        let controls = ChatControls()
        controls.openRestart(.compact)
        XCTAssertTrue(controls.restartOpen)
        XCTAssertEqual(controls.restartMode, .compact, "Compact conversation… opens the sheet on Compact")
    }

    /// Return sends toggled from ⋯ (the same stored setting) changes what Return does in the hosted composer.
    func testReturnSendsFromTheMenuChangesTheReturnKey() async throws {
        UserDefaults.standard.set(false, forKey: CommandBar.returnSendsKey)
        let settings = DemoSupport.prepareSettings()
        let repo = settings.deletingLastPathComponent().appendingPathComponent("repo").path
        let model = PanelModel(settingsURL: settings, makeTerminal: { RepoPM(cwd: repo) }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                               log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-n346.log")),
                               writer: DemoCardWriter(), defaults: makeTestDefaults(prefix: "agent-panel-n346"), roleStore: RoleStore())
        await model.reload()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        self.window = window
        window.contentView = NSHostingView(rootView: CommandBar(model: model, maxChatHeight: 500))
        window.makeKeyAndOrderFront(nil)
        let session = { model.chats.existingSession(project: model.selectedProjectID ?? "", pane: "w2:pA") }
        var input: NSTextView?
        await until { input = Self.find(in: window.contentView); return input != nil && session() != nil }
        let field = try XCTUnwrap(input)
        XCTAssertTrue(window.makeFirstResponder(field))
        defer { _ = session()?.chat.takeBack(editing: false); session()?.clearDraft() }

        field.insertText("one", replacementRange: field.selectedRange())
        try pressReturn(window)
        XCTAssertNil(session()?.chat.held, "Return sends is off: Return starts a new line")

        let toggle = try XCTUnwrap(PMChatHeader.menuItems(canRestart: true, busy: false, returnSends: false,
                                                          onReturnSends: { UserDefaults.standard.set($0, forKey: CommandBar.returnSendsKey) }).first { $0.title == "Return sends" })
        toggle.action()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: CommandBar.returnSendsKey))
        try await Task.sleep(for: .milliseconds(200))
        try pressReturn(window)
        XCTAssertNotNil(session()?.chat.held, "Return sends is on: Return sends")
        XCTAssertEqual(CommandBar.sendHint(returnSends: true), "↵ send · ⇧↵ new line")
        XCTAssertEqual(CommandBar.sendHint(returnSends: false), "⌘↵ send")
    }

    // MARK: no PM

    func testTheNoPMStateOffersStartResumeAndChooseByTodaysRules() {
        XCTAssertEqual(PMNoPMState.actions(resumeShown: false, candidates: 0), [.start])
        XCTAssertEqual(PMNoPMState.actions(resumeShown: true, candidates: 0), [.start, .resume])
        XCTAssertEqual(PMNoPMState.actions(resumeShown: true, candidates: 2), [.start, .resume, .choose])
        XCTAssertEqual(PMNoPMState.actions(resumeShown: false, candidates: 1), [.start, .choose])
        XCTAssertEqual(CommandBar.placeholder(pmOnly: true, noPM: true), "Start a PM to send messages")
        XCTAssertEqual(CommandBar.placeholder(pmOnly: true), "Message the PM…")
    }

    // MARK: the Dashboard header

    func testTheWidgetMenuAndDoneWhileRearranging() {
        let items = DashboardPopMenu.widgetItems()
        XCTAssertEqual(items.map(\.title), ["Add widget…", "Rearrange", "Lock tile sizes"])
        XCTAssertEqual(DashboardPopMenu.widgetItems(layout: [PopMenuItem(id: "p", title: "Balanced", kind: .check(true))]).map(\.kind),
                       [.action, .action, .check(true), .divider, .section, .check(true)], "N345's presets go after a divider and a Layout section")
        var ran: [String] = []
        for item in DashboardPopMenu.widgetItems(onAdd: { ran.append("add") }, onRearrange: { ran.append("rearrange") }, onLock: { ran.append("lock") }) { item.action() }
        XCTAssertEqual(ran, ["add", "rearrange", "lock"])
        XCTAssertEqual(DashboardPopMenu.headerButtons(rearranging: false), [.widgets])
        XCTAssertEqual(DashboardPopMenu.headerButtons(rearranging: true), [.reset, .done], "Done replaces the widget button")
    }

    func testTheStripHasNoAuthorityOrCost() {
        XCTAssertEqual(DashboardStripItem.items(planEnabled: true), [.planRound])
        XCTAssertEqual(DashboardStripItem.items(planEnabled: false), [.planRound, .planReason])
    }

    func testTheTourPointsAtTheNewHeader() {
        let steps = TutorialTours.tour(.chat).steps
        XCTAssertEqual(steps.first?.anchor, .pmState)
        let new = steps.first { $0.anchor == .chatNewConversation }
        XCTAssertEqual(new?.text, "New conversation is in ⋯.")
    }

    // MARK: shots (dark 1440×900 Dashboard; one light)

    func testTheShots() async throws {
        let size = CGSize(width: 1440, height: 900)
        let model = try await pmModel(working: true)
        XCTAssertEqual(model.pmStatus, .running, "a PM works in the demo repository")
        if let id = model.selectedProjectID {
            let chat = model.chats.session(project: id, pane: "w2:pA").chat
            chat.addPending("Let us resize the Dashboard tiles from their edges.", kind: .user)
        }
        try write(DashboardView(model: model, layout: .default), "running", size: size)
        try write(DashboardView(model: model, layout: .default, popMenu: .chat), "menu", size: size)
        try write(DashboardView(model: model, layout: .default, popMenu: .widgets), "widgets", size: size)
        let theme = AppTheme.current
        AppTheme.current = .light
        defer { AppTheme.current = theme }
        try write(DashboardView(model: model, layout: .default).environment(\.colorScheme, .light), "light", size: size)
        AppTheme.current = theme

        let none = try await pmModel(working: false, withPM: false)
        XCTAssertEqual(none.pmStatus, .missing)
        try write(DashboardView(model: none, layout: .default), "nopm", size: size)
    }

    // MARK: helpers

    private struct Listing: TerminalListing {
        let list: [AgentStatus]
        func agents() async throws -> [AgentStatus] { list }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
    }

    /// The demo project with a PM in its repository (working or idle) and one task agent.
    private func pmModel(working: Bool, withPM: Bool = true) async throws -> PanelModel {
        let settings = DemoSupport.prepareSettings()
        let repo = settings.deletingLastPathComponent().appendingPathComponent("repo").path
        let pm = AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: working ? .working : .idle, cwd: repo, title: "PM")
        let dev = AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .working, cwd: repo + "/.agent-worktrees/task-a1", title: "dev-a1")
        let model = PanelModel(settingsURL: settings, makeTerminal: { Listing(list: withPM ? [pm, dev] : [dev]) }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                               log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-n346-shots.log")),
                               writer: DemoCardWriter(), defaults: makeTestDefaults(prefix: "agent-panel-n346-shots"), roleStore: RoleStore())
        await model.reload()
        return model
    }

    private func write(_ view: some View, _ name: String, size: CGSize) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N346-\(name).png")) }
    }

    private static func find(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.accessibilityIdentifier() == CommandBar.inputIdentifier { return text }
        for sub in view.subviews { if let hit = find(in: sub) { return hit } }
        return nil
    }

    private func until(_ done: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func pressReturn(_ window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(event)
    }
}
