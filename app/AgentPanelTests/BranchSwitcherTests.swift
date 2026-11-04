import XCTest
import SwiftUI
@testable import AgentPanel

/// The Git screen's branch menu (N180): the pure switch rules and name check, and the git commands the switcher runs (a fake git).
@MainActor
final class BranchSwitcherTests: XCTestCase {
    private func state(current: String? = "main", local: [String] = ["main", "feature/x", "task/n151"], held: [String: Bool] = ["task/n151": true],
                       uncommitted: Int = 0, merge: Bool = false) -> BranchState {
        BranchState(current: current, local: local, heldElsewhere: held, uncommitted: uncommitted, mergeInProgress: merge)
    }

    // MARK: Name check

    func testNameCheckFollowsGitRules() {
        for good in ["feature/git-screen", "fix-1", "release/2.0", "a", "user/topic_x"] {
            XCTAssertNil(BranchSwitcher.nameProblem(good), good)
        }
        for bad in ["", " ", "has space", "-x", "/x", "x/", "a//b", "a..b", "a.lock", "a/b.lock/c", ".hidden", "a/.b", "x.", "a~b", "a^b", "a:b",
                    "a?b", "a*b", "a[b", "a\\b", "a@{b", "@", "HEAD", "tab\there", String(repeating: "x", count: 101)] {
            XCTAssertNotNil(BranchSwitcher.nameProblem(bad), "should refuse \(bad.debugDescription)")
        }
        XCTAssertEqual(BranchSwitcher.nameProblem("has space"), "A branch name cannot hold spaces.")
        XCTAssertEqual(BranchSwitcher.nameProblem("a..b"), "A branch name cannot hold \"..\".")
    }

    func testCreateOfferOnlyForANewValidName() {
        let s = state()
        XCTAssertEqual(BranchSwitcher.createOffer("  feature/git-screen ", state: s), "feature/git-screen")
        XCTAssertNil(BranchSwitcher.createOffer("", state: s))
        XCTAssertNil(BranchSwitcher.createOffer("feature/x", state: s), "exists already")
        XCTAssertNil(BranchSwitcher.createOffer("bad name", state: s))
    }

    // MARK: Rows

    func testRowsPutMainFirstTickTheCurrentAndHoldAgentBranches() {
        let s = state(current: "feature/x", local: ["feature/x", "main", "other", "task/n151"], held: ["task/n151": true, "other": false])
        let rows = BranchSwitcher.rows(s, main: "main")
        XCTAssertEqual(rows.map(\.name), ["main", "feature/x", "other", "task/n151"])
        XCTAssertEqual(rows[0].note, "merges go here")
        XCTAssertFalse(rows[0].current)
        XCTAssertTrue(rows[0].selectable)
        XCTAssertTrue(rows[1].current)
        XCTAssertFalse(rows[1].selectable, "the current branch is not switched to again")
        XCTAssertEqual(rows[2].note, "in another worktree")
        XCTAssertFalse(rows[2].selectable)
        XCTAssertEqual(rows[3].note, "in an agent worktree")
        XCTAssertFalse(rows[3].selectable)
    }

    func testFilterMatchesAnyPartIgnoringCase() {
        let rows = BranchSwitcher.rows(state(), main: "main")
        XCTAssertEqual(BranchSwitcher.matching(rows, query: "N15").map(\.name), ["task/n151"])
        XCTAssertEqual(BranchSwitcher.matching(rows, query: " ").count, 3)
    }

    // MARK: Switch rules

    func testSwitchIsRefusedWithTheReason() {
        XCTAssertNil(BranchSwitcher.switchProblem(to: "feature/x", state: state(), mergeRunning: false))
        XCTAssertEqual(BranchSwitcher.switchProblem(to: "feature/x", state: state(uncommitted: 2), mergeRunning: false),
                       "The project folder has 2 uncommitted files. Commit them first; a switch never stashes.")
        XCTAssertEqual(BranchSwitcher.switchProblem(to: "feature/x", state: state(uncommitted: 1), mergeRunning: false),
                       "The project folder has 1 uncommitted file. Commit it first; a switch never stashes.")
        XCTAssertEqual(BranchSwitcher.switchProblem(to: "feature/x", state: state(), mergeRunning: true),
                       "A merge is running. Switch when it is done.")
        XCTAssertEqual(BranchSwitcher.switchProblem(to: "feature/x", state: state(merge: true), mergeRunning: false),
                       "A merge, rebase or cherry-pick is in progress in the project folder. Finish or abort it first.")
        XCTAssertEqual(BranchSwitcher.switchProblem(to: "task/n151", state: state(), mergeRunning: false), "task/n151 is checked out in an agent worktree.")
        XCTAssertEqual(BranchSwitcher.switchProblem(to: "main", state: state(), mergeRunning: false), "The folder is already on main.")
        XCTAssertEqual(BranchSwitcher.switchProblem(to: "gone", state: state(), mergeRunning: false), "There is no local branch gone.")
    }

    func testCreateIsRefusedLikeASwitch() {
        XCTAssertNil(BranchSwitcher.createProblem("feature/new", state: state(), mergeRunning: false))
        XCTAssertNotNil(BranchSwitcher.createProblem("feature/new", state: state(uncommitted: 3), mergeRunning: false))
        XCTAssertEqual(BranchSwitcher.createProblem("feature/x", state: state(), mergeRunning: false), "feature/x exists already.")
        XCTAssertEqual(BranchSwitcher.createProblem("a b", state: state(), mergeRunning: false), "A branch name cannot hold spaces.")
    }

    func testAwayNoteOnlyOffTheMainBranch() {
        XCTAssertNil(BranchSwitcher.awayNote(current: "main", main: "main"))
        XCTAssertEqual(BranchSwitcher.awayNote(current: "feature/x", main: "main"),
                       "Agents keep working in their own worktrees. While this folder is on another branch, merges wait until you switch back to main.")
        XCTAssertNotNil(BranchSwitcher.awayNote(current: nil, main: "main"), "detached HEAD is off the main branch too")
        XCTAssertTrue(BranchSwitcher.menuNote(main: "trunk").contains("switch back to trunk. Uncommitted changes block a switch."))
    }

    // MARK: Commands

    nonisolated private static let repo: @Sendable (String) -> ScriptResult = { line in
        if line.contains("symbolic-ref") { return FakeTools.ok("main\n") }
        if line.contains("for-each-ref") { return FakeTools.ok("feature/x\nmain\ntask/n151\n") }
        if line.contains("worktree list") {
            return FakeTools.ok("worktree /code/ap\nbranch refs/heads/main\n\nworktree /code/ap/.agent-worktrees/task-n151\nbranch refs/heads/task/n151\n\n")
        }
        if line.contains("--verify") { return FakeTools.fail() }
        return FakeTools.ok()
    }

    func testReadsBranchesWorktreesAndState() async {
        let tools = FakeTools(); tools.handler = Self.repo
        let s = await BranchSwitchRunner(runner: tools).read(repoPath: "/code/ap")
        XCTAssertEqual(s, BranchState(current: "main", local: ["feature/x", "main", "task/n151"], heldElsewhere: ["task/n151": true], uncommitted: 0, mergeInProgress: false))
        XCTAssertTrue(tools.joined.contains("/usr/bin/git -C /code/ap --no-optional-locks status --porcelain"))
        for line in tools.joined { XCTAssertFalse(line.contains(" stash") || line.contains("branch -d") || line.contains("branch -D"), line) }
    }

    func testMergeHeadMarksAMergeInProgress() async {
        let tools = FakeTools()
        tools.handler = { line in line.contains("--verify -q MERGE_HEAD") ? FakeTools.ok("abc\n") : Self.repo(line) }
        let s = await BranchSwitchRunner(runner: tools).read(repoPath: "/code/ap")
        XCTAssertTrue(s.mergeInProgress)
    }

    func testSwitchRunsGitSwitchAfterCheckingAgain() async {
        let tools = FakeTools(); tools.handler = Self.repo
        let error = await BranchSwitchRunner(runner: tools).switchTo("feature/x", repoPath: "/code/ap", mergeRunning: false)
        XCTAssertNil(error)
        XCTAssertEqual(tools.joined.last, "/usr/bin/git -C /code/ap switch feature/x")
        for line in tools.joined { XCTAssertFalse(line.contains(" stash") || line.contains("branch -d") || line.contains("branch -D"), line) }
    }

    func testSwitchRefusedWhenTheFolderIsDirtyNow() async {
        let tools = FakeTools()
        tools.handler = { line in line.contains("status --porcelain") ? FakeTools.ok(" M a.swift\n") : Self.repo(line) }
        let error = await BranchSwitchRunner(runner: tools).switchTo("feature/x", repoPath: "/code/ap", mergeRunning: false)
        XCTAssertEqual(error, "The project folder has 1 uncommitted file. Commit it first; a switch never stashes.")
        XCTAssertFalse(tools.joined.contains { $0.contains(" switch ") }, "nothing switched")
    }

    func testCreateRunsSwitchDashC() async {
        let tools = FakeTools(); tools.handler = Self.repo
        let error = await BranchSwitchRunner(runner: tools).create("feature/git-screen", repoPath: "/code/ap", mergeRunning: false)
        XCTAssertNil(error)
        XCTAssertEqual(tools.joined.last, "/usr/bin/git -C /code/ap switch -c feature/git-screen")
        let bad = await BranchSwitchRunner(runner: tools).create("-f", repoPath: "/code/ap", mergeRunning: false)
        XCTAssertNotNil(bad)
        XCTAssertFalse(tools.joined.contains { $0.hasSuffix("switch -c -f") })
    }

    func testGitErrorIsShown() async {
        let tools = FakeTools()
        tools.handler = { line in line.hasSuffix("switch feature/x") ? FakeTools.fail("error: Your local changes would be overwritten") : Self.repo(line) }
        let error = await BranchSwitchRunner(runner: tools).switchTo("feature/x", repoPath: "/code/ap", mergeRunning: false)
        XCTAssertEqual(error, "error: Your local changes would be overwritten")
    }

    func testRealRepositorySwitchAndCreate() async throws {
        let dir = try TempDir()
        let repo = dir.url.path
        let git = { (args: [String]) in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"])
        try dir.write("a.txt", "a\n")
        try git(["add", "a.txt"])
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "first"])
        let runner = BranchSwitchRunner(runner: ProcessToolRunner(timeout: 20))
        let created = await runner.create("feature/one", repoPath: repo, mergeRunning: false)
        XCTAssertNil(created)
        var s = await runner.read(repoPath: repo)
        XCTAssertEqual(s.current, "feature/one")
        XCTAssertEqual(s.local, ["feature/one", "main"])
        try dir.write("a.txt", "changed\n")
        let refused = await runner.switchTo("main", repoPath: repo, mergeRunning: false)
        XCTAssertEqual(refused, "The project folder has 1 uncommitted file. Commit it first; a switch never stashes.")
        try git(["checkout", "--", "a.txt"])
        let back = await runner.switchTo("main", repoPath: repo, mergeRunning: false)
        XCTAssertNil(back)
        s = await runner.read(repoPath: repo)
        XCTAssertEqual(s.current, "main")
        XCTAssertEqual(s.local, ["feature/one", "main"], "no branch is deleted")
    }

    // MARK: Menu model

    func testMenuModelSwitchesAndCallsBack() async {
        let tools = FakeTools(); tools.handler = Self.repo
        let menu = BranchMenuModel(runner: BranchSwitchRunner(runner: tools))
        await menu.load(repoPath: "/code/ap")
        XCTAssertEqual(menu.state?.current, "main")
        var switched = false
        let ok = await menu.switchTo("feature/x", repoPath: "/code/ap", mergeRunning: false) { switched = true }
        XCTAssertTrue(ok)
        XCTAssertTrue(switched)
        XCTAssertNil(menu.error)
    }

    func testMenuModelKeepsTheRefusal() async {
        let menu = BranchMenuModel(runner: nil, state: state(uncommitted: 2))
        let ok = await menu.switchTo("feature/x", repoPath: "/code/ap", mergeRunning: false) {}
        XCTAssertFalse(ok)
        XCTAssertEqual(menu.error, "The project folder has 2 uncommitted files. Commit them first; a switch never stashes.")
    }

    // MARK: Screenshots

    private func details(branch: String) -> GitDetails {
        var d = GitDetails(branch: branch, remoteURL: nil)
        d.unpushed = [GitCommit(hash: "2dc9fcf", date: Date().addingTimeInterval(-180), subject: "test(setup): Calls helper behind a lock", tags: [], card: nil)]
        d.unpushedCount = 319
        d.merges = [GitCommit(hash: "a114b76", date: Date().addingTimeInterval(-720), subject: "refactor(app): TerminalBackend protocol (A4)", tags: ["stable-110"], card: "A4")]
        d.worktrees = [GitWorktree(path: "/demo/.agent-worktrees/task-n151", branch: "task/n151", ahead: 1, dirty: 0),
                       GitWorktree(path: "/demo/.agent-worktrees/task-n157", branch: "task/n157", ahead: 1, dirty: 0)]
        return d
    }

    private static let ignore = GitignoreInfo(text: ".DS_Store\ntmp/\n.superpowers/\napp/build/\n**/xcuserdata/\napp/Signing.local.xcconfig\napp/build.log\n",
                                              agentWorktrees: .exclude, branch: "main")

    private func shot(_ d: GitDetails, menu: BranchMenuModel?, ignore: GitignoreInfo, _ name: String) async throws {
        let model = await DemoSupport.makeModel()
        let git = GitScreenModel(reader: nil, details: d, projectID: model.selectedProjectID)
        let view = HStack(spacing: 0) {
            Rail(screen: .git, onSelect: { _ in }); Divider().overlay(Tok.line)
            GitView(model: model, git: git, branches: menu ?? BranchMenuModel(runner: nil), ignore: ignore, menuOpen: menu != nil)
        }
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 1440, height: 900)))
        XCTAssertGreaterThan(data.count, 20_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    func testScreenshotBranchMenuCreate() async throws {
        let menu = BranchMenuModel(runner: nil, state: state(local: ["main", "task/n151", "task/n157"], held: ["task/n151": true, "task/n157": true]))
        menu.query = "feature/git-screen"
        try await shot(details(branch: "main"), menu: menu, ignore: Self.ignore, "git-branch-menu-create")
    }

    func testScreenshotBranchMenuRefused() async throws {
        let menu = BranchMenuModel(runner: nil, state: state(local: ["main", "feature/x", "task/n151"], uncommitted: 2))
        var d = details(branch: "main"); d.uncommitted = 2
        try await shot(d, menu: menu, ignore: Self.ignore, "git-branch-menu-dirty")
    }

    func testScreenshotOffMainWithoutIgnore() async throws {
        let info = GitignoreInfo(text: ".DS_Store\n", agentWorktrees: .nowhere, branch: "feature/x")
        try await shot(details(branch: "feature/x"), menu: nil, ignore: info, "git-off-main-not-ignored")
    }
}
