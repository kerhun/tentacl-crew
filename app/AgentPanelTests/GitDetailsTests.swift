import XCTest
import SwiftUI
@testable import AgentPanel

/// The Git screen's reader (N179): pure parsing of recorded git output, and the read-only commands it runs (a fake git; nothing real).
@MainActor
final class GitDetailsTests: XCTestCase {
    // Recorded from `git log --first-parent --format=%h%x1f%ct%x1f%D%x1f%s` on this repository.
    private static let mergesLog = """
    b963bca\u{1F}1792491618\u{1F}HEAD -> main, tag: stable-119, task/n179\u{1F}feat(git): the app creates the GitHub repository and pushes (N178)
    6818846\u{1F}1792489062\u{1F}tag: stable-118\u{1F}feat(team): role editor as section cards (N174)
    8f32cbd\u{1F}1792488485\u{1F}\u{1F}Merge branch 'task/n167'
    1789541\u{1F}1792466924\u{1F}tag: stable-116, origin/main\u{1F}test(setup): Calls helper behind a lock

    """

    // Recorded from `git worktree list --porcelain`.
    private static let worktrees = """
    worktree /code/ap
    HEAD b963bca6c3d6eab633d8c3e9dbc8f9b9a0eca952
    branch refs/heads/main

    worktree /Users/me/.cache/agent-panel/build/agent-panel/N181
    HEAD 49ea413a5a755ba8e7d3ce863916d91b12f62ad8
    detached
    locked initializing

    worktree /code/ap-stable
    HEAD 8f32cbd7fa09bee07e7a229e2963098ad335c6db
    detached

    worktree /code/ap/.agent-worktrees/task-n173
    HEAD f60ba5e8d7effac21488874a36f01939cd5d0cbe
    branch refs/heads/task/n173

    worktree /code/ap/.agent-worktrees/task-n175
    HEAD 4af861d4eafc3e1af2c0545937d58a5361deff19
    branch refs/heads/task/n175

    """

    // MARK: Parsing

    func testParsesLogWithTagsCardsAndDates() {
        let commits = GitDetails.parseLog(Self.mergesLog)
        XCTAssertEqual(commits.map(\.hash), ["b963bca", "6818846", "8f32cbd", "1789541"])
        XCTAssertEqual(commits[0].tags, ["stable-119"], "only tags; HEAD, branches and remotes are not tags")
        XCTAssertEqual(commits[0].card, "N178")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1792491618))
        XCTAssertEqual(commits[1].card, "N174")
        XCTAssertEqual(commits[2].tags, [])
        XCTAssertEqual(commits[2].card, "N167", "a merge of task/n167 names its card")
        XCTAssertEqual(commits[3].card, nil)
        XCTAssertEqual(commits[3].tag, "stable-116")
        XCTAssertEqual(GitDetails.parseLog(""), [])
        XCTAssertEqual(GitDetails.parseLog("garbage line\n"), [], "a line in another format is skipped")
    }

    func testCardIDFromSubject() {
        XCTAssertEqual(GitDetails.cardID(in: "fix(app): scroll (N143)"), "N143")
        XCTAssertEqual(GitDetails.cardID(in: "G1: create the repo"), "G1")
        XCTAssertEqual(GitDetails.cardID(in: "refactor: HTTP2 and stable-110 tags"), nil, "no card in a word or a tag name")
        XCTAssertEqual(GitDetails.cardID(in: "Merge branch 'task/b3' into main"), "B3")
        XCTAssertEqual(GitDetails.cardID(in: "chore: bump"), nil)
    }

    func testTagsFromDecoration() {
        XCTAssertEqual(GitDetails.tags(fromDecoration: "HEAD -> main, tag: stable-110, tag: v1, origin/main"), ["stable-110", "v1"])
        XCTAssertEqual(GitDetails.tags(fromDecoration: ""), [])
    }

    func testAheadBehind() {
        XCTAssertEqual(GitDetails.parseAheadBehind("2\t5\n")?.behind, 2)
        XCTAssertEqual(GitDetails.parseAheadBehind("2\t5\n")?.ahead, 5)
        XCTAssertNil(GitDetails.parseAheadBehind(""))
        XCTAssertNil(GitDetails.parseAheadBehind("x y"))
    }

    func testWorktreesSplitIntoAgentAndOther() {
        let all = GitDetails.parseWorktrees(Self.worktrees)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all[0].branch, "main")
        XCTAssertNil(all[1].branch, "detached")
        let split = GitDetails.splitWorktrees(all, repoPath: "/code/ap/")
        XCTAssertEqual(split.agent.map(\.branch), ["task/n173", "task/n175"])
        XCTAssertEqual(split.agent.map(\.folder), ["task-n173", "task-n175"])
        XCTAssertEqual(split.other.map(\.path), ["/Users/me/.cache/agent-panel/build/agent-panel/N181", "/code/ap-stable"], "the main folder itself is neither")
    }

    func testIdleTaskBranchesSkipTheOnesARunningAgentHolds() {
        let idle = GitDetails.idleTaskBranches(["task/n173", "task/n175", "task/n177", "feature/x"], busy: ["task/n173"])
        XCTAssertEqual(idle, ["task/n175", "task/n177"])
    }

    func testAgoText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(GitDetails.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(GitDetails.ago(now.addingTimeInterval(-12 * 60), now: now), "12 min ago")
        XCTAssertEqual(GitDetails.ago(now.addingTimeInterval(-3 * 3600), now: now), "3 h ago")
        XCTAssertEqual(GitDetails.ago(now.addingTimeInterval(-50 * 3600), now: now), "2 d ago")
    }

    func testHeaderTexts() {
        var d = GitDetails(branch: "main")
        XCTAssertEqual(d.remoteText, "No remote")
        d.unpushedCount = 319
        XCTAssertEqual(d.noRemoteText, "No remote: 319 commits only on this Mac")
        d.remoteURL = "git@github.com:kerhun/ap.git"; d.upstream = "origin/main"; d.ahead = 3; d.behind = 0
        XCTAssertEqual(d.syncText, "3 ahead of origin/main")
        d.behind = 2
        XCTAssertEqual(d.syncText, "3 ahead, 2 behind origin/main")
        d.ahead = 0; d.behind = 0
        XCTAssertEqual(d.syncText, "Up to date with origin/main")
        d.upstream = nil
        XCTAssertEqual(d.syncText, "No upstream for main")
        let now = Date()
        XCTAssertEqual(d.fetchText(now: now), "Never fetched")
        d.lastFetch = now.addingTimeInterval(-300)
        XCTAssertEqual(d.fetchText(now: now), "Fetched 5 min ago")
    }

    // MARK: Reading (fake git)

    private static let withRemote: @Sendable (String) -> ScriptResult = { line in
        if line.contains("symbolic-ref") { return FakeTools.ok("main\n") }
        if line.contains("remote get-url") { return FakeTools.ok("git@github.com:kerhun/ap.git\n") }
        if line.contains("--symbolic-full-name @{upstream}") { return FakeTools.ok("origin/main\n") }
        if line.contains("--left-right") { return FakeTools.ok("1\t2\n") }
        if line.contains("log -n 20") { return FakeTools.ok("aaa1111\u{1F}1792491618\u{1F}\u{1F}feat: two (N1)\naaa0000\u{1F}1792491000\u{1F}\u{1F}feat: one\n") }
        if line.contains("rev-list --count @{upstream}..HEAD") { return FakeTools.ok("2\n") }
        if line.contains("log --first-parent") { return FakeTools.ok(mergesLog) }
        if line.contains("worktree list") { return FakeTools.ok(worktrees) }
        if line.contains("rev-list --count refs/heads/main..refs/heads/task/n173") { return FakeTools.ok("1\n") }
        if line.contains("rev-list --count refs/heads/main..refs/heads/task/n175") { return FakeTools.ok("4\n") }
        if line.contains("task-n175 --no-optional-locks status --porcelain") { return FakeTools.ok(" M a.swift\n?? b.swift\n") }
        if line.contains("for-each-ref") { return FakeTools.ok("task/n173\ntask/n175\ntask/n177\n") }
        if line.hasSuffix("status --porcelain") { return FakeTools.ok("") }
        if line.contains("--git-path FETCH_HEAD") { return FakeTools.ok(".git/FETCH_HEAD\n") }
        return FakeTools.fail()
    }

    func testReadsEverythingWithReadOnlyCommands() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("gitdetails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let fetched = Date(timeIntervalSince1970: 1_792_400_000)
        FileManager.default.createFile(atPath: repo.appendingPathComponent(".git/FETCH_HEAD").path, contents: Data())
        try FileManager.default.setAttributes([.modificationDate: fetched], ofItemAtPath: repo.appendingPathComponent(".git/FETCH_HEAD").path)

        let tools = FakeTools(); tools.handler = Self.withRemote
        let details = await GitDetailsReader(runner: tools).read(repoPath: repo.path, baseBranch: "main")
        XCTAssertEqual(details.branch, "main")
        XCTAssertEqual(details.remoteURL, "git@github.com:kerhun/ap.git")
        XCTAssertEqual(details.upstream, "origin/main")
        XCTAssertEqual(details.ahead, 2); XCTAssertEqual(details.behind, 1)
        XCTAssertEqual(details.unpushed.map(\.hash), ["aaa1111", "aaa0000"])
        XCTAssertEqual(details.unpushedCount, 2)
        XCTAssertEqual(details.merges.count, 4)
        XCTAssertEqual(details.taskBranches, ["task/n173", "task/n175", "task/n177"])
        XCTAssertEqual(details.uncommitted, 0)
        XCTAssertEqual(details.lastFetch, fetched)
        // The fake recorded paths start with /code/ap, not the temp repo: none counts as an agent worktree there.
        XCTAssertEqual(details.worktrees, [])
        for line in tools.joined {
            for verb in [" push", " fetch", " commit", " checkout", " switch", " reset", " branch -", " worktree add", " worktree remove", " tag "] {
                XCTAssertFalse(line.contains(verb), "read ran a writing command: \(line)")
            }
        }
    }

    func testReadsAgentWorktreesAheadAndDirty() async {
        let tools = FakeTools(); tools.handler = Self.withRemote
        let details = await GitDetailsReader(runner: tools).read(repoPath: "/code/ap", baseBranch: "main")
        XCTAssertEqual(details.worktrees.map(\.branch), ["task/n173", "task/n175"])
        XCTAssertEqual(details.worktrees.map(\.ahead), [1, 4])
        XCTAssertEqual(details.worktrees.map(\.dirty), [0, 2])
        XCTAssertEqual(details.otherWorktrees.count, 2)
        let statuses = tools.joined.filter { $0.contains(" status") }
        XCTAssertEqual(statuses.count, 3, "the project folder and both agent worktrees")
        for line in statuses { XCTAssertTrue(line.contains(" --no-optional-locks status --porcelain"), "status must not take the index lock: \(line)") }
        XCTAssertNil(details.lastFetch, "no FETCH_HEAD under /code/ap")
    }

    func testNoRemoteCountsEveryCommitAsLocal() async {
        let tools = FakeTools()
        tools.handler = { line in
            if line.contains("symbolic-ref") { return FakeTools.ok("main\n") }
            if line.contains("log -n 20") && line.hasSuffix(" HEAD") { return FakeTools.ok("aaa1111\u{1F}1792491618\u{1F}\u{1F}feat: two\n") }
            if line.contains("rev-list --count HEAD") { return FakeTools.ok("319\n") }
            return FakeTools.fail()
        }
        let details = await GitDetailsReader(runner: tools).read(repoPath: "/code/ap", baseBranch: "main")
        XCTAssertNil(details.remoteURL)
        XCTAssertNil(details.upstream)
        XCTAssertEqual(details.unpushedCount, 319)
        XCTAssertEqual(details.unpushed.count, 1)
        XCTAssertFalse(tools.joined.contains { $0.contains("--left-right") }, "no ahead/behind without an upstream")
    }

    func testFetchRunsOnlyGitFetchOrigin() async {
        let tools = FakeTools()
        tools.handler = { $0.contains("fetch") ? FakeTools.fail("fatal: could not read from remote repository") : FakeTools.ok() }
        let error = await GitDetailsReader(runner: tools).fetch(repoPath: "/code/ap")
        XCTAssertEqual(tools.joined, ["/usr/bin/git -C /code/ap fetch origin"])
        XCTAssertEqual(error, "fatal: could not read from remote repository")
        tools.handler = { _ in FakeTools.ok() }
        let ok = await GitDetailsReader(runner: tools).fetch(repoPath: "/code/ap")
        XCTAssertNil(ok)
    }

    // MARK: Screen model

    private func project(_ id: String = "ap") -> ProjectConfig {
        ProjectConfig(id: id, name: id, repoPath: "/code/\(id)", dataDir: "/data/\(id)", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
    }

    func testModelRefreshesAndFetchesThenReadsAgain() async {
        let tools = FakeTools(); tools.handler = { $0.hasSuffix(" fetch origin") ? FakeTools.ok() : Self.withRemote($0) }
        let model = GitScreenModel(reader: GitDetailsReader(runner: tools))
        await model.refresh(project())
        XCTAssertEqual(model.details?.branch, "main")
        XCTAssertEqual(model.projectID, "ap")
        let reads = tools.joined.count
        await model.fetch(project())
        XCTAssertFalse(model.fetching)
        XCTAssertNil(model.fetchError)
        XCTAssertTrue(tools.joined.contains("/usr/bin/git -C /code/ap fetch origin"))
        XCTAssertGreaterThan(tools.joined.count, reads + 1, "read again after the fetch")
    }

    func testModelKeepsFetchErrorAndDropsAnotherProjectsDetails() async {
        let tools = FakeTools()
        tools.handler = { $0.contains(" fetch ") ? FakeTools.fail("no network") : Self.withRemote($0) }
        let model = GitScreenModel(reader: GitDetailsReader(runner: tools))
        await model.refresh(project())
        await model.fetch(project())
        XCTAssertEqual(model.fetchError, "no network")
        model.show(projectID: "other")
        XCTAssertNil(model.details, "another project's details are never shown")
        XCTAssertNil(model.fetchError)
    }

    func testModelWithoutReaderReadsNothing() async {
        let model = GitScreenModel(reader: nil)
        await model.refresh(project())
        XCTAssertNil(model.details)
        XCTAssertFalse(model.loading)
    }

    // MARK: Screenshots

    private static func commit(_ hash: String, _ minutes: Double, _ subject: String, tags: [String] = []) -> GitCommit {
        GitCommit(hash: hash, date: Date().addingTimeInterval(-minutes * 60), subject: subject, tags: tags, card: GitDetails.cardID(in: subject))
    }

    private static let merges = [
        commit("a114b76", 12, "refactor(app): TerminalBackend protocol and BackendError replace the Terminal* protocols (A4)", tags: ["stable-110"]),
        commit("9d9fecc", 20, "fix(codex): 0.163 permission mapping, efforts from the catalog (K1)", tags: ["stable-109"]),
        commit("3202c80", 31, "fix(dashboard): Not now on Push to GitHub ignores new commits (A1)", tags: ["stable-108"]),
        commit("d161412", 46, "feat(plan): project summary from summary.md at the top of the Plan screen (B3)", tags: ["stable-107"]),
    ]

    private func shot(_ details: GitDetails, _ name: String, prepare: (PanelModel) async -> Void = { _ in }) async throws {
        let model = await DemoSupport.makeModel()
        await prepare(model)
        let git = GitScreenModel(reader: nil, details: details, projectID: model.selectedProjectID)
        let view = HStack(spacing: 0) { Rail(screen: .git, onSelect: { _ in }); Divider().overlay(Tok.line); GitView(model: model, git: git) }
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 860)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    func testScreenshotWithRemote() async throws {
        var d = GitDetails(branch: "main", remoteURL: "git@github.com:kerhun/demo.git", upstream: "origin/main", ahead: 2, behind: 1, lastFetch: Date().addingTimeInterval(-8 * 60))
        d.unpushed = [Self.commit("2dc9fcf", 3, "test(setup): Calls helper behind a lock"), Self.commit("a114b76", 12, "refactor(app): TerminalBackend protocol (A4)")]
        d.unpushedCount = 2
        d.merges = Self.merges
        d.worktrees = [GitWorktree(path: "/demo/.agent-worktrees/fix-a5-widget", branch: "fix/a5-widget", ahead: 1, dirty: 0)]
        d.taskBranches = []
        try await shot(d, "git-with-remote")
    }

    /// N209: the merge queue with a merged, a failed, a running and a waiting card, and the last stable tag.
    func testScreenshotMergeQueue() async throws {
        var d = GitDetails(branch: "main", remoteURL: "git@github.com:kerhun/demo.git", upstream: "origin/main", ahead: 0, behind: 0, lastFetch: Date().addingTimeInterval(-8 * 60))
        d.merges = Self.merges
        try await shot(d, "git-merge-queue") { model in
            let q = model.mergeQueue, id = model.selectedProjectID ?? ""
            await q.run(project: id, card: "N207", branch: "task/n207") { .merged(detail: "fc3ded0 stable-110") }
            await q.run(project: id, card: "N208", branch: "task/n208") { .failed("the branch is behind main and rebasing conflicts in: GitView.swift") }
            let running = Task { await q.run(project: id, card: "N209", branch: "task/n209") { try? await Task.sleep(for: .seconds(3)); return .merged(detail: nil) } }
            try? await Task.sleep(for: .milliseconds(50))
            let waiting = Task { await q.run(project: id, card: "N210", branch: "task/n210") { .merged(detail: nil) } }
            try? await Task.sleep(for: .milliseconds(50))
            addTeardownBlock { running.cancel(); waiting.cancel() }
        }
    }

    func testScreenshotWithoutRemote() async throws {
        var d = GitDetails(branch: "main")
        d.unpushed = Self.merges; d.unpushedCount = 319
        d.merges = Self.merges
        d.uncommitted = 2
        try await shot(d, "git-no-remote")
    }

    func testScreenshotManyWorktrees() async throws {
        var d = GitDetails(branch: "main", remoteURL: "https://github.com/kerhun/demo.git", upstream: "origin/main", ahead: 0, behind: 0, lastFetch: Date().addingTimeInterval(-2 * 3600))
        d.merges = Self.merges
        d.worktrees = [
            GitWorktree(path: "/demo/.agent-worktrees/feat-a1-cleanup", branch: "feat/a1-cleanup", ahead: 3, dirty: 0),
            GitWorktree(path: "/demo/.agent-worktrees/docs-a4-open-items", branch: "docs/a4-open-items", ahead: 1, dirty: 0),
            GitWorktree(path: "/demo/.agent-worktrees/fix-a5-widget", branch: "fix/a5-widget", ahead: 2, dirty: 4),
            GitWorktree(path: "/demo/.agent-worktrees/feat-b3-a11y", branch: "feat/b3-a11y", ahead: 1, dirty: 0),
            GitWorktree(path: "/demo/.agent-worktrees/task-n177", branch: "task/n177", ahead: 0, dirty: 0),
            GitWorktree(path: "/demo/.agent-worktrees/task-n181", branch: "task/n181", ahead: 5, dirty: 1),
        ]
        d.taskBranches = ["task/n177", "task/n181", "task/n182"]
        d.otherWorktrees = [GitWorktree(path: "/code/demo-stable", branch: nil)]
        try await shot(d, "git-many-worktrees")
    }

    func testRailHasTheGitScreen() {
        XCTAssertTrue(ShellScreen.railOrder.contains(.git))
        XCTAssertEqual(ShellScreen.git.railTitle, "Git")
        XCTAssertEqual(ShellScreen(stored: "git"), .git)
    }
}
