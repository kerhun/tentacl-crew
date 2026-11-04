import Foundation

// N385: what the Review packets, Fix loops and PM decisions tiles show. Everything is read here (card files, `tasks/<ID>/`, the action
// log, the decision log, git); the tiles only draw the rows.

/// `+112 −8 · 6 files`: the branch against the project's main branch.
struct BranchDiff: Equatable, Sendable {
    var added: Int
    var deleted: Int
    var files: Int
    /// The changed paths; empty when only the totals are known (the packet's diff summary).
    var paths: [String] = []

    var text: String { "+\(added) −\(deleted) · \(files) \(files == 1 ? "file" : "files")" }
}

/// One card in review, summed up for the Review packets tile.
struct ReviewPacketSummary: Equatable, Identifiable {
    enum Build: Equatable { case passed, failed, unknown }
    let id: String
    let title: String
    let build: Build
    /// "2950 / 0" (run / failed), nil when the Report's Tests line cannot be read.
    let tests: String?
    let shots: Int
    var diff: BranchDiff?
    /// Changed files that are not under the card's `files:` list.
    var outside: [String] = []

    var testsText: String { "tests " + (tests ?? "—") }
    var buildText: String {
        switch build {
        case .passed: "build ✓"
        case .failed: "build ✗"
        case .unknown: "build —"
        }
    }
}

/// An F-number of the card's Fix notes with a few words of what it asks.
struct FixNoteLabel: Equatable {
    let label: String
    let text: String
}

/// A card back from review, for the Fix loops tile.
struct FixLoopSummary: Equatable, Identifiable {
    let id: String
    let title: String
    let notes: [FixNoteLabel]
    /// The fix round: how many times the card was sent back (at least 1).
    let round: Int

    /// Round 3 and later: the card may need splitting.
    var isRed: Bool { round >= DashboardFeeds.redRound }
    /// "F1 hero, F2 stats"; empty without F-numbers.
    var notesText: String { notes.map { $0.text.isEmpty ? $0.label : "\($0.label) \($0.text)" }.joined(separator: ", ") }
}

/// One agent question of today the PM answered or sent to the user.
struct PMDecisionRow: Equatable, Identifiable {
    let id: String
    let time: Date
    let cardID: String
    /// "N384-q1" when the action log names it; nil for a question that never went through the relay.
    let qid: String?
    let question: String
    /// The PM's answer; empty for a question sent to the user.
    let answer: String
    let toYou: Bool
    let critical: Bool

    var ref: String { qid ?? cardID }
}

struct PMDecisionsDay: Equatable {
    var answered: [PMDecisionRow] = []
    var toYou: [PMDecisionRow] = []

    var isEmpty: Bool { answered.isEmpty && toYou.isEmpty }
    var header: String { "today: \(answered.count) answered · \(toYou.count) sent to you" }
    /// Sent to you first (they need you), then the answers, newest first in each.
    var rows: [PMDecisionRow] { toYou + answered }
}

enum DashboardFeeds {
    static let redRound = 3
    static let redLine = "Round 3+ is shown red: the card may need splitting."
    static let noPackets = "No card is in review."
    static let noFixLoops = "No card came back from review."
    static let noDecisions = "The PM has not answered or passed on a question today."

    // MARK: Review packets

    /// The selected project's cards in review, in card order. `diffs` are the branch reads by card id (see `readDiff`); a card without one
    /// falls back to the packet's diff summary.
    static func reviewPackets(cards: [TaskCard], dataDir: URL?, diffs: [String: BranchDiff] = [:]) -> [ReviewPacketSummary] {
        cards.filter { $0.status == .review }.map { packet($0, dataDir: dataDir, diff: diffs[$0.id]) }
    }

    static func packet(_ card: TaskCard, dataDir: URL?, diff: BranchDiff?) -> ReviewPacketSummary {
        let folder = dataDir?.appendingPathComponent("tasks").appendingPathComponent(card.id)
        let log = folder.flatMap { readTail($0.appendingPathComponent("build.log")) }
        let packet = card.sections["Review packet"] ?? ""
        let d = diff ?? packetDiff(packet)
        return ReviewPacketSummary(id: card.id, title: card.title, build: build(log: log, packet: packet),
                                   tests: testsRun(report: card.sections["Report"] ?? ""),
                                   shots: folder.map { shotCount($0.appendingPathComponent("shots")) } ?? 0,
                                   diff: d, outside: outside(d?.paths ?? [], cardFiles: card.files))
    }

    /// The last 64 KB of a file: a build log's verdict is at its end, and a log can be megabytes long.
    static func readTail(_ url: URL, bytes: Int = 65_536) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? h.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    /// From `build.log`: its last lines decide first (tests/run.sh's "ALL PASSED", xcodebuild's SUCCEEDED / FAILED lines, a non-zero
    /// "N failed"); else any FAILED or FAIL line anywhere is failed. Without a log, or one that says neither, the packet's `Build:` line decides.
    static func build(log: String?, packet: String = "") -> ReviewPacketSummary.Build {
        if let log, !log.isEmpty {
            let lines = log.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            func fails(_ l: String) -> Bool {
                l.contains("** BUILD FAILED **") || l.contains("** TEST FAILED **") || l.hasPrefix("FAIL ") || l == "FAIL"
                    || l == "FAILURES" || l.hasPrefix("failed  ")
            }
            func passes(_ l: String) -> Bool { l.contains("ALL PASSED") || l.contains("** BUILD SUCCEEDED **") || l.contains("** TEST SUCCEEDED **") }
            for l in lines.suffix(8).reversed() {
                if fails(l) || firstMatch(#"(?:^|[^\d])([1-9]\d*) failed\b"#, in: l) != nil || firstMatch(#"with [1-9]\d* failures?"#, in: l) != nil { return .failed }
                if passes(l) { return .passed }
            }
            if lines.contains(where: fails) { return .failed }
            if lines.contains(where: passes) { return .passed }
        }
        for line in packet.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces).lowercased()
            if l.hasPrefix("build: passed") { return .passed }
            if l.hasPrefix("build: failed") { return .failed }
        }
        return .unknown
    }

    /// "2950 / 0" from the Report's Tests line: "2950 run / 0 failed", "tests 1774/0", or "Executed 2950 tests, with 0 failures".
    static func testsRun(report: String) -> String? {
        guard let line = reviewReportSummary(report).first(where: { $0.label == "Tests" })?.text else { return nil }
        for pattern in [#"(\d+)\s*run\s*/\s*(\d+)\s*failed"#, #"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?"#, #"(\d+)\s*/\s*(\d+)"#] {
            if let m = firstMatch(pattern, in: line), m.count == 3 { return "\(m[1]) / \(m[2])" }
        }
        return nil
    }

    static func shotCount(_ folder: URL) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.count
    }

    /// `git diff --numstat` lines: "12<TAB>3<TAB>path" (binary files have "-").
    static func parseNumstat(_ text: String) -> BranchDiff {
        var d = BranchDiff(added: 0, deleted: 0, files: 0)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            d.added += Int(parts[0]) ?? 0
            d.deleted += Int(parts[1]) ?? 0
            d.files += 1
            d.paths.append(renamedTo(parts[2]))
        }
        return d
    }

    /// "a/{old => new}/b" or "old => new" as numstat prints a rename: the new path.
    static func renamedTo(_ path: String) -> String {
        guard path.contains(" => ") else { return path }
        if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}"), open < close {
            let inner = path[path.index(after: open)..<close].components(separatedBy: " => ")
            let joined = String(path[..<open]) + (inner.last ?? "") + String(path[path.index(after: close)...])
            return joined.replacingOccurrences(of: "//", with: "/")
        }
        return path.components(separatedBy: " => ").last ?? path
    }

    /// The packet's "6 files changed, 112 insertions(+), 1 deletion(-)" line; nil when there is none.
    static func packetDiff(_ packet: String) -> BranchDiff? {
        guard let m = firstMatch(#"(\d+) files? changed(?:, (\d+) insertions?\(\+\))?(?:, (\d+) deletions?\(-\))?"#, in: packet) else { return nil }
        return BranchDiff(added: Int(m[2]) ?? 0, deleted: Int(m[3]) ?? 0, files: Int(m[1]) ?? 0)
    }

    /// Changed paths that no entry of `files:` covers (the path itself, or a folder it is in; an entry may start with `app/` or not).
    static func outside(_ paths: [String], cardFiles: [String]) -> [String] {
        guard !cardFiles.isEmpty else { return [] }
        let entries = cardFiles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return paths.filter { p in
            !entries.contains { e in
                let folder = e.hasSuffix("/") ? e : e + "/"
                return p == e || p.hasPrefix(folder) || p.hasSuffix("/" + e) || p.contains("/" + folder)
            }
        }
    }

    /// The card's branch against the main branch: `git diff --numstat <base>...<branch>` in the repository. Nil when git cannot tell.
    static func readDiff(repo: String, base: String, branch: String, runner: GitToolRunning, git: URL = URL(fileURLWithPath: "/usr/bin/git")) async -> BranchDiff? {
        let r = await runner.run(git, ["-C", repo, "diff", "--numstat", "\(base)...\(branch)"])
        guard r.status == 0 else { return nil }
        return parseNumstat(r.stdout)
    }

    // MARK: Fix loops

    /// Cards back from review: `needs-fix`, or `doing` with a fix request newer than their last review packet.
    static func fixLoops(cards: [TaskCard], events: [ActionLogEvent], decisions: [DecisionRecord], project: String) -> [FixLoopSummary] {
        let mine = events.filter { $0.concerns(project: project) }
        let rebases = decisions.filter { $0.kind == AutopilotModel.rebaseKind && $0.by == .pm && $0.result == .answered }
        let loops: [FixLoopSummary] = cards.compactMap { card in
            guard card.status == .needsFix || card.status == .doing else { return nil }
            let fixes = fixTimes(card.id, events: mine, rebases: rebases)
            if card.status == .doing {
                let packet = mine.filter { isPacketPrepared($0.text, card.id) }.map(\.time).max()
                guard let last = fixes.max(), packet.map({ last > $0 }) ?? true else { return nil }
            }
            return FixLoopSummary(id: card.id, title: card.title, notes: fixNotes(card.sections["Fix notes"] ?? ""), round: max(fixes.count, 1))
        }
        return loops.sorted { $0.round != $1.round ? $0.round > $1.round : $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// The fix round of a card: its "fix request … sent to … for ID" lines, without the ones sent with the PM's rebase request (within two
    /// minutes), which are a rebase, not a fix.
    static func fixRound(_ cardID: String, events: [ActionLogEvent], decisions: [DecisionRecord] = [], project: String) -> Int {
        let rebases = decisions.filter { $0.kind == AutopilotModel.rebaseKind && $0.by == .pm && $0.result == .answered }
        return fixTimes(cardID, events: events.filter { $0.concerns(project: project) }, rebases: rebases).count
    }

    private static func fixTimes(_ id: String, events: [ActionLogEvent], rebases: [DecisionRecord]) -> [Date] {
        let rebaseTimes = rebases.filter { $0.cardID == id }.map(\.time)
        return events.filter { isFixRequest($0.text, id) }.map(\.time).filter { t in !rebaseTimes.contains { abs($0.timeIntervalSince(t)) <= 120 } }
    }

    static func isFixRequest(_ text: String, _ id: String) -> Bool {
        let w = text.split(separator: " ")
        return w.count >= 4 && w[0] == "fix" && w[1] == "request" && text.contains(" sent to ") && w[w.count - 2] == "for" && w.last.map(String.init) == id
    }

    private static func isPacketPrepared(_ text: String, _ id: String) -> Bool {
        let w = text.split(separator: " ")
        return w.count >= 5 && w[0] == "review" && w[1] == "packet" && w[2] == "prepared" && w[4] == Substring(id)
    }

    /// The F-numbers in `## Fix notes` with their first three words ("F1 hero shot"), the newest text of each number; answers written
    /// under "### Fix round N" are left out.
    static func fixNotes(_ body: String) -> [FixNoteLabel] {
        var order: [String] = []
        var text: [String: String] = [:]
        var skipping = false
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") { skipping = line.lowercased().hasPrefix("### fix round"); continue }
            guard !skipping, let m = firstMatch(#"^[>\-*\s]*\**(F\d+)\**\b[\s:.)\-–—*]*(.*)$"#, in: line) else { continue }
            let label = m[1]
            let words = m[2].filter { !"*`()".contains($0) }
                .split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.-–—")) }.filter { !$0.isEmpty }
                .prefix(3).joined(separator: " ")
            if text[label] == nil { order.append(label) }
            text[label] = words
        }
        return order.map { FixNoteLabel(label: $0, text: text[$0] ?? "") }
    }

    // MARK: PM decisions

    static let questionKinds: Set<String> = [DecisionCategory.choice, .freeText, .permission, .plan].map(\.rawValue).reduce(into: []) { $0.insert($1) }

    /// Today's agent questions the PM answered and the ones it sent to the user, newest first. `events` name the relay's question id
    /// ("answered-by-pm N384-q1 (N384): …", "relayed to the PM: QUESTION N384-q1 …").
    static func pmDecisions(_ records: [DecisionRecord], events: [ActionLogEvent] = [], project: String? = nil,
                            now: Date = Date(), calendar: Calendar = .current) -> PMDecisionsDay {
        let today = records.filter { calendar.isDate($0.time, inSameDayAs: now) && $0.by == .pm && questionKinds.contains($0.kind) }
        let relayEvents = events.filter { calendar.isDate($0.time, inSameDayAs: now) && (project.map($0.concerns(project:)) ?? true) }
        let answeredQids = relayEvents.compactMap { e -> (Date, String, String)? in
            guard let m = firstMatch(#"^answered-by-pm (\S+) \((\S+)\)"#, in: e.text) else { return nil }
            return (e.time, m[1], m[2])
        }
        let relayedQids = relayEvents.compactMap { e -> (Date, String, String)? in
            guard let m = firstMatch(#"^relayed to the PM: QUESTION (\S+) .*?· (\S+?):"#, in: e.text) else { return nil }
            return (e.time, m[1], m[2])
        }
        func qid(_ r: DecisionRecord, _ list: [(Date, String, String)], within: TimeInterval) -> String? {
            list.filter { $0.2 == r.cardID && abs($0.0.timeIntervalSince(r.time)) <= within }.min { abs($0.0.timeIntervalSince(r.time)) < abs($1.0.timeIntervalSince(r.time)) }?.1
        }
        var day = PMDecisionsDay()
        for r in today.sorted(by: { $0.time > $1.time }) {
            switch r.result {
            case .answered:
                day.answered.append(PMDecisionRow(id: r.id, time: r.time, cardID: r.cardID, qid: qid(r, answeredQids, within: 30),
                                                  question: questionTitle(r.question), answer: r.answer, toYou: false, critical: false))
            case .escalated:
                day.toYou.append(PMDecisionRow(id: r.id, time: r.time, cardID: r.cardID, qid: qid(r, relayedQids, within: 900),
                                               question: questionTitle(r.question), answer: "", toYou: true, critical: isCritical(r.why)))
            case .suggested: continue
            }
        }
        return day
    }

    /// The decision log keeps "Title: text"; the tile shows the text after the title when there is one.
    static func questionTitle(_ q: String) -> String {
        guard let colon = q.range(of: ": ") else { return q }
        let rest = q[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? q : rest
    }

    /// The hard rules' reasons (`AutopilotRules.criticalReason`) and "always yours".
    static func isCritical(_ why: String) -> Bool {
        ["marked it critical", "Reaches outside", "Can destroy", "outside the card's files", "always yours"].contains { why.localizedCaseInsensitiveContains($0) }
    }

    // MARK: helpers

    /// The whole match and its groups (an unmatched group is ""), or nil.
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}
