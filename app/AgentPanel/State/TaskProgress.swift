import Foundation

/// One step of a task's progress row in the detail (N135): Card → Started → Work → Packet → Your review → Merged.
struct ProgressStep: Equatable, Identifiable {
    enum Kind: CaseIterable, Equatable {
        case card, started, work, packet, review, merged
        var title: String {
            switch self {
            case .card: return "Card"
            case .started: return "Started"
            case .work: return "Work"
            case .packet: return "Packet"
            case .review: return "Your review"
            case .merged: return "Merged"
            }
        }
    }
    /// Green when done, orange when it waits for the user, blue while an agent works, grey otherwise.
    enum Tone: Equatable { case done, waiting, working, todo }

    let kind: Kind
    let when: String
    let tone: Tone
    var id: Kind { kind }
}

/// The progress steps of a card, from what the panel already read: the card's dates and sections, and the action log. Pure and testable.
enum TaskProgress {
    static func steps(card: TaskCard, phase: TaskPhase?, events: [ActionLogEvent], now: Date, calendar: Calendar = .current) -> [ProgressStep] {
        // One pass over the log with a cheap prefix test first: only a few line shapes concern a card, and the log has thousands of lines.
        var start: Date?, packetAt: Date?, fixAt: Date?, approvedAt: Date?
        let startPrefix = "start \(card.id) agent="
        for e in events where e.concerns(project: card.project) {
            let text = e.text
            if text.hasPrefix("start ") {
                if text.hasPrefix(startPrefix), start.map({ e.time < $0 }) ?? true { start = e.time }
            } else if text.hasPrefix("review ") {
                let w = text.split(separator: " ")
                if w.count >= 5, w[0] == "review", w[1] == "packet", w[2] == "prepared", w[4] == card.id, packetAt.map({ e.time > $0 }) ?? true { packetAt = e.time }
            } else if text.hasPrefix("fix ") {
                let w = text.split(separator: " ")
                if w.count >= 3, w[0] == "fix", w[1] == "request", w.last.map(String.init) == card.id, fixAt.map({ e.time > $0 }) ?? true { fixAt = e.time }
            } else if text.hasPrefix("approved ") {
                let w = text.split(separator: " ")
                if w.count >= 2, w[0] == "approved", w[1] == card.id, approvedAt.map({ e.time > $0 }) ?? true { approvedAt = e.time }
            }
        }
        let time = { (d: Date?) in d.map { clock($0, now: now, calendar: calendar) } }
        let duration = { (end: Date?) -> String? in
            guard let start, let end else { return nil }
            return Stats.durationText(max(0, end.timeIntervalSince(start)))
        }
        let raw = (card.sections["Review packet"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let packetText: String = {
            let p = packetSections(from: raw)
            let base = p.buildPassed ? "passed" : p.build.hasPrefix("none") ? "no build" : p.build.isEmpty ? "ready" : "failed"
            return [base, time(packetAt)].compactMap { $0 }.joined(separator: " ")
        }()
        let dash = "—"
        let s = card.status

        let started: (String, ProgressStep.Tone)
        switch s {
        case .todo, .unknown: started = (dash, .todo)
        case .awaitingStartApproval: started = ("your call", .waiting)
        default: started = (time(start) ?? (card.agent == nil ? dash : "started"), card.agent == nil && start == nil ? .todo : .done)
        }

        let work: (String, ProgressStep.Tone)
        switch s {
        case .doing, .blocked, .needsFix:
            if phase == .waitingForYou { work = ("asks you", .waiting) }
            else if s == .needsFix { work = ("fixing", .working) }
            else if s == .blocked { work = ("blocked", .waiting) }
            else if phase == .finished { work = (duration(now) ?? "done", .done) }
            else { work = (duration(now) ?? "working", .working) }
        case .review, .done: work = (duration(packetAt ?? approvedAt) ?? "done", .done)
        default: work = (dash, .todo)
        }

        let packet: (String, ProgressStep.Tone)
        switch s {
        case .review, .done: packet = (raw.isEmpty ? "none" : packetText, .done)
        case .doing where phase == .finished: packet = ("prepare", .waiting)
        default: packet = (raw.isEmpty ? dash : packetText, .todo)
        }

        let review: (String, ProgressStep.Tone)
        switch s {
        case .review: review = ("now", .waiting)
        case .done: review = ("approved", .done)
        case .needsFix: review = (["fix asked", time(fixAt)].compactMap { $0 }.joined(separator: " "), .todo)
        default: review = (dash, .todo)
        }

        let merged: (String, ProgressStep.Tone)
        switch s {
        case .done:
            let parts = [time(approvedAt ?? AgentTagInfo.decisionDateTime(card, calendar: calendar)), release(card)].compactMap { $0 }
            merged = (parts.isEmpty ? "merged" : parts.joined(separator: " · "), .done)
        case .cancelled: merged = ("closed", .todo)
        default: merged = (dash, .todo)
        }

        return [ProgressStep(kind: .card, when: time(card.created) ?? dash, tone: .done),
                ProgressStep(kind: .started, when: started.0, tone: started.1),
                ProgressStep(kind: .work, when: work.0, tone: work.1),
                ProgressStep(kind: .packet, when: packet.0, tone: packet.1),
                ProgressStep(kind: .review, when: review.0, tone: review.1),
                ProgressStep(kind: .merged, when: merged.0, tone: merged.1)]
    }

    /// "13:05" today, "Oct 17" on another day.
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d"
        return f.string(from: date)
    }

    /// The merge commit the Decision section names ("Merged 2026-10-19 by PM (63fef19, stable-80)").
    static func commit(_ card: TaskCard) -> String? {
        guard let d = card.sections["Decision"], let r = d.range(of: #"\([0-9a-f]{7,40}[,)]"#, options: .regularExpression) else { return nil }
        return String(d[r].dropFirst().dropLast())
    }

    /// The stable release the Decision section names ("stable-80").
    static func release(_ card: TaskCard) -> String? {
        guard let d = card.sections["Decision"], let r = d.range(of: #"stable-\d+"#, options: .regularExpression) else { return nil }
        return String(d[r])
    }
}

/// One line of "Report in short": a bold lead ("Cause") and its first sentence.
struct ReportLine: Equatable {
    let lead: String?
    let text: String
}

enum ReportSummary {
    /// The first three bullet points of a Report (lead and first sentence each), or its first three sentences when it has no bullets.
    static func lines(_ report: String) -> [ReportLine] {
        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let bullets = trimmed.components(separatedBy: "\n").compactMap(bulletBody)
        if !bullets.isEmpty { return bullets.prefix(3).map(line) }
        return sentences(clean(trimmed.replacingOccurrences(of: "\n", with: " "))).prefix(3).map { ReportLine(lead: nil, text: $0) }
    }

    private static func bulletBody(_ line: String) -> String? {
        guard !line.hasPrefix("  ") else { return nil }
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("- ") || l.hasPrefix("* ") { return String(l.dropFirst(2)) }
        if let r = l.range(of: #"^\d+\. "#, options: .regularExpression) { return String(l[r.upperBound...]) }
        return nil
    }

    private static func line(_ body: String) -> ReportLine {
        if body.hasPrefix("**"), let close = body.range(of: "**", range: body.index(body.startIndex, offsetBy: 2)..<body.endIndex) {
            let lead = String(body[body.index(body.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ".: "))
            let rest = String(clean(String(body[close.upperBound...])).drop { ".: ".contains($0) })
            return ReportLine(lead: lead.isEmpty ? nil : lead, text: sentences(rest).first ?? "")
        }
        return ReportLine(lead: nil, text: sentences(clean(body)).first ?? "")
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Sentences end at ". ", "! " or "? " (so "NotesPad.swift" stays whole); a very long one is cut.
    private static func sentences(_ s: String) -> [String] {
        var out: [String] = [], current = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if ".!?".contains(c), i + 1 == chars.count || chars[i + 1] == " " {
                out.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }.map { $0.count > 220 ? String($0.prefix(219)) + "…" : $0 }
    }
}

/// The Agent box: model, effort, tokens and cost of the card's agent.
struct AgentFacts: Equatable {
    let model: String
    /// The role's configured model, when the session used another one.
    let modelHelp: String?
    let effort: String
    let tokens: String
    let cost: String

    /// `role`: the card's role as configured; `cost`: its agent's session files (`CostReader.taskCost`); nil when there are none.
    static func make(role: RoleConfig?, cost: SessionCost?, hasAgent: Bool) -> AgentFacts {
        let configured = role.map { ModelName.display($0.model) }
        let used = hasAgent ? cost?.mainModel.map(ModelName.display) : nil
        let help = used != nil && configured != nil && used != configured ? "Configured for the role: \(configured!)" : nil
        let effort = role.map { $0.effort.isEmpty ? "default" : $0.effort } ?? "—"
        guard hasAgent, let cost, !cost.usage.isEmpty else {
            return AgentFacts(model: used ?? configured ?? "—", modelHelp: help, effort: effort, tokens: "—", cost: "—")
        }
        let u = cost.usage
        let total = u.input + u.output + u.cacheWrite + u.cacheRead
        let cached = total > 0 ? Int((Double(u.cacheRead) / Double(total) * 100).rounded()) : 0
        return AgentFacts(model: used ?? configured ?? "—", modelHelp: help, effort: effort,
                          tokens: "\(tokenCount(total)) · \(cached)% cached",
                          cost: cost.dollars.map { String(format: "$%.2f", $0) } ?? (cost.isTokensOnly ? "tokens only" : "unknown"))
    }

    /// "800", "1.5 k", "12 k", "2.1 M".
    static func tokenCount(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 { return n < 10_000 ? String(format: "%.1f k", Double(n) / 1_000) : "\(n / 1_000) k" }
        return String(format: "%.1f M", Double(n) / 1_000_000)
    }
}

/// Model ids as people say them: "claude-sonnet-5-5" → "Sonnet 5.5".
enum ModelName {
    static func display(_ id: String) -> String {
        var s = id.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        if s.isEmpty || s == "default" { return "default" }
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        let parts = s.split(separator: "-").map(String.init)
        guard let family = parts.first, ["opus", "sonnet", "haiku", "fable"].contains(family) else { return id }
        let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return family.capitalized + (version.isEmpty ? "" : " " + version.joined(separator: "."))
    }
}

/// One line of the Changed files box, from the review packet's diff summary (git's diffstat).
struct ChangedFile: Equatable {
    let path: String
    let added: Int
    let removed: Int
    /// git scales the +/− bar when a file is large; a mixed bar then only gives the share.
    let exact: Bool
    let binary: Bool
    var name: String { (path as NSString).lastPathComponent }

    var text: String {
        if binary { return "binary" }
        let parts = [added > 0 ? "+\(added)" : nil, removed > 0 ? "−\(removed)" : nil].compactMap { $0 }
        return (exact ? "" : "≈ ") + (parts.isEmpty ? "0" : parts.joined(separator: " "))
    }

    static func parse(_ diff: String) -> [ChangedFile] {
        diff.components(separatedBy: "\n").compactMap { line in
            guard let bar = line.range(of: " | ") else { return nil }
            let path = line[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = line[bar.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("Bin") { return ChangedFile(path: path, added: 0, removed: 0, exact: true, binary: true) }
            let words = rest.split(separator: " ", maxSplits: 1)
            guard let n = words.first.flatMap({ Int($0) }) else { return nil }
            let graph = words.count > 1 ? words[1] : ""
            let plus = graph.filter { $0 == "+" }.count, minus = graph.filter { $0 == "-" }.count
            if minus == 0 { return ChangedFile(path: path, added: n, removed: 0, exact: true, binary: false) }
            if plus == 0 { return ChangedFile(path: path, added: 0, removed: n, exact: true, binary: false) }
            if plus + minus == n { return ChangedFile(path: path, added: plus, removed: minus, exact: true, binary: false) }
            let added = Int((Double(n) * Double(plus) / Double(plus + minus)).rounded())
            return ChangedFile(path: path, added: added, removed: n - added, exact: false, binary: false)
        }
    }
}

/// One button of the detail's tab row: greyed out while its content does not exist yet.
struct DetailTab: Equatable {
    let tab: TaskDetailView.Tab
    let title: String
    /// Shown as a small number after the label (Changes, Screenshots); nil for the others or when there is nothing.
    var count: Int? = nil
    let enabled: Bool

    static func items(card: TaskCard, shots: Int) -> [DetailTab] {
        let packetRaw = (card.sections["Review packet"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let packet = packetSections(from: packetRaw)
        let changes = packet.filesChanged ?? card.files.count
        let report = !(card.sections["Report"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return TaskDetailView.Tab.allCases.map { tab in
            switch tab {
            case .overview, .card, .timeline, .preview: return DetailTab(tab: tab, title: tab.rawValue, enabled: true)
            case .report: return DetailTab(tab: tab, title: tab.rawValue, enabled: report)
            case .packet: return DetailTab(tab: tab, title: tab.rawValue, enabled: !packetRaw.isEmpty)
            case .changes: return DetailTab(tab: tab, title: tab.rawValue, count: changes > 0 ? changes : nil, enabled: changes > 0 || !packet.diff.isEmpty)
            case .screenshots: return DetailTab(tab: tab, title: tab.rawValue, count: shots > 0 ? shots : nil, enabled: shots > 0)
            }
        }
    }

    /// ⌘[ / ⌘]: the enabled tab `delta` steps away, stopping at the ends.
    static func move(from current: TaskDetailView.Tab, in items: [DetailTab], by delta: Int) -> TaskDetailView.Tab {
        let tabs = items.filter(\.enabled).map(\.tab)
        guard let i = tabs.firstIndex(of: current) else { return tabs.first ?? current }
        return tabs[min(max(i + delta, 0), tabs.count - 1)]
    }
}
