import SwiftUI

/// The Terminals toolbar's items, left to right (N327).
enum TerminalToolItem: Hashable, CaseIterable {
    case prompt, swap, filter, broadcast, preview, commands, appearance, backend
}

/// Which items of a row stay in it and which go into its "…" (N327): the toolbar's buttons and the bottom bar's key hints.
/// The row offers every split, widest first, to `ViewThatFits`: the first one whose one-line width fits is shown, so one window
/// width always gives the same split (no jump while the window is dragged).
enum TerminalToolbarFit {
    struct Split<Item: Equatable>: Equatable {
        let bar: [Item]
        let menu: [Item]
    }

    /// The toolbar items shown: Swap only with two panes or more.
    static func items(panes: Int) -> [TerminalToolItem] {
        TerminalToolItem.allCases.filter { $0 != .swap || panes > 1 }
    }

    /// The bottom bar's key hints, left to right; the ones that do not fit drop out whole from the right.
    static let hints = ["⌘1–9 terminal", "⌥⌘ ← → ↑ ↓ pane", "⌘D split · ⌘⇧D down", "⌘P preview", "⌘L prompt", "⌘F find · ⇧⌘F filter"]

    /// A "…" item's title with its key at the end as text; the item itself registers no key (the hidden shortcut group does).
    static func menuTitle(_ title: String, key: String) -> String {
        key.isEmpty ? title : "\(title)   \(key)"
    }

    /// All in the bar first, then one more from the right end into the menu at each step, down to all in the menu. Order is kept.
    static func splits<Item: Equatable>(_ items: [Item]) -> [Split<Item>] {
        (0...items.count).reversed().map { Split(bar: Array(items.prefix($0)), menu: Array(items.dropFirst($0))) }
    }
}
