import XCTest
@testable import AgentPanel

/// N209: the merge queue runs one merge at a time in the order asked, keeps what became of each, waits for a merge made by merge-queue.sh,
/// and the real script merges a throwaway card in a temporary repository through the queue.
@MainActor
final class MergeQueueTests: XCTestCase {
    /// Records how many `work` closures run at once and in what order they started.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var maxRunning = 0
        private(set) var order: [String] = []
        func enter(_ name: String) { lock.withLock { running += 1; maxRunning = max(maxRunning, running); order.append(name) } }
        func leave() { lock.withLock { running -= 1 } }
    }

    private func work(_ name: String, _ probe: Probe, _ outcome: MergeOutcome = .merged(detail: nil)) -> () async -> MergeOutcome {
        { probe.enter(name); try? await Task.sleep(for: .milliseconds(40)); probe.leave(); return outcome }
    }

    func testMergesNeverRunTogetherAndKeepTheOrder() async {
        let q = MergeQueue(), probe = Probe()
        async let a = q.run(project: "p", card: "A", branch: "task/a", work: work("A", probe))
        async let b = q.run(project: "q", card: "B", branch: "task/b", work: work("B", probe))
        async let c = q.run(project: "p", card: "C", branch: "task/c", work: work("C", probe))
        _ = await (a, b, c)
        XCTAssertEqual(probe.maxRunning, 1)
        XCTAssertEqual(Set(probe.order), ["A", "B", "C"])
        XCTAssertFalse(q.isRunning)
        XCTAssertEqual(q.items.map(\.card).sorted(), ["A", "B", "C"])
    }

    func testAFailureIsKeptWithItsReasonAndTheNextOneStillRuns() async {
        let q = MergeQueue(), probe = Probe()
        async let a = q.run(project: "p", card: "A", branch: "task/a", work: work("A", probe, .failed("the repository is on dev")))
        async let b = q.run(project: "p", card: "B", branch: "task/b", work: work("B", probe, .merged(detail: "abc1234 stable-4")))
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra.failure, "the repository is on dev")
        XCTAssertNil(rb.failure)
        XCTAssertEqual(q.items.first { $0.card == "A" }?.state, .failed(reason: "the repository is on dev"))
        XCTAssertEqual(q.items.first { $0.card == "B" }?.state, .done(detail: "abc1234 stable-4"))
        XCTAssertNotNil(q.items.first { $0.card == "A" }?.finishedAt)
    }

    func testAWaitingItemShowsWaitingWhileTheFirstRuns() async throws {
        let q = MergeQueue(), probe = Probe()
        let first = Task { await q.run(project: "p", card: "A", branch: "task/a", work: { try? await Task.sleep(for: .milliseconds(300)); return .merged(detail: nil) }) }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { await q.run(project: "p", card: "B", branch: "task/b", work: work("B", probe)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(q.items.first { $0.card == "A" }?.state, .running)
        XCTAssertEqual(q.items.first { $0.card == "B" }?.state, .waiting)
        XCTAssertTrue(q.isRunning(project: "p"))
        XCTAssertFalse(q.isRunning(project: "other"))
        _ = await (first.value, second.value)
        XCTAssertEqual(q.items.first { $0.card == "B" }?.state, .done(detail: nil))
    }

    func testWaitsForAMergeMadeByTheScript() async throws {
        let q = MergeQueue(), probe = Probe()
        var external = true
        q.externalMerge = { external }
        q.externalPoll = .milliseconds(20)
        let task = Task { await q.run(project: "p", card: "A", branch: "task/a", work: work("A", probe)) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(q.items.first?.state, .waiting)
        XCTAssertNotNil(q.items.first?.waitNote)
        XCTAssertTrue(probe.order.isEmpty)
        external = false
        _ = await task.value
        XCTAssertEqual(probe.order, ["A"])
    }

    func testOnlyTheLastTenFinishedItemsAreKept() async {
        let q = MergeQueue()
        for i in 0..<14 { await q.run(project: "p", card: "N\(i)", branch: "task/n\(i)", work: { .merged(detail: nil) }) }
        XCTAssertEqual(q.items.count, MergeQueue.keepFinished)
        XCTAssertEqual(q.items.last?.card, "N13")
    }

    func testLastStableIsTheHighestNumber() {
        XCTAssertEqual(MergeQueue.lastStable(in: ["stable-9", "v1", "stable-12", "stable-x", "stable-3"]), "stable-12")
        XCTAssertNil(MergeQueue.lastStable(in: ["v1"]))
    }

    func testParsesTheResultLine() {
        let r = MergeQueue.parseResult("N209 merged abc1234 stable-7")
        XCTAssertEqual(r?.card, "N209"); XCTAssertEqual(r?.sha, "abc1234"); XCTAssertEqual(r?.tag, "stable-7")
        XCTAssertNil(MergeQueue.parseResult("N209 needs a fix; not merged"))
    }

    func testScriptLockIsHeldOnlyWhileItsProcessLives() throws {
        let dir = try TempDir()
        XCTAssertFalse(MergeQueue.scriptLockHeld(buildRoot: dir.url))
        try dir.write(".merge-queue.lock/pid", "\(ProcessInfo.processInfo.processIdentifier)\n")
        XCTAssertTrue(MergeQueue.scriptLockHeld(buildRoot: dir.url))
        try dir.write(".merge-queue.lock/pid", "999999\n")
        XCTAssertFalse(MergeQueue.scriptLockHeld(buildRoot: dir.url))
    }

    func testInstallCommandNamesTheScriptTheRepositoryAndTheTag() {
        let c = MergeQueue.installCommand(scriptsDir: URL(fileURLWithPath: "/s"), repoPath: "/r", tag: "stable-5")
        XCTAssertEqual(c.arguments, ["/s/release-stable.sh", "--source", "/r", "stable-5"])
        XCTAssertEqual(MergeQueue.installText(repoPath: "/r", tag: "stable-5"), "release-stable.sh --source /r stable-5")
    }

    // MARK: the app's lock

    func testWhileTheAppMergesTheScriptWaitsAndGivesUp() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = try TempDir()
        let project = try dir.write("project.json", "{\"id\":\"t\",\"repoPath\":\"\(dir.url.path)\",\"dataDir\":\"\(dir.url.path)\"}")
        try dir.write("tasks/T1.md", "---\nid: T1\nstatus: review\n---\n")
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent(".agent-worktrees/task-t1"), withIntermediateDirectories: true)
        let q = MergeQueue(lockRoot: dir.url.appendingPathComponent("build"))
        let script = root.appendingPathComponent("scripts/merge-queue.sh").path
        let result = await q.run(project: "t", card: "T1", branch: "task/t1") { () -> MergeOutcome in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script, project.path, "T1"]
            p.environment = ProcessInfo.processInfo.environment.merging(["AGENT_PANEL_BUILD_ROOT": dir.url.appendingPathComponent("build").path,
                                                                        "MERGE_QUEUE_LOCK_TIMEOUT": "1", "MERGE_QUEUE_POLL": "1",
                                                                        "TENTACL_ACTION_LOG": dir.url.appendingPathComponent("actions.log").path]) { $1 }
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return p.terminationStatus == 14 && text.contains("another merge is running") ? .merged(detail: "waited") : .failed("exit \(p.terminationStatus): \(text)")
        }
        XCTAssertNil(result.failure)
    }

    func testTheLockIsTakenWhileAnItemRunsAndGoneAfterAFailure() async throws {
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("build")
        let lock = root.appendingPathComponent(".merge-queue.lock")
        let q = MergeQueue(lockRoot: root)
        await q.run(project: "p", card: "A", branch: "task/a") {
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.appendingPathComponent("pid").path))
            XCTAssertTrue(MergeQueue.scriptLockHeld(buildRoot: root))
            return .failed("boom")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertEqual(q.items.last?.state, .failed(reason: "boom"))
    }

    func testAStaleLockOfADeadProcessIsTakenOver() async throws {
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("build")
        try dir.write("build/.merge-queue.lock/pid", "999999\n")
        let q = MergeQueue(lockRoot: root)
        let r = await q.run(project: "p", card: "A", branch: "task/a") { .merged(detail: nil) }
        XCTAssertNil(r.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".merge-queue.lock").path))
    }

    func testALiveLockOfTheScriptMakesTheAppWait() async throws {
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("build")
        try dir.write("build/.merge-queue.lock/pid", "\(ProcessInfo.processInfo.processIdentifier)\n")
        let q = MergeQueue(lockRoot: root); q.externalPoll = .milliseconds(20)
        let probe = Probe()
        let task = Task { await q.run(project: "p", card: "A", branch: "task/a", work: work("A", probe)) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(probe.order.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".merge-queue.lock"))
        _ = await task.value
        XCTAssertEqual(probe.order, ["A"])
    }

    // MARK: real script on a throwaway card

    private func git(_ at: URL, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", at.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheScriptMergesAThrowawayCardThroughTheQueue() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = try TempDir()
        let repo = dir.url.appendingPathComponent("repo"), data = dir.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try git(repo, ["init", "-q", "-b", "main"])
        try dir.write("repo/a.txt", "a\n"); try dir.write("repo/.gitignore", ".agent-worktrees\n")
        _ = try git(repo, ["add", "."]); _ = try git(repo, ["commit", "-q", "-m", "init"])
        let wt = repo.appendingPathComponent(".agent-worktrees/task-t1")
        _ = try git(repo, ["worktree", "add", "-q", "-b", "task/t1", wt.path])
        try dir.write("repo/.agent-worktrees/task-t1/b.txt", "b\n")
        _ = try git(wt, ["add", "."]); _ = try git(wt, ["commit", "-q", "-m", "work"])
        let head = try git(wt, ["rev-parse", "HEAD"])
        let card = try dir.write("data/tasks/T1.md", "---\nid: T1\nstatus: review\nbranch: task/t1\n---\n# T1\n## Review packet\nHead: \(head)\nBuild: passed\n")
        let project = try dir.write("project.json", "{\"id\":\"tmp\",\"name\":\"Tmp\",\"repoPath\":\"\(repo.path)\",\"dataDir\":\"\(data.path)\"}")

        let actionLog = dir.url.appendingPathComponent("actions.log")   // never the real log (N221)
        // No `agent:` on the card, so the script closes no terminal; the rest of its steps run for real.
        let q = MergeQueue()
        let outcome = await q.run(project: "tmp", card: "T1", branch: "task/t1") {
            let r = await ProcessToolRunner(timeout: 60).run(URL(fileURLWithPath: "/usr/bin/env"), ["TENTACL_ACTION_LOG=\(actionLog.path)", "/bin/bash", root.appendingPathComponent("scripts/merge-queue.sh").path, project.path, "T1"])
            let line = r.stdout.split(separator: "\n").last.map(String.init) ?? ""
            guard r.status == 0, let done = MergeQueue.parseResult(line) else { return .failed(line.isEmpty ? r.stderr : line) }
            return .merged(detail: "\(done.sha) \(done.tag)")
        }
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(q.items.last?.state, .done(detail: "\(head.prefix(7)) stable-1"))
        XCTAssertEqual(try git(repo, ["rev-parse", "stable-1"]), head)
        XCTAssertTrue((try? String(contentsOf: actionLog))?.contains("[tmp] merged T1 \(head) (script)") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("b.txt").path))
        XCTAssertTrue(try String(contentsOf: card, encoding: .utf8).contains("status: done"))
    }
}
