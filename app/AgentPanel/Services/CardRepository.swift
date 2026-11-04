import Foundation

enum CardLoadResult: Equatable {
    case card(TaskCard)
    /// A file in `tasks/` that could not be parsed. Shown to the user instead of being skipped silently.
    case unreadable(url: URL, reason: String)
}

/// Reads task cards from `<dataDir>/tasks/*.md`. Read-only: nothing in this type writes to disk.
struct CardRepository {
    let dataDir: URL

    init(dataDir: URL) { self.dataDir = dataDir }

    private var tasksDir: URL { dataDir.appendingPathComponent("tasks") }

    /// Cards sorted by id in natural order (A2 before A10); unreadable files are returned too.
    func loadAll() -> [CardLoadResult] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)) ?? []
        let results: [CardLoadResult] = urls
            .filter { $0.pathExtension == "md" }
            .map { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return .unreadable(url: url, reason: "file is not readable as UTF-8 text")
                }
                do {
                    var card = try CardParser.parse(text, url: url)
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                    card.modified = values?.contentModificationDate
                    card.created = values?.creationDate
                    return .card(card)
                }
                catch CardParseError.noFrontMatter { return .unreadable(url: url, reason: "no complete front matter (\"---\" block)") }
                catch CardParseError.missingID { return .unreadable(url: url, reason: "front matter has no id") }
                catch { return .unreadable(url: url, reason: "\(error)") }
            }
        return results.sorted { sortKey($0).localizedStandardCompare(sortKey($1)) == .orderedAscending }
    }

    /// Screenshots for a card: `<dataDir>/tasks/<id>/shots/*.png|jpg`, sorted by file name.
    func screenshots(for card: TaskCard) -> [URL] {
        let shots = tasksDir.appendingPathComponent(card.id).appendingPathComponent("shots")
        let urls = (try? FileManager.default.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func sortKey(_ result: CardLoadResult) -> String {
        switch result {
        case .card(let c): return c.id
        case .unreadable(let url, _): return "~" + url.lastPathComponent   // unreadable files after real cards
        }
    }
}
