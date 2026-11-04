import XCTest
import SwiftUI
@testable import AgentPanel

/// N342: the Dashboard grid's layout model (stored app-wide), its packing and the tour step that needs the Round tile.
@MainActor
final class DashboardGridTests: XCTestCase {
    private var all: DashboardGridLayout { Self.all }

    /// Every widget on the 6×4 grid, no cell free.
    static var all: DashboardGridLayout {
        DashboardGridLayout([t(.chat, 0, 0, 3, 3), t(.waiting, 3, 0, 2, 2), t(.agents, 5, 0, 1, 2), t(.highlights, 3, 2, 3, 1),
                             t(.round, 0, 3, 2, 1), t(.cost, 2, 3, 1, 1), t(.usage, 3, 3, 2, 1), t(.git, 5, 3, 1, 1)])
    }

    /// N344's default (N345 made Balanced the default): the chat 4×4, Waiting 2×2 and Agents 2×2, no cell free.
    static var n344Default: DashboardGridLayout {
        DashboardGridLayout([t(.chat, 0, 0, 4, 4), t(.waiting, 4, 0, 2, 2), t(.agents, 4, 2, 2, 2)])
    }

    static func t(_ w: DashboardWidget, _ c: Int, _ r: Int, _ width: Int, _ height: Int) -> DashboardTile {
        DashboardTile(widget: w, rect: DashboardCellRect(column: c, row: r, width: width, height: height))
    }

    private func t(_ w: DashboardWidget, _ c: Int, _ r: Int, _ width: Int, _ height: Int) -> DashboardTile { Self.t(w, c, r, width, height) }
    private func rect(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> DashboardCellRect { DashboardCellRect(column: c, row: r, width: w, height: h) }

    /// No overlaps, everything on the grid, each tile at least its minimum, the chat there.
    private func assertValid(_ l: DashboardGridLayout, _ note: String = "", line: UInt = #line) {
        XCTAssertTrue(l.contains(.chat), note, line: line)
        for (i, a) in l.tiles.enumerated() {
            XCTAssertTrue(a.rect.isInGrid, "\(a.widget) off the grid \(note)", line: line)
            XCTAssertGreaterThanOrEqual(a.columns, a.widget.minColumns, note, line: line)
            XCTAssertGreaterThanOrEqual(a.rows, a.widget.minRows, note, line: line)
            for b in l.tiles.dropFirst(i + 1) { XCTAssertFalse(a.rect.intersects(b.rect), "\(a.widget) over \(b.widget) \(note)", line: line) }
        }
    }

    func testTheDefaultLayoutIsChatLeftWaitingAndAgentsRight() {
        let layout = DashboardLayoutStore(defaults: TestDefaults.make(self)).load()
        XCTAssertEqual(layout, .default)
        XCTAssertEqual(layout.widgets, [.chat, .waiting, .agents])
        XCTAssertEqual(layout.tiles.map(\.rect), [rect(0, 0, 4, 4), rect(4, 0, 2, 2), rect(4, 2, 2, 1)])
        XCTAssertEqual(layout.addArea, rect(4, 3, 2, 1), "N345: Balanced leaves a 2×1 free, so Add works on a fresh install")
        XCTAssertFalse(Self.n344Default.hasRoom)
        assertValid(all)
        XCTAssertEqual(all.widgets.count, 8)
        XCTAssertFalse(all.hasRoom)
    }

    func testAStoredLayoutRoundTrips() throws {
        let store = DashboardLayoutStore(defaults: TestDefaults.make(self))
        let layout = DashboardGridLayout([t(.git, 0, 0, 4, 1), t(.chat, 0, 1, 3, 3), t(.usage, 4, 0, 2, 2)])
        store.save(layout)
        XCTAssertEqual(store.load(), layout)
        XCTAssertEqual(DashboardLayoutStore(defaults: store.defaults).load().widgets, [.git, .usage, .chat], "reading order")
        store.save(all)
        XCTAssertEqual(store.load(), all, "every widget can be stored")
        let json = try XCTUnwrap(String(data: layout.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains(#""id":"chat""#) && json.contains(#""w":3"#) && json.contains(#""h":3"#), json)
    }

    func testUnknownIdsAreDroppedAndABadPlaceIsMended() throws {
        let json = #"[{"id":"weather","x":0,"y":0,"w":1,"h":1},{"id":"chat","x":0,"y":0,"w":4,"h":4},{"id":"cost","x":2,"y":2,"w":2,"h":1},{"id":"git","x":5,"y":3,"w":3,"h":3},{"id":"cost","x":4,"y":0,"w":1,"h":1}]"#
        let layout = try XCTUnwrap(DashboardGridLayout.decode(Data(json.utf8)))
        assertValid(layout)
        XCTAssertEqual(layout.rect(of: .cost), rect(4, 0, 2, 1), "over the chat: the first free place of its size")
        XCTAssertEqual(layout.rect(of: .git), rect(4, 1, 2, 3), "off the grid: pulled in, then shrunk to the largest free place")
        XCTAssertEqual(layout.widgets.count, 3, "unknown dropped, a repeated widget kept once")
        let defaults = TestDefaults.make(self)
        defaults.set(Data("not json".utf8), forKey: DashboardLayoutStore.key)
        XCTAssertEqual(DashboardLayoutStore(defaults: defaults).load(), .default, "unreadable data falls back to the default")
    }

    func testTheChatIsAlwaysThereAndAtLeastThreeByTwo() throws {
        XCTAssertEqual(DashboardGridLayout([t(.waiting, 4, 0, 2, 1)]).widgets, [.chat, .waiting])
        XCTAssertEqual(DashboardGridLayout([]).tiles, [t(.chat, 0, 0, 4, 4)])
        XCTAssertEqual(try XCTUnwrap(DashboardGridLayout.decode(Data("[]".utf8))).widgets, [.chat])
        XCTAssertEqual(DashboardGridLayout([t(.chat, 0, 0, 1, 1)]).rect(of: .chat), rect(0, 0, 3, 2), "a stored chat is never under 3×2")
        let layout = Self.n344Default
        XCTAssertEqual(layout.applying(.remove(.chat)), layout)
        XCTAssertEqual(layout.applying(.add(.chat)), layout)
        XCTAssertEqual(layout.applying(.place(.chat, rect(0, 0, 2, 2))), layout, "under the minimum")
        XCTAssertEqual(layout.resized(.chat, right: -3), rect(0, 0, 3, 4), "a drag stops at three columns")
        XCTAssertEqual(layout.resized(.chat, bottom: -3), rect(0, 0, 4, 2), "and at two rows")
        XCTAssertFalse(WidgetGallery.widgets.contains(.chat), "the gallery does not list the chat")
    }

    func testAnN343OrderIsMigratedOnce() throws {
        let n343default = #"[{"id":"chat","size":"L"},{"id":"waiting","size":"S"},{"id":"agents","size":"T"}]"#
        XCTAssertEqual(try XCTUnwrap(DashboardGridLayout.decode(Data(n343default.utf8))), .default, "N343's default becomes the new one")
        let every = #"[{"id":"chat","size":"L"},{"id":"waiting","size":"S"},{"id":"agents","size":"T"},{"id":"round","size":"S"},{"id":"cost","size":"S"},{"id":"highlights","size":"T"},{"id":"usage","size":"S"},{"id":"git","size":"S"}]"#
        let layout = try XCTUnwrap(DashboardGridLayout.decode(Data(every.utf8)))
        assertValid(layout)
        XCTAssertEqual(layout.rect(of: .chat), rect(0, 0, 4, 3), "the chat keeps N343's 4×3")
        XCTAssertEqual(layout.rect(of: .waiting), rect(4, 0, 2, 1))
        XCTAssertEqual(layout.rect(of: .agents), rect(4, 1, 2, 2))
        XCTAssertEqual(layout.rect(of: .round), rect(0, 3, 2, 1))
        XCTAssertEqual(layout.rect(of: .cost), rect(2, 3, 2, 1))
        XCTAssertEqual(layout.rect(of: .highlights), rect(4, 3, 2, 1), "no 2×2 left: shrunk to the largest free place")
        XCTAssertFalse(layout.contains(.usage) || layout.contains(.git), "no cell left: dropped")
        let defaults = TestDefaults.make(self)
        defaults.set(Data(every.utf8), forKey: DashboardLayoutStore.key)
        let store = DashboardLayoutStore(defaults: defaults)
        store.save(store.load())
        XCTAssertEqual(DashboardGridLayout.decode(try XCTUnwrap(defaults.data(forKey: DashboardLayoutStore.key))), layout, "saved in the new form")
    }

    func testAResizeStopsAtANeighbourAndAtTheGridEdge() {
        let layout = Self.n344Default
        XCTAssertEqual(layout.resized(.waiting, left: -2), rect(4, 0, 2, 2), "the chat is in the way")
        XCTAssertEqual(layout.resized(.waiting, bottom: 2), rect(4, 0, 2, 2), "Agents is in the way")
        XCTAssertEqual(layout.resized(.waiting, right: 3), rect(4, 0, 2, 2), "the grid's edge")
        XCTAssertEqual(layout.resized(.waiting, left: 1, bottom: -1), rect(5, 0, 1, 1), "shrinking always works, down to 1×1")
        XCTAssertEqual(layout.resized(.waiting, left: 3, bottom: -3), rect(5, 0, 1, 1))
        let room = layout.applying(.remove(.agents))
        XCTAssertEqual(room.resized(.waiting, bottom: 5), rect(4, 0, 2, 4), "down to the grid's last row and no further")
        XCTAssertEqual(room.applying(.place(.waiting, rect(3, 0, 3, 2))), room, "a place over the chat is refused")
        let shrunk = room.applying(.place(.chat, rect(0, 0, 3, 4)))
        XCTAssertEqual(shrunk.resized(.waiting, left: -2, top: 0), rect(3, 0, 3, 2), "it grows left into the freed column, then stops")
    }

    /// N349: the grab strips are easy to find (at least 10 pt), fill the gap from both sides without overlapping, and a corner is larger.
    func testTheGripReachesIntoTheGap() {
        let gap = DashboardGrid<EmptyView>.gap
        XCTAssertGreaterThanOrEqual(DashboardResizeGrip.thickness, 10)
        XCTAssertEqual(2 * DashboardResizeGrip.outside, gap, "two neighbours' strips meet in the middle of the gap")
        XCTAssertGreaterThan(DashboardResizeGrip.corner, DashboardResizeGrip.thickness)
        XCTAssertGreaterThan(DashboardResizeGrip.inside, 0)
    }

    /// N349: an edge drag's place is saved, read back after a reload, and the preset becomes Custom.
    func testAPlacedSizeIsSavedAndTheLayoutIsCustom() {
        let defaults = TestDefaults.make(self)
        let store = DashboardLayoutStore(defaults: defaults)
        let balanced = DashboardPreset.balanced.layout
        XCTAssertEqual(DashboardPreset.matching(balanced), .balanced)
        let placed = store.apply(.place(.agents, rect(4, 2, 2, 2)), to: balanced)
        XCTAssertEqual(placed.rect(of: .agents), rect(4, 2, 2, 2))
        XCTAssertEqual(DashboardLayoutStore(defaults: defaults).load(), placed, "a reload keeps the size")
        XCTAssertNil(DashboardPreset.matching(placed), "no preset matches: the menu shows Custom")
    }

    func testAddingNeverOverflows() {
        let full = Self.n344Default
        XCTAssertEqual(full.applying(.add(.git)), full, "no free cell: refused")
        XCTAssertNil(full.addArea, "and no add tile")
        let one = full.applying(.place(.waiting, rect(4, 0, 1, 1)))
        XCTAssertTrue(one.hasRoom)
        XCTAssertEqual(one.addArea, rect(5, 0, 1, 2), "the add tile fills the largest free area")
        let added = one.applying(.add(.highlights))
        XCTAssertEqual(added.rect(of: .highlights), rect(5, 0, 1, 2), "no 2×2 free: the largest free area")
        let wide = DashboardGridLayout([t(.chat, 0, 0, 4, 2)]).applying(.add(.git))
        XCTAssertEqual(wide.rect(of: .git), rect(4, 0, 2, 1), "the first free place of its default size")
        var l = DashboardGridLayout([t(.chat, 0, 0, 3, 2)])
        for w in l.missing { l = l.applying(.add(w)); assertValid(l, "after adding \(w)") }
        // N359/N385: the widgets fill the grid in order; the Terminal (at least 2×1) and the two last N385 widgets find no room and are refused.
        XCTAssertEqual(l.missing, [.terminal, .fixLoops, .pmDecisions])
        for w in l.missing {
            XCTAssertFalse(l.hasRoom(for: w), "so the gallery shows No room for \(w)")
            XCTAssertEqual(l.applying(.add(w)), l)
        }
    }

    func testNothingOverlapsAfterAnyChange() {
        var l = DashboardGridLayout([t(.chat, 0, 0, 3, 2)])
        var seed: UInt64 = 344
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let widgets = DashboardWidget.allCases
        for step in 0..<600 {
            let w = widgets[next(widgets.count)]
            let edit: DashboardLayoutEdit = switch next(7) {
            case 0: .add(w)
            case 1: .remove(w)
            case 2: .resize(w, DashboardTileSize.allCases[next(4)])
            case 3: .place(w, rect(next(6), next(4), 1 + next(4), 1 + next(3)))
            case 4: .swap(w, widgets[next(widgets.count)])
            case 5: .move(w, by: next(2) == 0 ? -1 : 1)
            default: .place(w, l.resized(w, left: next(5) - 2, top: next(5) - 2, right: next(5) - 2, bottom: next(5) - 2) ?? rect(0, 0, 1, 1))
            }
            l = l.applying(edit)
            assertValid(l, "step \(step) \(edit)")
        }
    }

    func testPresetsSwapAndMove() {
        let store = DashboardLayoutStore(defaults: TestDefaults.make(self))
        var layout = Self.n344Default
        store.save(layout)
        XCTAssertTrue(layout.fits(.waiting, preset: .small))
        XCTAssertFalse(layout.fits(.waiting, preset: .wide), "W at Waiting's place runs off the grid")
        layout = store.apply(.resize(.waiting, .small), to: layout)
        XCTAssertEqual(store.load().rect(of: .waiting), rect(4, 0, 2, 1), "saved at once")
        XCTAssertEqual(layout.applying(.resize(.waiting, .large)), layout, "a preset that does not fit is refused")
        layout = store.apply(.swap(.waiting, .agents), to: layout)
        XCTAssertEqual(store.load().rect(of: .waiting), rect(4, 2, 2, 2))
        XCTAssertEqual(store.load().rect(of: .agents), rect(4, 0, 2, 1))
        XCTAssertEqual(layout.applying(.swap(.chat, .agents)), layout, "the chat does not fit a 2×1")
        layout = store.apply(.move(.agents, by: 1), to: layout)
        XCTAssertEqual(layout.rect(of: .agents), rect(4, 1, 2, 1), "the next free place of the same size")
        layout = store.apply(.move(.agents, by: -1), to: layout)
        XCTAssertEqual(layout.rect(of: .agents), rect(4, 0, 2, 1))
        XCTAssertEqual(layout.applying(.move(.agents, by: -1)), layout, "no free place before it")
        XCTAssertEqual(layout.dropped(.agents, column: 5, row: 1), rect(4, 1, 2, 1), "dropped on a free cell: kept on the grid")
        layout = store.apply(.remove(.agents), to: layout)
        XCTAssertEqual(DashboardLayoutStore(defaults: store.defaults).load().widgets, [.chat, .waiting])
        layout = store.apply(.reset, to: layout)
        XCTAssertEqual(store.load(), .default, "Reset is saved too")
    }

    func testTheGridFitsTheWindow() {
        for window in [CGSize(width: 1280, height: 800), CGSize(width: 1728, height: 1117), CGSize(width: 1440, height: 900)] {
            let room = DashboardView.gridSize(window)
            XCTAssertFalse(DashboardGrid<EmptyView>.isNarrow(size: room), "\(window)")
            let row = DashboardGrid<EmptyView>.rowHeight(height: room.height)
            XCTAssertGreaterThanOrEqual(row, DashboardGrid<EmptyView>.minRow)
            XCTAssertLessThanOrEqual(DashboardGrid<EmptyView>.height(for: room), room.height, "four rows fit: no scrolling at \(window)")
            XCTAssertGreaterThan(DashboardGrid<EmptyView>.height(for: room), room.height - 4, "and they fill it")
        }
        XCTAssertEqual(DashboardGrid<EmptyView>.rowHeight(height: 4 * 100 + 3 * 16), 100)
        XCTAssertTrue(DashboardGrid<EmptyView>.isNarrow(size: CGSize(width: 899, height: 900)))
        XCTAssertTrue(DashboardGrid<EmptyView>.isNarrow(size: CGSize(width: 1400, height: 4 * 89 + 48)), "rows under 90 pt: one column")
        XCTAssertEqual(all.narrowOrder.map(\.widget), [.waiting, .chat, .agents, .highlights, .round, .cost, .usage, .git])
    }

    func testTheSummaryCountsAnAgentWithoutACardByItsOwnState() async throws {
        XCTAssertTrue(PanelModel.isWorking(phase: nil, agent: .working))
        XCTAssertFalse(PanelModel.isWorking(phase: nil, agent: .idle))
        XCTAssertFalse(PanelModel.isWorking(phase: .inReview, agent: .working), "a card's phase wins")
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self)
        let rows = DashboardAgentRow.make(model).filter { $0.state.hasPrefix("working") || $0.state.hasPrefix("starting") || $0.state.hasPrefix("PM deciding") }
        XCTAssertFalse(rows.isEmpty, "the fixture has an agent working on no card")
        let summary = model.dashboardSummary(plan: .missing, pick: nil)
        XCTAssertTrue(summary.rest.hasPrefix(rows.count == 1 ? "1 agent working" : "\(rows.count) agents working"), summary.text)
    }

    func testTheDashboardTourRoundStepPointsAtTheRoundTile() {
        // The tutorial passes over a step whose anchor is missing (TutorialModelTests), so without the Round tile the step is skipped.
        let steps = TutorialTours.tour(.dashboard).steps
        XCTAssertEqual(steps.filter { $0.anchor == .dashboardGoal }.count, 1)
        XCTAssertTrue(steps.contains { $0.anchor == .dashboardWaiting } && steps.contains { $0.anchor == .pmChat } && steps.contains { $0.anchor == .agents })
    }
}

/// N342 shots (dark unless named, NSHostingView) → AGENT_PANEL_SNAPSHOT_DIR/N342-*.png.
@MainActor
final class DashboardGridSnapshotTests: XCTestCase {
    private let size = CGSize(width: 1440, height: 900)
    private let terminal = "ui_dev-n339 › Tours group: the mock shows one row on General.\nui_dev-n339 › QUESTION N339-q1: keep Tours on General or move to Help?\n critical: no\n"
    private var all: DashboardGridLayout { DashboardGridTests.all }
    /// Chat, Waiting 2×1, Agents, Cost: one cell left.
    private var some: DashboardGridLayout {
        DashboardGridLayout([DashboardGridTests.t(.chat, 0, 0, 4, 4), DashboardGridTests.t(.waiting, 4, 0, 2, 1), DashboardGridTests.t(.agents, 4, 1, 2, 2),
                             DashboardGridTests.t(.cost, 4, 3, 1, 1)])
    }

    private func write(_ view: some View, _ name: String, size: CGSize? = nil, prefix: String = "N342") throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size ?? self.size))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(prefix)-\(name).png")) }
    }

    func testTheGridShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self)
        XCTAssertEqual(model.dashboardWaiting.count, 2, "a question and a fix")
        try write(DashboardView(model: model, layout: .default), "dashboard")
        try write(DashboardView(model: model, layout: all), "dashboard-all")
        let theme = AppTheme.current
        AppTheme.current = .light
        defer { AppTheme.current = theme }
        try write(DashboardView(model: model, layout: .default).environment(\.colorScheme, .light), "dashboard-light")
        AppTheme.current = theme
        try write(DashboardView(model: model, layout: .default), "dashboard-narrow", size: CGSize(width: 820, height: 1300))
        let question = try XCTUnwrap(model.dashboardWaiting.first { if case .question = $0.kind { true } else { false } })
        try write(DashboardView(model: model, layout: .default, focusOn: question.id, focusTerminal: terminal), "focus-question")
    }

    /// N343 shots (dark) → N343-gallery.png, N343-menu.png, N343-rearrange.png.
    func testTheLayoutEditingShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self)
        try write(DashboardView(model: model, layout: some, gallery: true), "gallery", prefix: "N343")
        try write(DashboardView(model: model, layout: some, menuOn: .agents), "menu", prefix: "N343")
        try write(DashboardView(model: model, layout: some, rearrange: true), "rearrange", prefix: "N343")
    }

    /// N344 shots (dark) → N344-full.png (every widget, 1440×900), N344-resize.png (mid-resize outline), N344-noroom.png.
    func testTheFitAndResizeShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self)
        try write(DashboardView(model: model, layout: all), "full", prefix: "N344")
        let room = DashboardGridTests.n344Default.applying(.remove(.agents))
        let outline = DashboardResizeOutline(widget: .waiting, rect: DashboardCellRect(column: 4, row: 0, width: 2, height: 3))
        try write(DashboardView(model: model, layout: room, resizeOutline: outline), "resize", prefix: "N344")
        try write(DashboardView(model: model, layout: DashboardGridTests.n344Default, gallery: true), "noroom", prefix: "N344")
    }

    func testTheReviewFocusShot() async throws {
        let model = await DemoSupport.makeModel()
        let review = try XCTUnwrap(model.dashboardWaiting.first { if case .review = $0.kind { true } else { false } })
        try write(DashboardView(model: model, layout: .default, focusOn: review.id, focusTerminal: "dev-a4 › Report written. Tests 412/0.\ndev-a4 › Waiting for review."), "focus-review")
    }

    /// N351: a UI test run keeps its own layout; the user's `.standard` is never written, and the same folder finds it again.
    func testUITestFolderUsesItsOwnDefaults() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("n351-\(UUID().uuidString)")
        let own = DashboardLayoutStore.appDefaults(uiTestFolder: folder)
        defer { own.removePersistentDomain(forName: folder.standardizedFileURL.appendingPathComponent("tentacl-uitest-defaults").path) }
        XCTAssertFalse(own === UserDefaults.standard)
        XCTAssertTrue(DashboardLayoutStore.appDefaults(uiTestFolder: nil) === UserDefaults.standard)
        let before = UserDefaults.standard.data(forKey: DashboardLayoutStore.key)
        let placed = DashboardGridTests.all
        DashboardLayoutStore(defaults: own).save(placed)
        XCTAssertEqual(UserDefaults.standard.data(forKey: DashboardLayoutStore.key), before, ".standard is unchanged")
        XCTAssertEqual(DashboardLayoutStore(defaults: DashboardLayoutStore.appDefaults(uiTestFolder: folder)).load(), placed, "a relaunch with the same folder")
    }

    // MARK: N360: the title row

    /// The ⋯ glyph ends on the content edge and sits `Tok.Space.s` after the link, on one 22 pt row.
    func testTheTitleRowEndsOnTheContentEdge() throws {
        XCTAssertEqual(DashboardTileShell<EmptyView>.titleRowHeight, 22)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let glyph = try XCTUnwrap(NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?.withSymbolConfiguration(config))
        XCTAssertEqual(glyph.size.width, DashboardTileMoreButton.glyphWidth, accuracy: 1.5, "the glyph width the inset is made from")
        let inset = DashboardTileShell<EmptyView>.moreGlyphInset
        XCTAssertEqual(inset, (DashboardTileMoreButton.hitWidth - DashboardTileMoreButton.glyphWidth) / 2)
        XCTAssertLessThan(inset, 20, "the hit area stays inside the tile's 20 pt side padding")
        XCTAssertEqual(DashboardTileShell<EmptyView>.linkToMoreSpacing + inset, Tok.Space.s)
    }

    /// Waiting, Agents, Round and Cost with the mouse off every tile: each ⋯ is drawn and every title row ends on the same edge.
    static var n360Layout: DashboardGridLayout {
        DashboardGridLayout([DashboardGridTests.t(.chat, 0, 0, 3, 4), DashboardGridTests.t(.waiting, 3, 0, 2, 2), DashboardGridTests.t(.agents, 5, 0, 1, 2), DashboardGridTests.t(.round, 3, 2, 2, 2), DashboardGridTests.t(.cost, 5, 2, 1, 2)])
    }

    /// Live-window shots (an on-screen NSHostingView), dark and light → N360-headers-dark.png, N360-headers-light.png.
    func testTheLiveHeaderShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self)
        for dark in [true, false] {
            let theme = AppTheme.current
            AppTheme.current = dark ? .dark : .light
            defer { AppTheme.current = theme }
            try await Self.liveWindowShot(DashboardView(model: model, layout: Self.n360Layout), dark: dark, "N360-headers-\(dark ? "dark" : "light").png")
        }
    }

    /// An on-screen 1440×900 window with `root`, drawn after it settles; written to the snapshot folder as `file`.
    static func liveWindowShot(_ root: some View, dark: Bool, _ file: String) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(1200))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(file)) }
    }

    /// Live-window shots → N358-menu.png (the widget menu with Lock tile sizes, locked) and N358-push.png (an edge pushing two tiles).
    func testTheLockAndPushShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self)
        try await Self.liveWindowShot(DashboardView(model: model, layout: Self.n360Layout, popMenu: .widgets), dark: true, "N358-menu.png")
        try await Self.liveWindowShot(DashboardView(model: model, layout: Self.n360Layout, popMenu: .widgets, sizesLocked: false), dark: true, "N358-menu-unlocked.png")
        let l = Self.n360Layout
        let next = l.resized(.chat, pushing: true, right: 1)
        let outline = DashboardResizeOutline(widget: .chat, rect: try XCTUnwrap(next.rect(of: .chat)), pushed: l.changed(in: next).filter { $0.widget != .chat })
        XCTAssertEqual(outline.pushed.count, 2, "Waiting and Round")
        try await Self.liveWindowShot(DashboardView(model: model, layout: l, resizeOutline: outline), dark: true, "N358-push.png")
    }
}

extension DashboardGridTests {
    // MARK: N358: lock tile sizes, push to shrink

    func testTileSizesAreLockedByDefaultAndTheLockIsSaved() {
        let defaults = TestDefaults.make(self)
        XCTAssertTrue(DashboardLayoutStore(defaults: defaults).sizesLocked, "a first run, or an update with no saved value: locked")
        DashboardLayoutStore(defaults: defaults).sizesLocked = false
        XCTAssertFalse(DashboardLayoutStore(defaults: defaults).sizesLocked, "a relaunch keeps it unlocked")
        DashboardLayoutStore(defaults: defaults).sizesLocked = true
        XCTAssertTrue(DashboardLayoutStore(defaults: defaults).sizesLocked)
    }

    func testTheGripsAreOffWhileLockedAndOnInRearrange() {
        XCTAssertFalse(DashboardView.resizable(locked: true, rearranging: false), "locked: the edges do nothing")
        XCTAssertTrue(DashboardView.resizable(locked: true, rearranging: true), "Rearrange lifts the lock while it is on")
        XCTAssertTrue(DashboardView.resizable(locked: false, rearranging: false))
        XCTAssertTrue(DashboardView.resizable(locked: false, rearranging: true))
        let locked = DashboardPopMenu.lockItem(true), open = DashboardPopMenu.lockItem(false)
        XCTAssertEqual(locked.kind, .check(true))
        XCTAssertEqual(open.kind, .check(false))
        XCTAssertEqual(locked.icon, "lock")
        XCTAssertTrue(locked.help?.contains("unlock") == true, "the help says how to unlock")
        XCTAssertEqual(DashboardPopMenu.widgetItems().map(\.id), ["add", "rearrange", "lock"], "next to Rearrange")
    }

    func testAnEdgePushesOneNeighbourSmaller() {
        let l = DashboardGridTests.n344Default  // chat 0,0 4×4 · waiting 4,0 2×2 · agents 4,2 2×2
        let wide = l.applying(.place(.chat, rect(0, 0, 3, 4)))  // column 3 free
        let pushed = wide.resized(.waiting, pushing: true, bottom: 1)
        XCTAssertEqual(pushed.rect(of: .waiting), rect(4, 0, 2, 3))
        XCTAssertEqual(pushed.rect(of: .agents), rect(4, 3, 2, 1), "Agents gives up its top row")
        XCTAssertEqual(pushed.rect(of: .chat), rect(0, 0, 3, 4), "nothing else moves")
        XCTAssertEqual(wide.changed(in: pushed).map(\.widget).sorted { $0.rawValue < $1.rawValue }, [.agents, .waiting])
        assertValid(pushed)
    }

    func testTwoStackedNeighboursShrinkTogether() {
        let l = DashboardGridLayout([t(.chat, 0, 0, 3, 4), t(.waiting, 3, 0, 3, 2), t(.agents, 3, 2, 3, 2)])
        let pushed = l.resized(.chat, pushing: true, right: 2)
        XCTAssertEqual(pushed.rect(of: .chat), rect(0, 0, 5, 4))
        XCTAssertEqual(pushed.rect(of: .waiting), rect(5, 0, 1, 2))
        XCTAssertEqual(pushed.rect(of: .agents), rect(5, 2, 1, 2))
        assertValid(pushed)
    }

    func testThePushStopsAtANeighboursMinimumAndAtTheGridEdge() {
        // Waiting 2 wide on the chat's right: the chat (min 3 columns) can be pushed one column, not two.
        let l = DashboardGridLayout([t(.chat, 0, 0, 4, 4), t(.waiting, 4, 0, 2, 4)])
        let once = l.resized(.waiting, pushing: true, left: -1)
        XCTAssertEqual(once.rect(of: .waiting), rect(3, 0, 3, 4))
        XCTAssertEqual(once.rect(of: .chat), rect(0, 0, 3, 4))
        XCTAssertEqual(l.resized(.waiting, pushing: true, left: -3), once, "the chat stops at three columns; the edge stops there")
        XCTAssertEqual(l.resized(.waiting, pushing: true, right: 2), l, "the grid's edge")
        XCTAssertEqual(l.resized(.chat, pushing: true, right: 5).rect(of: .waiting), rect(5, 0, 1, 4), "Waiting down to one column")
        XCTAssertEqual(l.resized(.chat, pushing: true, right: 5).rect(of: .chat), rect(0, 0, 5, 4))
    }

    func testDraggingBackGivesTheSpaceBack() {
        let l = DashboardGridLayout([t(.chat, 0, 0, 3, 4), t(.waiting, 3, 0, 3, 2), t(.agents, 3, 2, 3, 2)])
        // A drag is always measured from where it started: 2 columns out, then back to 1, then to 0.
        XCTAssertEqual(l.resized(.chat, pushing: true, right: 1).rect(of: .waiting), rect(4, 0, 2, 2))
        XCTAssertEqual(l.resized(.chat, pushing: true, right: 0), l)
        XCTAssertTrue(l.changed(in: l.resized(.chat, pushing: true, right: 0)).isEmpty, "nothing to save")
    }

    func testPushedSizesAreSavedAtOnce() {
        let defaults = TestDefaults.make(self)
        let store = DashboardLayoutStore(defaults: defaults)
        let l = DashboardGridLayout([t(.chat, 0, 0, 3, 4), t(.waiting, 3, 0, 3, 2), t(.agents, 3, 2, 3, 2)])
        let next = l.resized(.chat, pushing: true, right: 1)
        let saved = store.apply(.placeAll(l.changed(in: next)), to: l)
        XCTAssertEqual(saved, next)
        XCTAssertEqual(DashboardLayoutStore(defaults: defaults).load(), next, "all three after a reload")
        XCTAssertEqual(l.applying(.placeAll([t(.chat, 0, 0, 4, 4)])), l, "an overlapping set is refused")
        XCTAssertEqual(l.applying(.placeAll([t(.chat, 0, 0, 2, 4)])), l, "under the chat's minimum is refused")
    }
}
