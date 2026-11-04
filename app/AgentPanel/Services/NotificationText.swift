import Foundation

/// Markdown → readable plain text for notification titles and bodies (the chat itself keeps its Markdown).
enum NotificationText {
    static func plain(_ text: String) -> String {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { continue }   // fence lines; the code inside stays (its marks too: shortcut, fine for a banner)
            if t.hasPrefix("|") || t.hasSuffix("|") {
                if t.range(of: #"^\|?[\s:|-]*-[\s:|-]*\|?$"#, options: .regularExpression) != nil { continue }
                line = t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s{0,3}>\s?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
            out.append(inline(line))
        }
        return out.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A PM acknowledgement that is just a check mark (✓ ✔ ✅, maybe with a period) is not worth a banner.
    static func isOnlyCheckMark(_ text: String) -> Bool {
        plain(text).range(of: #"^[\s.]*[✓✔✅]\uFE0F?[\s.]*$"#, options: .regularExpression) != nil
    }

    private static let rules: [(String, String)] = [
        (#"!?\[([^\]]+)\]\([^)]*\)"#, "$1"),
        (#"`([^`]+)`"#, "$1"),
        (#"\*\*(\S(?:.*?\S)?)\*\*"#, "$1"),
        (#"(?<!\w)__(\S(?:.*?\S)?)__(?!\w)"#, "$1"),
        (#"(?<![\w*])\*([^*\s](?:[^*]*?[^*\s])?)\*(?![\w*])"#, "$1"),
        (#"(?<![\w_])_([^_\s](?:[^_]*?[^_\s])?)_(?![\w_])"#, "$1"),
    ]

    private static func inline(_ line: String) -> String {
        rules.reduce(line) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }
}
