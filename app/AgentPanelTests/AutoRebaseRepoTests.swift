import XCTest
@testable import AgentPanel

private struct IdleReader: TerminalReading { func screen(of target: String, lines: Int) async throws -> String { "" } }
private struct IdleSender: TerminalKeySending, TerminalCommanding {
    func sendKeys(target: String, keys: [String]) async throws {}
    func prompt(target: String, text: String) async throws {}
}
private struct NoDecider: PMDeciding {
    func decide(_ request: DecisionRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
    func decide(_ request: FixRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
}

/// N207: the autopilot rebases a behind card itself, against real temporary git repositories and the real merge-task.sh.
@MainActor
final class AutoRebaseRepoTests: XCTestCase {
    private var dir: TempDir!
    private var repo: URL!
    private var project: ProjectConfig!
    private var flow: ReviewFlow!
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var worktree: URL { repo.appendingPathComponent(".agent-worktrees/test-r1") }
    private var actionsLog: URL { dir.url.appendingPathComponent("actions.log") }

    override func setUpWithError() throws {
        dir = try TempDir()
        repo = dir.url.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-q", "-b", "main"])
        try dir.write("repo/a.txt", "a\n")
        try git(repo, ["add", "."]); try git(repo, ["commit", "-q", "-m", "init"])
        try git(repo, ["worktree", "add", "-q", "-b", "test/r1", worktree.path])
        try dir.write("repo/.agent-worktrees/test-r1/b.txt", "b\n")
        try git(worktree, ["add", "."]); try git(worktree, ["commit", "-q", "-m", "branch work"])
        let source = try dir.write("project.json", """
        {"id":"demo","name":"Demo","repoPath":"\(repo.path)","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,"sharedFiles":[],"roles":{}}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")
        project = try XCTUnwrap(ProjectStore.load(settingsURL: settings).projects.first)
        let app = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        flow = ReviewFlow(project: project, scripts: ProcessScriptRunner(settings: app, timeout: 60), adapter: FakeTerminal(agentsResult: .success([])), commander: IdleSender(),
                          writer: CardWriter(), log: ActionLog(fileURL: actionsLog))
    }

    @discardableResult
    private func git(_ at: URL, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", at.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Main moves on with a commit that touches `file`.
    private func mainMoves(file: String = "c.txt", text: String = "c\n") throws {
        try dir.write("repo/\(file)", text)
        try git(repo, ["add", "."]); try git(repo, ["commit", "-q", "-m", "main moves \(file)"])
    }

    private let card = TaskCard(id: "R1", project: "demo", status: .review, agent: "dev-r1", branch: "test/r1", kind: nil, files: [], title: "R1", sections: [:],
                                url: URL(fileURLWithPath: "/tmp/R1.md"))
    private var behind: Int { Int(try! git(repo, ["rev-list", "--count", "test/r1..main"])) ?? -1 }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock(); private var list: [String] = []
        var notes: [String] { lock.withLock { list } }
        func add(_ n: String) { lock.withLock { list.append(n) } }
    }

    private func make(_ sent: Sent, working: Bool = false) throws -> AutopilotModel {
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = .on
        try store.save(p, for: project.id)
        let inbox = AgentInboxModel(reader: IdleReader(), keys: IdleSender(), commander: IdleSender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store, makeDecider: { _ in NoDecider() })
        m.setProject(project)
        m.isFinished = { _ in !working }
        m.isWorking = { _ in working }
        let flow = self.flow!
        m.behindMain = { await flow.commitsBehindMain($0) }
        m.rebaseNow = { await flow.autoRebase($0, agentWorking: working) }
        m.requestFix = { _, notes in sent.add(notes); return nil }
        return m
    }

    private func run(_ m: AutopilotModel) async {
        m.process([], cards: [card])
        for _ in 0..<300 where m.records.last?.kind != AutopilotModel.rebaseKind { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testACleanRebaseIsDoneByThePanelAndTheAgentIsNotAsked() async throws {
        try mainMoves()
        XCTAssertEqual(behind, 1)
        let sent = Sent(); let m = try make(sent)
        await run(m)
        XCTAssertEqual(behind, 0)
        XCTAssertEqual(sent.notes, [])
        XCTAssertEqual(m.records.last?.result, .answered)
        XCTAssertTrue(m.records.last?.answer.hasPrefix("Rebased onto main") ?? false, m.records.last?.answer ?? "")
        XCTAssertTrue(m.records.last?.why.contains("Rebased onto main by the panel; head is ") ?? false)
        let log = (try? String(contentsOf: actionsLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("rebased test/r1 onto main for R1"), log)
    }

    func testAConflictIsAbortedAndTheAgentGetsOneNoteNamingTheFiles() async throws {
        try dir.write("repo/.agent-worktrees/test-r1/a.txt", "branch change\n")
        try git(worktree, ["commit", "-q", "-am", "edit a"])
        try mainMoves(file: "a.txt", text: "main change\n")
        let before = try git(worktree, ["rev-parse", "HEAD"])
        let sent = Sent(); let m = try make(sent)
        await run(m)
        XCTAssertEqual(sent.notes.count, 1)
        XCTAssertTrue(sent.notes.first?.contains("conflicts in: a.txt") ?? false, sent.notes.first ?? "")
        XCTAssertEqual(try git(worktree, ["rev-parse", "HEAD"]), before, "branch unchanged")
        XCTAssertEqual(try git(worktree, ["status", "--porcelain"]), "", "no rebase left half-done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try git(worktree, ["rev-parse", "--git-path", "rebase-merge"])))
        let log = (try? String(contentsOf: actionsLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("conflicts; nothing changed"), log)
    }

    func testADirtyWorktreeIsLeftAloneAndTheAgentGetsOneNote() async throws {
        try mainMoves()
        try dir.write("repo/.agent-worktrees/test-r1/wip.txt", "unsaved\n")
        let sent = Sent(); let m = try make(sent)
        await run(m)
        XCTAssertEqual(sent.notes.count, 1)
        XCTAssertTrue(sent.notes.first?.contains("unsaved changes") ?? false, sent.notes.first ?? "")
        XCTAssertEqual(behind, 1, "nothing was rebased")
        XCTAssertEqual(try git(worktree, ["status", "--porcelain"]), "?? wip.txt")
    }

    func testNothingHappensWhileTheAgentIsWorking() async throws {
        try mainMoves()
        let sent = Sent(); let m = try make(sent, working: true)
        // A working agent is never scanned; the flow refuses as well when asked directly.
        m.process([], cards: [card])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(behind, 1)
        XCTAssertEqual(sent.notes, [])
        let direct = await flow.autoRebase(card, agentWorking: true)
        XCTAssertEqual(direct, .skipped)
        XCTAssertEqual(behind, 1)
    }
}
