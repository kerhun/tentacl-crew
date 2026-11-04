import XCTest
import SwiftUI
import AppKit
@testable import AgentPanel

/// N345: the ready-made Dashboard layouts, applying one with Undo, the active one (or Custom) in the widget menu, and the shots.
@MainActor
final class DashboardPresetTests: XCTestCase {
    private func rect(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> DashboardCellRect { DashboardCellRect(column: c, row: r, width: w, height: h) }

    func testEveryPresetFitsTheGridWithNoOverlapAndRespectsMinimums() {
        for preset in DashboardPreset.allCases {
            let tiles = preset.tiles
            XCTAssertEqual(preset.layout.tiles.count, tiles.count, "\(preset): no tile was moved or dropped")
            XCTAssertEqual(Set(preset.layout.tiles), Set(tiles), "\(preset): every tile stays where the preset says")
            XCTAssertEqual(tiles.first { $0.widget == .chat }.map { $0.columns >= 3 && $0.rows >= 2 }, true, "\(preset): the chat is there and at least 3×2")
            XCTAssertEqual(Set(tiles.map(\.widget)).count, tiles.count, "\(preset): each widget once")
            for (i, a) in tiles.enumerated() {
                XCTAssertTrue(a.rect.isInGrid, "\(preset): \(a.widget) off the 6×4 grid")
                XCTAssertGreaterThanOrEqual(a.columns, a.widget.minColumns)
                XCTAssertGreaterThanOrEqual(a.rows, a.widget.minRows)
                for b in tiles.dropFirst(i + 1) { XCTAssertFalse(a.rect.intersects(b.rect), "\(preset): \(a.widget) over \(b.widget)") }
            }
        }
        XCTAssertEqual(DashboardPreset.allCases.map(\.name), ["Balanced", "Focus", "Team watch", "Cost"])
        let layouts = DashboardPreset.allCases.map(\.layout)
        for (i, a) in layouts.enumerated() { for b in layouts.dropFirst(i + 1) { XCTAssertNotEqual(a, b, "four different layouts") } }
        XCTAssertEqual(DashboardPreset.focus.layout.widgets, [.chat, .waiting])
        XCTAssertEqual(DashboardPreset.focus.layout.rect(of: .waiting), rect(4, 0, 2, 4), "Waiting alone on the right, full height")
        XCTAssertTrue([.agents, .round, .waiting].allSatisfy { DashboardPreset.team.layout.rect(of: $0)?.area == 6 }, "Team watch: Agents, Round, Waiting large")
        XCTAssertEqual(DashboardPreset.team.layout.rect(of: .chat).map { [$0.width, $0.height] }, [3, 2])
        XCTAssertTrue([.cost, .usage, .git].allSatisfy(DashboardPreset.cost.layout.contains), "Cost: Cost, Plan usage and Git")
    }

    func testBalancedIsTheFreshDefaultWithRoomAndAStoredLayoutIsKept() {
        XCTAssertEqual(DashboardGridLayout.default, DashboardPreset.balanced.layout)
        let defaults = TestDefaults.make(self)
        XCTAssertEqual(DashboardLayoutStore(defaults: defaults).load(), DashboardPreset.balanced.layout, "a fresh install")
        XCTAssertEqual(DashboardGridLayout.default.addArea, rect(4, 3, 2, 1), "a 2×1 free area, so Add works")
        let mine = DashboardGridTests.n344Default
        DashboardLayoutStore(defaults: defaults).save(mine)
        XCTAssertEqual(DashboardLayoutStore(defaults: defaults).load(), mine, "the user's own layout is not changed")
    }

    func testApplyingThenUndoRestoresThePreviousLayoutExactly() {
        let store = DashboardLayoutStore(defaults: TestDefaults.make(self))
        let before = DashboardGridLayout(DashboardGridTests.all.tiles)
        store.save(before)
        let (applied, undo) = store.apply(.focus, replacing: store.load())
        XCTAssertEqual(applied, DashboardPreset.focus.layout)
        XCTAssertEqual(store.load(), DashboardPreset.focus.layout, "saved at once: widgets the preset does not have are removed")
        XCTAssertEqual(undo.previous, before)
        XCTAssertEqual(store.undo(undo), before)
        XCTAssertEqual(store.load(), before, "Undo restores and saves every tile at its rectangle")
        XCTAssertEqual(DashboardPresetUndo.seconds, 6)

        let (team, _) = store.apply(.team, replacing: DashboardPreset.focus.layout)
        XCTAssertTrue(team.contains(.agents) && team.contains(.round), "widgets the preset has are added")
    }

    func testMatchingFindsTheActivePresetAndCustomAfterAResize() {
        for preset in DashboardPreset.allCases { XCTAssertEqual(DashboardPreset.matching(preset.layout), preset) }
        let resized = DashboardPreset.focus.layout.applying(.place(.waiting, rect(4, 0, 2, 3)))
        XCTAssertNotEqual(resized, DashboardPreset.focus.layout)
        XCTAssertNil(DashboardPreset.matching(resized), "Custom")
        XCTAssertNil(DashboardPreset.matching(DashboardPreset.balanced.layout.applying(.add(.git))), "Custom after an add")
        XCTAssertEqual(DashboardPreset.matching(DashboardPreset.team.layout.applying(.remove(.round)).applying(.add(.round))), nil,
                       "a removed and re-added tile lands elsewhere: Custom")
    }

    func testTheLayoutMenuItems() {
        var applied: [DashboardPreset] = []
        let items = DashboardPopMenu.layoutItems(for: DashboardPreset.focus.layout) { applied.append($0) }
        XCTAssertEqual(items.map(\.title), ["Balanced", "Focus", "Team watch", "Cost"])
        XCTAssertEqual(items.map(\.kind), [.check(false), .check(true), .check(false), .check(false)], "the active one is checked")
        XCTAssertEqual(items.map(\.voiceLabel), ["Layout: Balanced", "Layout: Focus", "Layout: Team watch", "Layout: Cost"])
        XCTAssertTrue(items.allSatisfy { $0.thumbnail != nil })
        items[2].action()
        XCTAssertEqual(applied, [.team])
        XCTAssertEqual(DashboardPreset.team.appliedAnnouncement, "Layout Team watch applied")

        let custom = DashboardPopMenu.layoutItems(for: DashboardPreset.focus.layout.applying(.place(.waiting, rect(4, 0, 2, 3))))
        XCTAssertEqual(custom.map(\.title), ["Balanced", "Focus", "Team watch", "Cost", "Custom"])
        XCTAssertEqual(custom.map(\.kind), [.check(false), .check(false), .check(false), .check(false), .check(true)])
        XCTAssertEqual(custom.last?.voiceLabel, "Layout: Custom")
        let menu = DashboardPopMenu.widgetItems(layout: items).map(\.id)
        XCTAssertEqual(Array(menu.prefix(5)), ["add", "rearrange", "lock", "layout", "section.Layout"], "under Add widget…, Rearrange and Lock tile sizes, a divider and the Layout label")
    }

    /// N356: each layout row names its widgets on a second line; Custom says it is your own.
    func testTheLayoutSubtitles() {
        XCTAssertEqual(DashboardPreset.allCases.map(\.subtitle), ["Chat · Waiting · Agents", "Chat · Waiting", "Chat · Waiting · Agents · Round",
                                                                 "Chat · Cost · Usage · Waiting · Git"])
        let items = DashboardPopMenu.layoutItems(for: DashboardPreset.focus.layout.applying(.place(.waiting, rect(4, 0, 2, 3))))
        XCTAssertEqual(items.map(\.subtitle), ["Chat · Waiting · Agents", "Chat · Waiting", "Chat · Waiting · Agents · Round",
                                               "Chat · Cost · Usage · Waiting · Git", "Your own layout"])
        XCTAssertEqual(PopMenuView.width(for: DashboardPopMenu.widgetItems(layout: items)), PopMenuView.wideWidth, "the widget menu widens for the second line")
        XCTAssertEqual(PopMenuView.width(for: DashboardPopMenu.widgetItems()), PopMenuView.width, "menus without subtitles keep their width")
        XCTAssertEqual(DashboardLayoutThumbnail.size, CGSize(width: 44, height: 30))
    }

    /// N356: live-window shots (on-screen NSHostingView, not ImageRenderer) of the open widget menu, Focus active and Custom, light and dark.
    func testTheLiveLayoutMenuShots() async throws {
        let custom = DashboardPreset.focus.layout.applying(.place(.waiting, rect(4, 0, 2, 3)))
        for dark in [false, true] {
            let items = DashboardPopMenu.widgetItems(layout: DashboardPopMenu.layoutItems(for: custom))
            let data = try await liveShot(PopMenuView(label: "Widgets", items: items, onClose: {}), dark: dark)
            XCTAssertGreaterThan(data.count, 10_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N356-layout-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func liveShot(_ menu: PopMenuView, dark: Bool) async throws -> Data {
        let theme = AppTheme.current
        AppTheme.current = dark ? .dark : .light
        defer { AppTheme.current = theme }
        let root = menu.padding(30).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PopMenuView.wideWidth + 60, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: shots (dark, 1440×900) → N345-menu.png, N345-focus.png, N345-team.png

    private func write(_ view: some View, _ name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 900)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N345-\(name).png")) }
    }

    func testTheShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self)
        try write(DashboardView(model: model, layout: .default, popMenu: .widgets), "menu")
        try write(DashboardView(model: model, layout: DashboardPreset.focus.layout), "focus")
        try write(DashboardView(model: model, layout: DashboardPreset.team.layout), "team")
        try write(DashboardView(model: model, layout: DashboardPreset.cost.layout), "cost")
    }
}
