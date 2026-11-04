import SwiftUI

/// A menu whose whole label is the click target. (A menu laid over a styled label with a clear label of its own is only as big as
/// its tiny indicator, so a click on the visible label did nothing.) Snapshots draw the label alone: ImageRenderer cannot draw a Menu.
struct MenuBox<Items: View, Label: View>: View {
    @ViewBuilder let items: () -> Items
    @ViewBuilder let label: () -> Label
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            label()
        } else {
            Menu { items() } label: { label() }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
        }
    }
}
