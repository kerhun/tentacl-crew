import XCTest
@testable import AgentPanel

/// N93: tests must never reach the user's real action log, defaults or roles folder.
@MainActor
final class PanelModelIsolationTests: XCTestCase {
    private func realLogText() -> String { (try? String(contentsOf: ActionLog.defaultURL, encoding: .utf8)) ?? "" }

    /// A PanelModel built without log, defaults or roles under XCTest must hit the guard, once for each.
    func testBuildingAPanelWithRealDefaultsUnderTestIsRefused() async throws {
        let dir = try TempDir()
        var refused: [String] = []
        let original = PanelModel.onRealDefaultUnderTest
        PanelModel.onRealDefaultUnderTest = { refused.append($0) }
        defer { PanelModel.onRealDefaultUnderTest = original }
        _ = PanelModel(settingsURL: dir.url.appendingPathComponent("projects.json"), makeTerminal: { FakeTerminal() }, opener: RecordingOpener())
        XCTAssertEqual(refused.sorted(), ["UserDefaults", "action log", "roles folder"])
    }

    /// Runs a model the way the other tests do (an asked line in the log) and checks the real log did not change.
    func testAPanelBuiltTheUsualWayDoesNotWriteTheRealLog() async throws {
        let before = realLogText()
        let dir = try TempDir()
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: dir.url.appendingPathComponent("projects.json"), makeTerminal: { FakeTerminal() }, opener: RecordingOpener(),
                           log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        m.actionLog.append("asked B1", project: "b")
        await m.reload()
        XCTAssertTrue(iso.log.read().contains("asked B1"))
        XCTAssertEqual(realLogText(), before, "the user's real actions.log must stay untouched by tests")
    }

    /// N105: a script run through the default runner under test (merge-task.sh appends a `merged … (script)` line to TENTACL_ACTION_LOG) must not reach the real log.
    func testAScriptRunThroughTheDefaultRunnerDoesNotWriteTheRealLog() async throws {
        let before = realLogText()
        let dir = try TempDir()
        try dir.write("scripts/spawn-agent.sh", "#!/bin/bash\necho \"${TENTACL_ACTION_LOG:-unset}\"\n")
        let runner = ProcessScriptRunner(settings: AppSettings(scriptsDir: dir.url.appendingPathComponent("scripts"), problems: []))
        let seen = try await runner.run(.spawn, arguments: []).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(seen, "unset", "the script must be told where to log")
        XCTAssertNotEqual(seen, ActionLog.defaultURL.path)
        XCTAssertEqual(realLogText(), before, "a script started by the panel under test must not write the user's real actions.log")
    }
}
