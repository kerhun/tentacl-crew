import Foundation

/// One todo card as the PM sees it when it picks a round.
struct RoundCandidate: Equatable {
    let id: String
    let title: String
    let goal: String
    /// The card's Dependencies section as written (empty when there is none).
    let dependencies: String
    /// The cards named in `dependencies` that are not done yet.
    let unmet: [String]
    let files: [String]
    var priority: CardPriority = .normal
}

struct RoundRequest: Equatable {
    let projectName: String
    /// How many more agents may run now.
    let slots: Int
    let candidates: [RoundCandidate]
    /// The user's one-line instruction for this round (empty when none).
    var note: String = ""
    /// The user's safe point and the 5-hour usage now; the PM picks fewer or smaller cards when they are close.
    var safePoint: SafePoint = SafePoint(percent: nil)
    var usage: PlanUsage?
    /// The Codex 5-hour usage now; nil when no role uses Codex.
    var codexUsage: PlanUsage?
}

struct RoundPick: Codable, Equatable {
    let id: String
    let why: String
}

struct RoundProposal: Codable, Equatable {
    let cards: [RoundPick]
}

struct RoundReply: Equatable {
    let proposal: RoundProposal
    let costUSD: Double?
}

protocol RoundProposing: Sendable {
    func proposeRound(_ request: RoundRequest) async throws -> RoundReply
}

/// The round prompt and the JSON its answer must match. Pure.
enum RoundPrompt {
    static let goalLimit = 600
    static let maxCards = 4

    static let system = """
    You are the project manager (PM) of a small software team run from Tentacl. You pick the next round of task cards to run in parallel. \
    You cannot run tools; decide from what you are given.

    Pick 2 to \(maxCards) cards (fewer only when fewer can run), never more than the free slots you are told. Only pick cards from the list. \
    Prefer cards other work waits for, and cards that are quick to review. Do not pick a card whose dependencies are not done, and do not pick \
    two cards that list the same file or folder. The panel checks all of this again, so a wrong pick is only dropped.
    Each card has a priority set by the user. Prefer high priority cards, then normal; pick a low priority card only when nothing else can run. \
    If the user gives an instruction for this round, it comes first: follow it as long as the cards can run.
    When you are told a safe point (a share of the 5-hour plan limit), cards must finish before it: the closer the usage is to it, the fewer \
    and smaller cards you pick (for example one small card when usage is within 10 points of it, none that need a long run when it is closer). \
    The panel starts nothing at or above the safe point.
    Put the cards in the order they should start. "why" is one short sentence the user will read.
    """

    static let schema = """
    {"type":"object","properties":{"cards":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"why":{"type":"string"}},\
    "required":["id","why"],"additionalProperties":false}}},"required":["cards"],"additionalProperties":false}
    """

    static func message(for r: RoundRequest) -> String {
        var lines = ["Project: \(r.projectName)", "Free slots: \(r.slots)", ""]
        if !r.note.isEmpty { lines += ["The user says: \(r.note)", ""] }
        if let line = r.safePoint.promptLine(r.usage, codex: r.codexUsage) { lines += [line, ""] }
        lines.append("## Todo cards")
        for c in r.candidates {
            lines.append("")
            lines.append("### \(c.id) · \(c.title)")
            lines.append("Goal: " + (c.goal.count > goalLimit ? String(c.goal.prefix(goalLimit)) + " [cut here]" : c.goal))
            let deps = c.dependencies.isEmpty ? "none" : c.dependencies
            lines.append("Dependencies: \(deps)" + (c.unmet.isEmpty ? "" : " (not done: \(c.unmet.joined(separator: ", ")))"))
            lines.append("Priority: \(c.priority.rawValue)")
            lines.append("Files: " + (c.files.isEmpty ? "none listed" : c.files.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    /// Reads `claude --print --output-format json` output: the proposal, or the reason there is none.
    static func parse(_ data: Data) throws -> RoundReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PMDecisionError.unreadable }
        if object["is_error"] as? Bool == true {
            throw PMDecisionError.failed((object["result"] as? String) ?? (object["subtype"] as? String) ?? "unknown error")
        }
        guard let structured = object["structured_output"], let json = try? JSONSerialization.data(withJSONObject: structured),
              let proposal = try? JSONDecoder().decode(RoundProposal.self, from: json) else { throw PMDecisionError.unreadable }
        return RoundReply(proposal: proposal, costUSD: object["total_cost_usd"] as? Double)
    }
}

extension ClaudePMDecider: RoundProposing {
    func arguments(for request: RoundRequest) -> [String] { arguments(prompt: RoundPrompt.message(for: request), system: RoundPrompt.system, schema: RoundPrompt.schema) }

    func proposeRound(_ request: RoundRequest) async throws -> RoundReply {
        try RoundPrompt.parse(try await runRaw(arguments(for: request)))
    }
}
