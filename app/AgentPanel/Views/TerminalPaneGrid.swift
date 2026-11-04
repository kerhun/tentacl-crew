import SwiftUI
import UniformTypeIdentifiers

/// Where a dragged sidebar row would land (N234): a pane and the zone the layout accepts there.
struct TerminalDropTarget: Equatable {
    let pane: Int
    let zone: TerminalPaneLayout.Zone
}

/// The row drag in progress (N245): the terminal dragged and the zone lit. A drop that ended or was cancelled clears both at once, and
/// an update that arrives after the drop (AppKit still sends one while the drag image settles) lights nothing.
@MainActor @Observable
final class TerminalDropState {
    private(set) var target: TerminalDropTarget?
    private(set) var dragging: String?
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var released = 0

    func begin(_ terminal: String) { dragging = terminal; ended = false; released = 0 }
    func enter(_ next: TerminalDropTarget) { guard dragging != nil else { return }; ended = false; target = next }
    func update(_ next: TerminalDropTarget) { guard !ended, dragging != nil, target != next else { return }; target = next }
    func leave(pane: Int) { if target?.pane == pane { target = nil } }
    /// The drop was made.
    func finish() { ended = true; target = nil; dragging = nil; released = 0 }
    /// The drag was cancelled or left the window.
    func cancel() { finish() }
    var isDragging: Bool { dragging != nil || target != nil }

    /// Polled while a drag is shown: a drag that shows still, with the button up twice in a row, was cancelled (Esc, dropped outside the
    /// window); nothing tells the destination then.
    func settle(buttonDown: Bool) {
        released = buttonDown ? 0 : released + 1
        if released >= 2 { cancel() }
    }
}

/// The panes of `TerminalPaneLayout` on screen: the split tree with draggable dividers, and a drop zone on every pane. While a row is
/// dragged over a pane, the zone it would get lights up (the middle: the whole pane, "Replace"; an edge: that half, "Split"). An edge the
/// layout cannot split on (4 panes, or a third column or row) does not light up: the drop replaces.
struct TerminalPaneGrid<Content: View>: View {
    let node: TerminalPaneLayout.Node
    let layout: TerminalPaneLayout
    let preview: Bool
    /// False for the pane pair shown beside Preview (not the saved tree): its divider does not resize.
    let resizable: Bool
    let drops: TerminalDropState
    /// Snapshots: a zone lit as if a row were dragged.
    var shownTarget: TerminalDropTarget? = nil
    let onDrop: (Int, TerminalPaneLayout.Zone, [NSItemProvider]) -> Void
    let onRatio: ([Bool], Double) -> Void
    /// A divider drag ended (or a step of VoiceOver's): the layout is saved.
    var onRatioEnd: () -> Void = {}
    @ViewBuilder let content: (TerminalPaneLayout.Pane) -> Content
    @Environment(\.snapshotMode) private var snapshot

    var body: some View { view(node, path: []) }

    private func view(_ node: TerminalPaneLayout.Node, path: [Bool]) -> AnyView {
        switch node {
        case .pane(let id, _):
            guard let pane = layout.pane(id) else { return AnyView(Color.clear) }
            return AnyView(paneView(pane))
        case .split(let axis, let a, let b, let ratio):
            return AnyView(GeometryReader { g in
                let total = (axis == .row ? g.size.width : g.size.height) - Self.handle
                if axis == .row {
                    HStack(spacing: 0) {
                        view(a, path: path + [false]).frame(width: max(0, total * ratio))
                        divider(.horizontal, ratio: ratio, total: total, path: path, resizable: resizable)
                        view(b, path: path + [true])
                    }
                } else {
                    VStack(spacing: 0) {
                        view(a, path: path + [false]).frame(height: max(0, total * ratio))
                        divider(.vertical, ratio: ratio, total: total, path: path, resizable: resizable)
                        view(b, path: path + [true])
                    }
                }
            })
        }
    }

    private static var handle: CGFloat { 7 }

    @ViewBuilder private func divider(_ axis: ResizeHandle.Axis, ratio: Double, total: CGFloat, path: [Bool], resizable: Bool) -> some View {
        if resizable {
            ResizeHandle(axis: axis, help: "Drag to resize the panes · double-click to make them equal",
                         onDrag: { delta in if total > 0 { onRatio(path, ratio + delta / total) } }, onReset: { onRatio(path, 0.5); onRatioEnd() }, onEnd: onRatioEnd,
                         label: TerminalDividerAccessibility.label(axis: axis == .horizontal ? .row : .column), value: TerminalDividerAccessibility.value(ratio: ratio),
                         onAdjust: { steps in onRatio(path, TerminalDividerAccessibility.adjusted(ratio, steps: steps)); onRatioEnd() })
        } else {
            Color.clear.frame(width: axis == .horizontal ? Self.handle : nil, height: axis == .vertical ? Self.handle : nil)
        }
    }

    private func paneView(_ pane: TerminalPaneLayout.Pane) -> some View {
        GeometryReader { g in
            let shown = content(pane)
                .frame(width: g.size.width, height: g.size.height)
                .overlay { highlight(pane, size: g.size) }
            // The drop target is an AppKit view the snapshot renderer cannot draw.
            if snapshot {
                shown
            } else {
                shown.onDrop(of: [.text, .plainText, .utf8PlainText], delegate: PaneDropDelegate(pane: pane.id, size: g.size, accept: { zone in
                    layout.accepted(zone, on: pane.id, preview: preview)
                }, drops: drops, perform: onDrop))
            }
        }
    }

    @ViewBuilder private func highlight(_ pane: TerminalPaneLayout.Pane, size: CGSize) -> some View {
        if let target = shownTarget ?? drops.target, target.pane == pane.id {
            let rect = Self.rect(of: target.zone, in: size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Tok.radius).fill(Tok.you.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.you, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .overlay {
                        Text(target.zone == .center ? "Replace pane \(pane.number)" : "Split pane \(pane.number)")
                            .font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.askInk)
                            .padding(.horizontal, Tok.Space.s).padding(.vertical, 3).background(Tok.you, in: Capsule())
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The lit part of a pane: all of it for the middle, the half on the edge's side for a split.
    static func rect(of zone: TerminalPaneLayout.Zone, in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch zone {
        case .center: return CGRect(x: 0, y: 0, width: w, height: h)
        case .left: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .right: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        }
    }
}

private struct PaneDropDelegate: DropDelegate {
    let pane: Int
    let size: CGSize
    let accept: (TerminalPaneLayout.Zone) -> TerminalPaneLayout.Zone
    let drops: TerminalDropState
    let perform: (Int, TerminalPaneLayout.Zone, [NSItemProvider]) -> Void

    private func target(_ info: DropInfo) -> TerminalDropTarget {
        TerminalDropTarget(pane: pane, zone: accept(TerminalPaneLayout.zone(at: info.location, in: size)))
    }

    /// Only a row dragged from the sidebar (a drag of text from another app has no row behind it).
    func validateDrop(info: DropInfo) -> Bool { drops.dragging != nil }

    func dropEntered(info: DropInfo) { drops.enter(target(info)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drops.update(target(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { drops.leave(pane: pane) }

    func performDrop(info: DropInfo) -> Bool {
        let zone = target(info).zone
        perform(pane, zone, info.itemProviders(for: [.text, .plainText, .utf8PlainText]))
        drops.finish()
        return true
    }
}

/// What VoiceOver says about a pane divider and how its steps move it (N245).
enum TerminalDividerAccessibility {
    static func label(axis: TerminalPaneLayout.Axis) -> String {
        axis == .row ? "Divider between the left and right panes" : "Divider between the top and bottom panes"
    }

    /// The first pane's share.
    static func value(ratio: Double) -> String { "\(Int((ratio * 100).rounded())) percent" }

    /// One step is 5 %, kept between 20 and 80 %.
    static func adjusted(_ ratio: Double, steps: Int) -> Double { min(0.8, max(0.2, ratio + 0.05 * Double(steps))) }
}
