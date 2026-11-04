import XCTest
@testable import AgentPanel

/// Settings → General → Appearance (N312): a choice is shown at once and saved in the settings file.
@MainActor
final class AppearanceSettingTests: XCTestCase {
    private final class NoGit: CommandRunner, @unchecked Sendable {
        func run(_ executable: URL, _ arguments: [String]) async throws -> Data { Data() }
    }
    private final class NoLoginItem: LoginItemControlling, @unchecked Sendable {
        var isEnabled: Bool { false }
        func setEnabled(_ on: Bool) throws {}
    }

    private var dir: URL!
    private var saved: AppTheme = .dark
    private var savedLook: NSAppearance?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saved = AppTheme.current; savedLook = NSApplication.shared.appearance
    }

    override func tearDown() async throws {
        AppTheme.current = saved; NSApplication.shared.appearance = savedLook
        try? FileManager.default.removeItem(at: dir)
    }

    private func flow(_ settingsURL: URL) -> SettingsFlow {
        SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: settingsURL, stableDir: dir.appendingPathComponent("stable"),
                     signingConfigured: false, git: NoGit(), release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") },
                     appURL: dir.appendingPathComponent("Tentacl.app"), processID: 1, launch: { _, _ in },
                     extras: SettingsExtras(defaults: makeTestDefaults(prefix: "appearance"), loginItem: NoLoginItem(), toolProbe: { _ in nil }))
    }

    func testChangePostsTerminalThemeChanged() throws {
        let url = dir.appendingPathComponent("projects.json")
        try Data(#"{"projects": []}"#.utf8).write(to: url)
        let posted = expectation(forNotification: TerminalAppearance.themeChanged, object: nil)
        flow(url).setAppearance(.light)
        wait(for: [posted], timeout: 1)
    }

    func testChangeSetsCurrentThemeAndIsSaved() throws {
        let url = dir.appendingPathComponent("projects.json")
        try Data(#"{"projects": [], "scriptsDir": "/nowhere"}"#.utf8).write(to: url)
        let f = flow(url)
        f.setAppearance(.midnight)
        XCTAssertEqual(f.appearance, .midnight)
        XCTAssertEqual(AppTheme.current, .midnight)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        XCTAssertNil(f.appearanceError)
        XCTAssertEqual(AppSettingsStore.load(settingsURL: url).appearance, .midnight)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["scriptsDir"] as? String, "/nowhere", "other keys are kept")

        f.setAppearance(.light)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
        f.setAppearance(.system)
        XCTAssertNil(NSApplication.shared.appearance, "System follows macOS")
        XCTAssertEqual(AppSettingsStore.load(settingsURL: url).appearance, .system)
    }

    func testUnwritableFileKeepsTheChoiceAndSays() throws {
        let url = dir.appendingPathComponent("projects.json")
        try Data("not json".utf8).write(to: url)
        let f = flow(url)
        f.setAppearance(.light)
        XCTAssertEqual(AppTheme.current, .light)
        XCTAssertNotNil(f.appearanceError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json", "a broken file is never overwritten")
    }

    func testFlowShowsTheThemeOnScreen() {
        AppTheme.current = .midnight
        XCTAssertEqual(flow(dir.appendingPathComponent("p.json")).appearance, .midnight)
    }

    func testSearchFindsAppearance() {
        XCTAssertEqual(SettingsItem.matching("Appearance"), [.appearance])
        XCTAssertEqual(SettingsItem.matching("theme"), [.appearance])
        XCTAssertEqual(SettingsItem.matching("midnight"), [.appearance])
        XCTAssertEqual(SettingsItem.appearance.category, .general)
    }

    /// Dashboard, Settings and a sheet follow the theme (nothing forces Dark any more). `AGENT_PANEL_SNAPSHOT_DIR` keeps the PNGs.
    func testWindowAndSheetFollowTheTheme() async throws {
        let model = await DemoSupport.makeModel()
        let b1 = try XCTUnwrap(model.cards.compactMap { r -> TaskCard? in if case .card(let c) = r, c.id == "B1" { return c } else { return nil } }.first)
        let approval = ApprovalPlan(card: b1, agentName: "dev-b1", branch: "feat/b1", worktreePath: "/repo/.agent-worktrees/feat-b1", base: "main",
                                    head: "0123456789abcdef0123456789abcdef01234567", ahead: 2, filesChanged: 3, screenshotCount: 1, isAnalysis: false, commandPreview: "merge-task.sh")
        let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        var shots: [AppTheme: [Data]] = [:]
        for theme in [AppTheme.light, .dark, .midnight] {
            AppTheme.apply(theme)
            let window = CGSize(width: 1440, height: 860)
            let images = [
                ("dashboard", try XCTUnwrap(SnapshotRenderer.render(view: ShellView(model: model, screen: .dashboard), size: window))),
                ("settings", try XCTUnwrap(SnapshotRenderer.render(view: ShellView(model: model, screen: .settings), size: window))),
                ("approve-sheet", try XCTUnwrap(SnapshotRenderer.render(view: ApproveSheet(plan: approval, state: .idle, onConfirm: {}, onCancel: {}), size: CGSize(width: 560, height: 480)))),
            ]
            if let out { for (name, data) in images { try data.write(to: out.appendingPathComponent("\(name)-\(theme.rawValue).png")) } }
            shots[theme] = images.map(\.1)
        }
        for i in 0..<3 {
            XCTAssertNotEqual(shots[.light]?[i], shots[.dark]?[i], "image \(i) is not the same in Light and Dark")
            XCTAssertNotEqual(shots[.midnight]?[i], shots[.dark]?[i], "image \(i) is not the same in Midnight and Dark")
        }
    }

    /// F1: the wordmark's dark-ink image is used on Light only (the asset's variant follows this scheme).
    func testThemeSchemePicksTheAssetSide() {
        XCTAssertEqual(ThemeScheme.scheme(.light, window: .dark), .light)
        XCTAssertEqual(ThemeScheme.scheme(.dark, window: .light), .dark)
        XCTAssertEqual(ThemeScheme.scheme(.midnight, window: .light), .dark)
        XCTAssertEqual(ThemeScheme.scheme(.system, window: .light), .light)
        XCTAssertEqual(ThemeScheme.scheme(.system, window: .dark), .dark)
    }
}
