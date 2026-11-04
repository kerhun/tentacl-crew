import XCTest
@testable import AgentPanel

final class ResumeSessionTests: XCTestCase {
    private var dir: TempDir!
    private var claudeRoot: URL { dir.url.appendingPathComponent("claude/projects") }
    private var codexRoot: URL { dir.url.appendingPathComponent("codex/sessions") }
    private let cwd = "/repo/.agent-worktrees/task-n1"

    override func setUpWithError() throws { dir = try TempDir() }

    private func transcript(_ id: String, age: TimeInterval) throws {
        let url = TranscriptReader.path(projectsRoot: claudeRoot, cwd: cwd, session: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    private func rollout(_ id: String, cwd: String, age: TimeInterval) throws {
        let url = codexRoot.appendingPathComponent("2026/10/25/rollout-2026-10-25T10-00-00-\(id).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"}}\n"
        try meta.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    private func pick(_ known: String?, _ tool: AgentTool = .claude) -> String? {
        ResumeSession.pick(known: known, tool: tool, cwd: cwd, claudeRoot: claudeRoot, codexRoot: codexRoot)
    }

    // MARK: session choice

    func testKnownSessionWinsOverANewerTranscript() throws {
        try transcript("old-known", age: 500)
        try transcript("newer", age: 10)
        XCTAssertEqual(pick("old-known"), "old-known")
    }

    func testNewestTranscriptWhenNothingIsKnown() throws {
        try transcript("a", age: 300)
        try transcript("b", age: 20)
        try transcript("c", age: 100)
        XCTAssertEqual(pick(nil), "b")
        XCTAssertEqual(pick(""), "b")
    }

    func testKnownSessionWithoutAFileFallsBackToTheNewestTranscript() throws {
        try transcript("real", age: 50)
        XCTAssertEqual(pick("gone"), "real")
    }

    func testNoneWhenThereIsNothing() throws {
        XCTAssertNil(pick(nil))
        XCTAssertNil(pick("gone"))
        try transcript("other-folder-id", age: 5)   // another folder's transcripts are not this agent's
        let other = ResumeSession.pick(known: nil, tool: .claude, cwd: "/elsewhere", claudeRoot: claudeRoot, codexRoot: codexRoot)
        XCTAssertNil(other)
    }

    func testCodexKnownThenNewestForTheWorktreeThenNone() throws {
        XCTAssertNil(pick(nil, .codex))
        try rollout("aaa-old", cwd: cwd, age: 400)
        try rollout("bbb-new", cwd: cwd, age: 10)
        try rollout("zzz-other", cwd: "/other", age: 1)
        XCTAssertEqual(pick(nil, .codex), "bbb-new")
        XCTAssertEqual(pick("aaa-old", .codex), "aaa-old")
        XCTAssertEqual(pick("missing", .codex), "bbb-new")
    }

    // MARK: when Resume is shown

    private func card(_ status: String, branch: String? = "task/n1") throws -> TaskCard {
        let b = branch.map { "branch: \($0)\n" } ?? "branch:\n"
        let url = try dir.write("tasks/N1.md", "---\nid: N1\nproject: demo\nstatus: \(status)\nagent:\n\(b)files:\n  - a\n---\n# N1 · T\n\n## Report\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    func testResumeIsOfferedOnlyForANotDoneCardWithoutALiveAgentAndWithAWorktree() throws {
        for status in ["doing", "needs-fix"] {
            XCTAssertEqual(ResumeSession.buttonState(card: try card(status), agentLive: false, worktreeExists: true)?.enabled, true, status)
        }
        for status in ["todo", "awaiting-start-approval", "review", "done", "blocked"] {
            XCTAssertNil(ResumeSession.buttonState(card: try card(status), agentLive: false, worktreeExists: true), status)
        }
        XCTAssertNil(ResumeSession.buttonState(card: try card("doing"), agentLive: true, worktreeExists: true), "a live agent")
        XCTAssertNil(ResumeSession.buttonState(card: try card("doing"), agentLive: false, worktreeExists: false), "no worktree")
        XCTAssertNil(ResumeSession.buttonState(card: try card("doing", branch: nil), agentLive: false, worktreeExists: true), "no branch")
    }

    func testResumeIsShownOffWhileBusyOrNotSetUp() throws {
        let busy = ResumeSession.buttonState(card: try card("doing"), agentLive: false, worktreeExists: true, busy: true)
        XCTAssertEqual(busy?.enabled, false)
        let setup = ResumeSession.buttonState(card: try card("doing"), agentLive: false, worktreeExists: true, canAct: false, reason: "No scripts folder.")
        XCTAssertEqual(setup, StartButtonState(enabled: false, help: "No scripts folder."))
    }

    func testResumeBecomesTheNextStep() throws {
        let start = StartButtonState(enabled: false, help: "x"), review = reviewButtonStates(card: try card("doing"), canAct: true, reason: nil)
        let resume = ResumeSession.buttonState(card: try card("doing"), agentLive: false, worktreeExists: true)
        XCTAssertEqual(nextStep(card: try card("doing"), phase: .idle, start: start, review: review, resume: resume), .action(.resume, blocked: nil))
        XCTAssertEqual(nextStep(card: try card("needs-fix"), phase: .needsFix, start: start, review: review, resume: resume), .action(.resume, blocked: nil))
        XCTAssertEqual(NextAction.resume.title, "Resume agent")
        XCTAssertEqual(nextStep(card: try card("doing"), phase: .working, start: start, review: review), .status("Agent is working"), "no resume state: unchanged")
    }
}

final class ResumeFlowTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!
    private var logURL: URL!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
        logURL = dir.url.appendingPathComponent("support/actions.log")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{\"agent\":\"dev-a5\",\"workspace_id\":\"wW\",\"pane_id\":\"wW:p1\",\"worktree_path\":\"/repo/.agent-worktrees/pilot-a5\",\"udid\":\"\"}\n", stderr: "") }
        try dir.write("roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\"}")
    }

    private func flow(writer: CardWriting = CardWriter()) -> StartTaskFlow {
        let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: dir.url.appendingPathComponent("data").path, maxParallel: 2,
                                    buildCommand: "build", xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: "Xcode",
                                    roles: ["dev": dir.url.appendingPathComponent("roles/dev.json").path], sourcePath: "/etc/demo/project.json")
        return StartTaskFlow(project: project, scripts: scripts, commander: commander, writer: writer, log: ActionLog(fileURL: logURL),
                             roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: { [] })
    }

    private func card(_ status: String = "doing") throws -> TaskCard {
        let url = try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: \(status)\nagent: dev-a5-demo\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5 · T\n\n## Report\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    func testResumeRunsTheScriptWithTheSessionAndLogsOneLine() async throws {
        let started = try await flow().resume(try card(), session: "sess-1")
        XCTAssertEqual(scripts.calls(of: .spawn).map(\.args), [["--resume", "sess-1", "/etc/demo/project.json", dir.url.appendingPathComponent("roles/dev.json").path, "A5", "pilot/a5"]])
        XCTAssertEqual(started.agent, "dev-a5")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").filter { $0.contains("resume A5") }.count, 1)
        XCTAssertTrue(log.contains(" [demo] resume A5"))
        XCTAssertEqual(commander.prompts.count, 1)
        XCTAssertTrue(commander.prompts[0].text.contains("A5.md"))
        XCTAssertTrue(scripts.calls(of: .stop).isEmpty, "a failed or finished resume never removes the worktree or branch")
    }

    func testResumeKeepsTheCardStatusAndSetsTheAgent() async throws {
        _ = try await flow().resume(try card("needs-fix"), session: "s")
        let text = try String(contentsOf: dir.url.appendingPathComponent("data/tasks/A5.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("status: needs-fix"))
        XCTAssertTrue(text.contains("agent: dev-a5"))
    }

    func testResumeRefusesCardsThatAreNotRunning() async throws {
        for status in ["todo", "done", "review"] {
            do { _ = try await flow().resume(try card(status), session: "s"); XCTFail(status) } catch let e as StartError { guard case .notStartable = e else { return XCTFail("\(e)") } }
        }
        XCTAssertTrue(scripts.calls.isEmpty)
    }

    func testAFailedScriptShowsItsMessageAndLeavesTheCard() async throws {
        scripts.handler = { _, _ in ScriptResult(status: 1, stdout: "", stderr: "ERROR: cannot resume: the worktree /x is gone") }
        let c = try card()
        let before = try String(contentsOf: c.url, encoding: .utf8)
        do { _ = try await flow().resume(c, session: "s"); XCTFail("expected a failure") }
        catch let e as StartError { XCTAssertTrue(e.message.contains("worktree /x is gone")) }
        XCTAssertEqual(try String(contentsOf: c.url, encoding: .utf8), before)
        XCTAssertTrue(commander.prompts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path) && ((try? String(contentsOf: logURL, encoding: .utf8))?.contains("resume A5") ?? false))
    }
}
