import AppKit

/// The Dock icon's badge (what waits for the user) and its one bounce.
enum DockBadge {
    /// The number of waiting things as text; nil (no badge) at 0 or when the setting is off.
    static func label(count: Int, enabled: Bool) -> String? { enabled && count > 0 ? String(count) : nil }

    @MainActor static func apply(_ label: String?) {
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// One bounce, only while the app is not active.
    @MainActor static func bounce() {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }
}
