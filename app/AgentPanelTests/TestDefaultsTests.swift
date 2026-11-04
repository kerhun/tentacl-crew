import XCTest
@testable import AgentPanel

/// A test's defaults suite is gone, with its preference file, when the test is done (N116).
final class TestDefaultsTests: XCTestCase {
    nonisolated(unsafe) private static var earlier = ""

    func testDiscardingASuiteRemovesItsDomainAndFile() {
        let name = TestDefaults.newName(prefix: "agent-panel-tests-probe")
        let d = TestDefaults.open(name)
        d.set("x", forKey: "k")
        XCTAssertEqual(d.string(forKey: "k"), "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TestDefaults.fileURL(of: name).deletingLastPathComponent().path))
        TestDefaults.discard(d, name: name)
        XCTAssertTrue(UserDefaults.standard.persistentDomain(forName: name)?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TestDefaults.fileURL(of: name).path))
    }

    func testASuiteMadeByTheHelperWorksAndIsRemembered() {
        let d = makeTestDefaults(prefix: "agent-panel-tests-probe")
        d.set(3, forKey: "n")
        XCTAssertEqual(d.integer(forKey: "n"), 3)
        Self.earlier = TestDefaults.lastName
    }

    /// Runs after the test above (XCTest runs a class's tests in name order): its teardown has removed the suite.
    func testTheSuiteOfTheEarlierTestIsGone() throws {
        try XCTSkipIf(Self.earlier.isEmpty, "the earlier test did not run")
        // The teardown of the earlier test made the removal final: the file is gone and stays gone.
        let path = TestDefaults.fileURL(of: Self.earlier).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the preference file is removed")
        // The preference daemon rewrote a removed domain's file about a second later (seen 1.0 to 1.7 s) when it lived in ~/Library/Preferences.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the preference file stays removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path), "and so does its folder")
        XCTAssertTrue(UserDefaults.standard.persistentDomain(forName: Self.earlier)?.isEmpty ?? true)
    }
}

/// A model built under XCTest never registers real power observers (N116).
@MainActor
final class InertPowerTests: XCTestCase {
    func testTheInertEnvironmentReportsAPluggedInMacAndNeverCallsBack() {
        XCTAssertTrue(PanelModel.runsUnderXCTest)
        let env = InertPowerEnvironment()
        var calls = 0
        env.start(onChange: { calls += 1 }, willSleep: { calls += 1 }, didWake: { calls += 1 })
        XCTAssertFalse(env.snapshot.onBattery)
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(PanelModel.isolatedForTests().sleepGuard)
    }
}
