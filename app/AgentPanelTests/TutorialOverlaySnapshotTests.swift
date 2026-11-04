import XCTest
import SwiftUI
@testable import AgentPanel

/// N311: the tour over the Dashboard in Light, Dark and Midnight, and the review shots (the welcome, one step per tour, the `?` popover).
/// Set AGENT_PANEL_SNAPSHOT_DIR to write the PNGs (N311-*.png).
@MainActor
final class TutorialOverlaySnapshotTests: XCTestCase {
    private let window = CGSize(width: 1440, height: 860)
    override func tearDown() { AppTheme.current = .dark; super.tearDown() }

    private func tutorial(_ model: PanelModel, screen: ShellScreen) -> TutorialModel {
        TutorialModel(store: TutorialStore(defaults: makeTestDefaults(prefix: "tutorial-shot")), screen: screen)
    }

    private func render(_ name: String, theme: AppTheme, size: CGSize, _ view: () -> some View) throws -> NSBitmapImageRep {
        AppTheme.current = theme
        let scheme: ColorScheme = theme == .light ? .light : .dark
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view().environment(\.colorScheme, scheme), size: size))
        XCTAssertGreaterThan(data.count, 10_000, name)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N311-\(name)-\(theme.rawValue).png"))
        }
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func color(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB)
    }

    /// Dashboard tour, step 3 (Waiting for you): the rest is dimmed, the card is drawn, in each theme.
    func testDashboardStepInEveryTheme() async throws {
        let model = await DemoSupport.makeModel()
        for theme in [AppTheme.light, .dark, .midnight] {
            AppTheme.current = theme
            let plain = try render("dashboard-plain", theme: theme, size: window) { ShellView(model: model, screen: .dashboard) }
            let t = tutorial(model, screen: .dashboard)
            t.start(.dashboard, at: 2)
            let shot = try render("dashboard-waiting", theme: theme, size: window) { ShellView(model: model, screen: .dashboard, tutorial: t) }
            // The bottom right corner (Activity) is dimmed: darker than without the tour.
            let before = try XCTUnwrap(color(plain, window.width - 20, window.height - 20)), after = try XCTUnwrap(color(shot, window.width - 20, window.height - 20))
            XCTAssertLessThan(after.brightnessComponent, before.brightnessComponent - 0.05, "\(theme) dims")
            XCTAssertEqual(t.active, .dashboard, "\(theme): the step's target was found, the tour is still on")
        }
    }

    func testWelcome() throws {
        let model = PanelModel.isolatedForTests()
        for theme in [AppTheme.light, .dark] {
            let t = tutorial(model, screen: .tasks)
            t.card = .welcome
            _ = try render("welcome", theme: theme, size: window) { ShellView(model: model, screen: .tasks, tutorial: t) }
        }
    }

    /// One step of every tour, in Light (and Dark for the first).
    func testOneStepPerTour() async throws {
        let model = await DemoSupport.makeModel()
        let steps: [(TutorialTourID, Int, ShellScreen)] = [(.firstLaunch, 5, .team), (.chat, 3, .dashboard), (.tasks, 4, .tasks), (.plan, 0, .plan), (.preview, 0, .dashboard)]
        for (id, step, screen) in steps {
            let t = tutorial(model, screen: screen)
            // No question is open in the demo: the chat step shows its dashed example.
            if id == .chat { t.anchorsChanged(host: "seen", Set(TutorialAnchorID.allCases).subtracting([.chatQuestion])) }
            t.start(id, at: step)
            _ = try render("tour-\(id.rawValue)", theme: .light, size: window) { ShellView(model: model, screen: screen, tutorial: t) }
            if id == .firstLaunch { _ = try render("tour-\(id.rawValue)", theme: .dark, size: window) { ShellView(model: model, screen: screen, tutorial: t) } }
        }
        // Settings is drawn on its own: the window builds its settings on first use.
        let t = tutorial(model, screen: .settings)
        t.start(.settings, at: 2)
        _ = try render("tour-settings", theme: .light, size: CGSize(width: 1200, height: 760)) {
            SettingsView(flow: model.makeSettingsFlow(), onCleanup: {}).environment(t).tutorialHost(t, name: TutorialOverlay.windowHost)
        }
    }

    func testToursPopover() throws {
        let t = TutorialModel(store: TutorialStore(defaults: makeTestDefaults(prefix: "tutorial-shot")), screen: .dashboard)
        t.start(.firstLaunch); while t.active != nil { t.next() }
        t.start(.dashboard); while t.active != nil { t.next() }
        t.start(.chat); t.skip()
        t.start(.tasks, at: 3); t.pause()
        for theme in [AppTheme.light, .dark] {
            _ = try render("popover", theme: theme, size: CGSize(width: 340, height: 420)) {
                TutorialPanel(model: t, screen: .dashboard, hasProjects: true).coachCardChrome().padding(20).background(Tok.bg)
            }
        }
        XCTAssertEqual(t.stateLabel(.dashboard), "✓ finished")
        XCTAssertEqual(t.stateLabel(.chat), "skipped · start")
        XCTAssertEqual(t.stateLabel(.tasks), "resume · step 4 of 7")
        XCTAssertEqual(t.stateLabel(.plan), "not started")
    }
}
