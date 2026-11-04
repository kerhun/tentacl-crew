import Foundation

/// A question as the card and the window show it (N279): a plain title, the answers, and everything else as one clean block for "Details".
/// Code, paths and terminal furniture never reach the title.
struct ReadableQuestion: Equatable {
    struct Option: Equatable { let number: Int; let label: String; let detail: String; let recommended: Bool }

    let title: String
    /// A muted line under the title: the other half of the question (context or the ask), or a permission's own description. Empty when none.
    let subtitle: String
    let options: [Option]
    let details: String

    init(_ pending: PendingQuestion) { self.init(pending.question) }

    init(_ q: AgentQuestion) {
        (title, subtitle) = Self.titles(of: q)
        options = q.options.filter { !$0.isSpecial }.map {
            Option(number: $0.number, label: Self.stripRecommended($0.label), detail: $0.detail, recommended: Self.isRecommended($0.label))
        }
        var parts: [String] = []
        // With the title taken from the question's own first sentence, the details hold the whole question; with `user:` they hold what the agent wrote.
        for part in [q.plainText, q.context, q.code ?? ""] where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(Self.cleaned(part)) }
        details = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: recommended option

    static func isRecommended(_ label: String) -> Bool { label.localizedCaseInsensitiveContains("(recommended)") }

    static func stripRecommended(_ label: String) -> String {
        guard let r = label.range(of: #"\s*\(recommended\)"#, options: [.regularExpression, .caseInsensitive]) else { return label }
        return label.replacingCharacters(in: r, with: "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: title

    /// Details start open only for a plan: the user approves what it says.
    static func detailsOpenByDefault(_ kind: AgentQuestion.Kind) -> Bool { kind == .plan }

    private static func titles(of q: AgentQuestion) -> (String, String) {
        if let user = q.userLine { return (single(user, limit: 220), "") }
        if q.isCall { return (q.title, "") }
        if q.kind == .permission, q.command != nil || q.code != nil {
            let title = q.command != nil ? "Wants to run a command" : "Wants to make a change"
            return (title, single(q.context, limit: 200))
        }
        // The prose only: an indented snippet is code and stays out.
        let prose = QuestionSegments.split(q.plainText).filter { !$0.code }.map(\.text).joined(separator: " ")
        let sentences = sentences(prose)
        guard let first = sentences.first else { return (q.title.isEmpty ? "Waiting for your answer" : q.title, "") }
        // The ask is the last real question; a vague one ("Which way do you want it?") only means something next to the sentence before it.
        if let ask = sentences.last(where: { $0.hasSuffix("?") && $0.split(separator: " ").count >= 4 && !vague($0) }) {
            return (single(ask, limit: 200), ask == first ? "" : single(first, limit: 200))
        }
        let ask = sentences.last { $0.hasSuffix("?") }
        return (single(first, limit: 200), ask.map { $0 == first ? "" : single($0, limit: 200) } ?? "")
    }

    private static func vague(_ sentence: String) -> Bool {
        sentence.range(of: #"(?i)^(which|what) (way|option|one)\b|\b(it|this|that|them)\?$|\bproceed\?$"#, options: .regularExpression) != nil
    }

    private static func sentences(_ text: String) -> [String] {
        let flat = single(text, limit: .max)
        var out: [String] = [], rest = Substring(flat)
        while !rest.isEmpty {
            if let r = rest.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression) {
                out.append(String(rest[..<rest.index(after: r.lowerBound)]).trimmingCharacters(in: .whitespaces)); rest = rest[r.upperBound...]
            } else { out.append(rest.trimmingCharacters(in: .whitespaces)); break }
        }
        return out.filter { !$0.isEmpty }
    }

    static func firstSentence(_ text: String, limit: Int = 200) -> String {
        let flat = single(text, limit: .max)
        guard !flat.isEmpty else { return "" }
        var end = flat.endIndex
        if let r = flat.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression) { end = flat.index(after: r.lowerBound) }
        return single(String(flat[..<end]), limit: limit)
    }

    /// One line, no backticks, cut at `limit` characters on a word.
    private static func single(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "`", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    // MARK: details

    private static let frame: Set<Character> = ["│", "┃", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "─", "━", "╌", "┄", "═", "║", "╔", "╗", "╚", "╝", "├", "┤", "┬", "┴", "┼"]
    private static let glyphs = ["⏺", "⎿", "✻", "✽", "❯"]

    /// Terminal furniture off (box lines, rules, the agent's marker glyphs), the lines' own indentation kept, blank runs squeezed, the common margin removed.
    static func cleaned(_ text: String) -> String {
        var out: [String] = []
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            var s = Substring(raw)
            while let c = s.last, c == " " || c == "\t" || frame.contains(c) { s = s.dropLast() }
            var lead = s.prefix { $0 == " " }.count
            var rest = s.dropFirst(lead)
            while let c = rest.first, frame.contains(c) { rest = rest.dropFirst(); lead = 0; rest = rest.drop { $0 == " " } }
            if let g = glyphs.first(where: { rest.hasPrefix($0) }) { rest = rest.dropFirst(g.count).drop { $0 == " " || $0 == "\u{fe0f}" } }
            let line = String(repeating: " ", count: lead) + rest
            if rest.isEmpty { if out.last?.isEmpty == false { out.append("") }; continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }
        let margin = out.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return out.map { String($0.dropFirst(min(margin, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }
}
