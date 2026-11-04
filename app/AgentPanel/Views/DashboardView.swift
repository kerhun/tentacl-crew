import SwiftUI
import AppKit

/// Column widths of the Dashboard: three columns while they fit, else the side areas share one column next to the conversation, else one column.
struct DashboardLayout: Equatable {
    static let gap = Tok.Space.l
    static let padding = Tok.Space.l
    static let minLeft: CGFloat = 260, maxLeft: CGFloat = 340
    static let minRight: CGFloat = 300, maxRight: CGFloat = 400
    static let minCentre: CGFloat = 380

    let columns: Int
    let left: CGFloat
    let right: CGFloat

    init(width: CGFloat) {
        let inner = width - 2 * Self.padding
        let three = Self.minLeft + Self.minCentre + Self.minRight + 2 * Self.gap
        let side = max(Self.minLeft, Self.minRight)
        if inner >= three {
            // The side columns take a little of the extra room; the conversation gets the rest.
            let extra = inner - three
            columns = 3; left = min(Self.minLeft + extra * 0.15, Self.maxLeft); right = min(Self.minRight + extra * 0.15, Self.maxRight)
        } else if inner >= side + Self.minCentre + Self.gap {
            columns = 2; left = side; right = side
        } else {
            columns = 1; left = inner; right = inner
        }
    }
}

/// The Dashboard (first in the rail), v2 (N342): a greeting with one summary line, then a calm grid of tiles; the PM chat is the
/// centre and largest. A Waiting for you row opens its decision in front (the focus card) instead of growing the tile. Everything
/// here reuses the views and actions of the other screens.
struct DashboardView: View {
    @Bindable var model: PanelModel
    var onOpen: (String) -> Void = { _ in }
    var onApprove: (TaskCard) -> Void = { _ in }
    var onStart: (TaskCard) -> Void = { _ in }
    var onApproveRound: () -> Void = {}
    var onOpenPlan: () -> Void = {}
    var onOpenTimeline: () -> Void = {}
    var onOpenTerminals: () -> Void = {}
    var onRequestFix: (TaskCard) -> Void = { _ in }
    var onOpenStats: () -> Void = {}
    @State private var goal: String
    @State private var chatPreviewState: ChatPreviewState
    @State private var chatPage = ChatPageHolder()
    @State private var plan: PlanLoad
    @State private var layout: DashboardGridLayout
    @State private var focus: DecisionFocusState?
    /// N343: the gallery, the open ⋯ menu and Rearrange. Changes are saved at once (`store`; nil when a snapshot passed its layout).
    @State private var galleryOpen: Bool
    @State private var menuFor: DashboardWidget?
    @State private var rearranging: Bool
    /// N358: tile edges do nothing while locked (saved with the layout; locked by default); Rearrange lifts the lock while it is on.
    @State private var sizesLocked: Bool
    /// N346: the open widget menu or chat ⋯ menu, the chat header's shared state and Return sends (the composer's own setting).
    @State private var popMenu: DashboardPopMenu?
    @State private var chatControls = ChatControls()
    /// N345: the Undo toast after a layout preset was applied (gone after `DashboardPresetUndo.seconds`).
    @State private var presetUndo: DashboardPresetUndo?
    @AppStorage(CommandBar.returnSendsKey) private var returnSends = false
    private let store: DashboardLayoutStore?
    /// A mid-resize outline (snapshots).
    private let resizeOutline: DashboardResizeOutline?
    /// The focus card's terminal lines (snapshots).
    private let focusTerminal: String?
    /// N359: the tentacld the Terminal tile attaches to (the app's own; tests name a temp one).
    private let terminalClient: TentacldClient?
    @FocusState private var focusedRow: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `chatPreview`: the chat Preview's state, for snapshots; the app uses the saved one. `layout`: the grid (snapshots); the app reads
    /// the stored one. `focusOn`: a waiting item id whose focus card is open (snapshots).
    init(model: PanelModel, onOpen: @escaping (String) -> Void = { _ in }, onApprove: @escaping (TaskCard) -> Void = { _ in }, onStart: @escaping (TaskCard) -> Void = { _ in },
         onApproveRound: @escaping () -> Void = {}, onOpenPlan: @escaping () -> Void = {}, onOpenTimeline: @escaping () -> Void = {}, onOpenTerminals: @escaping () -> Void = {},
         onRequestFix: @escaping (TaskCard) -> Void = { _ in }, onOpenStats: @escaping () -> Void = {},
         chatPreview: ChatPreviewState? = nil, layout: DashboardGridLayout? = nil, focusOn: String? = nil, focusTerminal: String? = nil,
         gallery: Bool = false, menuOn: DashboardWidget? = nil, rearrange: Bool = false, resizeOutline: DashboardResizeOutline? = nil, popMenu: DashboardPopMenu? = nil,
         sizesLocked: Bool = true, terminalClient: TentacldClient? = LiveTerminalSession.appClient) {
        self.model = model
        self.terminalClient = terminalClient
        _chatPreviewState = State(initialValue: chatPreview ?? ChatPreviewState())
        self.onOpen = onOpen; self.onApprove = onApprove; self.onStart = onStart
        self.onApproveRound = onApproveRound; self.onOpenPlan = onOpenPlan; self.onOpenTimeline = onOpenTimeline; self.onOpenTerminals = onOpenTerminals
        self.onRequestFix = onRequestFix; self.onOpenStats = onOpenStats
        store = layout == nil ? DashboardLayoutStore() : nil
        _sizesLocked = State(initialValue: store?.sizesLocked ?? sizesLocked)
        _layout = State(initialValue: layout ?? DashboardLayoutStore().load())
        _galleryOpen = State(initialValue: gallery)
        _menuFor = State(initialValue: menuOn)
        _rearranging = State(initialValue: rearrange)
        _popMenu = State(initialValue: popMenu)
        self.resizeOutline = resizeOutline
        _focus = State(initialValue: focusOn.map { DecisionFocusState(opening: $0, in: model.dashboardWaiting) })
        self.focusTerminal = focusTerminal
        // Read here, not in a task, so the first draw is the only one (N131).
        let url = model.selectedProject?.dataURL
        _plan = State(initialValue: url.map { PlanReader.load(dataDir: $0) } ?? .missing)
        _goal = State(initialValue: url.map { GoalStore.read(dataDir: $0) } ?? "")
    }

    private var dataURL: URL? { model.selectedProject?.dataURL }
    private var cards: [TaskCard] { model.cards.compactMap { if case .card(let c) = $0 { c } else { nil } } }

    /// The page edge: the same as Team and Plan (`pageMargin()`, N347).
    static let padding: CGFloat = Tok.Space.page

    var body: some View {
        GeometryReader { geo in
            let narrow = DashboardGrid<EmptyView>.isNarrow(size: Self.gridSize(geo.size))
            let covered = focus != nil || galleryOpen
            ZStack(alignment: .top) {
                page(size: geo.size, narrow: narrow)
                    .blur(radius: covered ? 3 : 0)
                    .allowsHitTesting(!covered)
                    .accessibilityHidden(covered)
                if focus != nil { focusLayer(size: geo.size, narrow: narrow) }
                if galleryOpen { galleryLayer(size: geo.size) }
            }
            .overlay(alignment: .bottom) { presetUndoToast }
            .animation(reduceMotion ? .easeInOut(duration: 0.18) : .easeOut(duration: 0.18), value: covered)
        }
        .background(Tok.bg)
        .modifier(AgentStopDialog(model: model))
        .modifier(PMChoiceDialog(model: model))
        .sheet(isPresented: Binding(get: { model.inbox.focus != nil }, set: { if !$0 { model.inbox.closeFocus() } })) { questionSheet }
        .task(id: dataURL) { reload() }
        .task(id: cards.count) { reload() }
        .onAppear { model.dashboardVisible = true; if let id = model.selectedProjectID { model.chats.markSeen(project: id) } }
        .onDisappear { model.dashboardVisible = false }
    }

    private var hasRounds: Bool { if case .plan(let file) = plan { !file.rounds.isEmpty } else { false } }

    private func reload() {
        guard let url = dataURL else { plan = .missing; goal = ""; return }
        plan = PlanReader.load(dataDir: url)
        goal = GoalStore.read(dataDir: url)
    }

    // MARK: page: header and grid

    /// The room under the header: the grid fills exactly this (N344).
    static func gridSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width - 2 * padding, height: size.height - 2 * padding - headerHeight - DashboardGrid<EmptyView>.gap)
    }

    /// The grid fills the window and does not scroll; only the one-column fallback of a small window scrolls.
    @ViewBuilder private func page(size: CGSize, narrow: Bool) -> some View {
        if narrow {
            Scroller { pageContent(size: size, narrow: true) }
        } else {
            pageContent(size: size, narrow: false).frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func pageContent(size: CGSize, narrow: Bool) -> some View {
        let room = layout.missing.isEmpty ? nil : { openGallery() }
        return VStack(alignment: .leading, spacing: DashboardGrid<EmptyView>.gap) {
                header.frame(minHeight: Self.headerHeight)
                let resizable = Self.resizable(locked: sizesLocked, rearranging: rearranging)
                DashboardGrid(layout: layout, size: Self.gridSize(size), onAdd: rearranging ? nil : room,
                              onPlace: resizable && !rearranging ? { edit(.place($0, $1)) } : nil,
                              onPlaceAll: resizable ? { edit(.placeAll($0)) } : nil,
                              onDropAt: rearranging ? { drop($0, column: $1, row: $2) } : nil,
                              outline: resizeOutline) { gridTile($0, narrow: narrow) }
                    // N254: the tiles never move; the Preview is one layer above them, so it grows and shrinks without reloading the page.
                    .overlayPreferenceValue(ChatCardBounds.self) { anchor in
                        GeometryReader { proxy in previewLayer(chat: anchor.map { proxy[$0] }, area: CGRect(origin: .zero, size: proxy.size)) }
                    }
                    // N343: the open ⋯ menu, under its button and above the other tiles.
                    .overlayPreferenceValue(DashboardMenuAnchors.self) { anchors in
                        GeometryReader { proxy in menuLayer(button: menuFor.flatMap { anchors[$0] }.map { proxy[$0] }, area: proxy.size) }
                    }
            }
            // N346: the widget menu and the chat's ⋯ menu, under their buttons and above the tiles.
            .overlayPreferenceValue(PopMenuAnchors.self) { anchors in
                GeometryReader { proxy in popMenuLayer(button: popMenu.flatMap { anchors[$0.rawValue] }.map { proxy[$0] }, area: proxy.size) }
            }
            .padding(Self.padding)
    }

    static let headerHeight: CGFloat = 48

    /// N358: whether tile edges resize: always in Rearrange, else only when the sizes are not locked.
    static func resizable(locked: Bool, rearranging: Bool) -> Bool { rearranging || !locked }

    private func setSizesLocked(_ locked: Bool) {
        sizesLocked = locked
        store?.sizesLocked = locked
        AccessibilityNotification.Announcement(locked ? "Tile sizes locked" : "Tile sizes unlocked").post()
    }

    /// "Good afternoon" and one line: what needs you (in the ask colour), the agents working and the round.
    private var header: some View {
        let summary = model.dashboardSummary(plan: plan, pick: pick)
        return HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboardGreeting(hour: Calendar.current.component(.hour, from: Date()))).font(.system(size: 22, weight: .semibold)).foregroundStyle(Tok.ink)
                summaryLine(summary).font(.system(size: 13)).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            DashboardStrip(model: model, onPlanRound: { model.round.begin() })
            widgetButton
        }
    }

    /// N346: one widget button whose menu has Add widget… and Rearrange; while rearranging, Reset and a blue Done in its place.
    private var widgetButton: some View {
        HStack(spacing: Tok.Space.s) {
            ForEach(DashboardPopMenu.headerButtons(rearranging: rearranging), id: \.self) { button in
                switch button {
                case .reset:
                    Button("Reset") { edit(.reset) }.buttonStyle(PanelButtonStyle())
                        .help("Back to the default: the PM chat, Waiting for you and Agents")
                case .done:
                    Button("Done") { rearranging = false }.buttonStyle(ConfirmButtonStyle())
                        .help("Stop rearranging").accessibilityLabel("Done rearranging")
                case .widgets:
                    widgetsMenuButton
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var widgetsMenuButton: some View {
            let open = popMenu == .widgets
            Button { menuFor = nil; popMenu = open ? nil : .widgets } label: {
                Image(systemName: "square.grid.2x2").font(.system(size: 13))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus").font(.system(size: 7, weight: .bold)).padding(1.5)
                            .background(open ? Tok.line : Tok.raise, in: Circle()).offset(x: 3, y: 3)
                    }
                    .foregroundStyle(Tok.ink)
                    .frame(width: 34, height: 32)
                    .background(open ? Tok.line : Tok.raise, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(open ? Tok.work : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Widgets").accessibilityLabel("Widgets").accessibilityValue(open ? "open" : "")
            .anchorPreference(key: PopMenuAnchors.self, value: .bounds) { [DashboardPopMenu.widgets.rawValue: $0] }
    }

    /// The open widget or chat menu, right-aligned under its button; a click anywhere else or Esc closes it.
    @ViewBuilder private func popMenuLayer(button: CGRect?, area: CGSize) -> some View {
        if let button, let which = popMenu {
            let close = { popMenu = nil }
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: close).accessibilityHidden(true)
                let items = popMenuItems(which), width = PopMenuView.width(for: items)
                PopMenuView(label: which == .widgets ? "Widgets" : "Chat options", items: items, onClose: close)
                    .offset(x: min(max(button.maxX - width, 0), max(area.width - width, 0)), y: button.maxY + 6)
                    .escapeCancels(close)
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
        }
    }

    private func popMenuItems(_ which: DashboardPopMenu) -> [PopMenuItem] {
        switch which {
        case .widgets:
            return DashboardPopMenu.widgetItems(onAdd: { openGallery() }, onRearrange: { menuFor = nil; rearranging = true },
                                                sizesLocked: sizesLocked, onLock: { setSizesLocked(!sizesLocked) },
                                                layout: DashboardPopMenu.layoutItems(for: layout, onApply: applyPreset))
        case .chat:
            let pm = model.selectedProjectID.flatMap { model.pmAgent(forProject: $0) }
            return PMChatHeader.menuItems(canRestart: pm.map { model.canRestartConversation($0) } == true, busy: model.isBusy, returnSends: returnSends, compact: pm.map { model.restartModes(for: $0).contains(.compact) } ?? true,
                                          onNew: { chatControls.openRestart(.handoff) }, onCompact: { chatControls.openRestart(.compact) },
                                          onReturnSends: { returnSends = $0 }, onRules: { model.openAuthorityRules() },
                                          onStop: { if let pm { model.requestStop(pm) } })
        }
    }

    // MARK: N343: changing the tiles

    private func edit(_ change: DashboardLayoutEdit) {
        let next = store?.apply(change, to: layout) ?? layout.applying(change)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { layout = next }
        if case .remove = change { menuFor = nil }
    }

    /// N345: replaces the layout with the preset's, saves it, announces it and offers Undo for a few seconds.
    private func applyPreset(_ preset: DashboardPreset) {
        menuFor = nil
        let previous = layout
        let next = store?.apply(preset, replacing: previous).layout ?? preset.layout
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { layout = next }
        presetUndo = DashboardPresetUndo(preset: preset, previous: previous)
        AccessibilityNotification.Announcement(preset.appliedAnnouncement).post()
    }

    private func undoPreset() {
        guard let undo = presetUndo else { return }
        let previous = store?.undo(undo) ?? undo.previous
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { layout = previous }
        presetUndo = nil
        AccessibilityNotification.Announcement("Layout restored").post()
    }

    /// "Layout Focus applied · Undo", at the bottom for a few seconds.
    @ViewBuilder private var presetUndoToast: some View {
        if let undo = presetUndo {
            HStack(spacing: Tok.Space.m) {
                Text(undo.preset.appliedAnnouncement).font(.system(size: 12.5)).foregroundStyle(Tok.ink)
                Button("Undo", action: undoPreset).buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tok.work)
                    .help("Put the layout from before back").accessibilityLabel("Undo layout \(undo.preset.name)")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tok.line, lineWidth: 1))
            .shadow(color: .black.opacity(Tok.shadowOpacity(0.3)), radius: 12, y: 8)
            .padding(.bottom, Self.padding + 8)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .task(id: undo) {
                try? await Task.sleep(for: .seconds(DashboardPresetUndo.seconds))
                if !Task.isCancelled, presetUndo == undo { presetUndo = nil }
            }
        }
    }

    private func openGallery() { menuFor = nil; galleryOpen = true }

    /// Rearrange: a tile dropped on a free cell goes there at its size, or as large as fits from that cell.
    private func drop(_ w: DashboardWidget, column: Int, row: Int) {
        if let r = layout.dropped(w, column: column, row: row) { edit(.place(w, r)) }
    }

    /// Each tile with its ⋯ menu (not the chat), or in Rearrange with the dashed border, drag and ⌘← ⌘→.
    @ViewBuilder private func gridTile(_ t: DashboardTile, narrow: Bool) -> some View {
        if rearranging {
            DashboardRearrangeTile(tile: t, onSwap: { edit(.swap($0, t.widget)) }, onMove: { edit(.move(t.widget, by: $0)) }) { tile(t, narrow: narrow) }
        } else {
            tile(t, narrow: narrow)
                .environment(\.dashboardTileMenu, t.widget == .chat ? nil : DashboardTileMenuContext(
                    widget: t.widget, isOpen: menuFor == t.widget, toggle: { menuFor = menuFor == t.widget ? nil : t.widget }))
        }
    }

    /// The open menu, right-aligned under its ⋯ button; a click anywhere else or Esc closes it.
    @ViewBuilder private func menuLayer(button: CGRect?, area: CGSize) -> some View {
        if let button, let w = menuFor, let t = layout.tile(w) {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { menuFor = nil }.accessibilityHidden(true)
                DashboardTileMenuView(widget: w, size: t.size, fits: { layout.fits(w, preset: $0) }, onSize: { edit(.resize(w, $0)) }, onRemove: { edit(.remove(w)) })
                    .offset(x: min(max(button.maxX - DashboardTileMenuView.width, 0), max(area.width - DashboardTileMenuView.width, 0)), y: button.maxY + 6)
                    .escapeCancels { menuFor = nil }
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
        }
    }

    private func galleryLayer(size: CGSize) -> some View {
        ZStack(alignment: .top) {
            Tok.bg.opacity(0.6).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture { galleryOpen = false }
                .accessibilityHidden(true)
            WidgetGallery(layout: layout, onAdd: { edit(.add($0)) }, onClose: { galleryOpen = false })
                .frame(maxHeight: max(size.height - 100, 300), alignment: .top)
                .padding(.top, 70)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    private func summaryLine(_ s: DashboardSummary) -> Text {
        let need = Text(s.need ?? "Nothing needs you").foregroundColor(s.need == nil ? Tok.ink3 : Tok.askText)
        return s.rest.isEmpty ? need : need + Text(" · " + s.rest).foregroundColor(Tok.ink3)
    }

    @ViewBuilder private func tile(_ t: DashboardTile, narrow: Bool) -> some View {
        switch t.widget {
        case .chat: conversation(narrow: narrow)
        case .waiting:
            WaitingTile(model: model, onOpen: { open($0) }, focusedRow: $focusedRow).tutorialAnchor(.dashboardWaiting)
        case .agents:
            AgentsTile(model: model, onOpen: onOpen, onOpenTerminals: onOpenTerminals).tutorialAnchor(.agents)
        case .round:
            RoundTile(goal: goal, plan: plan, cards: cards, pick: pick, onPick: { model.setGoalRoundPick($0, project: projectID, cards: cards, plan: plan); pickRev += 1 },
                      onOpen: onOpen, onOpenPlan: onOpenPlan)
                .tutorialAnchor(.dashboardGoal)
        case .cost:
            CostTile(today: costToday, limit: model.autopilot.policy.dailyLimitUSD,
                     limitReached: model.autopilot.limitReached, onOpenStats: onOpenStats,
                     week: CostTile.Read.of(costRead, project: projectID).map { CostTile.week($0.days, today: costToday) }, allProjects: model.planUsage?.todayCost)
                .task(id: CostTile.refreshKey(project: projectID, cards: cards.count, autopilot: model.autopilot.lastCostToday, allProjects: model.planUsage?.todayCost)) {
                    // Read now, then once a minute while the key stays the same (without a daily limit nothing else moves the key).
                    let project = projectID
                    while !Task.isCancelled {
                        let read = await StatsModel.recentCost(of: model)
                        guard !Task.isCancelled else { return }
                        costRead = CostTile.Read(project: project, days: read.days, today: read.today)
                        try? await Task.sleep(for: .seconds(CostTile.refreshSeconds))
                    }
                }
        case .highlights:
            HighlightsTile(highlights: model.dashboardHighlights, onOpen: onOpen, onOpenTimeline: onOpenTimeline, timelineEnabled: hasRounds)
        case .usage:
            UsageTile(usage: model.planUsage, gate: model.usageGate)
        case .git:
            GitTile(model: model)
        case .terminal:
            DashboardTerminalTile(model: model, store: store, client: terminalClient, onOpenTerminals: onOpenTerminals)
        case .reviewPackets:
            ReviewPacketsLiveTile(model: model, onOpen: openPacket)
        case .fixLoops:
            FixLoopsTile(loops: DashboardFeeds.fixLoops(cards: model.selectedTaskCards, events: model.actionLogEvents(),
                                                        decisions: model.autopilot.allDecisions(), project: projectID), onOpen: onOpen)
        case .pmDecisions:
            PMDecisionsTile(day: DashboardFeeds.pmDecisions(model.autopilot.allDecisions(), events: model.actionLogEvents(), project: projectID),
                            onOpen: openTimeline)
        }
    }

    /// N385: Open packet opens the review in front, as Waiting for you does; a review that is not listed there opens the card.
    private func openPacket(_ id: String) {
        if let item = model.dashboardWaiting.first(where: { $0.kind == .review(id) }) { open(item) } else { onOpen(id) }
    }

    /// N385: a PM decision opens its card on the Timeline tab.
    private func openTimeline(_ id: String) {
        model.selectedCardID = id
        model.saveOpenTab(.timeline, card: id)
        onOpen(id)
    }

    @State private var pickRev = 0
    /// The Cost tile's last 7 days and today's cost, tagged with the project they were read for (read off the main thread on each
    /// `CostTile.refreshKey` change and once a minute). Another project's read is ignored (`CostTile.Read.of`), so a switch never shows it.
    @State private var costRead: CostTile.Read?
    /// The big amount and the line's last point: one number, this project only (N361).
    private var costToday: Double? { CostTile.projectToday(read: CostTile.Read.of(costRead, project: projectID)?.today, autopilot: model.autopilot.lastCostToday) }
    private var pick: GoalPick? { _ = pickRev; return model.goalRoundPick(projectID) }

    // MARK: the focus card

    private func open(_ item: DashboardWaitingItem) {
        focus = DecisionFocusState(opening: item.id, in: model.dashboardWaiting)
    }

    private func closeFocus() {
        let id = focus?.currentID
        focus = nil
        // Back to the row it opened from (or the one now in its place).
        let items = model.dashboardWaiting
        focusedRow = items.first { $0.id == id }?.id ?? items.first?.id
    }

    /// Where the card grows from: the Waiting for you tile's place on the grid.
    private func origin(width: CGFloat, narrow: Bool) -> UnitPoint {
        guard !narrow, let p = layout.rect(of: .waiting) else { return .top }
        let x = (CGFloat(p.column) + CGFloat(p.width) / 2) / CGFloat(DashboardGridLayout.columns)
        let cardLeft = (width - DecisionFocusCard.width) / 2 / max(width, 1)
        return UnitPoint(x: min(max((x - cardLeft) * width / DecisionFocusCard.width, 0), 1), y: 0)
    }

    private func focusLayer(size: CGSize, narrow: Bool) -> some View {
        let items = model.dashboardWaiting
        return ZStack(alignment: .top) {
            Tok.bg.opacity(0.6).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture { closeFocus() }
                .accessibilityHidden(true)
            DecisionFocusCard(model: model, items: items, state: Binding(get: { focus ?? DecisionFocusState(opening: "", in: []) }, set: { focus = $0 }),
                              onClose: { closeFocus() }, onOpen: onOpen, onApprove: onApprove, onStart: onStart, onApproveRound: onApproveRound,
                              onRequestFix: onRequestFix, terminalText: focusTerminal)
                .frame(maxHeight: max(size.height - 100, 200), alignment: .top)
                .padding(.top, 70)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: origin(width: size.width, narrow: narrow)).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    /// Call questions and the top bar's questions still open the question window.
    private var questionSheet: some View {
        let inbox = model.inbox
        let pm = model.selectedProjectID.flatMap { model.pmPane(forProject: $0) }
        let window = NSApp.mainWindow?.contentLayoutRect.height ?? QuestionFocusSheet.height
        let byID = Dictionary(model.questionsForYou.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let questions = model.dashboardWaiting.compactMap { if case .question(let id) = $0.kind { byID[id] } else { nil } }
        return QuestionFocusSheet(inbox: inbox, questions: questions,
                                  suggestion: { model.autopilot.suggestion(for: $0) }, escalation: { model.autopilot.escalation(for: $0) },
                                  cardTitle: { model.card(id: $0)?.title },
                                  waited: { q in inbox.askedAt[q.id].map { Stats.durationText(max(Date().timeIntervalSince($0), 0)) } },
                                  onPassOn: pm.map { pane in { q in Task { await model.tellPM(pane: pane, passOnToPMText(q)) } } },
                                  onAlwaysAllow: model.autopilot.isAvailable ? { q in Task { _ = await model.autopilot.alwaysAllow(q) } } : nil,
                                  maxHeight: window - 40)
    }

    // MARK: the PM conversation

    private var projectID: String { model.selectedProjectID ?? "" }
    private var previewLayout: ChatPreviewLayout { chatPreviewState.layout(projectID) }

    private var commandBar: some View {
        CommandBar(model: model, fillsHeight: true, viewing: true, pmOnly: true,
                   onOpenPreview: { url in withAnimation(previewAnimation) { chatPreviewState.open(url, project: projectID) } },
                   controls: chatControls, noPM: model.pmStatus == .missing ? AnyView(noPMState) : nil)
    }

    /// The grow and shrink of the Preview (N254); with Reduce motion it fades and does not move.
    private var previewAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.1) }
    private func previewChange(_ change: () -> Void) { withAnimation(previewAnimation, change) }

    /// The Preview above the tiles: over the chat tile (`chat`, its content frame) or, expanded, over the whole `area` on a backdrop
    /// that hides the tiles. The one PreviewPane only changes its frame, so the page is not reloaded.
    @ViewBuilder private func previewLayer(chat: CGRect?, area: CGRect) -> some View {
        let layout = previewLayout
        ZStack(alignment: .topLeading) {
            if layout == .expanded { Tok.bg.transition(.opacity) }
            if layout != .chat, let chat {
                let rect = layout == .expanded ? area : chat
                chatPreviewCard
                    .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(reduceMotion ? nil : previewAnimation, value: layout)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
                    .escapeCancels { previewChange { _ = chatPreviewState.escape(projectID) } }
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    /// The Preview of the chat (N248, N254): a tab-like header (title, "from the chat", Chat, expand or restore). The page model is
    /// kept while the Preview covers the chat, the Dashboard or neither, so switching does not reload the page.
    @ViewBuilder private var chatPreviewCard: some View {
        if let url = chatPreviewState.url(for: projectID) {
            let project = projectID, root = model.selectedProject?.repoURL
            let key = "\(project)|\(chatPreviewState.opened)"
            let page = chatPage.model(key: key, url: url) { [chatPreviewState] in chatPreviewState.remember($0, project: project, projectRoot: root) }
            let expanded = chatPreviewState.expanded(project)
            PreviewPane(model: page, source: nil, cardID: "Chat", fromText: "from the chat",
                        onExpand: { previewChange { chatPreviewState.setExpanded(!expanded, project: project) } }, expanded: expanded,
                        onChat: { previewChange { chatPreviewState.select(.chat, project: project) } })
                .id(key)
                .accessibilityElement(children: .contain).accessibilityLabel("Preview of the chat")
        }
    }

    /// The Chat and Preview tabs of the chat tile on a narrow window (N248).
    private func chatTabs(_ selected: ChatPreviewTab) -> some View {
        HStack(spacing: Tok.Space.xs) {
            ForEach([(ChatPreviewTab.chat, "Chat"), (.preview, "Preview")], id: \.1) { tab, name in
                let on = tab == selected
                Button { previewChange { chatPreviewState.select(tab, project: projectID) } } label: {
                    Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? Tok.ink : Tok.ink2)
                        .padding(.horizontal, 12).frame(height: 26).background(on ? Tok.line : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.xs + 2)
        .background(Tok.pane)
    }

    /// The PM chat tile. Its content below the PM bar is where the Preview goes (N254, N265: the bar and its Preview icon stay
    /// above it); the chat stays underneath, hidden, so its scroll and draft are kept. A narrow window adds the Chat | Preview tabs.
    private func conversation(narrow: Bool) -> some View {
        let tabs = narrow && chatPreviewState.url(for: projectID) != nil
        let covered = previewLayout != .chat
        return VStack(spacing: 0) {
            if tabs { chatTabs(chatPreviewState.tab(projectID)); Divider().overlay(Tok.line) }
            chatHeader(previewIcon: !tabs)
            VStack(spacing: 0) { commandBar }
                .opacity(covered ? 0 : 1).allowsHitTesting(!covered).accessibilityHidden(covered)
                .anchorPreference(key: ChatCardBounds.self, value: .bounds) { $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashboardTile()
        .tutorialAnchor(.pmChat)
    }

    /// The PM bar; on a wide window it has the Preview icon beside Stop PM when the project has a page to show (N265).
    @ViewBuilder private func chatHeader(previewIcon: Bool) -> some View {
        let project = projectID
        let block = PMStartBlock.make(setupReason: model.startSetupReason, signInReason: model.signInReason(forRole: "pm"), gateReason: model.usageGateReason, safePointReason: model.safePointReason, busy: model.isBusy)
        let offHelp = model.isBusy ? PMStartBlock.busyHelp : block?.text
        let pm = model.selectedProjectID.flatMap { model.pmAgent(forProject: $0) }
        let header = CommandBar.headerLabel(agent: pm.map { $0.name ?? "" }, displayNames: model.roleDisplayNames)
        let pane = model.selectedProjectID.flatMap { model.pmPane(forProject: $0) }
        let waiting = pane != nil && model.questionsForYou.contains { $0.paneID == pane && $0.question.kind != .freeText }
        PMChatHeader(status: model.pmStatus, name: pm == nil ? "PM" : header.name, role: pm == nil ? nil : header.role, projectName: model.selectedProject?.name ?? "",
                     waiting: waiting, authority: PMChatHeader.authorityText(model.dashboardAuthority), authorityOn: model.autopilot.policy.pmAuthority,
                     onAuthority: { model.openAuthorityRules() },
                     conversationOnly: chatControls.conversationOnly, onConversationOnly: { chatControls.conversationOnly.toggle() },
                     onSearch: { chatControls.searching = true },
                     previewShown: previewIcon ? PMChatHeader.previewIcon(hasPage: chatPreviewState.url(for: project) != nil, showing: chatPreviewState.shown(project)) : nil,
                     onPreview: { previewChange { chatPreviewState.toggle(project) } },
                     menuOpen: popMenu == .chat, onMenu: { menuFor = nil; popMenu = popMenu == .chat ? nil : .chat })
        if let folder = model.pmOutsideFolder, let repo = model.selectedProject?.repoPath {
            PMOutsideWarning(folder: folder, repo: repo, canStart: model.canStart && !model.isBusy, offHelp: offHelp, onStart: { Task { await model.startPMHere() } })
        }
        // Start PM / Resume PM / Start a PM here are off: say why in one line (N328).
        if let block, model.pmStatus == .missing || model.pmOutsideFolder != nil {
            PMStartBlockedLine(block: block, onStartAnyway: { model.startAnyway() }, signingIn: model.signInGate.signingIn != nil, onSignIn: { tool in Task { await model.signIn(tool) } })
        }
        Divider().overlay(Tok.line)
    }

    /// The thread area without a PM (N346): Start PM, Resume PM and Choose a running agent by today's rules.
    private var noPMState: some View {
        let block = PMStartBlock.make(setupReason: model.startSetupReason, signInReason: model.signInReason(forRole: "pm"), gateReason: model.usageGateReason, safePointReason: model.safePointReason, busy: model.isBusy)
        return PMNoPMState(projectName: model.selectedProject?.name ?? "", candidates: model.pmCandidates, label: { model.agentLabel($0) },
                           canStart: model.canStart && !model.isBusy, offHelp: model.isBusy ? PMStartBlock.busyHelp : block?.text,
                           resumeHelp: model.pmResumeSession == nil ? "No earlier PM conversation was found in the project folder" : "Starts the PM again and continues its last conversation",
                           canResume: model.pmResumeSession != nil, onResume: { Task { await model.resumePM() } },
                           onChoose: { agent in if let id = model.selectedProjectID { model.choosePM(agent, forProject: id) } },
                           onStart: { Task { await model.startPM() } })
    }

    // MARK: agents

    /// The agents with their rich cards (step bar, last action, time, cost, the stopped warning with Nudge).
    /// A click on a task agent's card opens that card on Tasks (`onOpen`).
    static func agentsPane(_ model: PanelModel, onOpen: @escaping (String) -> Void = { _ in }, onOpenTerminals: @escaping () -> Void = {}) -> AgentsPane {
        // The roles' colours as the Team screen's roster gives them.
        let groups = model.team.groups
        let roster = TeamRoster(base: groups.first?.roles ?? [], project: groups.count > 1 ? groups[1].roles : [], projectName: nil,
                                chart: model.team.chart.savedChart, cards: model.selectedTaskCards, agents: [])
        let tints = Dictionary(roster.cards.map { ($0.name, $0.tint) }, uniquingKeysWith: { first, _ in first })
        let pm = model.selectedProjectID.flatMap { model.pmPane(forProject: $0) }
        return AgentsPane(state: model.visibleAgents, label: { model.agentLabel($0) }, phase: { model.phase(ofAgent: $0) }, autopilot: model.autopilot, feedOnly: true,
                   onOpenTerminal: { agent in Task { await model.openTerminal(agent) } }, onStop: { model.requestStop($0) }, canStop: { model.canStop($0) },
                   cards: model.agentCards, onOpenCard: onOpen, statusLine: { model.statusLine($0) },
                   onSleep: { agent in Task { await model.sleepAgent(agent) } }, sleepWhy: { model.sleepRefusal(of: $0) },
                   sleeping: model.sleepingAgents, onWake: { id in
                       for case .card(let card) in model.cards where card.id == id { Task { await model.wakeAgent(card) } }
                   }, displayNames: model.roleDisplayNames, roleTint: { RosterView.tint(tints[$0]) }, isPM: { $0.paneID == pm }, pmAsking: model.inbox.questions.contains(where: \.isPM),
                   askingYou: { [asking = model.askingPanes] in asking.contains($0.paneID) }, onOpenTerminals: onOpenTerminals)
    }
}

/// The frame of the PM chat card's content, where the chat's Preview goes (N254).
struct ChatCardBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// Keeps the chat Preview's page model while its key (project and open count) stays the same (N248).
@MainActor final class ChatPageHolder {
    private var key = ""
    private var page: PreviewModel?

    func model(key: String, url: URL, onNavigate: @escaping (URL) -> Void) -> PreviewModel {
        if let page, self.key == key { return page }
        let made = PreviewModel(url: url)
        made.onNavigate = onNavigate
        page = made; self.key = key
        return made
    }
}

/// The Dashboard header's widget menu and the chat's ⋯ menu (N346), drawn by the panel.
enum DashboardPopMenu: String {
    case widgets, chat

    /// Add widget…, Rearrange and (N358) Lock tile sizes, checked while locked. N345: the Layout presets go after them as
    /// `.divider("layout")`, `.section("Layout")` and one `.check` item per preset, passed in as `layout`.
    static func widgetItems(onAdd: @escaping () -> Void = {}, onRearrange: @escaping () -> Void = {}, sizesLocked: Bool = true, onLock: @escaping () -> Void = {},
                            layout: [PopMenuItem] = []) -> [PopMenuItem] {
        [PopMenuItem(id: "add", title: "Add widget…", icon: "plus", help: "Open the widget gallery", action: onAdd),
         PopMenuItem(id: "rearrange", title: "Rearrange", icon: "arrow.left.arrow.right", help: "Drag tiles onto each other to swap them, or onto free cells", action: onRearrange),
         lockItem(sizesLocked, action: onLock)]
        + (layout.isEmpty ? [] : [.divider("layout"), .section("Layout")] + layout)
    }

    /// N358: the lock toggle; its help says how to unlock (or that Rearrange resizes too).
    static func lockItem(_ locked: Bool, action: @escaping () -> Void = {}) -> PopMenuItem {
        PopMenuItem(id: "lock", title: "Lock tile sizes", icon: locked ? "lock" : "lock.open", kind: .check(locked),
                    help: locked ? "Tile edges don't resize now. Choose this to unlock them, or use Rearrange to resize there"
                                 : "Tile edges resize by dragging. Choose this to lock them",
                    action: action)
    }

    /// N345: one item per preset with its grid thumbnail, the active one checked; Custom (checked, does nothing) when none matches.
    static func layoutItems(for layout: DashboardGridLayout, onApply: @escaping (DashboardPreset) -> Void = { _ in }) -> [PopMenuItem] {
        let active = DashboardPreset.matching(layout)
        var items = DashboardPreset.allCases.map { preset in
            PopMenuItem(id: "layout." + preset.rawValue, title: preset.name, kind: .check(preset == active), help: preset.help,
                        thumbnail: AnyView(DashboardLayoutThumbnail(tiles: preset.tiles, active: preset == active)),
                        voiceLabel: preset.accessibilityLabel, subtitle: preset.subtitle, action: { onApply(preset) })
        }
        if active == nil {
            items.append(PopMenuItem(id: "layout.custom", title: "Custom", kind: .check(true), help: "Your own layout; choose a layout above to replace it",
                                     thumbnail: AnyView(DashboardLayoutThumbnail(tiles: layout.tiles, active: true)), voiceLabel: "Layout: Custom",
                                     subtitle: DashboardPreset.customSubtitle))
        }
        return items
    }

    /// The header's right-hand buttons after Plan a round: the widget button, or Reset and a blue Done while rearranging.
    enum HeaderButton: Hashable { case widgets, reset, done }
    static func headerButtons(rearranging: Bool) -> [HeaderButton] { rearranging ? [.reset, .done] : [.widgets] }
}

/// What the Dashboard's strip shows, in order (N346: PM authority went to the chat header, the cost to its own tile).
enum DashboardStripItem: Equatable {
    case planRound, planReason

    static func items(planEnabled: Bool) -> [DashboardStripItem] {
        [.planRound] + (planEnabled ? [] : [.planReason])
    }
}

/// The line at the top of the Dashboard: Plan a round, and why it is off.
private struct DashboardStrip: View {
    @Bindable var model: PanelModel
    let onPlanRound: () -> Void

    var body: some View {
        let planState = model.planRoundState
        HStack(spacing: Tok.Space.s + 2) {
            ForEach(DashboardStripItem.items(planEnabled: planState.enabled), id: \.self) { item in
                switch item {
                case .planRound:
                    Button(action: onPlanRound) { Label("Plan a round", systemImage: "square.stack.3d.up") }
                        .buttonStyle(PanelButtonStyle()).disabled(!planState.enabled).help(planState.help)
                        .tutorialAnchor(.dashboardPlanRound)
                case .planReason:
                    Text(planState.help).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2).frame(maxWidth: 260, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}


/// "Initialize git" or "Push to GitHub" in Waiting for you. Only Push has "Not now": without git no agent can start.
struct GitSuggestionRow: View {
    let suggestion: GitSuggestion
    let onOpen: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        switch suggestion {
        case .initializeGit:
            WaitingRow(chip: "Initialize git", tint: .git, title: suggestion.title, detail: suggestion.detail) {
                Button("Initialize git…", action: onOpen).buttonStyle(PanelButtonStyle())
                    .help("Choose the files for the first commit; nothing is committed until you confirm")
            }
        case .pushToGitHub:
            WaitingRow(chip: "Push to GitHub", tint: .git, title: suggestion.title, detail: suggestion.detail) {
                Button("Push to GitHub…", action: onOpen).buttonStyle(PanelButtonStyle()).help("Nothing is pushed from here; the sheet says what happens")
                Button("Not now", action: onNotNow).buttonStyle(PanelButtonStyle()).help("Hide this until the remote or the commits change")
            }
        }
    }
}

/// The two git sheets of the Dashboard.
struct GitSetupSheets: ViewModifier {
    @Bindable var git: GitSuggestionModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $git.initSheet) { _ in InitGitSheet(model: git, onDone: { git.initSheet = nil }) }
            .sheet(item: $git.pushSheet) { _ in PushToGitHubSheet(model: git, onDone: { git.pushSheet = nil }) }
    }
}

/// git init and a first commit with the files the user leaves ticked (create-project.sh --init-git, N162). Nothing is pushed.
struct InitGitSheet: View {
    @Bindable var model: GitSuggestionModel
    let onDone: () -> Void

    /// Return closes the sheet; the commit needs a click or ⌘↵.
    static let defaultButton = SheetButton.cancel
    static let confirmShortcut = SheetShortcut.commandReturn

    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let sheet = model.initSheet
        let running = sheet?.phase == .running
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Initialize git").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text("Runs git init in \(sheet?.project.repoPath ?? "")\(sheet.map { " on " + $0.project.baseBranch } ?? ""), adds .agent-worktrees/ to .gitignore and makes the first commit with the ticked files. Nothing is pushed.")
                    .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let sheet, !sheet.files.isEmpty {
                HStack {
                    Text("\(sheet.ticked.count) of \(sheet.files.count) files").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    Spacer()
                    Button("All") { model.setAll(true) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work).disabled(running)
                    Button("None") { model.setAll(false) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work).disabled(running)
                }
                if snapshot { files(sheet) } else { ScrollView { files(sheet) }.frame(maxHeight: 300) }
            }
            statusLine
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(PanelButtonStyle()).keyboardShortcut(.defaultAction).disabled(running)
                Button("Initialize and commit (\(sheet?.ticked.count ?? 0))") { Task { await model.confirmInitGit() } }
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.return, modifiers: .command)
                    .disabled(sheet == nil || running || sheet?.phase == .loading || sheet?.files.isEmpty == true)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 560)
        .background(Tok.bg)
        .escapeCancels { if !running { onDone() } }
    }

    private func files(_ sheet: GitSuggestionModel.InitSheet) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(sheet.files, id: \.self) { file in
                Toggle(isOn: Binding(get: { !sheet.unticked.contains(file) }, set: { _ in model.toggle(file) })) {
                    HStack(spacing: Tok.Space.s) {
                        Text(file).font(Tok.Font.mono).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                        if file == GitSuggestionModel.InitSheet.gitignore { Text("always committed").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                    }
                }
                .toggleStyle(.checkbox).disabled(sheet.phase == .running || file == GitSuggestionModel.InitSheet.gitignore)
                .help(file == GitSuggestionModel.InitSheet.gitignore ? "Always committed: it keeps .agent-worktrees/ out of git" : "")
            }
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }

    @ViewBuilder private var statusLine: some View {
        switch model.initSheet?.phase {
        case .loading: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Listing the files…").font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .running: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Committing…").font(Tok.Font.body).foregroundStyle(Tok.ink2) }
        case .failed(let text): Text(text).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        case .ready where model.initSheet?.files.isEmpty == true:
            Text("The folder has no files git would add.").font(Tok.Font.body).foregroundStyle(Tok.ink2)
        default: EmptyView()
        }
    }
}

/// Push to GitHub (N178): shows what will happen; the button runs `gh repo create` / `git push`. Nothing runs before the click.
struct PushToGitHubSheet: View {
    @Bindable var model: GitSuggestionModel
    let onDone: () -> Void
    /// The commit whose full message shows under its row (a screenshot test sets one).
    @State var expanded: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            if let sheet = model.pushSheet {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sheet.willCreate ? "Create a GitHub repository" : "Push to GitHub").font(Tok.Font.title).foregroundStyle(Tok.ink)
                    Text(sheet.willCreate ? "Creates the repository on your account and pushes \(sheet.branch). Nothing happens until you click the button."
                                          : "Pushes \(sheet.branch) to origin. Nothing happens until you click the button.")
                        .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                }
                if sheet.phase == .loading {
                    Text("Reading the repository…").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                } else if sheet.inspection.problem == nil {
                    if sheet.willCreate { createForm(sheet) } else { pushDetails(sheet) }
                    Toggle("Also push the stable-N tags (\(sheet.inspection.tags.count))", isOn: Binding(get: { model.pushSheet?.alsoTags ?? false }, set: { model.pushSheet?.alsoTags = $0 }))
                        .toggleStyle(.checkbox).font(Tok.Font.body).foregroundStyle(Tok.ink2).disabled(sheet.inspection.tags.isEmpty || !sheet.canConfirm)
                }
                if case .done(let text) = sheet.phase {
                    Text(text).font(Tok.Font.bodyStrong).foregroundStyle(Tok.go).fixedSize(horizontal: false, vertical: true)
                } else if case .failed(let text) = sheet.phase {
                    Text(text).font(Tok.Font.body).foregroundStyle(Tok.wait).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if let text = sheet.problem {
                    Text(text).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Tok.Space.s + 2) {
                    if sheet.phase == .running { ProgressView().controlSize(.small); Text("Working…").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                    else { Text("Runs gh and git with your GitHub login; never a force push.").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                    Spacer()
                    if case .done = sheet.phase {
                        Button("Close", action: onDone).buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cancel", action: onDone).buttonStyle(PanelButtonStyle()).keyboardShortcut(.defaultAction).disabled(sheet.phase == .running)
                        if sheet.inspection.problem == nil, sheet.phase != .loading {
                            Button(sheet.buttonTitle) { Task { await model.confirmPush() } }
                                .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.return, modifiers: .command).disabled(!sheet.canConfirm)
                        }
                    }
                }
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 640)
        .background(Tok.bg)
        .escapeCancels { if model.pushSheet?.phase != .running { onDone() } }
    }

    private func createForm(_ sheet: GitSuggestionModel.PushSheet) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            HStack(spacing: Tok.Space.s) {
                FieldText(text: Binding(get: { model.pushSheet?.owner ?? "" }, set: { model.pushSheet?.owner = $0 }), placeholder: sheet.inspection.login.map { "\($0) (you)" } ?? "owner")
                Text("/").foregroundStyle(Tok.ink3)
                FieldText(text: Binding(get: { model.pushSheet?.name ?? "" }, set: { model.pushSheet?.name = $0 }), placeholder: "repository name")
            }
            HStack(spacing: Tok.Space.s) {
                choice("Private", selected: sheet.visibility == .privateRepo) { model.pushSheet?.visibility = .privateRepo }
                choice("Public", selected: sheet.visibility == .publicRepo) { model.pushSheet?.visibility = .publicRepo }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What will happen").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink3)
                Text("1. Create github.com/\(sheet.effectiveOwner)/\(sheet.name) (\(sheet.visibility == .privateRepo ? "private" : "public"))")
                Text("2. Add it as origin")
                Text("3. Push \(sheet.branch) (\(sheet.inspection.commitCount) commit\(sheet.inspection.commitCount == 1 ? "" : "s"))")
                Text("Agent branches (task/*) are not pushed. Tags stay on this Mac unless you tick the box.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            .font(Tok.Font.mono).foregroundStyle(Tok.ink)
            .padding(Tok.Space.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        }
    }

    private func pushDetails(_ sheet: GitSuggestionModel.PushSheet) -> some View {
        let list = sheet.commitList
        let locked = sheet.phase == .running || { if case .done = sheet.phase { true } else { false } }()
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(sheet.branch) → origin/\(sheet.branch)  \(sheet.inspection.remoteURL ?? "")").font(Tok.Font.mono).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                Text(list.shown.isEmpty ? "Nothing new to push." : sheet.choiceText + " · newest first")
                    .font(Tok.Font.small.weight(.semibold)).foregroundStyle(sheet.pushCount < sheet.inspection.commitCount ? Tok.wait : Tok.ink3)
            }
            .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
            if !list.shown.isEmpty {
                // A short list sits in the sheet as it is; a long one scrolls.
                if list.shown.count <= 8 { commitRows(sheet, list: list, locked: locked) }
                else { Scroller { commitRows(sheet, list: list, locked: locked) }.frame(height: 340) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
    }

    private func commitRows(_ sheet: GitSuggestionModel.PushSheet, list: (shown: [GitPublisher.Commit], more: Int), locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.shown.enumerated()), id: \.element.id) { index, commit in
                CommitRow(short: commit.short, subject: commit.subject, date: commit.date, message: commit.body,
                          expanded: expanded == commit.id, ticked: sheet.isTicked(index), tickDisabled: locked,
                          onTick: { model.togglePushCommit(index) },
                          onToggle: { expanded = expanded == commit.id ? nil : commit.id })
                if index < list.shown.count - 1 || list.more > 0 { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
            }
            if list.more > 0 {
                Toggle(isOn: Binding(get: { sheet.isTicked(list.shown.count) }, set: { _ in model.togglePushCommit(list.shown.count) })) {
                    Text("and \(list.more) older commit\(list.more == 1 ? "" : "s")").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
                .toggleStyle(.checkbox).disabled(locked)
                .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.s + 3)
            }
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Tok.Font.bodyStrong).foregroundStyle(selected ? Tok.ink : Tok.ink2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Tok.raise : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Tok.ink3 : Tok.line))
        }
        .buttonStyle(.plain)
    }
}

/// The kind of a Waiting for you item: a small dot and the label in the kind's colour (N182).
struct WaitingChip: View {
    let text: String
    let tint: WaitingTint
    /// Off where the row already starts with the kind's dot (the waiting round).
    var dot = true

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tint.color).frame(width: 6, height: 6) }
            Text(text).font(Tok.Font.small.weight(.semibold)).foregroundStyle(tint.color)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tint.color.opacity(WaitingTint.chipOpacity), in: Capsule())
    }
}

private struct WaitingRow<Actions: View>: View {
    let chip: String
    let tint: WaitingTint
    let title: String
    let detail: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            WaitingChip(text: chip, tint: tint)
            Text(title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(2)
            if let detail { Text(detail).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Tok.Space.s) { actions() }
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        .accessibilityElement(children: .contain)
    }
}

private struct DashboardLabel: View {
    let text: String
    var color: Color = Tok.ink3

    var body: some View {
        Text(text.uppercased()).font(Tok.Font.small.weight(.semibold)).kerning(0.6).foregroundStyle(color)
    }
}

private extension View {
    /// The Dashboard's card: the pane colour, rounded, with the line around it.
    func dashboardCard() -> some View {
        background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}

/// The Goal card: the goal text, the Plan link and the followed (or picked) round with its progress and cards.
struct GoalCard: View {
    let goal: String
    let plan: PlanLoad
    let cards: [TaskCard]
    var pick: GoalPick?
    var onPick: (String?) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    var onOpenPlan: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack {
                DashboardLabel(text: "Goal")
                Spacer()
                Button("Plan", action: onOpenPlan).buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work)
                    .help("Open the Plan screen to edit the goal and see every round")
            }
            Text(goal.isEmpty ? "No goal yet. Write it on the Plan screen; the PM plans against it." : goal)
                .font(Tok.Font.body).foregroundStyle(goal.isEmpty ? Tok.ink3 : Tok.ink).lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            roundSummary
        }
        .padding(Tok.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    /// The round the card shows: the picked or current one, never a round without cards ("0 / 0 done", N305); nil says "No round planned yet."
    static func shownRound(in file: PlanFile, cards: [TaskCard], pick: GoalPick?) -> PlanRound? {
        [goalRound(in: file, cards: cards, pick: pick), currentRound(in: file, cards: cards)].compactMap { $0 }.first { !$0.cards.isEmpty }
    }

    private func roundPicker(_ file: PlanFile, current: PlanRound) -> some View {
        Menu {
            Button("Current") { onPick(nil) }
            ForEach(goalRoundGroups(in: file, cards: cards), id: \.title) { g in
                Section(g.title) {
                    ForEach(g.rounds) { r in
                        Button(r.name) { onPick(r.name) }
                    }
                }
            }
        } label: { Image(systemName: "chevron.up.chevron.down").font(Tok.Font.small) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Show another round")
    }

    @ViewBuilder private var roundSummary: some View {
        if case .plan(let file) = plan, let round = Self.shownRound(in: file, cards: cards, pick: pick) {
            let p = PlanReader.progress(of: round, cards: cards)
            let status = Dictionary(cards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            HStack(alignment: .firstTextBaseline) {
                Text("Round · \(round.name)").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
                roundPicker(file, current: round)
                Spacer()
                Text("\(p.done) / \(p.total) done").font(Tok.Font.mono).foregroundStyle(Tok.ink2)
            }
            .padding(.top, Tok.Space.xs)
            UsageBar(fraction: Double(p.done) / Double(max(p.total, 1)), fill: Tok.go, height: 6, track: Tok.raise)
            FlowLayout(spacing: Tok.Space.xs + 2, lineSpacing: Tok.Space.xs + 2) {
                ForEach(round.cards, id: \.self) { id in
                    Button { onOpen(id) } label: { Chip(text: id, style: status[id] == .done ? .ok : (status[id] == .needsFix ? .problem : .neutral)) }
                        .buttonStyle(.plain).help("Open \(id) on the Tasks screen")
                }
            }
        } else if case .broken = plan {
            Text("plan.json could not be read; the Plan screen says why.").font(Tok.Font.small).foregroundStyle(Tok.wait)
        } else {
            Text("No round planned yet.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
        }
    }
}

/// N345/N356: a layout's 6×4 grid in miniature for the widget menu: the whole grid as a faint frame (so empty space reads as empty),
/// each tile a grey block with a hairline edge, the PM chat always in the accent. The active one is a little stronger.
struct DashboardLayoutThumbnail: View {
    let tiles: [DashboardTile]
    var active = false

    static let size = CGSize(width: 44, height: 30)
    static let inset: CGFloat = 2
    static let gap: CGFloat = 1.5

    var body: some View {
        let inner = CGSize(width: Self.size.width - 2 * Self.inset, height: Self.size.height - 2 * Self.inset)
        let cw = inner.width / CGFloat(DashboardGridLayout.columns), rh = inner.height / CGFloat(DashboardGridLayout.rows)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3.5).fill(Tok.ink3.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Tok.ink3.opacity(0.35), lineWidth: 0.75))
            ForEach(tiles, id: \.widget) { t in
                let chat = t.widget == .chat
                RoundedRectangle(cornerRadius: 2)
                    .fill(chat ? Tok.work.opacity(active ? 0.9 : 0.7) : Tok.ink3.opacity(active ? 0.6 : 0.45))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(chat ? Tok.work : Tok.ink2.opacity(0.6), lineWidth: 0.5))
                    .frame(width: CGFloat(t.columns) * cw - Self.gap, height: CGFloat(t.rows) * rh - Self.gap)
                    .offset(x: Self.inset + CGFloat(t.column) * cw + Self.gap / 2, y: Self.inset + CGFloat(t.row) * rh + Self.gap / 2)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
