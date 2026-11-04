import XCTest
@testable import AgentPanel

final class TeamChartStoreTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func project() throws -> ProjectConfig {
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }
    private var teamURL: URL { dir.url.appendingPathComponent("p/team.json") }
    private let good = TeamChart(members: [TeamMember(role: "pm", reportsTo: nil), TeamMember(role: "dev", reportsTo: "pm")])

    func testTheFileSitsNextToProjectJson() throws {
        XCTAssertEqual(TeamChartStore().url(for: try project())?.standardizedFileURL.path, teamURL.standardizedFileURL.path)
    }

    func testNoneValidAndInvalid() throws {
        let p = try project()
        XCTAssertEqual(TeamChartStore().load(for: p), .none)
        try dir.write("p/team.json", #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"dev","reportsTo":"pm"}]}"#)
        XCTAssertEqual(TeamChartStore().load(for: p), .valid(good))
        try dir.write("p/team.json", "{ nope")
        guard case .invalid(let broken) = TeamChartStore().load(for: p) else { return XCTFail("bad JSON should be invalid") }
        XCTAssertTrue(broken.map(\.message).joined().contains("not valid JSON"))
        try dir.write("p/team.json", #"{"version":1,"members":[{"role":"a","reportsTo":"b"},{"role":"b","reportsTo":"a"}]}"#)
        guard case .invalid(let cyc) = TeamChartStore().load(for: p) else { return XCTFail("a cycle should be invalid") }
        XCTAssertTrue(cyc.map(\.message).joined().contains("cycle"))
        try dir.write("p/team.json", #"{"version":1}"#)
        guard case .invalid = TeamChartStore().load(for: p) else { return XCTFail("a file without members should be invalid") }
    }

    func testSaveWritesAtomicallyAndKeepsUnknownKeys() throws {
        let p = try project()
        try dir.write("p/team.json", #"{"version":1,"members":[],"future":{"a":1}}"#)
        guard case .valid(var chart) = TeamChartStore().load(for: p) else { return XCTFail("valid") }
        chart.members = good.members
        try TeamChartStore().save(chart, for: p)
        XCTAssertEqual(TeamChartStore().load(for: p), .valid(chart))
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: Data(contentsOf: teamURL)) as? [String: Any])?["future"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent("p").path).sorted(), ["project.json", "team.json"], "no temporary file is left")
    }

    func testSaveRefusesSymlinkAndInvalidChartAndWritesNothing() throws {
        let p = try project()
        let victim = try dir.write("victim.json", "precious")
        try FileManager.default.createSymbolicLink(at: teamURL, withDestinationURL: victim)
        XCTAssertThrowsError(try TeamChartStore().save(good, for: p)) { XCTAssertEqual($0 as? TeamChartWriteError, .isSymlink) }
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "precious")
        try FileManager.default.removeItem(at: teamURL)
        let cyclic = TeamChart(members: [TeamMember(role: "a", reportsTo: "b"), TeamMember(role: "b", reportsTo: "a")])
        XCTAssertThrowsError(try TeamChartStore().save(cyclic, for: p)) { guard case .problems = $0 as? TeamChartWriteError else { return XCTFail("\($0)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: teamURL.path))
    }

    func testSaveNeverTouchesProjectJson() throws {
        let p = try project()
        let before = try String(contentsOfFile: try XCTUnwrap(p.sourcePath), encoding: .utf8)
        try TeamChartStore().save(good, for: p)
        XCTAssertEqual(try String(contentsOfFile: try XCTUnwrap(p.sourcePath), encoding: .utf8), before)
    }

    func testAProjectWithoutAFileLocationCannotSave() {
        let p = ProjectConfig(id: "d", name: "D", repoPath: "/r", dataDir: "/d", maxParallel: 2, buildCommand: "b", xcodeProject: nil, simulator: .init(baseDevice: "x"), sharedFiles: [], openWith: "Xcode")
        XCTAssertNil(TeamChartStore().url(for: p))
        XCTAssertThrowsError(try TeamChartStore().save(good, for: p)) { XCTAssertEqual($0 as? TeamChartWriteError, .noProjectFile) }
        XCTAssertEqual(TeamChartStore().load(for: p), .none)
    }

    func testRoleNamesFromTheFileAreValidatedBeforeAnyUse() throws {
        let p = try project()
        try dir.write("p/team.json", #"{"version":1,"members":[{"role":"../x","reportsTo":null}]}"#)
        guard case .invalid(let problems) = TeamChartStore().load(for: p) else { return XCTFail("a bad name is invalid") }
        XCTAssertTrue(problems.contains { $0.severity == .error })
    }
}
