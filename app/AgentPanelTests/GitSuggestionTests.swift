import XCTest
import SwiftUI
@testable import AgentPanel

/// "Initialize git" and "Push to GitHub" in the Dashboard's Waiting for you (N163).
@MainActor
final class GitSuggestionTests: XCTestCase {
    private var dir: TempDir!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = try TempDir()
        defaults = makeTestDefaults(prefix: "agent-panel-tests-git-suggestions")
    }

    private func project(_ id: String = "np", branch: String? = nil) -> ProjectConfig {
        ProjectConfig(id: id, name: "Np", repoPath: dir.url.appendingPathComponent("code/\(id)").path, dataDir: dir.url.appendingPathComponent("wiki/\(id)").path,
                      maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil, mainBranch: branch)
    }

    private func card(_ id: String, _ status: TaskStatus = .todo) -> TaskCard {
        TaskCard(id: id, project: "np", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func probe(git: Bool = true, top: Bool = true, commits: Bool = true, remote: String? = nil, unpushed: Int? = nil, count: Int = 3) -> ProjectProbe {
        var facts = RepoFacts()
        facts.isGitRepo = git; facts.isTopLevel = git && top; facts.hasCommits = git && commits; facts.branch = git ? "main" : nil
        var p = ProjectProbe(facts: facts)
        p.remote = remote; p.unpushedCommits = unpushed; p.commitCount = count
        return p
    }

    private func model(_ probe: ProjectProbe, scripts: ScriptRunning? = nil) -> (GitSuggestionModel, ProbeBox) {
        let box = ProbeBox(probe)
        return (GitSuggestionModel(defaults: defaults, probe: { _ in box.value }, scripts: { scripts }), box)
    }

    // MARK: what is suggested

    func testAFolderWithoutGitAsksToInitializeIt() {
        XCTAssertEqual(gitSuggestions(state: GitState(probe: probe(git: false)), notNow: nil, githubCardExists: false), [.initializeGit])
    }

    func testAProjectWithoutARemoteOrWithUnpushedCommitsSuggestsPushToGitHub() {
        XCTAssertEqual(gitSuggestions(state: GitState(probe: probe()), notNow: nil, githubCardExists: false), [.pushToGitHub(.noRemote)])
        XCTAssertEqual(gitSuggestions(state: GitState(probe: probe(remote: "git@github.com:a/b.git", unpushed: 2)), notNow: nil, githubCardExists: false),
                       [.pushToGitHub(.unpushed(2))])
    }

    func testNothingIsSuggestedForAPushedRepositoryASubfolderOrARepositoryWithoutCommits() {
        XCTAssertEqual(gitSuggestions(state: GitState(probe: probe(remote: "git@github.com:a/b.git", unpushed: 0)), notNow: nil, githubCardExists: false), [])
        XCTAssertEqual(gitSuggestions(state: GitState(probe: probe(top: false)), notNow: nil, githubCardExists: false), [], "git init there would nest a repository")
        XCTAssertEqual(gitSuggestions(state: GitState(probe: probe(commits: false)), notNow: nil, githubCardExists: false), [], "nothing to push yet")
        XCTAssertEqual(gitSuggestions(state: nil, notNow: nil, githubCardExists: false), [], "not probed yet")
    }

    func testAnExistingGitHubCardHidesPushToGitHub() {
        XCTAssertEqual(gitSuggestions(state: GitState(probe: probe()), notNow: nil, githubCardExists: true), [])
    }

    func testOnlyAFolderWithoutGitBlocksStartingAgents() {
        XCTAssertEqual(gitStartReason(state: GitState(probe: probe(git: false))), "Initialize git first")
        XCTAssertNil(gitStartReason(state: GitState(probe: probe())))
        XCTAssertNil(gitStartReason(state: nil))
    }

    func testNotNowWithoutARemoteStaysThroughNewCommitsUntilARemoteAppears() async {
        let (m, box) = model(probe())
        let p = project()
        await m.refresh(p)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [.pushToGitHub(.noRemote)])
        m.notNow(p.id)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [])
        box.value = probe(count: 40)
        await m.refresh(p, force: true)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [], "new commits (merges) keep it hidden")
        box.value = probe(remote: "git@github.com:a/b.git", unpushed: 1, count: 41)
        await m.refresh(p, force: true)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [.pushToGitHub(.unpushed(1))], "a remote appearing brings it back")
    }

    func testNotNowWithUnpushedCommitsStaysUntilTheRemoteOrTheCountChanges() async {
        let (m, box) = model(probe(remote: "git@github.com:a/b.git", unpushed: 2, count: 5))
        let p = project()
        await m.refresh(p)
        m.notNow(p.id)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [])
        box.value = probe(remote: "git@github.com:a/b.git", unpushed: 2, count: 9)
        await m.refresh(p, force: true)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [], "the commit count alone does not bring it back")
        box.value = probe(remote: "git@github.com:a/b.git", unpushed: 3, count: 10)
        await m.refresh(p, force: true)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [.pushToGitHub(.unpushed(3))], "a new unpushed count brings it back")
        m.notNow(p.id)
        box.value = probe(remote: "git@github.com:c/d.git", unpushed: 3, count: 10)
        await m.refresh(p, force: true)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [.pushToGitHub(.unpushed(3))], "another remote brings it back")
        XCTAssertEqual(m.suggestions(for: p.id, cards: [card("G1")]), [])
    }

    func testTheProbeIsNotRunAgainWithinAMinuteUnlessForced() async {
        let (m, box) = model(probe(git: false))
        var clock = Date(timeIntervalSince1970: 1000)
        m.now = { clock }
        let p = project()
        await m.refresh(p)
        XCTAssertEqual(box.calls, 1)
        await m.refresh(p)
        XCTAssertEqual(box.calls, 1)
        clock += GitSuggestionModel.refreshInterval + 1
        await m.refresh(p)
        XCTAssertEqual(box.calls, 2)
        await m.refresh(p, force: true)
        XCTAssertEqual(box.calls, 3)
    }

    // MARK: Initialize git

    func testInitializeGitListsTheFilesAndCommitsOnlyTheTickedOnes() async throws {
        let scripts = FakeScripts()
        let listed = LockedBox<[String]>([])
        scripts.handler = { _, args in
            if args.contains("--list-files") { return ScriptResult(status: 0, stdout: "3\n.gitignore\nsrc/a.txt\n.env\n", stderr: "") }
            if let i = args.firstIndex(of: "--files") {
                listed.value = (try String(contentsOfFile: args[i + 1], encoding: .utf8)).split(separator: "\n").map(String.init)
            }
            return ScriptResult(status: 0, stdout: "/x/project.json\n", stderr: "")
        }
        let (m, box) = model(probe(git: false), scripts: scripts)
        let p = project(branch: "trunk")
        await m.refresh(p)
        await m.openInitGit(p)
        let sheet = try XCTUnwrap(m.initSheet)
        XCTAssertEqual(sheet.files, [".gitignore", "src/a.txt", ".env"])
        XCTAssertEqual(sheet.phase, .ready)
        XCTAssertEqual(scripts.calls(of: .createProject).first?.args, ["--existing", "--init-git", "--list-files", p.repoPath])
        m.toggle(".env")
        XCTAssertEqual(m.initSheet?.ticked, [".gitignore", "src/a.txt"])

        box.value = probe()
        let ok = await m.confirmInitGit()
        XCTAssertTrue(ok)
        let run = try XCTUnwrap(scripts.calls(of: .createProject).last?.args)
        XCTAssertEqual(Array(run.prefix(4)), ["--existing", "--init-git", "--branch", "trunk"])
        XCTAssertEqual(Array(run.suffix(5)), [p.repoPath, p.dataDir, p.id, p.name, "other"])
        XCTAssertEqual(listed.value, ["src/a.txt"], ".gitignore is committed by the script itself")
        XCTAssertNil(m.initSheet, "the sheet closes")
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [.pushToGitHub(.noRemote)], "probed again: now a repository without a remote")
        XCTAssertNil(m.startReason(projectID: p.id))
        m.initSheet = .init(project: p, files: [".gitignore", "a"], phase: .ready)
        m.toggle(".gitignore"); m.setAll(false)
        XCTAssertEqual(m.initSheet?.ticked, [".gitignore"], ".gitignore cannot be unticked")
    }

    func testAFailedInitializeKeepsTheSheetOpenWithTheScriptsError() async {
        let scripts = FakeScripts()
        scripts.handler = { _, args in
            args.contains("--list-files") ? ScriptResult(status: 0, stdout: "1\na.txt\n", stderr: "")
                                          : ScriptResult(status: 1, stdout: "", stderr: "ERROR: the initial commit failed\n")
        }
        let (m, _) = model(probe(git: false), scripts: scripts)
        let p = project()
        await m.openInitGit(p)
        let ok = await m.confirmInitGit()
        XCTAssertFalse(ok)
        XCTAssertEqual(m.initSheet?.phase, .failed("ERROR: the initial commit failed"))
    }

    func testWithoutAScriptsFolderTheSheetSaysWhy() async {
        let (m, _) = model(probe(git: false))
        await m.openInitGit(project())
        guard case .failed(let text) = m.initSheet?.phase else { return XCTFail("\(String(describing: m.initSheet))") }
        XCTAssertTrue(text.contains("scriptsDir"), text)
    }

    /// The real create-project.sh on a temporary folder: git init, only the ticked files, nothing pushed.
    func testInitializeGitWithTheRealScript() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runner = ProcessScriptRunner(settings: AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: []), timeout: 60)
        setenv("TENTACL_ROLES_DIR", dir.url.appendingPathComponent("roles").path, 1)
        defer { unsetenv("TENTACL_ROLES_DIR") }
        let p = project()
        let fm = FileManager.default
        try fm.createDirectory(atPath: p.repoPath + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: p.dataDir, withIntermediateDirectories: true)
        try "a".write(toFile: p.repoPath + "/src/a.txt", atomically: true, encoding: .utf8)
        try "secret".write(toFile: p.repoPath + "/.env", atomically: true, encoding: .utf8)
        let inspector = RepoInspector(runner: ProcessRunner(timeout: 30))
        let m = GitSuggestionModel(defaults: defaults, probe: { await inspector.probe($0) }, scripts: { runner })
        await m.refresh(p)
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [.initializeGit])
        await m.openInitGit(p)
        XCTAssertEqual(m.initSheet?.files.sorted(), [".env", ".gitignore", "src/a.txt"])
        m.toggle(".env")
        let ok = await m.confirmInitGit()
        XCTAssertTrue(ok, "\(String(describing: m.initSheet?.phase))")
        let tracked = try gitOutput(p.repoPath, ["ls-files"]).split(separator: "\n").map(String.init)
        XCTAssertEqual(tracked, [".gitignore", "src/a.txt"])
        XCTAssertEqual(try gitOutput(p.repoPath, ["remote"]), "")
        XCTAssertEqual(m.suggestions(for: p.id, cards: []), [.pushToGitHub(.noRemote)])
    }

    private func gitOutput(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Push to GitHub

    func testPushToGitHubCreatesAndPushesOnlyAfterTheClick() async {
        let tools = FakeTools(); tools.handler = FakeTools.noRemote
        let (m, _) = model(probe())
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        let p = project()
        await m.openPush(p, visibility: .publicRepo, owner: "octo")
        XCTAssertEqual(m.pushSheet?.buttonTitle, "Create octo/np and push main")
        XCTAssertFalse(tools.joined.contains { $0.contains("repo create") || $0.contains(" push") }, "opening the sheet only reads")
        let ok = await m.confirmPush()
        XCTAssertTrue(ok)
        XCTAssertTrue(tools.joined.contains("/fake/gh repo create octo/np --public --source \(p.repoPath) --remote origin"), tools.joined.joined(separator: "\n"))
        XCTAssertTrue(tools.joined.contains("/usr/bin/git -C \(p.repoPath) push -u origin main"))
        XCTAssertEqual(m.pushSheet?.phase, .done("Created octo/np and pushed main"))
    }

    func testTheOwnerDefaultsToTheSignedInAccountAndABadNameBlocks() async {
        let tools = FakeTools(); tools.handler = FakeTools.noRemote
        let (m, _) = model(probe())
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        await m.openPush(project())
        XCTAssertEqual(m.pushSheet?.buttonTitle, "Create kerhun/np and push main")
        m.pushSheet?.owner = "-bad"
        XCTAssertNotNil(m.pushSheet?.problem)
        let blocked = await m.confirmPush()
        XCTAssertFalse(blocked)
        m.pushSheet?.owner = ""; m.pushSheet?.name = "a b"
        XCTAssertNotNil(m.pushSheet?.problem)
        XCTAssertFalse(tools.joined.contains { $0.contains(" push") })
    }

    func testAPushWithARemoteListsTheCommitsAndSaysFetchFirstWhenBehind() async {
        let tools = FakeTools(); tools.handler = FakeTools.withRemote(behind: 2)
        let (m, _) = model(probe(remote: "git@github.com:a/b.git", unpushed: 3))
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        await m.openPush(project())
        XCTAssertEqual(m.pushSheet?.buttonTitle, "Push 3 commits to origin/main")
        XCTAssertEqual(m.pushSheet?.commitList.shown.count, 3)
        let ok = await m.confirmPush()
        XCTAssertFalse(ok)
        guard case .failed(let text)? = m.pushSheet?.phase else { return XCTFail("\(String(describing: m.pushSheet?.phase))") }
        XCTAssertTrue(text.hasPrefix("Fetch first"), text)
        XCTAssertFalse(tools.joined.contains { $0.contains(" push") }, "nothing was pushed")
    }

    func testNotSignedInOrGhMissingSaysSoAndOffersNoButton() async {
        let tools = FakeTools(); tools.handler = FakeTools.signedOut
        let (m, _) = model(probe())
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        await m.openPush(project())
        XCTAssertEqual(m.pushSheet?.problem, GitPublisher.signInProblem)
        XCTAssertFalse(m.pushSheet?.canConfirm ?? true)
        m.publisher = { GitPublisher(runner: tools, gh: nil) }
        await m.openPush(project())
        XCTAssertEqual(m.pushSheet?.problem, GitPublisher.missingProblem)
    }

    // MARK: N269: readable rows, push up to a chosen commit

    func testTheSubjectSplitsIntoTypeScopeCardAndText() {
        let full = CommitSubject("fix(terminals): the open filter field asks for focus (N266)")
        XCTAssertEqual(full, CommitSubject.init(type: "fix", scope: "terminals", card: "N266", text: "the open filter field asks for focus"))
        XCTAssertEqual(CommitSubject("feat: Usage category (N267)"), .init(type: "feat", scope: nil, card: "N267", text: "Usage category"))
        XCTAssertEqual(CommitSubject("docs!: breaking"), .init(type: "docs", scope: nil, card: nil, text: "breaking"))
        XCTAssertEqual(CommitSubject("Merge branch 'task/n167'"), .init(type: nil, scope: nil, card: "N167", text: "Merge branch 'task/n167'"))
        XCTAssertEqual(CommitSubject("note: not a known prefix"), .init(type: nil, scope: nil, card: nil, text: "note: not a known prefix"))
        XCTAssertEqual(CommitSubject("plain words"), .init(type: nil, scope: nil, card: nil, text: "plain words"))
        XCTAssertEqual(CommitSubject("fix:no space").type, nil, "a prefix needs the space after its colon")
    }

    private static let fourCommits: @Sendable (String) -> ScriptResult = { line in
        if line.contains("log -n") {
            return FakeTools.ok(["d4", "c3", "b2", "a1"].enumerated().map { i, sha in "\(sha)\u{1F}\(sha)\u{1F}\(1_700_000_000 - i * 3600)\u{1F}feat: c\(4 - i)\u{1F}\u{1E}" }.joined(separator: "\n"))
        }
        if line.contains("rev-list --count") && !line.contains("HEAD..refs/remotes") { return FakeTools.ok("4\n") }
        return FakeTools.withRemote(behind: 0)(line)
    }

    func testUntickingACommitKeepsItAndEveryNewerOneAndThePushStopsBeforeThem() async throws {
        let tools = FakeTools(); tools.handler = Self.fourCommits
        let (m, _) = model(probe(remote: "git@github.com:a/b.git", unpushed: 4))
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        let p = project()
        await m.openPush(p)
        XCTAssertEqual(m.pushSheet?.buttonTitle, "Push 4 commits to origin/main")
        XCTAssertEqual((0..<4).map { m.pushSheet?.isTicked($0) }, [true, true, true, true], "all ticked by default")
        m.togglePushCommit(1)
        XCTAssertEqual((0..<4).map { m.pushSheet?.isTicked($0) }, [false, false, true, true], "the newer one is unticked too")
        XCTAssertEqual(m.pushSheet?.choiceText, "2 of 4 commits will be pushed; the rest stay on this Mac")
        XCTAssertEqual(m.pushSheet?.buttonTitle, "Push 2 commits to origin/main")
        m.togglePushCommit(3)
        XCTAssertEqual(m.pushSheet?.pushCount, 0); XCTAssertNotNil(m.pushSheet?.problem, "nothing ticked blocks the button")
        m.togglePushCommit(2)
        XCTAssertEqual((0..<4).map { m.pushSheet?.isTicked($0) }, [false, false, true, true], "ticking one ticks every older one")
        let ok = await m.confirmPush()
        XCTAssertTrue(ok)
        XCTAssertEqual(tools.joined.last { $0.contains(" push") }, "/usr/bin/git -C \(p.repoPath) push origin b2:refs/heads/main")
        XCTAssertEqual(m.pushSheet?.phase, .done("Pushed 2 commits to origin/main; 2 stay on this Mac"))
    }

    func testWithEverythingTickedThePushIsTheNormalOne() async {
        let tools = FakeTools(); tools.handler = Self.fourCommits
        let (m, _) = model(probe(remote: "git@github.com:a/b.git", unpushed: 4))
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        let p = project()
        await m.openPush(p)
        m.togglePushCommit(0); m.togglePushCommit(0)
        XCTAssertEqual(m.pushSheet?.choiceText, "All 4 commits will be pushed")
        _ = await m.confirmPush()
        XCTAssertEqual(tools.joined.last { $0.contains(" push") }, "/usr/bin/git -C \(p.repoPath) push origin main")
    }

    func testTheOlderCommitsRowStandsForAllOfThem() async {
        let tools = FakeTools()
        tools.handler = { line in
            if line.contains("log -n") { return FakeTools.ok((0...20).map { "s\($0)\u{1F}s\($0)\u{1F}1700000000\u{1F}fix: \($0)\u{1F}\u{1E}" }.joined()) }
            if line.contains("rev-list --count") && !line.contains("HEAD..refs/remotes") { return FakeTools.ok("30\n") }
            return FakeTools.withRemote(behind: 0)(line)
        }
        let (m, _) = model(probe(remote: "git@github.com:a/b.git", unpushed: 30))
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        await m.openPush(project())
        XCTAssertEqual(m.pushSheet?.commitList.more, 10)
        m.togglePushCommit(20)
        XCTAssertEqual(m.pushSheet?.pushCount, 0, "unticking the older row unticks everything")
        m.togglePushCommit(20)
        XCTAssertEqual(m.pushSheet?.pushCount, 10)
        XCTAssertEqual(m.pushSheet?.upTo, "s20", "the push stops at the newest of the older commits")
    }

    // MARK: the panel

    func testTheDashboardListsTheGitSuggestionLastAndStartingWaitsForGit() async {
        let model = await DemoSupport.makeModel()
        let before = model.startDisabledReason
        let id = try? XCTUnwrap(model.selectedProjectID)
        let box = ProbeBox(probe(git: false))
        model.gitSetup.probe = { _ in box.value }
        await model.refreshGitState(force: true)
        XCTAssertEqual(model.dashboardWaiting.last?.kind, .git(.initializeGit), "git comes last (N182)")
        XCTAssertEqual(model.waitingForYouCount, waitingDecisionCount(model.dashboardWaiting))
        if before == nil { XCTAssertEqual(model.startDisabledReason, "Initialize git first") }
        XCTAssertEqual(model.gitSetup.startReason(projectID: id ?? ""), "Initialize git first")
    }

    /// N182: git suggestions come last (questions first).
    func testDashboardWaitingItemsPutGitLast() {
        let items = dashboardWaitingItems(questions: ["q"], fixes: [], cards: [], roundWaiting: [], approveRound: 0, git: [.pushToGitHub(.noRemote)])
        XCTAssertEqual(items.map(\.kind), [.question("q"), .git(.pushToGitHub(.noRemote))])
        XCTAssertEqual(items.last?.id, "git|push")
    }

    func testTheRowTexts() {
        XCTAssertEqual(GitSuggestion.initializeGit.title, "This folder is not a git repository")
        XCTAssertEqual(GitSuggestion.pushToGitHub(.noRemote).title, "No GitHub remote yet")
        XCTAssertEqual(GitSuggestion.pushToGitHub(.unpushed(1)).title, "1 commit not pushed")
        XCTAssertEqual(GitSuggestion.pushToGitHub(.unpushed(3)).title, "3 commits not pushed")
    }

    // MARK: screenshots

    func testSnapshotsOfTheRowsAndSheets() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "4\n.gitignore\nREADME.md\nsrc/main.swift\n.env\n", stderr: "") }
        let (m, _) = model(probe(git: false), scripts: scripts)
        let p = project()
        await m.openInitGit(p)
        m.toggle(".env")
        let initView = InitGitSheet(model: m, onDone: {})
        let (push, _) = model(probe())
        let tools = FakeTools(); tools.handler = FakeTools.noRemote
        push.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        await push.openPush(p)
        let pushView = PushToGitHubSheet(model: push, onDone: {})
        let (pushed, _) = model(probe(remote: "git@github.com:kerhun/np.git", unpushed: 3))
        let tools2 = FakeTools(); tools2.handler = FakeTools.withRemote(behind: 0)
        pushed.publisher = { GitPublisher(runner: tools2, gh: URL(fileURLWithPath: "/fake/gh")) }
        await pushed.openPush(p)
        let pushedView = PushToGitHubSheet(model: pushed, onDone: {})
        _ = await pushed.confirmPush()
        let doneView = PushToGitHubSheet(model: pushed, onDone: {})
        let (out, _) = model(probe())
        let tools3 = FakeTools(); tools3.handler = FakeTools.signedOut
        out.publisher = { GitPublisher(runner: tools3, gh: URL(fileURLWithPath: "/fake/gh")) }
        await out.openPush(p)
        let outView = PushToGitHubSheet(model: out, onDone: {})
        let rows = VStack(spacing: 8) {
            GitSuggestionRow(suggestion: .initializeGit, onOpen: {}, onNotNow: {})
            GitSuggestionRow(suggestion: .pushToGitHub(.unpushed(2)), onOpen: {}, onNotNow: {})
        }.padding(16).frame(width: 340).background(Tok.pane)
        for (name, data) in [("git-init-sheet", SnapshotRenderer.render(view: initView, size: CGSize(width: 560, height: 520))),
                             ("git-create-sheet", SnapshotRenderer.render(view: pushView, size: CGSize(width: 560, height: 520))),
                             ("git-push-sheet", SnapshotRenderer.render(view: pushedView, size: CGSize(width: 560, height: 420))),
                             ("git-push-done", SnapshotRenderer.render(view: doneView, size: CGSize(width: 560, height: 420))),
                             ("git-push-signed-out", SnapshotRenderer.render(view: outView, size: CGSize(width: 560, height: 260))),
                             ("git-waiting-rows", SnapshotRenderer.render(view: rows, size: CGSize(width: 340, height: 300))),
                             ("N269-push", try await partialPushSheet()),
                             ("N269-git", try await gitScreenList()),
                             ("N269-push-long", try await longPushSheet())] {
            let png = try XCTUnwrap(data)
            XCTAssertGreaterThan(png.count, 5_000, name)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
        }
    }
}

extension GitSuggestionTests {
    static let sampleSubjects = [
        ("d7c7d9e", "fix(terminals): the open filter field asks for focus until it lands; test opens the screen with the filter open (N266)"),
        ("0894d56", "fix(terminals): ⇧⌘F puts the keyboard in the filter field; every Aa panel tile and option takes a click on its whole area (N266)"),
        ("ca0e2da", "feat(settings): Usage category with Usage limit and Safe point, Sleep under Agents, search words (N267)"),
        ("977d838", "feat(dashboard): Preview icon beside Stop PM replaces the Show preview link (N265)"),
        ("8e8e614", "test: run limit counts after the build slot (N264)"),
        ("5b1c0aa", "docs: README explains the merge queue"),
    ]

    /// N269: the push sheet with the two newest commits kept back and one row opened.
    func partialPushSheet() async throws -> Data? {
        let tools = FakeTools()
        tools.handler = { line in
            if line.contains("log -n") {
                return FakeTools.ok(Self.sampleSubjects.enumerated().map { i, c in
                    "\(c.0)aaaa\u{1F}\(c.0)\u{1F}\(Int(Date().timeIntervalSince1970) - 600 - i * 2400)\u{1F}\(c.1)\u{1F}\(i == 2 ? "Adds the Usage category to Settings.\n\nThe usage chip opens it while the gate holds." : "")\u{1E}"
                }.joined(separator: "\n"))
            }
            if line.contains("rev-list --count") && !line.contains("HEAD..refs/remotes") { return FakeTools.ok("\(Self.sampleSubjects.count)\n") }
            if line.contains("tag --list") { return FakeTools.ok("stable-140\nstable-141\n") }
            return FakeTools.withRemote(behind: 0)(line)
        }
        let (m, _) = model(probe(remote: "git@github.com:kerhun/np.git", unpushed: Self.sampleSubjects.count))
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        await m.openPush(project())
        m.togglePushCommit(1)
        let view = PushToGitHubSheet(model: m, onDone: {}, expanded: "ca0e2daaaaa")
        return SnapshotRenderer.render(view: view, size: CGSize(width: 640, height: 640))
    }

    /// N269: 30 commits: 20 rows in a scrolling list and the "and 10 older commits" row.
    func longPushSheet() async throws -> Data? {
        let tools = FakeTools()
        tools.handler = { line in
            if line.contains("log -n") {
                return FakeTools.ok((0...20).map { i in
                    let c = Self.sampleSubjects[i % Self.sampleSubjects.count]
                    return "\(c.0)\(i)\u{1F}\(c.0)\u{1F}\(Int(Date().timeIntervalSince1970) - 600 - i * 3600)\u{1F}\(c.1)\u{1F}\u{1E}"
                }.joined())
            }
            if line.contains("rev-list --count") && !line.contains("HEAD..refs/remotes") { return FakeTools.ok("30\n") }
            return FakeTools.withRemote(behind: 0)(line)
        }
        let (m, _) = model(probe(remote: "git@github.com:kerhun/np.git", unpushed: 30))
        m.publisher = { GitPublisher(runner: tools, gh: URL(fileURLWithPath: "/fake/gh")) }
        await m.openPush(project())
        return SnapshotRenderer.render(view: PushToGitHubSheet(model: m, onDone: {}), size: CGSize(width: 640, height: 660))
    }

    /// N269: the Git screen's "Not pushed" list, one row opened.
    func gitScreenList() async throws -> Data? {
        let model = await DemoSupport.makeModel()
        var details = GitDetails(branch: "main", remoteURL: "git@github.com:kerhun/demo.git", upstream: "origin/main", lastFetch: Date())
        details.unpushed = Self.sampleSubjects.enumerated().map { i, c in
            GitCommit(hash: c.0, date: Date().addingTimeInterval(TimeInterval(-600 - i * 2400)), subject: c.1, tags: [], card: GitDetails.cardID(in: c.1))
        }
        details.unpushedCount = details.unpushed.count; details.ahead = details.unpushedCount; details.behind = 0
        let git = GitScreenModel(reader: nil, details: details, projectID: model.selectedProjectID)
        let view = GitView(model: model, git: git, expandedCommit: "ca0e2da", messages: ["ca0e2da": "Adds the Usage category to Settings.\n\nThe usage chip opens it while the gate holds."])
        return SnapshotRenderer.render(view: view, size: CGSize(width: 1200, height: 760))
    }
}

/// The probe answer a test can change between refreshes; counts the calls.
final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProjectProbe
    private(set) var calls = 0
    init(_ value: ProjectProbe) { stored = value }
    var value: ProjectProbe {
        get { lock.lock(); defer { lock.unlock() }; calls += 1; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
