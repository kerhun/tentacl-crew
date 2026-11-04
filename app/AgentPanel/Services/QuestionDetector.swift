import Foundation
import CryptoKit

/// What pressing an option means, for the permission cards ("Yes", "Yes, and don't ask again", "No").
enum OptionRole: Equatable { case plain, allow, allowAlways, deny }

struct QuestionOption: Equatable {
    let number: Int
    let label: String
    let detail: String
    /// An option the panel cannot answer with one key ("Type something.", "Chat about this", a number above 9).
    let isSpecial: Bool
    var role: OptionRole = .plain
    /// A label that ends in "(esc)" is answered with Escape.
    var usesEscape = false
    var keys: [String] { usesEscape ? ["esc"] : [String(number)] }
}

struct AgentQuestion: Equatable {
    /// choice: the AskUserQuestion menu; permission: "Do you want to allow…"; plan: "Would you like to proceed?" after a plan.
    enum Kind { case choice, freeText, permission, plan, signIn }
    let kind: Kind
    /// The menu's heading ("Colour"); empty for a free-text question.
    var title: String
    let text: String
    let options: [QuestionOption]
    /// The lines above the question that explain it (a plan's text); empty for the other kinds.
    var context = ""
    /// The menu's footer offers "Tab to amend": option 3 turns into a text field with Tab.
    var canAmend = false
    /// The panel cannot answer this safely with one key (a multiSelect menu, Codex's several questions): it is answered in the terminal.
    var terminalOnly = false
    /// The agent sits at a login screen or a sign-in error (kind .signIn): whose sign-in it needs.
    var signInTool: AgentTool?
    /// Claude's several questions in one call: the tab names, which tab this is (1-based; nil on the review step), and whether this is the
    /// "Review your answers" step (Submit answers / Cancel). A digit answers one tab and moves to the next; empty for a single question.
    var tabs: [String] = []
    var step: Int?
    var isReview = false
    /// Per tab, whether the tab bar marks it answered (☒); empty without tabs.
    var tabAnswered: [Bool] = []
    /// All questions of the call, read from the session file; the panel asks them in its own window and sends them in one go.
    /// Such a question is one item: its options are the call's, not the screen's.
    var call: AskCall?
    var isCall: Bool { call != nil }
    /// A Bash permission prompt: the command as drawn between the two dashed lines above the menu (all its lines); nil for every other question.
    var command: String?
    /// The code a permission shows between the dashed lines (a Bash command, a file's new content or diff), indentation kept; nil without one.
    var code: String?
    /// The number of "Type something." in Claude's menu, when one key reaches it: the user's own words go in there (N187, N192).
    var typeNumber: Int? { kind == .choice && !terminalOnly ? options.first { $0.label.hasPrefix("Type something") && $0.number <= 9 }?.number : nil }

    /// One item for the whole call (N188): the screen's first tab, standing for all of them.
    static func call(_ call: AskCall, from screen: AgentQuestion) -> AgentQuestion {
        var q = AgentQuestion(kind: .choice, title: call.title, text: call.items.map(\.question).joined(separator: "\n"), options: [])
        q.tabs = screen.tabs
        q.call = call
        return q
    }

    /// How typed feedback reaches the agent, picked from the screen (option text and footer); nil when the menu has no such way.
    enum FeedbackPath: Equatable {
        /// Press `select`, then Tab when `tab`, type the text with send-text, press Enter.
        case inline(select: [String], tab: Bool)
        /// Escape rejects the call; once the agent is idle, the feedback goes in as a prompt.
        case escapeThenPrompt
    }

    var feedbackPath: FeedbackPath? {
        switch kind {
        case .plan:
            guard let o = options.first(where: { $0.label.hasPrefix("Tell Claude what to change") }), o.number <= 9 else { return nil }
            return .inline(select: Array(repeating: "down", count: o.number - 1), tab: false)
        case .permission:
            guard let o = options.last(where: { $0.role == .deny }) else { return nil }
            if canAmend && !o.usesEscape && o.number <= 9 { return .inline(select: Array(repeating: "down", count: o.number - 1), tab: true) }
            return o.usesEscape && !canAmend ? .escapeThenPrompt : nil
        case .choice, .freeText, .signIn: return nil
        }
    }

    /// The `critical: yes|no` and `user: …` lines an agent ends its question with (N279); nil when it wrote none.
    var critical: Bool? { QuestionDetector.marks(in: text).critical }
    var userLine: String? { QuestionDetector.marks(in: text).user }
    /// The question as the agent wrote it, without those two lines.
    var plainText: String { QuestionDetector.marks(in: text).body }

    /// Everything the screen said about the question, for checks that must not miss a word (the autopilot's outward words) and for the PM.
    var fullText: String { [title, context, code ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n") }

    /// Identifies this question, so one that was answered or dismissed is not shown again.
    var signature: String {
        let source = ([title, text, context, code ?? ""] + options.map { "\($0.number).\($0.label)" } + (call?.items.flatMap { $0.options.map(\.label) } ?? [])).joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Finds out from an agent's screen whether it is asking the user something. Pure; written against screens captured from real agents
/// (tests/fixtures/agent-screens). A menu is recognised only while the agent is blocked, a plain question only after it finished its turn.
enum QuestionDetector {
    static func detect(screen: String, state: AgentState) -> AgentQuestion? {
        let lines = screen.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        if state == .blocked || state == .idle || state == .done, let tool = signInTool(in: lines) { return signIn(tool) }
        switch state {
        case .blocked: return choice(in: lines)
        case .idle, .done: return codexPlan(in: lines) ?? freeText(in: lines, done: state == .done)
        default: return nil
        }
    }

    /// Login screens and sign-in errors, as drawn by `claude` 2.1.316 and `codex` 0.164.0 (texts taken from the binaries). A line counts only
    /// when it starts with the text (after a marker like ⎿ or ●) and is among the last lines: code or prose that merely mentions it does not.
    private static let signInTexts: [(AgentTool, String)] = [
        (.claude, "Select login method"), (.claude, "Please run /login"), (.claude, "Invalid API key"), (.claude, "OAuth token has expired"),
        (.claude, "API Error: 401"), (.claude, "Not logged in. Run claude auth login"), (.claude, "Not logged in. This session uses"),
        (.codex, "Your access token could not be refreshed"), (.codex, "Your authentication session could not be refreshed"),
        (.codex, "Not signed in. Please run 'codex login'"), (.codex, "Sign in with ChatGPT"),
    ]

    private static func signInTool(in lines: [String]) -> AgentTool? {
        let tail = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(12)
        for line in tail.reversed() {
            let t = line.drop { " ⎿●⏺■✗>›❯•│┃1234567890.".contains($0) || $0 == "\u{2022}" }
            guard let hit = signInTexts.first(where: { t.hasPrefix($0.1) }) else { continue }
            // "Sign in with ChatGPT" is a menu line: it counts next to the API key choice (Codex's first-run screen).
            if hit.1 == "Sign in with ChatGPT", !tail.contains(where: { $0.contains("Provide your own API key") }) { continue }
            if hit.1 == "Invalid API key", !t.contains("/login") { continue }
            return hit.0
        }
        return nil
    }

    private static func signIn(_ tool: AgentTool) -> AgentQuestion {
        var q = AgentQuestion(kind: .signIn, title: "", text: "Needs sign-in: \(tool == .claude ? "Claude Code" : "Codex")", options: [])
        q.terminalOnly = true
        q.signInTool = tool
        return q
    }

    /// Reads the closing `critical:` and `user:` lines of a question's text. Only the trailing run of such lines counts, in either order;
    /// `user:` may have been wrapped over several lines by the agent (the lines after it, up to the end, belong to it).
    static func marks(in text: String) -> (body: String, critical: Bool?, user: String?) {
        var lines = text.components(separatedBy: "\n")
        var critical: Bool?, user: String?
        while true {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            guard let last = lines.last?.trimmingCharacters(in: .whitespaces).lowercased() else { break }
            if critical == nil, last.range(of: #"^critical:\s*(yes|no)\.?$"#, options: .regularExpression) != nil {
                critical = last.contains("yes"); lines.removeLast(); continue
            }
            // A wrapped `user:` line: walk up to the line that starts it, if only plain text lies between.
            if user == nil, let at = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("user:") }),
               lines[(at + 1)...].allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.lowercased().contains("critical:") }), lines.count - at <= 4 {
                let joined = lines[at...].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                user = String(joined.dropFirst("user:".count)).trimmingCharacters(in: .whitespaces)
                lines.removeSubrange(at...); continue
            }
            break
        }
        if user?.isEmpty == true { user = nil }
        return (lines.joined(separator: "\n"), critical, user)
    }

    // MARK: menus

    private static func isRule(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).filter { $0 == "─" }.count >= 8 }
    private static func isFooter(_ line: String) -> Bool {
        line.contains("Enter to select") || line.contains("Esc to cancel")
            // Codex: "Press enter to confirm or esc to cancel", "enter select · esc back", "tab to add notes | enter to submit answer | …", "enter confirm · esc skip"
            || line.contains("enter to confirm") || line.contains("Press enter to continue") || line.contains("enter select · esc back")
            || line.contains("enter to submit answer") || line.contains("enter confirm · esc skip")
    }

    /// The cursor of Claude's menus is ❯, Codex's is ›.
    private static func hasCursor(_ line: String) -> Bool { let t = line.trimmingCharacters(in: .whitespaces); return t.hasPrefix("❯") || t.hasPrefix("›") }

    private static let borderSides: Set<Character> = ["│", "┃"]
    private static let borderAll: Set<Character> = ["│", "┃", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "─", "━"]

    /// A line without the menu's box border at its start and end; a border character inside the text stays.
    private static func unboxed(_ line: String, _ border: Set<Character>) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        while let c = s.first, border.contains(c) { s = s.dropFirst().drop { $0 == " " } }
        while let c = s.last, border.contains(c) { s = s.dropLast(); while s.last == " " { s = s.dropLast() } }
        return String(s)
    }


    /// A line without the menu's box border at its ends, its own indentation kept.
    private static func unboxedKeepingIndent(_ line: String, _ border: Set<Character>) -> String {
        var s = Substring(line)
        while s.last == " " || s.last == "\t" { s = s.dropLast() }
        while let c = s.last, border.contains(c) { s = s.dropLast(); while s.last == " " { s = s.dropLast() } }
        let rest = s.drop { $0 == " " }
        if let c = rest.first, border.contains(c) { s = rest.dropFirst(); if s.first == " " { s = s.dropFirst() } }
        return String(s)
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// The text lines of `lines[range]` as the agent drew them: box borders, rules and dashed lines gone, indentation kept, one blank line
    /// at most between paragraphs, none at the ends, and the common left margin taken off.
    private static func block(_ lines: [String], _ range: Range<Int>) -> [String] {
        var out: [String] = []
        for i in range where lines.indices.contains(i) {
            let raw = lines[i]
            if isRule(raw) || isDashes(raw) { continue }
            let t = unboxedKeepingIndent(raw, borderAll)
            if t.trimmingCharacters(in: .whitespaces).isEmpty { if out.last?.isEmpty == false { out.append("") }; continue }
            out.append(t)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return dedented(out)
    }

    /// The lines without their common left margin and without blank lines at the ends.
    private static func dedented(_ lines: [String]) -> [String] {
        var out = lines
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        let margin = out.filter { !$0.isEmpty }.map(indent).min() ?? 0
        return out.map { String($0.dropFirst(min(margin, indent($0)))) }
    }

    /// The width the agent wrapped its text at: the longest rule on the screen, else the longest line.
    private static func screenWidth(_ lines: [String]) -> Int {
        let rules = lines.filter { isRule($0) || isDashes($0) }.map { $0.trimmingCharacters(in: .whitespaces).count }
        return rules.max() ?? lines.map { $0.trimmingCharacters(in: .whitespaces).count }.max() ?? 0
    }

    private static func listMarkerWidth(_ line: String) -> Int? {
        let t = line.drop { $0 == " " }
        if let m = t.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) { return t.distance(from: t.startIndex, to: m.upperBound) }
        return nil
    }

    /// The agent wraps its own text at the screen width, so a paragraph arrives as several lines. A line that is followed by one whose first
    /// word would not have fitted on it, and that continues at the same indentation (after a list marker, at the text), is one with it.
    /// Code (more indented than the text above) and list items stay as they are.
    static func unwrapped(_ lines: [String], width: Int) -> [String] {
        guard width > 0 else { return lines }
        var out: [String] = [], physical = 0
        for line in lines {
            if let last = out.last, !last.isEmpty, !line.isEmpty, listMarkerWidth(line) == nil {
                let first = last.drop { $0 == " " }
                let textIndent = indent(last) + (listMarkerWidth(last) ?? 0)
                let word = line.drop { $0 == " " }.prefix { $0 != " " }
                if indent(line) == textIndent || (indent(line) == indent(last) && listMarkerWidth(last) == nil), !first.isEmpty,
                   physical + 1 + word.count > width - 3 {
                    out[out.count - 1] = last + " " + line.drop { $0 == " " }
                    physical = line.count
                    continue
                }
            }
            out.append(line); physical = line.count
        }
        return out
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("❯") || s.hasPrefix("›") { s = s.dropFirst().drop { $0 == " " || $0 == "\u{a0}" } }
        var digits = ""
        var rest = s
        while let c = rest.first, c.isNumber, c.isASCII { digits.append(c); rest = rest.dropFirst() }
        guard !digits.isEmpty, let n = Int(digits), let sep = rest.first, sep == "." || sep == ")" else { return nil }
        let label = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (n, label)
    }

    private static func isDashes(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "╌" } && line.contains("╌") }

    /// With option previews the menu is two columns: the options on the left, a box with the preview of the focused option on the right.
    /// The right column is cut off from the first option line down, so labels and details stay clean.
    private static func withoutPreview(_ lines: [String]) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"^\s*(❯\s*)?\d+[.)]\s+\S.*?\s{2,}(┌)"#)
        guard let at = lines.lastIndex(where: { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }),
              let corner = lines[at].firstIndex(of: "┌") else { return lines }
        let column = lines[at].distance(from: lines[at].startIndex, to: corner)
        // The box may start on an earlier option line: cut every line from the first numbered one.
        let first = lines[..<at].lastIndex(where: { numbered($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "❯", with: "").trimmingCharacters(in: .whitespaces))?.0 == 1 }) ?? at
        return lines.enumerated().map { i, line in i >= first && line.count > column ? String(line.prefix(column)) : line }
    }

    /// Only a real menu counts: it starts at the last option 1, has the cursor (❯) on one of its options, and its numbers run 1, 2, 3…
    /// A numbered list in the agent's own text has no cursor, so it is not a menu.
    private static func choice(in rawLines: [String]) -> AgentQuestion? {
        let boxed = withoutPreview(rawLines)
        let lines = boxed.map { unboxed($0, borderSides) }
        guard let first = lines.lastIndex(where: { numbered($0)?.0 == 1 }) else { return nil }
        let end = lines[first...].firstIndex(where: isFooter) ?? lines.count
        guard lines[first..<end].contains(where: { hasCursor($0) && numbered($0) != nil }) else { return nil }
        // Codex menus: cursor ›, a hotkey in brackets after the label, the detail on the label's line, no rule or heading above.
        let codex = !lines[first..<end].contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }
        var options: [QuestionOption] = []
        var i = first
        while i < end {
            let line = lines[i]
            if case (let n, var label)? = numbered(line) {
                var detail = ""
                if codex, let gap = label.range(of: #"\s{2,}"#, options: .regularExpression) {
                    detail = String(label[gap.upperBound...])
                    label = String(label[..<gap.lowerBound])
                }
                if codex, let hotkey = label.range(of: #" \([a-z]\)$"#, options: .regularExpression) { label = String(label[..<hotkey.lowerBound]) }
                var j = i + 1
                while detail.isEmpty, j < end, numbered(lines[j]) == nil, !isRule(lines[j]) {
                    let d = lines[j].trimmingCharacters(in: .whitespaces)
                    if !d.isEmpty { detail = d; break }
                    j += 1
                }
                let usesEscape = label.hasSuffix("(esc)")
                let lower = label.lowercased()
                let role: OptionRole = lower.contains("don't ask again") ? .allowAlways : label.hasPrefix("Yes") ? .allow : label.hasPrefix("No") ? .deny : .plain
                let special = n > 9 || label.hasPrefix("Type something") || label == "Chat about this" || label.hasPrefix("Tell Claude")
                options.append(QuestionOption(number: n, label: label, detail: detail, isSpecial: special, role: role, usesEscape: usesEscape))
            }
            i += 1
        }
        guard options.map(\.number) == Array(1...max(options.count, 1)) else { return nil }

        // The heading ("☐ Colour") and the question are the lines above the first option.
        var title = "", above: [String] = [], tabs = false
        var tabNames: [String] = [], tabMarks: [Character] = []
        var k = first - 1
        var ruleAt: Int?
        var dashed: [Int] = []
        var blanks = 0
        while k >= 0 {
            let t = unboxed(lines[k], borderAll)
            if isRule(lines[k]) { ruleAt = k; break }
            // Codex draws the menu at the bottom of the screen: a run of empty lines separates it from the conversation.
            blanks = t.isEmpty ? blanks + 1 : 0
            if codex, blanks >= 3 { break }
            if t.hasPrefix("←"), t.contains("☐") || t.contains("☒") || t.contains("✔") {
                // Several questions in one call: the tab bar names them ("← ☐ Colour ☐ Size ✔ Submit →").
                let marks: Set<Character> = ["☐", "☒", "✔"]
                var entries: [(mark: Character, name: String)] = []
                for ch in t.dropFirst() {
                    if marks.contains(ch) { entries.append((ch, "")) } else if !entries.isEmpty { entries[entries.count - 1].name.append(ch) }
                }
                // The last entry is "✔ Submit →"; the names are what the agent called the questions (they may hold spaces).
                let questions = entries.dropLast().map { (mark: $0.mark, name: $0.name.trimmingCharacters(in: .whitespaces)) }
                tabNames = questions.map(\.name); tabMarks = questions.map(\.mark)
                title = tabNames.joined(separator: " · "); tabs = true
                break
            }
            if t.hasPrefix("☐") || t.hasPrefix("☒") { title = String(t.dropFirst()).trimmingCharacters(in: .whitespaces); break }
            if isDashes(lines[k]) { dashed.append(k) }
            if !t.isEmpty, !isDashes(lines[k]) { above.insert(t, at: 0) }
            k -= 1
        }
        var codexAsk = false
        if codex, let head = above.first, let m = head.range(of: #"^Question (\d+)/(\d+)"#, options: .regularExpression) {
            // "Question 1/2 (1 unanswered)": a digit submits only when it is the one question.
            let parts = head[m].dropFirst("Question ".count).split(separator: "/")
            tabs = parts.last.flatMap { Int($0) }.map { $0 > 1 } ?? true
            codexAsk = true
            above.removeFirst()
        }
        // The review step's heading is part of the title ("Review your answers · Colour · Size"), not repeated in the text.
        let review = !tabNames.isEmpty && above.first == "Review your answers"
        if review { above.removeFirst() }
        let width = screenWidth(lines)
        var prose = above
        if !codex {
            // Claude's text keeps its indentation and paragraphs; the lines the agent wrapped itself are joined again.
            prose = block(boxed, (k + 1)..<first)
            if review, let head = prose.firstIndex(where: { !$0.isEmpty }) { prose.remove(at: head) }
            prose = unwrapped(prose, width: width)
        }
        let text = prose.joined(separator: "\n")
        guard !text.isEmpty else { return nil }

        let isPlan = text.contains("ready to execute") || text.contains("Implement this plan?") || (above.first?.hasPrefix("Bash command") != true && options.contains { $0.label.contains("auto mode") || $0.label.contains("manually approve") })
        let isAsk = !title.isEmpty || codexAsk || options.contains { $0.label.hasPrefix("Type something") || $0.label == "Chat about this" }
        let kind: AgentQuestion.Kind = isPlan ? .plan : isAsk ? .choice : (options.first?.label.hasPrefix("Yes") == true ? .permission : .choice)
        guard options.filter({ !$0.isSpecial }).count >= 2 || kind != .choice else { return nil }
        var context = ""
        if kind == .plan, let r = ruleAt {
            // The plan is what follows the agent's last marker line ("⎿ Plan saved to…").
            let from = lines[..<r].lastIndex { let t = $0.trimmingCharacters(in: .whitespaces); return stops.contains { g in starts(t, with: g) } }.map { $0 + 1 } ?? 0
            context = unwrapped(Array(block(boxed, from..<r).suffix(80)), width: width).joined(separator: "\n")
        }
        if kind == .plan, codex, let p = lines.lastIndex(where: { $0.contains("Proposed Plan") }), p < first {
            context = lines[(p + 1)..<first].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("Worked for") && $0 != text }.joined(separator: "\n")
        }
        var question = AgentQuestion(kind: kind, title: title, text: text, options: options, context: context)
        if kind == .permission, dashed.count >= 2, !codex {
            // "Bash command", the why, a dashed line, the code, a dashed line, the question: each goes where it belongs.
            let isBash = above.first?.hasPrefix("Bash command") == true
            let code = block(boxed, (dashed[1] + 1)..<dashed[0])
            var head = block(boxed, (k + 1)..<dashed[1])
            if let first = head.firstIndex(where: { !$0.isEmpty }), isBash { head.remove(at: first) }
            head.removeAll { $0.hasPrefix("Tip:") }
            head = dedented(head)
            let ask = unwrapped(block(boxed, (dashed[0] + 1)..<first), width: width)
            if !ask.isEmpty { question = AgentQuestion(kind: kind, title: title, text: ask.joined(separator: "\n"), options: options, context: unwrapped(head, width: width).joined(separator: "\n")) }
            if !code.isEmpty { question.code = code.joined(separator: "\n"); if isBash { question.command = question.code } }
        }
        if tabs, !tabNames.isEmpty {
            // Claude's tab bar does not mark the current tab: it is the one whose name the question carries, else the first unanswered.
            question.tabs = tabNames
            question.tabAnswered = tabMarks.map { $0 != "☐" }
            question.isReview = review
            if !question.isReview {
                let lower = text.lowercased()
                let named = tabNames.indices.filter { !tabNames[$0].isEmpty && lower.contains(tabNames[$0].lowercased()) }
                question.step = named.count == 1 ? named[0] + 1 : tabMarks.firstIndex(of: "☐").map { $0 + 1 }
            }
            let progress = question.isReview ? "Review your answers" : question.step.map { "Question \($0) of \(tabNames.count)" } ?? "Questions"
            question.title = ([progress] + tabNames).joined(separator: " · ")
        }
        // Codex's several questions: a digit submits only when it is the one question. Claude's tabs are answered by digit, one tab each.
        question.terminalOnly = (tabs && codexAsk) || options.contains { $0.label.hasPrefix("[ ]") || $0.label.hasPrefix("[x]") || $0.label.hasPrefix("[✔]") }
        question.canAmend = lines[first..<min(lines.count, end + 1)].contains { $0.contains("Tab to amend") }
        return question
    }

    /// Codex's "Implement this plan?" menu appears while the agent counts as done, not blocked.
    private static func codexPlan(in lines: [String]) -> AgentQuestion? {
        guard lines.contains(where: { $0.contains("Implement this plan?") }), let q = choice(in: lines), q.kind == .plan else { return nil }
        return q
    }

    // MARK: plain questions

    private static let stops = ["✻", "⎿", "⏺", "❯"]
    /// A finished turn with a longer message than this is a report whose last sentence only happens to end in "?".
    private static let longReport = 400

    /// True when the line starts with the glyph, also when a variation selector follows it ("⏺" + U+FE0F is one character in Swift).
    private static func starts(_ line: String, with glyph: String) -> Bool { line.unicodeScalars.first == glyph.unicodeScalars.first }

    private static func freeText(in lines: [String], done: Bool) -> AgentQuestion? {
        guard let start = lines.lastIndex(where: { starts($0, with: "⏺") }) else { return codexFreeText(in: lines, done: done) }
        // The marker is as wide as the indentation of the lines below it, so the agent's own line wrapping can be undone.
        var block = ["  " + String(String.UnicodeScalarView(lines[start].unicodeScalars.dropFirst())).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{fe0f}")))]
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            if isRule(line) || stops.contains(where: { starts(line.trimmingCharacters(in: .whitespaces), with: $0) }) { break }
            block.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : line)
            i += 1
        }
        while block.last?.isEmpty == true { block.removeLast() }
        block = unwrapped(block, width: screenWidth(lines)).map { $0.trimmingCharacters(in: .whitespaces) }
        let text = block.joined(separator: "\n")
        guard text.hasSuffix("?") else { return nil }
        if done, text.count > longReport { return nil }
        return AgentQuestion(kind: .freeText, title: "", text: text, options: [])
    }

    /// Codex: the last "• " block of a finished turn; it ends at the footnote (└ Tip), the next marker or the prompt box (›).
    private static func codexFreeText(in lines: [String], done: Bool) -> AgentQuestion? {
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("›") }),
              let start = lines.lastIndex(where: { $0.hasPrefix("• ") }) else { return nil }
        var block = [String(lines[start].dropFirst(2)).trimmingCharacters(in: .whitespaces)]
        for line in lines[(start + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if ["›", "└", "•", "■", "✔", "Worked for"].contains(where: { t.hasPrefix($0) }) { break }
            block.append(t)
        }
        while block.last?.isEmpty == true { block.removeLast() }
        let text = block.joined(separator: "\n")
        guard text.hasSuffix("?"), !(done && text.count > longReport) else { return nil }
        return AgentQuestion(kind: .freeText, title: "", text: text, options: [])
    }
}
