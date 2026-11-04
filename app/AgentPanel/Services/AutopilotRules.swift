import Foundation

/// What the PM returned for one question (the JSON its decision call must produce).
struct PMDecision: Codable, Equatable {
    enum Verdict: String, Codable { case answer, escalate }
    enum Confidence: String, Codable { case high, low }
    let verdict: Verdict
    var option: Int? = nil
    /// A call of several questions: one option number per question, in order.
    var options: [Int]? = nil
    var text: String? = nil
    let why: String
    let confidence: Confidence
}

/// An answer the PM proposes, as the user sees it on a card.
struct PMSuggestion: Equatable {
    /// The menu option the PM picked, or nil for a typed answer.
    let option: Int?
    let text: String?
    let why: String
    var optionLabel: String? = nil

    /// What the card shows: the option's label, or the typed text.
    var summary: String { optionLabel ?? text ?? "" }
}

/// What the panel does with a PM decision after checking it.
enum DecisionOutcome: Equatable {
    case sendOption(QuestionOption, PMSuggestion)
    case sendText(String, PMSuggestion)
    /// All questions of one call, one option number each; all or none.
    case sendCall([Int], PMSuggestion)
    case escalate(reason: String, suggestion: PMSuggestion?)
}

/// The rules the panel enforces around the PM, whatever the PM says. Pure.
enum AutopilotRules {
    static let maxTextLength = 600

    /// Words in a permission prompt that mean the agent wants to reach outside the task: these always go to the user.
    private static let outward = ["git push", "git remote", "curl ", "wget ", "ssh ", "scp ", "npm install", "npm i ", "pnpm add", "yarn add", "pip install",
                                  "brew ", "gem install", "cargo install", "sudo ", "rm -rf", "rm -fr", "--force", "git reset --hard", "git clean", "git checkout --", "git push -f", "launchctl", "defaults write", "security ",
                                  "fetch content", "Fetch", "WebFetch", "WebSearch", "Web Search", "~/.ssh", ".env"]

    /// Commands matched only where a command starts (line start, or after `;`, `&&`, `||`, `|`), so "through" or "high" never match.
    private static let commandPatterns: [(name: String, regex: NSRegularExpression)] = [
        ("gh", #"(?:^|;|&&|\|)[ \t]*gh[ \t]"#),
        ("rm outside the worktree", #"(?:^|;|&&|\|)[ \t]*rm(?=[ \t])[^\n;&|]*(?:[ \t](?:/|~)|\.\.)"#),
    ].compactMap { name, pattern in (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])).map { (name, $0) } }

    /// The reason a question must go to the user before the PM is even asked; nil when the PM may look at it.
    static func mustEscalate(_ q: AgentQuestion) -> String? {
        if q.kind == .signIn { return "Needs a sign-in: only you can do it." }
        if q.terminalOnly { return "Has to be answered in the agent's terminal." }
        guard q.kind == .permission else { return nil }
        let text = q.fullText
        if let hit = outward.first(where: { text.localizedCaseInsensitiveContains($0) }) {
            return "Reaches outside the task (\(hit.trimmingCharacters(in: .whitespaces))): always yours."
        }
        let whole = NSRange(text.startIndex..., in: text)
        if let hit = commandPatterns.first(where: { $0.regex.firstMatch(in: text, range: whole) != nil }) {
            return "Reaches outside the task (\(hit.name)): always yours."
        }
        return nil
    }

    /// Words that mean something is lost for good; with `outward`, a question that holds one is critical (N279).
    private static let destructive = ["delete", "overwrite", "wipe", "destroy", "irreversible", "cannot be undone", "can't be undone", "drop table", "truncate", "force-push", "force push"]

    /// Why a question is critical, or nil. Critical questions always go to the user; neither the PM nor the agent's `critical: no` lowers it.
    /// `cardFiles` are the card's `files:`; a path in the question outside them is a scope hint (judged only when the card names files).
    /// `hardOnly`: only the rules about the words themselves (outward, destructive); the agent's mark and the scope hint are left out.
    static func criticalReason(_ q: AgentQuestion, cardFiles: [String] = [], hardOnly: Bool = false) -> String? {
        if q.critical == true, !hardOnly { return "The agent marked it critical." }
        let text = q.fullText + "\n" + q.options.map(\.label).joined(separator: "\n")
        if let hit = outward.first(where: { text.localizedCaseInsensitiveContains($0) }) { return "Reaches outside the task (\(hit.trimmingCharacters(in: .whitespaces)))." }
        let whole = NSRange(text.startIndex..., in: text)
        if let hit = commandPatterns.first(where: { $0.regex.firstMatch(in: text, range: whole) != nil }) { return "Reaches outside the task (\(hit.name))." }
        if let hit = destructive.first(where: { text.localizedCaseInsensitiveContains($0) }) { return "Can destroy something (\(hit))." }
        if !hardOnly, let path = pathsOutside(cardFiles, in: text).first { return "Touches \(path), outside the card's files." }
        return nil
    }

    /// Paths written in the text (a slash and a file extension, or an absolute/home path) that no entry of `files` covers.
    static func pathsOutside(_ files: [String], in text: String) -> [String] {
        guard !files.isEmpty, let regex = try? NSRegularExpression(pattern: #"(?<![\w:/.~-])(?:(?:~|\.{1,2})?/[\w.-]+(?:/[\w.-]+)*/?|[\w.-]+(?:/[\w.-]+)+/?)"#) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            var path = String(text[r])
            let rooted = path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("..")
            guard rooted || path.range(of: #"\.\w{1,6}$"#, options: .regularExpression) != nil || path.hasSuffix("/") else { return nil }
            // Inside the task's own worktree an absolute path is a relative one.
            if let w = path.range(of: ".agent-worktrees/") { path = String(path[w.upperBound...].drop { $0 != "/" }.dropFirst()) }
            else if rooted { return path }
            let p = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            let covered = files.contains { f in let f = f.hasPrefix("./") ? String(f.dropFirst(2)) : f; return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/") || p.hasPrefix(f) }
            return covered ? nil : path
        }
    }

    /// Options the PM may never choose: a permission beyond this one time, auto mode, anything that bypasses later prompts.
    static func forbidden(_ option: QuestionOption, in kind: AgentQuestion.Kind) -> Bool {
        if option.isSpecial || option.usesEscape { return true }
        let label = option.label.lowercased()
        if label.contains("don't ask again") || label.contains("auto mode") || label.contains("bypass") || label.contains("auto-accept") { return true }
        switch kind {
        case .permission: return option.role != .allow || label != "yes"
        case .plan: return !label.hasPrefix("yes")
        case .choice, .freeText, .signIn: return false
        }
    }

    /// Checks a decision against the question it answers. Anything doubtful becomes an escalation that still carries the PM's
    /// suggestion when the suggestion itself is usable.
    static func outcome(of d: PMDecision, for q: AgentQuestion) -> DecisionOutcome {
        let why = d.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No reason given." : String(d.why.prefix(400))
        if let reason = mustEscalate(q) {
            return .escalate(reason: reason, suggestion: suggestion(d, q, why))
        }
        guard let s = suggestion(d, q, why) else {
            return .escalate(reason: d.verdict == .escalate ? "PM: \(why)" : "PM gave an answer it may not give.", suggestion: nil)
        }
        if d.verdict == .escalate { return .escalate(reason: "PM: \(why)", suggestion: s) }
        if d.confidence == .low { return .escalate(reason: "PM is not sure.", suggestion: s) }
        if q.isCall, let picks = d.options { return .sendCall(picks, s) }
        if let n = s.option, let option = q.options.first(where: { $0.number == n }) { return .sendOption(option, s) }
        if let text = s.text { return .sendText(text, s) }
        return .escalate(reason: "PM gave no answer.", suggestion: nil)
    }

    /// The usable part of a decision: an allowed option for a menu, a short text for a plain question.
    private static func suggestion(_ d: PMDecision, _ q: AgentQuestion, _ why: String) -> PMSuggestion? {
        if let call = q.call {
            // All or none: one allowed option for every question.
            guard let picks = d.options, picks.count == call.items.count,
                  picks.indices.allSatisfy({ call.items[$0].options.indices.contains(picks[$0] - 1) }) else { return nil }
            return PMSuggestion(option: nil, text: nil, why: why, optionLabel: picks.indices.map { call.items[$0].options[picks[$0] - 1].label }.joined(separator: " · "))
        }
        switch q.kind {
        case .freeText:
            guard let text = d.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= maxTextLength else { return nil }
            return PMSuggestion(option: nil, text: text, why: why)
        case .choice, .permission, .plan, .signIn:
            guard let n = d.option, let option = q.options.first(where: { $0.number == n }), !forbidden(option, in: q.kind) else { return nil }
            return PMSuggestion(option: n, text: nil, why: why, optionLabel: option.label)
        }
    }
}

/// What the panel does with a PM decision about a reviewer's Fix notes.
enum FixOutcome: Equatable {
    case passOn(why: String)
    case escalate(reason: String)
}

extension AutopilotRules {
    /// A PM "answer" means pass the notes on; anything else, or doubt, goes to the user.
    static func fixOutcome(of d: PMDecision) -> FixOutcome {
        let why = d.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No reason given." : String(d.why.prefix(400))
        if d.verdict == .escalate { return .escalate(reason: "PM: \(why)") }
        if d.confidence == .low { return .escalate(reason: "PM is not sure.") }
        return .passOn(why: why)
    }

    /// The entry added to a card's Fix notes between two reads; nil when the section did not grow.
    static func newFixEntry(old: String, new: String) -> String? {
        let old = old.trimmingCharacters(in: .whitespacesAndNewlines), new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new.count > old.count else { return nil }
        if new.hasPrefix(old) {
            let added = String(new.dropFirst(old.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return added.isEmpty ? nil : added
        }
        // The section was edited as well: the newest entry is the best guess.
        let parts = ("\n" + new).components(separatedBy: "\n### ")
        guard parts.count > 1, let last = parts.last else { return new }
        return "### " + last.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
