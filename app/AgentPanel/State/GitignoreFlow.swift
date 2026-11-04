import Foundation
import Observation

/// Where `.agent-worktrees/` is ignored (N180): Tentacl needs it ignored somewhere, or every agent worktree shows up as untracked files.
enum IgnoreSource: Equatable {
    case gitignore, exclude, other(String), nowhere
}

/// The project's `.gitignore` as the Git screen shows it.
struct GitignoreInfo: Equatable {
    /// nil when the file does not exist.
    var text: String?
    var agentWorktrees: IgnoreSource
    /// The branch a commit would go to; nil when detached.
    var branch: String?
}

/// Pure helpers for editing the root `.gitignore`.
enum Gitignore {
    static let quickLines = [".agent-worktrees/", ".env", "DerivedData/", "node_modules/"]
    static let defaultMessage = "chore: update .gitignore"

    /// Pattern lines: trimmed, without blanks and comments.
    static func patterns(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Lines in `new` that `old` does not have; negations ("!x") un-ignore, so they are left out.
    static func addedPatterns(old: String, new: String) -> [String] {
        let before = Set(patterns(old))
        var seen = Set<String>()
        return patterns(new).filter { !$0.hasPrefix("!") && !before.contains($0) && seen.insert($0).inserted }
    }

    private static func normalized(_ line: String) -> String {
        var s = line
        if s.hasPrefix("/") { s.removeFirst() }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// True when `text` has `line` (a leading or trailing "/" aside).
    static func contains(_ line: String, in text: String) -> Bool {
        let want = normalized(line)
        return patterns(text).contains { normalized($0) == want }
    }

    static func adding(_ line: String, to text: String) -> String {
        if contains(line, in: text) { return text }
        let base = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return base + line + "\n"
    }

    static func commitMessage(old: String, new: String) -> String {
        let added = addedPatterns(old: old, new: new)
        let removed = Set(patterns(old)).subtracting(patterns(new))
        guard removed.isEmpty, (1...3).contains(added.count) else { return defaultMessage }
        return "chore: ignore \(added.joined(separator: ", ")) in .gitignore"
    }

    /// `git check-ignore -v`: "<source>:<line>:<pattern>\t<path>".
    static func source(checkIgnore output: String) -> IgnoreSource {
        guard let line = output.split(separator: "\n").first, let tab = line.firstIndex(of: "\t") else { return .nowhere }
        let head = line[..<tab]
        let parts = head.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return .nowhere }
        let pattern = parts[2...].joined(separator: ":")
        if pattern.hasPrefix("!") { return .nowhere }
        let file = parts[0..<parts.count - 2].joined(separator: ":")
        if file == ".gitignore" { return .gitignore }
        if file.hasSuffix("info/exclude") { return .exclude }
        return .other(file)
    }

    /// The source with the edited (unsaved) text taken into account.
    static func effectiveSource(text: String, read: IgnoreSource) -> IgnoreSource {
        if contains(".agent-worktrees/", in: text) { return .gitignore }
        return read == .gitignore ? .nowhere : read
    }

    static func agentWorktreesNote(_ source: IgnoreSource) -> String {
        switch source {
        case .gitignore: return ".agent-worktrees/ is ignored in .gitignore."
        case .exclude: return ".agent-worktrees/ is ignored in .git/info/exclude (this Mac only). Tentacl Crew needs it ignored somewhere."
        case .other(let file): return ".agent-worktrees/ is ignored in \(file). Tentacl Crew needs it ignored somewhere."
        case .nowhere: return ".agent-worktrees/ is not ignored anywhere: agent worktrees would show up as untracked files. Add it here."
        }
    }

    static func trackedWarning(_ files: [String]) -> String? {
        guard !files.isEmpty else { return nil }
        let shown = files.prefix(8).joined(separator: ", ") + (files.count > 8 ? " and \(files.count - 8) more" : "")
        let one = files.count == 1
        return "\(files.count) tracked file\(one ? " matches" : "s match") the new lines and stay\(one ? "s" : "") tracked until you remove \(one ? "it" : "them") from git: \(shown)."
    }
}

/// Reads and saves `.gitignore`; git only reads, except `add` and `commit` of `.gitignore` alone when asked.
struct GitignoreTool: Sendable {
    var runner: GitToolRunning
    var git = URL(fileURLWithPath: "/usr/bin/git")

    private func git(_ repo: String, _ args: [String]) async -> ScriptResult { await runner.run(git, ["-C", repo] + args) }

    static func fileURL(_ repoPath: String) -> URL { URL(fileURLWithPath: repoPath).appendingPathComponent(".gitignore") }

    func read(repoPath: String) async -> GitignoreInfo {
        let text = try? String(contentsOf: Self.fileURL(repoPath), encoding: .utf8)
        let check = await git(repoPath, ["check-ignore", "-v", "--no-index", ".agent-worktrees/"])
        let head = await git(repoPath, ["symbolic-ref", "--short", "-q", "HEAD"])
        let branch = head.status == 0 ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return GitignoreInfo(text: text, agentWorktrees: check.status == 0 ? Gitignore.source(checkIgnore: check.stdout) : .nowhere,
                             branch: branch.isEmpty ? nil : branch)
    }

    /// Tracked files that `patterns` match (they stay tracked: ignoring never untracks).
    func trackedMatches(repoPath: String, patterns: [String]) async -> [String] {
        guard !patterns.isEmpty else { return [] }
        let result = await git(repoPath, ["-c", "core.quotePath=false", "ls-files", "--cached", "--ignored"] + patterns.flatMap { ["--exclude=\($0)"] })
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Writes the file, then commits only `.gitignore` when `commitMessage` is set. The error to show, or nil.
    func save(repoPath: String, text: String, commitMessage: String?) async -> String? {
        do { try text.write(to: Self.fileURL(repoPath), atomically: true, encoding: .utf8) }
        catch { return ".gitignore could not be written: \(error.localizedDescription)" }
        guard let commitMessage else { return nil }
        let add = await git(repoPath, ["add", "--", ".gitignore"])
        guard add.status == 0 else { return ".gitignore is saved but not committed: " + GitPublisher.errorText(add, "git add") }
        let commit = await git(repoPath, ["commit", "-m", commitMessage, "--", ".gitignore"])
        return commit.status == 0 ? nil : ".gitignore is saved but not committed: " + GitPublisher.errorText(commit, "git commit")
    }
}

/// The .gitignore sheet (from the Git screen and from Edit project).
@Observable @MainActor
final class GitignoreFlow: Identifiable {
    let id = UUID()
    let repoPath: String
    let projectName: String
    var text = ""
    private(set) var original = ""
    var commit = true
    private(set) var tracked: [String] = []
    private(set) var source: IgnoreSource = .nowhere
    private(set) var branch: String?
    private(set) var loaded = false
    private(set) var saving = false
    private(set) var error: String?
    /// Nil under XCTest unless a test sets one.
    @ObservationIgnored let tool: GitignoreTool?

    init(repoPath: String, projectName: String, tool: GitignoreTool?) {
        self.repoPath = repoPath; self.projectName = projectName; self.tool = tool
    }

    func load() async {
        guard let tool else { return }
        let info = await tool.read(repoPath: repoPath)
        original = info.text ?? ""; text = original; source = info.agentWorktrees; branch = info.branch; loaded = true
    }

    /// Screenshots: a state without reading anything.
    func preview(original: String, text: String, tracked: [String], source: IgnoreSource, branch: String?) {
        self.original = original; self.text = text; self.tracked = tracked; self.source = source; self.branch = branch; loaded = true
    }

    var added: [String] { Gitignore.addedPatterns(old: original, new: text) }
    var changed: Bool { text != original }
    var effectiveSource: IgnoreSource { Gitignore.effectiveSource(text: text, read: source) }
    var commitMessage: String { Gitignore.commitMessage(old: original, new: text) }
    var commitLabel: String { "Commit the change on \(branch ?? "the current branch") (\"\(commitMessage)\")" }

    func has(_ line: String) -> Bool { Gitignore.contains(line, in: text) }
    func add(_ line: String) { text = Gitignore.adding(line, to: text) }

    func findTracked() async {
        guard let tool else { return }
        let patterns = added
        let found = await tool.trackedMatches(repoPath: repoPath, patterns: patterns)
        if patterns == added { tracked = found }
    }

    func save() async -> Bool {
        guard let tool, !saving else { return false }
        saving = true; error = nil
        error = await tool.save(repoPath: repoPath, text: text, commitMessage: commit && branch != nil ? commitMessage : nil)
        saving = false
        // The file is written even when the commit failed; the sheet stays open to show why.
        if error == nil { original = text }
        return error == nil
    }
}
