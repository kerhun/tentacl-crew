import XCTest
@testable import AgentPanel

final class FakeScripts: ScriptRunning, @unchecked Sendable {
    struct Call: Equatable { let script: ScriptName; let args: [String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    var handler: @Sendable (ScriptName, [String]) async throws -> ScriptResult = { script, args in
        switch script {
        case .spawn:
            let id = args[2].lowercased(), branch = args[3].replacingOccurrences(of: "/", with: "-")
            return ScriptResult(status: 0, stdout: "{\"agent\":\"dev-\(id)\",\"workspace_id\":\"wW\",\"pane_id\":\"wW:p1\",\"worktree_path\":\"/repo/.agent-worktrees/\(branch)\",\"udid\":\"UDID-1\"}\n", stderr: "")
        default: return ScriptResult(status: 0, stdout: "", stderr: "")
        }
    }
    func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult {
        lock.lock(); recorded.append(Call(script: script, args: arguments)); lock.unlock()
        return try await handler(script, arguments)
    }
    func calls(of script: ScriptName) -> [Call] { calls.filter { $0.script == script } }
}

final class FakeCommander: TerminalCommanding, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, String)] = []
    var error: Error?
    var prompts: [(target: String, text: String)] { lock.lock(); defer { lock.unlock() }; return recorded.map { ($0.0, $0.1) } }
    func prompt(target: String, text: String) async throws {
        lock.lock(); recorded.append((target, text)); lock.unlock()
        if let error { throw error }
    }
}

struct FailingWriter: CardWriting {
    func update(_ card: TaskCard, set values: [CardField: String], section: SectionEdit?, expectingStatus: TaskStatus) throws {
        throw CardWriteError.writeFailed("disk full")
    }
}

final class StartTaskFlowTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!
    private var logURL: URL!
    private var running: [TaskCard] = []

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
        logURL = dir.url.appendingPathComponent("support/actions.log")
        running = []
        try dir.write("roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\"}")
    }

    private func project(maxParallel: Int = 2, roles: Bool = true, source: Bool = true, repo: String = "/repo") -> ProjectConfig {
        ProjectConfig(id: "demo", name: "Demo", repoPath: repo, dataDir: dir.url.appendingPathComponent("data").path, maxParallel: maxParallel,
                      buildCommand: "build", xcodeProject: nil, simulator: .init(baseDevice: "iPhone 17 Pro"), sharedFiles: [], openWith: "Xcode",
                      roles: roles ? ["dev": dir.url.appendingPathComponent("roles/dev.json").path] : nil,
                      sourcePath: source ? "/etc/demo/project.json" : nil)
    }

    @discardableResult
    private func makeCard(_ id: String, status: String = "todo", branch: String? = "pilot/a5") throws -> TaskCard {
        let b = branch.map { "branch: \($0)\n" } ?? "branch:\n"
        let url = try dir.write("data/tasks/\(id).md", "---\nid: \(id)\nproject: demo\nstatus: \(status)\nagent:\n\(b)files:\n  - App/\(id).swift\n---\n# \(id) · Title\n\n## Goal\nGoal text.\n\n## Report\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private func flow(project: ProjectConfig? = nil, writer: CardWriting = CardWriter(), trust: ClaudeTrust? = nil, server: TerminalServerEnsuring = NoTerminalServerCheck()) -> StartTaskFlow {
        let snapshot = { [unowned self] in self.running }
        return StartTaskFlow(project: project ?? self.project(), scripts: scripts, commander: commander, writer: writer,
                             log: ActionLog(fileURL: logURL), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: snapshot, trust: trust, server: server)
    }

    private func read(_ card: TaskCard) throws -> String { try String(contentsOf: card.url, encoding: .utf8) }

    func testStartLineNamesTheProject() async throws {
        let f = flow()
        let card = try makeCard("A5")
        _ = try? await f.start(try f.plan(for: card))
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains(" [demo] start A5"))
    }

    // MARK: plan

    func testPlanRequiresStartableStatus() throws {
        for status in ["doing", "done", "review", "blocked", "needs-fix"] {
            let card = try makeCard("A\(status.count)", status: status)
            XCTAssertThrowsError(try flow().plan(for: card), status) { guard case .notStartable = $0 as? StartError else { return XCTFail("\($0)") } }
        }
        XCTAssertNoThrow(try flow().plan(for: try makeCard("T1", status: "todo")))
        XCTAssertNoThrow(try flow().plan(for: try makeCard("T2", status: "awaiting-start-approval")))
    }

    /// Review Focus 1: card fields are untrusted; nothing unsafe reaches a script.
    func testPlanRejectsUnsafeBranchAndID() throws {
        for branch in ["x; rm -rf ~", "--force", "../..", "a b", "$(id)"] {
            let card = try makeCard("U1", branch: branch)
            XCTAssertThrowsError(try flow().plan(for: card), branch) { guard case .invalid = $0 as? StartError else { return XCTFail("\($0)") } }
        }
        let evil = TaskCard(id: "../../etc", project: "demo", status: .todo, agent: nil, branch: "ok/b", kind: nil, files: ["a"], title: "t", sections: [:], url: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertThrowsError(try flow().plan(for: evil)) { guard case .invalid = $0 as? StartError else { return XCTFail("\($0)") } }
        XCTAssertEqual(scripts.calls, [])
    }

    func testCapacityCountsDoingNeedsFixAndReview() throws {
        running = [try makeCard("R1", status: "doing", branch: "other/r1"), try makeCard("R2", status: "needs-fix", branch: "other/r2"),
                   try makeCard("R3", status: "review", branch: "other/r3")]
        XCTAssertThrowsError(try flow(project: project(maxParallel: 3)).plan(for: try makeCard("T1"))) { XCTAssertEqual($0 as? StartError, .capacity(3)) }
        XCTAssertNoThrow(try flow(project: project(maxParallel: 4)).plan(for: try makeCard("T1")))
    }

    func testPlanStopsAtCapacity() throws {
        running = [try makeCard("R1", status: "doing", branch: "other/r1"), try makeCard("R2", status: "doing", branch: "other/r2")]
        XCTAssertThrowsError(try flow(project: project(maxParallel: 2)).plan(for: try makeCard("T1"))) { XCTAssertEqual($0 as? StartError, .capacity(2)) }
        XCTAssertNoThrow(try flow(project: project(maxParallel: 3)).plan(for: try makeCard("T1")))
    }

    func testCapacityIsCheckedAgainRightBeforeSpawning() async throws {
        let f = flow(project: project(maxParallel: 2))
        let plan = try f.plan(for: try makeCard("T1"))   // two slots free when planned
        running = [try makeCard("R1", status: "doing", branch: "other/r1"), try makeCard("R2", status: "doing", branch: "other/r2")]   // taken since
        do { _ = try await f.start(plan); XCTFail("expected the limit to stop it") }
        catch let error as StartError { XCTAssertEqual(error, .capacity(2)) }
        XCTAssertTrue(scripts.calls(of: .spawn).isEmpty, "nothing was spawned")
    }

    func testPlanNeedsDevRoleAndProjectFile() throws {
        XCTAssertThrowsError(try flow(project: project(roles: false)).plan(for: try makeCard("T1"))) {
            guard case .missingRole(let name, _, _) = $0 as? StartError else { return XCTFail("\($0)") }; XCTAssertEqual(name, "dev")
        }
        XCTAssertThrowsError(try flow(project: project(source: false)).plan(for: try makeCard("T1"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }; XCTAssertTrue(m.contains("project.json"))
        }
    }

    func testPlanUsesDefaultBranchWhenMissing() throws {
        let plan = try flow().plan(for: try makeCard("A5", branch: nil))
        XCTAssertEqual(plan.branch, "task/a5")
    }

    func testPlanFieldsAreComplete() throws {
        let plan = try flow().plan(for: try makeCard("A5", branch: "pilot/a5-widget"))
        XCTAssertEqual(plan.agentName, "dev-a5-demo")
        XCTAssertEqual(plan.branch, "pilot/a5-widget")
        XCTAssertEqual(plan.worktreePath, "/repo/.agent-worktrees/pilot-a5-widget")
        XCTAssertTrue(plan.rolePath.hasSuffix("roles/dev.json"))
        for part in ["spawn-agent.sh", "/etc/demo/project.json", "A5", "pilot/a5-widget"] { XCTAssertTrue(plan.commandPreview.contains(part), part) }
    }

    // MARK: start

    func testStartRunsConflictCheckAgainstEveryRunningCard() async throws {
        running = [try makeCard("R1", status: "doing", branch: "other/r1"), try makeCard("R2", status: "doing", branch: "other/r2")]
        let card = try makeCard("T1")
        let f = flow(project: project(maxParallel: 5))
        _ = try await f.start(try f.plan(for: card))
        let checks = scripts.calls(of: .checkConflicts)
        XCTAssertEqual(checks.count, 2)
        XCTAssertEqual(checks.map { $0.args[1] }.sorted(), running.map(\.url.path).sorted())
        XCTAssertTrue(checks.allSatisfy { $0.args[0] == card.url.path && $0.args[2] == "/etc/demo/project.json" })
    }

    func testConflictAbortsBeforeSpawn() async throws {
        running = [try makeCard("R1", status: "doing", branch: "other/r1")]
        scripts.handler = { script, _ in script == .checkConflicts ? ScriptResult(status: 1, stdout: "CONFLICT: App/R1.swift\n", stderr: "") : ScriptResult(status: 0, stdout: "", stderr: "") }
        let card = try makeCard("T1")
        let f = flow(project: project(maxParallel: 5))
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a conflict") }
        catch let e as StartError { guard case .conflict(let m) = e else { return XCTFail("\(e)") }; XCTAssertTrue(m.contains("App/R1.swift")) }
        XCTAssertEqual(scripts.calls(of: .spawn).count, 0)
        XCTAssertTrue(try read(card).contains("status: todo"))
    }

    func testSpawnFailureLeavesCardUntouched() async throws {
        scripts.handler = { script, _ in script == .spawn ? ScriptResult(status: 1, stdout: "", stderr: "ERROR: terminal is not reachable: no server\n") : ScriptResult(status: 0, stdout: "", stderr: "") }
        let card = try makeCard("T1"); let before = try read(card)
        let f = flow()
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .spawnFailed(let m) = e else { return XCTFail("\(e)") }; XCTAssertTrue(m.contains("terminal is not reachable")) }
        XCTAssertEqual(try read(card), before)
        XCTAssertEqual(commander.prompts.count, 0)
        XCTAssertEqual(scripts.calls(of: .stop).count, 0, "spawn-agent.sh rolls back its own failure")
    }

    func testUnparseableSpawnOutputIsReportedAndCleanedUp() async throws {
        scripts.handler = { script, _ in script == .spawn ? ScriptResult(status: 0, stdout: "no json here\n", stderr: "") : ScriptResult(status: 0, stdout: "", stderr: "") }
        let card = try makeCard("T1"); let f = flow()
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .spawnFailed = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(scripts.calls(of: .stop).count, 1)
        XCTAssertTrue(try read(card).contains("status: todo"))
    }

    func testPromptFailureRollsBackAgent() async throws {
        commander.error = BackendError.failed("agent not found")
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow()
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .promptFailed(let m) = e else { return XCTFail("\(e)") }; XCTAssertTrue(m.contains("agent not found")) }
        let stop = try XCTUnwrap(scripts.calls(of: .stop).first)
        XCTAssertEqual(stop.args, ["dev-t1", "/repo/.agent-worktrees/pilot-t1", "--remove-worktree", "--delete-branch", "--expect-branch", "pilot/t1"])
        XCTAssertTrue(try read(card).contains("status: todo"))
    }

    /// Review Focus 3: the agent is running but the card cannot be updated.
    func testCardWriteFailureRollsBackAgentAndReports() async throws {
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow(writer: FailingWriter())
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .cardWriteFailed(let m) = e else { return XCTFail("\(e)") }; XCTAssertTrue(m.contains("disk full")) }
        XCTAssertEqual(scripts.calls(of: .stop).count, 1)
        XCTAssertTrue(try read(card).contains("status: todo"))
    }

    func testCardChangedBeforeStartIsRejectedBeforeSpawn() async throws {
        let card = try makeCard("T1"); let f = flow()
        let plan = try f.plan(for: card)
        try (try read(card)).replacingOccurrences(of: "status: todo", with: "status: blocked").write(to: card.url, atomically: true, encoding: .utf8)
        do { _ = try await f.start(plan); XCTFail("expected a refusal") }
        catch let e as StartError { guard case .notStartable = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(scripts.calls(of: .spawn).count, 0)
    }

    /// I4: the card's branch was edited while the sheet was open; the panel must not spawn on the stale branch nor overwrite the edit.
    func testCardEditedWhileSheetOpenIsRejectedBeforeSpawn() async throws {
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow()
        let plan = try f.plan(for: card)
        let edited = try read(card).replacingOccurrences(of: "branch: pilot/t1", with: "branch: chosen/by-the-pm")
        try edited.write(to: card.url, atomically: true, encoding: .utf8)
        do { _ = try await f.start(plan); XCTFail("expected a refusal") }
        catch let e as StartError { guard case .notStartable = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(scripts.calls(of: .spawn).count, 0)
        XCTAssertEqual(try read(card), edited)
    }

    // MARK: I1 — a failed cleanup must be reported, not hidden behind "stopped again"

    private func stopFails(_ stderr: String = "ERROR: no terminal workspace for worktree\n") {
        let base = scripts.handler
        scripts.handler = { script, args in script == .stop ? ScriptResult(status: 1, stdout: "", stderr: stderr) : try await base(script, args) }
    }

    func testRollbackFailureAfterPromptFailureIsReportedWithManualSteps() async throws {
        commander.error = BackendError.failed("agent not found"); stopFails()
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow()
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError {
            guard case .cleanupFailed(let cause, let detail, let manual) = e else { return XCTFail("expected cleanupFailed, got \(e)") }
            XCTAssertTrue(cause.contains("agent not found"))
            XCTAssertTrue(detail.contains("no terminal workspace"))
            for part in ["dev-t1", "/repo/.agent-worktrees/pilot-t1", "pilot/t1", "agent-dev-t1"] { XCTAssertTrue(manual.contains(part), part) }
            XCTAssertTrue(e.message.contains("Remove manually"))
            XCTAssertFalse(e.message.contains("stopped again"))
        }
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("CLEANUP FAILED"))
    }

    func testRollbackFailureAfterCardWriteFailureIsReported() async throws {
        stopFails()
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow(writer: FailingWriter())
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .cleanupFailed = e else { return XCTFail("expected cleanupFailed, got \(e)") } }
    }

    func testRollbackThatThrowsIsReported() async throws {
        commander.error = BackendError.failed("nope")
        let base = scripts.handler
        scripts.handler = { script, args in if script == .stop { throw ScriptError.timedOut(2) }; return try await base(script, args) }
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow()
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .cleanupFailed(_, let detail, _) = e else { return XCTFail("\(e)") }; XCTAssertTrue(detail.contains("did not finish")) }
    }

    // MARK: I3 — rollback only ever touches what this run created

    func testPlanRefusesAWorktreeFolderThatAlreadyExists() throws {
        let repo = try dir.write("repo/README", "x").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".agent-worktrees/pilot-t1"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try flow(project: project(repo: repo.path)).plan(for: try makeCard("T1", branch: "pilot/t1"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }; XCTAssertTrue(m.contains("already exists"), m)
        }
    }

    func testPlanRefusesBranchesThatShareAWorktreeFolder() throws {
        running = [try makeCard("R1", status: "doing", branch: "pilot/t1")]
        XCTAssertThrowsError(try flow().plan(for: try makeCard("T1", branch: "pilot-t1"))) {
            guard case .invalid(let m) = $0 as? StartError else { return XCTFail("\($0)") }; XCTAssertTrue(m.contains("same worktree folder"), m)
        }
    }

    func testLaunchFailureDoesNotRunRollback() async throws {
        scripts.handler = { script, _ in if script == .spawn { throw ScriptError.launchFailed("no bash") }; return ScriptResult(status: 0, stdout: "", stderr: "") }
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow()
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .spawnFailed = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(scripts.calls(of: .stop).count, 0, "nothing was started, so nothing may be stopped (the path may belong to another agent)")
    }

    func testTimedOutSpawnIsCleanedUpWithTheExpectedBranch() async throws {
        scripts.handler = { script, _ in if script == .spawn { throw ScriptError.timedOut(120) }; return ScriptResult(status: 0, stdout: "", stderr: "") }
        let card = try makeCard("T1", branch: "pilot/t1"); let f = flow()
        do { _ = try await f.start(try f.plan(for: card)); XCTFail("expected a failure") }
        catch let e as StartError { guard case .spawnFailed = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(try XCTUnwrap(scripts.calls(of: .stop).first).args.suffix(2), ["--expect-branch", "pilot/t1"])
    }

    func testSuccessWritesDoingAgentBranchAndLogs() async throws {
        let card = try makeCard("A5", branch: "pilot/a5-widget"); let f = flow()
        let started = try await f.start(try f.plan(for: card))
        XCTAssertEqual(started, StartedAgent(agent: "dev-a5", paneID: "wW:p1", worktreePath: "/repo/.agent-worktrees/pilot-a5-widget", udid: "UDID-1"))
        let written = try CardParser.parse(try read(card), url: card.url)
        XCTAssertEqual(written.status, .doing)
        XCTAssertEqual(written.agent, "dev-a5")
        XCTAssertEqual(written.branch, "pilot/a5-widget")
        let prompt = try XCTUnwrap(commander.prompts.first)
        XCTAssertEqual(prompt.target, "wW:p1")
        XCTAssertEqual(prompt.text, "Your task card: \(card.url.path) (read it fully, then do the task). Follow your role instructions (concise). When finished, fill the card's Report section and tell me briefly.")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 1)
        XCTAssertTrue(log.contains("start A5") && log.contains("dev-a5") && log.contains("pilot/a5-widget"))
    }

    func testArgumentsAreSeparatedNotJoined() async throws {
        let card = try makeCard("A5", branch: "pilot/a5-widget"); let f = flow()
        _ = try await f.start(try f.plan(for: card))
        let spawn = try XCTUnwrap(scripts.calls(of: .spawn).first)
        XCTAssertEqual(spawn.args.count, 4)
        XCTAssertEqual(spawn.args[0], "/etc/demo/project.json")
        XCTAssertTrue(spawn.args[1].hasSuffix("roles/dev.json"))
        XCTAssertEqual(Array(spawn.args[2...]), ["A5", "pilot/a5-widget"])
    }

    /// Review Focus 2: a second start for the same card while the first is still running.
    func testSecondStartWhileRunningIsRejected() async throws {
        let gate = TestGate()
        scripts.handler = { [scripts] script, args in
            if script == .spawn { await gate.wait() }
            return try await FakeScripts().handler(script, args)
        }
        _ = scripts
        let card = try makeCard("A5", branch: "pilot/a5-widget"); let f = flow()
        let plan = try f.plan(for: card)
        let first = Task { try await f.start(plan) }
        for _ in 0..<300 where self.scripts.calls(of: .spawn).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(self.scripts.calls(of: .spawn).count, 1)
        do { _ = try await f.start(plan); XCTFail("second start must be refused") }
        catch let e as StartError { XCTAssertEqual(e, .alreadyStarting) }
        await gate.release()
        _ = try await first.value
        XCTAssertEqual(self.scripts.calls(of: .spawn).count, 1)
        XCTAssertEqual(self.commander.prompts.count, 1)
    }

    func testStartChecksTheServerBeforeSpawningAndReportsTheStatusLine() async throws {
        let server = RecordingServer(); server.announces = true
        let lines = LockedLines()
        server.onCall = { XCTAssertTrue(self.scripts.calls(of: .spawn).isEmpty, "the server is checked before the spawn script") }
        let f = flow(server: server)
        _ = try await f.start(try f.plan(for: try makeCard("A5")), status: { lines.add($0) })
        XCTAssertEqual(server.calls, 1)
        XCTAssertEqual(lines.all, ["Starting the terminal…", "Starting dev-a5-demo…"])
    }

    func testStartWithAServerThatDoesNotComeUpSpawnsNothingAndSaysWhy() async throws {
        let server = RecordingServer(); server.failure = BackendError.failed("terminal did not start within 15 s; open terminal in a terminal and try again")
        let f = flow(server: server)
        do { _ = try await f.start(try f.plan(for: try makeCard("A5"))); XCTFail("should fail") }
        catch let e as StartError { XCTAssertEqual(e.message, "The agent could not be started: terminal did not start within 15 s; open terminal in a terminal and try again") }
        XCTAssertTrue(scripts.calls(of: .spawn).isEmpty)
        XCTAssertTrue(scripts.calls(of: .stop).isEmpty, "nothing was started, so nothing is cleaned up")
    }

    func testStartAllowsTheSameCardAgainAfterItFinished() async throws {
        let card = try makeCard("A5", branch: "pilot/a5-widget"); let f = flow()
        scripts.handler = { script, _ in script == .spawn ? ScriptResult(status: 1, stdout: "", stderr: "ERROR: nope\n") : ScriptResult(status: 0, stdout: "", stderr: "") }
        _ = try? await f.start(try f.plan(for: card))
        scripts.handler = FakeScripts().handler
        _ = try await f.start(try f.plan(for: card))
        XCTAssertEqual(scripts.calls(of: .spawn).count, 2)
    }

    /// Review Focus 7: nothing but the three front-matter lines changes.
    func testStartDoesNotTouchCardBodyOrOtherFiles() async throws {
        let other = try dir.write("data/tasks/OTHER.md", "---\nid: OTHER\nstatus: todo\n---\n# other\n")
        let backlog = try dir.write("data/orchard-backlog.md", "# backlog\n")
        let card = try makeCard("A5", branch: "pilot/a5-widget")
        let before = try read(card).components(separatedBy: "\n")
        let f = flow(); _ = try await f.start(try f.plan(for: card))
        let after = try read(card).components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.map { $1 }.sorted(), ["agent: dev-a5", "status: doing"])
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "---\nid: OTHER\nstatus: todo\n---\n# other\n")
        XCTAssertEqual(try String(contentsOf: backlog, encoding: .utf8), "# backlog\n")
    }

    func testActionLogFailureDoesNotBlockStart() async throws {
        let blocker = try dir.write("blocker", "i am a file")
        let card = try makeCard("A5", branch: "pilot/a5-widget")
        let f = StartTaskFlow(project: project(), scripts: scripts, commander: commander, writer: CardWriter(),
                              log: ActionLog(fileURL: blocker.appendingPathComponent("sub/actions.log")), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), teamStore: TeamChartStore(), runningCards: { [] })
        let started = try await f.start(try f.plan(for: card))
        XCTAssertEqual(started.agent, "dev-a5")
    }

    // MARK: Claude Code's trust question

    private func trustFile(trusted: Bool) throws -> ClaudeTrust {
        let json = trusted ? #"{"projects":{"/repo":{"hasTrustDialogAccepted":true}}}"# : #"{"projects":{}}"#
        return ClaudeTrust(configURL: try dir.write("claude.json", json))
    }

    func testAnUntrustedRepositoryIsMarkedTrustedBeforeTheAgentStarts() async throws {
        let f = flow(trust: try trustFile(trusted: false))
        let plan = try f.plan(for: try makeCard("A5"))
        XCTAssertTrue(plan.needsTrust)
        _ = try await f.start(plan)
        let names = scripts.calls.map(\.script)
        XCTAssertEqual(names.first, .trustFolder)
        XCTAssertEqual(scripts.calls.first?.args, ["/repo"])
        XCTAssertTrue(names.contains(.spawn))
        XCTAssertLessThan(names.firstIndex(of: .trustFolder)!, names.firstIndex(of: .spawn)!)
    }

    func testATrustedOrUnknownRepositoryNeedsNoTrustStep() async throws {
        for (trust, id) in [(try trustFile(trusted: true), "B1"), (nil, "B2")] {
            scripts = FakeScripts()
            let f = flow(trust: trust)
            let plan = try f.plan(for: try makeCard(id))
            XCTAssertFalse(plan.needsTrust)
            _ = try await f.start(plan)
            XCTAssertFalse(scripts.calls.map(\.script).contains(.trustFolder))
        }
    }

    func testWhenTheTrustStepFailsNothingIsStarted() async throws {
        scripts.handler = { script, _ in script == .trustFolder ? ScriptResult(status: 1, stdout: "", stderr: "ERROR: not valid") : ScriptResult(status: 0, stdout: "{}", stderr: "") }
        let f = flow(trust: try trustFile(trusted: false))
        let plan = try f.plan(for: try makeCard("C1"))
        do { _ = try await f.start(plan); XCTFail("should fail") }
        catch let error as StartError { XCTAssertTrue(error.message.contains("trusted"), error.message) }
        XCTAssertFalse(scripts.calls.map(\.script).contains(.spawn))
    }

    func testTheStartSheetTellsTheUserAboutTheTrustStep() throws {
        let f = flow(trust: try trustFile(trusted: false))
        let plan = try f.plan(for: try makeCard("D1"))
        let fields = startSheetFields(plan: plan, project: project())
        XCTAssertTrue(fields.first { $0.label == "Trust" }?.value.contains("/repo") == true)
        let trusted = try flow(trust: try trustFile(trusted: true)).plan(for: try makeCard("D2"))
        XCTAssertNil(startSheetFields(plan: trusted, project: project()).first { $0.label == "Trust" })
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    var all: [String] { lock.withLock { items } }
    func add(_ s: String) { lock.withLock { items.append(s) } }
}
