import SwiftUI

/// The terminal's appearance (N235), for a popover (~340 pt). Every change goes through the store at once. Each choice is clickable on its
/// whole tile, not only on its drawn parts (N266): a plain button's clear background is no hit area without `contentShape`.
struct AppearancePanel: View {
    @Bindable var store: TerminalAppearanceStore

    private var a: TerminalAppearance { store.appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            section("THEME") {
                toggleChip("Follow app", isOn: a.followApp, id: "appearance-follow-app") { store.appearance.followApp.toggle() }
                    .help("The terminal colours change with the app theme (Dark, Light, Midnight)")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Tok.Space.s), GridItem(.flexible(), spacing: Tok.Space.s)], spacing: Tok.Space.s) {
                    ForEach(TerminalAppearance.ThemeID.allCases, id: \.self) { id in themeTile(id) }
                }
            }
            section("FONT") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Tok.Space.s), GridItem(.flexible(), spacing: Tok.Space.s)], spacing: Tok.Space.s) {
                    ForEach(TerminalAppearance.FontFamily.allCases, id: \.self) { f in fontButton(f) }
                }
                toggleChip("Ligatures", isOn: a.ligatures, id: "appearance-ligatures") { store.appearance.ligatures.toggle() }
                    .help("Draw -> != => as one symbol, in fonts that have them (Fira Code, JetBrains Mono)")
            }
            section("SIZE") { sizeRow }
            if TerminalAppearance.supportsLineHeight {
                section("LINE HEIGHT") { segment(TerminalAppearance.LineHeight.allCases, \.lineHeight, title: \.title) }
            }
            section("CURSOR") {
                HStack(spacing: Tok.Space.s) {
                    segment(TerminalAppearance.CursorShape.allCases, \.cursor, title: \.title)
                    toggleChip("Blink", isOn: a.blink, id: "appearance-blink") { store.appearance.blink.toggle() }
                }
            }
            section("PADDING") { segment(TerminalAppearance.Padding.allCases, \.padding, title: \.title) }
            section("SELECTION") {
                toggleChip("Copy on select", isOn: a.copyOnSelect, id: "appearance-copy-on-select") { store.appearance.copyOnSelect.toggle() }
                    .help("A finished mouse selection goes to the clipboard")
            }
            section("OPEN FILE LINKS IN") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tok.Space.s), count: 3), spacing: Tok.Space.s) {
                    ForEach(TerminalAppearance.Editor.allCases, id: \.self) { e in editorButton(e) }
                }
                Text("⌘-click app/Foo.swift:42 in a terminal").font(.system(size: 10)).foregroundStyle(Tok.ink3)
            }
            HStack {
                Button {} label: { Text("Import theme…").font(Tok.Font.small) }
                    .buttonStyle(.plain).foregroundStyle(Tok.ink3).disabled(true)
                    .help("Later: read an iTerm2 or Ghostty theme file")
                Spacer()
                Button { store.reset() } label: { Text("Reset").font(Tok.Font.small) }
                    .buttonStyle(.plain).foregroundStyle(Tok.ink2).disabled(a == .default)
                    .accessibilityIdentifier("appearance-reset")
            }
        }
        .padding(Tok.Space.l)
        .frame(width: 340)
        .background(Tok.pane)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Tok.ink3)
            content()
        }
    }

    private func themeTile(_ id: TerminalAppearance.ThemeID) -> some View {
        let t = id.palette
        let on = !a.followApp && a.theme == id
        return Button { store.appearance.theme = id; store.appearance.followApp = false } label: {
            VStack(alignment: .leading, spacing: 6) {
                // A small live swatch: the theme's own background, a line of its text and four of its colors.
                VStack(alignment: .leading, spacing: 5) {
                    Text("$ ls").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: t.foreground))
                    HStack(spacing: 4) {
                        ForEach([2, 3, 4, 1], id: \.self) { i in Circle().fill(Color(hex: t.ansi[i])).frame(width: 7, height: 7) }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: t.background), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: t.line), lineWidth: 1))
                Text(t.name).font(Tok.Font.small).foregroundStyle(on ? Tok.ink : Tok.ink2)
            }
            .padding(6)
            .background(on ? Tok.raise : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Tok.you : Tok.line, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance-theme-\(id.rawValue)")
    }

    private func fontButton(_ f: TerminalAppearance.FontFamily) -> some View {
        let on = a.font == f
        return Button { store.appearance.font = f } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(f.title).font(f.swiftUIFont(size: 12)).foregroundStyle(on ? Tok.ink : Tok.ink2)
                if !f.isInstalled { Text("not installed").font(.system(size: 10)).foregroundStyle(Tok.wait) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Tok.raise : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Tok.you : Tok.line, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance-font-\(f.rawValue)")
    }

    private func editorButton(_ e: TerminalAppearance.Editor) -> some View {
        let on = a.editor == e
        return Button { store.appearance.editor = e } label: {
            Text(e.title).font(Tok.Font.small).foregroundStyle(on ? Tok.ink : Tok.ink2)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(on ? Tok.raise : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Tok.you : Tok.line, lineWidth: on ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance-editor-\(e.rawValue)")
    }

    private var sizeRow: some View {
        HStack(spacing: Tok.Space.m) {
            stepper("minus", enabled: a.size > TerminalAppearance.sizeRange.lowerBound, id: "appearance-size-down") { store.appearance.size -= 1 }
            Text("\(a.size) pt").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).frame(minWidth: 48)
            stepper("plus", enabled: a.size < TerminalAppearance.sizeRange.upperBound, id: "appearance-size-up") { store.appearance.size += 1 }
        }
    }

    private func stepper(_ symbol: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(enabled ? Tok.ink : Tok.ink3)
                .frame(width: 28, height: 24)
                .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).disabled(!enabled).accessibilityIdentifier(id)
    }

    /// A segmented choice bound to one field of the appearance.
    private func segment<V: Hashable>(_ values: [V], _ key: WritableKeyPath<TerminalAppearance, V>, title: KeyPath<V, String>) -> some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { v in
                let on = a[keyPath: key] == v
                Button { store.appearance[keyPath: key] = v } label: {
                    Text(v[keyPath: title]).font(Tok.Font.small).foregroundStyle(on ? Tok.ink : Tok.ink2)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(on ? Tok.raise : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.line, lineWidth: 1))
    }

    private func toggleChip(_ title: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square").font(.system(size: 11)).foregroundStyle(isOn ? Tok.you : Tok.ink3)
                Text(title).font(Tok.Font.small).foregroundStyle(isOn ? Tok.ink : Tok.ink2)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }
}
