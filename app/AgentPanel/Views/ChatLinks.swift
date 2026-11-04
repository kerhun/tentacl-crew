import SwiftUI
import AppKit

/// Links in the chat (N240): bare addresses and `design/x.html` paths become clickable, and a click goes to the Preview beside the chat.
enum ChatLinks {
    private static let designPath = try! NSRegularExpression(pattern: #"(?<![\w/.:-])design/[\w.-]+\.html"#)
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// `text` with a link on every http(s) address and design path that has none yet.
    static func linkified(_ text: AttributedString) -> AttributedString {
        var result = text
        let plain = String(text.characters)
        let whole = NSRange(plain.startIndex..., in: plain)
        func mark(_ range: NSRange, _ url: URL) {
            guard let r = Range(range, in: plain) else { return }
            let from = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let to = result.index(from, offsetByCharacters: plain.distance(from: r.lowerBound, to: r.upperBound))
            guard result[from..<to].link == nil else { return }
            result[from..<to].link = url
        }
        for match in detector.matches(in: plain, range: whole) {
            if let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { mark(match.range, url) }
        }
        for match in designPath.matches(in: plain, range: whole) {
            if let r = Range(match.range, in: plain), let url = URL(string: String(plain[r])) { mark(match.range, url) }
        }
        return result
    }

    static func text(_ s: String) -> Text { Text(linkified(AttributedString(s))) }
}
