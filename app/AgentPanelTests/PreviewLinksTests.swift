import XCTest
import SwiftUI
import WebKit
@testable import AgentPanel

final class PreviewLinksTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private let root = URL(fileURLWithPath: "/tmp/n240-project")

    // MARK: classification

    func testArtifactLinks() {
        for s in ["https://claude.ai/artifact/abc-123", "https://claude.ai/code/artifact/6f1e-77", "https://www.claude.ai/artifact/x?y=1"] {
            XCTAssertEqual(PreviewLink.kind(of: url(s), projectRoot: root), .artifact, s)
            XCTAssertEqual(PreviewRoute.of(url(s)), .load, s)
        }
        for s in ["https://claude.ai/chat/1", "https://claude.ai/artifact/", "http://claude.ai/artifact/x", "https://evil.com/artifact/x", "https://claude.ai.evil.com/artifact/x"] {
            XCTAssertNotEqual(PreviewLink.kind(of: url(s), projectRoot: root), .artifact, s)
        }
        XCTAssertEqual(PreviewRoute.of(url("https://claude.ai/chat/1")), .openOutside)
    }

    func testLocalDesignAndOtherLinks() {
        XCTAssertEqual(PreviewLink.kind(of: url("http://localhost:5173/x"), projectRoot: root), .local)
        XCTAssertEqual(PreviewLink.kind(of: url("http://127.0.0.1:8000/"), projectRoot: root), .local)
        XCTAssertEqual(PreviewLink.kind(of: url("design/preview.html"), projectRoot: root), .designFile)
        XCTAssertEqual(PreviewLink.kind(of: URL(fileURLWithPath: "/tmp/n240-project/design/a/b.html"), projectRoot: root), .designFile)
        XCTAssertEqual(PreviewLink.kind(of: URL(fileURLWithPath: "/tmp/n240-project/design/../secret.html"), projectRoot: root), .other)
        XCTAssertEqual(PreviewLink.kind(of: URL(fileURLWithPath: "/tmp/n240-project/src/a.html"), projectRoot: root), .other)
        XCTAssertEqual(PreviewLink.kind(of: URL(fileURLWithPath: "/tmp/n240-project/design/a.txt"), projectRoot: root), .other)
        XCTAssertEqual(PreviewLink.kind(of: url("design/preview.html"), projectRoot: nil), .other)
        XCTAssertEqual(PreviewLink.kind(of: url("https://example.com/"), projectRoot: root), .other)
    }

    func testTheClaudeViewFollowsSignInButNotOtherSites() {
        let claude = PreviewSession.claude
        XCTAssertEqual(PreviewRoute.of(url("https://claude.ai/login"), session: claude), .load)
        XCTAssertEqual(PreviewRoute.of(url("https://accounts.google.com/o/oauth2/v2/auth"), session: claude), .load)
        XCTAssertEqual(PreviewRoute.of(url("https://abc.claudeusercontent.com/x"), mainFrame: false, session: claude), .load, "the artifact's own frame")
        XCTAssertEqual(PreviewRoute.of(url("https://example.com/"), session: claude), .openOutside)
        XCTAssertEqual(PreviewRoute.of(url("https://accounts.google.com/"), session: .local), .openOutside, "a local page cannot reach it")
    }

    // MARK: web view

    @MainActor func testTheClaudeStoreIsPersistentAndNotTheLocalOne() {
        let claude = PreviewModel.configuration(for: .claude)
        let local = PreviewModel.configuration(for: .local)
        XCTAssertTrue(claude.websiteDataStore.isPersistent)
        XCTAssertNotEqual(claude.websiteDataStore, local.websiteDataStore)
        XCTAssertNotEqual(claude.websiteDataStore, WKWebsiteDataStore.default())
        XCTAssertEqual(claude.websiteDataStore.identifier, PreviewLink.claudeStoreID)
    }

    @MainActor func testNoScriptsAreInjectedIntoClaudePages() {
        let handler = NoopHandler()
        XCTAssertTrue(PreviewModel.configuration(for: .claude, handler: handler).userContentController.userScripts.isEmpty)
        XCTAssertEqual(PreviewModel.configuration(for: .local, handler: handler).userContentController.userScripts.count, 2)
    }

    @MainActor func testOpeningAnArtifactSwitchesTheSessionAndBack() {
        let model = PreviewModel(url: url("http://localhost:3000/"))
        XCTAssertEqual(model.session, .local)
        XCTAssertFalse(model.isClaude)
        let before = model.generation
        model.show(url("https://claude.ai/artifact/abc"))
        XCTAssertTrue(model.isClaude)
        XCTAssertEqual(model.current?.absoluteString, "https://claude.ai/artifact/abc")
        XCTAssertEqual(model.generation, before + 1)
        model.show(url("https://claude.ai/code/artifact/def"))
        XCTAssertEqual(model.generation, before + 1, "same session keeps its web view")
        model.go("localhost:5173")
        XCTAssertEqual(model.session, .local)
        XCTAssertEqual(model.generation, before + 2)
    }

    @MainActor func testTypedArtifactAddressOpensHereAndNotInTheBrowser() {
        var opened: [URL] = []
        let model = PreviewModel(url: nil, openOutside: { opened.append($0) })
        model.go("https://claude.ai/artifact/abc")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(model.isClaude)
        model.openInBrowser()
        XCTAssertEqual(opened, [url("https://claude.ai/artifact/abc")])
    }

    // MARK: chat links

    func testAClickOpensThePreviewAndACommandClickTheBrowser() {
        for s in ["https://claude.ai/artifact/abc", "http://localhost:5173/", "design/preview.html"] {
            XCTAssertEqual(ChatLinkAction.of(url(s), commandHeld: false, projectRoot: root).isPreview, true, s)
            XCTAssertEqual(ChatLinkAction.of(url(s), commandHeld: true, projectRoot: root).isPreview, false, s)
        }
        XCTAssertEqual(ChatLinkAction.of(url("https://example.com/"), commandHeld: false, projectRoot: root), .browser(url("https://example.com/")))
        XCTAssertEqual(ChatLinkAction.of(url("design/preview.html"), commandHeld: false, projectRoot: root),
                       .preview(URL(fileURLWithPath: "/tmp/n240-project/design/preview.html")))
    }

    func testBareAddressesAndDesignPathsBecomeLinks() {
        let text = ChatLinks.linkified(AttributedString("See https://claude.ai/artifact/abc and design/preview.html, or localhost only."))
        let links = text.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://claude.ai/artifact/abc", "design/preview.html"])
    }

    @MainActor func testTheChatPreviewRemembersThePageAndVisibilityPerProject() {
        let defaults = makeTestDefaults(prefix: "n240")
        let state = ChatPreviewState(defaults: defaults)
        XCTAssertFalse(state.shown("a"))
        state.open(url("http://localhost:3000/"), project: "a")
        XCTAssertTrue(state.shown("a"))
        XCTAssertFalse(state.shown("b"))
        state.remember(url("http://localhost:3000/next"), project: "a")
        state.toggle("a")
        XCTAssertFalse(state.shown("a"))
        let again = ChatPreviewState(defaults: defaults)
        XCTAssertEqual(again.url(for: "a")?.absoluteString, "http://localhost:3000/next")
        XCTAssertFalse(again.shown("a"))
        again.open(url("https://claude.ai/artifact/x"), project: "a")
        XCTAssertTrue(again.shown("a"))
    }

    @MainActor func testRememberKeepsOnlyPreviewPagesNotSignInOrOtherHosts() {
        let state = ChatPreviewState(defaults: makeTestDefaults(prefix: "n248"))
        state.open(url("https://claude.ai/artifact/x"), project: "a")
        for s in ["https://accounts.google.com/o/oauth2/v2/auth", "https://claude.ai/login", "https://claude.ai/magic-link#abc", "https://example.com/", "https://abc.claudeusercontent.com/x"] {
            state.remember(url(s), project: "a", projectRoot: root)
            XCTAssertEqual(state.url(for: "a")?.absoluteString, "https://claude.ai/artifact/x", s)
        }
        state.remember(url("https://claude.ai/code/artifact/y"), project: "a", projectRoot: root)
        XCTAssertEqual(state.url(for: "a")?.absoluteString, "https://claude.ai/code/artifact/y")
        state.remember(url("http://localhost:5173/"), project: "a", projectRoot: root)
        XCTAssertEqual(state.url(for: "a")?.absoluteString, "http://localhost:5173/")
        let design = URL(fileURLWithPath: "/tmp/n240-project/design/a.html")
        state.remember(design, project: "a", projectRoot: root)
        XCTAssertEqual(state.url(for: "a"), design)
        state.remember(URL(fileURLWithPath: "/tmp/elsewhere/a.html"), project: "a", projectRoot: root)
        XCTAssertEqual(state.url(for: "a"), design, "a file outside design/")
    }

    func testThePreviewTabIsNamedByThePageTitleOrHost() {
        XCTAssertEqual(PreviewPane.tabTitle(title: "Settings draft", url: url("https://claude.ai/artifact/x")), "Settings draft")
        XCTAssertEqual(PreviewPane.tabTitle(title: "  ", url: url("http://localhost:5173/a")), "localhost:5173")
        XCTAssertEqual(PreviewPane.tabTitle(title: nil, url: url("https://claude.ai/artifact/x")), "claude.ai")
        XCTAssertEqual(PreviewPane.tabTitle(title: nil, url: URL(fileURLWithPath: "/w/design/settings.html")), "settings.html")
        XCTAssertEqual(PreviewPane.tabTitle(title: nil, url: nil), "Preview")
    }

    // MARK: terminals

    func testAnArtifactLinkInATerminalIsAPage() {
        let text = "ready\nPreview: https://claude.ai/code/artifact/6f1e-77.\n$ "
        XCTAssertEqual(PreviewLink.page(in: text)?.url.absoluteString, "https://claude.ai/code/artifact/6f1e-77")
        XCTAssertEqual(PreviewLink.page(in: "https://claude.ai/artifact/old\nLocal: http://localhost:5173/\n")?.url.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(PreviewLink.page(in: "Local: http://localhost:5173/\nhttps://claude.ai/artifact/new\n")?.url.absoluteString, "https://claude.ai/artifact/new")
        XCTAssertNil(PreviewLink.page(in: "https://claude.ai/chat/1"))
        XCTAssertEqual(TerminalPreview.port(url("https://claude.ai/artifact/x")), "artifact")
    }

    @MainActor func testTheTerminalWatchKeepsAnArtifactWithoutAPort() async {
        let watch = TerminalPageWatch(isOpen: { _ in false })
        await watch.consider(pane: "p", text: "https://claude.ai/artifact/abc")
        XCTAssertEqual(watch.pages["p"]?.url.absoluteString, "https://claude.ai/artifact/abc")
        await watch.recheck()
        XCTAssertNotNil(watch.pages["p"], "no port to close")
    }
}

private extension ChatLinkAction {
    var isPreview: Bool { if case .preview = self { return true } else { return false } }
}

private final class NoopHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
}

/// Snapshots → tasks/assets/N240-*.png (AGENT_PANEL_SNAPSHOT_DIR). The web view is not drawn by ImageRenderer.
@MainActor
final class PreviewLinksSnapshotTests: XCTestCase {
    private func write(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    func testChatBesideThePreview() throws {
        let entries = [
            ChatEntry(id: "1", kind: .user, text: "Show me the Settings design", time: nil),
            ChatEntry(id: "2", kind: .agent, text: "The page is design/settings.html. The same draft as an artifact: https://claude.ai/artifact/6f1e-77a2 (⌘-click opens either in the browser).", time: nil),
        ]
        let chat = ChatThread(place: ChatPlace(), entries: entries, agentLabel: "PM", working: false).padding(12).frame(width: 380).background(Tok.pane)
        let model = PreviewModel(url: URL(fileURLWithPath: "/work/demo/design/settings.html"))
        let preview = PreviewPane(model: model, source: nil, cardID: "Chat", onClose: {}, fromText: "from the chat").padding(8).frame(width: 560)
        let view = HStack(spacing: 0) { chat; Divider().overlay(Tok.line); preview }.environment(\.snapshotMode, true).background(Tok.pane)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 940, height: 480)))
        XCTAssertGreaterThan(data.count, 10_000)
        try write(data, "N240-chat-preview.png")
    }

    func testArtifactShowsTheSignInHint() throws {
        let model = PreviewModel(url: URL(string: "https://claude.ai/artifact/6f1e-77a2"))
        let view = PreviewPane(model: model, source: nil, cardID: "Chat", onClose: {}, fromText: "claude.ai artifact").frame(width: 760, height: 420).padding(12)
            .environment(\.snapshotMode, true).background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 784, height: 444)))
        XCTAssertGreaterThan(data.count, 10_000)
        try write(data, "N240-artifact-hint.png")
    }
}
