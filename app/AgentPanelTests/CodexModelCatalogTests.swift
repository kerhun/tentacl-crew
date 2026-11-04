import XCTest
@testable import AgentPanel

final class CodexModelCatalogTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func fixtureData() throws -> Data { try Data(contentsOf: Fixture.url("codex/debug_models.json")) }

    func testParsesOnlyListedModelsInOrderWithEfforts() throws {
        let catalog = CodexModelCatalog.parse(try fixtureData())
        XCTAssertNil(catalog.reason)
        XCTAssertEqual(catalog.models.map(\.id), ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.2"])
        let sol = try XCTUnwrap(catalog.models.first)
        XCTAssertEqual(sol.label, "GPT-5.6-Sol")
        XCTAssertEqual(sol.efforts, ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(sol.defaultEffort, "low")
        XCTAssertEqual(catalog.models.first { $0.id == "gpt-5.6-terra" }?.defaultEffort, "medium")
    }

    func testChoiceHasTheShapeOfTheClaudeList() throws {
        let choices = CodexModelCatalog.parse(try fixtureData()).choices
        XCTAssertEqual(choices.first, ModelChoice(id: "gpt-5.6-sol", label: "GPT-5.6-Sol", group: CodexModelCatalog.group))
    }

    func testDefaultEffortOutsideTheListFallsBackToTheFirstSupported() {
        let json = #"{"models":[{"slug":"m","display_name":"M","visibility":"list","default_reasoning_level":"zzz","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}"#
        XCTAssertEqual(CodexModelCatalog.parse(Data(json.utf8)).models.first?.defaultEffort, "low")
    }

    func testParseFailureGivesEmptyCatalogWithReason() {
        for text in ["", "not json", "[]", #"{"models":"x"}"#, #"{"models":[]}"#, #"{"models":[{"slug":"h","visibility":"hide"}]}"#] {
            let catalog = CodexModelCatalog.parse(Data(text.utf8))
            XCTAssertTrue(catalog.models.isEmpty, text)
            XCTAssertNotNil(catalog.reason, text)
        }
    }

    func testMissingCodexGivesEmptyCatalogWithReason() async {
        let catalog = await CodexModelCatalog(executable: nil).load()
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertEqual(catalog.reason, "codex is not installed (or not on PATH)")
    }

    func testRunsTheExecutableWithDebugModels() async throws {
        let fixture = Fixture.url("codex/debug_models.json").path
        let script = try dir.write("codex", "#!/bin/sh\n[ \"$1 $2\" = \"debug models\" ] && cat '\(fixture)' || exit 3\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let catalog = await CodexModelCatalog(executable: script).load()
        XCTAssertNil(catalog.reason)
        XCTAssertEqual(catalog.models.count, 5)
    }

    func testFailingExecutableGivesReason() async throws {
        let script = try dir.write("codex", "#!/bin/sh\necho boom >&2\nexit 2\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let catalog = await CodexModelCatalog(executable: script).load()
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertTrue(catalog.reason?.contains("boom") == true, catalog.reason ?? "nil")
    }

    func testSuccessIsCachedAndFailureIsRetried() async throws {
        let counter = dir.url.appendingPathComponent("count")
        let fixture = Fixture.url("codex/debug_models.json").path
        let script = try dir.write("codex", "#!/bin/sh\necho x >> '\(counter.path)'\ncat '\(fixture)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let catalog = CodexModelCatalog(executable: script)
        _ = await catalog.load(); _ = await catalog.load()
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 1)
        _ = await catalog.load(refresh: true)
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 2)

        let missing = CodexModelCatalog(executable: nil)
        _ = await missing.load()
        XCTAssertNil(missing.cached, "an empty result is not cached")
    }
}
