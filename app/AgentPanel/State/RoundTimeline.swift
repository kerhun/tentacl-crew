import Foundation

/// Where a timeline item points: the card, the question asked, or the card's review packet.
enum TimelineLink: Equatable, Hashable {
    case card(String)
    case question(String)
    case packet(String)
}

/// One bar (with an end) or dot (no end) in a lane of the round timeline.
struct TimelineItem: Equatable, Identifiable {
    enum Kind: Equatable { case working, packet, waiting, merged, asked, pmDecision }
    let kind: Kind
    let lane: String
    let start: Date
    /// How a bar's end is known (N355): read from a record, guessed from the card's next moment, still running, or unknown.
    enum Tail: Equatable { case recorded, guessed, live, unknown }
    /// Nil for a dot, and for a bar whose end was never recorded and has no later moment to guess it from (see `tail`).
    var end: Date?
    var tail: Tail = .recorded
    /// A packet prepared again without new work from the agent (a rebase or a new commit on the branch).
    var isRepeat = false
    let title: String
    var what: String
    var why: String
    var links: [TimelineLink]
    var id: String { "\(lane)-\(kind)-\(start.timeIntervalSince1970)-\(title)" }
    var isBar: Bool { kind == .working || kind == .packet || kind == .waiting }
    var seconds: TimeInterval { end.map { max(0, $0.timeIntervalSince(start)) } ?? 0 }
}

struct TimelineLane: Equatable, Identifiable {
    /// "PM" or the card id.
    let id: String
    let title: String
    var items: [TimelineItem]
}

struct RoundSummary: Equatable {
    /// The numbers that can be estimated; the rest (the counts) are read straight from the log.
    enum Part: Hashable { case round, working, waiting, packets, cost }

    /// From the first to the last recorded moment; nil when nothing is recorded.
    var roundSeconds: TimeInterval?
    /// The agents' own work, summed over the cards (rebase turns are counted under `packetSeconds`).
    var workingSeconds: TimeInterval = 0
    /// The time anything in the round waited for the user (overlapping waits count once).
    var waitingSeconds: TimeInterval = 0
    /// Review packets (prepared, failed or prepared again) and the agents' rebase turns, summed over the cards.
    var packetSeconds: TimeInterval = 0
    /// Fix requests sent to the agents, rebase requests left out.
    var fixRounds = 0
    var rebaseRounds = 0
    /// Of `fixRounds`: requests sent for a packet whose test run broke (before N202 sorted packet failures).
    var infrastructureFixes = 0
    /// Packet runs that broke and were retried by the panel or handed to the user, never sent to the agent (N202).
    var infrastructureRuns = 0
    /// The PM's recorded decision costs plus the agents' sessions; nil when no cost is known.
    var cost: Double?
    /// Every card of the round is done or cancelled.
    var finished = false
    /// The numbers that rest on a guess somewhere; each guess is said in `notes`.
    var estimated: Set<Part> = []
    /// What was estimated or left out: one sentence per kind of guess, naming the cards it applies to.
    var notes: [String] = []

    /// Every turn the round lost to a failed review or a broken run.
    var fixTurns: Int { fixRounds + infrastructureRuns }
    var infrastructureTurns: Int { infrastructureFixes + infrastructureRuns }
}

/// One cause of lost time, summed over the round.
struct RoundDelay: Equatable {
    /// The order is the tie-break when two causes lost the same time.
    enum Kind: Int, Equatable { case repeatedPackets, roundSheet, questions, fixes, mergeWait }
    let kind: Kind
    let count: Int
    let seconds: TimeInterval
    let text: String
}

struct RoundTimelineData: Equatable {
    let round: PlanRound
    let lanes: [TimelineLane]
    let start: Date?
    let end: Date?
    let summary: RoundSummary
    /// The three causes that lost the most time, largest first.
    let delays: [RoundDelay]
    /// What could not be read from the records (shown under the timeline).
    let gaps: [String]
    /// The moment the data was built; a live work bar is drawn up to it.
    var now = Date()

    /// How long a bar with an unknown end and nothing after it is drawn: a short stub, never the rest of the round (N355).
    static let unknownStub: TimeInterval = 5 * 60

    /// Where a bar is drawn to: its end, else now for live work, else a short stub.
    func drawnEnd(_ item: TimelineItem) -> Date {
        if let end = item.end { return end }
        return item.tail == .live ? max(now, item.start) : item.start.addingTimeInterval(Self.unknownStub)
    }

    /// The chart's right edge: the round's end, or later when a live bar or a stub reaches past it.
    var windowEnd: Date? {
        guard let end else { return nil }
        return lanes.flatMap(\.items).filter(\.isBar).map(drawnEnd).reduce(end, max)
    }
}

/// Builds one round's timeline from the action log, the decision log and the cards; reads nothing itself.
enum RoundTimeline {
    static func build(round: PlanRound, project: String, cards: [TaskCard], events: [ActionLogEvent], decisions: [DecisionRecord],
                      agentCosts: [String: Double] = [:], now: Date = Date()) -> RoundTimelineData {
        let ids = Set(round.cards)
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let facts = Facts(events: events.filter { $0.concerns(project: project) }.sorted { $0.time < $1.time }, ids: ids)
        let mine = decisions.filter { !ids.isDisjoint(with: cardIDs(of: $0)) }.sorted { $0.time < $1.time }
        var gaps: [String] = []
        var delays: [RoundDelay.Kind: (count: Int, seconds: TimeInterval, cards: [String])] = [:]
        func lost(_ kind: RoundDelay.Kind, _ seconds: TimeInterval, _ card: String) {
            var d = delays[kind] ?? (0, 0, [])
            d.count += 1; d.seconds += seconds; if !d.cards.contains(card) { d.cards.append(card) }
            delays[kind] = d
        }

        let pmItems: [TimelineItem] = mine.filter { $0.by == .pm && $0.result != .escalated }.map { d in
            let title = d.result == .suggested ? "PM suggested" : "PM decided"
            let what = d.answer.isEmpty ? d.question : "\(d.question) → \(d.answer)"
            return TimelineItem(kind: .pmDecision, lane: "PM", start: d.time, title: "\(title) · \(d.cardID)", what: what,
                                why: d.why, links: cardIDs(of: d).filter(ids.contains).map { .card($0) })
        }
        var lanes = [TimelineLane(id: "PM", title: "PM", items: pmItems)]
        var summary = RoundSummary()
        var notes = Notes()
        var missingMerge: [String] = []
        var nothing: [String] = []
        var sheetCounted: Set<Date> = []

        for id in round.cards {
            let f = facts.of(id)
            let card = byID[id]
            var items: [TimelineItem] = []
            let mineHere = mine.filter { cardIDs(of: $0).contains(id) }
            let clicks = mineHere.filter { $0.by == .you && $0.kind == "round" }.map(\.time)
            let answers = (f.answered + mineHere.filter { $0.by == .you && $0.kind != "round" && $0.result == .answered }.map(\.time)).sorted()

            // Start requests that waited for the Round sheet: until the user's click, else until the start.
            for r in f.sheetRequests {
                guard let end = (clicks.first { $0 >= r } ?? f.starts.first { $0.time >= r }?.time) else { continue }
                items.append(TimelineItem(kind: .waiting, lane: id, start: r, end: end, title: "\(id) waiting for the Round sheet",
                                          what: "The PM asked to start \(id); the Round sheet waited for your click until \(clock(end)).",
                                          why: "Start requests wait for a click in the Round sheet unless PM authority is on.", links: [.card(id)]))
                // One request for several cards is one wait.
                if sheetCounted.insert(r).inserted { lost(.roundSheet, end.timeIntervalSince(r), id) }
            }

            // Work: from each start or fix request to the next finish, never past the next start or fix.
            // A fix request sent with the PM's rebase request (within two minutes) is a rebase turn, not a fix.
            let rebases = mineHere.filter { $0.kind == AutopilotModel.rebaseKind && $0.by == .pm && $0.result == .answered }.map(\.time)
            func isRebase(_ t: Date) -> Bool { rebases.contains { abs($0.timeIntervalSince(t)) <= 120 } }
            let begins = (f.starts.map { (time: $0.time, fix: false, note: $0.note) } + f.fixes.map { (time: $0, fix: true, note: "") }).sorted { $0.time < $1.time }
            let rebaseCount = f.fixes.filter(isRebase).count
            summary.rebaseRounds += rebaseCount
            summary.fixRounds += f.fixes.count - rebaseCount
            // A work turn without a finish line ends, as a guess, at the card's next packet, merge or done line,
            // else at the next turn; never after the card's merge (a turn begun after it is a reopen with its own segment).
            let laterMarks = (f.packetStarts + f.packets + f.approved + f.doneNotices).sorted()
            let mergeMarks = (f.approved + f.doneNotices).sorted()
            var guessedWork = false, openWork = false
            for (i, b) in begins.enumerated() {
                let next = i + 1 < begins.count ? begins[i + 1].time : nil
                var end = f.finished.first { $0 > b.time }
                if let e = end, let n = next, e > n { end = nil }
                if let e = end, let m = mergeMarks.first(where: { $0 > b.time }), e > m { end = m }
                let rebase = b.fix && isRebase(b.time)
                let why = rebase ? "The branch was behind main; the agent was asked to rebase." : b.fix ? "A fix was requested after the review." : (b.note.isEmpty ? "Started for this round." : b.note)
                let what = end.map { "The agent worked from \(clock(b.time)) to \(clock($0)) and wrote its report." }
                    ?? "The agent started at \(clock(b.time)); no finish is recorded."
                let guess = end == nil ? (laterMarks.first { $0 > b.time && $0 <= (next ?? .distantFuture) } ?? next) : nil
                // No end and nothing later: live while the card is still in progress (so its round still runs), else unknown.
                let tail: TimelineItem.Tail = end != nil ? .recorded : guess != nil ? .guessed : card?.status == .doing ? .live : .unknown
                items.append(TimelineItem(kind: .working, lane: id, start: b.time, end: end ?? guess, tail: tail, title: rebase ? "\(id) rebasing" : "\(id) agent working",
                                          what: tail == .live ? "The agent started at \(clock(b.time)) and is still working." : what, why: why, links: [.card(id)]))
                if b.fix, !rebase, let end { lost(.fixes, end.timeIntervalSince(b.time), id) }
                if end == nil { if guess == nil { openWork = true } else { guessedWork = true } }
                guard let until = end ?? guess else { continue }
                if rebase { summary.packetSeconds += until.timeIntervalSince(b.time) } else { summary.workingSeconds += until.timeIntervalSince(b.time) }
                if guess != nil { summary.estimated.insert(rebase ? .packets : .working) }
            }
            if guessedWork { notes.add(.guessedWork, id) }
            if openWork { notes.add(card?.status == .done ? .openWork : .runningWork, id) }

            // Packets: from their start line, else from the finish before it; a packet with no new finish since the last one is a repeat.
            // A packet that started and never got prepared failed: it runs to the next thing that happened to the card.
            var lastPacket: Date?
            var guessedPacket = false
            for p in f.packets {
                let finish = f.finished.last { $0 <= p }
                let started = f.packetStarts.last { $0 <= p && $0 > (lastPacket ?? .distantPast) }
                let repeated = lastPacket.map { last in finish.map { $0 <= last } ?? true } ?? false
                let begin = started ?? (repeated ? lastPacket! : (finish ?? p))
                if started == nil { guessedPacket = true }
                items.append(TimelineItem(kind: .packet, lane: id, start: begin, end: p, isRepeat: repeated, title: repeated ? "\(id) review packet again" : "\(id) review packet",
                                          what: "Review packet prepared at \(clock(p)).",
                                          why: repeated ? "Prepared again: the branch changed after the last packet (a rebase or a new commit)." : "The agent finished; the review packet was prepared.",
                                          links: [.card(id), .packet(id)]))
                summary.packetSeconds += p.timeIntervalSince(begin)
                if repeated { lost(.repeatedPackets, p.timeIntervalSince(begin), id) }
                lastPacket = p
            }
            let afterFailure = (begins.map(\.time) + f.packetStarts + f.approved + f.doneNotices).sorted()
            for s in f.packetStarts where !f.packets.contains(where: { $0 >= s && $0 <= (f.packetStarts.first { $0 > s } ?? .distantFuture) }) {
                guard let end = afterFailure.first(where: { $0 > s }) else { continue }
                items.append(TimelineItem(kind: .packet, lane: id, start: s, end: end, title: "\(id) review packet failed",
                                          what: "A review packet started at \(clock(s)) and was not prepared; the next step came at \(clock(end)).",
                                          why: "The packet's build or tests did not pass.", links: [.card(id), .packet(id)]))
                summary.packetSeconds += end.timeIntervalSince(s)
                guessedPacket = true
            }
            if guessedPacket {
                summary.estimated.insert(.packets)
                notes.add(.guessedPacket, id)
            }

            // Broken test runs (N202 retries them itself; before that they went to the agent as a fix of "Packet failed").
            summary.infrastructureRuns += mineHere.filter { r in
                (r.kind == DecisionCategory.review.rawValue && r.answer == "Retry" && r.why.hasPrefix(PendingFix.packetCouldNotRun))
                    || (r.kind == DecisionCategory.fix.rawValue && r.question.hasPrefix(PendingFix.packetCouldNotRun))
            }.count
            let brokenFixes = mineHere.filter { r in
                r.kind == DecisionCategory.fix.rawValue && r.by == .pm && r.result == .answered && r.question.hasPrefix(PendingFix.packetFailed + ":")
                    && PacketFailure.infrastructureMarkers.contains { r.question.contains($0) }
            }.count
            summary.infrastructureFixes += min(brokenFixes, f.fixes.count - rebaseCount)

            // Questions to the user: the log line and the PM's escalation of the same question make one wait.
            let escalations = mineHere.filter { $0.by == .pm && $0.result == .escalated }
            let asks = (f.asked.map { (time: $0, record: DecisionRecord?.none) } + escalations.map { (time: $0.time, record: Optional($0)) }).sorted { $0.time < $1.time }
            var questions: [(start: Date, end: Date?, record: DecisionRecord?)] = []
            for a in asks {
                if let i = questions.firstIndex(where: { q in a.time >= q.start && a.time <= (q.end ?? .distantFuture) }) {
                    if questions[i].record == nil { questions[i].record = a.record }
                    continue
                }
                questions.append((a.time, answers.first { $0 >= a.time }, a.record))
            }
            for q in questions {
                let text = q.record?.question ?? "The agent asked a question."
                var links: [TimelineLink] = [.card(id)]
                if let r = q.record { links.append(.question(r.question)) }
                let why = q.record.map { $0.why.isEmpty ? "The PM sent it to you." : $0.why } ?? "The agent asked; the question came to you."
                items.append(TimelineItem(kind: .asked, lane: id, start: q.start, title: "\(id) asked you", what: text, why: why, links: links))
                if let end = q.end {
                    items.append(TimelineItem(kind: .waiting, lane: id, start: q.start, end: end, title: "\(id) waiting for you",
                                              what: "\(text) You answered at \(clock(end)).", why: why, links: links))
                    lost(.questions, end.timeIntervalSince(q.start), id)
                }
            }
            if questions.contains(where: { $0.end == nil }) {
                summary.estimated.insert(.waiting)
                notes.add(.unanswered, id)
            }

            // Merge: the approval line, else the moment the panel saw the card done.
            let decisionText = card?.sections["Decision"]?.split(separator: "\n").first.map(String.init) ?? ""
            let merged: (Date, Bool)? = f.approved.last.map { ($0, true) } ?? f.doneNotices.first.map { ($0, false) }
            if let merged {
                let (time, exact) = merged
                if !exact { missingMerge.append(id) }
                items.append(TimelineItem(kind: .merged, lane: id, start: time, title: "\(id) merged",
                                          what: exact ? "Approved and merged at \(clock(time))." : "Done at \(clock(time)) (when the panel saw it; the merge time is not recorded).",
                                          why: decisionText.isEmpty ? "The review passed." : decisionText, links: [.card(id), .packet(id)]))
                if let packet = f.packets.last(where: { $0 <= time }) {
                    let held = questions.reduce(0.0) { sum, q in
                        guard let e = q.end else { return sum }
                        return sum + max(0, min(e, time).timeIntervalSince(max(q.start, packet)))
                    }
                    let wait = time.timeIntervalSince(packet) - held
                    if wait > 0 { lost(.mergeWait, wait, id) }
                }
            } else if card?.status == .done {
                missingMerge.append(id)
            }

            if items.isEmpty { nothing.append(id) }
            items.sort { ($0.start, $0.isBar ? 0 : 1) < ($1.start, $1.isBar ? 0 : 1) }
            // Card titles often repeat the id ("N86 · Title").
            let title = card.map { $0.title.hasPrefix("\(id) · ") ? String($0.title.dropFirst(id.count + 3)) : $0.title } ?? id
            lanes.append(TimelineLane(id: id, title: title, items: items))
        }

        var all = lanes.flatMap(\.items)
        let start = all.map(\.start).min()
        let end = all.flatMap { [$0.start, $0.end].compactMap { $0 } }.max()
        // The user's resets of the PM's start count name no card: shown when they fall inside the round.
        if let start, let end {
            let resets = decisions.filter { $0.kind == AutopilotModel.authorityResetKind && $0.time >= start && $0.time <= end }.sorted { $0.time < $1.time }.map {
                TimelineItem(kind: .pmDecision, lane: "PM", start: $0.time, title: "PM start count reset", what: "Started today: 0", why: $0.why, links: [])
            }
            lanes[0].items = (lanes[0].items + resets).sorted { $0.start < $1.start }
            all += resets
        }
        if let start, let end { summary.roundSeconds = end.timeIntervalSince(start) }
        summary.waitingSeconds = union(all.filter { $0.kind == .waiting }.compactMap { i in i.end.map { (i.start, $0) } })
        summary.finished = !round.cards.isEmpty && round.cards.allSatisfy { byID[$0]?.status == .done || byID[$0]?.status == .cancelled }
        if !missingMerge.isEmpty { summary.estimated.insert(.round) }
        let pmCost = mine.compactMap(\.costUSD)
        let agent = round.cards.compactMap { agentCosts[$0] }
        if !pmCost.isEmpty || !agent.isEmpty {
            summary.cost = pmCost.reduce(0, +) + agent.reduce(0, +)
            summary.estimated.insert(.cost)
        }
        summary.notes = notes.lines

        if !nothing.isEmpty { gaps.append("Nothing is recorded for \(nothing.joined(separator: ", ")).") }
        if !missingMerge.isEmpty { gaps.append("No merge time is recorded for \(missingMerge.joined(separator: ", ")); the dot is when the panel saw the card done, if it did.") }
        if agent.count < round.cards.count, summary.cost != nil { gaps.append("The cost leaves out agent sessions that could not be read.") }

        let ranked = delays.filter { $0.value.seconds > 0 }
            .sorted { ($1.value.seconds, $0.key.rawValue) < ($0.value.seconds, $1.key.rawValue) }
            .prefix(3)
            .map { RoundDelay(kind: $0.key, count: $0.value.count, seconds: $0.value.seconds, text: text(for: $0.key, $0.value.count, $0.value.seconds, $0.value.cards)) }
        return RoundTimelineData(round: round, lanes: lanes, start: start, end: end, summary: summary, delays: Array(ranked), gaps: gaps, now: now)
    }

    /// Axis marks on round clock times (every 5, 10, 15, 30 minutes or hours), at most eight inside the window.
    static func ticks(from start: Date, to end: Date) -> [Date] {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [start] }
        let steps: [TimeInterval] = [5, 10, 15, 30, 60, 120, 240, 480, 720, 1440].map { $0 * 60 }
        let step = steps.first { span / $0 <= 8 } ?? steps.last!
        var t = (start.timeIntervalSince1970 / step).rounded(.up) * step
        var result: [Date] = []
        while t <= end.timeIntervalSince1970 { result.append(Date(timeIntervalSince1970: t)); t += step }
        return result
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// A decision about several cards names them as "N1, N2".
    private static func cardIDs(of d: DecisionRecord) -> [String] {
        d.cardID.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func union(_ intervals: [(Date, Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for (s, e) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let c = current, s <= c.1 { current = (c.0, max(c.1, e)) }
            else { if let c = current { total += c.1.timeIntervalSince(c.0) }; current = (s, e) }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    private static func text(for kind: RoundDelay.Kind, _ count: Int, _ seconds: TimeInterval, _ cards: [String]) -> String {
        let total = Stats.durationText(seconds)
        let each = Stats.durationText(seconds / Double(max(count, 1)))
        let names = cards.joined(separator: ", ")
        switch kind {
        case .repeatedPackets:
            return count == 1 ? "A review packet for \(names) was prepared again after the branch changed: \(total)."
                : "Review packets were prepared again after the branch changed (\(names)): \(count) × ~\(each)."
        case .roundSheet:
            return count == 1 ? "A start request waited for a click in the Round sheet: \(total)."
                : "Start requests waited for a click in the Round sheet: \(count) times, \(total) in all."
        case .questions:
            return count == 1 ? "One question to you held \(names) for \(total)." : "\(count) questions to you held \(names) for \(total) in all."
        case .fixes:
            return count == 1 ? "A fix round on \(names) took \(total)." : "\(count) fix rounds (\(names)) took \(total) in all."
        case .mergeWait:
            return "Passed packets waited for a merge (\(names)): \(total) in all."
        }
    }
}

/// The summary's ≈ notes, gathered per kind of guess so a round says each guess once with the cards it applies to.
private struct Notes {
    enum Kind: Int, CaseIterable { case guessedWork, openWork, runningWork, guessedPacket, unanswered }
    private var cards: [Kind: [String]] = [:]

    mutating func add(_ kind: Kind, _ card: String) { cards[kind, default: []].append(card) }

    var lines: [String] {
        Kind.allCases.compactMap { kind in
            cards[kind].map { "\(Self.head(kind)) (\($0.joined(separator: ", "))): \(Self.tail(kind))" }
        }
    }

    private static func head(_ kind: Kind) -> String {
        switch kind {
        case .guessedWork: return "Work turn has no finish line"
        case .openWork, .runningWork: return "Work turn has no finish and nothing after it"
        case .guessedPacket: return "Packet has no start line or never finished"
        case .unanswered: return "Question has no recorded answer"
        }
    }

    private static func tail(_ kind: Kind) -> String {
        switch kind {
        case .guessedWork: return "counted up to the next packet, merge or turn."
        case .openWork: return "left out."
        case .runningWork: return "left out (it may still be running)."
        case .guessedPacket: return "its time runs from the agent's finish or to the next step."
        case .unanswered: return "its wait is left out."
        }
    }
}

/// The action log lines about the round's cards, sorted by kind.
private struct Facts {
    struct CardFacts {
        var sheetRequests: [Date] = []
        var starts: [(time: Date, note: String)] = []
        var finished: [Date] = []
        var packets: [Date] = []
        /// "review packet started for ID" (older logs have only the prepared line).
        var packetStarts: [Date] = []
        var fixes: [Date] = []
        var asked: [Date] = []
        var answered: [Date] = []
        var approved: [Date] = []
        var doneNotices: [Date] = []
    }

    private var byCard: [String: CardFacts] = [:]

    func of(_ id: String) -> CardFacts { byCard[id] ?? CardFacts() }

    init(events: [ActionLogEvent], ids: Set<String>) {
        var byCard: [String: CardFacts] = [:]
        for e in events {
            let w = e.text.split(separator: " ").map(String.init)
            guard w.count >= 2 else { continue }
            func add(_ id: String, _ change: (inout CardFacts) -> Void) {
                guard ids.contains(id) else { return }
                change(&byCard[id, default: CardFacts()])
            }
            switch w[0] {
            case "start-request":
                // "start-request ID sheet cards=N1,N2 started= refused="
                guard w.count >= 4, w[2] == "sheet", w[3].hasPrefix("cards=") else { break }
                for id in w[3].dropFirst(6).split(separator: ",").map(String.init) { add(id) { $0.sheetRequests.append(e.time) } }
            case "start":
                guard w.count >= 3, w[2].hasPrefix("agent=") else { break }
                let note = e.text.firstIndex(of: "(").map { String(e.text[$0...]).trimmingCharacters(in: CharacterSet(charactersIn: "()")) } ?? ""
                add(w[1]) { $0.starts.append((e.time, note.isEmpty ? "" : note.prefix(1).uppercased() + note.dropFirst() + ".")) }
            case "asked": add(w[1]) { $0.asked.append(e.time) }
            case "answered": add(w[1]) { $0.answered.append(e.time) }
            case "approved": add(w[1]) { $0.approved.append(e.time) }
            // "merged ID SHA (script)": merge-task.sh writes no approval line.
            case "merged" where w.count == 4 && w[3] == "(script)": add(w[1]) { $0.approved.append(e.time) }
            case "review":
                if w.count >= 5, w[1] == "packet", w[2] == "prepared" { add(w[4]) { $0.packets.append(e.time) } }
                if w.count >= 5, w[1] == "packet", w[2] == "started" { add(w[4]) { $0.packetStarts.append(e.time) } }
            case "fix":
                if e.text.contains(" sent to "), w[1] == "request", w.count >= 3, w[w.count - 2] == "for", let id = w.last { add(id) { $0.fixes.append(e.time) } }
            case "command":
                // "command to PANE: Panel: N1 finished its work (Report written); N2 is done." — the log cuts long lines, so a cut part is skipped.
                guard let r = e.text.range(of: ": Panel: ") else { break }
                for part in e.text[r.upperBound...].components(separatedBy: "; ") {
                    let p = part.split(separator: " ", maxSplits: 1).map(String.init)
                    guard p.count == 2 else { continue }
                    if p[1].hasPrefix("finished its work") { add(p[0]) { $0.finished.append(e.time) } }
                    else if p[1] == "is done" || p[1] == "is done." { add(p[0]) { $0.doneNotices.append(e.time) } }
                }
            default: break
            }
        }
        self.byCard = byCard
    }
}
