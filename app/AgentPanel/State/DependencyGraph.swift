import Foundation

/// What a card's Dependencies section means for starting it.
enum DependencyState: Equatable {
    /// No dependencies, or the card is finished.
    case clear
    /// Named cards that are not done yet.
    case waiting([String])
    /// Every dependency is done; the user can start the card.
    case ready
    /// A cycle or an unknown card id.
    case problem(String)

    var isProblem: Bool { if case .problem = self { return true } else { return false } }

    /// The short text for a card row and the detail view; nil when there is nothing to say.
    var label: String? {
        switch self {
        case .clear: return nil
        case .waiting(let ids): return "waiting for " + ids.joined(separator: ", ")
        case .ready: return "ready to start"
        case .problem(let text): return text
        }
    }
}

/// The Dependencies sections of all cards as a graph. Pure.
struct DependencyGraph {
    private let states: [String: DependencyState]

    init(cards: [TaskCard]) {
        let known = Set(cards.map(\.id))
        let doneIDs = Set(cards.filter { $0.status == .done }.map(\.id))
        var dependsOn: [String: [String]] = [:]
        for card in cards where dependsOn[card.id] == nil {
            dependsOn[card.id] = Self.mentioned(in: card.sections["Dependencies"] ?? "", known: known, except: card.id)
        }
        var result: [String: DependencyState] = [:]
        for card in cards where result[card.id] == nil {
            let deps = dependsOn[card.id] ?? []
            let unknown = Self.unknownIDs(in: card.sections["Dependencies"] ?? "", known: known)
            if card.status == .done || card.status == .cancelled { result[card.id] = .clear }
            else if !unknown.isEmpty { result[card.id] = .problem("unknown card " + unknown.joined(separator: ", ")) }
            else if Self.reaches(card.id, from: deps, in: dependsOn) { result[card.id] = .problem("dependency cycle through " + card.id) }
            else if deps.isEmpty { result[card.id] = .clear }
            else {
                let open = deps.filter { !doneIDs.contains($0) }
                result[card.id] = open.isEmpty ? .ready : .waiting(open)
            }
        }
        states = result
    }

    func state(of cardID: String) -> DependencyState { states[cardID] ?? .clear }

    /// True when `target` can be reached by following `start` and the dependencies of what it finds.
    private static func reaches(_ target: String, from start: [String], in dependsOn: [String: [String]]) -> Bool {
        var seen = Set<String>()
        var queue = start
        while let id = queue.popLast() {
            if id == target { return true }
            if seen.insert(id).inserted { queue += dependsOn[id] ?? [] }
        }
        return false
    }

    // MARK: reading the section

    /// The ids a Dependencies text lists, known or not. Only `- ID` list items count (text after the id is a note);
    /// a section starting with "None" has none; an old one-line list ("N20 and N22.") still counts.
    private static func listedIDs(_ text: String, known: Set<String>) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, !first.lowercased().hasPrefix("none") else { return [] }
        let items = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        if !items.isEmpty {
            return items.compactMap { line in
                let word = line.dropFirst(2).trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "," }).first
                return word.map(String.init).flatMap { isIDShaped($0) || known.contains($0) ? $0 : nil }
            }
        }
        guard lines.count == 1 else { return [] }
        var line = first
        if line.hasSuffix(".") { line.removeLast() }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let ids = words.filter { $0 != "and" }
        return !ids.isEmpty && ids.allSatisfy { isIDShaped($0) || known.contains($0) } ? ids : []
    }

    /// The card ids named in a Dependencies text, in order.
    static func mentioned(in text: String, known: Set<String>, except own: String) -> [String] {
        var out: [String] = []
        for id in listedIDs(text, known: known) where id != own && known.contains(id) && !out.contains(id) { out.append(id) }
        return out
    }

    /// Listed ids that look like a card id (letters then digits, like `N13`) but name no card.
    static func unknownIDs(in text: String, known: Set<String>) -> [String] {
        var out: [String] = []
        for id in listedIDs(text, known: known) where !known.contains(id) && !out.contains(id) { out.append(id) }
        return out
    }

    private static func isIDShaped(_ token: String) -> Bool {
        let letters = token.prefix(while: { $0.isLetter })
        let digits = token.dropFirst(letters.count)
        return !letters.isEmpty && !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}
