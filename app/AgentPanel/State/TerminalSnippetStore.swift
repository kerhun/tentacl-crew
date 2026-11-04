import Foundation

/// A saved command (N272): typed into the focused pane on the user's click; `runAtOnce` adds Return.
struct TerminalSnippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    var runAtOnce = false
}

/// Which list: one per project, or the global one.
enum TerminalSnippetScope: Hashable {
    case project(String)
    case global
}

/// The saved commands in UserDefaults: one key per project and one global key. Nothing here sends anything.
struct TerminalSnippetStore {
    static let globalKey = "terminals.snippets.global"
    static func key(_ scope: TerminalSnippetScope) -> String {
        switch scope {
        case .project(let id): "terminals.snippets.\(id)"
        case .global: globalKey
        }
    }

    let defaults: UserDefaults

    func load(_ scope: TerminalSnippetScope) -> [TerminalSnippet] {
        defaults.data(forKey: Self.key(scope)).flatMap { try? JSONDecoder().decode([TerminalSnippet].self, from: $0) } ?? []
    }

    func save(_ list: [TerminalSnippet], _ scope: TerminalSnippetScope) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key(scope)) }
    }

    /// Appends a command; nil (nothing saved) when the text is empty. A blank name falls back to the first line of the text.
    @discardableResult
    func add(name: String, text: String, runAtOnce: Bool, to scope: TerminalSnippetScope) -> TerminalSnippet? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let title = name.trimmingCharacters(in: .whitespaces)
        let item = TerminalSnippet(name: title.isEmpty ? String(body.prefix(40)) : title, text: body, runAtOnce: runAtOnce)
        save(load(scope) + [item], scope)
        return item
    }

    func update(_ item: TerminalSnippet, in scope: TerminalSnippetScope) {
        var list = load(scope)
        guard let i = list.firstIndex(where: { $0.id == item.id }), !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        list[i] = item
        save(list, scope)
    }

    func delete(_ id: UUID, from scope: TerminalSnippetScope) { save(load(scope).filter { $0.id != id }, scope) }

    func move(_ id: UUID, by step: Int, in scope: TerminalSnippetScope) {
        var list = load(scope)
        guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + step) else { return }
        list.swapAt(i, i + step)
        save(list, scope)
    }
}

/// How a saved command reaches a pane.
enum TerminalSnippetSend {
    enum Route: Equatable {
        /// A shell: the bytes go to its live session (text, plus Return when run at once).
        case shell(bytes: [UInt8])
        /// An agent pane: through the ⌘L box's path (`TerminalComposer.send`) when run at once, else into the open box to be read first.
        /// No raw keystrokes reach an agent's prompt menu.
        case agentPrompt(text: String)
        case agentBox(text: String)
    }

    static func route(_ item: TerminalSnippet, pane: String) -> Route {
        if TerminalShells.isUserShell(pane) {
            return .shell(bytes: Array(item.text.replacingOccurrences(of: "\n", with: "\r").utf8) + (item.runAtOnce ? [0x0D] : []))
        }
        return item.runAtOnce ? .agentPrompt(text: item.text) : .agentBox(text: item.text)
    }
}
