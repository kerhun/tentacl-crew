import Foundation
import Observation

/// One commit as the Git screen lists it.
struct GitCommit: Equatable, Identifiable {
    let hash: String
    let date: Date
    let subject: String
    let tags: [String]
    /// The card the subject names ("(N178)", "Merge branch 'task/n167'"); nil when it names none.
    let card: String?
    var id: String { hash }
    /// The stable-N tag a merge got (the first tag when there is no stable one).
    var tag: String? { tags.first { $0.hasPrefix(GitPublisher.tagPrefix) } ?? tags.first }
}

/// A worktree from `git worktree list --porcelain`; `ahead` and `dirty` are read only for agent worktrees.
struct GitWorktree: Equatable, Identifiable {
    let path: String
    /// nil when detached.
    let branch: String?
    var ahead: Int?
    /// Uncommitted files.
    var dirty: Int?
    var id: String { path }
    var folder: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// What the Git screen shows for one project (N179). Read with plain read-only git commands by `GitDetailsReader`; the parsing is pure.
struct GitDetails: Equatable {
    var branch: String?
    var remoteURL: String?
    /// The branch's upstream ("origin/main"); nil when it has none.
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    /// When `git fetch` last ran (FETCH_HEAD's date); nil when never.
    var lastFetch: Date?
    /// Newest first, at most `listLimit`.
    var unpushed: [GitCommit] = []
    var unpushedCount = 0
    /// First-parent commits of the main branch, newest first.
    var merges: [GitCommit] = []
    /// `.agent-worktrees/*`.
    var worktrees: [GitWorktree] = []
    /// Worktrees elsewhere (the stable copy, review builds).
    var otherWorktrees: [GitWorktree] = []
    /// Local `task/*` branches.
    var taskBranches: [String] = []
    /// Uncommitted files in the project folder.
    var uncommitted = 0

    static let listLimit = 20
    static let mergeLimit = 10
    /// `%x1f` (unit separator) between fields: subjects never hold it.
    static let logFormat = "--format=%h%x1f%ct%x1f%D%x1f%s"

    // MARK: Texts

    var remoteText: String { remoteURL ?? "No remote" }
    var noRemoteText: String { "No remote: \(unpushedCount) commit\(unpushedCount == 1 ? "" : "s") only on this Mac" }

    var syncText: String {
        guard let upstream else { return "No upstream for \(branch ?? "this branch")" }
        let a = ahead ?? 0, b = behind ?? 0
        switch (a, b) {
        case (0, 0): return "Up to date with \(upstream)"
        case (_, 0): return "\(a) ahead of \(upstream)"
        case (0, _): return "\(b) behind \(upstream)"
        default: return "\(a) ahead, \(b) behind \(upstream)"
        }
    }

    func fetchText(now: Date = Date()) -> String { lastFetch.map { "Fetched " + Self.ago($0, now: now) } ?? "Never fetched" }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    // MARK: Parsing

    /// Lines of `logFormat`; a line in another shape is skipped.
    static func parseLog(_ text: String) -> [GitCommit] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let seconds = TimeInterval(f[1]) else { return nil }
            return GitCommit(hash: f[0], date: Date(timeIntervalSince1970: seconds), subject: f[3], tags: tags(fromDecoration: f[2]), card: cardID(in: f[3]))
        }
    }

    /// "(N178)" or a whole word like "G1"; else the card of a merged `task/<id>` branch.
    static func cardID(in subject: String) -> String? {
        if let m = subject.range(of: #"\b[A-Z]{1,2}[0-9]{1,4}\b"#, options: .regularExpression),
           subject[..<m.lowerBound].last != "-" { return String(subject[m]) }
        if let m = subject.range(of: #"task/[a-z]{1,2}[0-9]{1,4}\b"#, options: .regularExpression) {
            return String(subject[m].dropFirst("task/".count)).uppercased()
        }
        return nil
    }

    /// `%D`: "HEAD -> main, tag: stable-110, origin/main" → ["stable-110"].
    static func tags(fromDecoration text: String) -> [String] {
        text.components(separatedBy: ", ").compactMap { $0.hasPrefix("tag: ") ? String($0.dropFirst(5)) : nil }
    }

    /// `rev-list --left-right --count @{upstream}...HEAD`: "behind<TAB>ahead".
    static func parseAheadBehind(_ text: String) -> (ahead: Int, behind: Int)? {
        let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    static func parseWorktrees(_ text: String) -> [GitWorktree] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var path: String?, branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
            }
            return path.map { GitWorktree(path: $0, branch: branch) }
        }
    }

    /// Agent worktrees are the ones under `<repo>/.agent-worktrees/`; the project folder itself is neither list.
    static func splitWorktrees(_ all: [GitWorktree], repoPath: String) -> (agent: [GitWorktree], other: [GitWorktree]) {
        let repo = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        let root = repo + "/.agent-worktrees/"
        let rest = all.filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path != repo }
        return (rest.filter { $0.path.hasPrefix(root) }, rest.filter { !$0.path.hasPrefix(root) })
    }

    /// `task/*` branches no running agent holds (left to clean up; nothing here deletes them).
    static func idleTaskBranches(_ branches: [String], busy: Set<String>) -> [String] {
        branches.filter { $0.hasPrefix("task/") && !busy.contains($0) }
    }
}

/// Reads `GitDetails` with read-only git commands (no fetch, no checkout, nothing written); `fetch` is the one command that talks to the
/// remote, and it never touches the work tree.
struct GitDetailsReader: Sendable {
    var runner: GitToolRunning
    var git = URL(fileURLWithPath: "/usr/bin/git")

    /// `status` refreshes the index and takes its lock unless told not to; an agent committing in that worktree at the same moment
    /// would then fail on index.lock.
    static let statusArguments = ["--no-optional-locks", "status", "--porcelain"]

    private func git(_ repo: String, _ args: [String]) async -> ScriptResult { await runner.run(git, ["-C", repo] + args) }

    func read(repoPath: String, baseBranch: String) async -> GitDetails {
        var d = GitDetails()
        d.branch = Self.line(await git(repoPath, ["symbolic-ref", "--short", "-q", "HEAD"]))
        d.remoteURL = Self.line(await git(repoPath, ["remote", "get-url", "origin"]))
        d.upstream = Self.line(await git(repoPath, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]))
        if d.upstream != nil, let counts = Self.line(await git(repoPath, ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"])).flatMap(GitDetails.parseAheadBehind) {
            d.ahead = counts.ahead; d.behind = counts.behind
        }
        // What is not pushed: past the upstream, else past origin/<branch>, else everything (no remote yet).
        if let branch = d.branch {
            let range: String
            if d.upstream != nil { range = "@{upstream}..HEAD" }
            else if Self.line(await git(repoPath, ["rev-parse", "--verify", "-q", "refs/remotes/origin/\(branch)"])) != nil { range = "refs/remotes/origin/\(branch)..HEAD" }
            else { range = "HEAD" }
            d.unpushed = GitDetails.parseLog(Self.text(await git(repoPath, ["log", "-n", "\(GitDetails.listLimit)", GitDetails.logFormat, range])))
            d.unpushedCount = Self.line(await git(repoPath, ["rev-list", "--count", range])).flatMap { Int($0) } ?? d.unpushed.count
        }
        d.merges = GitDetails.parseLog(Self.text(await git(repoPath, ["log", "--first-parent", "-n", "\(GitDetails.mergeLimit)", GitDetails.logFormat, "refs/heads/\(baseBranch)"])))
        let split = GitDetails.splitWorktrees(GitDetails.parseWorktrees(Self.text(await git(repoPath, ["worktree", "list", "--porcelain"]))), repoPath: repoPath)
        d.otherWorktrees = split.other
        for var tree in split.agent {
            if let branch = tree.branch {
                tree.ahead = Self.line(await git(repoPath, ["rev-list", "--count", "refs/heads/\(baseBranch)..refs/heads/\(branch)"])).flatMap { Int($0) }
            }
            let status = await git(tree.path, Self.statusArguments)
            tree.dirty = status.status == 0 ? Self.lines(status).count : nil
            d.worktrees.append(tree)
        }
        d.taskBranches = Self.lines(await git(repoPath, ["for-each-ref", "--format=%(refname:short)", "refs/heads/task/"]))
        d.uncommitted = Self.lines(await git(repoPath, Self.statusArguments)).count
        if let path = Self.line(await git(repoPath, ["rev-parse", "--git-path", "FETCH_HEAD"])) {
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: repoPath).appendingPathComponent(path)
            d.lastFetch = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return d
    }

    /// `git fetch origin`: updates the remote branches only. git's own error text, or nil when it worked.
    func fetch(repoPath: String) async -> String? {
        let result = await git(repoPath, ["fetch", "origin"])
        return result.status == 0 ? nil : GitPublisher.errorText(result, "git fetch")
    }

    private static func text(_ result: ScriptResult) -> String { result.status == 0 ? result.stdout : "" }

    private static func line(_ result: ScriptResult) -> String? {
        guard result.status == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func lines(_ result: ScriptResult) -> [String] {
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One file's diff as the Changes tab shows it (N204): the parsed diff, git's own text for Copy, and the file at the branch (for the
/// unchanged lines between hunks); `error` is git's text when the read failed.
struct TaskFileDiff: Equatable {
    var diff: FileDiff?
    var raw = ""
    var newText: String?
    var error: String?
}

/// Reads a task branch's change against the merge base with the main branch (`git diff main...task/nX`), read-only and off the main thread.
struct TaskDiffReader: Sendable {
    var runner: GitToolRunning
    var git = URL(fileURLWithPath: "/usr/bin/git")
    let repoPath: String
    let base: String
    let branch: String

    var range: String { "\(base)...\(branch)" }
    /// Plain output whatever the user's git config says: no colour, no external diff tool, paths unquoted.
    private var diffArgs: [String] { ["-C", repoPath, "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "-M"] }

    func files() async -> Result<[DiffFileEntry], GitReadError> {
        let r = await runner.run(git, diffArgs + ["--name-status", "-z", range])
        guard r.status == 0 else { return .failure(GitReadError(text: GitPublisher.errorText(r, "git diff"))) }
        return .success(DiffFileEntry.parseNameStatus(r.stdout))
    }

    func diff(_ entry: DiffFileEntry) async -> TaskFileDiff {
        let r = await runner.run(git, diffArgs + [range, "--"] + [entry.oldPath, entry.path].compactMap { $0 })
        guard r.status == 0 else { return TaskFileDiff(error: GitPublisher.errorText(r, "git diff")) }
        var out = TaskFileDiff(diff: FileDiff.parse(r.stdout).first, raw: r.stdout)
        if let d = out.diff, !d.binary, d.kind != .added, d.kind != .deleted, !d.hunks.isEmpty {
            let show = await runner.run(git, ["-C", repoPath, "show", "\(branch):\(entry.path)"])
            if show.status == 0 { out.newText = show.stdout }
        }
        return out
    }
}

struct GitReadError: Error, Equatable { let text: String }

/// The Git screen's state: the selected project's details, read when the screen opens, after a Fetch and after merges or a push.
@Observable @MainActor
final class GitScreenModel {
    private(set) var details: GitDetails?
    /// The project `details` belong to.
    private(set) var projectID: String?
    private(set) var loading = false
    private(set) var fetching = false
    private(set) var fetchError: String?
    /// Nil under XCTest unless a test sets one, so no test reads a real repository.
    @ObservationIgnored var reader: GitDetailsReader?

    init(reader: GitDetailsReader?, details: GitDetails? = nil, projectID: String? = nil) {
        self.reader = reader; self.details = details; self.projectID = projectID
    }

    /// Forgets another project's details at once, so they are never shown under this one.
    func show(projectID id: String?) {
        guard id != projectID else { return }
        projectID = id; details = nil; fetchError = nil
    }

    func refresh(_ project: ProjectConfig) async {
        show(projectID: project.id)
        guard let reader else { return }
        loading = true
        let found = await reader.read(repoPath: project.repoPath, baseBranch: project.baseBranch)
        loading = false
        if projectID == project.id { details = found }
    }

    func fetch(_ project: ProjectConfig) async {
        guard let reader, !fetching else { return }
        fetching = true; fetchError = nil
        let error = await reader.fetch(repoPath: project.repoPath)
        fetching = false
        guard projectID == project.id else { return }
        fetchError = error
        await refresh(project)
    }
}
