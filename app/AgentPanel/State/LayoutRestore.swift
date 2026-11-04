import SwiftUI

/// Where the user left the window, so a relaunch (or an update) opens there again (N260): one record for the window (the screen; the
/// frame is the window's own autosave), one per project (the open card and its tab). The project itself is `selectedProject` (N132),
/// the Terminals panes `TerminalPaneStore` (N245), the Dashboard Preview `ChatPreviewState` (N254). Anything that no longer exists
/// falls back quietly: an unknown screen opens the Dashboard, a gone card opens no card, a tab the card no longer has opens Overview.
enum LayoutRestore {
    /// What one project showed.
    struct ProjectRecord: Codable, Equatable {
        var card: String?
        /// The detail's tab (`TaskDetailView.Tab` raw value); belongs to `card`.
        var tab: String?
    }

    static let screenKey = "layout.window.screen"
    static func projectKey(_ project: String) -> String { "layout.project.\(project)" }
    /// The window's frame, saved by AppKit under this name.
    static let frameName = "TentaclMainWindow"

    static func screen(_ defaults: UserDefaults) -> ShellScreen { ShellScreen(stored: defaults.string(forKey: screenKey) ?? "") }
    static func saveScreen(_ defaults: UserDefaults, _ screen: ShellScreen) { defaults.set(screen.rawValue, forKey: screenKey) }

    static func record(_ defaults: UserDefaults, project: String) -> ProjectRecord? {
        defaults.data(forKey: projectKey(project)).flatMap { try? JSONDecoder().decode(ProjectRecord.self, from: $0) }
    }

    static func save(_ defaults: UserDefaults, project: String, _ record: ProjectRecord) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: projectKey(project)) }
    }

    /// The card to open again: the saved one while the project still has it, else none.
    static func card(_ record: ProjectRecord?, in cards: [TaskCard]) -> String? {
        guard let id = record?.card, cards.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The tab to open `card` on: the saved one when it was saved for this card and the card can show it now, else nil (the usual tab).
    static func tab(_ record: ProjectRecord?, card: TaskCard, shots: Int) -> TaskDetailView.Tab? {
        guard let record, record.card == card.id, let raw = record.tab, let tab = TaskDetailView.Tab(rawValue: raw) else { return nil }
        return DetailTab.items(card: card, shots: shots).contains { $0.tab == tab && $0.enabled } ? tab : nil
    }
}

/// Gives the window its frame autosave name once it has one: AppKit puts it back where and how big it was, and saves every move.
struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    final class Probe: NSView {
        var name = ""
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName != name else { return }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
    }

    func makeNSView(context: Context) -> Probe { let v = Probe(); v.name = name; return v }
    func updateNSView(_ view: Probe, context: Context) { view.name = name }
}
