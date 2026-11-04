import Foundation

/// Runs one command and reports how it ended; never throws, so git's and gh's own error text reaches the sheet.
protocol GitToolRunning: Sendable {
    func run(_ tool: URL, _ arguments: [String]) async -> ScriptResult
}

/// The real runner: stdin empty, both streams collected, a PATH that holds the usual install folders.
struct ProcessToolRunner: GitToolRunning {
    var timeout: TimeInterval = 120

    func run(_ tool: URL, _ arguments: [String]) async -> ScriptResult {
        let timeout = timeout
        return await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["GIT_TERMINAL_PROMPT"] = "0"   // never wait for a password nobody can type
            environment["GH_PROMPT_DISABLED"] = "1"
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return ScriptResult(status: 127, stdout: "", stderr: error.localizedDescription) }
            let group = DispatchGroup()
            var outData = Data(), errData = Data()
            group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()
            group.wait()
            return ScriptResult(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
        }.value
    }
}

/// Creating the GitHub repository and pushing, with `gh` and `git` and the GitHub login already on the Mac (N178). Only the sheet's button
/// starts it: nothing here is reachable from an agent, the PM, Autopilot or a script, and it uses no model tokens. It never force-pushes
/// and only ever pushes the branch the sheet shows.
struct GitPublisher: Sendable {
    enum Visibility: Equatable { case privateRepo, publicRepo }

    /// What the sheet found out before it asks for the click.
    struct Inspection: Equatable {
        var branch: String?
        var remoteURL: String?
        /// The branch has an upstream (a plain push goes there).
        var hasUpstream = false
        /// Newest first, at most `commitListLimit + 1` of them (the extra one is where a push of every listed commit but none of
        /// the older ones would stop).
        var commits: [Commit] = []
        var commitCount = 0
        var tags: [String] = []
        /// The signed-in account; nil when `gh` is missing or not signed in.
        var login: String?
        /// Why nothing can be created or pushed (gh missing, not signed in, no branch); nil when ready.
        var problem: String?
    }

    /// One commit the sheet lists (N269).
    struct Commit: Equatable, Identifiable {
        var sha: String
        var short: String
        var date: Date?
        var subject: String
        var body = ""
        var id: String { sha }
    }

    enum Outcome: Equatable {
        case done(String)
        case failed(String)
    }

    static let commitListLimit = 20
    /// `%x1f` between fields and `%x1e` after each commit: the body may hold newlines.
    static let commitFormat = "--format=%H%x1f%h%x1f%ct%x1f%s%x1f%b%x1e"
    static let tagPrefix = "stable-"
    static let signInProblem = "Not signed in to GitHub. Sign in under Settings › GitHub, then open this again."
    static let missingProblem = "The GitHub CLI (gh) is not installed. Install it under Settings › GitHub, then open this again."

    var runner: GitToolRunning
    var git = URL(fileURLWithPath: "/usr/bin/git")
    /// nil when `gh` was not found.
    var gh: URL?

    // MARK: Pure parts

    /// A GitHub user or organisation name: letters, digits and single dashes, 1 to 39 characters, not starting with a dash.
    static func isValidOwner(_ owner: String) -> Bool {
        owner.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil
    }

    /// A repository name: letters, digits, dots, dashes and underscores, not `.` or `..`.
    static func isValidRepoName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil && name != "." && name != ".."
    }

    static func createArguments(owner: String, name: String, visibility: Visibility, repoPath: String) -> [String] {
        ["repo", "create", "\(owner)/\(name)", visibility == .privateRepo ? "--private" : "--public", "--source", repoPath, "--remote", "origin"]
    }

    /// `git push` of exactly this branch (plus the ticked tags); with `upTo`, only up to that commit (`<sha>:refs/heads/<branch>`), so
    /// the newer ones stay on this Mac. Never a force: no `--force`, no `+` refspec.
    static func pushArguments(repoPath: String, branch: String, setUpstream: Bool, upTo: String? = nil, tags: [String] = []) -> [String] {
        ["-C", repoPath, "push"] + (setUpstream ? ["-u"] : []) + ["origin", upTo.map { "\($0):refs/heads/\(branch)" } ?? branch] + tags.map { "refs/tags/\($0)" }
    }

    /// Lines of `commitFormat`; plain `short subject` lines (no separators) are read too.
    static func parseCommits(_ text: String) -> [Commit] {
        guard text.contains("\u{1F}") else {
            return text.split(separator: "\n").compactMap { line in
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
                guard let short = parts.first else { return nil }
                return Commit(sha: short, short: short, date: nil, subject: parts.count > 1 ? parts[1] : "")
            }
        }
        return text.split(separator: "\u{1E}").compactMap { record in
            let f = record.trimmingCharacters(in: .newlines).split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { return nil }
            return Commit(sha: f[0], short: f[1], date: TimeInterval(f[2]).map { Date(timeIntervalSince1970: $0) }, subject: f[3],
                          body: f[4].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Only a prefix of the branch can be pushed (N269). Rows are newest first and `keep` newest ones stay on this Mac; unticking row
    /// `index` keeps it and every newer one, ticking it pushes it and every older one.
    static func keepAfterToggle(keep: Int, index: Int) -> Int { index >= keep ? index + 1 : index }

    static func createButtonTitle(owner: String, name: String, branch: String) -> String { "Create \(owner)/\(name) and push \(branch)" }

    static func pushButtonTitle(commits: Int, branch: String, hasUpstream: Bool) -> String {
        guard hasUpstream || commits > 0 else { return "Push \(branch) to origin/\(branch)" }
        return "Push \(commits) commit\(commits == 1 ? "" : "s") to origin/\(branch)"
    }

    /// "2 of 3 commits will be pushed; the rest stay on this Mac".
    static func choiceText(pushed: Int, of total: Int) -> String {
        if pushed == total { return total == 1 ? "The commit will be pushed" : "All \(total) commits will be pushed" }
        if pushed == 0 { return "No commit will be pushed; tick one to push it and every older one" }
        return "\(pushed) of \(total) commits will be pushed; the rest stay on this Mac"
    }

    /// The commits the sheet lists: at most 20, then "and N more".
    static func commitList<T>(_ commits: [T], total: Int) -> (shown: [T], more: Int) {
        let shown = Array(commits.prefix(commitListLimit))
        return (shown, max(0, total - shown.count))
    }

    /// "Pushed 3 commits to origin/main", plus "; 1 stays on this Mac" after a partial push.
    static func doneText(commits: Int, branch: String, kept: Int = 0) -> String {
        "Pushed \(commits) commit\(commits == 1 ? "" : "s") to origin/\(branch)" + (kept == 0 ? "" : "; \(kept) stay\(kept == 1 ? "s" : "") on this Mac")
    }

    static func fetchFirstText(behind: Int, branch: String) -> String {
        "Fetch first: origin/\(branch) has \(behind) commit\(behind == 1 ? "" : "s") this branch does not have. Nothing was pushed."
    }

    /// git's or gh's own text, or the status when it printed none.
    static func errorText(_ result: ScriptResult, _ what: String) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "\(what) exited with status \(result.status)." : out
    }

    // MARK: Runs

    private func git(_ repo: String, _ args: [String]) async -> ScriptResult { await runner.run(git, ["-C", repo] + args) }

    /// Read-only: the branch, the remote, what would be pushed, the stable tags and the signed-in account.
    func inspect(repoPath: String) async -> Inspection {
        var found = Inspection()
        if let branch = Self.line(await git(repoPath, ["symbolic-ref", "--short", "-q", "HEAD"])) { found.branch = branch }
        found.remoteURL = Self.line(await git(repoPath, ["remote", "get-url", "origin"]))
        found.hasUpstream = Self.line(await git(repoPath, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])) != nil
        if let branch = found.branch {
            let range: String
            if found.hasUpstream { range = "@{upstream}..HEAD" }
            else if Self.line(await git(repoPath, ["rev-parse", "--verify", "-q", "refs/remotes/origin/\(branch)"])) != nil { range = "refs/remotes/origin/\(branch)..HEAD" }
            else { range = "HEAD" }
            let log = await git(repoPath, ["log", "-n", "\(Self.commitListLimit + 1)", Self.commitFormat, range])
            found.commits = log.status == 0 ? Self.parseCommits(log.stdout) : []
            found.commitCount = Self.line(await git(repoPath, ["rev-list", "--count", range])).flatMap { Int($0) } ?? found.commits.count
        }
        found.tags = Self.lines(await git(repoPath, ["tag", "--list", "\(Self.tagPrefix)*"]))
        guard found.branch != nil else { found.problem = "No branch is checked out (detached HEAD)."; return found }
        guard let gh else { found.problem = Self.missingProblem; return found }
        let status = await runner.run(gh, ["auth", "status"])
        guard status.status == 0 else { found.problem = Self.signInProblem; return found }
        found.login = Self.line(await runner.run(gh, ["api", "user", "--jq", ".login"]))
        return found
    }

    /// Creates the repository (when there is no remote) and pushes `branch`, or with `upTo` only up to that commit (`kept` newer ones
    /// stay). Fetches first and stops when the remote has commits the branch does not.
    func publish(repoPath: String, branch: String, create: (owner: String, name: String, visibility: Visibility)?, hasUpstream: Bool,
                 commits: Int, upTo: String? = nil, kept: Int = 0, tags: [String]) async -> Outcome {
        guard await currentBranch(repoPath) == branch else { return .failed("The checked-out branch is not \(branch) any more. Close this and open it again.") }
        if let create {
            guard let gh else { return .failed(Self.missingProblem) }
            guard Self.isValidOwner(create.owner), Self.isValidRepoName(create.name) else { return .failed("\"\(create.owner)/\(create.name)\" is not a valid repository name.") }
            let made = await runner.run(gh, Self.createArguments(owner: create.owner, name: create.name, visibility: create.visibility, repoPath: repoPath))
            guard made.status == 0 else { return .failed(Self.errorText(made, "gh repo create")) }
        } else {
            let fetch = await git(repoPath, ["fetch", "origin"])
            guard fetch.status == 0 else { return .failed(Self.errorText(fetch, "git fetch")) }
            let behind = await git(repoPath, ["rev-list", "--count", "HEAD..refs/remotes/origin/\(branch)"])
            if behind.status == 0, let n = Int(behind.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
                return .failed(Self.fetchFirstText(behind: n, branch: branch))
            }
        }
        if let upTo {
            let onBranch = await git(repoPath, ["merge-base", "--is-ancestor", upTo, "HEAD"])
            guard onBranch.status == 0 else { return .failed("\(upTo.prefix(7)) is not on \(branch) any more. Close this and open it again.") }
        }
        let setUpstream = create != nil || !hasUpstream
        let push = await runner.run(git, Self.pushArguments(repoPath: repoPath, branch: branch, setUpstream: setUpstream, upTo: upTo, tags: tags))
        guard push.status == 0 else { return .failed(Self.errorText(push, "git push")) }
        // `-u` sets no upstream when the source is a commit rather than the branch.
        if setUpstream, upTo != nil { _ = await git(repoPath, ["branch", "--set-upstream-to=origin/\(branch)", branch]) }
        if let create { return .done("Created \(create.owner)/\(create.name) and pushed \(branch)") }
        return .done(Self.doneText(commits: commits, branch: branch, kept: kept))
    }

    private func currentBranch(_ repo: String) async -> String? { Self.line(await git(repo, ["symbolic-ref", "--short", "-q", "HEAD"])) }

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
