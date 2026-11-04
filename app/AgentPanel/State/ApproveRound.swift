import Foundation

/// "Approve round": every card in review (packet prepared) in one sheet, one approval merges the ticked ones one by one.
/// A round is not recorded anywhere for review (the Round sheet only plans starts), so the sheet lists all cards in review.
/// Each merge is the single-card path: the plan step rebases a card that fell behind and checks the packet head, then the normal approve runs.
enum ApproveRound {
    struct Row: Identifiable, Equatable {
        let card: TaskCard
        let checks: [SheetField]
        var ticked = true
        var id: String { card.id }
    }

    struct Failure: Equatable {
        let id: String
        let message: String
    }

    struct Result: Equatable {
        var merged: [String] = []
        var skipped: [String] = []
        var failure: Failure?
        /// Ticked cards that were not merged, the failed one first.
        var notRun: [String] = []

        var text: String {
            var parts: [String] = []
            if let failure {
                parts.append(merged.isEmpty ? "Nothing was merged." : "Merged: \(merged.joined(separator: ", ")).")
                parts.append("\(failure.id) stopped the round: \(failure.message)")
                parts.append("Not merged: \(([failure.id] + notRun).joined(separator: ", ")).")
            } else {
                parts.append(merged.isEmpty ? "Nothing was approved." : "Approved and merged \(merged.joined(separator: ", ")).")
            }
            if !skipped.isEmpty { parts.append("Skipped \(skipped.joined(separator: ", ")).") }
            return parts.joined(separator: " ")
        }
    }

    /// Cards in review that have a review packet.
    static func candidates(in cards: [TaskCard]) -> [TaskCard] {
        cards.filter { $0.status == .review && !($0.sections["Review packet"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A card after the cards it depends on, otherwise by id.
    static func order(_ cards: [TaskCard]) -> [TaskCard] {
        let known = Set(cards.map(\.id))
        var remaining = cards.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        var done = Set<String>()
        var ordered: [TaskCard] = []
        while !remaining.isEmpty {
            let index = remaining.firstIndex { card in
                DependencyGraph.mentioned(in: card.sections["Dependencies"] ?? "", known: known, except: card.id).allSatisfy { done.contains($0) }
            } ?? 0
            let next = remaining.remove(at: index)
            done.insert(next.id)
            ordered.append(next)
        }
        return ordered
    }

    static func row(_ card: TaskCard, behind: Int?) -> Row {
        let packet = packetSections(from: card.sections["Review packet"] ?? "")
        let analysis = card.kind == "analysis"
        var checks: [SheetField] = []
        if !analysis {
            checks.append(SheetField(label: "Build", value: packet.buildPassed ? "passed" : packet.build.hasPrefix("none") ? "none in this project" : "not passed"))
            checks.append(SheetField(label: "Screenshots", value: packet.screenshotsNotUsed ? "not used" : "\(packet.screenshots.count)"))
            checks.append(SheetField(label: "Files changed", value: packet.filesChanged.map(String.init) ?? "unknown"))
        } else {
            checks.append(SheetField(label: "Analysis", value: "nothing is merged"))
        }
        let notes = (card.sections["Fix notes"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        checks.append(SheetField(label: "PM review", value: notes.isEmpty ? "no open fix notes" : "open fix notes: check the card first"))
        if !analysis {
            let value = behind.map { "\($0) commit\($0 == 1 ? "" : "s"): rebased before its merge" } ?? "up to date"
            checks.append(SheetField(label: "Behind main", value: value))
        }
        return Row(card: card, checks: checks)
    }

    /// Merges the ticked rows one after another through `plan` (rebase, packet head check) and `approve` (nil when merged, else the reason).
    /// Stops at the first failure.
    @MainActor
    static func run(rows: [Row], plan: (TaskCard) async -> Swift.Result<ApprovalPlan, ReviewError>, approve: (ApprovalPlan) async -> String?) async -> Result {
        var result = Result()
        result.skipped = rows.filter { !$0.ticked }.map(\.id)
        let todo = order(rows.filter(\.ticked).map(\.card))
        for (index, card) in todo.enumerated() {
            let failure: String?
            switch await plan(card) {
            case .failure(let error): failure = error.message
            case .success(let approval): failure = await approve(approval)
            }
            if let failure {
                result.failure = Failure(id: card.id, message: failure)
                result.notRun = todo.dropFirst(index + 1).map(\.id)
                return result
            }
            result.merged.append(card.id)
        }
        return result
    }
}
