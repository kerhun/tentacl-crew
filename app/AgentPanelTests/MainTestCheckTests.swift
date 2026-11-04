import XCTest
@testable import AgentPanel

/// N214: the main check with a fake runner; no real checkout of main.
final class MainTestCheckTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        var list: [[String]] { lock.withLock { all } }
        func add(_ a: [String]) { lock.withLock { all.append(a) } }
    }

    private func check(_ dir: TempDir, scriptExists: Bool = true, checkoutStatus: Int32 = 0, test: (status: Int32, output: String), calls: Calls) -> MainTestCheck {
        let folder = dir.url.appendingPathComponent("main-check")
        return MainTestCheck(repo: "/repo", base: "main", folder: folder, exec: { args, cwd in
            calls.add(args)
            if args.prefix(3) == ["git", "worktree", "add"] {
                if checkoutStatus == 0 {
                    try? FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
                    if scriptExists { FileManager.default.createFile(atPath: folder.appendingPathComponent("scripts/app-test.sh").path, contents: Data()) }
                }
                return (checkoutStatus, checkoutStatus == 0 ? "" : "fatal: invalid reference: main")
            }
            if args.first == "bash" { return test }
            return (0, "")
        })
    }

    func testTheNamedTestsRunOnMainOnlyAndTheCheckoutIsRemoved() async throws {
        let dir = try TempDir(), calls = Calls()
        let out = "** TEST FAILED **\nfailed  AgentPanelTests.AFlowTests.testOne"
        let result = await check(dir, test: (1, out), calls: calls).run(["AgentPanelTests.AFlowTests.testOne", "BFlowTests.testTwo"])
        XCTAssertEqual(result, .failing(["AgentPanelTests.AFlowTests.testOne"]))
        let run = try XCTUnwrap(calls.list.first { $0.first == "bash" })
        XCTAssertEqual(run, ["bash", "scripts/app-test.sh", "-only-testing:AgentPanelTests/AFlowTests/testOne", "-only-testing:AgentPanelTests/BFlowTests/testTwo"])
        XCTAssertTrue(calls.list.contains { $0.prefix(3) == ["git", "worktree", "remove"] })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("main-check").path))
    }

    func testAPassingRunMeansNoneFailOnMain() async throws {
        let dir = try TempDir()
        let result = await check(dir, test: (0, "Executed 2 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **"), calls: Calls()).run(["A.b"])
        XCTAssertEqual(result, .failing([]))
    }

    func testABrokenRunIsUnavailableAndStillCleansUp() async throws {
        let dir = try TempDir(), calls = Calls()
        let result = await check(dir, test: (1, PacketFailureTests.hostCrash), calls: calls).run(["A.b"])
        guard case .unavailable = result else { return XCTFail("\(result)") }
        XCTAssertTrue(calls.list.contains { $0.prefix(3) == ["git", "worktree", "remove"] })
    }

    func testACheckoutThatFailsOrHasNoTestScriptIsUnavailable() async throws {
        let dir = try TempDir()
        let r1 = await check(dir, checkoutStatus: 128, test: (0, ""), calls: Calls()).run(["A.b"])
        guard case .unavailable(let reason) = r1 else { return XCTFail("\(r1)") }
        XCTAssertTrue(reason.contains("main"))
        let r2 = await check(dir, scriptExists: false, test: (0, ""), calls: Calls()).run(["A.b"])
        guard case .unavailable = r2 else { return XCTFail("\(r2)") }
    }

    func testSplitMatchesOnClassAndTestName() {
        let tests = [PacketFailure.FailedTest(name: "AgentPanelTests.A.one"), PacketFailure.FailedTest(name: "AgentPanelTests.B.two")]
        let split = PacketFailure.split(tests, failingOnMain: ["B.two"])
        XCTAssertEqual(split.own.map(\.name), ["AgentPanelTests.A.one"])
        XCTAssertEqual(split.onMain.map(\.name), ["AgentPanelTests.B.two"])
    }
}
