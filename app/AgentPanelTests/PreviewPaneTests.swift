import XCTest
import SwiftUI
@testable import AgentPanel

final class PreviewPaneTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: local only

    func testLocalPagesLoadInThePane() {
        for s in ["http://localhost:5173/", "https://localhost:8443/x", "http://127.0.0.1:8000/", "http://[::1]:3000/", "http://app.localhost:3000/",
                  "file:///tmp/index.html", "about:blank"] {
            XCTAssertEqual(PreviewRoute.of(url(s)), .load, s)
        }
    }

    func testEveryOtherLinkIsSentToTheBrowser() {
        for s in ["https://example.com/", "http://192.168.1.20:5173/", "https://localhost.example.com/", "mailto:a@b.c"] {
            XCTAssertEqual(PreviewRoute.of(url(s)), .openOutside, s)
        }
        XCTAssertEqual(PreviewRoute.of(url("https://www.youtube.com/embed/x"), mainFrame: false), .ignore, "an embedded frame never opens the browser")
        XCTAssertEqual(PreviewRoute.of(url("javascript:void(0)")), .ignore)
    }

    func testTypedAddresses() {
        XCTAssertEqual(PreviewRoute.typed("localhost:5173/settings")?.absoluteString, "http://localhost:5173/settings")
        XCTAssertEqual(PreviewRoute.typed(" https://localhost:1/ ")?.absoluteString, "https://localhost:1/")
        XCTAssertEqual(PreviewRoute.typed("/tmp/page.html")?.absoluteString, "file:///tmp/page.html")
        XCTAssertNil(PreviewRoute.typed("  "))
    }

    @MainActor func testATypedOutsideAddressOpensInTheBrowserAndNotHere() {
        var opened: [URL] = []
        let model = PreviewModel(url: nil, openOutside: { opened.append($0) })
        model.go("https://example.com/a")
        XCTAssertEqual(opened, [url("https://example.com/a")])
        XCTAssertNil(model.current)
        model.go("localhost:3000")
        XCTAssertEqual(model.current?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(opened.count, 1)
    }

    // MARK: fix notes

    func testFixNoteLineFormat() {
        XCTAssertEqual(PreviewNote.line(url: url("http://localhost:5173/settings"), selector: "button.btn-primary", note: "  Button sticks\nto the field  "),
                       "- http://localhost:5173/settings button.btn-primary: Button sticks to the field")
    }

    @MainActor func testTheNoteLineNeedsAPickAndANote() {
        let model = PreviewModel(url: url("http://localhost:5173/"))
        XCTAssertNil(model.noteLine)
        model.picked = PickedElement(selector: "main > h2", rect: CGRect(x: 0, y: 0, width: 132.4, height: 38))
        model.note = "   "
        XCTAssertNil(model.noteLine)
        model.note = "Too big"
        XCTAssertEqual(model.noteLine, "- http://localhost:5173/ main > h2: Too big")
        XCTAssertEqual(model.picked?.size, "132×38")
    }

    func testAddToFixNotesAppendsToTheCardsSection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = dir.appendingPathComponent("N9.md")
        try "---\nid: N9\nproject: p\nstatus: review\n---\n# N9 · T\n\n## Report\nok\n\n## Fix notes\n- old\n\n## Decision\n".write(to: card, atomically: true, encoding: .utf8)
        try PreviewNote.append("- http://localhost:1/ a: one", toCardAt: card)
        try PreviewNote.append("- http://localhost:1/ b: two", toCardAt: card)
        let text = try String(contentsOf: card, encoding: .utf8)
        XCTAssertTrue(text.contains("## Fix notes\n- old\n\n- http://localhost:1/ a: one\n\n- http://localhost:1/ b: two\n\n## Decision"), text)
        XCTAssertTrue(text.contains("status: review"), "the status stays")
    }

    // MARK: layout

    func testWidthsAndZoom() {
        XCTAssertEqual(PreviewWidth.desktop.frame(available: 800).width, 800)
        XCTAssertEqual(PreviewWidth.phone.frame(available: 800).width, 390)
        XCTAssertEqual(PreviewWidth.phone.frame(available: 800).zoom, 1)
        let tablet = PreviewWidth.tablet.frame(available: 768)
        XCTAssertEqual(tablet.width, 768)
        XCTAssertEqual(tablet.zoom, 0.75, accuracy: 0.0001, "1024 is laid out at 1024 and scaled to fit")
        XCTAssertNotNil(PreviewWidth.phone.userAgent?.range(of: "iPhone"))
        XCTAssertNil(PreviewWidth.desktop.userAgent)
    }

    func testTheCommentBoxSitsRightNextToTheElement() {
        let frame = CGSize(width: 1000, height: 600), box = CGSize(width: 300, height: 150)
        XCTAssertEqual(PickBoxPlacement.origin(element: CGRect(x: 28, y: 200, width: 132, height: 38), frame: frame, box: box, below: false), CGPoint(x: 168, y: 200), "beside it on the right")
        XCTAssertEqual(PickBoxPlacement.origin(element: CGRect(x: 800, y: 200, width: 150, height: 38), frame: frame, box: box, below: false), CGPoint(x: 492, y: 200), "on the left when the right is full")
        XCTAssertEqual(PickBoxPlacement.origin(element: CGRect(x: 0, y: 500, width: 1000, height: 40), frame: frame, box: box, below: false).y, 342, "above when neither side nor below fits")
        let phone = CGSize(width: 390, height: 600)
        XCTAssertEqual(PickBoxPlacement.origin(element: CGRect(x: 200, y: 100, width: 150, height: 40), frame: phone, box: box, below: true), CGPoint(x: 82, y: 148), "below it on the 390 width, kept inside")
    }

    func testScreenshotsAreNumberedInTheAssetsFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(PreviewShots.next(in: dir, id: "N9").lastPathComponent, "N9-preview-1.png", "a missing folder starts at 1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["N9-preview-1.png", "N9-preview-10.png", "N9-preview-2.png", "N90-preview-3.png", "N9-shot.png"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(PreviewShots.existing(in: dir, id: "N9").map(\.lastPathComponent), ["N9-preview-1.png", "N9-preview-2.png", "N9-preview-10.png"])
        XCTAssertEqual(PreviewShots.next(in: dir, id: "N9").lastPathComponent, "N9-preview-11.png")
    }
}

/// Snapshots → tasks/assets/N225-*.png (AGENT_PANEL_SNAPSHOT_DIR). The web view is not drawn by ImageRenderer: the page area shows a
/// placeholder there.
@MainActor
final class PreviewPaneSnapshotTests: XCTestCase {
    private func write(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    private let card = TaskCard(id: "N225", project: "p", status: .doing, agent: "ui_dev-n225", branch: "task/n225", kind: nil, files: [], title: "Preview",
                                sections: [:], url: URL(fileURLWithPath: "/x/tasks/N225.md"), modified: nil)

    func testEmptyStateInTheTaskDetail() throws {
        let view = TaskDetailView(card: card, shots: [], opener: nil, startState: StartButtonState(enabled: false, help: ""),
                                  reviewState: reviewButtonStates(card: card, canAct: false, reason: "x", worktreeExists: false, busy: false, agentWorking: true),
                                  onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}, startTab: .preview)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 900, height: 560)))
        XCTAssertGreaterThan(data.count, 20_000)
        try write(data, "N225-preview-empty.png")
    }

    func testPaneChromeWithAPickedElementAndConsole() throws {
        func pane(_ width: PreviewWidth, _ rect: CGRect) -> some View {
            let model = PreviewModel(url: URL(string: "http://localhost:5173/settings"), picking: true)
            model.width = width
            model.record(PreviewConsoleLine(level: .error, text: "GET /api/currencies 404"))
            model.record(PreviewConsoleLine(level: .error, text: "TypeError: list.map is not a function · settings.tsx:31"))
            model.picked = PickedElement(selector: "button.btn-primary", rect: rect)
            model.note = "Button sticks to the field at 390 px"
            return PreviewPane(model: model, source: "npm run dev", cardID: "W12", assetsFolder: URL(fileURLWithPath: "/x/assets"), addFixNote: { _ in nil }, onClose: {})
                .frame(height: 620)
        }
        let view = VStack(spacing: 20) { pane(.desktop, CGRect(x: 28, y: 236, width: 132, height: 38)); pane(.phone, CGRect(x: 24, y: 236, width: 132, height: 38)) }
            .padding(20).background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1100, height: 1300)))
        XCTAssertGreaterThan(data.count, 20_000)
        try write(data, "N225-preview.png")
    }
}

/// The injected scripts in a real web view (a local file page, no window, no network).
@MainActor
final class PreviewWebViewTests: XCTestCase {
    func testConsoleErrorsAndAPickReachTheModel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("index.html")
        try """
        <html><body><main><button class="btn btn-primary" style="width:132px;height:38px">Save</button><button class="btn">Cancel</button></main>
        <script>console.warn('slow'); console.error('GET /api/currencies 404');</script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let model = PreviewModel(url: page)
        let web = model.webView()
        web.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        try await wait { model.console.count == 2 }
        XCTAssertEqual(model.console, [PreviewConsoleLine(level: .warn, text: "slow"), PreviewConsoleLine(level: .error, text: "GET /api/currencies 404")])
        XCTAssertEqual(model.errorCount, 1)

        model.togglePick()
        _ = try await web.evaluateJavaScript("document.querySelector('.btn-primary').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true})); 1")
        try await wait { model.picked != nil }
        XCTAssertEqual(model.picked?.selector, "button.btn.btn-primary")
        XCTAssertEqual(model.picked?.size, "132×38")
    }

    private func wait(_ done: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(done(), "timed out")
    }
}
