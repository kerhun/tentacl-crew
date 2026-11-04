import Foundation

/// Everything the PM is told about one question.
struct DecisionRequest: Equatable {
    let projectName: String
    let cardID: String
    /// The card file as read (front matter and sections), cut to a size a decision call can afford.
    let cardText: String
    let agentLabel: String
    let question: AgentQuestion
    /// Earlier decisions on the same card, newest last, one line each.
    let earlier: [String]
}

struct PMReply: Equatable {
    let decision: PMDecision
    let costUSD: Double?
}

/// Everything the PM is told about a reviewer's new Fix notes entry.
struct FixRequest: Equatable {
    let projectName: String
    let cardID: String
    let cardText: String
    /// The new entry in the card's "Fix notes".
    let entry: String
    let earlier: [String]
}

protocol PMDeciding: Sendable {
    func decide(_ request: DecisionRequest) async throws -> PMReply
    /// Whether a reviewer's new Fix notes entry may be passed on to the developer ("answer") or must go to the user ("escalate").
    func decide(_ request: FixRequest) async throws -> PMReply
}

/// The PM's decision prompt and the JSON its answer must match. Pure.
enum PMPrompt {
    static let cardLimit = 12_000

    static let system = """
    You are the project manager (PM) of a small software team run from Tentacl. A team member (an AI agent working on one task card) \
    is waiting for an answer. You decide it in place of the user, or you escalate it to the user. You cannot run tools; decide from what you are given.

    Answer yourself only when the task card (Goal, Scope, Acceptance criteria, Fix notes) and the earlier decisions settle the question.
    Escalate when:
    - it is a product, design or scope decision the card does not settle, or it would deviate from the specification or prototype;
    - it touches anything outside the project: pushing, network access, installing packages, accounts, money, other folders;
    - it deletes or overwrites work, or cannot easily be undone;
    - you hesitate. Set confidence to "low" whenever you are not sure.

    Permission prompts: choose only the one-time "Yes" option, and only for work the task clearly needs inside its own worktree. \
    Never choose "don't ask again". To refuse, escalate.
    Plan approvals: choose the option that keeps manual approval of edits, and only when the plan stays within the card's Scope. Never auto mode. \
    Otherwise escalate.
    Several questions in one call: answer every one, in order, with one option number each in "options"; if you cannot answer all of them, escalate. Never answer only some.
    Plain questions: answer in "text", at most 600 characters, in the language of the question.
    "why" is one short sentence the user will read; quote the card where you can.
    """

    static let schema = """
    {"type":"object","properties":{"verdict":{"type":"string","enum":["answer","escalate"]},"option":{"type":"integer"},"options":{"type":"array","items":{"type":"integer"}},"text":{"type":"string"},\
    "why":{"type":"string"},"confidence":{"type":"string","enum":["high","low"]}},"required":["verdict","why","confidence"],"additionalProperties":false}
    """

    /// The same answer for Codex: its structured output wants every property required, so the optional ones may be null.
    static let codexSchema = """
    {"type":"object","properties":{"verdict":{"type":"string","enum":["answer","escalate"]},"option":{"type":["integer","null"]},"options":{"type":["array","null"],"items":{"type":"integer"}},"text":{"type":["string","null"]},\
    "why":{"type":"string"},"confidence":{"type":"string","enum":["high","low"]}},"required":["verdict","option","options","text","why","confidence"],"additionalProperties":false}
    """

    static let fixSystem = """
    You are the project manager (PM) of a small software team run from Tentacl. A reviewer agent has added a new entry to the "Fix notes" of a task card. \
    The developer agent of that card has not seen it yet. You decide whether the panel passes it on to the developer as it is, or escalates it to the user. \
    You cannot run tools; decide from what you are given.

    Pass it on (verdict "answer") only when every change the entry asks for is inside the card's Scope and Goal, and it does not contradict the Acceptance criteria.
    Escalate when:
    - it asks for something outside the card's Scope (other files, a new feature, a design or product change), or changes what the card was asked to do;
    - it asks for anything outside the project: pushing, network access, installing packages, accounts, money, other folders;
    - it is a question, an opinion or an approval rather than a request for changes, or it is unclear what to change;
    - earlier decisions show the same fix keeps coming back;
    - you hesitate. Set confidence to "low" whenever you are not sure.
    "why" is one short sentence the user will read; quote the card where you can. Leave "option" and "text" out.
    """

    static func fixMessage(for r: FixRequest) -> String {
        var lines: [String] = []
        lines.append("Project: \(r.projectName)")
        lines.append("")
        lines.append("## Task card \(r.cardID)")
        lines.append(r.cardText.count > cardLimit ? String(r.cardText.prefix(cardLimit)) + "\n[card cut here]" : r.cardText)
        lines.append("")
        lines.append("## Earlier decisions on this card")
        lines.append(r.earlier.isEmpty ? "None." : r.earlier.map { "- \($0)" }.joined(separator: "\n"))
        lines.append("")
        lines.append("## The new Fix notes entry")
        lines.append(r.entry.count > 4_000 ? String(r.entry.prefix(4_000)) + "\n[entry cut here]" : r.entry)
        return lines.joined(separator: "\n")
    }

    static func message(for r: DecisionRequest) -> String {
        let q = r.question
        var lines: [String] = []
        lines.append("Project: \(r.projectName)")
        lines.append("")
        lines.append("## Task card \(r.cardID)")
        lines.append(r.cardText.count > cardLimit ? String(r.cardText.prefix(cardLimit)) + "\n[card cut here]" : r.cardText)
        lines.append("")
        lines.append("## Earlier decisions on this card")
        lines.append(r.earlier.isEmpty ? "None." : r.earlier.map { "- \($0)" }.joined(separator: "\n"))
        lines.append("")
        lines.append("## The question")
        lines.append("From: \(r.agentLabel)")
        lines.append("Kind: \(kindName(q.kind))")
        if !q.title.isEmpty { lines.append("Heading: \(q.title)") }
        if !q.context.isEmpty { lines.append("Plan:\n\(q.context)") }
        if let code = q.code { lines.append("Code:\n\(code)") }
        lines.append("Text:\n\(q.text)")
        let options = q.options.filter { !$0.isSpecial }
        if let call = q.call {
            lines.append("This is one call of \(call.items.count) questions. Answer all of them, in order, with one option number each in \"options\" (for example [2, 1, 1]).")
            for (i, item) in call.items.enumerated() {
                lines.append("Question \(i + 1) (\(item.header)): \(item.question)")
                for (n, o) in item.options.enumerated() { lines.append("  \(n + 1). \(o.label)" + (o.description.isEmpty || o.description == o.label ? "" : " — \(o.description)")) }
            }
        } else if !options.isEmpty {
            lines.append("Options (answer with the number in \"option\"):")
            for o in options { lines.append("\(o.number). \(o.label)" + (o.detail.isEmpty || o.detail == o.label ? "" : " — \(o.detail)")) }
        } else {
            lines.append("Answer in \"text\".")
        }
        return lines.joined(separator: "\n")
    }

    private static func kindName(_ kind: AgentQuestion.Kind) -> String {
        switch kind {
        case .choice: "multiple choice question"
        case .freeText: "plain question"
        case .permission: "permission prompt"
        case .plan: "plan approval"
        case .signIn: "sign-in screen"
        }
    }

    /// Reads `claude --print --output-format json` output: the structured answer, or the reason there is none.
    static func parse(_ data: Data) throws -> PMReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PMDecisionError.unreadable }
        if object["is_error"] as? Bool == true {
            throw PMDecisionError.failed((object["result"] as? String) ?? (object["subtype"] as? String) ?? "unknown error")
        }
        guard let structured = object["structured_output"], let json = try? JSONSerialization.data(withJSONObject: structured),
              let decision = try? JSONDecoder().decode(PMDecision.self, from: json) else { throw PMDecisionError.unreadable }
        return PMReply(decision: decision, costUSD: object["total_cost_usd"] as? Double)
    }
}

enum PMDecisionError: Error, LocalizedError, Equatable {
    case notInstalled
    case unreadable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "claude is not installed (or not on PATH)"
        case .unreadable: "the PM's answer could not be read"
        case .failed(let m): "the PM call failed: \(String(m.prefix(200)))"
        }
    }
}

/// Asks the PM with one short `claude --print` call per question: no tools, no saved session, no user settings or MCP servers,
/// a budget cap and a JSON schema the answer must match. It always runs on Claude: no role's `tool` is read here.
struct ClaudePMDecider: PMDeciding {
    let model: String
    let budgetUSD: Double
    let timeout: TimeInterval
    var executable: URL? = nil
    var locate: @Sendable () -> URL? = { ClaudePMDecider.findExecutable() }
    var makeRunner: @Sendable (TimeInterval) -> CommandRunner = { ProcessRunner(timeout: $0, killGrace: 2) }

    func arguments(for request: DecisionRequest) -> [String] { arguments(prompt: PMPrompt.message(for: request), system: PMPrompt.system) }

    func arguments(for request: FixRequest) -> [String] { arguments(prompt: PMPrompt.fixMessage(for: request), system: PMPrompt.fixSystem) }

    func arguments(prompt: String, system: String, schema: String = PMPrompt.schema) -> [String] {
        ["-p", prompt,
         "--system-prompt", system,
         "--output-format", "json",
         "--json-schema", schema,
         "--tools", "",
         "--no-session-persistence",
         "--setting-sources", "",
         "--strict-mcp-config",
         "--model", model,
         "--max-budget-usd", String(format: "%.2f", budgetUSD)]
    }

    func decide(_ request: DecisionRequest) async throws -> PMReply { try await run(arguments(for: request)) }

    func decide(_ request: FixRequest) async throws -> PMReply { try await run(arguments(for: request)) }

    private func run(_ arguments: [String]) async throws -> PMReply { try PMPrompt.parse(try await runRaw(arguments)) }

    func runRaw(_ arguments: [String]) async throws -> Data {
        guard let exe = executable ?? locate() else { throw PMDecisionError.notInstalled }
        do { return try await makeRunner(timeout).run(exe, arguments) }
        catch { throw PMDecisionError.failed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    /// Looks for `claude` on PATH and in the usual install folders (an app started from Finder has a short PATH).
    static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathDirs + ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        return candidates.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// The decider for when Claude is not signed in but Codex is: one `codex exec` per question, read-only, no saved session, no user config
/// or rules; the answer is the last message, written to a file and read as the same JSON. Codex has no per-call budget cap
/// (the daily limit still applies) and no "no tools" switch (the read-only sandbox is the limit).
struct CodexPMDecider: PMDeciding {
    let model: String
    let timeout: TimeInterval
    var executable: URL? = nil
    var locate: @Sendable () -> URL? = { CodexModelCatalog.findExecutable() }
    var makeRunner: @Sendable (TimeInterval) -> CommandRunner = { ProcessRunner(timeout: $0, killGrace: 2) }

    /// `folder` holds the schema and the answer; it is also the working folder, so nothing of a project is read.
    func arguments(prompt: String, schemaFile: URL, outputFile: URL, folder: URL) -> [String] {
        ["exec", "--json", "--output-schema", schemaFile.path, "--ephemeral", "--ignore-user-config", "--ignore-rules",
         "--skip-git-repo-check", "-C", folder.path, "-s", "read-only"]
        + (model.isEmpty ? [] : ["-m", model]) + ["-o", outputFile.path, prompt]
    }

    func decide(_ request: DecisionRequest) async throws -> PMReply { try await run(system: PMPrompt.system, message: PMPrompt.message(for: request)) }

    func decide(_ request: FixRequest) async throws -> PMReply { try await run(system: PMPrompt.fixSystem, message: PMPrompt.fixMessage(for: request)) }

    private func run(system: String, message: String) async throws -> PMReply {
        guard let exe = executable ?? locate() else { throw PMDecisionError.notInstalled }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tentacl-codex-pm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let schemaFile = folder.appendingPathComponent("schema.json"), outputFile = folder.appendingPathComponent("answer.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PMPrompt.codexSchema.write(to: schemaFile, atomically: true, encoding: .utf8)
        } catch { throw PMDecisionError.failed("the temporary files could not be written") }
        do { _ = try await makeRunner(timeout).run(exe, arguments(prompt: system + "\n\n" + message, schemaFile: schemaFile, outputFile: outputFile, folder: folder)) }
        catch { throw PMDecisionError.failed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
        guard let data = try? Data(contentsOf: outputFile), let decision = try? JSONDecoder().decode(PMDecision.self, from: data) else { throw PMDecisionError.unreadable }
        return PMReply(decision: decision, costUSD: nil)
    }
}
