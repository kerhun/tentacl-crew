import XCTest
@testable import AgentPanel

final class ScriptRunnerTests: XCTestCase {
    /// A scripts folder where `spawn-agent.sh` has the given body and the other three scripts exist but do nothing.
    private func runner(_ dir: TempDir, body: String, timeout: TimeInterval = 10, killGrace: TimeInterval = 1,
                        extra: [String: String] = [:], shell: URL? = nil) throws -> ProcessScriptRunner {
        for name in ScriptName.allCases { try dir.write("scripts/\(name.rawValue)", "#!/bin/bash\nexit 0\n") }
        try dir.write("scripts/spawn-agent.sh", "#!/bin/bash\n\(body)\n")
        let settings = AppSettings(scriptsDir: dir.url.appendingPathComponent("scripts"), problems: [])
        var r = ProcessScriptRunner(settings: settings, timeout: timeout, killGrace: killGrace, extraEnvironment: extra)
        if let shell { r.shell = shell }
        return r
    }

    /// A review packet builds the app, which takes much longer than starting an agent.
    func testReviewPacketGetsALongerLimitThanOtherScripts() {
        let r = ProcessScriptRunner(settings: AppSettings(scriptsDir: nil, problems: []))
        XCTAssertEqual(r.limit(for: .spawn), 120)
        XCTAssertEqual(r.limit(for: .reviewPacket), 1800)
        var short = r; short.reviewPacketTimeout = 2
        XCTAssertEqual(short.limit(for: .reviewPacket), 2, "tests can shorten it")
    }

    /// N264: the packet's run limit counts from the moment it prints PACKET RUN STARTED; the wait before has its own limit.
    func testPacketRunLimitStartsAfterTheSlotWasTaken() async throws {
        let dir = try TempDir()
        let r = try runner(dir, body: "sleep 1; echo PACKET RUN STARTED; sleep 0.5; echo done")
        let url = dir.url.appendingPathComponent("scripts/spawn-agent.sh")
        // the wait (1 s) is longer than the run limit (0.9 s) and still passes
        let result = try await r.run(file: url, arguments: [], timeout: 0.9, waitTimeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("done"))
    }

    func testPacketRunLimitStillAppliesAfterTheStart() async throws {
        let dir = try TempDir()
        let r = try runner(dir, body: "echo PACKET RUN STARTED; trap '' TERM; sleep 30", killGrace: 0.3)
        let url = dir.url.appendingPathComponent("scripts/spawn-agent.sh")
        do { _ = try await r.run(file: url, arguments: [], timeout: 0.5, waitTimeout: 20); XCTFail("expected a timeout") }
        catch let e as ScriptError { XCTAssertEqual(e, .timedOut(1)) }
    }

    func testPacketWaitHasItsOwnLimitAndSaysSo() async throws {
        let dir = try TempDir()
        let r = try runner(dir, body: "echo waiting; trap '' TERM; sleep 30", killGrace: 0.3)
        let url = dir.url.appendingPathComponent("scripts/spawn-agent.sh")
        do { _ = try await r.run(file: url, arguments: [], timeout: 30, waitTimeout: 0.5); XCTFail("expected a timeout") }
        catch let e as ScriptError { XCTAssertEqual(e, .waitTimedOut(1)); XCTAssertTrue(StartTaskFlow.describe(e).contains("build slot")) }
    }

    func testPacketWaitLimitIsLongerThanTheRunLimit() {
        let r = ProcessScriptRunner(settings: AppSettings(scriptsDir: nil, problems: []))
        XCTAssertGreaterThan(r.reviewPacketWaitTimeout, 2700, "longer than the script's own slot timeout")
    }

    /// N105: a script writes where the app writes - the runner always passes TENTACL_ACTION_LOG.
    func testPassesTheGivenActionLogToTheScript() async throws {
        let dir = try TempDir()
        var r = try runner(dir, body: "echo \"$TENTACL_ACTION_LOG\"")
        r.actionLogURL = dir.url.appendingPathComponent("mine.log")
        let result = try await r.run(.spawn, arguments: [])
        XCTAssertEqual(result.stdout, dir.url.appendingPathComponent("mine.log").path + "\n")
    }

    /// Under XCTest with no log given the script gets a temporary file, never the user's real path.
    func testWithoutALogTheScriptGetsATemporaryFileUnderTest() async throws {
        let dir = try TempDir()
        let result = try await runner(dir, body: "echo \"$TENTACL_ACTION_LOG\"").run(.spawn, arguments: [])
        let seen = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(seen.isEmpty)
        XCTAssertNotEqual(seen, ActionLog.defaultURL.path)
        XCTAssertTrue(seen.hasPrefix(NSTemporaryDirectory()) || seen.hasPrefix(FileManager.default.temporaryDirectory.path), seen)
    }

    /// The scripts always use Tentacl's own terminal: no backend choice is passed to them.
    func testScriptsGetNoBackendChoice() async throws {
        let dir = try TempDir()
        let plain = try runner(dir, body: "echo \"[${AGENT_PANEL_BACKEND:-}]\"")
        let result = try await plain.run(.spawn, arguments: [])
        XCTAssertEqual(result.stdout, "[]\n")
    }

    /// An explicit extraEnvironment value still wins.
    func testExtraEnvironmentOverridesTheActionLog() async throws {
        let dir = try TempDir()
        let r = try runner(dir, body: "echo \"$TENTACL_ACTION_LOG\"", extra: ["TENTACL_ACTION_LOG": "/x/y.log"])
        let result = try await r.run(.spawn, arguments: [])
        XCTAssertEqual(result.stdout, "/x/y.log\n")
    }

    /// N280: a per-run environment reaches the script, and only that run.
    func testRunEnvironmentReachesTheScriptForThatRunOnly() async throws {
        let dir = try TempDir()
        let r = try runner(dir, body: "echo \"[${TENTACL_PM_KEY:-}]\"")
        let with = try await r.run(.spawn, arguments: [], environment: ["TENTACL_PM_KEY": "k1"])
        XCTAssertEqual(with.stdout, "[k1]\n")
        let without = try await r.run(.spawn, arguments: [])
        XCTAssertEqual(without.stdout, "[]\n")
    }

    func testReturnsStdoutStderrAndExitCode() async throws {
        let dir = try TempDir()
        let result = try await runner(dir, body: "echo out; echo err >&2; exit 3").run(.spawn, arguments: [])
        XCTAssertEqual(result, ScriptResult(status: 3, stdout: "out\n", stderr: "err\n"))
    }

    /// Review Focus 1: arguments are never joined into a shell string.
    func testArgumentsArePassedAsSeparateArguments() async throws {
        let dir = try TempDir()
        let r = runner(dir)
        let result = try await r.run(.spawn, arguments: ["a b", "c;d", "--flag", "$(echo pwned)", "x\"y", "*"])
        XCTAssertEqual(result.stdout, "[a b]\n[c;d]\n[--flag]\n[$(echo pwned)]\n[x\"y]\n[*]\n")
    }

    func testUnconfiguredScriptThrowsNotConfigured() async throws {
        let r = ProcessScriptRunner(settings: AppSettings(scriptsDir: nil, problems: []))
        do { _ = try await r.run(.spawn, arguments: []); XCTFail("expected an error") }
        catch let e as ScriptError { XCTAssertEqual(e, .notConfigured("spawn-agent.sh")) }
    }

    func testTimeoutKillsScriptIgnoringTerm() async throws {
        let dir = try TempDir()
        let r = try runner(dir, body: "trap '' TERM; sleep 30", timeout: 0.3, killGrace: 0.3)
        let started = Date()
        do { _ = try await r.run(.spawn, arguments: []); XCTFail("expected a timeout") }
        catch let e as ScriptError { XCTAssertEqual(e, .timedOut(1)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// I2: a timeout must stop the script's children too (the terminal, simctl…), not just bash. Foundation's terminate() already
    /// signals the whole group; this script and its child both ignore SIGTERM, so only the SIGKILL fallback can stop them.
    /// No sleep-vs-deadline race: the child records its pid as soon as it runs and sleeps far longer than the test waits,
    /// so the test checks that exact process is gone. The timeout leaves room for a loaded machine to start the child.
    func testTimeoutKillsTheWholeProcessGroup() async throws {
        let dir = try TempDir()
        let pidFile = dir.url.appendingPathComponent("child.pid").path
        let body = "trap '' TERM; /bin/bash -c 'echo $$ > \"$PIDFILE\"; exec sleep 60' & wait"
        let r = try runner(dir, body: body, timeout: 3, killGrace: 0.3, extra: ["PIDFILE": pidFile])
        do { _ = try await r.run(.spawn, arguments: []); XCTFail("expected a timeout") } catch let e as ScriptError { XCTAssertEqual(e, .timedOut(3)) }
        let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(text), "the child never recorded its pid, so it was not running when the timeout hit")
        var alive = true
        for _ in 0..<100 where alive {   // SIGKILL is already sent; wait for the kernel to reap it (up to 10 s)
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertFalse(alive, "the script's background child survived the timeout and kept running")
        if alive { kill(pid, SIGKILL) }
    }

    /// N61: cancelling the awaiting Task stops the child (even one that ignores SIGTERM) and throws a cancellation error.
    func testCancellingTheTaskStopsTheChild() async throws {
        let dir = try TempDir()
        let pidFile = dir.url.appendingPathComponent("child.pid").path
        let body = "trap '' TERM; echo $$ > \"$PIDFILE\"; sleep 60 & wait"
        let r = try runner(dir, body: body, timeout: 60, killGrace: 0.3, extra: ["PIDFILE": pidFile])
        let task = Task { try await r.run(.spawn, arguments: []) }
        var text = ""
        for _ in 0..<100 where text.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            text = ((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pid = try XCTUnwrap(pid_t(text))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        var alive = true
        for _ in 0..<50 where alive { alive = kill(pid, 0) == 0; if alive { try await Task.sleep(for: .milliseconds(100)) } }
        XCTAssertFalse(alive, "the script survived the cancellation")
        if alive { kill(pid, SIGKILL) }
    }

    func testLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let dir = try TempDir()
        let result = try await runner(dir, body: "yes | head -c 300000; yes e | head -c 200000 >&2").run(.spawn, arguments: [])
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testEnvironmentGetsExtendedPath() async throws {
        let dir = try TempDir()
        let result = try await runner(dir, body: "echo \"$PATH\"").run(.spawn, arguments: [])
        XCTAssertTrue(result.stdout.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.stdout.contains(".local/bin"))
        XCTAssertTrue(result.stdout.contains("/usr/bin"))
    }

    func testExtraEnvironmentIsPassed() async throws {
        let dir = try TempDir()
        let result = try await runner(dir, body: "echo \"$MY_FLAG\"", extra: ["MY_FLAG": "on"]).run(.spawn, arguments: [])
        XCTAssertEqual(result.stdout, "on\n")
    }

    func testScriptCannotReadStdin() async throws {
        let dir = try TempDir()
        let result = try await runner(dir, body: "cat; echo done", timeout: 5).run(.spawn, arguments: [])
        XCTAssertEqual(result.stdout, "done\n")
    }

    func testLaunchFailureIsReported() async throws {
        let dir = try TempDir()
        let r = try runner(dir, body: "echo hi", shell: URL(fileURLWithPath: "/nonexistent/bash"))
        do { _ = try await r.run(.spawn, arguments: []); XCTFail("expected an error") }
        catch let e as ScriptError { guard case .launchFailed = e else { return XCTFail("wrong error \(e)") } }
    }
}

private extension ScriptRunnerTests {
    /// Runner whose spawn script prints each argument in brackets, one per line.
    func runner(_ dir: TempDir) -> ProcessScriptRunner {
        try! runner(dir, body: "for a in \"$@\"; do echo \"[$a]\"; done")
    }
}
