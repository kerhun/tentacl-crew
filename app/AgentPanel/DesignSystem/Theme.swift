import SwiftUI
import AppKit

/// The user's appearance choice (spec agent-panel-tema-tasarim §4). `system` follows macOS: Light when it is light, Dark when it is dark.
enum AppTheme: String, CaseIterable {
    case system, light, dark, midnight

    /// The selected theme; `Tok` colours read it each time they are resolved. Set from the main thread (the settings flow).
    nonisolated(unsafe) static var current: AppTheme = .dark

    /// The macOS look of the window for this theme (nil = follow the system).
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark, .midnight: NSAppearance(named: .darkAqua)
        }
    }

    func palette(systemIsDark: Bool) -> Palette {
        switch self {
        case .system: systemIsDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        case .midnight: .midnight
        }
    }

    /// Palette for a view's appearance (used by the dynamic `Tok` colours).
    func palette(for appearance: NSAppearance) -> Palette {
        palette(systemIsDark: appearance.name.rawValue.contains("Dark"))
    }

    /// Whether shadows should be light (Light theme) — see `Palette.shadowOpacity`.
    static func read(_ raw: String?) -> AppTheme { raw.flatMap(AppTheme.init(rawValue:)) ?? .dark }
}

/// One colour table: the 31 tokens of spec §1 plus the shadow strength.
struct Palette: Equatable {
    var bg, rail, pane, list, raise, line: UInt32
    var ink, ink2, ink3: UInt32
    var go, goInk, work, wait, stop, ask, askInk, askText: UInt32
    var waitQuestion, waitReview, waitFix, waitStart, you: UInt32
    var code, chrome, chartA, chartAHover, chartB, tintViolet, tintTeal, claude, dotBlue: UInt32
    /// Black at this opacity under shadows (1 = today's dark-theme strength; light themes use less).
    var shadowOpacity: Double

    static let dark = Palette(
        bg: Tok.Hex.bg, rail: Tok.Hex.rail, pane: Tok.Hex.pane, list: Tok.Hex.list, raise: Tok.Hex.raise, line: Tok.Hex.line,
        ink: Tok.Hex.ink, ink2: Tok.Hex.ink2, ink3: Tok.Hex.ink3,
        go: Tok.Hex.go, goInk: Tok.Hex.goInk, work: Tok.Hex.work, wait: Tok.Hex.wait, stop: Tok.Hex.stop,
        ask: Tok.Hex.ask, askInk: Tok.Hex.askInk, askText: Tok.Hex.askText,
        waitQuestion: Tok.Hex.waitQuestion, waitReview: Tok.Hex.waitReview, waitFix: Tok.Hex.waitFix,
        waitStart: Tok.Hex.waitStart, you: Tok.Hex.you,
        code: 0x262A33, chrome: 0x111317, chartA: 0x3D8BE0, chartAHover: 0x5A9FEA, chartB: 0xDB6526,
        tintViolet: 0xA98BF5, tintTeal: 0x3FBFA0, claude: 0xE8956F, dotBlue: 0x6C8CFF, shadowOpacity: 1)

    static let light = Palette(
        bg: 0xF5F5F7, rail: 0xECECF0, pane: 0xFFFFFF, list: 0xFAFAFB, raise: 0xF0F0F3, line: 0xDCDCE2,
        ink: 0x1D1D1F, ink2: 0x55555C, ink3: 0x68686E,
        go: 0x1B7A3A, goInk: 0xFFFFFF, work: 0x0A5CC2, wait: 0x8A5A00, stop: 0xB8233F,
        ask: 0xC2410C, askInk: 0xFFFFFF, askText: 0xB3390A,
        waitQuestion: 0xB04A17, waitReview: 0x2B5FC4, waitFix: 0x7A5E00, waitStart: 0x0B7158, you: 0x6A45D9,
        code: 0xEFEFF3, chrome: 0xE6E6EB, chartA: 0x2F74C8, chartAHover: 0x4A8AD8, chartB: 0xC2561B,
        tintViolet: 0x7B5BE0, tintTeal: 0x0F8A70, claude: 0xB85A33, dotBlue: 0x3F5FD8, shadowOpacity: 0.4)

    static let midnight = Palette(
        bg: 0x121A2C, rail: 0x0D1423, pane: 0x18223A, list: 0x162036, raise: 0x212D49, line: 0x2D3B5C,
        ink: 0xE6EAF3, ink2: 0xA6B0C5, ink3: 0x8D98B2,
        go: 0x5CCB94, goInk: 0x07140D, work: 0x6CA8FF, wait: 0xE9BC5C, stop: 0xF27D78,
        ask: 0xFF6A3D, askInk: 0x1B0C07, askText: 0xFF977D,
        waitQuestion: 0xF4A985, waitReview: 0x8DB8FF, waitFix: 0xE8C766, waitStart: 0x64CFB0, you: 0xB39BFF,
        code: 0x263252, chrome: 0x0B111D, chartA: 0x4D8FE6, chartAHover: 0x6CA8FF, chartB: 0xE0703A,
        tintViolet: 0xB39BFF, tintTeal: 0x4FCBAE, claude: 0xEDA07D, dotBlue: 0x7C9AFF, shadowOpacity: 1)
}

extension Tok {
    /// A colour that reads its value from the selected theme every time it is drawn (no restart on change).
    static func dynamic(_ pick: @escaping (Palette) -> UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = pick(AppTheme.current.palette(for: appearance))
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// Shadow opacity for `base` (today's dark-theme value) under the selected theme.
    static func shadowOpacity(_ base: Double) -> Double {
        base * AppTheme.current.palette(systemIsDark: NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).shadowOpacity
    }
}
