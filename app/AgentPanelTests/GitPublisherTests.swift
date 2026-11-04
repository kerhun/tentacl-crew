import XCTest
@testable import AgentPanel

/// A fake gh/git: records every command and answers from a handler. Nothing real runs.
final class FakeTools: GitToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var joined: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var handler: @Sendable (String) -> ScriptResult = { _ in ScriptResult(status: 0, stdout: "", stderr: "") }

    func run(_ tool: URL, _ arguments: [String]) async -> ScriptResult {
        let line = ([tool.path] + arguments).joined(separator: " ")
        lock.lock(); recorded.append(line); lock.unlock()
        return handler(line)
    }

    static func ok(_ out: String = "") -> ScriptResult { ScriptResult(status: 0, stdout: out, stderr: "") }
    static func fail(_ err: String = "") -> ScriptResult { ScriptResult(status: 1, stdout: "", stderr: err) }

    /// A repository on `main` with 3 commits and no remote, signed in as kerhun.
    static let noRemote: @Sendable (String) -> ScriptResult = { line in
        if line.contains("symbolic-ref") { return ok("main\n") }
        if line.contains("remote get-url") { return fail("error: No such remote 'origin'") }
        if line.contains("@{upstream}") || line.contains("rev-parse --verify") { return fail() }
        if line.contains("log -n") { return ok("c3 third\nb2 second\na1 first\n") }
        if line.contains("rev-list --count") { return ok("3\n") }
        if line.contains("gh auth status") || line.hasSuffix("auth status") { return ok() }
        if line.contains("api user") { return ok("kerhun\n") }
        return ok()
    }

    static func withRemote(behind: Int) -> @Sendable (String) -> ScriptResult {
        { line in
            if line.contains("symbolic-ref") { return ok("main\n") }
            if line.contains("remote get-url") { return ok("git@github.com:kerhun/np.git\n") }
            if line.contains("@{upstream}") && line.contains("rev-parse") { return ok("origin/main\n") }
            if line.contains("HEAD..refs/remotes") { return ok("\(behind)\n") }
            if line.contains("log -n") { return ok("c3 third\nb2 second\na1 first\n") }
            if line.contains("rev-list --count") { return ok("3\n") }
            if line.hasSuffix("auth status") { return ok() }
            if line.contains("api user") { return ok("kerhun\n") }
            return ok()
        }
    }

    static let signedOut: @Sendable (String) -> ScriptResult = { line in
        line.hasSuffix("auth status") ? fail("You are not logged into any GitHub hosts.") : noRemote(line)
    }
}

final class GitPublisherTests: XCTestCase {
    private let gh = URL(fileURLWithPath: "/fake/gh")
    private func publisher(_ tools: FakeTools, gh: URL? = URL(fileURLWithPath: "/fake/gh")) -> GitPublisher { GitPublisher(runner: tools, gh: gh) }

    // MARK: argument building

    func testCreateArguments() {
        XCTAssertEqual(GitPublisher.createArguments(owner: "kerhun", name: "agent-panel", visibility: .privateRepo, repoPath: "/code/ap"),
                       ["repo", "create", "kerhun/agent-panel", "--private", "--source", "/code/ap", "--remote", "origin"])
        XCTAssertTrue(GitPublisher.createArguments(owner: "o", name: "n", visibility: .publicRepo, repoPath: "/x").contains("--public"))
    }

    func testPushArgumentsNameTheBranchAndNeverForce() {
        let first = GitPublisher.pushArguments(repoPath: "/r", branch: "main", setUpstream: true)
        XCTAssertEqual(first, ["-C", "/r", "push", "-u", "origin", "main"])
        let later = GitPublisher.pushArguments(repoPath: "/r", branch: "main", setUpstream: false, tags: ["stable-1", "stable-2"])
        XCTAssertEqual(later, ["-C", "/r", "push", "origin", "main", "refs/tags/stable-1", "refs/tags/stable-2"])
        for args in [first, later] {
            XCTAssertFalse(args.contains { $0.hasPrefix("--force") || $0 == "-f" || $0.hasPrefix("+") || $0 == "--mirror" || $0 == "--all" })
        }
    }

    func testButtonTexts() {
        XCTAssertEqual(GitPublisher.createButtonTitle(owner: "kerhun", name: "agent-panel", branch: "main"), "Create kerhun/agent-panel and push main")
        XCTAssertEqual(GitPublisher.pushButtonTitle(commits: 3, branch: "main", hasUpstream: true), "Push 3 commits to origin/main")
        XCTAssertEqual(GitPublisher.pushButtonTitle(commits: 1, branch: "main", hasUpstream: true), "Push 1 commit to origin/main")
        XCTAssertEqual(GitPublisher.pushButtonTitle(commits: 9, branch: "dev", hasUpstream: false), "Push 9 commits to origin/dev")
        XCTAssertEqual(GitPublisher.pushButtonTitle(commits: 0, branch: "dev", hasUpstream: false), "Push dev to origin/dev")
        XCTAssertEqual(GitPublisher.doneText(commits: 3, branch: "main"), "Pushed 3 commits to origin/main")
        XCTAssertEqual(GitPublisher.doneText(commits: 2, branch: "main", kept: 1), "Pushed 2 commits to origin/main; 1 stays on this Mac")
        XCTAssertEqual(GitPublisher.doneText(commits: 1, branch: "main", kept: 3), "Pushed 1 commit to origin/main; 3 stay on this Mac")
        XCTAssertEqual(GitPublisher.choiceText(pushed: 3, of: 3), "All 3 commits will be pushed")
        XCTAssertEqual(GitPublisher.choiceText(pushed: 2, of: 5), "2 of 5 commits will be pushed; the rest stay on this Mac")
        XCTAssertEqual(GitPublisher.choiceText(pushed: 0, of: 5), "No commit will be pushed; tick one to push it and every older one")
    }

    // MARK: N269: readable rows, push up to a chosen commit

    func testAPartialPushNamesTheCommitAndTheBranchAndNeverForces() {
        let partial = GitPublisher.pushArguments(repoPath: "/r", branch: "main", setUpstream: false, upTo: "abc123")
        XCTAssertEqual(partial, ["-C", "/r", "push", "origin", "abc123:refs/heads/main"])
        let first = GitPublisher.pushArguments(repoPath: "/r", branch: "dev", setUpstream: true, upTo: "abc123", tags: ["stable-1"])
        XCTAssertEqual(first, ["-C", "/r", "push", "-u", "origin", "abc123:refs/heads/dev", "refs/tags/stable-1"])
        XCTAssertEqual(GitPublisher.pushArguments(repoPath: "/r", branch: "main", setUpstream: false, upTo: nil), ["-C", "/r", "push", "origin", "main"])
        for args in [partial, first] { XCTAssertFalse(args.contains { $0.hasPrefix("--force") || $0 == "-f" || $0.hasPrefix("+") }) }
    }

    func testOnlyAPrefixCanBeChosen() {
        // Rows newest first; `keep` newest stay. Unticking row 1 keeps rows 0 and 1, ticking row 0 again pushes everything.
        XCTAssertEqual(GitPublisher.keepAfterToggle(keep: 0, index: 1), 2)
        XCTAssertEqual(GitPublisher.keepAfterToggle(keep: 2, index: 0), 0)
        XCTAssertEqual(GitPublisher.keepAfterToggle(keep: 2, index: 1), 1, "ticking a kept row ticks every older one")
        XCTAssertEqual(GitPublisher.keepAfterToggle(keep: 2, index: 4), 5, "unticking an older row unticks every newer one")
    }

    func testCommitsAreReadWithTheirBody() {
        let text = "aaaa111\u{1F}aaaa\u{1F}1700000000\u{1F}fix(git): x (N1)\u{1F}line one\nline two\n\u{1E}\nbbbb222\u{1F}bbbb\u{1F}1690000000\u{1F}docs: y\u{1F}\u{1E}\n"
        let commits = GitPublisher.parseCommits(text)
        XCTAssertEqual(commits.map(\.sha), ["aaaa111", "bbbb222"])
        XCTAssertEqual(commits.first?.body, "line one\nline two")
        XCTAssertEqual(commits.first?.date, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(commits.last?.body, "")
        XCTAssertEqual(GitPublisher.parseCommits("c3 third\nb2 second\n").map(\.subject), ["third", "second"], "plain lines still read")
    }

    /// The real git on a temporary repository with a local bare remote: only the chosen commits reach it, never anything newer.
    func testAPartialPushSendsExactlyTheChosenCommitsToABareRemote() async throws {
        let dir = try TempDir()
        let repo = dir.url.appendingPathComponent("repo").path, bare = dir.url.appendingPathComponent("remote.git").path
        try sh(dir.url.path, ["init", "-q", "--bare", "-b", "main", bare])
        try sh(dir.url.path, ["init", "-q", "-b", "main", repo])
        for n in 1...4 { try sh(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "feat: c\(n) (N\(n))"]) }
        try sh(repo, ["remote", "add", "origin", bare])
        let publisher = GitPublisher(runner: ProcessToolRunner(timeout: 30), gh: nil)

        // No upstream yet: push the two oldest; -u alone sets none for a commit, so it is set afterwards.
        var found = await publisher.inspect(repoPath: repo)
        XCTAssertEqual(found.commits.map(\.subject), ["feat: c4 (N4)", "feat: c3 (N3)", "feat: c2 (N2)", "feat: c1 (N1)"])
        XCTAssertFalse(found.hasUpstream)
        let second = found.commits[2].sha
        var out = await publisher.publish(repoPath: repo, branch: "main", create: nil, hasUpstream: false, commits: 2, upTo: second, kept: 2, tags: [])
        XCTAssertEqual(out, .done("Pushed 2 commits to origin/main; 2 stay on this Mac"))
        XCTAssertEqual(try sh(bare, ["rev-parse", "refs/heads/main"]), second)
        XCTAssertEqual(try sh(repo, ["rev-parse", "--abbrev-ref", "main@{upstream}"]), "origin/main")

        // With the upstream: push one more, then the rest with a plain push.
        found = await publisher.inspect(repoPath: repo)
        XCTAssertEqual(found.commitCount, 2); XCTAssertTrue(found.hasUpstream)
        let third = found.commits[1].sha
        out = await publisher.publish(repoPath: repo, branch: "main", create: nil, hasUpstream: true, commits: 1, upTo: third, kept: 1, tags: [])
        XCTAssertEqual(out, .done("Pushed 1 commit to origin/main; 1 stays on this Mac"))
        XCTAssertEqual(try sh(bare, ["rev-parse", "refs/heads/main"]), third)
        XCTAssertEqual(try sh(bare, ["rev-list", "--count", "main"]), "3")
        out = await publisher.publish(repoPath: repo, branch: "main", create: nil, hasUpstream: true, commits: 1, tags: [])
        XCTAssertEqual(out, .done("Pushed 1 commit to origin/main"))
        XCTAssertEqual(try sh(bare, ["rev-parse", "refs/heads/main"]), try sh(repo, ["rev-parse", "HEAD"]))

        // A commit that is not on the branch is refused before anything is pushed.
        let refused = await publisher.publish(repoPath: repo, branch: "main", create: nil, hasUpstream: true, commits: 1, upTo: "0000000000000000000000000000000000000000", kept: 0, tags: [])
        guard case .failed = refused else { return XCTFail("\(refused)") }
    }

    @discardableResult private func sh(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheCommitListIsCutAtTwentyWithAnAndNMore() {
        let commits = (1...21).map { "h\($0) c\($0)" }
        let cut = GitPublisher.commitList(commits, total: 45)
        XCTAssertEqual(cut.shown.count, 20); XCTAssertEqual(cut.more, 25)
        let small = GitPublisher.commitList(["a b", "c d"], total: 2)
        XCTAssertEqual(small.shown.count, 2); XCTAssertEqual(small.more, 0)
    }

    func testNames() {
        XCTAssertTrue(GitPublisher.isValidOwner("my-org")); XCTAssertFalse(GitPublisher.isValidOwner("-x")); XCTAssertFalse(GitPublisher.isValidOwner("a b"))
        XCTAssertTrue(GitPublisher.isValidRepoName("agent-panel.v2")); XCTAssertFalse(GitPublisher.isValidRepoName("a b")); XCTAssertFalse(GitPublisher.isValidRepoName(".."))
    }

    // MARK: running

    func testInspectReadsOnlyAndFindsTheAccount() async {
        let tools = FakeTools(); tools.handler = FakeTools.noRemote
        let found = await publisher(tools).inspect(repoPath: "/r")
        XCTAssertEqual(found.branch, "main"); XCTAssertNil(found.remoteURL); XCTAssertEqual(found.login, "kerhun")
        XCTAssertEqual(found.commitCount, 3); XCTAssertNil(found.problem)
        XCTAssertFalse(tools.joined.contains { $0.contains("push") || $0.contains("repo create") || $0.contains("fetch") })
    }

    func testInspectSaysWhenGhIsMissingOrSignedOut() async {
        let tools = FakeTools(); tools.handler = FakeTools.noRemote
        let missing = await publisher(tools, gh: nil).inspect(repoPath: "/r")
        XCTAssertEqual(missing.problem, GitPublisher.missingProblem)
        let out = FakeTools(); out.handler = FakeTools.signedOut
        let signedOut = await publisher(out).inspect(repoPath: "/r")
        XCTAssertEqual(signedOut.problem, GitPublisher.signInProblem)
    }

    func testPublishFetchesAndStopsWhenTheRemoteHasCommitsWeLack() async {
        let tools = FakeTools(); tools.handler = FakeTools.withRemote(behind: 1)
        let out = await publisher(tools).publish(repoPath: "/r", branch: "main", create: nil, hasUpstream: true, commits: 2, tags: [])
        XCTAssertEqual(out, .failed("Fetch first: origin/main has 1 commit this branch does not have. Nothing was pushed."))
        XCTAssertTrue(tools.joined.contains { $0.contains("fetch origin") })
        XCTAssertFalse(tools.joined.contains { $0.contains(" push") })
    }

    func testPublishPushesAfterAFetchThatIsNotBehind() async {
        let tools = FakeTools(); tools.handler = FakeTools.withRemote(behind: 0)
        let out = await publisher(tools).publish(repoPath: "/r", branch: "main", create: nil, hasUpstream: true, commits: 2, tags: ["stable-3"])
        XCTAssertEqual(out, .done("Pushed 2 commits to origin/main"))
        XCTAssertEqual(tools.joined.last, "/usr/bin/git -C /r push origin main refs/tags/stable-3")
    }

    func testPublishPassesGitsErrorTextOn() async {
        let tools = FakeTools()
        tools.handler = { line in
            if line.contains("symbolic-ref") { return FakeTools.ok("main\n") }
            return line.contains(" push") ? FakeTools.fail("remote: Permission denied") : FakeTools.ok("0\n")
        }
        let out = await publisher(tools).publish(repoPath: "/r", branch: "main", create: nil, hasUpstream: true, commits: 1, tags: [])
        XCTAssertEqual(out, .failed("remote: Permission denied"))
        let created = FakeTools()
        created.handler = { line in
            if line.contains("symbolic-ref") { return FakeTools.ok("main\n") }
            return line.contains("repo create") ? FakeTools.fail("name already exists on this account") : FakeTools.ok()
        }
        let again = await publisher(created).publish(repoPath: "/r", branch: "main", create: ("kerhun", "np", .privateRepo), hasUpstream: false, commits: 1, tags: [])
        XCTAssertEqual(again, .failed("name already exists on this account"))
        XCTAssertFalse(created.joined.contains { $0.contains(" push") }, "no push after a failed create")
    }

    func testPublishRefusesWhenTheBranchChanged() async {
        let tools = FakeTools(); tools.handler = { _ in FakeTools.ok("other\n") }
        let out = await publisher(tools).publish(repoPath: "/r", branch: "main", create: nil, hasUpstream: true, commits: 1, tags: [])
        guard case .failed = out else { return XCTFail("\(out)") }
        XCTAssertEqual(tools.joined.count, 1, "only the branch was read")
    }
}
