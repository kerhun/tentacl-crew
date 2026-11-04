import Foundation

/// Stop on the chat's working line (N293): Esc to the PM's pane, the key that interrupts its turn.
extension PanelModel {
    /// Sends Esc to the selected project's PM. Returns whether the key went; a failure shows in the action line.
    @discardableResult
    func interruptPM() async -> Bool {
        guard let id = selectedProjectID, let pane = pmPane(forProject: id) else { return false }
        do {
            try await makeKeySender().sendKeys(target: pane, keys: ["esc"])
            return true
        } catch {
            setActionState(.failed("The PM could not be interrupted: \(error.localizedDescription)"))
            return false
        }
    }
}
