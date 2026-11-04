import Foundation
import CoreGraphics

/// The Terminals screen's panes (N234, board B section 5): 1 to 4 terminals on screen, at most 2 columns × 2 rows, built by dropping a
/// sidebar row on a pane's middle (replace) or edge (split). Each pane shows one terminal and a terminal is in at most one pane.
/// Panes are numbered 1–4 in reading order; one pane has the focus (the keyboard, the ⌘L box, Find and Preview follow it).
struct TerminalPaneLayout: Codable, Equatable {
    static let maxPanes = 4
    /// With Preview open, at most this many terminal panes stay on screen.
    static let maxPanesWithPreview = 2

    /// `row`: side by side (a vertical divider); `column`: stacked (a horizontal divider).
    enum Axis: String, Codable { case row, column }
    /// Where a drop lands on a pane: its middle replaces the terminal, an edge splits the pane that way.
    enum Zone: String, Codable { case center, left, right, top, bottom }

    indirect enum Node: Codable, Equatable {
        case pane(id: Int, terminal: String)
        /// `ratio`: the first child's share of the split (a divider drag changes it).
        case split(Axis, Node, Node, ratio: Double)
    }

    private(set) var root: Node
    private(set) var focused: Int
    private var nextID: Int

    init(terminal: String) {
        root = .pane(id: 1, terminal: terminal)
        focused = 1
        nextID = 2
    }

    init(root: Node, focused: Int) {
        self.root = root
        let ids = root.leaves.map(\.id)
        self.focused = ids.contains(focused) ? focused : ids.first ?? 1
        nextID = (ids.max() ?? 0) + 1
    }

    // MARK: reading

    struct Pane: Equatable, Identifiable {
        let id: Int
        let terminal: String
        /// 1–4, reading order.
        let number: Int
        /// The pane's place in the unit square, from equal shares (a divider drag does not renumber).
        let rect: CGRect
    }

    /// The panes in reading order: top to bottom, then left to right.
    var panes: [Pane] {
        var placed: [(Int, String, CGRect)] = []
        Self.place(root, in: CGRect(x: 0, y: 0, width: 1, height: 1), into: &placed)
        let sorted = placed.sorted { a, b in
            abs(a.2.minY - b.2.minY) > 0.001 ? a.2.minY < b.2.minY : a.2.minX < b.2.minX
        }
        return sorted.enumerated().map { Pane(id: $1.0, terminal: $1.1, number: $0 + 1, rect: $1.2) }
    }

    var count: Int { root.leaves.count }
    var terminals: [String] { panes.map(\.terminal) }
    var focusedPane: Pane? { panes.first { $0.id == focused } ?? panes.first }
    var focusedTerminal: String? { focusedPane?.terminal }
    func pane(showing terminal: String) -> Pane? { panes.first { $0.terminal == terminal } }
    func pane(_ id: Int) -> Pane? { panes.first { $0.id == id } }

    private static func place(_ node: Node, in rect: CGRect, into out: inout [(Int, String, CGRect)]) {
        switch node {
        case .pane(let id, let terminal): out.append((id, terminal, rect))
        case .split(let axis, let a, let b, _):
            let (ra, rb) = axis == .row ? rect.divided(atDistance: rect.width / 2, from: .minXEdge) : rect.divided(atDistance: rect.height / 2, from: .minYEdge)
            place(a, in: ra, into: &out)
            place(b, in: rb, into: &out)
        }
    }

    // MARK: limits

    /// A split that keeps at most 4 panes, 2 columns and 2 rows (and 2 panes while Preview is open).
    func canSplit(_ pane: Int, _ zone: Zone, preview: Bool = false) -> Bool {
        guard zone != .center, root.leaves.contains(where: { $0.id == pane }) else { return false }
        guard count < (preview ? Self.maxPanesWithPreview : Self.maxPanes) else { return false }
        let tried = Self.splitting(root, pane: pane, zone: zone, adding: .pane(id: -1, terminal: ""))
        return tried.columns <= 2 && tried.rows <= 2
    }

    /// The zone a drop really gets: an edge the pane cannot split on falls back to replace.
    func accepted(_ zone: Zone, on pane: Int, preview: Bool = false) -> Zone {
        zone == .center || canSplit(pane, zone, preview: preview) ? zone : .center
    }

    /// The drop zone under a point of a pane of `size`: the outer quarter of each side is its edge, the rest the middle.
    static func zone(at point: CGPoint, in size: CGSize) -> Zone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = point.x / size.width, y = point.y / size.height
        let edges: [(Zone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return .center }
        return nearest.0
    }

    // MARK: changes

    mutating func focus(_ pane: Int) {
        if root.leaves.contains(where: { $0.id == pane }) { focused = pane }
    }

    /// Shows `terminal` in `pane`. A terminal already in another pane swaps with this one (both stay on screen).
    mutating func show(_ terminal: String, in pane: Int) {
        guard let target = root.leaves.first(where: { $0.id == pane }), target.terminal != terminal else { return }
        if let other = root.leaves.first(where: { $0.terminal == terminal }) {
            root = root.replacing(other.id, with: target.terminal)
        }
        root = root.replacing(pane, with: terminal)
    }

    /// A sidebar click or ⌘1…⌘9: the terminal goes into the focused pane (swapping when it is in another one).
    mutating func showInFocused(_ terminal: String) {
        if let pane = focusedPane { show(terminal, in: pane.id) }
    }

    /// Splits `pane` on `zone`'s side with `terminal` in the new pane, which gets the focus. A terminal already on screen moves:
    /// its old pane closes first. Returns false (and changes nothing) when the split is not allowed.
    @discardableResult
    mutating func split(_ pane: Int, _ zone: Zone, with terminal: String, preview: Bool = false) -> Bool {
        guard zone != .center else { show(terminal, in: pane); return true }
        var next = self
        if let old = next.root.leaves.first(where: { $0.terminal == terminal }) {
            guard old.id != pane else { return false }
            next.close(old.id)
        }
        guard next.canSplit(pane, zone, preview: preview) else { return false }
        let id = next.nextID
        next.nextID += 1
        next.root = Self.splitting(next.root, pane: pane, zone: zone, adding: .pane(id: id, terminal: terminal))
        next.focused = id
        self = next
        return true
    }

    /// A drop of a sidebar row on a pane.
    @discardableResult
    mutating func drop(_ terminal: String, on pane: Int, zone: Zone, preview: Bool = false) -> Bool {
        let zone = accepted(zone, on: pane, preview: preview)
        if zone == .center { show(terminal, in: pane); return true }
        return split(pane, zone, with: terminal, preview: preview)
    }

    /// Closes a pane (its agent keeps running). The last pane stays. `focusing`: the pane that had the focus before the click that closed
    /// this one; a × on an unfocused pane also taps it, and the focus must go back to the pane that had it (N245).
    mutating func close(_ pane: Int, focusing keep: Int? = nil) {
        guard count > 1, let removed = root.removing(pane) else { return }
        root = removed
        if focused == pane { focused = panes.first?.id ?? 1 }
        if let keep, keep != pane, root.leaves.contains(where: { $0.id == keep }) { focused = keep }
    }

    /// The toolbar's "Swap 1 ⇄ 2": the terminals of the first two panes in reading order trade places; the focus stays on its pane.
    mutating func swapFirstTwo() {
        let list = panes
        guard list.count >= 2 else { return }
        root = root.replacing(list[0].id, with: list[1].terminal).replacing(list[1].id, with: list[0].terminal)
    }

    /// A saved layout that cannot be shown as it is (N245): nil for repeated pane ids or terminals, an empty terminal, more than 4 panes
    /// or more than 2 columns or rows. A ratio outside 20–80 % (or not a number) is brought back into range.
    func validated() -> TerminalPaneLayout? {
        let leaves = root.leaves
        guard leaves.count <= Self.maxPanes, Set(leaves.map(\.id)).count == leaves.count, Set(leaves.map(\.terminal)).count == leaves.count,
              !leaves.contains(where: { $0.terminal.isEmpty }), root.columns <= 2, root.rows <= 2 else { return nil }
        return TerminalPaneLayout(root: root.clampingRatios(), focused: focused)
    }

    /// What to save after the user changed the shown layout (N245): a pane that `reconciled` filled with another terminal because its own
    /// is missing for now (an agent restarting) keeps the terminal the user had there, unless the user changed that pane.
    func keepingMissingTerminals(saved: TerminalPaneLayout, shown: TerminalPaneLayout) -> TerminalPaneLayout {
        var was: [Int: String] = [:], now: [Int: String] = [:]
        for leaf in saved.root.leaves { was[leaf.id] = leaf.terminal }
        for leaf in shown.root.leaves { now[leaf.id] = leaf.terminal }
        var out = self
        for leaf in root.leaves {
            guard let old = was[leaf.id], let filled = now[leaf.id], old != filled, leaf.terminal == filled,
                  !out.root.leaves.contains(where: { $0.terminal == old }) else { continue }
            out.root = out.root.replacing(leaf.id, with: old)
        }
        return out
    }

    /// ⌥⌘ arrows: the nearest pane on that side of the focused one.
    mutating func moveFocus(_ direction: Zone) {
        guard let from = focusedPane, direction != .center else { return }
        let c = CGPoint(x: from.rect.midX, y: from.rect.midY)
        let candidates = panes.filter { p in
            switch direction {
            case .left: p.rect.midX < c.x - 0.001
            case .right: p.rect.midX > c.x + 0.001
            case .top: p.rect.midY < c.y - 0.001
            case .bottom: p.rect.midY > c.y + 0.001
            case .center: false
            }
        }
        let best = candidates.min { a, b in
            let da = direction == .left || direction == .right ? (abs(a.rect.midX - c.x), abs(a.rect.midY - c.y)) : (abs(a.rect.midY - c.y), abs(a.rect.midX - c.x))
            let db = direction == .left || direction == .right ? (abs(b.rect.midX - c.x), abs(b.rect.midY - c.y)) : (abs(b.rect.midY - c.y), abs(b.rect.midX - c.x))
            return da.1 != db.1 ? da.1 < db.1 : da.0 < db.0
        }
        if let best { focused = best.id }
    }

    /// A divider drag: the split at `path` (see `Node.settingRatio`) gets the new share, kept between 20 and 80 %.
    mutating func setRatio(_ ratio: Double, ofSplitAt path: [Bool]) {
        root = root.settingRatio(min(0.8, max(0.2, ratio)), at: path[...])
    }

    /// Terminals that closed: their panes show the next terminal not on screen, else close. With none left, the first terminal.
    func reconciled(with available: [String]) -> TerminalPaneLayout? {
        guard let first = available.first else { return nil }
        let live = Set(available)
        var next = self
        for leaf in root.leaves where !live.contains(leaf.terminal) {
            let shown = Set(next.root.leaves.map(\.terminal))
            if let free = available.first(where: { !shown.contains($0) }) {
                next.root = next.root.replacing(leaf.id, with: free)
            } else if next.count > 1 {
                next.close(leaf.id)
            } else {
                next.root = next.root.replacing(leaf.id, with: first)
            }
        }
        return next
    }

    /// Preview open: the tree when it has at most 2 panes, else the focused pane with the next one in reading order, stacked.
    func withPreview() -> Node {
        guard count > Self.maxPanesWithPreview, let f = focusedPane else { return root }
        let list = panes
        let other = list[(list.firstIndex(of: f)! + 1) % list.count]
        return .split(.column, .pane(id: f.id, terminal: f.terminal), .pane(id: other.id, terminal: other.terminal), ratio: 0.5)
    }

    /// The first terminal of `order` not on screen (⌘D's new pane).
    func nextFree(in order: [String]) -> String? {
        let shown = Set(terminals)
        return order.first { !shown.contains($0) }
    }

    private static func splitting(_ node: Node, pane: Int, zone: Zone, adding new: Node) -> Node {
        switch node {
        case .pane(let id, _) where id == pane:
            switch zone {
            case .left: return .split(.row, new, node, ratio: 0.5)
            case .right: return .split(.row, node, new, ratio: 0.5)
            case .top: return .split(.column, new, node, ratio: 0.5)
            case .bottom, .center: return .split(.column, node, new, ratio: 0.5)
            }
        case .pane: return node
        case .split(let axis, let a, let b, let ratio):
            return .split(axis, splitting(a, pane: pane, zone: zone, adding: new), splitting(b, pane: pane, zone: zone, adding: new), ratio: ratio)
        }
    }
}

extension TerminalPaneLayout.Node {
    var leaves: [(id: Int, terminal: String)] {
        switch self {
        case .pane(let id, let terminal): [(id, terminal)]
        case .split(_, let a, let b, _): a.leaves + b.leaves
        }
    }

    /// Side by side splits add columns; a stacked split takes its widest child.
    var columns: Int {
        switch self {
        case .pane: 1
        case .split(.row, let a, let b, _): a.columns + b.columns
        case .split(.column, let a, let b, _): max(a.columns, b.columns)
        }
    }

    var rows: Int {
        switch self {
        case .pane: 1
        case .split(.column, let a, let b, _): a.rows + b.rows
        case .split(.row, let a, let b, _): max(a.rows, b.rows)
        }
    }

    func clampingRatios() -> Self {
        switch self {
        case .pane: self
        case .split(let axis, let a, let b, let ratio): .split(axis, a.clampingRatios(), b.clampingRatios(), ratio: ratio.isFinite ? min(0.8, max(0.2, ratio)) : 0.5)
        }
    }

    func replacing(_ pane: Int, with terminal: String) -> Self {
        switch self {
        case .pane(let id, _) where id == pane: .pane(id: id, terminal: terminal)
        case .pane: self
        case .split(let axis, let a, let b, let ratio): .split(axis, a.replacing(pane, with: terminal), b.replacing(pane, with: terminal), ratio: ratio)
        }
    }

    /// The tree without the pane (its sibling takes the split's place); nil when the pane is the whole tree.
    func removing(_ pane: Int) -> Self? {
        switch self {
        case .pane(let id, _): return id == pane ? nil : self
        case .split(let axis, let a, let b, let ratio):
            guard let a2 = a.removing(pane) else { return b }
            guard let b2 = b.removing(pane) else { return a }
            return .split(axis, a2, b2, ratio: ratio)
        }
    }

    /// `path`: false = first child, true = second, from the root down to the split.
    func settingRatio(_ value: Double, at path: ArraySlice<Bool>) -> Self {
        guard case .split(let axis, let a, let b, let ratio) = self else { return self }
        guard let step = path.first else { return .split(axis, a, b, ratio: value) }
        let rest = path.dropFirst()
        return step ? .split(axis, a, b.settingRatio(value, at: rest), ratio: ratio) : .split(axis, a.settingRatio(value, at: rest), b, ratio: ratio)
    }
}

/// The panes saved per project (`terminals.panes.<project>`, JSON). The values of the single/split/preview layout before N234
/// (`terminals.layout`, `terminals.selected.<project>`, `terminals.previous.<project>`) migrate once: single and preview become one
/// pane with the saved terminal, split two side by side with the one selected before; the per-project keys are then removed
/// (`terminals.layout` was for all projects and stays for the others).
enum TerminalPaneStore {
    static func key(project: String) -> String { "terminals.panes.\(project)" }
    static let sidebarKey = "terminals.sidebarCollapsed"
    static let oldLayoutKey = "terminals.layout"
    static func oldSelectedKey(project: String) -> String { "terminals.selected.\(project)" }
    static func oldPreviousKey(project: String) -> String { "terminals.previous.\(project)" }

    private struct Saved: Codable {
        let root: TerminalPaneLayout.Node
        let focused: Int
    }

    static func load(_ defaults: UserDefaults, project: String) -> TerminalPaneLayout? {
        if let data = defaults.data(forKey: key(project: project)), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            return TerminalPaneLayout(root: saved.root, focused: saved.focused).validated()
        }
        return migrate(defaults, project: project)
    }

    static func save(_ defaults: UserDefaults, project: String, _ layout: TerminalPaneLayout) {
        if let data = try? JSONEncoder().encode(Saved(root: layout.root, focused: layout.focused)) { defaults.set(data, forKey: key(project: project)) }
    }

    private static func migrate(_ defaults: UserDefaults, project: String) -> TerminalPaneLayout? {
        let selected = defaults.string(forKey: oldSelectedKey(project: project))
        let previous = defaults.string(forKey: oldPreviousKey(project: project))
        let old = defaults.object(forKey: oldLayoutKey) as? String
        defaults.removeObject(forKey: oldSelectedKey(project: project))
        defaults.removeObject(forKey: oldPreviousKey(project: project))
        guard let selected else { return nil }
        var layout = TerminalPaneLayout(terminal: selected)
        if old == "split", let previous, previous != selected {
            layout.split(1, .right, with: previous)
            layout.focus(1)
        }
        save(defaults, project: project, layout)
        return layout
    }

    static func sidebarCollapsed(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: sidebarKey) }
    static func setSidebarCollapsed(_ defaults: UserDefaults, _ value: Bool) { defaults.set(value, forKey: sidebarKey) }
}
