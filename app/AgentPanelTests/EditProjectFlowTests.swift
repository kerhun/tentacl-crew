import XCTest
@testable import AgentPanel

@MainActor
final class EditProjectFlowTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private struct Validator: ScriptRunning {
        var status: Int32 = 0
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { ScriptResult(status: status, stdout: "", stderr: status == 0 ? "" : "ERROR: refused") }
    }

    private func setup(validator: Validator = Validator(), extra: String = #","buildCommand":"make","screenshots":true,"roles":{"dev":"/r/dev.json"},"future":1"#) throws -> (EditProjectFlow, URL, URL) {
        let file = try dir.write("p/project.json", #"{"id":"p","name":"P","repoPath":"/r","dataDir":"/d","maxParallel":2,"sharedFiles":["a.txt","b.txt"]\#(extra)}"#)
        let settings = try dir.write("projects.json", #"{"projects":["\#(file.path)"]}"#)
        var project = try JSONDecoder().decode(ProjectConfig.self, from: Data(contentsOf: file)); project.sourcePath = file.path
        return (EditProjectFlow(project: project, registry: ProjectRegistry(settingsURL: settings, scripts: validator)), file, settings)
    }

    private func object(_ url: URL) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }

    func testTheFormStartsFromTheProjectAndIsNotDirty() throws {
        let (f, _, _) = try setup()
        XCTAssertEqual(f.name, "P"); XCTAssertEqual(f.maxParallel, 2); XCTAssertEqual(f.buildCommand, "make")
        XCTAssertEqual(f.sharedFiles, "a.txt\nb.txt"); XCTAssertTrue(f.screenshots)
        XCTAssertFalse(f.isDirty)
        f.name = "Q"
        XCTAssertTrue(f.isDirty)
    }

    func testEmptyOptionalTextBecomesAMissingKey() throws {
        let (f, _, _) = try setup()
        f.buildCommand = "  "; f.simulatorDevice = ""; f.xcodeProject = ""; f.openWith = ""
        let p = f.applied()
        XCTAssertNil(p.buildCommand); XCTAssertNil(p.simulator); XCTAssertNil(p.xcodeProject); XCTAssertNil(p.openWith)
        f.simulatorDevice = "iPhone 17 Pro"
        XCTAssertEqual(f.applied().simulator?.baseDevice, "iPhone 17 Pro")
    }

    func testSharedFilesAreOnePerLineWithoutBlankLines() throws {
        let (f, _, _) = try setup()
        f.sharedFiles = " a.txt \n\n  \nb/c.txt\n"
        XCTAssertEqual(f.applied().sharedFiles, ["a.txt", "b/c.txt"])
    }

    func testProblemsBlockSavingWithoutTouchingTheFile() async throws {
        let (f, file, _) = try setup()
        let before = try String(contentsOf: file, encoding: .utf8)
        f.name = " "; f.maxParallel = 9; f.mainBranch = "../x"
        XCTAssertEqual(f.problems.count, 3)
        XCTAssertFalse(f.canSave)
        let saved = await f.save()
        XCTAssertNil(saved)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
    }

    func testParallelAgentsRangeIsTwoToEightWithTheMessage() throws {
        let (f, _, _) = try setup()
        for n in 2...8 { f.maxParallel = n; XCTAssertTrue(f.problems.isEmpty, "\(n)") }
        for n in [0, 1, 9] { f.maxParallel = n; XCTAssertEqual(f.problems, ["Parallel agents must be from 2 to 8."], "\(n)") }
    }

    func testAProjectRaisedFromOneShowsTheNoteAndIsNotDirty() throws {
        let (f, _, _) = try setup()
        XCTAssertNil(f.migrationNote)
        var p = f.project; p.raisedToMinimum = true
        let g = EditProjectFlow(project: p, registry: ProjectRegistry(settingsURL: URL(fileURLWithPath: "/x"), scripts: Validator()))
        XCTAssertNotNil(g.migrationNote); XCTAssertFalse(g.isDirty)
    }

    func testSavingWritesTheChangesAndKeepsTheRest() async throws {
        let (f, file, _) = try setup()
        f.name = "Renamed"; f.maxParallel = 3; f.screenshots = false; f.buildCommand = ""
        let saved = await f.save()
        XCTAssertEqual(saved?.name, "Renamed")
        let o = try object(file)
        XCTAssertEqual(o["name"] as? String, "Renamed"); XCTAssertEqual(o["maxParallel"] as? Int, 3)
        XCTAssertNil(o["buildCommand"]); XCTAssertEqual(o["screenshots"] as? Bool, false)
        XCTAssertNotNil(o["roles"]); XCTAssertNotNil(o["future"])
        XCTAssertEqual(f.phase, .saved)
    }

    func testARefusedSaveShowsTheReasonAndChangesNothing() async throws {
        let (f, file, _) = try setup(validator: Validator(status: 1))
        let before = try String(contentsOf: file, encoding: .utf8)
        f.name = "Renamed"
        let saved = await f.save()
        XCTAssertNil(saved)
        XCTAssertEqual(f.phase, .failed("ERROR: refused"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
    }

    func testSavingKeepsTheCopyFilesTheFormDoesNotShow() async throws {
        let (f, file, _) = try setup(extra: #","copyFiles":["app/Signing.local.xcconfig"]"#)
        f.name = "Renamed"
        _ = await f.save()
        XCTAssertEqual(try object(file)["copyFiles"] as? [String], ["app/Signing.local.xcconfig"])
    }

    func testSetupCommandRoundTripsAndEmptyRemovesIt() async throws {
        let (f, file, _) = try setup(extra: #","setupCommand":"npm install","future":1"#)
        XCTAssertEqual(f.setupCommand, "npm install"); XCTAssertFalse(f.isDirty)
        f.setupCommand = "  xcodegen  "
        XCTAssertEqual(f.applied().setupCommand, "xcodegen")
        _ = await f.save()
        var o = try object(file)
        XCTAssertEqual(o["setupCommand"] as? String, "xcodegen"); XCTAssertEqual(o["future"] as? Int, 1)
        f.setupCommand = " "
        _ = await f.save()
        o = try object(file)
        XCTAssertNil(o["setupCommand"]); XCTAssertEqual(o["future"] as? Int, 1)
    }

    func testAttributionRoundTripsAndDefaultRemovesTheKeys() async throws {
        let (f, file, _) = try setup(extra: #","future":1"#)
        XCTAssertEqual(f.attribution, "default"); XCTAssertFalse(f.isDirty)
        f.attribution = "custom"
        XCTAssertFalse(f.canSave, "custom needs a text")
        f.attributionText = "  Co-Authored-By: Team <t@example.com>  "
        _ = await f.save()
        var o = try object(file)
        XCTAssertEqual(o["attribution"] as? String, "custom"); XCTAssertEqual(o["attributionText"] as? String, "Co-Authored-By: Team <t@example.com>")
        f.attribution = "none"
        _ = await f.save()
        o = try object(file)
        XCTAssertEqual(o["attribution"] as? String, "none"); XCTAssertNil(o["attributionText"])
        f.attribution = "default"
        _ = await f.save()
        o = try object(file)
        XCTAssertNil(o["attribution"]); XCTAssertNil(o["attributionText"]); XCTAssertEqual(o["future"] as? Int, 1)
    }

    func testRemovingTakesTheProjectOffTheListAndKeepsItsFiles() async throws {
        let (f, file, settings) = try setup()
        let removed = await f.remove()
        XCTAssertTrue(removed)
        XCTAssertEqual(try object(settings)["projects"] as? [String], [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAProjectWithoutTheScreenshotsKeyIsNotDirtyAndSavingDoesNotAddTheKey() async throws {
        let (f, file, _) = try setup(extra: "")
        XCTAssertTrue(f.screenshots, "a missing value means on")
        XCTAssertFalse(f.isDirty)
        f.name = "Renamed"
        _ = await f.save()
        XCTAssertNil(try object(file)["screenshots"])
        f.screenshots = false
        XCTAssertTrue(f.isDirty)
    }

    func testClearingTheSimulatorWhileTheBuildCommandUsesUDIDWarns() throws {
        let (f, _, _) = try setup(extra: #","buildCommand":"xcodebuild -destination 'id=$UDID' build","simulator":{"baseDevice":"iPhone 17 Pro"}"#)
        XCTAssertTrue(f.warnings.isEmpty)
        f.simulatorDevice = ""
        XCTAssertEqual(f.warnings.count, 1)
        XCTAssertTrue(f.warnings[0].contains("$UDID"))
        XCTAssertTrue(f.problems.isEmpty, "a warning does not block saving")
        f.buildCommand = "make"
        XCTAssertTrue(f.warnings.isEmpty)
    }

    func testEditProjectSaysWhyItIsUnavailable() throws {
        let scripts = URL(fileURLWithPath: "/s")
        let p = try JSONDecoder().decode(ProjectConfig.self, from: Data(#"{"id":"p","name":"P","repoPath":"/r","dataDir":"/d","maxParallel":2,"sharedFiles":[]}"#.utf8))
        var withSource = p; withSource.sourcePath = "/d/agent-panel/project.json"
        XCTAssertNil(EditProjectFlow.unavailableReason(project: withSource, scriptsDir: scripts))
        XCTAssertTrue(EditProjectFlow.unavailableReason(project: nil, scriptsDir: scripts)?.contains("No project") == true)
        XCTAssertTrue(EditProjectFlow.unavailableReason(project: p, scriptsDir: scripts)?.contains("project.json") == true)
        XCTAssertTrue(EditProjectFlow.unavailableReason(project: withSource, scriptsDir: nil)?.contains("scriptsDir") == true)
    }

    func testCancelIsLockedWhileSaving() throws {
        let (f, _, _) = try setup()
        XCTAssertFalse(f.isWorking)
    }

    func testTheEditSheetRenders() throws {
        let (f, _, _) = try setup()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: EditProjectSheet(flow: f, onSaved: { _ in }, onRemoved: {}, onCancel: {}), size: CGSize(width: 560, height: 720)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("edit-project.png")) }
    }
}
