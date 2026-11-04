import SwiftUI
import AppKit

/// The Dashboard's calm grid (N344): 6 columns × 4 rows that always fill the area under the header, 16 pt gaps, no page scrolling.
/// Each tile has its own rectangle of cells (`DashboardGridLayout`); its edges and corners resize it by dragging, in whole cells.
/// Only a small window (narrower than `narrowWidth` or rows under `minRow`) falls back to one scrolling column: Waiting, chat, Agents, the rest.
struct DashboardGrid<Tile: View>: View {
    static var gap: CGFloat { 16 }
    /// Rows shorter than this switch to the one-column list.
    static var minRow: CGFloat { 90 }
    static var narrowWidth: CGFloat { 900 }
    /// One column: the height of one row, and the chat's.
    static var narrowRow: CGFloat { 140 }
    static var narrowChatHeight: CGFloat { 520 }

    let layout: DashboardGridLayout
    /// The room the grid has (the area under the header).
    let size: CGSize
    /// The "+ Add widget" tile in the largest free area (N343, N344); nil hides it.
    var onAdd: (() -> Void)? = nil
    /// A new rectangle from a VoiceOver resize action (N344); nil turns those actions off.
    var onPlace: ((DashboardWidget, DashboardCellRect) -> Void)? = nil
    /// N358: the new rectangles after an edge drag (the dragged tile and any neighbours it pushed smaller); nil hides the grab strips
    /// (sizes locked outside Rearrange).
    var onPlaceAll: (([DashboardTile]) -> Void)? = nil
    /// Rearrange: a tile dropped on a free cell (column, row); nil hides the free cells.
    var onDropAt: ((DashboardWidget, Int, Int) -> Void)? = nil
    /// A resize outline drawn as if mid-drag (snapshots).
    var outline: DashboardResizeOutline? = nil
    @ViewBuilder let tile: (DashboardTile) -> Tile
    @State private var drag: DashboardResizeOutline?

    static func isNarrow(size: CGSize) -> Bool { size.width < narrowWidth || rowHeight(height: size.height) < minRow }

    /// One row: the four rows and three gaps share the height.
    static func rowHeight(height: CGFloat) -> CGFloat { ((height - CGFloat(DashboardGridLayout.rows - 1) * gap) / CGFloat(DashboardGridLayout.rows)).rounded(.down) }
    static func columnWidth(width: CGFloat) -> CGFloat { ((width - CGFloat(DashboardGridLayout.columns - 1) * gap) / CGFloat(DashboardGridLayout.columns)).rounded(.down) }

    /// The grid's own height: exactly the four rows (never more than `size.height`, so nothing scrolls).
    static func height(for size: CGSize) -> CGFloat { CGFloat(DashboardGridLayout.rows) * rowHeight(height: size.height) + CGFloat(DashboardGridLayout.rows - 1) * gap }

    var body: some View {
        if Self.isNarrow(size: size) { narrow } else { wide }
    }

    private var wide: some View {
        let column = Self.columnWidth(width: size.width), row = Self.rowHeight(height: size.height)
        let frame = { (r: DashboardCellRect) in
            CGRect(x: CGFloat(r.column) * (column + Self.gap), y: CGFloat(r.row) * (row + Self.gap), width: span(r.width, column), height: span(r.height, row))
        }
        return ZStack(alignment: .topLeading) {
            if let onDropAt { freeCells(frame: frame, onDrop: onDropAt) }
            ForEach(layout.tiles, id: \.widget) { t in
                let f = frame(t.rect)
                tile(t)
                    .frame(width: f.width, height: f.height)
                    .modifier(TileResizeAccess(tile: t, layout: layout, onPlace: onPlace, rearranging: onDropAt != nil))
                    .overlay {
                        if let onPlaceAll {
                            DashboardTileEdges(widget: t.widget, layout: layout, pitch: CGSize(width: column + Self.gap, height: row + Self.gap),
                                               onChange: { drag = $0 }, onCommit: onPlaceAll)
                        }
                    }
                    .offset(x: f.minX, y: f.minY)
            }
            if let onAdd, let area = layout.addArea, drag == nil, outline == nil {
                let f = frame(area)
                DashboardAddTile(action: onAdd).frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
            }
            if let o = drag ?? outline {
                ForEach(o.pushed, id: \.widget) { p in
                    let f = frame(p.rect)
                    DashboardResizeOutlineView(rect: p.rect, pushed: true).frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
                }
                let f = frame(o.rect)
                DashboardResizeOutlineView(rect: o.rect).frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
            }
        }
        .frame(width: max(size.width, 0), height: Self.height(for: size), alignment: .topLeading)
    }

    /// Rearrange: each free cell is a dashed drop place.
    private func freeCells(frame: @escaping (DashboardCellRect) -> CGRect, onDrop: @escaping (DashboardWidget, Int, Int) -> Void) -> some View {
        let cells = (0..<DashboardGridLayout.rows).flatMap { r in (0..<DashboardGridLayout.columns).map { DashboardCellRect(column: $0, row: r, width: 1, height: 1) } }
            .filter { c in !layout.tiles.contains { $0.rect.intersects(c) } }
        return ForEach(cells, id: \.self) { c in
            let f = frame(c)
            DashboardFreeCell { onDrop($0, c.column, c.row) }.frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
        }
    }

    private var narrow: some View {
        VStack(spacing: Self.gap) {
            ForEach(layout.narrowOrder, id: \.widget) { t in
                tile(t).frame(height: Self.narrowHeight(t)).modifier(TileResizeAccess(tile: t, layout: layout, onPlace: nil, rearranging: false))
            }
            if let onAdd, layout.hasRoom { DashboardAddTile(action: onAdd).frame(height: Self.narrowRow) }
        }
        .frame(width: max(size.width, 0))
    }

    /// One column: the chat 520 pt, Waiting for you two rows, the others their own rows (at most two).
    static func narrowHeight(_ t: DashboardTile) -> CGFloat {
        let rows = t.widget == .waiting ? 2 : min(t.rows, 2)
        return t.widget == .chat ? narrowChatHeight : CGFloat(rows) * narrowRow + CGFloat(rows - 1) * gap
    }

    private func span(_ n: Int, _ unit: CGFloat) -> CGFloat { max(CGFloat(n) * unit + CGFloat(n - 1) * Self.gap, 0) }
}

// MARK: N344: resizing by the edges

/// The rectangle a tile would take if the drag ended now, and (N358) the neighbours it pushed smaller with their new rectangles.
struct DashboardResizeOutline: Equatable {
    let widget: DashboardWidget
    let rect: DashboardCellRect
    var pushed: [DashboardTile] = []
}

/// The live outline of the new size: the work colour, and the size in cells. A pushed neighbour's is dashed and fainter.
private struct DashboardResizeOutlineView: View {
    let rect: DashboardCellRect
    var pushed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DashboardTileShell<EmptyView>.radius)
        shape.fill(Tok.work.opacity(pushed ? 0.05 : 0.08))
            .overlay(shape.strokeBorder(Tok.work.opacity(pushed ? 0.7 : 1), style: StrokeStyle(lineWidth: pushed ? 1.5 : 2, dash: pushed ? [6, 4] : [])))
            .overlay(alignment: .bottomTrailing) {
                Text("\(rect.width) × \(rect.height)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Tok.ink)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An edge or a corner of a tile.
enum DashboardTileEdge: CaseIterable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

    /// -1 the left edge, 1 the right edge, 0 neither; `v` likewise for top and bottom.
    var h: Int {
        switch self {
        case .left, .topLeft, .bottomLeft: -1
        case .right, .topRight, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    var v: Int {
        switch self {
        case .top, .topLeft, .topRight: -1
        case .bottom, .bottomLeft, .bottomRight: 1
        case .left, .right: 0
        }
    }

    var alignment: Alignment {
        switch (h, v) {
        case (-1, -1): .topLeading
        case (1, -1): .topTrailing
        case (-1, 1): .bottomLeading
        case (1, 1): .bottomTrailing
        case (-1, _): .leading
        case (1, _): .trailing
        case (_, -1): .top
        default: .bottom
        }
    }

    @available(macOS 15.0, *)
    var position: FrameResizePosition {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .left: .left
            case .right: .right
            case .top: .top
            case .bottom: .bottom
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return v == 0 ? .resizeLeftRight : h == 0 ? .resizeUpDown : .crosshair
    }
}

/// The size of a tile's grab strips (N349).
enum DashboardResizeGrip {
    /// How far a strip reaches beyond the tile: half the gap, so two neighbours' strips meet in its middle.
    static var outside: CGFloat { DashboardGrid<EmptyView>.gap / 2 }
    /// How far it reaches into the tile.
    static var inside: CGFloat { 6 }
    static var thickness: CGFloat { outside + inside }
    /// A corner square: `outside` beyond the tile, `corner - outside` into it.
    static var corner: CGFloat { 24 }
}

/// Invisible grab strips along a tile's edges and squares at its corners: hover shows the resize cursor and lights the edge, a drag
/// resizes the tile in whole cells (N358: a neighbour in the way shrinks, down to its minimum; the grid edge and the minimum stop it).
/// The outlines follow the drag; the end saves every changed tile at once.
/// N349: each strip reaches `outside` (half the 16 pt gap) beyond the tile and `inside` into it, so the whole gap is a grab place and two
/// neighbours' strips meet in its middle. The cursor is SwiftUI's `pointerStyle` (macOS 15) or set on every move (macOS 14): a pushed
/// `NSCursor` was lost whenever AppKit reset its cursor rects (after the first resize the edges showed the arrow).
private struct DashboardTileEdges: View {
    let widget: DashboardWidget
    let layout: DashboardGridLayout
    /// One cell plus one gap, in points.
    let pitch: CGSize
    let onChange: (DashboardResizeOutline?) -> Void
    let onCommit: ([DashboardTile]) -> Void
    @State private var hovered: DashboardTileEdge?
    @State private var dragged: DashboardTileEdge?

    private typealias Grip = DashboardResizeGrip

    var body: some View {
        ZStack {
            if let lit = dragged ?? hovered { DashboardEdgeLight(edge: lit) }
            ForEach(DashboardTileEdge.allCases, id: \.self) { e in
                // Aligned to the tile's side, then moved out by `outside`: `inside` (or `corner - outside`) stays over the tile.
                handle(e)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: e.alignment)
                    .offset(x: CGFloat(e.h) * Grip.outside, y: CGFloat(e.v) * Grip.outside)
            }
        }
    }

    @ViewBuilder private func handle(_ e: DashboardTileEdge) -> some View {
        let corner = e.h != 0 && e.v != 0
        Color.clear.contentShape(Rectangle())
            .frame(width: corner ? Grip.corner : e.h != 0 ? Grip.thickness : nil, height: corner ? Grip.corner : e.v != 0 ? Grip.thickness : nil)
            .padding(e.v == 0 ? .vertical : e.h == 0 ? .horizontal : [], Grip.corner - Grip.outside)
            .modifier(ResizePointer(edge: e))
            .onHover { inside in
                if inside { hovered = e } else if hovered == e { hovered = nil }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragged = e
                    e.cursor.set()
                    let next = target(e, value.translation)
                    onChange(next.rect(of: widget).map { r in
                        DashboardResizeOutline(widget: widget, rect: r, pushed: layout.changed(in: next).filter { $0.widget != widget })
                    })
                }
                .onEnded { value in
                    dragged = nil
                    let moved = layout.changed(in: target(e, value.translation))
                    onChange(nil)
                    if !moved.isEmpty { onCommit(moved) }
                })
            .accessibilityHidden(true)
    }

    /// The layout if the drag ended now, always from the drag's starting layout (dragging back gives pushed cells back).
    private func target(_ e: DashboardTileEdge, _ t: CGSize) -> DashboardGridLayout {
        let dc = Int((t.width / max(pitch.width, 1)).rounded()), dr = Int((t.height / max(pitch.height, 1)).rounded())
        return layout.resized(widget, pushing: true, left: e.h < 0 ? dc : 0, top: e.v < 0 ? dr : 0, right: e.h > 0 ? dc : 0, bottom: e.v > 0 ? dr : 0)
    }
}

/// The resize cursor over a grab strip: SwiftUI's own pointer style where there is one, else set again on every mouse move (so an
/// AppKit cursor-rect reset cannot leave the arrow behind) and the arrow put back on leaving.
private struct ResizePointer: ViewModifier {
    let edge: DashboardTileEdge

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.frameResize(position: edge.position, directions: .all))
        } else {
            content.onContinuousHover { phase in
                if case .active = phase { edge.cursor.set() } else { NSCursor.arrow.set() }
            }
        }
    }
}

/// The hovered (or dragged) edge lit in the work colour on the tile's border; a corner lights both of its sides.
private struct DashboardEdgeLight: View {
    let edge: DashboardTileEdge
    static var width: CGFloat { 3 }

    var body: some View {
        let r = DashboardTileShell<EmptyView>.radius
        ZStack {
            if edge.h != 0 {
                Capsule().fill(Tok.work).frame(width: Self.width).padding(.vertical, r)
                    .frame(maxWidth: .infinity, alignment: edge.h < 0 ? .leading : .trailing).offset(x: CGFloat(edge.h) * Self.width / 2)
            }
            if edge.v != 0 {
                Capsule().fill(Tok.work).frame(height: Self.width).padding(.horizontal, r)
                    .frame(maxHeight: .infinity, alignment: edge.v < 0 ? .top : .bottom).offset(y: CGFloat(edge.v) * Self.width / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// VoiceOver: "name, w by h" and the Wider / Narrower / Taller / Shorter actions (N344).
struct TileResizeAccess: ViewModifier {
    let tile: DashboardTile
    let layout: DashboardGridLayout
    let onPlace: ((DashboardWidget, DashboardCellRect) -> Void)?
    /// Rearrange tiles speak for themselves.
    let rearranging: Bool

    func body(content: Content) -> some View {
        if rearranging {
            content
        } else if let onPlace {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Self.label(tile))
                .accessibilityAction(named: "Wider") { act(onPlace, grow: true, horizontal: true) }
                .accessibilityAction(named: "Narrower") { act(onPlace, grow: false, horizontal: true) }
                .accessibilityAction(named: "Taller") { act(onPlace, grow: true, horizontal: false) }
                .accessibilityAction(named: "Shorter") { act(onPlace, grow: false, horizontal: false) }
        } else {
            content.accessibilityElement(children: .contain).accessibilityLabel(Self.label(tile))
        }
    }

    static func label(_ t: DashboardTile) -> String { "\(t.widget.title), \(t.columns) by \(t.rows)" }

    /// Grows to the right (or down) and, when that side is blocked, to the left (or up); shrinks from the right (or bottom).
    private func act(_ onPlace: (DashboardWidget, DashboardCellRect) -> Void, grow: Bool, horizontal: Bool) {
        let w = tile.widget
        let step = grow ? 1 : -1
        var r = horizontal ? layout.resized(w, right: step) : layout.resized(w, bottom: step)
        if grow, r == tile.rect { r = horizontal ? layout.resized(w, left: -1) : layout.resized(w, top: -1) }
        if let r, r != tile.rect { onPlace(w, r) }
    }
}

/// A free cell in Rearrange: dashed, lit while a tile is dragged over it.
private struct DashboardFreeCell: View {
    let onDrop: (DashboardWidget) -> Void
    @State private var targeted = false
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DashboardTileShell<EmptyView>.radius)
        let cell = shape.fill(targeted ? Tok.work.opacity(0.12) : .clear)
            .overlay(shape.strokeBorder(targeted ? Tok.work : Tok.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .contentShape(shape)
            .accessibilityHidden(true)
        if snapshot {
            cell
        } else {
            cell.dropDestination(for: String.self) { items, _ in
                guard let id = items.first, let w = DashboardWidget(rawValue: id) else { return false }
                onDrop(w)
                return true
            } isTargeted: { targeted = $0 }
        }
    }
}

/// A grid tile: the pane colour, radius 14, no border, 18/20 pt padding and a small title row (title, then a link on the right).
struct DashboardTileShell<Content: View>: View {
    let title: String
    var titleColor: Color = Tok.ink3
    /// N385: a short muted note after the title ("1 ready", "today: 3 answered · 1 sent to you").
    var meta: String? = nil
    var link: String? = nil
    var linkHelp: String = ""
    var onLink: () -> Void = {}
    var linkDisabled = false
    @ViewBuilder let content: () -> Content

    static var radius: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Tok.Space.s) {
                Text(title).font(.system(size: 12, weight: .semibold)).kerning(0.24).foregroundStyle(titleColor)
                    .accessibilityAddTraits(.isHeader)
                if let meta { Text(meta).font(.system(size: 12)).foregroundStyle(Tok.ink3).lineLimit(1).truncationMode(.tail) }
                Spacer(minLength: Tok.Space.s)
                HStack(spacing: menu == nil ? 0 : Self.linkToMoreSpacing) {
                    if let link {
                        Button(link, action: onLink).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tok.ink3)
                            .disabled(linkDisabled).help(linkHelp)
                    }
                    // N360: the ⋯ glyph's right edge sits on the content edge, so every tile's row ends at the same place.
                    if let menu { DashboardTileMoreButton(title: title, menu: menu).padding(.trailing, -Self.moreGlyphInset) }
                }
            }
            .frame(height: Self.titleRowHeight)
            content()
        }
        .padding(.vertical, 18).padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardTile()
    }

    /// N360: one title row height for every tile; title, link and ⋯ are centred in it.
    static var titleRowHeight: CGFloat { 22 }
    /// The empty space either side of the ⋯ glyph inside its 24 pt hit area.
    static var moreGlyphInset: CGFloat { (DashboardTileMoreButton.hitWidth - DashboardTileMoreButton.glyphWidth) / 2 }
    /// Link to ⋯ spacing, so the visible gap from the link's text to the glyph is `Tok.Space.s`.
    static var linkToMoreSpacing: CGFloat { Tok.Space.s - moreGlyphInset }

    @Environment(\.dashboardTileMenu) private var menu
}

// MARK: N343: the ⋯ menu, Rearrange and the add tile

/// What a tile's ⋯ button needs: its widget and size, whether its menu is open, and how to open or close it. Set by the Dashboard
/// on each tile (not the chat); nil leaves the tile without a menu.
struct DashboardTileMenuContext {
    let widget: DashboardWidget
    let isOpen: Bool
    let toggle: () -> Void
}

private struct DashboardTileMenuKey: EnvironmentKey { static let defaultValue: DashboardTileMenuContext? = nil }

extension EnvironmentValues {
    var dashboardTileMenu: DashboardTileMenuContext? {
        get { self[DashboardTileMenuKey.self] }
        set { self[DashboardTileMenuKey.self] = newValue }
    }
}

/// Where each tile's ⋯ button is, so the open menu is drawn under it above the other tiles.
struct DashboardMenuAnchors: PreferenceKey {
    static let defaultValue: [DashboardWidget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [DashboardWidget: Anchor<CGRect>], nextValue: () -> [DashboardWidget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// ⋯ in a tile's title row: always shown (N360), quiet `Tok.ink3`; open, it is `Tok.ink` on a raised chip.
struct DashboardTileMoreButton: View {
    let title: String
    let menu: DashboardTileMenuContext

    static let hitWidth: CGFloat = 24
    /// The width of the 12 pt semibold ellipsis glyph.
    static let glyphWidth: CGFloat = 14

    var body: some View {
        Button(action: menu.toggle) {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(menu.isOpen ? Tok.ink : Tok.ink3)
                .frame(width: Self.hitWidth, height: DashboardTileShell<EmptyView>.titleRowHeight)
                .background(menu.isOpen ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Size and remove")
        .accessibilityLabel("\(title) options")
        .accessibilityValue(menu.isOpen ? "open" : "")
        .anchorPreference(key: DashboardMenuAnchors.self, value: .bounds) { [menu.widget: $0] }
    }
}

/// The ⋯ menu: Size as four small shape buttons (the current one marked) and Remove.
struct DashboardTileMenuView: View {
    let widget: DashboardWidget
    /// The preset the tile's size matches, if any.
    let size: DashboardTileSize?
    /// Whether a preset fits at the tile's place (N344): one that does not is disabled.
    var fits: (DashboardTileSize) -> Bool = { _ in true }
    let onSize: (DashboardTileSize) -> Void
    let onRemove: () -> Void

    static let width: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SIZE").font(.system(size: 10.5)).kerning(0.4).foregroundStyle(Tok.ink3).padding(.horizontal, 9).padding(.top, 4)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                ForEach(DashboardTileSize.allCases, id: \.self) { s in
                    let on = s == size
                    Button { onSize(s) } label: {
                        RoundedRectangle(cornerRadius: 2).fill(on ? Tok.work : Tok.ink3)
                            .frame(width: s.columns == 2 ? 10 : 20, height: s.rows == 1 ? 6 : 14)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(Tok.bg, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Tok.work : Tok.line, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!on && !fits(s))
                    .opacity(on || fits(s) ? 1 : 0.4)
                    .help(on || fits(s) ? s.name : "\(s.name): no room here")
                    .accessibilityLabel("Size \(s.name)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            Button(action: onRemove) {
                Text("Remove").font(.system(size: 12.5)).foregroundStyle(Tok.stop)
                    .padding(.horizontal, 9).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(widget.title)")
        }
        .padding(5)
        .frame(width: Self.width)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tok.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 15, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(widget.title) options")
    }
}

/// A tile in Rearrange (N343): a dashed border, the content quiet and inert; drag it onto another tile to swap them, or with
/// keyboard focus move it with ⌘← / ⌘→.
struct DashboardRearrangeTile<Content: View>: View {
    let tile: DashboardTile
    let onSwap: (DashboardWidget) -> Void
    let onMove: (Int) -> Void
    @ViewBuilder let content: () -> Content
    @State private var targeted = false
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DashboardTileShell<EmptyView>.radius)
        ZStack {
            content().allowsHitTesting(false)
            // A veil, not .opacity: the chat holds a platform text view that a translucent group cannot draw.
            Tok.bg.opacity(0.3).clipShape(shape).contentShape(shape)
        }
        .overlay(
            shape.strokeBorder(targeted || focused ? Tok.work : Tok.ink3.opacity(0.45),
                               style: StrokeStyle(lineWidth: focused ? 2 : 1, dash: targeted || focused ? [] : [5, 4]))
        )
        .modifier(DragSwap(snapshot: snapshot, tile: tile, onSwap: onSwap, targeted: $targeted))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            onMove(press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .help("Drag onto another tile to swap them, or onto free cells to move it. ⌘← ⌘→ move it.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TileResizeAccess.label(tile))
        .accessibilityHint("Drag onto another tile or onto free cells, or use the Move actions.")
        .accessibilityAction(named: "Move back") { onMove(-1) }
        .accessibilityAction(named: "Move on") { onMove(1) }
    }

    @Environment(\.snapshotMode) private var snapshot
}

/// Drag a tile onto another to swap them. Left out in snapshots: the drag source is a platform view a bitmap cannot draw.
private struct DragSwap: ViewModifier {
    let snapshot: Bool
    let tile: DashboardTile
    let onSwap: (DashboardWidget) -> Void
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if snapshot {
            content
        } else {
            content
                .draggable(tile.widget.rawValue) {
                    Text(tile.widget.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tok.ink)
                        .padding(.horizontal, 14).padding(.vertical, 10).background(Tok.raise, in: RoundedRectangle(cornerRadius: 10))
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first, let other = DashboardWidget(rawValue: id), other != tile.widget else { return false }
                    onSwap(other)
                    return true
                } isTargeted: { targeted = $0 }
        }
    }
}

/// The dashed "+ Add widget" tile: it fills the largest free area while a widget is missing.
struct DashboardAddTile: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("+").font(.system(size: 22, weight: .light))
                Text("Add widget").font(.system(size: 12.5))
            }
            .foregroundStyle(hovered ? Tok.ink : Tok.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: DashboardTileShell<EmptyView>.radius)
                .strokeBorder(hovered ? Tok.work : Tok.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open the widget gallery")
        .accessibilityLabel("Add widget")
    }
}

extension View {
    /// The Dashboard tile: the pane colour, rounded 14, no border.
    func dashboardTile() -> some View {
        background(Tok.pane, in: RoundedRectangle(cornerRadius: DashboardTileShell<EmptyView>.radius))
            .clipShape(RoundedRectangle(cornerRadius: DashboardTileShell<EmptyView>.radius))
    }
}
