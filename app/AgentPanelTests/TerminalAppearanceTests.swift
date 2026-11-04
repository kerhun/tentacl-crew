import XCTest
import SwiftUI
import SwiftTerm
@testable import AgentPanel

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults { TestDefaults.make(self, prefix: "terminal-appearance") }

    func testDefaultEqualsTodaysTerminalTheme() {
        let t = TerminalAppearance.default.palette
        XCTAssertEqual(t.background, Tok.Hex.rail)
        XCTAssertEqual(t.foreground, Tok.Hex.ink)
        XCTAssertEqual(t.caret, Tok.Hex.ink2)
        XCTAssertEqual(t.selection, Tok.Hex.line)
        XCTAssertEqual(t.ansi, TerminalTheme.tentaclANSI)
        XCTAssertEqual(t.ansi[1], Tok.Hex.stop)
        XCTAssertEqual(t.ansi[2], Tok.Hex.go)
        XCTAssertEqual(TerminalAppearance.default.size, 12)
        XCTAssertEqual(TerminalAppearance.default.font, .sfMono)
        XCTAssertEqual(TerminalAppearance.default.cursor, .block)
    }

    func testCodableRoundTrip() throws {
        var a = TerminalAppearance()
        a.followApp = false; a.theme = .gruvbox; a.font = .menlo; a.size = 15; a.lineHeight = .relaxed; a.cursor = .bar; a.blink = false; a.padding = .roomy
        XCTAssertEqual(try JSONDecoder().decode(TerminalAppearance.self, from: JSONEncoder().encode(a)), a)
    }

    func testBrokenOrOldStoredValueLoadsDefault() {
        for raw in [Data("not json".utf8), Data(#"{"theme":"nope"}"#.utf8)] {
            let d = freshDefaults()
            d.set(raw, forKey: TerminalAppearanceStore.defaultsKey)
            XCTAssertEqual(TerminalAppearanceStore(defaults: d).appearance, .default)
        }
        let d = freshDefaults()
        d.set("a string", forKey: TerminalAppearanceStore.defaultsKey)
        XCTAssertEqual(TerminalAppearanceStore(defaults: d).appearance, .default)
    }

    func testSizeIsClamped() throws {
        var a = TerminalAppearance()
        a.size = 3; XCTAssertEqual(a.size, 10)
        a.size = 99; XCTAssertEqual(a.size, 20)
        let stored = Data(#"{"theme":"tentacl","font":"sfMono","size":99,"lineHeight":1.35,"cursor":"block","blink":true,"padding":"compact"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(TerminalAppearance.self, from: stored).size, 20)
    }

    func testEveryThemeHas16ColorsAndReadableText() {
        for id in TerminalAppearance.ThemeID.allCases {
            let t = id.palette
            XCTAssertEqual(t.ansi.count, 16, t.name)
            XCTAssertGreaterThanOrEqual(TerminalTheme.contrast(t.foreground, t.background), 4.5, t.name)
        }
        XCTAssertEqual(TerminalAppearance.ThemeID.allCases.map { $0.palette.name }, ["Tentacl Dark", "Tentacl Light", "Tentacl Midnight", "Dracula", "Solarized Dark", "Gruvbox Dark", "One Light"])
        XCTAssertTrue(TerminalAppearance.ThemeID.oneLight.palette.isLight)
    }

    func testFollowAppPicksThePalettePerTheme() {
        typealias T = TerminalAppearance
        XCTAssertEqual(T.followed(.dark, systemIsDark: false), .tentacl)
        XCTAssertEqual(T.followed(.light, systemIsDark: true), .tentaclLight)
        XCTAssertEqual(T.followed(.midnight, systemIsDark: false), .tentaclMidnight)
        XCTAssertEqual(T.followed(.system, systemIsDark: true), .tentacl)
        XCTAssertEqual(T.followed(.system, systemIsDark: false), .tentaclLight)
        let saved = AppTheme.current
        defer { AppTheme.current = saved }
        var a = T()
        XCTAssertTrue(a.followApp)
        for (app, name) in [(AppTheme.dark, "Tentacl Dark"), (.light, "Tentacl Light"), (.midnight, "Tentacl Midnight")] {
            AppTheme.current = app
            XCTAssertEqual(a.palette.name, name)
        }
        // A manual choice wins over the app theme.
        a.followApp = false; a.theme = .dracula
        XCTAssertEqual(a.palette.name, "Dracula")
    }

    func testThemeChangedReappliesOnlyWhenFollowing() {
        let saved = AppTheme.current
        defer { AppTheme.current = saved }
        let store = TerminalAppearanceStore(defaults: freshDefaults())
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        store.addListener { [weak view] next in if let view { next.apply(to: view) } }
        AppTheme.current = .dark
        store.appearance.apply(to: view)
        AppTheme.current = .midnight
        NotificationCenter.default.post(name: TerminalAppearance.themeChanged, object: nil)
        XCTAssertEqual(view.nativeBackgroundColor, TerminalAppearance.ns(0x0D1423))
        store.appearance.followApp = false   // the manual theme (Tentacl Dark) is applied now
        AppTheme.current = .light
        NotificationCenter.default.post(name: TerminalAppearance.themeChanged, object: nil)
        XCTAssertEqual(view.nativeBackgroundColor, TerminalAppearance.ns(Tok.Hex.rail), "manual theme: unchanged")
    }

    func testSystemAppearanceChangeReappliesOnlyForSystemTheme() {
        let saved = AppTheme.current
        defer { AppTheme.current = saved }
        let store = TerminalAppearanceStore(defaults: freshDefaults())
        var calls = 0
        store.addListener { _ in calls += 1 }
        AppTheme.current = .system
        store.systemAppearanceChanged()
        XCTAssertEqual(calls, 1)
        AppTheme.current = .dark
        store.systemAppearanceChanged()
        XCTAssertEqual(calls, 1, "Dark: unchanged")
        AppTheme.current = .system
        store.appearance.followApp = false
        calls = 0
        store.systemAppearanceChanged()
        XCTAssertEqual(calls, 0, "Follow app off: unchanged")
    }

    func testOldSavedThemeStaysManual() throws {
        XCTAssertTrue(try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"size":14}"#.utf8)).followApp)
        XCTAssertTrue(try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"theme":"tentacl"}"#.utf8)).followApp)
        XCTAssertFalse(try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"theme":"dracula"}"#.utf8)).followApp)
    }

    func testMissingFontFallsBackToSFMono() {
        XCTAssertTrue(TerminalAppearance.FontFamily.sfMono.isInstalled)
        XCTAssertTrue(TerminalAppearance.FontFamily.menlo.isInstalled)
        for f in TerminalAppearance.FontFamily.allCases where !f.isInstalled {
            XCTAssertNil(f.nsFont(size: 12))
            var a = TerminalAppearance(); a.font = f
            XCTAssertEqual(a.nsFont().fontName, NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)
        }
    }

    func testStoreSavesNotifiesAndResets() {
        let d = freshDefaults()
        let store = TerminalAppearanceStore(defaults: d)
        var seen: [TerminalAppearance] = []
        let token = store.addListener { seen.append($0) }
        store.appearance.followApp = false; store.appearance.theme = .dracula
        store.appearance.size += 2
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(TerminalAppearanceStore(defaults: d).appearance, store.appearance)
        store.removeListener(token)
        store.reset()
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(TerminalAppearanceStore(defaults: d).appearance, .default)
    }

    func testApplySetsFontColorsAndCursor() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        var a = TerminalAppearance()
        a.followApp = false; a.theme = .oneLight; a.size = 16; a.cursor = .bar; a.blink = false
        a.apply(to: view)
        XCTAssertEqual(view.font.pointSize, 16)
        XCTAssertEqual(view.nativeBackgroundColor, TerminalAppearance.ns(0xFAFAFA))
        XCTAssertEqual(view.nativeForegroundColor, TerminalAppearance.ns(0x383A42))
        XCTAssertEqual(view.caretColor, TerminalAppearance.ns(0x526FFF))
        XCTAssertEqual(view.selectedTextBackgroundColor, TerminalAppearance.ns(0xB9CBF2))
        XCTAssertTrue(view.optionAsMetaKey)
        // The view exposes neither its cursor style nor its palette; the style mapping is tested below.
        XCTAssertEqual(a.cursorStyle, .steadyBar)
    }

    func testOneLightColorsAndSelectionAreReadable() {
        let t = TerminalAppearance.ThemeID.oneLight.palette
        for (i, c) in t.ansi.enumerated() {
            XCTAssertGreaterThanOrEqual(TerminalTheme.contrast(c, t.background), 3, "ansi \(i) \(String(c, radix: 16))")
        }
        XCTAssertGreaterThanOrEqual(TerminalTheme.contrast(t.selection, t.background), 1.5, "selection is visible")
        XCTAssertGreaterThanOrEqual(TerminalTheme.contrast(t.foreground, t.selection), 4.5, "text on selection")
    }

    func testDecodingBlobWithMissingKeysKeepsWhatIsThere() throws {
        let a = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"theme":"dracula","size":15}"#.utf8))
        XCTAssertEqual(a.theme, .dracula)
        XCTAssertEqual(a.size, 15)
        XCTAssertEqual(a.font, .sfMono)
        XCTAssertEqual(a.cursor, .block)
        XCTAssertTrue(a.blink)
        XCTAssertEqual(try JSONDecoder().decode(TerminalAppearance.self, from: Data("{}".utf8)), .default)
        let d = freshDefaults()
        d.set(Data(#"{"theme":"gruvbox"}"#.utf8), forKey: TerminalAppearanceStore.defaultsKey)
        XCTAssertEqual(TerminalAppearanceStore(defaults: d).appearance.theme, .gruvbox)
    }

    func testColorChangeKeepsFontAndProgramsCursor() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        var a = TerminalAppearance()
        a.apply(to: view)
        let font = view.font
        XCTAssertEqual(TerminalAppearance.cursorApplyCount(of: view), 1)
        a.followApp = false; a.theme = .dracula
        a.apply(to: view)
        XCTAssertTrue(view.font === font, "font untouched when only colors change")
        XCTAssertEqual(TerminalAppearance.cursorApplyCount(of: view), 1, "cursor shape (maybe set by the program) untouched")
        XCTAssertEqual(view.nativeBackgroundColor, TerminalAppearance.ns(0x282A36))
        a.size = 16
        a.apply(to: view)
        XCTAssertEqual(view.font.pointSize, 16)
        XCTAssertEqual(TerminalAppearance.cursorApplyCount(of: view), 1)
        a.cursor = .bar
        a.apply(to: view)
        XCTAssertEqual(TerminalAppearance.cursorApplyCount(of: view), 2, "user's new cursor applied")
    }

    func testFontIsFoundByFamily() {
        for f in TerminalAppearance.FontFamily.allCases where f.isInstalled {
            XCTAssertNotNil(f.nsFont(size: 12), f.title)
        }
    }

    func testCursorStyleMapping() {
        var a = TerminalAppearance()
        XCTAssertEqual(a.cursorStyle, .blinkBlock)
        a.cursor = .underline; XCTAssertEqual(a.cursorStyle, .blinkUnderline)
        a.blink = false; XCTAssertEqual(a.cursorStyle, .steadyUnderline)
    }

    func testSnapshots() throws {
        let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"]
        for (theme, name) in [(TerminalAppearance.ThemeID.tentacl, "N235-appearance.png"), (.oneLight, "N235-appearance-light.png")] {
            let store = TerminalAppearanceStore(defaults: freshDefaults())
            store.appearance.followApp = false; store.appearance.theme = theme
            let data = try XCTUnwrap(SnapshotRenderer.render(view: AppearancePanel(store: store), size: CGSize(width: 340, height: 700)))
            XCTAssertGreaterThan(data.count, 8_000)
            if let dir { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        }
    }

    /// N314: the panel with Follow app on, under the Light and Midnight app themes (the tile row shows the palettes).
    func testFollowAppSnapshots() throws {
        let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"]
        let saved = AppTheme.current
        defer { AppTheme.current = saved }
        for (theme, name) in [(AppTheme.light, "N314-follow-light.png"), (.midnight, "N314-follow-midnight.png")] {
            AppTheme.current = theme
            let store = TerminalAppearanceStore(defaults: freshDefaults())
            let t = store.appearance.palette
            let swatch = VStack(alignment: .leading, spacing: 6) {
                Text("$ ls  # \(t.name)").foregroundStyle(t.fg)
                HStack(spacing: 4) { ForEach(0..<16, id: \.self) { Rectangle().fill(Color(hex: t.ansi[$0])).frame(width: 14, height: 14) } }
            }.font(.system(size: 12, design: .monospaced)).padding(16).frame(width: 340, alignment: .leading).background(t.bg)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: VStack(spacing: 0) { swatch; AppearancePanel(store: store) }, size: CGSize(width: 340, height: 880)))
            if let dir { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        }
    }

    /// N241 before/after: One Light's 16 colors and selection as text on its background.
    func testOneLightSwatchSnapshots() throws {
        let t = TerminalAppearance.ThemeID.oneLight.palette
        let old: [UInt32] = [0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0x0184BC, 0xA626A4, 0x0997B3, 0xA0A1A7,
                             0x4F525E, 0xDF6C75, 0x98C379, 0xE4C07A, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF]
        for (name, colors, selection) in [("N241-onelight-before.png", old, UInt32(0xE5E5E6)), ("N241-onelight-after.png", t.ansi, t.selection)] {
            let view = VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<16, id: \.self) { i in
                    Text("\(i)  The quick brown fox  \(String(format: "%.2f", TerminalTheme.contrast(colors[i], t.background)))")
                        .foregroundStyle(SwiftUI.Color(nsColor: TerminalAppearance.ns(colors[i])))
                }
                Text("selected text").foregroundStyle(t.fg).background(SwiftUI.Color(nsColor: TerminalAppearance.ns(selection)))
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(16).frame(width: 360, alignment: .leading).background(t.bg)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 360, height: 420)))
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        }
    }

    /// N263: JetBrains Mono ships in the app, so it is found even where it is not installed.
    func testJetBrainsMonoIsBundled() {
        let f = TerminalAppearance.FontFamily.jetBrainsMono
        XCTAssertTrue(f.isInstalled)
        let font = f.nsFont(size: 13)
        XCTAssertEqual(font?.familyName, "JetBrains Mono")
        XCTAssertNotEqual(font?.fontName, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName)
        var a = TerminalAppearance(); a.font = .jetBrainsMono
        XCTAssertEqual(a.nsFont().familyName, "JetBrains Mono")
    }

    /// N263 snapshot: the same terminal text in the bundled JetBrains Mono and in the default SF Mono.
    func testJetBrainsMonoSnapshot() throws {
        let t = TerminalAppearance.ThemeID.tentacl.palette
        let sample = "func render() -> Bool {\n    return 0 != 1 && a >= b // -> => ==\n}"
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach([TerminalAppearance.FontFamily.jetBrainsMono, .sfMono], id: \.self) { f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title).foregroundStyle(t.dim)
                    Text(sample).font(f.swiftUIFont(size: 13)).foregroundStyle(t.fg)
                }
            }
        }
        .padding(16).frame(width: 420, alignment: .leading).background(t.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 420, height: 200)))
        XCTAssertGreaterThan(data.count, 4_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N263-font.png")) }
    }

    // MARK: N268

    /// Fira Code ships in the app, so it is found and drawn where it is not installed.
    func testFiraCodeIsBundled() {
        let f = TerminalAppearance.FontFamily.firaCode
        XCTAssertTrue(f.isInstalled)
        XCTAssertEqual(f.nsFont(size: 13)?.familyName, "Fira Code")
        var a = TerminalAppearance(); a.font = .firaCode
        XCTAssertEqual(a.nsFont().familyName, "Fira Code")
        XCTAssertFalse(a.nsFont().fontName.contains("SFMono"))
        for file in ["FiraCode-Regular.ttf", "FiraCode-Bold.ttf", "OFL-FiraCode.txt", "OFL-JetBrainsMono.txt"] {
            XCTAssertNotNil(Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: (file as NSString).pathExtension) ?? Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: (file as NSString).pathExtension, subdirectory: "Fonts"), file)
        }
    }

    func testNewSettingsDefaultPersistAndKeepOldBlobs() throws {
        let d = TerminalAppearance()
        XCTAssertFalse(d.ligatures); XCTAssertFalse(d.copyOnSelect); XCTAssertEqual(d.editor, .defaultApp)
        let defaults = freshDefaults()
        let store = TerminalAppearanceStore(defaults: defaults)
        store.appearance.ligatures = true; store.appearance.copyOnSelect = true; store.appearance.editor = .zed
        let again = TerminalAppearanceStore(defaults: defaults).appearance
        XCTAssertTrue(again.ligatures); XCTAssertTrue(again.copyOnSelect); XCTAssertEqual(again.editor, .zed)
        let old = try JSONDecoder().decode(TerminalAppearance.self, from: Data(#"{"theme":"dracula","size":14}"#.utf8))
        XCTAssertEqual(old.theme, .dracula); XCTAssertFalse(old.ligatures); XCTAssertEqual(old.editor, .defaultApp)
    }

    func testLigaturesOffSwitchesTheFontFeaturesOff() {
        var a = TerminalAppearance(); a.font = .firaCode
        XCTAssertTrue(TerminalAppearance.hasLigaturesOff(a.nsFont()))
        XCTAssertEqual(a.nsFont().familyName, "Fira Code")
        a.ligatures = true
        XCTAssertFalse(TerminalAppearance.hasLigaturesOff(a.nsFont()))
    }

    /// SwiftTerm shapes each run with CoreText and the view's font, so the font's features decide: with the toggle on, `->` and `!=` take
    /// Fira Code's ligature glyphs; off, the plain ones. (An offscreen SwiftTerm view draws nothing, so the shaping is checked on the font.)
    func testLigatureChangesTheGlyphsCoreTextPicks() {
        func glyphs(_ ligatures: Bool) -> [CGGlyph] {
            var a = TerminalAppearance(); a.font = .firaCode; a.ligatures = ligatures
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "->  !=  =>", attributes: [.font: a.nsFont()]))
            return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
                [CGGlyph](unsafeUninitializedCapacity: CTRunGetGlyphCount(run)) { buf, n in CTRunGetGlyphs(run, CFRange(), buf.baseAddress!); n = CTRunGetGlyphCount(run) }
            }
        }
        XCTAssertNotEqual(glyphs(true), glyphs(false))
    }

    func testFileLinkDetection() throws {
        let dir = NSTemporaryDirectory() + "n268-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir + "/app", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/app/Foo.swift", contents: Data("x".utf8))
        FileManager.default.createFile(atPath: dir + "/path.swift", contents: Data("x".utf8))
        func m(_ w: String) -> TerminalFileLink.Match? { TerminalFileLink.match(word: w, folder: dir) }
        XCTAssertEqual(m("app/Foo.swift:42"), .init(path: dir + "/app/Foo.swift", line: 42, column: nil))
        XCTAssertEqual(m(dir + "/app/Foo.swift:42:7"), .init(path: dir + "/app/Foo.swift", line: 42, column: 7))
        XCTAssertEqual(m("path.swift"), .init(path: dir + "/path.swift", line: nil, column: nil))
        XCTAssertEqual(m("./app/Foo.swift:3:"), .init(path: dir + "/app/Foo.swift", line: 3, column: nil))
        XCTAssertEqual(m("app/Foo.swift."), .init(path: dir + "/app/Foo.swift", line: nil, column: nil))
        XCTAssertNil(m("app/Missing.swift:1"))
        XCTAssertNil(m("app"))                       // a folder is no link
        XCTAssertNil(m("https://example.com/a.swift:1"))
        XCTAssertNil(TerminalFileLink.match(word: "path.swift", folder: nil))
        XCTAssertEqual(TerminalFileLink.word(in: "error: (app/Foo.swift:42:7) bad", at: 12), "app/Foo.swift:42:7")
        XCTAssertNil(TerminalFileLink.word(in: "a  b", at: 2))
    }

    func testEditorLaunch() {
        let m = TerminalFileLink.Match(path: "/p/my dir/Foo.swift", line: 42, column: 7)
        let plain = TerminalFileLink.Match(path: "/p/Foo.swift", line: nil, column: nil)
        XCTAssertEqual(TerminalFileLink.launch(m, editor: .defaultApp), .open(URL(fileURLWithPath: m.path)))
        XCTAssertEqual(TerminalFileLink.launch(m, editor: .vscode), .url(URL(string: "vscode://file/p/my%20dir/Foo.swift:42:7")!))
        XCTAssertEqual(TerminalFileLink.launch(m, editor: .cursor), .url(URL(string: "cursor://file/p/my%20dir/Foo.swift:42:7")!))
        XCTAssertEqual(TerminalFileLink.launch(plain, editor: .vscode), .url(URL(string: "vscode://file/p/Foo.swift")!))
        XCTAssertEqual(TerminalFileLink.launch(m, editor: .xcode), .run("/usr/bin/xed", ["-l", "42", m.path]))
        XCTAssertEqual(TerminalFileLink.launch(plain, editor: .xcode), .run("/usr/bin/xed", [plain.path]))
        XCTAssertEqual(TerminalFileLink.launch(m, editor: .zed, zedCLI: "/z/zed"), .run("/z/zed", ["/p/my dir/Foo.swift:42:7"]))
        XCTAssertEqual(TerminalFileLink.launch(m, editor: .zed, zedCLI: nil), .open(URL(fileURLWithPath: m.path)))
    }

    /// The terminal finds the file under a point, and copies a finished selection only when the setting is on.
    func testTerminalFileLinkAndCopyOnSelect() throws {
        let dir = NSTemporaryDirectory() + "n268v-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir + "/app", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/app/Foo.swift", contents: Data("x".utf8))
        let view = LiveTerminalNSView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.folder = dir
        view.feedQuiet(Array("first line\r\nsee app/Foo.swift:42 now\r\n".utf8))
        let dims = view.terminalDimensions
        let size = view.getOptimalFrameSize().size
        let scroller = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let (w, h) = ((size.width - scroller) / CGFloat(dims.cols), size.height / CGFloat(dims.rows))
        func point(col: Int, row: Int) -> NSPoint { NSPoint(x: (CGFloat(col) + 0.5) * w, y: view.bounds.height - (CGFloat(row) + 0.5) * h) }
        XCTAssertEqual(view.fileLink(at: point(col: 8, row: 1)), .init(path: dir + "/app/Foo.swift", line: 42, column: nil))
        XCTAssertNil(view.fileLink(at: point(col: 1, row: 1)))   // "see"
        XCTAssertNil(view.fileLink(at: point(col: 3, row: 0)))   // "first line"

        let saved = NSPasteboard.general.string(forType: .string)
        defer { NSPasteboard.general.clearContents(); if let saved { NSPasteboard.general.setString(saved, forType: .string) } }
        func event(_ type: NSEvent.EventType, col: Int, row: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point(col: col, row: row), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func drag() { view.mouseDown(with: event(.leftMouseDown, col: 0, row: 1)); view.mouseDragged(with: event(.leftMouseDragged, col: 20, row: 1)); view.mouseUp(with: event(.leftMouseUp, col: 20, row: 1)) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("before", forType: .string)
        drag()
        XCTAssertEqual(view.getSelection(), "see app/Foo.swift:42")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "before")
        var a = TerminalAppearance(); a.copyOnSelect = true
        a.apply(to: view)
        XCTAssertTrue(view.copyOnSelect)
        drag()
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.hasPrefix("see app/Foo.swift:42") == true)
    }

    func testAppearanceSnapshotN268() throws {
        var a = TerminalAppearance(); a.font = .firaCode; a.ligatures = true; a.copyOnSelect = true; a.editor = .vscode
        let store = TerminalAppearanceStore(defaults: freshDefaults())
        store.appearance = a
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AppearancePanel(store: store), size: CGSize(width: 340, height: 880)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N268-aa.png")) }
    }
}
