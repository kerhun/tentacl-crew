import XCTest
import AppKit
@testable import AgentPanel

final class ThemeTests: XCTestCase {
    private func lum(_ h: UInt32) -> Double {
        func c(_ s: UInt32) -> Double { let x = Double((h >> s) & 0xFF) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * c(16) + 0.7152 * c(8) + 0.0722 * c(0)
    }
    private func ratio(_ a: UInt32, _ b: UInt32) -> Double { let x = lum(a), y = lum(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
    private let palettes: [(String, Palette)] = [("dark", .dark), ("light", .light), ("midnight", .midnight)]

    func testTextTokensReadableOnEverySurface() {
        for (name, p) in palettes {
            for surface in [p.bg, p.rail, p.pane, p.list, p.raise] {
                for (token, ink) in [("ink", p.ink), ("ink2", p.ink2), ("ink3", p.ink3), ("go", p.go), ("work", p.work), ("wait", p.wait),
                                     ("stop", p.stop), ("askText", p.askText), ("waitQuestion", p.waitQuestion), ("waitReview", p.waitReview),
                                     ("waitFix", p.waitFix), ("waitStart", p.waitStart), ("you", p.you)] {
                    XCTAssertGreaterThanOrEqual(ratio(ink, surface), 4.5, "\(name) \(token) on \(String(surface, radix: 16))")
                }
            }
            XCTAssertGreaterThanOrEqual(ratio(p.goInk, p.go), 4.5, "\(name) goInk")
            XCTAssertGreaterThanOrEqual(ratio(p.askInk, p.ask), 4.5, "\(name) askInk")
        }
    }

    func testDarkIsTodayExceptInk3() {
        XCTAssertEqual(Palette.dark.bg, 0x14161B)
        XCTAssertEqual(Palette.dark.ink3, 0x8A92A3)
        XCTAssertEqual(Palette.dark.shadowOpacity, 1)
        XCTAssertLessThan(Palette.light.shadowOpacity, 1)
    }

    func testPaletteFollowsThemeAndSystem() {
        XCTAssertEqual(AppTheme.system.palette(systemIsDark: true), .dark)
        XCTAssertEqual(AppTheme.system.palette(systemIsDark: false), .light)
        XCTAssertEqual(AppTheme.midnight.palette(systemIsDark: false), .midnight)
        XCTAssertEqual(AppTheme.light.palette(systemIsDark: true), .light)
    }

    func testDynamicTokenResolvesFromCurrentTheme() {
        let saved = AppTheme.current
        defer { AppTheme.current = saved }
        for (theme, p) in [(AppTheme.dark, Palette.dark), (.light, .light), (.midnight, .midnight)] {
            AppTheme.current = theme
            var rgb: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
            NSApp.appearance = theme.appearance
            (theme.appearance ?? NSAppearance(named: .darkAqua)!).performAsCurrentDrawingAppearance {
                let c = NSColor(Tok.pane).usingColorSpace(.sRGB)!
                rgb = (c.redComponent, c.greenComponent, c.blueComponent)
            }
            XCTAssertEqual(Int((rgb.0 * 255).rounded()), Int(p.pane >> 16 & 0xFF), "\(theme)")
            XCTAssertEqual(Int((rgb.2 * 255).rounded()), Int(p.pane & 0xFF), "\(theme)")
        }
        NSApp.appearance = nil
    }

    func testAppearanceSetting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AppSettingsStore.load(settingsURL: url).appearance, .dark)
        try AppSettingsStore.update(url) { $0["appearance"] = "midnight" }
        XCTAssertEqual(AppSettingsStore.load(settingsURL: url).appearance, .midnight)
        try AppSettingsStore.update(url) { $0["appearance"] = "nonsense" }
        XCTAssertEqual(AppSettingsStore.load(settingsURL: url).appearance, .dark)
    }
}
