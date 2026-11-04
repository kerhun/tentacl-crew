import XCTest

/// N353: the Dashboard's Cost tile with its 7-day line, in the real app (Tentacl Dev, `--ui-test`). The fixture has done cards approved on
/// several of the last 7 days, each with a session file in the test's own `claude-projects` folder; one day has nothing.
final class CostTileUITests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testSmallTileShowsTheLine() throws { try run(layout: #"[{"id":"cost","x":0,"y":0,"w":1,"h":1},{"id":"waiting","x":1,"y":0,"w":2,"h":2}]"#, shot: "N353-cost-small") }

    func testLargeTileShowsTheLine() throws { try run(layout: #"[{"id":"cost","x":0,"y":0,"w":3,"h":2},{"id":"waiting","x":3,"y":0,"w":2,"h":2}]"#, shot: "N353-cost-large") }

    private func run(layout: String, shot name: String) throws {
        continueAfterFailure = false
        folder = try Self.makeFixture()
        app = XCUIApplication()
        let hex = Data(layout.utf8).map { String(format: "%02x", $0) }.joined()
        app.launchArguments = ["--ui-test", folder.path, "-dashboardLayout.v2", "<\(hex)>", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the window did not open")
        let dashboard = app.buttons.matching(identifier: "square.grid.2x2").firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 20), "the rail did not appear")
        dashboard.click()
        let line = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Last 7 days: $")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 20), "no 7-day line\n\(app.debugDescription)")
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Output tokens of each day's card (Opus), days back from today; day 2 has no card.
    static let days: [(back: Int, output: Int)] = [(6, 40_000), (5, 90_000), (4, 60_000), (3, 120_000), (1, 70_000), (0, 100_000)]

    private static func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tentacl-ui-cost-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo"), data = root.appendingPathComponent("data"), tasks = data.appendingPathComponent("tasks")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: tasks, withIntermediateDirectories: true)
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        for (i, d) in days.enumerated() {
            let id = "C\(i + 1)", branch = "task/c\(i + 1)"
            let when = cal.date(byAdding: .hour, value: 10, to: cal.date(byAdding: .day, value: -d.back, to: today)!)!
            let card = tasks.appendingPathComponent("\(id).md")
            try "---\nid: \(id)\nproject: cost\nstatus: done\nagent: dev-\(i)\nbranch: \(branch)\n---\n# \(id) · Card \(i + 1)\n\n## Goal\nx\n".write(to: card, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: min(when, Date())], ofItemAtPath: card.path)
            // The session folder is the worktree path with every character but letters, digits and "-" turned into "-".
            let worktree = repo.appendingPathComponent(".agent-worktrees/task-c\(i + 1)").path
            let folderName = String(worktree.unicodeScalars.map { s -> Character in (s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "-")) ? Character(s) : "-" })
            let sessions = root.appendingPathComponent("claude-projects").appendingPathComponent(folderName)
            try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
            let line = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","id":"m1","model":"claude-opus-4-1","content":[],"usage":{"input_tokens":100,"output_tokens":\#(d.output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
            try (line + "\n").write(to: sessions.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        }
        let project: [String: Any] = ["id": "cost", "name": "Cost Project", "repoPath": repo.path, "dataDir": data.path, "maxParallel": 2, "sharedFiles": []]
        let projectFile = root.appendingPathComponent("project.json")
        try JSONSerialization.data(withJSONObject: project).write(to: projectFile)
        try JSONSerialization.data(withJSONObject: ["projects": [projectFile.path]]).write(to: root.appendingPathComponent("settings.json"))
        return root
    }
}
