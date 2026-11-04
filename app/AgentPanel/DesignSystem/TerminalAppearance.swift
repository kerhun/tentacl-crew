import SwiftUI
import AppKit
import ObjectiveC
import CoreText
import SwiftTerm

/// The look of every terminal (N235): theme, font, size, cursor, padding. One setting for all terminals; saved in UserDefaults.
/// Default = the terminal as it was before N235: Tentacl Dark, SF Mono 12 pt, block cursor.
struct TerminalAppearance: Codable, Equatable {
    enum ThemeID: String, Codable, CaseIterable { case tentacl, tentaclLight, tentaclMidnight, dracula, solarized, gruvbox, oneLight }
    enum FontFamily: String, Codable, CaseIterable { case sfMono, menlo, jetBrainsMono, firaCode }
    enum LineHeight: Double, Codable, CaseIterable { case tight = 1.2, normal = 1.35, relaxed = 1.5 }
    enum CursorShape: String, Codable, CaseIterable { case block, bar, underline }
    enum Padding: String, Codable, CaseIterable { case compact, comfortable, roomy }
    enum Editor: String, Codable, CaseIterable { case defaultApp, vscode, cursor, xcode, zed }

    static let sizeRange = 10...20
    /// SwiftTerm 1.x has no line spacing (`_lineSpacing` is internal and unused): `lineHeight` is stored but not applied, and the panel hides it.
    static let supportsLineHeight = false

    var theme: ThemeID = .tentacl
    /// The terminal takes the palette of the app theme (N314); a manual theme choice turns it off.
    var followApp: Bool = true
    var font: FontFamily = .sfMono
    var size: Int = 12 { didSet { size = Self.clamp(size) } }
    var lineHeight: LineHeight = .normal
    var cursor: CursorShape = .block
    var blink: Bool = true   // SwiftTerm's own default is a blinking block
    var padding: Padding = .comfortable
    /// Code ligatures (-> != =>) of fonts that have them (N268). Off by default: the terminal draws every character as typed.
    var ligatures: Bool = false
    /// A finished mouse selection goes to the clipboard (N268).
    var copyOnSelect: Bool = false
    /// Where ⌘-click on `path:line` opens the file (N268).
    var editor: Editor = .defaultApp

    static let `default` = TerminalAppearance()

    /// Posted after the app theme changed (`AppTheme.current` set); a store re-applies the Follow-app palette to its terminals.
    static let themeChanged = Notification.Name("TerminalAppearance.themeChanged")

    static func clamp(_ size: Int) -> Int { min(max(size, sizeRange.lowerBound), sizeRange.upperBound) }

    init() {}

    /// A key that is missing keeps its default, so a new field never resets what the user saved; a wrong value still throws.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = TerminalAppearance()
        theme = try c.decodeIfPresent(ThemeID.self, forKey: .theme) ?? d.theme
        // Saved before N314: a theme other than the default was a manual choice, so it stays.
        followApp = try c.decodeIfPresent(Bool.self, forKey: .followApp) ?? (theme == d.theme)
        font = try c.decodeIfPresent(FontFamily.self, forKey: .font) ?? d.font
        size = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .size) ?? d.size)
        lineHeight = try c.decodeIfPresent(LineHeight.self, forKey: .lineHeight) ?? d.lineHeight
        cursor = try c.decodeIfPresent(CursorShape.self, forKey: .cursor) ?? d.cursor
        blink = try c.decodeIfPresent(Bool.self, forKey: .blink) ?? d.blink
        padding = try c.decodeIfPresent(Padding.self, forKey: .padding) ?? d.padding
        ligatures = try c.decodeIfPresent(Bool.self, forKey: .ligatures) ?? d.ligatures
        copyOnSelect = try c.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? d.copyOnSelect
        editor = try c.decodeIfPresent(Editor.self, forKey: .editor) ?? d.editor
    }

    private enum Keys: String, CodingKey { case theme, followApp, font, size, lineHeight, cursor, blink, padding, ligatures, copyOnSelect, editor }

    var palette: TerminalTheme { (followApp ? Self.followed(AppTheme.current, systemIsDark: Self.systemIsDark) : theme).palette }

    /// The terminal theme that goes with an app theme.
    static func followed(_ app: AppTheme, systemIsDark: Bool) -> ThemeID {
        switch app {
        case .light: .tentaclLight
        case .dark: .tentacl
        case .midnight: .tentaclMidnight
        case .system: systemIsDark ? .tentacl : .tentaclLight
        }
    }

    private static var systemIsDark: Bool { NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua }
    var paddingPoints: CGFloat { padding.points }

    /// The font to draw with: the chosen family, or SF Mono when it is not installed.
    /// With ligatures off, the font carries the "ligatures" and "contextual alternates" features switched off (Fira Code makes -> and != with the latter).
    func nsFont() -> NSFont {
        let base = font.nsFont(size: CGFloat(size)) ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        guard !ligatures else { return base }
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: Self.ligaturesOff]), size: base.pointSize) ?? base
    }

    static let ligaturesOff: [[NSFontDescriptor.FeatureKey: Int]] = [
        [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
        [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
    ]

    static func hasLigaturesOff(_ font: NSFont) -> Bool { (font.fontDescriptor.object(forKey: .featureSettings) as? [Any])?.isEmpty == false }

    var cursorStyle: CursorStyle {
        switch (cursor, blink) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    /// Font, colors, caret, 16-color palette and cursor on a SwiftTerm view. Padding is the caller's (SwiftTerm has none): `paddingPoints`.
    @MainActor func apply(to view: TerminalView) {
        let t = palette
        // SwiftTerm's font setter resets the font and clears the selection: only when the face or size changed.
        let wanted = nsFont()
        if view.font.fontName != wanted.fontName || view.font.pointSize != wanted.pointSize || Self.hasLigaturesOff(view.font) != Self.hasLigaturesOff(wanted) { view.font = wanted }
        view.nativeBackgroundColor = Self.ns(t.background)
        view.nativeForegroundColor = Self.ns(t.foreground)
        view.caretColor = Self.ns(t.caret)
        view.selectedTextBackgroundColor = Self.ns(t.selection)
        view.optionAsMetaKey = true
        if let live = view as? LiveTerminalNSView { live.copyOnSelect = copyOnSelect; live.editor = editor }
        view.installColors(t.ansi.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) })
        // A program may have chosen its own shape (DECSCUSR): only a changed cursor setting overrides it.
        if Self.cursorState(of: view)?.style != cursorStyle {
            view.setCursorStyle(cursorStyle)
            Self.setCursorState(.init(style: cursorStyle, count: (Self.cursorState(of: view)?.count ?? 0) + 1), on: view)
        }
    }

    private struct CursorState { let style: CursorStyle; let count: Int }
    private static var cursorKey = 0
    private final class CursorBox { let value: CursorState; init(_ v: CursorState) { value = v } }
    private static func cursorState(of view: TerminalView) -> CursorState? { (objc_getAssociatedObject(view, &cursorKey) as? CursorBox)?.value }
    private static func setCursorState(_ s: CursorState, on view: TerminalView) { objc_setAssociatedObject(view, &cursorKey, CursorBox(s), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }

    /// How often `apply` set the cursor shape on this view (tests).
    static func cursorApplyCount(of view: TerminalView) -> Int { cursorState(of: view)?.count ?? 0 }

    static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension TerminalAppearance.Padding {
    var points: CGFloat { switch self { case .compact: 8; case .comfortable: 16; case .roomy: 26 } }
    var title: String { switch self { case .compact: "Compact"; case .comfortable: "Comfortable"; case .roomy: "Roomy" } }
}

extension TerminalAppearance.Editor {
    var title: String { switch self { case .defaultApp: "Default app"; case .vscode: "VS Code"; case .cursor: "Cursor"; case .xcode: "Xcode"; case .zed: "Zed" } }
}

extension TerminalAppearance.LineHeight {
    var title: String { switch self { case .tight: "Tight"; case .normal: "Normal"; case .relaxed: "Relaxed" } }
}

extension TerminalAppearance.CursorShape {
    var title: String { switch self { case .block: "Block"; case .bar: "Bar"; case .underline: "Underline" } }
}

extension TerminalAppearance.FontFamily {
    var title: String { switch self { case .sfMono: "SF Mono"; case .menlo: "Menlo"; case .jetBrainsMono: "JetBrains Mono"; case .firaCode: "Fira Code" } }

    /// The installed family name; looked up by family, so static and variable-font installs are both found.
    private var familyName: String? {
        switch self { case .sfMono: nil; case .menlo: "Menlo"; case .jetBrainsMono: "JetBrains Mono"; case .firaCode: "Fira Code" }
    }

    /// The fonts shipped in the app (JetBrains Mono, Fira Code; both OFL), registered for this process once, before the first lookup (N263).
    /// An installed copy is not replaced: registering a face that already exists just reports "already registered".
    private static let bundledFontsRegistered: Bool = {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls where url.lastPathComponent.hasPrefix("JetBrainsMono") || url.lastPathComponent.hasPrefix("FiraCode") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// The regular face of the family (nil when the family is not installed).
    private func regularFont(size: CGFloat) -> NSFont? {
        _ = Self.bundledFontsRegistered
        guard let family = familyName,
              let members = NSFontManager.shared.availableMembers(ofFontFamily: family), !members.isEmpty else { return nil }
        // Member = [PostScript name, style name, weight, traits]; prefer "Regular", else the member closest to weight 5.
        let best = members.first { ($0[1] as? String) == "Regular" }
            ?? members.min { abs(($0[2] as? Int ?? 5) - 5) < abs(($1[2] as? Int ?? 5) - 5) }
        return (best?[0] as? String).flatMap { NSFont(name: $0, size: size) }
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    var isInstalled: Bool { familyName == nil || regularFont(size: 12) != nil }

    /// nil when the font is not installed (the caller falls back to SF Mono).
    func nsFont(size: CGFloat) -> NSFont? {
        guard familyName != nil else { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return regularFont(size: size)
    }

    /// The face for the panel's button; the system font when not installed.
    func swiftUIFont(size: CGFloat) -> SwiftUI.Font {
        guard familyName != nil, let font = regularFont(size: size) else { return .system(size: size, design: .monospaced) }
        return .custom(font.fontName, size: size)
    }
}

/// One terminal theme: terminal colors plus `chrome` (pane header / status line) and `line` (dividers) for the screen around it.
struct TerminalTheme: Equatable {
    let name: String
    let background, foreground, caret, selection: UInt32
    /// black red green yellow blue magenta cyan white, then the bright ones.
    let ansi: [UInt32]
    let chrome, line: UInt32
    var isLight: Bool { TerminalTheme.luminance(background) > 0.5 }

    /// Tentacl Dark's 16 colors: the design tokens' hues (the terminal's palette before N235).
    static let tentaclANSI: [UInt32] = [
        0x1A1D23, Tok.Hex.stop, Tok.Hex.go, Tok.Hex.wait, Tok.Hex.work, Tok.Hex.you, Tok.Hex.waitStart, Tok.Hex.ink2,
        Tok.Hex.ink3, 0xFF8A85, 0x6EDCA6, 0xF2CB72, Tok.Hex.waitReview, 0xC3B0FF, 0x7FE0C6, Tok.Hex.ink,
    ]

    /// SwiftUI colors for the pane around the terminal (N236): header, status line, ask dock and the polled text.
    var bg: SwiftUI.Color { SwiftUI.Color(nsColor: TerminalAppearance.ns(background)) }
    var fg: SwiftUI.Color { SwiftUI.Color(nsColor: TerminalAppearance.ns(foreground)) }
    /// Secondary text (titles, meta): the foreground, dimmed.
    var dim: SwiftUI.Color { fg.opacity(0.68) }
    var chromeColor: SwiftUI.Color { SwiftUI.Color(nsColor: TerminalAppearance.ns(chrome)) }
    var lineColor: SwiftUI.Color { SwiftUI.Color(nsColor: TerminalAppearance.ns(line)) }

    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double { let s = Double(v & 0xFF) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

extension TerminalAppearance.ThemeID {
    var palette: TerminalTheme {
        switch self {
        case .tentacl:
            TerminalTheme(name: "Tentacl Dark", background: Tok.Hex.rail, foreground: Tok.Hex.ink, caret: Tok.Hex.ink2, selection: Tok.Hex.line,
                          ansi: TerminalTheme.tentaclANSI, chrome: 0x16181D, line: Tok.Hex.line)
        case .tentaclLight:
            TerminalTheme(name: "Tentacl Light", background: 0xFAFAFB, foreground: 0x1D1D1F, caret: 0x55555C, selection: 0xCFE0FA,
                          ansi: [0x2B2B30, 0xB8233F, 0x1B7A3A, 0x8A5A00, 0x0A5CC2, 0x6A45D9, 0x0B7158, 0x55555C,
                                 0x68686E, 0xC8372A, 0x1F8A44, 0x9E6A00, 0x2B5FC4, 0x7F5BE8, 0x0E8268, 0x1D1D1F],
                          chrome: Palette.light.rail, line: Palette.light.line)
        case .tentaclMidnight:
            TerminalTheme(name: "Tentacl Midnight", background: 0x0D1423, foreground: 0xE6EAF3, caret: 0xA6B0C5, selection: 0x2D3B5C,
                          ansi: [0x18223A, 0xF27D78, 0x5CCB94, 0xE9BC5C, 0x6CA8FF, 0xB39BFF, 0x64CFB0, 0xA6B0C5,
                                 0x7D88A1, 0xFF9A95, 0x7EDDAE, 0xF2CE7A, 0x8DB8FF, 0xC9B8FF, 0x86DEC6, 0xE6EAF3],
                          chrome: Palette.midnight.rail, line: Palette.midnight.line)
        case .dracula:
            TerminalTheme(name: "Dracula", background: 0x282A36, foreground: 0xF8F8F2, caret: 0xF8F8F2, selection: 0x44475A,
                          ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                                 0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF],
                          chrome: 0x21222C, line: 0x3B3E4F)
        case .solarized:
            // Foreground is base1 (not base0): base0 on base03 is 4.4:1.
            TerminalTheme(name: "Solarized Dark", background: 0x002B36, foreground: 0x93A1A1, caret: 0x93A1A1, selection: 0x073642,
                          ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                 0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3],
                          chrome: 0x00252F, line: 0x0E4352)
        case .gruvbox:
            TerminalTheme(name: "Gruvbox Dark", background: 0x282828, foreground: 0xEBDBB2, caret: 0xEBDBB2, selection: 0x504945,
                          ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                                 0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2],
                          chrome: 0x1D2021, line: 0x3C3836)
        case .oneLight:
            TerminalTheme(name: "One Light", background: 0xFAFAFA, foreground: 0x383A42, caret: 0x526FFF, selection: 0xB9CBF2,
                          // Every color is at least 3:1 on FAFAFA (the original One Light brights and white were 1.0 to 2.8:1).
                          ansi: [0x383A42, 0xCA1243, 0x3F7F3E, 0x9A6700, 0x0070A8, 0x8E2090, 0x007A91, 0x696C77,
                                 0x4F525E, 0xD03A35, 0x2F7D32, 0x8A6000, 0x2B6FD6, 0x9B3FBA, 0x007C8A, 0x50535D],
                          chrome: 0xEDEDEE, line: 0xD7D8DC)
        }
    }
}

/// The saved appearance, observable. Views read `appearance`; terminals register a listener to re-apply on change.
/// The app has one: `PanelModel.terminalAppearance`, on the model's defaults (so tests keep their own).
@MainActor @Observable
final class TerminalAppearanceStore {
    static let defaultsKey = "terminal.appearance"

    var appearance: TerminalAppearance {
        didSet {
            guard appearance != oldValue else { return }
            save()
            for handler in listeners.values { handler(appearance) }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listeners: [UUID: (TerminalAppearance) -> Void] = [:]
    @ObservationIgnored private var systemObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(TerminalAppearance.self, from: $0) } ?? .default
        // The block holds the store weakly, so it ends with the store's use.
        NotificationCenter.default.addObserver(forName: TerminalAppearance.themeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyFollowedTheme() }
        }
        // macOS light/dark switch (by hand or by the clock): KVO fires once the new appearance is in effect.
        systemObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.systemAppearanceChanged() }
        }
    }

    /// Calls `handler` after every change; returns a token for `removeListener`.
    @discardableResult
    func addListener(_ handler: @escaping (TerminalAppearance) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    /// Only an app theme of System follows macOS; Light, Dark and Midnight stay as they are.
    func systemAppearanceChanged() {
        if AppTheme.current == .system { reapplyFollowedTheme() }
    }

    /// The listeners re-apply the appearance; its palette is read again, so a followed theme picks up the new app theme.
    private func reapplyFollowedTheme() {
        guard appearance.followApp else { return }
        for handler in listeners.values { handler(appearance) }
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    var listenerCount: Int { listeners.count }

    func reset() { appearance = .default }

    private func save() {
        if let data = try? JSONEncoder().encode(appearance) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
