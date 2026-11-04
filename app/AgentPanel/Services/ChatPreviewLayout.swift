import Foundation
import Observation

/// Which tab the PM chat card shows on a narrow window (N248): the Chat tab is the chat, the Preview tab is the Preview over it.
enum ChatPreviewTab: Equatable { case chat, preview }

/// Where the chat's Preview is on the Dashboard (N254): hidden, over the PM chat card (same frame), or over the whole Dashboard
/// area under the strip. The same on every window width; a narrow window only adds the Chat | Preview tabs.
enum ChatPreviewLayout: Equatable {
    case chat, inChat, expanded

    static func of(shown: Bool, expanded: Bool) -> ChatPreviewLayout {
        guard shown else { return .chat }
        return expanded ? .expanded : .inChat
    }
}

/// The chat's Preview per project: the last page and whether it covers the chat (kept between launches); expanded is for this run
/// only.
@MainActor @Observable
final class ChatPreviewState {
    private(set) var urls: [String: URL] = [:]
    private(set) var hidden: Set<String> = []
    /// Bumped on every open, so the panel loads the new page even when it already shows another one.
    private(set) var opened = 0
    private var expandedProjects: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: Self.urlsKey) as? [String: String] { urls = saved.compactMapValues { URL(string: $0) } }
        hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    static let urlsKey = "chatPreviewURLs", hiddenKey = "chatPreviewHidden"

    func url(for project: String) -> URL? { urls[project] }
    func shown(_ project: String) -> Bool { urls[project] != nil && !hidden.contains(project) }
    func expanded(_ project: String) -> Bool { shown(project) && expandedProjects.contains(project) }
    func layout(_ project: String) -> ChatPreviewLayout { .of(shown: shown(project), expanded: expanded(project)) }
    func tab(_ project: String) -> ChatPreviewTab { shown(project) ? .preview : .chat }

    /// A link from the chat: the Preview covers the chat card with the new page.
    func open(_ url: URL, project: String) {
        urls[project] = url; hidden.remove(project); opened += 1; save()
    }

    /// A page the user went to inside the Preview. Only a page the Preview is for (artifact, local, design file) becomes the last page:
    /// never a sign-in page or another host on the way.
    func remember(_ url: URL, project: String, projectRoot: URL? = nil) {
        guard urls[project] != nil, urls[project] != url, PreviewLink.kind(of: url, projectRoot: projectRoot) != .other else { return }
        urls[project] = url; save()
    }

    /// "Show preview" and the Chat button (or tab): the page stays, only what covers the chat card changes. Back to the chat also
    /// leaves the expanded state.
    func select(_ tab: ChatPreviewTab, project: String) {
        guard urls[project] != nil else { return }
        if tab == .preview { hidden.remove(project) } else { hidden.insert(project); expandedProjects.remove(project) }
        save()
    }

    func toggle(_ project: String) { select(shown(project) ? .chat : .preview, project: project) }

    func setExpanded(_ on: Bool, project: String) {
        guard shown(project) else { return }
        if on { expandedProjects.insert(project) } else { expandedProjects.remove(project) }
    }

    /// Esc steps back one level: the Dashboard → the chat card → the chat. False when the chat already shows.
    func escape(_ project: String) -> Bool {
        switch layout(project) {
        case .expanded: expandedProjects.remove(project)
        case .inChat: select(.chat, project: project)
        case .chat: return false
        }
        return true
    }

    private func save() {
        defaults.set(urls.mapValues(\.absoluteString), forKey: Self.urlsKey)
        defaults.set(Array(hidden), forKey: Self.hiddenKey)
    }
}
