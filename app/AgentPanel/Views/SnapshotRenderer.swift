import SwiftUI
import AppKit

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while the window is rendered to a PNG: images must be there on the first frame and nothing scrolls.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// Renders the whole window to PNG data (`--snapshot <path>`), so a layout can be checked without a screen.
@MainActor
enum SnapshotRenderer {
    static func render(model: PanelModel, size: CGSize, scale: CGFloat = 2) -> Data? {
        render(view: ShellView(model: model), size: size, scale: scale)
    }

    /// Renders any view (a sheet, a single column) the same way.
    static func render<V: View>(view: V, size: CGSize, scale: CGFloat = 2) -> Data? {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.snapshotMode, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// A scroll view that becomes a plain clipped stack while rendering a snapshot (ImageRenderer cannot draw scroll views).
struct Scroller<Content: View>: View {
    var axes: Axis.Set = .vertical
    @ViewBuilder var content: () -> Content
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            // An overlay does not add to the layout size, so tall content cannot push the window bars out of the frame.
            Color.clear.overlay(alignment: .topLeading) { content() }.clipped()
        } else {
            ScrollView(axes) { content() }
        }
    }
}
