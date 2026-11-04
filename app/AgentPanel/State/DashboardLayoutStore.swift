import Foundation

/// A tile the Dashboard grid can show (N342). The PM chat is always there; the rest are added, sized and removed (N343, N344).
enum DashboardWidget: String, CaseIterable, Codable, Hashable {
    case chat, waiting, agents, round, cost, highlights, usage, git, terminal
    /// N385: cards in review, cards back from review, today's PM answers.
    case reviewPackets, fixLoops, pmDecisions

    var title: String {
        switch self {
        case .chat: "PM chat"
        case .waiting: "Waiting for you"
        case .agents: "Agents"
        case .round: "Round"
        case .cost: "Cost"
        case .highlights: "Highlights"
        case .usage: "Plan usage"
        case .git: "Git"
        case .terminal: "Terminal"
        case .reviewPackets: "Review packets"
        case .fixLoops: "Fix loops"
        case .pmDecisions: "PM decisions"
        }
    }

    /// The ⋯ preset nearest the size a widget gets when it is added (`addColumns` × `addRows` is the size itself).
    var defaultSize: DashboardTileSize {
        switch self {
        case .chat: .large
        case .agents, .highlights, .terminal: .tall
        case .waiting, .round, .cost, .usage, .git, .reviewPackets, .fixLoops, .pmDecisions: .small
        }
    }

    /// The size a widget gets when it is added: its preset's, but the Terminal (N359) 3×2, wide enough for a readable screen.
    var addColumns: Int { self == .terminal ? 3 : defaultSize.columns }
    var addRows: Int { self == .terminal ? 2 : defaultSize.rows }

    /// The smallest a tile can be (N344): the chat 3×2, the Terminal 2×1 (N359), every other widget one cell.
    var minColumns: Int { self == .chat ? 3 : self == .terminal ? 2 : 1 }
    var minRows: Int { self == .chat ? 2 : 1 }
}

/// The ⋯ menu's presets: S 2×1, W 4×1, T 2×2, L 4×2 (columns × rows of the grid).
enum DashboardTileSize: String, CaseIterable, Codable, Hashable {
    case small = "S", wide = "W", tall = "T", large = "L"

    var columns: Int { self == .small || self == .tall ? 2 : 4 }
    var rows: Int { self == .small || self == .wide ? 1 : 2 }
}

/// A rectangle of grid cells: the top-left cell and the size in cells.
struct DashboardCellRect: Equatable, Hashable {
    var column: Int
    var row: Int
    var width: Int
    var height: Int

    init(column: Int, row: Int, width: Int, height: Int) {
        self.column = column; self.row = row; self.width = width; self.height = height
    }

    var maxColumn: Int { column + width }
    var maxRow: Int { row + height }
    var area: Int { width * height }
    var isInGrid: Bool {
        column >= 0 && row >= 0 && width >= 1 && height >= 1 && maxColumn <= DashboardGridLayout.columns && maxRow <= DashboardGridLayout.rows
    }

    func intersects(_ o: DashboardCellRect) -> Bool {
        column < o.maxColumn && o.column < maxColumn && row < o.maxRow && o.row < maxRow
    }
}

struct DashboardTile: Equatable, Hashable {
    let widget: DashboardWidget
    var rect: DashboardCellRect

    var column: Int { rect.column }
    var row: Int { rect.row }
    var columns: Int { rect.width }
    var rows: Int { rect.height }

    /// The preset this tile's size matches, if any.
    var size: DashboardTileSize? { DashboardTileSize.allCases.first { $0.columns == columns && $0.rows == rows } }
}

/// The placed tiles of the Dashboard (N344): each widget at most once, on a 6×4 grid, never overlapping, never smaller than its
/// minimum, the chat always there. Every layout it is made from is cleaned: a tile that does not fit where it says goes to the first
/// free place of its size, else to the largest free place it fits, else it is left out.
struct DashboardGridLayout: Equatable {
    static let columns = 6
    static let rows = 4

    /// Sorted by place (row, then column), the reading order.
    let tiles: [DashboardTile]

    /// A fresh install's layout (N345): the Balanced preset, which leaves a 2×1 area free so Add works. A stored layout is kept as it is.
    static let `default` = DashboardPreset.balanced.layout

    init(_ tiles: [DashboardTile]) {
        var seen: Set<DashboardWidget> = []
        var list = tiles.filter { seen.insert($0.widget).inserted }
        let chat = list.firstIndex { $0.widget == .chat }.map { list.remove(at: $0) } ?? Self.default.tiles[0]
        var placed: [DashboardTile] = []
        for t in [chat] + list {
            let want = Self.clamped(t.rect, for: t.widget)
            if let r = Self.free(want, among: placed) ? want : Self.spot(for: t.widget, size: want, among: placed) {
                placed.append(DashboardTile(widget: t.widget, rect: r))
            }
        }
        self.tiles = placed.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    var widgets: [DashboardWidget] { tiles.map(\.widget) }
    func contains(_ widget: DashboardWidget) -> Bool { tiles.contains { $0.widget == widget } }
    func tile(_ widget: DashboardWidget) -> DashboardTile? { tiles.first { $0.widget == widget } }
    func rect(of widget: DashboardWidget) -> DashboardCellRect? { tile(widget)?.rect }

    /// The widgets the gallery can still add (the chat is never listed).
    var missing: [DashboardWidget] { DashboardWidget.allCases.filter { $0 != .chat && !contains($0) } }

    /// Whether any cell is free: the gallery's Add and the "+ Add widget" tile need one.
    var hasRoom: Bool { Self.largestFree(among: tiles) != nil }

    /// Whether a free area is at least `widget`'s minimum (N359: the Terminal needs 2×1), so Add places it.
    func hasRoom(for widget: DashboardWidget) -> Bool {
        Self.largestFree(among: tiles, minWidth: widget.minColumns, minHeight: widget.minRows) != nil
    }

    /// The area the "+ Add widget" tile fills: the largest free one, while a widget is missing.
    var addArea: DashboardCellRect? { missing.isEmpty ? nil : Self.largestFree(among: tiles) }

    /// Whether `rect` is a place `widget` can take: in the grid, at least its minimum, over no other tile.
    func fits(_ widget: DashboardWidget, at rect: DashboardCellRect) -> Bool {
        rect.width >= widget.minColumns && rect.height >= widget.minRows && Self.free(rect, among: tiles.filter { $0.widget != widget })
    }

    /// Whether a ⋯ preset fits at the tile's place (same top-left cell).
    func fits(_ widget: DashboardWidget, preset: DashboardTileSize) -> Bool {
        guard let r = rect(of: widget) else { return false }
        return fits(widget, at: DashboardCellRect(column: r.column, row: r.row, width: preset.columns, height: preset.rows))
    }

    /// The tile's rectangle after moving its edges by whole cells (negative `left`/`top` and positive `right`/`bottom` grow it).
    /// Each edge moves one cell at a time and stops at a neighbour, the grid edge or the minimum size; nothing else moves.
    func resized(_ widget: DashboardWidget, left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0) -> DashboardCellRect? {
        guard var r = rect(of: widget) else { return nil }
        func walk(_ delta: Int, _ step: (inout DashboardCellRect, Int) -> Void) {
            for _ in 0..<abs(delta) {
                var next = r
                step(&next, delta.signum())
                guard fits(widget, at: next) else { return }
                r = next
            }
        }
        walk(right) { $0.width += $1 }
        walk(left) { $0.column += $1; $0.width -= $1 }
        walk(bottom) { $0.height += $1 }
        walk(top) { $0.row += $1; $0.height -= $1 }
        return r
    }

    /// N358, push to shrink: the layout after an edge drag, where a growing edge that meets neighbours shrinks them cell by cell from
    /// that side instead of stopping. Only tiles touching the moved edge shrink; when one would go under its minimum (or the grid
    /// edge is reached) the edge stops there. Computed from this (the drag's starting) layout, so dragging back gives the space back.
    func resized(_ widget: DashboardWidget, pushing: Bool, left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0) -> DashboardGridLayout {
        guard pushing else { return resized(widget, left: left, top: top, right: right, bottom: bottom).map { applying(.place(widget, $0)) } ?? self }
        var list = tiles
        guard let me = list.firstIndex(where: { $0.widget == widget }) else { return self }
        /// `step` moves the edge by ±1; `push` takes one cell off a neighbour on the side the edge grows into.
        func walk(_ delta: Int, _ step: (inout DashboardCellRect, Int) -> Void, _ push: (inout DashboardCellRect) -> Void) {
            for _ in 0..<abs(delta) {
                var next = list[me].rect
                step(&next, delta.signum())
                guard next.isInGrid, next.width >= widget.minColumns, next.height >= widget.minRows else { return }
                var trial = list
                trial[me].rect = next
                for i in trial.indices where i != me && trial[i].rect.intersects(next) {
                    push(&trial[i].rect)
                    let n = trial[i]
                    guard n.columns >= n.widget.minColumns, n.rows >= n.widget.minRows, !n.rect.intersects(next) else { return }
                }
                list = trial
            }
        }
        walk(right, { $0.width += $1 }, { $0.column += 1; $0.width -= 1 })
        walk(left, { $0.column += $1; $0.width -= $1 }, { $0.width -= 1 })
        walk(bottom, { $0.height += $1 }, { $0.row += 1; $0.height -= 1 })
        walk(top, { $0.row += $1; $0.height -= $1 }, { $0.height -= 1 })
        return DashboardGridLayout(list)
    }

    /// The tiles whose rectangles differ in `other` (by widget), with their rectangles there.
    func changed(in other: DashboardGridLayout) -> [DashboardTile] {
        other.tiles.filter { t in rect(of: t.widget) != t.rect }
    }

    /// Where a tile dropped on the free cell (column, row) goes: at its size from that cell (moved left or up to stay on the grid),
    /// else the largest rectangle from that cell that fits it, no larger than its size. Nil when nothing fits.
    func dropped(_ widget: DashboardWidget, column: Int, row: Int) -> DashboardCellRect? {
        guard let r = rect(of: widget) else { return nil }
        let whole = DashboardCellRect(column: min(column, Self.columns - r.width), row: min(row, Self.rows - r.height), width: r.width, height: r.height)
        if fits(widget, at: whole) { return whole }
        let sizes = (1...r.height).flatMap { h in (1...r.width).map { (w: $0, h: h) } }.sorted { ($0.w * $0.h, $0.w) > ($1.w * $1.h, $1.w) }
        return sizes.lazy.map { DashboardCellRect(column: column, row: row, width: $0.w, height: $0.h) }.first { fits(widget, at: $0) }
    }

    /// The layout after one change. A change that does not apply returns the same layout.
    func applying(_ edit: DashboardLayoutEdit) -> DashboardGridLayout {
        var list = tiles
        func index(_ w: DashboardWidget) -> Int? { list.firstIndex { $0.widget == w } }
        switch edit {
        case .add(let w):
            guard w != .chat, !contains(w) else { return self }
            let size = DashboardCellRect(column: 0, row: 0, width: w.addColumns, height: w.addRows)
            guard let r = Self.firstFree(width: size.width, height: size.height, among: tiles)
                    ?? Self.largestFree(among: tiles, minWidth: w.minColumns, minHeight: w.minRows) else { return self }
            list.append(DashboardTile(widget: w, rect: r))
        case .remove(let w):
            guard w != .chat else { return self }
            list.removeAll { $0.widget == w }
        case .resize(let w, let preset):
            guard let i = index(w), fits(w, preset: preset) else { return self }
            list[i].rect.width = preset.columns
            list[i].rect.height = preset.rows
        case .place(let w, let rect):
            guard let i = index(w), fits(w, at: rect) else { return self }
            list[i].rect = rect
        case .placeAll(let moved):
            for t in moved {
                guard let i = index(t.widget), t.rect.isInGrid, t.columns >= t.widget.minColumns, t.rows >= t.widget.minRows else { return self }
                list[i].rect = t.rect
            }
            guard !list.indices.contains(where: { i in list.indices.contains { j in j > i && list[i].rect.intersects(list[j].rect) } }) else { return self }
        case .swap(let a, let b):
            guard a != b, let i = index(a), let j = index(b) else { return self }
            let (ra, rb) = (list[i].rect, list[j].rect)
            guard rb.width >= a.minColumns, rb.height >= a.minRows, ra.width >= b.minColumns, ra.height >= b.minRows else { return self }
            list[i].rect = rb
            list[j].rect = ra
        case .move(let w, let step):
            guard let i = index(w), step != 0 else { return self }
            let r = list[i].rect
            let key = { (c: DashboardCellRect) in c.row * Self.columns + c.column }
            let spots = Self.origins(width: r.width, height: r.height).filter { $0 != r && fits(w, at: $0) }
            let next = step > 0 ? spots.filter { key($0) > key(r) }.min { key($0) < key($1) } : spots.filter { key($0) < key(r) }.max { key($0) < key($1) }
            guard let next else { return self }
            list[i].rect = next
        case .reset:
            return .default
        }
        return DashboardGridLayout(list)
    }

    // MARK: free space

    private static func clamped(_ r: DashboardCellRect, for w: DashboardWidget) -> DashboardCellRect {
        let width = min(max(r.width, w.minColumns), columns), height = min(max(r.height, w.minRows), rows)
        return DashboardCellRect(column: min(max(r.column, 0), columns - width), row: min(max(r.row, 0), rows - height), width: width, height: height)
    }

    private static func free(_ r: DashboardCellRect, among tiles: [DashboardTile]) -> Bool {
        r.isInGrid && !tiles.contains { $0.rect.intersects(r) }
    }

    /// Every place a rectangle of this size can have on the grid, in reading order.
    private static func origins(width: Int, height: Int) -> [DashboardCellRect] {
        guard width <= columns, height <= rows, width >= 1, height >= 1 else { return [] }
        return (0...(rows - height)).flatMap { row in (0...(columns - width)).map { DashboardCellRect(column: $0, row: row, width: width, height: height) } }
    }

    static func firstFree(width: Int, height: Int, among tiles: [DashboardTile]) -> DashboardCellRect? {
        origins(width: width, height: height).first { free($0, among: tiles) }
    }

    /// The largest free rectangle (no wider or taller than given, at least the minimum); ties go to the first in reading order, then the wider.
    static func largestFree(among tiles: [DashboardTile], maxWidth: Int = columns, maxHeight: Int = rows, minWidth: Int = 1, minHeight: Int = 1) -> DashboardCellRect? {
        var best: DashboardCellRect?
        for h in stride(from: min(maxHeight, rows), through: max(minHeight, 1), by: -1) {
            for w in stride(from: min(maxWidth, columns), through: max(minWidth, 1), by: -1) {
                guard let r = firstFree(width: w, height: h, among: tiles) else { continue }
                if let b = best {
                    let earlier = (r.row, r.column) < (b.row, b.column)
                    if r.area > b.area || (r.area == b.area && (earlier || ((r.row, r.column) == (b.row, b.column) && r.width > b.width))) { best = r }
                } else {
                    best = r
                }
            }
        }
        return best
    }

    /// Where a tile that does not fit at its place goes: the first free place of its size, else the largest it fits (shrunk).
    private static func spot(for w: DashboardWidget, size r: DashboardCellRect, among tiles: [DashboardTile]) -> DashboardCellRect? {
        firstFree(width: r.width, height: r.height, among: tiles)
            ?? largestFree(among: tiles, maxWidth: r.width, maxHeight: r.height, minWidth: w.minColumns, minHeight: w.minRows)
    }

    // MARK: stored

    /// What is stored: `[{"id": "chat", "x": 0, "y": 0, "w": 4, "h": 4}, …]`. N342/N343 stored `{"id", "size"}` in order.
    private struct Stored: Codable {
        let id: String
        var size: String? = nil
        var x: Int? = nil, y: Int? = nil, w: Int? = nil, h: Int? = nil
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(tiles.map { Stored(id: $0.widget.rawValue, x: $0.column, y: $0.row, w: $0.columns, h: $0.rows) })) ?? Data()
    }

    /// Nil when the data is not a list at all; unknown ids are dropped. A list without places (N342/N343) is migrated once.
    static func decode(_ data: Data) -> DashboardGridLayout? {
        guard let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return nil }
        let known = stored.compactMap { s in DashboardWidget(rawValue: s.id).map { (s, $0) } }
        if known.allSatisfy({ $0.0.x != nil && $0.0.y != nil && $0.0.w != nil && $0.0.h != nil }) {
            return DashboardGridLayout(known.map { s, w in DashboardTile(widget: w, rect: .init(column: s.x!, row: s.y!, width: s.w!, height: s.h!)) })
        }
        return migrate(known.map { s, w in (w, s.size.flatMap(DashboardTileSize.init(rawValue:)) ?? w.defaultSize) })
    }

    /// N343's ordered list on the 6×4 grid: in order, each tile in the first free place of its N343 size (the chat 4×3), shrinking
    /// to the largest free place when that size has no room; a tile with no free cell left is dropped. N343's default becomes the new default.
    static func migrate(_ list: [(DashboardWidget, DashboardTileSize)]) -> DashboardGridLayout {
        var seen: Set<DashboardWidget> = []
        let list = list.filter { seen.insert($0.0).inserted }
        if list.map(\.0) == [.chat, .waiting, .agents], list[1].1 == .small, list[2].1 == .tall { return .default }
        var placed: [DashboardTile] = []
        for (w, size) in list {
            let want = DashboardCellRect(column: 0, row: 0, width: w == .chat ? 4 : size.columns, height: w == .chat ? 3 : size.rows)
            if let r = spot(for: w, size: want, among: placed) { placed.append(DashboardTile(widget: w, rect: r)) }
        }
        return DashboardGridLayout(placed)
    }

    /// The one-column order of a small window: Waiting, chat, Agents, then the others in reading order.
    var narrowOrder: [DashboardTile] {
        let first: [DashboardWidget] = [.waiting, .chat, .agents]
        return first.compactMap { tile($0) } + tiles.filter { !first.contains($0.widget) }
    }
}

/// The Dashboard's layout, saved app-wide in the app's defaults (not per project).
struct DashboardLayoutStore {
    static let key = "dashboardLayout.v2"
    let defaults: UserDefaults

    init(defaults: UserDefaults = Self.appDefaults()) { self.defaults = defaults }

    /// A UI test run (`--ui-test <folder>`) keeps its own layout, found again by the same folder after a relaunch (N351); else the app's defaults.
    static func appDefaults(uiTestFolder: URL? = PanelModel.uiTestFolder) -> UserDefaults {
        guard let folder = uiTestFolder else { return .standard }
        // N362: an absolute-path domain is a plist in the test's own folder (gone with it), not in ~/Library/Preferences.
        return UserDefaults(suiteName: folder.standardizedFileURL.appendingPathComponent("tentacl-uitest-defaults").path) ?? UserDefaults()
    }

    func load() -> DashboardGridLayout {
        defaults.data(forKey: Self.key).flatMap(DashboardGridLayout.decode) ?? .default
    }

    func save(_ layout: DashboardGridLayout) { defaults.set(layout.encoded(), forKey: Self.key) }

    /// N358: whether tile edges are locked (no drag resizing outside Rearrange). Locked when never set: a first run and an update.
    static let lockKey = "dashboardSizesLocked"
    var sizesLocked: Bool {
        get { defaults.object(forKey: Self.lockKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.lockKey) }
    }

    /// N359: the terminal the Terminal tile shows, per project (`[project id: {pane, label}]`).
    static let terminalKey = "dashboardTerminal.v1"
    func terminalChoice(project: String) -> DashboardTerminalChoice? { terminalChoices[project] }
    func setTerminalChoice(_ choice: DashboardTerminalChoice?, project: String) {
        var all = terminalChoices
        all[project] = choice
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.terminalKey)
    }
    private var terminalChoices: [String: DashboardTerminalChoice] {
        defaults.data(forKey: Self.terminalKey).flatMap { try? JSONDecoder().decode([String: DashboardTerminalChoice].self, from: $0) } ?? [:]
    }

    /// Applies one change and saves the result at once (N343).
    @discardableResult func apply(_ edit: DashboardLayoutEdit, to layout: DashboardGridLayout) -> DashboardGridLayout {
        let next = layout.applying(edit)
        save(next)
        return next
    }
}

/// One change to the Dashboard's tiles: from the gallery, a tile's ⋯ menu, an edge drag or Rearrange.
enum DashboardLayoutEdit: Equatable {
    case add(DashboardWidget)
    case remove(DashboardWidget)
    /// A ⋯ preset at the tile's place, when it fits there.
    case resize(DashboardWidget, DashboardTileSize)
    /// A new rectangle: an edge drag, a resize action or a drop on free cells (N344). Refused when it does not fit.
    case place(DashboardWidget, DashboardCellRect)
    /// N358: several new rectangles at once (an edge drag that pushed neighbours smaller). Refused when any does not fit or two overlap.
    case placeAll([DashboardTile])
    /// Drag one tile onto another: the two swap rectangles when each fits the other's.
    case swap(DashboardWidget, DashboardWidget)
    /// ⌘← / ⌘→ in Rearrange: the previous (-1) or next (+1) free place of the same size, in reading order.
    case move(DashboardWidget, by: Int)
    case reset
}

extension DashboardTileSize {
    var name: String {
        switch self {
        case .small: "Small"
        case .wide: "Wide"
        case .tall: "Tall"
        case .large: "Large"
        }
    }
}

extension DashboardWidget {
    /// The gallery's one sentence.
    var blurb: String {
        switch self {
        case .chat: "Talk to the PM."
        case .waiting: "Questions, reviews and start requests. Opens each one in front."
        case .agents: "Who runs, on which card, for how long."
        case .round: "Goal, progress of the round's cards, time."
        case .cost: "Today and your daily limit."
        case .highlights: "Started, in review, merged, failed. The rest is on Timeline."
        case .usage: "5 hours and week, with your limits marked."
        case .git: "Branch, commits not on GitHub yet, Push."
        case .terminal: "The PM's or an agent's live terminal. Type into it here."
        case .reviewPackets: "Build, tests, shots and diff of each card in review, before you open it."
        case .fixLoops: "Cards back from review, their F-notes and the fix round."
        case .pmDecisions: "What the PM answered today, and what it sent to you."
        }
    }
}
