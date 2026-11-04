import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

private final class PMAgent: TerminalListing, @unchecked Sendable {
    let cwd: String
    init(cwd: String) { self.cwd = cwd }
    func agents() async throws -> [AgentStatus] {
        [AgentStatus(paneID: "pm-agent-panel", workspaceID: "pm-agent-panel", state: .idle, cwd: cwd, title: "pm-agent-panel", sessionID: "s1", name: "pm-agent-panel")]
    }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// N293: the chat's PM header, the input that stays open while an action runs, Stop on the working line (dark snapshots).
@MainActor
final class ChatInterruptTests: XCTestCase {
    private var model: PanelModel!
    private var terminal: PMAgent!
    private var sender: AgentInboxTests.FakeSender!
    private var window: NSWindow!

    override func setUp() async throws {
        let settings = DemoSupport.prepareSettings()
        let work = settings.deletingLastPathComponent()
        let roles = work.appendingPathComponent("n293-roles")
        try FileManager.default.createDirectory(at: roles, withIntermediateDirectories: true)
        try #"{"name":"pm","kind":"interactive","model":"opus","effort":"high","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"pm.md","displayName":"Ibrahim"}"#
            .write(to: roles.appendingPathComponent("pm.json"), atomically: true, encoding: .utf8)
        try "PM\n".write(to: roles.appendingPathComponent("pm.md"), atomically: true, encoding: .utf8)
        let terminal = PMAgent(cwd: work.appendingPathComponent("repo").path)
        let sender = AgentInboxTests.FakeSender()
        self.terminal = terminal; self.sender = sender
        model = PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: WorkspaceURLOpener(),
                           makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                           log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-n293-tests.log")),
                           writer: DemoCardWriter(), defaults: makeTestDefaults(prefix: "agent-panel-n293-tests"), roleStore: RoleStore(baseDir: roles), makeKeySender: { sender })
        await model.reload()
    }

    override func tearDown() async throws {
        model.setActionState(.idle)
        model.chats.existingSession(project: model.selectedProjectID ?? "", pane: "pm-agent-panel")?.clearDraft()
        window?.contentView = nil
        window?.orderOut(nil); window = nil
        try? await Task.sleep(for: .milliseconds(50))
    }

    private var project: String { model.selectedProjectID ?? "" }

    func testHeaderIsThePMsLabel() {
        XCTAssertTrue(CommandBar.headerLabel(agent: "pm-agent-panel", displayNames: ["pm": "Ibrahim"]) == ("Ibrahim", "pm"))
        XCTAssertTrue(CommandBar.headerLabel(agent: "pm-agent-panel", displayNames: [:]) == ("pm", nil))
        XCTAssertTrue(CommandBar.headerLabel(agent: "", displayNames: ["pm": "Ibrahim"]) == ("pm", nil), "a PM started by hand: the role, never its terminal name")
        XCTAssertTrue(CommandBar.headerLabel(agent: nil, displayNames: ["pm": "Ibrahim"]) == ("PM not running", nil))
    }

    func testStopSendsEscToThePMsPane() async throws {
        XCTAssertEqual(model.pmPane(forProject: project), "pm-agent-panel")
        let sent = await model.interruptPM()
        XCTAssertTrue(sent)
        XCTAssertEqual(sender.keys.map(\.target), ["pm-agent-panel"])
        XCTAssertEqual(sender.keys.map(\.keys), [["esc"]])
    }

    func testAFailedStopShowsWhy() async throws {
        sender.failure = BackendError.failed("no such pane")
        let sent = await model.interruptPM()
        XCTAssertFalse(sent)
        guard case .failed(let why) = model.actionState else { return XCTFail("the action line says it failed") }
        XCTAssertTrue(why.hasPrefix("The PM could not be interrupted"))
    }

    func testWaitingLineNamesTheRunningAction() {
        XCTAssertEqual(CommandBar.waitingText("Starting N294…"), "Waiting: Starting N294…")
        XCTAssertFalse(canSend(text: "Ship it", target: "pm-agent-panel", busy: true), "Send waits while an action runs")
        XCTAssertTrue(canSend(text: "Ship it", target: "pm-agent-panel", busy: false))
    }

    // MARK: snapshots

    private func show(width: CGFloat = DashboardLayout.minCentre) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        window.contentView = NSHostingView(rootView: CommandBar(model: model, fillsHeight: true, pmOnly: true).frame(height: 560).environment(\.colorScheme, .dark))
    }

    private func write(_ name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    /// New conversation… on its own row, the header "Ibrahim  pm" with search, Conversation only, at the Dashboard's narrow width.
    func testHeaderSnapshot() async throws {
        model.chats.session(project: project, pane: "pm-agent-panel").chat.addPending("N292 is merged.\nN293 can start once you approve.", kind: .agent, id: "turn1")
        show()
        try? await Task.sleep(for: .milliseconds(500))
        try write("N293-header.png")
    }

    /// An action runs: the draft stays in the input, Send waits, the line under it says why.
    func testBusySnapshot() async throws {
        model.chats.session(project: project, pane: "pm-agent-panel").chat.addPending("Starting N294 now.", kind: .agent, id: "turn1")
        model.chats.session(project: project, pane: "pm-agent-panel").text = "After that, ship N293 to stable."
        model.setActionState(.running("Starting N294…"))
        show()
        try? await Task.sleep(for: .milliseconds(500))
        try write("N293-busy.png")
    }

    /// The working line with its elapsed time and Stop at its end.
    func testWorkingSnapshot() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let asked = day.addingTimeInterval(14 * 3600 + 55 * 60)
        let entries = [
            ChatEntry(id: "u1", kind: .user, text: "Is N293's review done?", time: asked, pending: nil, tools: [], toolSummary: ""),
            ChatEntry(id: "t1", kind: .tools, text: "ran 1 command", time: asked.addingTimeInterval(4), pending: nil, tools: ["Bash · git log main..task/n293 --oneline"], toolSummary: "ran 1 command"),
        ]
        let view = ChatThread(place: ChatPlace(), entries: entries, agentLabel: "Ibrahim", agentRole: "pm", working: true, onStop: {}, now: asked.addingTimeInterval(42))
            .environment(\.snapshotMode, true)
            .padding(16).frame(width: 420, height: 240).background(Tok.pane).environment(\.colorScheme, .dark)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 420, height: 240)))
        XCTAssertGreaterThan(data.count, 5_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N293-working.png")) }
    }
}
