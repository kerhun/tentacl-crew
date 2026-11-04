import SwiftUI
import AppKit

/// A thin line the user drags to resize the area next to it. `horizontal` resizes widths (a vertical line, ↔ cursor),
/// `vertical` resizes heights (a horizontal line, ↕ cursor). `onDrag` gets how far the pointer moved since the last call,
/// to the right or down; double-click calls `onReset`; `onEnd` runs when a drag ends. `label` and `value` replace the VoiceOver words;
/// `onAdjust` (1 or -1 per VoiceOver step) makes the handle adjustable.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    var help = ""
    let onDrag: (Double) -> Void
    var onReset: () -> Void = {}
    var onEnd: () -> Void = {}
    var label: String?
    var value: String?
    var onAdjust: ((Int) -> Void)?
    @State private var last: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(hovering ? Tok.work.opacity(0.6) : Tok.line)
                .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
        }
        .frame(width: axis == .horizontal ? 7 : nil, height: axis == .vertical ? 7 : nil)
        .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let now = axis == .horizontal ? value.translation.width : value.translation.height
                onDrag(Double(now - last))
                last = now
            }
            .onEnded { _ in last = 0; onEnd() })
        .onTapGesture(count: 2) { onReset() }
        .help(help)
        .accessibilityElement()
        .accessibilityLabel(label ?? (axis == .horizontal ? "Column width" : "Conversation height"))
        .accessibilityValue(value ?? "")
        .accessibilityAddTraits(.isButton)
        .modifier(AdjustableIf(onAdjust: onAdjust))
    }
}

/// VoiceOver's up and down gestures on the handle, when it has an action for them.
private struct AdjustableIf: ViewModifier {
    let onAdjust: ((Int) -> Void)?

    func body(content: Content) -> some View {
        if let onAdjust {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(1)
                case .decrement: onAdjust(-1)
                @unknown default: break
                }
            }
        } else {
            content
        }
    }
}
