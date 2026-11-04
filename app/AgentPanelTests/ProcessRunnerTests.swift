import XCTest
@testable import AgentPanel

final class ProcessRunnerTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testNormalOutputIsReturned() async throws {
        let data = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/echo"), ["hi"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hi\n")
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let data = try await ProcessRunner().run(sh, ["-c", "yes | head -c 300000"])
        XCTAssertEqual(data.count, 300_000)
    }

    /// A process that ignores SIGTERM must still be stopped (SIGKILL after a grace period).
    func testTimeoutKillsProcessThatIgnoresTerm() async throws {
        let runner = ProcessRunner(timeout: 0.3, killGrace: 0.3)
        let started = Date()
        do { _ = try await runner.run(sh, ["-c", "trap '' TERM; sleep 30"]); XCTFail("expected a timeout") }
        catch { XCTAssertTrue("\(error)".contains("did not finish") || (error as? LocalizedError)?.errorDescription?.contains("did not finish") == true) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A child that inherited stdout and keeps the pipe open must not make the caller wait for it.
    func testTimeoutDoesNotWaitForAChildHoldingThePipe() async throws {
        let runner = ProcessRunner(timeout: 0.3, killGrace: 0.3)
        let started = Date()
        _ = try? await runner.run(sh, ["-c", "sleep 20 & wait"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// N61: cancelling the awaiting Task stops the process (even one that ignores SIGTERM).
    func testCancellingTheTaskStopsTheProcess() async throws {
        let pidFile = NSTemporaryDirectory() + "pr-cancel-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let runner = ProcessRunner(timeout: 60, killGrace: 0.3)
        let task = Task { try await runner.run(sh, ["-c", "trap '' TERM; echo $$ > \(pidFile); sleep 60 & wait"]) }
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
        XCTAssertFalse(alive, "the process survived the cancellation")
        if alive { kill(pid, SIGKILL) }
    }

    func testCrashIsNotReportedAsTimeout() async throws {
        do { _ = try await ProcessRunner().run(sh, ["-c", "kill -9 $$"]); XCTFail("expected an error") }
        catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertFalse(text.contains("did not finish"), text)
            XCTAssertTrue(text.contains("signal"), text)
        }
    }
}
