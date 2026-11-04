import XCTest

/// N349: resizing Dashboard tiles with a real mouse drag on their edges and corners (N344), in the real app (Tentacl Dev, `--ui-test`).
/// The layout starts as a known one passed in the arguments domain: the chat 3×4 on the left, Waiting for you 2×2 and Agents 2×1 next to it.
final class DashboardResizeUITests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    /// The `dashboardLayout.v2` value: chat (0,0) 4×3, Waiting (4,0) 1×2, Agents (4,2) 2×1; the bottom row under the chat is free.
    static let layoutJSON = #"[{"id":"chat","x":0,"y":0,"w":4,"h":3},{"id":"waiting","x":4,"y":0,"w":1,"h":2},{"id":"agents","x":4,"y":2,"w":2,"h":1}]"#

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = try Self.makeFixture()
        app = XCUIApplication()
        let hex = Data(Self.layoutJSON.utf8).map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["--ui-test", folder.path, "-dashboardLayout.v2", "<\(hex)>"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the window did not open")
        let dashboard = app.buttons.matching(identifier: "square.grid.2x2").firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 20), "the rail did not appear")
        dashboard.click()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private static func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tentacl-ui-resize-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo"), data = root.appendingPathComponent("data")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: data.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        let project: [String: Any] = ["id": "resize", "name": "Resize Project", "repoPath": repo.path, "dataDir": data.path, "maxParallel": 2, "sharedFiles": []]
        let projectFile = root.appendingPathComponent("project.json")
        try JSONSerialization.data(withJSONObject: project).write(to: projectFile)
        try JSONSerialization.data(withJSONObject: ["projects": [projectFile.path]]).write(to: root.appendingPathComponent("settings.json"))
        return root
    }

    /// The tile whose accessibility label starts with "<title>, ".
    private func tile(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
        XCTAssertTrue(e.waitForExistence(timeout: 10), "no \(title) tile\n\(app.debugDescription)", file: file, line: line)
        return e
    }

    private func expectLabel(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(e.waitForExistence(timeout: 5), "no tile labelled \"\(label)\"\n\(app.debugDescription)", file: file, line: line)
    }

    /// The window as a kept attachment (the review shots are exported from the result bundle).
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// A real press on `from` (window points) and a drag by `by`. XCUITest's `press(forDuration:thenDragTo:)` never delivers a mouse-down
    /// to the app on macOS (seen in N349); `click(forDuration:thenDragTo:)` does. `hoverShot` names a shot taken while hovering.
    private func drag(from p: CGPoint, by d: CGVector, hoverShot: String? = nil) {
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: p.x, dy: p.y))
        let end = origin.withOffset(CGVector(dx: p.x + d.dx, dy: p.y + d.dy))
        start.hover()
        if let hoverShot { Thread.sleep(forTimeInterval: 0.5); shot(hoverShot) }
        start.click(forDuration: 0.3, thenDragTo: end)
    }

    private func local(_ f: CGRect) -> CGRect { f.offsetBy(dx: -app.windows.firstMatch.frame.minX, dy: -app.windows.firstMatch.frame.minY) }

    /// One column and one row of the grid (cell plus gap), from the tiles' frames: the chat's 4 columns, Waiting's 2 rows.
    private func pitch() -> CGVector {
        let chat = local(tile("PM chat").frame), w = local(tile("Waiting for you").frame), agents = local(tile("Agents").frame)
        return CGVector(dx: (w.minX - chat.minX) / 4, dy: (agents.minY - w.minY) / 2)
    }

    /// N358: sizes are locked by default; the widget menu's Lock tile sizes unlocks them (saved, so a relaunch stays unlocked).
    private func unlock() {
        let widgets = app.buttons["Widgets"]
        XCTAssertTrue(widgets.waitForExistence(timeout: 10), "no widget button")
        widgets.click()
        let lock = app.buttons["Lock tile sizes"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), "no Lock tile sizes item\n\(app.debugDescription)")
        XCTAssertTrue(lock.isSelected, "locked by default")
        lock.click()
        XCTAssertFalse(lock.waitForExistence(timeout: 1), "the menu closes")
    }

    /// N358: locked (the default), a drag on Waiting's right edge changes nothing.
    func testALockedEdgeDragDoesNothing() {
        expectLabel("Waiting for you, 1 by 2")
        let w = local(tile("Waiting for you").frame), p = pitch()
        drag(from: CGPoint(x: w.maxX + 6, y: w.midY), by: CGVector(dx: p.dx, dy: 0))
        Thread.sleep(forTimeInterval: 1)
        expectLabel("Waiting for you, 1 by 2")
        expectLabel("PM chat, 4 by 3")
    }

    /// Waiting's right edge, grabbed in the middle of the gap (6 pt outside the tile), dragged one column: 2 by 2. It stays after a relaunch.
    func testDragWaitingRightEdgeOneColumn() {
        unlock()
        expectLabel("Waiting for you, 1 by 2")
        let w = local(tile("Waiting for you").frame), p = pitch()
        XCTAssertGreaterThan(p.dx, 100, "the grid is in its one-column fallback; the window is too small")
        drag(from: CGPoint(x: w.maxX + 6, y: w.midY), by: CGVector(dx: p.dx, dy: 0), hoverShot: "N349-hover")
        expectLabel("Waiting for you, 2 by 2")
        expectLabel("PM chat, 4 by 3")

        // A reload reads the saved layout (the arguments domain would win, so the relaunch goes without it).
        app.terminate()
        app.launchArguments = ["--ui-test", folder.path]
        app.launch()
        app.buttons.matching(identifier: "square.grid.2x2").firstMatch.click()
        expectLabel("Waiting for you, 2 by 2")
    }

    /// The chat's bottom-right corner, grabbed in the gap corner, dragged one column left and one row down: 3 by 4.
    func testDragChatBottomRightCorner() {
        unlock()
        expectLabel("PM chat, 4 by 3")
        let chat = local(tile("PM chat").frame), p = pitch()
        drag(from: CGPoint(x: chat.maxX + 6, y: chat.maxY + 6), by: CGVector(dx: -p.dx, dy: p.dy))
        expectLabel("PM chat, 3 by 4")
        shot("N349-after")
    }

    /// N358, push to shrink: the chat's right edge dragged one column into Waiting and Agents: chat 5 by 3, Waiting and Agents give a column.
    func testAnEdgePushesNeighboursSmaller() {
        unlock()
        // Agents is 2 wide, Waiting 1 wide (its minimum): Waiting first grows to 2 so both can give a column.
        let w = local(tile("Waiting for you").frame), p = pitch()
        drag(from: CGPoint(x: w.maxX + 6, y: w.midY), by: CGVector(dx: p.dx, dy: 0))
        expectLabel("Waiting for you, 2 by 2")
        let chat = local(tile("PM chat").frame)
        drag(from: CGPoint(x: chat.maxX + 6, y: chat.midY), by: CGVector(dx: p.dx, dy: 0))
        expectLabel("PM chat, 5 by 3")
        expectLabel("Waiting for you, 1 by 2")
        expectLabel("Agents, 1 by 1")
        shot("N358-push")
    }
}
