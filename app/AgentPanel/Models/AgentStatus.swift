import Foundation

enum AgentState: Equatable {
    case working, idle, blocked, done
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "working": self = .working
        case "idle": self = .idle
        case "blocked": self = .blocked
        case "done": self = .done
        default: self = .unknown(raw)
        }
    }
}

/// One agent session of the terminal (tentacld).
struct AgentStatus: Identifiable, Equatable {
    let paneID: String
    let workspaceID: String
    let state: AgentState
    let cwd: String
    let title: String
    /// The Claude session running in the pane. A pane id can be reused; the session id tells who is really there.
    var sessionID: String? = nil
    /// The counter of state changes for this agent; a new value means the screen may show something new.
    var changeSeq: Int? = nil
    /// The name the agent was started with; a session the user started by hand has none.
    var name: String? = nil
    /// What the program reports with OSC 7501 right now (its `msg`, else its `title`); nil when it reports nothing live.
    var liveMessage: String? = nil
    var id: String { paneID }
}

/// One workspace of the terminal: the session an agent runs in.
struct WorkspaceInfo: Identifiable, Equatable {
    let workspaceID: String
    let label: String
    let checkoutPath: String?
    let isLinkedWorktree: Bool
    var id: String { workspaceID }
}
