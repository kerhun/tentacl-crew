import Foundation
import Observation

/// What the Command box keeps for one project and one target agent: the thread, the unsent draft (text and images) and where the thread is scrolled to.
@MainActor @Observable
final class ChatSession {
    let chat: ChatModel
    var text = ""
    var images: [PendingImage] = []
    /// Where the thread is scrolled to: the bottom, or the place the user left it.
    let place = ChatPlace()
    /// The rows the user opened or closed (Show all, a tools line, a stack of panel notes), so a tab switch does not reset them.
    let opened = ChatOpenRows()
    /// The conversations before the last restart (/clear), oldest first; shown above the thread as the previous conversation.
    private(set) var previous: [ChatEntry] = []

    init(chat: ChatModel) { self.chat = chat }

    func clearDraft() { text = ""; images = [] }

    /// The agent's conversation was restarted: what was in the thread stays readable above the new one.
    func startNewThread(keeping old: [ChatEntry]) {
        previous += old
        place.follow()
    }
}

/// The open state the user gave the thread's rows, by kind and row id. A row not in it keeps its default; only a state that
/// differs from the default is kept (closing a default-open row too). Entry ids come from the transcript and never repeat,
/// so a new conversation leaves it as it is.
@MainActor @Observable
final class ChatOpenRows {
    enum Kind: String { case turn, tools, system }
    private(set) var states: [String: Bool] = [:]

    func isOpen(_ kind: Kind, _ id: String, default open: Bool) -> Bool { states["\(kind.rawValue):\(id)"] ?? open }
    func set(_ kind: Kind, _ id: String, open: Bool, default byDefault: Bool) {
        states["\(kind.rawValue):\(id)"] = open == byDefault ? nil : open
    }
}

/// The Command box's sessions, owned by the panel model so they outlive the views (tab, screen and project switches rebuild those).
@MainActor
final class ChatStore {
    private var sessions: [String: ChatSession] = [:]

    func session(project: String, pane: String, projectsRoot: URL? = nil) -> ChatSession {
        let key = "\(project)|\(pane)"
        if let found = sessions[key] { return found }
        let made = ChatSession(chat: projectsRoot.map { ChatModel(projectsRoot: $0) } ?? ChatModel())
        sessions[key] = made
        return made
    }

    /// The session if the Command box already made it; never creates one.
    func existingSession(project: String, pane: String) -> ChatSession? { sessions["\(project)|\(pane)"] }

    private func sessions(of project: String) -> [ChatSession] {
        sessions.filter { $0.key.hasPrefix("\(project)|") }.map(\.value)
    }

    func unread(project: String) -> Bool { sessions(of: project).contains { $0.chat.unread } }
    func markSeen(project: String) { sessions(of: project).forEach { $0.chat.markSeen() } }
}
