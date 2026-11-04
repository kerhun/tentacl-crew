import SwiftUI
import AppKit

/// Which button Return presses in a sheet. Merging or starting is never it.
enum SheetButton: Equatable { case cancel, confirm }

/// The key chord that confirms a risky step.
enum SheetShortcut: Equatable { case commandReturn }

/// Every sheet, alert and confirmation the window can show. `ShellView.close(_:)` switches over it without a default,
/// so a new case does not compile until it is closed there too (⌘Q and Relaunch close them all).
enum PanelSheet: String, CaseIterable {
    case startPlan, approve, approveRound, fixRequest, closeTask, leavingTeam, switchingProject, missingRole, addProject, editProject, newTask
    case updateStable, cleanup, round, autopilotRules, autopilotOn, roleTemplate, setup, gitInit, gitPush, questionFocus
}

/// The window registers one closure that closes all of its sheets; quitting calls it.
@MainActor final class SheetCloser {
    static let shared = SheetCloser()
    var closeAll: () -> Void = {}
}

@MainActor enum AppQuit {
    /// ⌘Q: an open sheet never blocks it.
    static func shouldTerminate() -> NSApplication.TerminateReply {
        SheetCloser.shared.closeAll()
        return .terminateNow
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { AppQuit.shouldTerminate() }
}

extension View {
    /// Esc still cancels while another button holds Return.
    func escapeCancels(_ action: @escaping () -> Void) -> some View {
        background(Button("", action: action).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
