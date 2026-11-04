import XCTest

/// Opens the real app (Tentacl Dev) in its UI-test mode (`--ui-test <folder>`: the folder holds settings.json and a fixture project; no
/// real settings, projects, terminal or action log) and opens every screen of the rail.
final class ScreenSmokeTests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = try Self.makeFixture()
        app = XCUIApplication()
        app.launchArguments = ["--ui-test", folder.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the window did not open")
        XCTAssertTrue(app.buttons["Dashboard"].waitForExistence(timeout: 20), "the rail did not appear")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// settings.json -> project.json -> a repo folder and a data folder with two cards (one in review with changed files).
    private static func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tentacl-ui-smoke-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo"), data = root.appendingPathComponent("data")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: data.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        let project: [String: Any] = ["id": "smoke", "name": "Smoke Project", "repoPath": repo.path, "dataDir": data.path, "maxParallel": 2, "sharedFiles": []]
        let projectFile = root.appendingPathComponent("project.json")
        try JSONSerialization.data(withJSONObject: project).write(to: projectFile)
        try JSONSerialization.data(withJSONObject: ["projects": [projectFile.path]]).write(to: root.appendingPathComponent("settings.json"))
        try """
        ---
        id: S1
        project: smoke
        status: review
        agent: dev-s1-smoke
        branch: task/s1
        files:
          - Sources/Widget.swift
          - Sources/Gauge.swift
        ---
        # S1 · Smoke review card

        ## Goal
        Fixture card in review.

        ## Report
        Done, with a short report.
        """.write(to: data.appendingPathComponent("tasks/S1.md"), atomically: true, encoding: .utf8)
        try """
        ---
        id: S2
        project: smoke
        status: todo
        files:
          - Sources/Other.swift
        ---
        # S2 · Smoke todo card

        ## Goal
        Fixture card to do.
        """.write(to: data.appendingPathComponent("tasks/S2.md"), atomically: true, encoding: .utf8)
        // A running round, so the Plan screen shows its board (Now, goal, summary) and not "No plan yet".
        try #"{"rounds":[{"name":"Smoke round","cards":["S1","S2"],"status":"running"}]}"#.write(to: data.appendingPathComponent("plan.json"), atomically: true, encoding: .utf8)
        return root
    }

    /// The rail buttons carry their SF Symbol as identifier; "Plan" alone is also the name of a button on the Dashboard.
    private static let rail = ["Dashboard": "square.grid.2x2", "Tasks": "checklist", "Terminals": "terminal", "Timeline": "calendar.day.timeline.left", "Team": "person.2",
                               "Plan": "book.closed", "Git": "arrow.triangle.branch", "Stats": "chart.bar", "Settings": "gearshape", "Notes": "note.text"]

    private func open(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons.matching(identifier: Self.rail[screen] ?? "").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no rail button \(screen)", file: file, line: line)
        button.click()
        XCTAssertEqual(app.state, .runningForeground, "the app is gone after opening \(screen)", file: file, line: line)
    }

    /// A text or a button whose label contains `text` (case does not matter) shows up on the screen.
    private func expect(_ text: String, screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let p = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let found = app.descendants(matching: .any).matching(p).firstMatch.waitForExistence(timeout: 10)
        XCTAssertTrue(found, "\(screen): nothing with \"\(text)\"\n\(app.debugDescription)", file: file, line: line)
    }

    func testDashboard() { open("Dashboard"); expect("Waiting for you", screen: "Dashboard"); expect("Plan a round", screen: "Dashboard") }
    func testTasks() { open("Tasks"); expect("S1, Smoke review card", screen: "Tasks"); expect("S2, Smoke todo card", screen: "Tasks") }
    func testTerminals() { open("Terminals"); expect("No terminals", screen: "Terminals"); expect("Prompt", screen: "Terminals") }   // no terminal in UI-test mode
    func testTimeline() { open("Timeline"); expect("Round · Smoke round", screen: "Timeline") }   // the fixture's plan.json names the round
    func testTeam() { open("Team"); expect("Roster", screen: "Team"); expect("Agents running", screen: "Team") }
    func testPlan() { open("Plan"); expect("Smoke round", screen: "Plan"); expect("Project summary", screen: "Plan"); expect("Save goal", screen: "Plan") }
    func testGit() { open("Git"); expect("Fetch", screen: "Git"); expect("Git · Smoke Project", screen: "Git") }
    func testStats() { open("Stats"); expect("Cards merged per day", screen: "Stats"); expect("Last 14 days", screen: "Stats") }
    func testSettings() { open("Settings"); expect("Startup and updates", screen: "Settings"); expect("Check for updates automatically", screen: "Settings") }
    func testNotes() { open("Notes"); expect("No notes in Smoke Project yet", screen: "Notes"); expect("Close notes", screen: "Notes") }

    func testTaskDetailAndChangesTab() {
        open("Tasks")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "S1,")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no S1 row\n\(app.debugDescription)")
        row.click()
        expect("Smoke review card", screen: "Task detail")
        let changes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Changes")).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 10), "no Changes tab on the task detail\n\(app.debugDescription)")
        changes.click()
        XCTAssertEqual(app.state, .runningForeground)
        expect("Widget.swift", screen: "Changes tab")
    }

    func testWaitingForYou() {
        open("Dashboard")
        expect("Waiting for you \u{B7} 1", screen: "Waiting for you")
        expect("Review \u{B7} S1: Smoke review card", screen: "Waiting for you")
    }
}
