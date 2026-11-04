import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

/// N313 (theme spec §2–§3): the listed views take every colour from `Tok`, and render in Light and Midnight
/// (set AGENT_PANEL_SNAPSHOT_DIR to write the PNGs).
@MainActor
final class ThemeColourTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let files = [
        "Views/MarkdownText.swift", "Views/PreviewPane.swift", "Views/StatsCharts.swift", "Views/RosterView.swift",
        "Views/Components/StatusDot.swift", "Views/Components/Chip.swift", "Views/DashboardView.swift", "State/ActionHelpers.swift",
        "Views/HistoryView.swift", "Views/NotesPad.swift", "Views/CommandField.swift", "Views/TerminalsView.swift", "Views/ChatThread.swift",
    ]
    /// The web page's own colours inside the preview frame (spec §2: the page is not the app).
    private static let allowed = ["foregroundStyle(Color(hex: 0x6B7280))"]

    override func tearDown() { AppTheme.current = .dark; super.tearDown() }

    func testListedViewsUseNoRawColours() throws {
        let raw = try NSRegularExpression(pattern: #"Color\(hex:|0x[0-9A-Fa-f]{6}\b|Tok\.Hex\.|preferredColorScheme\(|\.black\.opacity\(0"#)
        for file in Self.files {
            let text = try String(contentsOf: root.appendingPathComponent("AgentPanel/\(file)"), encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() where !Self.allowed.contains(where: line.contains) {
                let hit = raw.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                XCTAssertFalse(hit, "\(file):\(n + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    func testTintsFollowTheTheme() {
        for (theme, p) in [(AppTheme.dark, Palette.dark), (.light, .light), (.midnight, .midnight)] {
            AppTheme.current = theme
            XCTAssertEqual(hex(WaitingTint.question.color), p.waitQuestion, "\(theme) question")
            XCTAssertEqual(hex(WaitingTint.git.color), p.ink2, "\(theme) git")
            XCTAssertEqual(hex(StatsColor.blue), p.chartA, "\(theme) chartA")
            XCTAssertEqual(hex(RosterView.claudeColor), p.claude, "\(theme) claude")
            XCTAssertEqual(hex(MarkdownBlockView.inlineCodeFill), p.code, "\(theme) code")
            XCTAssertEqual(hex(TaskPhase.Tone.blue.color), p.dotBlue, "\(theme) dotBlue")
            XCTAssertEqual(WaitingTint.review.hex(in: p), p.waitReview)
        }
        XCTAssertEqual(WaitingTint.fix.hex, Palette.dark.waitFix, "hex stays the Dark table")
    }

    func testShadowsAreLighterInLight() {
        AppTheme.current = .light
        XCTAssertEqual(Tok.shadowOpacity(0.5), 0.5 * Palette.light.shadowOpacity, accuracy: 0.0001)
        AppTheme.current = .midnight
        XCTAssertEqual(Tok.shadowOpacity(0.5), 0.5, accuracy: 0.0001)
    }

    // MARK: screenshots

    func testDashboardInLightAndMidnight() async throws {
        let model = await DemoSupport.makeModel()
        try shots("dashboard", CGSize(width: 1440, height: 860)) { DashboardView(model: model) }
    }

    func testStatsInLightAndMidnight() async throws {
        let model = await DemoSupport.makeModel()
        try shots("stats", CGSize(width: 1440, height: 900)) { StatsView(stats: StatsModel(model: model)).background(Tok.bg) }
    }

    func testChatAndPreviewInLightAndMidnight() throws {
        let entries = [
            ChatEntry(id: "1", kind: .user, text: "Show me the Settings design", time: nil),
            ChatEntry(id: "2", kind: .agent, text: "The page is `design/settings.html`. The same draft as an artifact: https://claude.ai/artifact/6f1e-77a2 (⌘-click opens either in the browser).", time: nil),
        ]
        try shots("chat-preview", CGSize(width: 940, height: 480)) {
            HStack(spacing: 0) {
                ChatThread(place: ChatPlace(), entries: entries, agentLabel: "PM", working: false).padding(12).frame(width: 380).background(Tok.pane)
                Divider().overlay(Tok.line)
                PreviewPane(model: PreviewModel(url: URL(fileURLWithPath: "/work/demo/design/settings.html")), source: nil, cardID: "Chat", onClose: {},
                            fromText: "from the chat").padding(8).frame(width: 560)
            }.background(Tok.pane)
        }
    }

    private func shots<V: View>(_ name: String, _ size: CGSize, _ view: () -> V) throws {
        for theme in [AppTheme.light, .midnight] {
            AppTheme.current = theme
            let scheme: ColorScheme = theme == .light ? .light : .dark
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view().environment(\.colorScheme, scheme), size: size))
            XCTAssertGreaterThan(data.count, 10_000, "\(name) \(theme)")
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            let corner = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh - 4)?.usingColorSpace(.sRGB))
            if theme == .light { XCTAssertGreaterThan(corner.brightnessComponent, 0.8, "\(name) light background") }
            else { XCTAssertGreaterThan(corner.blueComponent, corner.redComponent, "\(name) midnight is blue-dark") }
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N313-\(name)-\(theme.rawValue).png"))
            }
        }
    }

    private func hex(_ c: Color) -> UInt32 {
        let n = NSColor(c).usingColorSpace(.sRGB)!
        func b(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return b(n.redComponent) << 16 | b(n.greenComponent) << 8 | b(n.blueComponent)
    }
}
