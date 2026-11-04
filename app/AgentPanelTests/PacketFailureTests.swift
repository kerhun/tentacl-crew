import XCTest
@testable import AgentPanel

/// N202: logs of each kind of packet failure (the first is the real N177 one from its card; the others use the wording app-test.sh and review-packet.sh print).
final class PacketFailureTests: XCTestCase {
    static let testFailure = """
    EVIDENCE MISSING: tests failed, see /Users/x/Documents/tasks/N177/build.log
    ** TEST FAILED **
    /Users/person/.cache/agent-panel/build/agent-panel/N177/app/AgentPanelTests/TestDefaultsTests.swift:29: error: -[AgentPanelTests.TestDefaultsTests testTheSuiteOfTheEarlierTestIsGone] : XCTAssertFalse failed - the preference file is removed
    failed  AgentPanelTests.TestDefaultsTests.testTheSuiteOfTheEarlierTestIsGone
    RAW  /Users/person/.cache/agent-panel/build/agent-panel/N177/app/AgentPanelTests/TestDefaultsTests.swift:29: error: -[AgentPanelTests.TestDefaultsTests testTheSuiteOfTheEarlierTestIsGone] : XCTAssertFalse failed - the preference file is removed
    RAW  ** TEST FAILED **
    RAW  \t Executed 1812 tests, with 1 test skipped and 1 failure (0 unexpected) in 79.619 (80.128) seconds
    """
    static let hostCrash = """
    EVIDENCE MISSING: tests failed, see /Users/x/tasks/N104/build.log
    failed  AgentPanelTests.SettingsFlowTests.testLoadListsTagsNewestFirstAndTheStableVersion
    RUNNER RESTARTED in build/review/test.log: the test host crashed or was killed; investigate, do not rerun and ignore
    last test started before the restart: AgentPanelTests.TeamChartModelTests.testDelete
    Executed 9 tests, with 0 failures (0 unexpected) in 0.4 (0.5) seconds
    """
    static let timeout = "EVIDENCE MISSING: waited 45 min for another packet to finish building (pid 123); run the packet again later"
    static let noTestNamed = "EVIDENCE MISSING: tests failed, see /tmp/build.log\n** TEST FAILED **\nExecuted 9 tests, with 0 failures (0 unexpected)"
    static let xcodebuildError = "EVIDENCE MISSING: tests failed, see /tmp/build.log\nerror: Unable to find a destination matching the provided destination specifier"
    static let compileError = "EVIDENCE MISSING: build failed, see /tmp/build.log\n/x/app/AgentPanel/Foo.swift:3: error: cannot find 'bar' in scope\n** BUILD FAILED **"
    static let uncommitted = "EVIDENCE MISSING: uncommitted work in the agent's worktree (ask the agent to commit or discard it)\n M a.swift"

    func testNamedFailingTestsAreTestFailuresWithFileLineMessageAndLog() throws {
        guard case .tests(let tests, let log) = PacketFailure.classify(Self.testFailure) else { return XCTFail("not tests") }
        XCTAssertEqual(tests.count, 1)
        XCTAssertEqual(tests[0].name, "AgentPanelTests.TestDefaultsTests.testTheSuiteOfTheEarlierTestIsGone")
        XCTAssertEqual(tests[0].location, "app/AgentPanelTests/TestDefaultsTests.swift:29")
        XCTAssertEqual(tests[0].message, "XCTAssertFalse failed - the preference file is removed")
        XCTAssertEqual(log, "/Users/x/Documents/tasks/N177/build.log")
        let note = PacketFailure.fixNotes(tests, log: log)
        XCTAssertTrue(note.notes.contains("1 test failed"))
        XCTAssertTrue(note.notes.contains("- AgentPanelTests.TestDefaultsTests.testTheSuiteOfTheEarlierTestIsGone — app/AgentPanelTests/TestDefaultsTests.swift:29: XCTAssertFalse failed"))
        XCTAssertTrue(note.notes.contains("Full log: /Users/x/Documents/tasks/N177/build.log"))
        XCTAssertFalse(note.notes.contains("Executed"))
        XCTAssertFalse(note.notes.contains("0 failures"))
        XCTAssertTrue(note.shown.contains("testTheSuiteOfTheEarlierTestIsGone"))
    }

    func testAHostCrashTimeoutOrXcodebuildErrorIsInfrastructure() {
        for text in [Self.hostCrash, Self.timeout, Self.noTestNamed, Self.xcodebuildError] {
            guard case .infrastructure = PacketFailure.classify(text) else { return XCTFail("not infrastructure: \(text)") }
        }
        if case .infrastructure(let reason) = PacketFailure.classify(Self.hostCrash) { XCTAssertTrue(reason.contains("RUNNER RESTARTED")) }
    }

    func testCompileErrorsAndLeftWorkStayWithTheAgentWithoutPassingSummaries() {
        for text in [Self.compileError, Self.uncommitted] {
            guard case .workLeft(let lines) = PacketFailure.classify(text) else { return XCTFail("not work left: \(text)") }
            XCTAssertFalse(lines.isEmpty)
        }
        guard case .workLeft(let lines) = PacketFailure.classify("EVIDENCE MISSING: build failed\nExecuted 9 tests, with 0 failures (0 unexpected)\nerror: x") else { return XCTFail() }
        XCTAssertFalse(lines.contains { $0.contains("0 failures") })
    }

    func testSeveralTestsAreEachNamedOnce() {
        let text = """
        EVIDENCE MISSING: tests failed, see /l.log
        /r/app/AgentPanelTests/A.swift:5: error: -[AgentPanelTests.ATests testOne] : XCTAssertEqual failed
        /r/app/AgentPanelTests/B.swift:9: error: -[AgentPanelTests.BTests testTwo] : XCTAssertTrue failed
        failed  AgentPanelTests.ATests.testOne
        failed  AgentPanelTests.BTests.testTwo
        """
        guard case .tests(let tests, _) = PacketFailure.classify(text) else { return XCTFail() }
        XCTAssertEqual(tests.map(\.name), ["AgentPanelTests.ATests.testOne", "AgentPanelTests.BTests.testTwo"])
        XCTAssertEqual(tests.map(\.location), ["app/AgentPanelTests/A.swift:5", "app/AgentPanelTests/B.swift:9"])
    }
}
