import Foundation
import Observation

/// "Copy my Claude rules to Codex…" (N367, N363 Decision 4): a Codex PM does not read `~/.claude/CLAUDE.md`, so the panel offers to put
/// the user's own Claude rules into `~/.codex/AGENTS.md`. The block sits between two marker comments, so a later copy replaces it and
/// never adds a second one. Nothing is written without `add()`.
struct CodexRules: Sendable {
    static let begin = "<!-- tentacl: Claude rules (from ~/.claude/CLAUDE.md) begin -->"
    static let end = "<!-- tentacl: Claude rules end -->"

    let claudeFile: URL
    let agentsFile: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        claudeFile = home.appendingPathComponent(".claude/CLAUDE.md")
        agentsFile = home.appendingPathComponent(".codex/AGENTS.md")
    }

    /// The user-level rules: the text of `~/.claude/CLAUDE.md` (trimmed); nil when the file is missing or empty.
    var claudeRules: String? {
        guard let text = try? String(contentsOf: claudeFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Exactly what goes into AGENTS.md: the rules between the two markers; nil when there are no rules.
    var block: String? { claudeRules.map { "\(Self.begin)\n\($0)\n\(Self.end)\n" } }

    private var agentsText: String? { try? String(contentsOf: agentsFile, encoding: .utf8) }

    /// The marked block already in AGENTS.md (markers included), if any.
    static func markedRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return nil }
        var upper = stop.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return start.lowerBound..<upper
    }

    /// AGENTS.md has a marked block already (Add replaces it).
    var hasBlock: Bool { agentsText.flatMap { Self.markedRange(in: $0) } != nil }

    /// The rules exist and AGENTS.md does not hold them as they are now: the panel offers the copy.
    var needsOffer: Bool {
        guard let block else { return false }
        guard let text = agentsText, let range = Self.markedRange(in: text) else { return true }
        return String(text[range]) != block
    }

    /// AGENTS.md after Add: the old marked block replaced, else the block appended after one blank line.
    func merged(into existing: String?, block: String) -> String {
        guard let existing, !existing.isEmpty else { return block }
        if let range = Self.markedRange(in: existing) { return existing.replacingCharacters(in: range, with: block) }
        let base = existing.hasSuffix("\n") ? existing : existing + "\n"
        return base + "\n" + block
    }

    enum WriteError: Error, Equatable { case noRules, failed(String) }

    /// Writes AGENTS.md (creating `~/.codex` when needed). Only called from the sheet's Add button.
    func add() throws {
        guard let block else { throw WriteError.noRules }
        let target = agentsFile.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try merged(into: agentsText, block: block).write(to: target, atomically: true, encoding: .utf8)
        } catch { throw WriteError.failed(error.localizedDescription) }
    }
}

/// The sheet's state: the preview, then Add or Cancel.
@Observable @MainActor
final class CodexRulesFlow: Identifiable {
    enum Phase: Equatable { case confirming, added, failed(String) }
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    let rules: CodexRules
    /// What Add writes, shown in full.
    let preview: String
    /// AGENTS.md already has a marked block: Add replaces it.
    let replaces: Bool
    private(set) var phase: Phase = .confirming

    /// nil when there is nothing to copy (no `~/.claude/CLAUDE.md`).
    init?(rules: CodexRules) {
        guard let block = rules.block else { return nil }
        self.rules = rules; preview = block; replaces = rules.hasBlock
    }

    var agentsPath: String { (rules.agentsFile.path as NSString).abbreviatingWithTildeInPath }

    func add() {
        do { try rules.add(); phase = .added }
        catch CodexRules.WriteError.failed(let why) { phase = .failed("Could not write \(agentsPath): \(why)") }
        catch { phase = .failed("There are no rules in ~/.claude/CLAUDE.md to copy.") }
    }
}
