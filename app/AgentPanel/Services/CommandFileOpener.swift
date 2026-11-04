import AppKit
import Foundation

/// Opens a `.command` file with Terminal.app (no AppleScript, so no extra permission): for the installers and checks that need a
/// real terminal window of their own (Homebrew's password prompt, `gh auth login`, a tool's `--version` for the user to read).
enum CommandFileOpener {
    static func open(_ file: URL) async throws {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: config)
    }
}
