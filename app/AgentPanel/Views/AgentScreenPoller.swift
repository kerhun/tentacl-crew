import SwiftUI

/// Reads one agent's screen on a timer, but only between `appear()` and `disappear()` (the view being open). Read-only.
@MainActor @Observable
final class AgentScreenPoller {
    private(set) var text = ""
    private(set) var error: String?
    @ObservationIgnored private let reader: TerminalReading
    @ObservationIgnored private let target: String?
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let lines: Int
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `lines`: how much of the screen is read (the Terminals screen reads more); `text`: what shows before the first read (snapshots).
    init(reader: TerminalReading, target: String?, interval: Duration = .seconds(2), lines: Int = 60, text: String = "") {
        self.reader = reader
        self.target = target
        self.interval = interval
        self.lines = lines
        self.text = text
    }

    func appear() {
        guard task == nil else { return }
        guard let target else { error = "No agent is running for this task."; return }
        task = Task { [weak self, reader, interval, lines] in
            while !Task.isCancelled {
                do {
                    let screen = try await reader.screen(of: target, lines: lines)
                    if Task.isCancelled { return }
                    self?.text = screen; self?.error = nil
                } catch {
                    if Task.isCancelled { return }
                    self?.error = (error as? LocalizedError)?.errorDescription ?? "Could not read the screen."
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func disappear() { task?.cancel(); task = nil }
}
