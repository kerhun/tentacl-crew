import SwiftUI

/// The Settings v2 row pattern (N339): a small title above a card, rows inside separated by hairlines, an optional one-sentence footer.
/// A row is a title (with an optional one-line hint and an ⓘ tooltip) on the left and its control right-aligned on the right.

/// The settings a page shows, collected from its rows (the test that every `SettingsItem` has a visible row reads it).
struct SettingsRowItemsKey: PreferenceKey {
    static let defaultValue: Set<SettingsItem> = []
    static func reduce(value: inout Set<SettingsItem>, nextValue: () -> Set<SettingsItem>) { value.formUnion(nextValue()) }
}

extension View {
    /// Marks this view as the row of `item` on its category page.
    func settingsItem(_ item: SettingsItem?) -> some View {
        transformPreference(SettingsRowItemsKey.self) { if let item { $0.insert(item) } }
    }
}

struct SettingsGroup<Content: View, Trailing: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(spacing: Tok.Space.s) {
                    if let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.ink2) }
                    Spacer(minLength: Tok.Space.s)
                    trailing().font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
                // The trailing part ends on the rows' right edge (a switch there lines up with the switches below).
                .padding(.leading, 4).padding(.trailing, 14)
            }
            SettingsCard(content: content)
            if let footer {
                Text(footer).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsGroup where Trailing == EmptyView {
    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, footer: footer, trailing: { EmptyView() }, content: content)
    }
}

/// The card of a group: rows stacked with a hairline above each; the first hairline sits under the card's own border.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.top, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane)
            .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}

/// One row of a card: the hairline above it, then title and hint left, control right.
struct SettingsRow<Control: View>: View {
    let title: String
    var hint: String?
    var info: String?
    var item: SettingsItem?
    /// The hint is a path or version (monospaced, cut in the middle).
    var monoHint = false
    var strong = false
    /// The whole row is faded and its control off (a master switch is off).
    var dimmed = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(strong ? Tok.Font.bodyStrong : Tok.Font.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                    if let info { SettingsInfo(text: info) }
                }
                if let hint {
                    Text(hint).font(monoHint ? Tok.Font.mono : Tok.Font.small).foregroundStyle(Tok.ink3)
                        .lineLimit(monoHint ? 1 : nil).truncationMode(.middle).fixedSize(horizontal: false, vertical: !monoHint)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Tok.Space.s) { control() }.fixedSize()
                .disabled(dimmed)
        }
        .opacity(dimmed ? 0.45 : 1)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { SettingsHairline() }
        .settingsItem(item)
    }
}

extension SettingsRow where Control == EmptyView {
    init(title: String, hint: String? = nil, info: String? = nil, item: SettingsItem? = nil, monoHint: Bool = false) {
        self.init(title: title, hint: hint, info: info, item: item, monoHint: monoHint, control: { EmptyView() })
    }
}

/// A row that is not title + control (a warning line, a command box, an install log): the same insets and hairline.
struct SettingsLine<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .top) { SettingsHairline() }
    }
}

struct SettingsHairline: View {
    var body: some View { Rectangle().fill(Tok.line).frame(height: 1) }
}

/// ⓘ with the long note as its tooltip.
struct SettingsInfo: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Tok.ink3)
            .help(text).accessibilityLabel(text)
    }
}

/// A switch without its own text; the row's title says what it does, the accessibility label repeats it.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) { self.label = label; _isOn = isOn }

    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).accessibilityLabel(label)
    }
}

/// A stepper whose value sits left of its switch; faded and off while the switch is off.
struct SettingsStepper<V: Strideable>: View where V.Stride: BinaryFloatingPoint {
    let text: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    var on = true

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            Text(text).font(Tok.Font.mono).foregroundStyle(on ? Tok.ink : Tok.ink3).monospacedDigit()
        }
        .fixedSize().disabled(!on).opacity(on ? 1 : 0.45)
    }
}

/// The same, for whole numbers.
struct SettingsIntStepper: View {
    let text: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    var on = true

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            Text(text).font(Tok.Font.mono).foregroundStyle(on ? Tok.ink : Tok.ink3).monospacedDigit()
        }
        .fixedSize().disabled(!on).opacity(on ? 1 : 0.45)
    }
}

/// A small status capsule: a dot and a few words in the tone's colour.
struct SettingsPill: View {
    enum Tone { case go, work, wait, off, warn }
    let text: String
    var tone: Tone = .off

    private var color: Color {
        switch tone {
        case .go: Tok.go
        case .work: Tok.work
        case .wait: Tok.wait
        case .off: Tok.ink3
        case .warn: Tok.askText
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Tok.Font.small).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// The page's state before its settings: icon, title, subtitle, a pill and a button on the right, and optional lines below
/// (release notes, a warning) in the same card.
struct SettingsStatusCard<Trailing: View, Below: View>: View {
    var icon: String?
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var below: () -> Below

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Tok.work)
                        .frame(width: 40, height: 40)
                        .background(Tok.raise, in: RoundedRectangle(cornerRadius: Tok.radius))
                        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tok.ink).textSelection(.enabled)
                    if let subtitle { Text(subtitle).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Tok.Space.s) { trailing() }.fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            below()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane)
        .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}

extension SettingsStatusCard where Below == EmptyView {
    init(icon: String? = nil, title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(icon: icon, title: title, subtitle: subtitle, trailing: trailing, below: { EmptyView() })
    }
}

/// The buttons inside Settings rows: smaller than `PanelButtonStyle`, so a row stays one line high.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, link }
    var kind: Kind = .plain
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: kind == .primary ? .medium : .regular))
            .lineLimit(1).fixedSize()
            .foregroundStyle(kind == .primary ? Tok.bg : kind == .link ? Tok.work : Tok.ink)
            .padding(.horizontal, kind == .link ? 2 : 11).padding(.vertical, 4)
            .background(kind == .primary ? Tok.work : kind == .link ? .clear : Tok.raise, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(kind == .plain ? Tok.line : .clear))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(kind: .primary) }
    static var settingsLink: SettingsButtonStyle { SettingsButtonStyle(kind: .link) }
}
