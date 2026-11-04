import Foundation

/// All questions of one AskUserQuestion call, read from the agent's session file (Claude Code JSONL). The screen shows only the
/// current tab, so this is where the other questions and their options come from.
struct AskCall: Equatable {
    struct Option: Equatable { let label: String; let description: String }
    struct Item: Equatable {
        let header: String
        let question: String
        let options: [Option]
        let multiSelect: Bool
        /// The menu offers "Type something." (a call read from the session file cannot tell, and Claude Code always adds it).
        var canType = true
    }
    /// What the user picked for one question: the option's number in the menu (1-based), or their own words.
    enum Answer: Equatable { case option(Int), text(String) }

    let items: [Item]

    /// A call built from the screen: the tab bar's names and what each tab showed (`tabs` in order, the first tab first).
    static func read(headers: [String], tabs: [AgentQuestion]) -> AskCall? {
        guard headers.count >= 2, tabs.count == headers.count else { return nil }
        var items: [Item] = []
        for (header, tab) in zip(headers, tabs) {
            let options = tab.options.filter { !$0.isSpecial }
            guard !tab.terminalOnly, options.count >= 2, !tab.text.isEmpty else { return nil }
            items.append(Item(header: header, question: tab.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " "),
                              options: options.map { Option(label: $0.label, description: $0.detail) }, multiSelect: false,
                              canType: tab.options.contains { $0.label.hasPrefix("Type something") && $0.number <= 9 }))
        }
        return AskCall(items: items)
    }

    /// "Colour · Size · Shape" with the count in front, as the call's list item is titled.
    var title: String { "\(items.count) questions · " + items.map(\.header).joined(separator: " · ") }

    /// The answer as a short phrase: the option's label, or the typed words.
    func words(_ answer: Answer, at i: Int) -> String {
        switch answer {
        case .option(let n): items[i].options.indices.contains(n - 1) ? items[i].options[n - 1].label : "?"
        case .text(let t): t
        }
    }

    // MARK: matching the screen

    /// The screen's tab bar names these questions: same headers, and the same options on the current tab.
    private func tabMatches(_ q: AgentQuestion, at i: Int) -> Bool {
        q.tabs == items.map(\.header) && !q.isReview && q.step == i + 1
            && q.options.filter { !$0.isSpecial }.map(\.label) == items[i].options.map(\.label)
    }

    /// The first tab with nothing answered yet.
    func isFresh(_ q: AgentQuestion) -> Bool { tabMatches(q, at: 0) && q.tabAnswered.allSatisfy { !$0 } }
    /// Any tab of this call, with nothing answered yet: the only state a call may be sent from (Send first goes back to the first tab).
    /// Which tab is on screen cannot be told from the tab bar, so the options must be those of one of the questions.
    func isUntouched(_ q: AgentQuestion) -> Bool {
        q.tabs == items.map(\.header) && !q.isReview && q.tabAnswered.allSatisfy { !$0 }
            && items.contains { $0.options.map(\.label) == q.options.filter { !$0.isSpecial }.map(\.label) }
    }
    /// Question `i` (0-based) is on screen with its own options.
    func isStep(_ q: AgentQuestion, _ i: Int) -> Bool { tabMatches(q, at: i) }
    /// The same tab, without comparing the options (after "Type something." was pressed the option holds the typed text).
    func isStepLoosely(_ q: AgentQuestion, _ i: Int) -> Bool { q.tabs == items.map(\.header) && !q.isReview && q.step == i + 1 }
    /// The "Review your answers" step of this call.
    func isReview(_ q: AgentQuestion) -> Bool { q.tabs == items.map(\.header) && q.isReview && q.options.first?.label.hasPrefix("Submit") == true }
}

/// What the user has picked so far in the window; nothing goes to the agent before Send.
struct CallDraft: Equatable {
    private(set) var answers: [AskCall.Answer?]
    /// 0-based question; `answers.count` is the summary.
    private(set) var step = 0

    init(count: Int) { answers = Array(repeating: nil, count: count) }

    var isComplete: Bool { !answers.contains { $0 == nil } }
    var isSummary: Bool { step == answers.count }

    /// Picks the answer of the current question and moves to the next one (after the last: the summary).
    mutating func choose(_ answer: AskCall.Answer) {
        guard step < answers.count else { return }
        answers[step] = answer
        step += 1
    }

    /// ‹ ›: back to an earlier question; forward only to a question that has an answer, or on to the summary once all are answered.
    mutating func move(by delta: Int) {
        let target = step + delta
        if target < 0 { return }
        if delta > 0 {
            guard step < answers.count, answers[step] != nil, target < answers.count || isComplete else { return }
        }
        step = min(target, answers.count)
    }

    /// The answers in order; nil until every question has one.
    var complete: [AskCall.Answer]? { isComplete ? answers.compactMap { $0 } : nil }
}

/// Finds the pending AskUserQuestion call in a session file.
enum AskCallReader {
    /// The last AskUserQuestion of the file that has no tool_result yet; nil when none is pending or the file cannot be read.
    static func pending(at url: URL, tail: Int = 2_000_000) -> AskCall? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), var text = String(data: data, encoding: .utf8) else { return nil }
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return parse(text)
    }

    static func parse(_ text: String) -> AskCall? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let at = lines.lastIndex(where: { $0.contains("\"AskUserQuestion\"") && $0.contains("\"tool_use\"") }),
              let (id, call) = call(in: lines[at]) else { return nil }
        // Once the user answered (or cancelled), a tool_result carries the call's id.
        if lines[(at + 1)...].contains(where: { $0.contains(id) && $0.contains("\"tool_result\"") }) { return nil }
        return call
    }

    private static func call(in line: Substring) -> (String, AskCall)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content where block["name"] as? String == "AskUserQuestion" && block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let input = block["input"] as? [String: Any], let raw = input["questions"] as? [[String: Any]] else { continue }
            let items = raw.compactMap { q -> AskCall.Item? in
                guard let question = q["question"] as? String, let header = q["header"] as? String, let options = q["options"] as? [[String: Any]] else { return nil }
                return AskCall.Item(header: header, question: question,
                                    options: options.compactMap { o in (o["label"] as? String).map { AskCall.Option(label: $0, description: o["description"] as? String ?? "") } },
                                    multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            // A call with an unreadable question is not trusted: the panel then falls back to the screen, one tab at a time.
            guard !items.isEmpty, items.count == raw.count else { return nil }
            return (id, AskCall(items: items))
        }
        return nil
    }
}
