import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

private struct RepoAgent: TerminalListing {
    let cwd: String
    func agents() async throws -> [AgentStatus] { [AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: cwd, title: "PM")] }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// The Command box hosted in a real window, switched out (another screen) and back the way the rail does it.
@MainActor
final class ChatThreadScrollTests: XCTestCase {
    private var model: PanelModel!
    private var window: NSWindow!

    override func setUp() async throws {
        let settings = DemoSupport.prepareSettings()
        let repo = settings.deletingLastPathComponent().appendingPathComponent("repo").path
        model = PanelModel(settingsURL: settings, makeTerminal: { RepoAgent(cwd: repo) }, opener: WorkspaceURLOpener(),
                           makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                           log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-scroll-tests.log")),
                           writer: DemoCardWriter(), defaults: makeTestDefaults(prefix: "agent-panel-scroll-tests"), roleStore: RoleStore())
        await model.reload()
    }

    override func tearDown() async throws {
        if let session = sessionIfMade { _ = session.chat.takeBack(editing: false); session.clearDraft() }
        // The Command box leaves the window first (its tasks, monitor and scroll observers stop), then the window goes.
        window?.contentView = nil
        window?.orderOut(nil); window = nil
        try? await Task.sleep(for: .milliseconds(50))
    }

    private var sessionIfMade: ChatSession? { model.chats.existingSession(project: model.selectedProjectID ?? "", pane: "w2:pA") }
    private var session: ChatSession { model.chats.session(project: model.selectedProjectID ?? "", pane: "w2:pA") }

    // MARK: hosting

    /// `fillsHeight`: the Dashboard's chat, whose thread gives up height as the input grows.
    private func showChat(fillsHeight: Bool = false) async throws {
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.makeKeyAndOrderFront(nil)
        }
        window.contentView = NSHostingView(rootView: CommandBar(model: model, maxChatHeight: 700, fillsHeight: fillsHeight)
            .frame(height: fillsHeight ? 520 : nil))
        await until { self.metrics.map { $0.content > $0.visible * 2 } ?? false }
        let m = try XCTUnwrap(metrics, "the thread is a scroll view taller than its view")
        XCTAssertGreaterThan(m.content, m.visible * 2)
    }

    /// Another screen in the same window: the Command box goes away and its views with it.
    private func showOtherScreen() async {
        window.contentView = NSHostingView(rootView: Text("Tasks"))
        await until { self.threadScroll == nil }
    }

    private func addMessages(_ n: Int, from start: Int = 0) {
        for i in start..<(start + n) { session.chat.addPending("Message \(i)\nwith a second line", kind: i.isMultiple(of: 2) ? .user : .panel, id: "m\(i)") }
    }

    /// The thread's scroll view (the input's is an NSTextView's).
    private var threadScroll: NSScrollView? { find(in: window?.contentView) }

    private func find(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView) { return scroll }
        for sub in view.subviews { if let hit = find(in: sub) { return hit } }
        return nil
    }

    /// The view's top measured from the thread's top, and how far its bottom is above the thread's end.
    private var metrics: (top: Double, fromBottom: Double, visible: Double, content: Double)? {
        guard let scroll = threadScroll, let doc = scroll.documentView else { return nil }
        let clip = scroll.contentView.bounds
        let content = doc.frame.height
        let top = doc.isFlipped ? clip.minY : content - clip.maxY
        return (top, content - clip.height - top, clip.height, content)
    }

    /// Scrolls the thread the way the user does, to a view top `top` points below the thread's top.
    private func userScroll(top: Double) {
        guard let scroll = threadScroll, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = doc.isFlipped ? top : doc.frame.height - clip.bounds.height - top
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    private func until(_ done: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Lets layout and any late scroll settle, then checks `done` once more.
    private func settled(_ done: () -> Bool) async -> Bool {
        await until(done)
        try? await Task.sleep(for: .milliseconds(400))
        return done()
    }

    private var atBottom: Bool { metrics.map { $0.fromBottom < 4 } ?? false }

    // MARK: keeping the place

    func testComingBackAtTheBottomShowsTheLatestEvenWithNewMessages() async throws {
        addMessages(40)
        try await showChat()
        let opened = await settled { self.atBottom }
        XCTAssertTrue(opened, "a chat opens at its latest message: \(String(describing: metrics))")
        await showOtherScreen()
        addMessages(3, from: 40)
        try await showChat()
        let back = await settled { self.atBottom }
        XCTAssertTrue(back, "back at the bottom, with the messages that came while away: \(String(describing: metrics))")
    }

    func testComingBackScrolledUpShowsTheSamePlace() async throws {
        addMessages(40)
        try await showChat()
        _ = await settled { self.atBottom }
        userScroll(top: 300)
        let moved = await settled { abs((self.metrics?.top ?? -1) - 300) < 2 }
        XCTAssertTrue(moved, "the user's scroll stays: \(String(describing: metrics))")
        await showOtherScreen()
        addMessages(2, from: 40)
        try await showChat()
        let back = await settled { abs((self.metrics?.top ?? -1) - 300) < 2 }
        XCTAssertTrue(back, "the same place, not the top and not the bottom: \(String(describing: metrics))")
    }

    func testComingBackAfterScrollingToTheVeryTopStaysThere() async throws {
        addMessages(40)
        try await showChat()
        _ = await settled { self.atBottom }
        userScroll(top: 0)
        _ = await settled { (self.metrics?.top ?? -1) < 1 }
        await showOtherScreen()
        try await showChat()
        let back = await settled { (self.metrics?.top ?? -1) < 1 }
        XCTAssertTrue(back, "left at the top, comes back at the top: \(String(describing: metrics))")
    }

    // MARK: jump to latest

    private var place: ChatPlace { session.place }
    private var newCount: Int { place.newCount(in: session.chat.entries) }

    func testTheButtonShowsOnlyFarUpCountsNewMessagesAndJumpsToTheBottom() async throws {
        addMessages(40)
        try await showChat()
        _ = await settled { self.atBottom }
        XCTAssertFalse(place.far, "no button at the bottom")
        try snapshot("chat-at-bottom")
        userScroll(top: (metrics?.content ?? 0) - (metrics?.visible ?? 0) - 100)
        let near = await settled { !self.place.following }
        XCTAssertTrue(near, "a small scroll up stops following")
        XCTAssertFalse(place.far, "less than a screen-height up: still no button")
        userScroll(top: 300)
        let far = await settled { self.place.far }
        XCTAssertTrue(far, "a screen-height up shows the button")
        XCTAssertEqual(newCount, 0)
        addMessages(3, from: 40)
        let counted = await settled { self.newCount == 2 }
        XCTAssertTrue(counted, "the badge counts the user's messages that came since, not the panel note between them: \(newCount)")
        XCTAssertEqual(metrics?.top ?? -1, 300, accuracy: 2, "new messages do not pull the view down")
        try snapshot("chat-scrolled-up")
        place.jump()
        let down = await settled { self.atBottom }
        XCTAssertTrue(down, "Jump to latest scrolls to the bottom: \(String(describing: metrics))")
        XCTAssertFalse(place.far, "at the bottom the button hides")
        XCTAssertTrue(place.following)
        XCTAssertEqual(newCount, 0)
        addMessages(1, from: 43)
        let follows = await settled { self.atBottom }
        XCTAssertTrue(follows, "after the jump new messages keep the view at the bottom")
    }

    /// A sleeping display or a hidden window runs no animation clock: the jump must still end at the bottom.
    func testJumpToLatestFinishesInAWindowThatIsNotVisible() async throws {
        addMessages(40)
        try await showChat()
        _ = await settled { self.atBottom }
        userScroll(top: 300)
        let far = await settled { self.place.far }
        XCTAssertTrue(far)
        window.orderOut(nil)
        await until { !self.window.occlusionState.contains(.visible) }
        place.jump()
        let down = await settled { self.atBottom }
        XCTAssertTrue(down, "the jump reaches the bottom without a visible window: \(String(describing: metrics))")
        XCTAssertFalse(place.far)
        XCTAssertTrue(place.following)
    }

    func testShouldAnimateOnlyWhenTheWindowCanDraw() {
        let f = ThreadScrollProbe.ProbeView.shouldAnimate
        XCTAssertTrue(f(true, false, false, false))
        XCTAssertFalse(f(false, false, false, false))
        XCTAssertFalse(f(true, true, false, false))
        XCTAssertFalse(f(true, false, true, false))
        XCTAssertFalse(f(true, false, false, true))
    }

    func testTheHeldBubbleAndAGrowingInputKeepTheBottomInView() async throws {
        addMessages(40)
        try await showChat(fillsHeight: true)
        _ = await settled { self.atBottom }
        session.chat.hold(text: "A held message\nwith\nseveral\nlines", images: [], stored: [], delay: .seconds(60)) { _ in }
        let held = await settled { self.atBottom }
        XCTAssertTrue(held, "the held bubble shows at the bottom: \(String(describing: metrics))")
        let before = metrics?.visible ?? 0
        session.text = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let grown = await settled { (self.metrics?.visible ?? before) < before && self.atBottom }
        XCTAssertTrue(grown, "the input grows, the thread's view shrinks and keeps its bottom: \(String(describing: metrics)) was \(before)")
        _ = session.chat.takeBack(editing: false)
        let undone = await settled { self.atBottom }
        XCTAssertTrue(undone, "Undo removes the bubble and the bottom stays in view")
    }

    func testAScrolledUpPlaceSurvivesTheInputGrowing() async throws {
        addMessages(40)
        try await showChat(fillsHeight: true)
        _ = await settled { self.atBottom }
        userScroll(top: 300)
        _ = await settled { abs((self.metrics?.top ?? -1) - 300) < 2 }
        let before = metrics?.visible ?? 0
        session.text = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let grown = await settled { (self.metrics?.visible ?? before) < before }
        XCTAssertTrue(grown, "the input grows and the thread's view shrinks")
        XCTAssertEqual(metrics?.top ?? -1, 300, accuracy: 2, "the view's top stays where the user left it")
    }

    /// Writes the window to `AGENT_PANEL_SNAPSHOT_DIR` (or the temporary folder) for the task's Report.
    private func snapshot(_ name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
