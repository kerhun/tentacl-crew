import Foundation

/// A command the user said may always run in this project ("Always allow in this project"), in the form of Claude's `permissions.allow`.
struct PermissionRule: Codable, Equatable, Identifiable {
    /// `Bash(scripts/app-test.sh:*)`: the command, or the command followed by arguments.
    let pattern: String
    let added: Date
    var id: String { pattern }
}

/// Which permission prompts a saved rule covers, and which it never can. Pure.
enum PermissionRules {
    /// Programs that run whatever they are given: a rule on one of these alone would allow anything.
    private static let runners: Set<String> = ["bash", "sh", "zsh", "env", "xargs", "eval", "exec", "python", "python3", "node", "ruby", "perl", "osascript",
                                               "open", "find", "time", "nohup", "swift", "make", "npx", "npm", "yarn", "pnpm", "git", "gh", "xcrun", "sudo"]
    /// Programs whose first argument is the command to run: the rule keeps both words (`git status`, `bash tests/run.sh`).
    private static let subcommand: Set<String> = ["bash", "sh", "zsh", "git", "swift", "make", "npm", "yarn", "pnpm", "xcrun", "python", "python3", "node", "npx"]
    /// What turns one command into several or into something else.
    private static let compound = [";", "&", "|", "`", "$(", ">", "<", "\n", "\\"]

    /// The command a Bash permission prompt asks about (as the detector read it from the screen); nil for any other kind of prompt.
    static func command(of q: AgentQuestion) -> String? {
        guard q.kind == .permission, !q.terminalOnly, !q.isCall, let command = q.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        return command
    }

    /// The rule a user could save for this prompt; nil when the command is compound, is a runner on its own, or is one of the always-yours.
    static func pattern(for q: AgentQuestion) -> String? {
        guard let command = command(of: q), AutopilotRules.mustEscalate(q) == nil, !compound.contains(where: command.contains) else { return nil }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first, !first.contains("="), !first.hasPrefix("-") else { return nil }
        var prefix = first
        if subcommand.contains(first) {
            guard words.count > 1, !words[1].hasPrefix("-") else { return nil }
            prefix += " " + words[1]
        } else if runners.contains(first) { return nil }
        return "Bash(\(prefix):*)"
    }

    /// Whether the rule covers this prompt: same program and arguments, nothing chained on. The always-yours never match.
    static func matches(_ rule: PermissionRule, _ q: AgentQuestion) -> Bool {
        guard rule.pattern.hasPrefix("Bash("), rule.pattern.hasSuffix(":*)"), let command = command(of: q),
              AutopilotRules.mustEscalate(q) == nil, !compound.contains(where: command.contains) else { return false }
        let prefix = String(rule.pattern.dropFirst("Bash(".count).dropLast(":*)".count))
        guard !prefix.isEmpty else { return false }
        return command == prefix || command.hasPrefix(prefix + " ")
    }

    static func rule(for q: AgentQuestion, in rules: [PermissionRule]) -> PermissionRule? { rules.first { matches($0, q) } }

    /// The one-time "Yes" a rule may press: never "don't ask again", never auto mode.
    static func answer(for q: AgentQuestion) -> QuestionOption? {
        q.options.first { $0.role == .allow && $0.label == "Yes" && !AutopilotRules.forbidden($0, in: .permission) }
    }

    /// What the rule can never cover, for the settings text.
    static let neverCovered = "Anything that reaches outside the task (git push, network, installs, deleting outside the worktree, secrets), several commands chained together, and edits."
}

extension AutopilotStore {
    func rulesURL(_ projectID: String) -> URL? { Self.fileStem(for: projectID).map { folder.appendingPathComponent("\($0).permissions.json") } }

    func loadRules(_ projectID: String) -> [PermissionRule] {
        guard let url = rulesURL(projectID), let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PermissionRule].self, from: data)) ?? []
    }

    func saveRules(_ rules: [PermissionRule], for projectID: String) throws {
        guard let url = rulesURL(projectID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: url, options: .atomic)
    }
}
