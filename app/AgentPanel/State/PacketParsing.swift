import Foundation

/// The parts of a "## Review packet" section written by scripts/review-packet.sh.
struct PacketSections: Equatable {
    var build = ""
    /// The branch tip the packet was built from; nil for packets written before the Head line existed.
    var head: String?
    var screenshots: [String] = []
    var diff = ""
    /// From the diffstat summary line ("2 files changed, ..."); nil when the packet has no diff.
    var filesChanged: Int?
    var buildPassed: Bool { build.hasPrefix("passed") }
    /// "Build: none …" is written for a project that has no build command.
    var buildAcceptable: Bool { buildPassed || build.hasPrefix("none") }
    /// "Screenshots: not used …" is written for a project that does not take screenshots; otherwise at least one is expected.
    var screenshotsNotUsed = false
    var screenshotsAcceptable: Bool { screenshotsNotUsed || !screenshots.isEmpty }
}

func packetSections(from text: String) -> PacketSections {
    var parts = PacketSections()
    enum Mode { case none, screenshots, diff }
    var mode = Mode.none
    var inFence = false
    var diffLines: [String] = []
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("Head: ") { parts.head = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); mode = .none; continue }
        if line.hasPrefix("Build: ") { parts.build = String(line.dropFirst(7)); mode = .none; continue }
        if line.hasPrefix("Screenshots: not used") { parts.screenshotsNotUsed = true; mode = .none; continue }
        if line.hasPrefix("Screenshots:") { mode = .screenshots; continue }
        if line.hasPrefix("Diff summary:") { mode = .diff; continue }
        switch mode {
        case .screenshots:
            if line.hasPrefix("- ") { parts.screenshots.append(String(line.dropFirst(2))) }
        case .diff:
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { diffLines.append(line) }
        case .none: break
        }
    }
    parts.diff = diffLines.joined(separator: "\n")
    if let summary = diffLines.last(where: { $0.contains("changed") }) {
        parts.filesChanged = summary.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
    }
    return parts
}

/// One line for an agent row: its state and the last two components of its working folder.
func agentSummaryLine(_ agent: AgentStatus) -> String {
    let state: String
    switch agent.state {
    case .working: state = "working"
    case .idle: state = "idle"
    case .blocked: state = "blocked"
    case .done: state = "done"
    case .unknown(let raw): state = raw
    }
    let parts = agent.cwd.split(separator: "/").map(String.init)
    guard !parts.isEmpty else { return state }
    return "\(state) · \(parts.suffix(2).joined(separator: "/"))"
}
