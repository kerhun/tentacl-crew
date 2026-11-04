import XCTest
import SwiftUI
@testable import AgentPanel

/// N254: the chat's Preview covers the PM chat card, expand covers the Dashboard, Esc / Chat / Restore step back.
@MainActor final class ChatPreviewLayoutTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private func state() -> ChatPreviewState { ChatPreviewState(defaults: makeTestDefaults(prefix: "n254")) }

    func testLayoutIsChatInChatOrExpandedOnEveryWidth() {
        XCTAssertEqual(ChatPreviewLayout.of(shown: false, expanded: false), .chat)
        XCTAssertEqual(ChatPreviewLayout.of(shown: false, expanded: true), .chat, "nothing to expand")
        XCTAssertEqual(ChatPreviewLayout.of(shown: true, expanded: false), .inChat)
        XCTAssertEqual(ChatPreviewLayout.of(shown: true, expanded: true), .expanded)
    }

    func testChatToPreviewToExpandedAndBack() {
        let s = state()
        XCTAssertEqual(s.layout("a"), .chat)
        s.select(.preview, project: "a")
        XCTAssertEqual(s.layout("a"), .chat, "no page yet: nothing to show")
        s.open(url("https://claude.ai/artifact/x"), project: "a")
        XCTAssertEqual(s.layout("a"), .inChat, "a link from the chat covers the chat card")
        s.setExpanded(true, project: "a")
        XCTAssertEqual(s.layout("a"), .expanded)
        s.setExpanded(false, project: "a")
        XCTAssertEqual(s.layout("a"), .inChat, "Restore goes back to the chat card")
        s.select(.chat, project: "a")
        XCTAssertEqual(s.layout("a"), .chat, "the Chat button")
        XCTAssertEqual(s.url(for: "a")?.absoluteString, "https://claude.ai/artifact/x", "the page stays for Show preview")
        s.select(.preview, project: "a")
        XCTAssertEqual(s.layout("a"), .inChat, "Show preview")
    }

    func testEscStepsBackDashboardThenChatCardThenNothing() {
        let s = state()
        s.open(url("http://localhost:3000/"), project: "a")
        s.setExpanded(true, project: "a")
        XCTAssertTrue(s.escape("a"))
        XCTAssertEqual(s.layout("a"), .inChat)
        XCTAssertTrue(s.escape("a"))
        XCTAssertEqual(s.layout("a"), .chat)
        XCTAssertFalse(s.escape("a"), "Esc does nothing when the chat shows")
    }

    func testBackToTheChatLeavesExpandedAndShowPreviewIsNotExpanded() {
        let s = state()
        s.open(url("http://localhost:3000/"), project: "a")
        s.setExpanded(true, project: "a")
        s.select(.chat, project: "a")
        XCTAssertFalse(s.expanded("a"))
        s.toggle("a")
        XCTAssertEqual(s.layout("a"), .inChat)
        s.setExpanded(true, project: "b")
        XCTAssertFalse(s.expanded("b"), "a project with no Preview cannot expand")
    }

    func testTheStateIsPerProject() {
        let s = state()
        s.open(url("http://localhost:3000/"), project: "a")
        s.open(url("http://localhost:5173/"), project: "b")
        s.setExpanded(true, project: "a")
        s.select(.chat, project: "b")
        XCTAssertEqual(s.layout("a"), .expanded)
        XCTAssertEqual(s.layout("b"), .chat)
        XCTAssertEqual(s.tab("a"), .preview)
        XCTAssertEqual(s.tab("b"), .chat)
        XCTAssertTrue(s.escape("a"))
        XCTAssertEqual(s.layout("b"), .chat, "Esc on a does not touch b")
    }

    func testCoveringTheChatIsKeptBetweenLaunchesExpandedIsNot() {
        let defaults = makeTestDefaults(prefix: "n254")
        let s = ChatPreviewState(defaults: defaults)
        s.open(url("http://localhost:3000/"), project: "a")
        s.open(url("http://localhost:5173/"), project: "b")
        s.setExpanded(true, project: "a")
        s.select(.chat, project: "b")
        let again = ChatPreviewState(defaults: defaults)
        XCTAssertEqual(again.layout("a"), .inChat)
        XCTAssertEqual(again.layout("b"), .chat)
    }

    /// The page model is kept while the layout changes; a new link makes a new one (N248's page model).
    func testThePageModelIsKeptAcrossLayouts() {
        let s = state(), holder = ChatPageHolder()
        s.open(url("http://localhost:3000/"), project: "a")
        let key = { "a|\(s.opened)" }
        let first = holder.model(key: key(), url: s.url(for: "a")!) { _ in }
        s.setExpanded(true, project: "a"); _ = s.escape("a"); s.select(.chat, project: "a"); s.select(.preview, project: "a")
        XCTAssertTrue(holder.model(key: key(), url: s.url(for: "a")!) { _ in } === first)
        s.open(url("http://localhost:3000/b"), project: "a")
        XCTAssertFalse(holder.model(key: key(), url: s.url(for: "a")!) { _ in } === first)
    }
}

@MainActor final class ChatPreviewLayoutSnapshotTests: XCTestCase {
    private func write(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    func testThePreviewInTheChatCardExpandedAndOnANarrowWindow() async throws {
        let dir = try TempDir()
        let iso = TestIsolation(dir, owner: self)
        let model = PanelModel(settingsURL: DemoSupport.prepareSettings(), makeTerminal: { DemoTerminal() }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() }, log: iso.log, writer: DemoCardWriter(),
                               defaults: iso.defaults, roleStore: iso.roleStore, autopilotStore: AutopilotStore(folder: dir.url.appendingPathComponent("autopilot")))
        await model.reload()
        let project = model.selectedProjectID ?? ""
        let state = ChatPreviewState(defaults: makeTestDefaults(prefix: "n254"))
        state.open(URL(string: "http://localhost:5173/settings")!, project: project)

        func shot(_ name: String, _ size: CGSize) throws {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: DashboardView(model: model, chatPreview: state), size: size))
            XCTAssertGreaterThan(data.count, 20_000)
            try write(data, name)
        }
        XCTAssertEqual(state.layout(project), .inChat)
        try shot("N254-preview-in-chat.png", CGSize(width: 1600, height: 900))
        state.setExpanded(true, project: project)
        try shot("N254-preview-expanded.png", CGSize(width: 1600, height: 900))
        XCTAssertTrue(state.escape(project))
        try shot("N254-narrow-preview-tab.png", CGSize(width: 860, height: 820))
        XCTAssertTrue(state.escape(project))
        try shot("N254-chat.png", CGSize(width: 1600, height: 900))
    }
}
