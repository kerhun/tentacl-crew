import Foundation

struct TokenUsage: Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
    var isEmpty: Bool { self == TokenUsage() }
}

enum ModelFamily: String, CaseIterable {
    case opus, sonnet, haiku
    static func detect(_ model: String) -> ModelFamily? { allCases.first { model.lowercased().contains($0.rawValue) } }
}

/// Dollars per million tokens for each model family. An estimate: list prices change, so the numbers live here and nowhere else.
enum PriceTable {
    struct Rates { let input: Double, output: Double, cacheWrite: Double, cacheRead: Double }
    /// $ per million tokens of the current models (Claude Opus 5.5, Sonnet 5.5, Haiku 5.5; Anthropic API list prices, 2026-10).
    /// Older models of a family (e.g. Opus 4.x at $5/$25) are priced as the current one: this is an estimate. Cache writes are the
    /// 5-minute rate (1.25 × input).
    static let estimate: [ModelFamily: Rates] = [
        .opus: Rates(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2),
        .sonnet: Rates(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2),
        .haiku: Rates(input: 0.1, output: 0.5, cacheWrite: 0.125, cacheRead: 0.01),
    ]

    static func dollars(_ u: TokenUsage, _ r: Rates) -> Double {
        (Double(u.input) * r.input + Double(u.output) * r.output + Double(u.cacheWrite) * r.cacheWrite + Double(u.cacheRead) * r.cacheRead) / 1_000_000
    }
}

/// The token use of one or more sessions, split by model family.
struct SessionCost: Equatable {
    var byFamily: [ModelFamily: TokenUsage] = [:]
    /// Tokens of a model that is in no family of the table: their price is unknown.
    var unpriced = TokenUsage()
    /// Tokens of Codex sessions: shown as tokens only, never priced (user decision, N149). They are not "unknown".
    var tokensOnly = TokenUsage()
    /// Output tokens per exact model name ("claude-sonnet-5-5"), so a screen can name the model an agent really used.
    var models: [String: Int] = [:]

    /// The model name that wrote the most output.
    var mainModel: String? { models.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key }
    var usage: TokenUsage { byFamily.values.reduce(unpriced + tokensOnly, +) }
    /// Every token came from Codex: there is no dollar figure and none is missing.
    var isTokensOnly: Bool { !tokensOnly.isEmpty && byFamily.isEmpty && unpriced.isEmpty }
    /// The family that produced the most output.
    var model: ModelFamily? { byFamily.max { $0.value.output < $1.value.output }?.key }
    /// Estimated dollars; nil when some tokens have no price, or when all of them are Codex's (tokens only). Codex tokens next to Claude's add nothing.
    var dollars: Double? {
        guard unpriced.isEmpty, !isTokensOnly else { return nil }
        return byFamily.reduce(0) { $0 + PriceTable.dollars($1.value, PriceTable.estimate[$1.key]!) }
    }

    static func + (a: SessionCost, b: SessionCost) -> SessionCost {
        SessionCost(byFamily: a.byFamily.merging(b.byFamily, uniquingKeysWith: +), unpriced: a.unpriced + b.unpriced, tokensOnly: a.tokensOnly + b.tokensOnly,
                    models: a.models.merging(b.models, uniquingKeysWith: +))
    }
}

/// How much of a model's context window a session holds.
struct ContextUse: Equatable {
    let tokens: Int
    let model: String
    var fraction: Double { Double(tokens) / Double(FreshStart.contextWindow(model: model)) }
}

/// Sums the token use in Claude Code session files. Read-only; a file that is missing or cannot be read is "unknown" (nil), never 0.
enum CostReader {
    /// What a file was read as, with the size and time it had then: a session file of a finished task never changes, so it is read once.
    private final class Known: @unchecked Sendable {
        let lock = NSLock()
        var byPath: [String: (size: Int, modified: Date, cost: SessionCost)] = [:]
    }
    private static let known = Known()

    static func read(_ url: URL) -> SessionCost? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? -1, modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        known.lock.lock()
        let seen = known.byPath[url.path]
        known.lock.unlock()
        if let seen, seen.size == size, seen.modified == modified { return seen.cost }
        guard let cost = readFile(url) else { return nil }
        known.lock.lock(); defer { known.lock.unlock() }
        if known.byPath.count > 2000 { known.byPath = [:] }
        known.byPath[url.path] = (size, modified, cost)
        return cost
    }

    private static func readFile(_ url: URL) -> SessionCost? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: url) else { return nil }
        // A reply is written once per content block with the same usage; the last line of a message id counts.
        var byMessage: [String: (String, TokenUsage)] = [:]
        var order: [String] = []
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
            let model = message["model"] as? String ?? ""
            if model == "<synthetic>" { continue }
            let id = message["id"] as? String ?? obj["uuid"] as? String ?? UUID().uuidString
            if byMessage[id] == nil { order.append(id) }
            byMessage[id] = (model, TokenUsage(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                                               cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0, cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0))
        }
        var cost = SessionCost()
        for id in order {
            guard let (model, usage) = byMessage[id] else { continue }
            if !model.isEmpty { cost.models[model, default: 0] += usage.output }
            if let family = ModelFamily.detect(model) { cost.byFamily[family, default: TokenUsage()] = cost.byFamily[family, default: TokenUsage()] + usage }
            else { cost.unpriced = cost.unpriced + usage }
        }
        return cost
    }

    /// The context a Claude session holds now: the last reply's input and cache tokens (what the next turn re-reads). Reads the end of the file only.
    static func contextUse(_ url: URL, tail: Int = 1_000_000) -> ContextUse? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // starts mid-line
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
            let model = message["model"] as? String ?? ""
            if model == "<synthetic>" { continue }
            let tokens = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
            return ContextUse(tokens: tokens, model: model)
        }
        return nil
    }

    /// The tokens of a Codex session file (the last cumulative count); tokens only, no dollars. Nil when the file has no count.
    static func readCodex(_ url: URL) -> SessionCost? {
        guard let usage = CodexSessionReader.usage(url) else { return nil }
        var cost = SessionCost(tokensOnly: usage.tokens)
        if let model = usage.model { cost.models[model] = usage.tokens.output }
        return cost
    }

    /// The cost of a task: every session file in the folder Claude Code made for the task's worktree, except those last written before
    /// `since` (the task's start line in the action log; an older task may have used the same folder name). Nil when no file can be read.
    /// `tool` picks Claude's files or Codex's (`codexRoot`, found by the worktree as `cwd`); nil reads both.
    static func taskCost(projectsRoot: URL, codexRoot: URL? = nil, tool: AgentTool? = nil, worktree: String, since: Date?) -> SessionCost? {
        let claude = tool == .codex ? nil : claudeTaskCost(projectsRoot: projectsRoot, worktree: worktree, since: since)
        let codex = tool == .claude ? nil : codexRoot.flatMap { root -> SessionCost? in
            let costs = CodexSessionReader.sessions(root: root, cwd: worktree).compactMap { url -> SessionCost? in
                if let since, let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m < since { return nil }
                return readCodex(url)
            }
            return costs.isEmpty ? nil : costs.reduce(SessionCost(), +)
        }
        switch (claude, codex) {
        case let (a?, b?): return a + b
        case let (a?, nil): return a
        case let (nil, b): return b
        }
    }

    private static func claudeTaskCost(projectsRoot: URL, worktree: String, since: Date?) -> SessionCost? {
        let folder = TranscriptReader.path(projectsRoot: projectsRoot, cwd: worktree, session: "x").deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let costs = files.filter { $0.pathExtension == "jsonl" }.compactMap { url -> SessionCost? in
            if let since, let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m < since { return nil }
            return read(url)
        }
        return costs.isEmpty ? nil : costs.reduce(SessionCost(), +)
    }
}
