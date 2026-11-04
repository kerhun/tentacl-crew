import Foundation

/// What starting an agent with a role would use: the Claude or Codex flags, the generated settings file (Claude), the instruction text,
/// the other settings that also apply and anything the user should know. It is produced by the real `spawn-agent.sh --print-flags` on a temporary
/// copy of the draft, so the preview cannot drift from what a start really does.
struct LaunchPreview: Equatable {
    /// The program the flags are for: "claude" or "codex".
    var tool = "claude"
    var flags = ""
    /// The output style the generated settings file sets.
    var outputStyle = ""
    var settingsJSON = ""
    var instructions = ""
    var overrides: [String] = []
    var problems: [String] = []

    /// The command line to show. For Codex the shell escapes are taken out (a word with a space is put in single quotes) and the
    /// long `-c developer_instructions=…` value is shortened (the text itself is in `instructions`).
    var command: String {
        guard tool == "codex" else { return "claude " + flags }
        let words = shellWords(flags).map { word -> String in
            let plain = unescaped(word)
            if plain.hasPrefix("developer_instructions=") || plain.hasPrefix("$'developer_instructions=") { return "developer_instructions=<the instructions>" }
            return plain.contains(" ") ? "'" + plain + "'" : plain
        }
        return (["codex"] + words).joined(separator: " ")
    }
}

/// `makeScripts` gets the folder the script may use as its state (settings and instruction files are written there) and returns a runner.
func makePreview(draft: RoleConfig, instructions: String, project: ProjectConfig?, makeScripts: (URL) -> ScriptRunning,
                 catalog: SkillCatalog, claudeHome: URL) async -> LaunchPreview {
    var preview = LaunchPreview()
    let found = RoleValidator.problems(for: draft, knownStyles: OutputStyleCatalog(claudeHome: claudeHome, repo: project?.repoURL).names())
    preview.problems = found.map { "\($0.field): \($0.message)" }
    preview.tool = draft.tool
    let codex = draft.tool == "codex"
    if !codex {   // skills and Claude's own settings do not reach a Codex agent
        let installed = Set(catalog.installed().map(\.name))
        for skill in draft.skills where !installed.contains(skill) { preview.problems.append("skills: \"\(skill)\" is not installed on this machine.") }
        preview.overrides = ClaudeSettingsSummary.lines(claudeHome: claudeHome, repo: project?.repoURL, roleSkills: draft.skills)
    }
    guard !found.contains(where: { $0.severity == .error }) else { return preview }

    let fm = FileManager.default
    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tentacl-preview-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: work) }
    let roleDir = work.appendingPathComponent("role"), state = work.appendingPathComponent("state")
    do {
        try fm.createDirectory(at: roleDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        var config = draft
        config.instructionFile = "\(draft.name).md"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: roleDir.appendingPathComponent("\(draft.name).json"))
        try Data(instructions.utf8).write(to: roleDir.appendingPathComponent("\(draft.name).md"))
        let result = try await makeScripts(state).run(.spawn, arguments: ["--print-flags", roleDir.appendingPathComponent("\(draft.name).json").path, "", project?.sourcePath ?? ""])
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            preview.problems.append(message.isEmpty ? "spawn-agent.sh exited with status \(result.status)" : message)
            return preview
        }
        preview.flags = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let settingsPath = value(after: "--settings", in: preview.flags), let text = try? String(contentsOfFile: settingsPath, encoding: .utf8) { preview.settingsJSON = text
            preview.outputStyle = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["outputStyle"] as? String ?? "" }
        if let instructionPath = value(after: "--append-system-prompt-file", in: preview.flags), let text = try? String(contentsOfFile: instructionPath, encoding: .utf8) { preview.instructions = text }
        // Codex takes the text inline; the script still writes it to <state>/<name>/instructions.md.
        if codex, let text = try? String(contentsOf: state.appendingPathComponent("\(draft.name)/instructions.md"), encoding: .utf8) { preview.instructions = text }
    } catch {
        preview.problems.append("The preview could not be built: \(error.localizedDescription)")
    }
    return preview
}

/// The words of a `%q`-quoted line: split at spaces that are not escaped with a backslash (escapes are kept as they are).
private func shellWords(_ line: String) -> [String] {
    var words: [String] = [], word = "", escaped = false, ansi = false   // ansi: inside $'…' (bash %q uses it for non-ASCII text, e.g. the protocol's "·")
    for c in line {
        if escaped { word.append(c); escaped = false }
        else if c == "\\" { word.append(c); escaped = true }
        else if ansi { word.append(c); if c == "'" { ansi = false } }
        else if c == "'" && word.hasSuffix("$") { word.append(c); ansi = true }
        else if c == " " { if !word.isEmpty { words.append(word); word = "" } }
        else { word.append(c) }
    }
    if !word.isEmpty { words.append(word) }
    return words
}

/// A `%q` word without its backslash escapes.
private func unescaped(_ word: String) -> String {
    var out = "", escaped = false
    for c in word {
        if !escaped && c == "\\" { escaped = true } else { out.append(c); escaped = false }
    }
    return out
}

/// The word after `flag` in the `%q`-quoted flag line (the paths here come from a temporary folder without spaces).
private func value(after flag: String, in line: String) -> String? {
    let words = line.split(separator: " ").map(String.init)
    guard let i = words.firstIndex(of: flag), i + 1 < words.count else { return nil }
    return words[i + 1]
}
