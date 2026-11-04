import Foundation

/// Search, collapsed sections and arrow-key movement for the task list. Pure and testable.
enum TaskListFilter {
    static let collapsedByDefault: Set<String> = ["Done", "Cancelled"]

    /// A card matches when every word of the query is found in its id, title, roles or status. Unreadable files match by file name.
    static func filter(_ results: [CardLoadResult], query: String) -> [CardLoadResult] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { return results }
        return results.filter { result in
            let haystack: String
            switch result {
            case .card(let c): haystack = ([c.id, c.title, c.status.label] + (c.roles.isEmpty ? ["dev"] : c.roles)).joined(separator: " ").lowercased()
            case .unreadable(let url, _): haystack = url.lastPathComponent.lowercased()
            }
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Done and Cancelled start closed; a search opens them so a match is never hidden.
    static func isCollapsed(_ title: String, expanded: Set<String>, query: String) -> Bool {
        collapsedByDefault.contains(title) && !expanded.contains(title) && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Card ids in the order the list shows them, without the rows of collapsed sections.
    static func visibleCardIDs(_ sections: [TaskSection], expanded: Set<String>, query: String) -> [String] {
        sections.filter { !isCollapsed($0.title, expanded: expanded, query: query) }.flatMap(\.rows).compactMap {
            if case .card(let c) = $0 { return c.id } else { return nil }
        }
    }

    /// The id after moving `delta` rows from `current`, stopping at the ends. Nothing selected: down picks the first, up the last.
    static func move(from current: String?, in ids: [String], by delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return delta >= 0 ? ids.first : ids.last }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}
