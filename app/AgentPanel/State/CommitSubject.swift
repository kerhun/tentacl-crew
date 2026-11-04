import Foundation

/// A commit subject split for a readable row (N269): "fix(terminals): the filter field asks for focus (N266)" → type `fix`, scope
/// `terminals`, card `N266`, text "the filter field asks for focus". A subject without a known prefix or card suffix keeps its whole text.
struct CommitSubject: Equatable {
    var type: String?
    var scope: String?
    var card: String?
    var text: String

    /// The conventional prefixes shown as a chip; any other word before a colon stays in the text.
    static let types: Set<String> = ["feat", "fix", "test", "tests", "docs", "refactor", "chore", "perf", "style", "build", "ci", "revert", "wip"]

    init(type: String?, scope: String?, card: String?, text: String) {
        self.type = type; self.scope = scope; self.card = card; self.text = text
    }

    init(_ subject: String) {
        var rest = subject.trimmingCharacters(in: .whitespaces)
        if let colon = rest.firstIndex(of: ":"), rest[rest.index(after: colon)...].first == " " {
            var head = String(rest[..<colon])
            if head.hasSuffix("!") { head.removeLast() }
            var scope: String?
            if head.hasSuffix(")"), let open = head.firstIndex(of: "(") {
                scope = String(head[head.index(after: open)..<head.index(before: head.endIndex)])
                head = String(head[..<open])
            }
            if Self.types.contains(head) {
                type = head
                self.scope = scope.flatMap { $0.isEmpty ? nil : $0 }
                rest = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let m = rest.range(of: #"\s*\(([A-Z]{1,2}[0-9]{1,4})\)$"#, options: .regularExpression) {
            card = rest[m].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            rest = String(rest[..<m.lowerBound])
        } else {
            card = GitDetails.cardID(in: rest)
        }
        text = rest.isEmpty ? subject : rest
    }
}
