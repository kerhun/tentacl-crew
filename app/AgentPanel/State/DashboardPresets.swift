import Foundation

/// N345: the ready-made Dashboard layouts the widget menu offers. Each one is a whole 6×4 layout (cell rectangles); applying one replaces
/// the current layout. A layout that equals none of them is "Custom", which is never stored.
enum DashboardPreset: String, CaseIterable, Identifiable {
    case balanced, focus, team, cost

    var id: String { rawValue }

    var name: String {
        switch self {
        case .balanced: "Balanced"
        case .focus: "Focus"
        case .team: "Team watch"
        case .cost: "Cost"
        }
    }

    var help: String {
        switch self {
        case .balanced: "PM chat, Waiting for you and Agents, with room for one more widget"
        case .focus: "A large PM chat and Waiting for you, nothing else"
        case .team: "Agents, Round and Waiting for you large, the PM chat smaller"
        case .cost: "Cost, Plan usage and Git, the PM chat medium, Waiting for you small"
        }
    }

    /// The tiles, as cell rectangles on the 6×4 grid (column, row, width, height).
    var tiles: [DashboardTile] {
        func t(_ w: DashboardWidget, _ c: Int, _ r: Int, _ width: Int, _ height: Int) -> DashboardTile {
            DashboardTile(widget: w, rect: DashboardCellRect(column: c, row: r, width: width, height: height))
        }
        switch self {
        case .balanced:
            // A 2×1 free area at the bottom right, so a fresh install can add a widget.
            return [t(.chat, 0, 0, 4, 4), t(.waiting, 4, 0, 2, 2), t(.agents, 4, 2, 2, 1)]
        case .focus:
            return [t(.chat, 0, 0, 4, 4), t(.waiting, 4, 0, 2, 4)]
        case .team:
            return [t(.chat, 0, 0, 3, 2), t(.waiting, 3, 0, 3, 2), t(.agents, 0, 2, 3, 2), t(.round, 3, 2, 3, 2)]
        case .cost:
            return [t(.chat, 0, 0, 4, 3), t(.cost, 4, 0, 2, 2), t(.usage, 4, 2, 2, 2), t(.waiting, 0, 3, 2, 1), t(.git, 2, 3, 2, 1)]
        }
    }

    var layout: DashboardGridLayout { DashboardGridLayout(tiles) }

    /// N356: the menu row's second line, naming the widgets in tile order ("Chat · Waiting · Agents").
    var subtitle: String { Self.widgetLine(tiles) }
    static func widgetLine(_ tiles: [DashboardTile]) -> String { tiles.map(\.widget.shortTitle).joined(separator: " · ") }
    /// N356: Custom's second line.
    static let customSubtitle = "Your own layout"

    /// The preset a layout equals (same widgets at the same rectangles), or nil for Custom.
    static func matching(_ layout: DashboardGridLayout) -> DashboardPreset? {
        allCases.first { $0.layout == layout }
    }

    /// The menu item's VoiceOver label and the line announced after applying.
    var accessibilityLabel: String { "Layout: \(name)" }
    var appliedAnnouncement: String { "Layout \(name) applied" }
}

extension DashboardWidget {
    /// N356: the one-word name used in a layout's subtitle.
    var shortTitle: String {
        switch self {
        case .chat: "Chat"
        case .waiting: "Waiting"
        case .usage: "Usage"
        default: title
        }
    }
}

/// What the Undo toast keeps after a preset was applied: the layout before it, restored exactly.
struct DashboardPresetUndo: Equatable {
    let preset: DashboardPreset
    let previous: DashboardGridLayout
    /// How long the toast stays.
    static let seconds: Double = 6
}

extension DashboardLayoutStore {
    /// Replaces the layout with the preset's and saves it at once; the returned undo restores `layout`.
    func apply(_ preset: DashboardPreset, replacing layout: DashboardGridLayout) -> (layout: DashboardGridLayout, undo: DashboardPresetUndo) {
        let next = preset.layout
        save(next)
        return (next, DashboardPresetUndo(preset: preset, previous: layout))
    }

    /// Puts the layout from before the preset back and saves it.
    func undo(_ undo: DashboardPresetUndo) -> DashboardGridLayout {
        save(undo.previous)
        return undo.previous
    }
}
