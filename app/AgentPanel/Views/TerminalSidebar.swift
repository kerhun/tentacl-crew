import SwiftUI

/// The sidebar's groups (N234): PM · CARDS · SHELLS, each in `TerminalTabs.make`'s order. Empty groups are left out.
enum TerminalSidebarGroups {
    struct Group: Equatable, Identifiable {
        let name: String
        let tabs: [TerminalTab]
        var id: String { name }
    }

    static func make(_ tabs: [TerminalTab]) -> [Group] {
        [("PM", TerminalTab.Kind.pm), ("CARDS", .card), ("SHELLS", .shell)].compactMap { name, kind in
            let list = tabs.filter { $0.kind == kind }
            return list.isEmpty ? nil : Group(name: name, tabs: list)
        }
    }

    /// The row's tooltip: "N302 · Asks you · ⌘2".
    static func help(_ tab: TerminalTab, digit: Int) -> String { "\(tab.label) · \(tab.stateLabel)" + (digit <= 9 ? " · ⌘\(digit)" : "") }

    static func accessibilityLabel(_ tab: TerminalTab, pane: Int?) -> String {
        "\(tab.label) \(tab.title), \(tab.stateLabel)" + (pane.map { ", in pane \($0)" } ?? "")
    }
}

/// What the AGENT column showed (N224), now in a pane header's "i" popover and the sidebar row's right-click menu (N234).
struct TerminalAgentInfo {
    let role: String
    let branch: String
    let model: String
    let restart: StartButtonState
    let stop: StartButtonState
    /// nil for the PM and a shell: they have no card.
    let onOpenCard: (() -> Void)?
    let onOpenChanges: (() -> Void)?
    let onRestart: () -> Void
    let onStop: () -> Void
    /// Only for the user's own shell (N245): closes it (kills the session).
    var onCloseShell: (() -> Void)? = nil
}

/// The Terminals screen's left column (N234, board A): the open terminals in groups, the pane each one is shown in, and the local pages.
/// Open by default; the button in the header shrinks it to icons and ids (saved). A row is clicked (focused pane), dragged onto a
/// pane (replace or split), or right-clicked (the agent's facts and actions).
struct TerminalSidebar: View {
    static let width: CGFloat = 264
    static let collapsedWidth: CGFloat = 76

    let tabs: [TerminalTab]
    /// The pane number of each terminal on screen; only shown with more than one pane.
    let paneNumbers: [String: Int]
    let focusedTerminal: String?
    let collapsed: Bool
    let localPages: [TerminalPreview.Row]
    let info: (TerminalTab) -> TerminalAgentInfo
    let onPick: (String) -> Void
    let onToggle: () -> Void
    let onDragStart: (String) -> Void
    let onOpenPage: (TerminalPreview.Row) -> Void
    /// The header's "+": the user's own shell in the project folder (N245). nil: not offered.
    var onNewShell: (() -> Void)? = nil
    var newShellHelp = "Open a new shell in the project folder"

    private var showsNumbers: Bool { paneNumbers.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Tok.line)
            Scroller(axes: .vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(TerminalSidebarGroups.make(tabs)) { group in
                        if collapsed {
                            Rectangle().fill(Tok.line).frame(height: 1).padding(.horizontal, 6).padding(.vertical, Tok.Space.s)
                        } else {
                            Text(group.name).font(Tok.Font.small.weight(.semibold)).tracking(0.8).foregroundStyle(Tok.ink2)
                                .padding(.horizontal, Tok.Space.s).padding(.top, Tok.Space.m).padding(.bottom, 6)
                        }
                        ForEach(group.tabs) { tab in row(tab, digit: (tabs.firstIndex(of: tab) ?? 99) + 1) }
                    }
                }
                .padding(.horizontal, Tok.Space.s).padding(.top, 6).padding(.bottom, Tok.Space.s + 2)
            }
            if !collapsed {
                if !localPages.isEmpty { pagesBox }
                Text(showsNumbers ? "Click a terminal to load it into the focused pane; the one in another pane swaps. Drag one onto a pane's edge to split."
                                  : "⌘1–9 opens a terminal. Drag one onto the pane's edge, or press ⌘D, to put a second one beside it.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tok.Space.m + 2).padding(.vertical, Tok.Space.s + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
            }
        }
        .frame(width: collapsed ? Self.collapsedWidth : Self.width)
        .frame(maxHeight: .infinity)
        .background(Tok.list)
        .overlay(alignment: .trailing) { Rectangle().fill(Tok.line).frame(width: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("Open terminals")
    }

    private var header: some View {
        HStack(spacing: Tok.Space.s) {
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Terminals").font(Tok.Font.body.weight(.semibold)).foregroundStyle(Tok.ink)
                    Text(TerminalTabs.countText(tabs)).font(Tok.Font.small).foregroundStyle(Tok.ink2)
                }
                Spacer(minLength: 0)
                Button { onNewShell?() } label: {
                    Text("+").font(.system(size: 15)).foregroundStyle(Tok.ink).frame(width: 28, height: 28)
                        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.line))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(onNewShell == nil).opacity(onNewShell == nil ? 0.45 : 1)
                .help(newShellHelp)
                .accessibilityLabel("New shell").accessibilityHint(newShellHelp)
            }
            Button(action: onToggle) {
                Image(systemName: collapsed ? "sidebar.right" : "sidebar.left").font(.system(size: 13)).foregroundStyle(Tok.ink2)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show terminal names" : "Show icons only")
            .accessibilityLabel(collapsed ? "Show terminal names" : "Show icons only")
        }
        .padding(.leading, collapsed ? 0 : Tok.Space.m + 2).padding(.trailing, collapsed ? 0 : Tok.Space.m)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: collapsed ? .center : .leading)
    }

    private func row(_ tab: TerminalTab, digit: Int) -> some View {
        let pane = paneNumbers[tab.paneID]
        let inFocused = tab.paneID == focusedTerminal
        let facts = info(tab)
        return Button { onPick(tab.paneID) } label: {
            if collapsed { compactRow(tab, pane: pane, inFocused: inFocused) } else { fullRow(tab, pane: pane, inFocused: inFocused) }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(digit <= 9 ? KeyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: .command) : nil)
        .help(TerminalSidebarGroups.help(tab, digit: digit))
        .accessibilityLabel(TerminalSidebarGroups.accessibilityLabel(tab, pane: showsNumbers ? pane : nil))
        .accessibilityAddTraits(inFocused ? .isSelected : [])
        .onDrag {
            onDragStart(tab.paneID)
            return NSItemProvider(object: tab.paneID as NSString)
        }
        .contextMenu { menu(tab, facts) }
    }

    /// Icons only: the state icon over the id, the pane number as a badge.
    private func compactRow(_ tab: TerminalTab, pane: Int?, inFocused: Bool) -> some View {
        VStack(spacing: 3) {
            TerminalStateIcon(icon: tab.icon).frame(width: 16, height: 16)
            Text(tab.label).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tab.asks ? Tok.askInk : Tok.ink)
                .padding(.horizontal, 3)
                .background(tab.asks ? Tok.askText : .clear, in: RoundedRectangle(cornerRadius: 4))
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(inFocused ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(pane == nil ? .clear : (inFocused ? Tok.ink3 : Tok.line)))
        .overlay(alignment: .topTrailing) {
            if showsNumbers, let pane {
                Text("\(pane)").font(.system(size: 9, weight: .bold)).foregroundStyle(inFocused ? Tok.askInk : Tok.ink)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(inFocused ? Tok.you : Tok.line, in: RoundedRectangle(cornerRadius: 4))
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
    }

    private func fullRow(_ tab: TerminalTab, pane: Int?, inFocused: Bool) -> some View {
        HStack(spacing: Tok.Space.s) {
            TerminalStateIcon(icon: tab.icon).frame(width: 16, height: 16)
            Text(tab.label).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(tab.asks ? Tok.askInk : Tok.ink)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tab.asks ? Tok.askText : .clear, in: RoundedRectangle(cornerRadius: 5))
                .lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail)
                Text(tab.stateLabel).font(Tok.Font.small).foregroundStyle(tab.asks ? Tok.askText : Tok.ink2).lineLimit(1).truncationMode(.tail)
                if !tab.statusLine.isEmpty {
                    Text(tab.statusLine).font(Tok.Font.mono).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.tail).help(tab.statusLine)
                }
            }
            Spacer(minLength: 0)
            if let port = tab.port {
                Text(port).font(.system(size: 10, design: .monospaced)).foregroundStyle(WaitingTint.review.color)
                    .padding(.horizontal, Tok.Space.xs).overlay(RoundedRectangle(cornerRadius: 5).stroke(Tok.line)).fixedSize()
                    .accessibilityLabel("Serves a local page on \(port)")
            }
            if tab.unread && pane == nil { Circle().fill(Tok.go).frame(width: 7, height: 7).accessibilityLabel("New output") }
            if showsNumbers, let pane {
                Text("\(pane)").font(.system(size: 11, weight: .bold)).foregroundStyle(inFocused ? Tok.askInk : Tok.ink)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(inFocused ? Tok.you : Tok.line, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("In pane \(pane)")
            }
        }
        .padding(.horizontal, Tok.Space.s).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(inFocused ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(pane == nil ? .clear : (inFocused ? Tok.ink3 : Tok.line)))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func menu(_ tab: TerminalTab, _ facts: TerminalAgentInfo) -> some View {
        Text("\(tab.label) · \(tab.stateLabel)")
        Text("Role: \(facts.role)")
        Text("Branch: \(facts.branch)")
        Text("Model: \(facts.model)")
        Divider()
        Button("Open card") { facts.onOpenCard?() }.disabled(facts.onOpenCard == nil)
        Button("Changes") { facts.onOpenChanges?() }.disabled(facts.onOpenChanges == nil)
        Divider()
        Button(facts.restart.enabled ? "Restart" : "Restart — \(facts.restart.help)", action: facts.onRestart).disabled(!facts.restart.enabled)
        Button(facts.stop.enabled ? "Stop…" : "Stop — \(facts.stop.help)", action: facts.onStop).disabled(!facts.stop.enabled)
        if let close = facts.onCloseShell {
            Divider()
            Button("Close shell…", action: close)
        }
    }

    /// LOCAL PAGES: a row loads its terminal into the focused pane and opens Preview (it serves a page, so Preview can open).
    private var pagesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOCAL PAGES").font(Tok.Font.small.weight(.semibold)).tracking(0.8).foregroundStyle(Tok.ink2)
            ForEach(localPages) { row in
                Button { onOpenPage(row) } label: {
                    HStack(spacing: Tok.Space.s) {
                        Circle().fill(Tok.go).frame(width: 7, height: 7)
                        Text(TerminalPreview.port(row.page.url)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink)
                        Text(row.label).font(.system(size: 12)).foregroundStyle(Tok.ink2).lineLimit(1)
                        Spacer(minLength: Tok.Space.xs)
                        Text("Preview").font(.system(size: 12)).foregroundStyle(WaitingTint.review.color)
                    }
                    .padding(.horizontal, Tok.Space.s).frame(height: 30)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(row.page.url.absoluteString) in Preview")
                .accessibilityLabel("\(TerminalPreview.port(row.page.url)) from \(row.label), Preview")
            }
        }
        .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
    }
}
