import XCTest
@testable import AgentPanel

final class ProjectRegistryTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private struct Validator: ScriptRunning {
        var status: Int32 = 0
        var message = ""
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult {
            XCTAssertEqual(script, .validate)
            return ScriptResult(status: status, stdout: "", stderr: message)
        }
    }

    private func projectJSON(id: String, extra: String = "") -> String {
        #"{"id":"\#(id)","name":"N \#(id)","repoPath":"/tmp/\#(id)","dataDir":"/tmp/\#(id)-data","maxParallel":2,"sharedFiles":[],"buildCommand":"make"\#(extra)}"#
    }

    private func registry(_ validator: Validator = Validator()) -> (ProjectRegistry, URL) {
        let settings = dir.url.appendingPathComponent("projects.json")
        return (ProjectRegistry(settingsURL: settings, scripts: validator), settings)
    }

    private func settingsObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: add

    func testAddingToANewSettingsFileCreatesIt() throws {
        let (r, settings) = registry()
        let file = try dir.write("a/project.json", projectJSON(id: "a"))
        let added = try r.add(projectFile: file)
        XCTAssertEqual(added.id, "a")
        XCTAssertEqual(try settingsObject(settings)["projects"] as? [String], [file.path])
    }

    func testAddingKeepsTheOtherSettingsAndProjects() throws {
        let (r, settings) = registry()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        let b = try dir.write("b/project.json", projectJSON(id: "b"))
        try #"{"scriptsDir":"/x/scripts","future":{"k":1},"projects":["\#(a.path)"]}"#.write(to: settings, atomically: true, encoding: .utf8)
        _ = try r.add(projectFile: b)
        let o = try settingsObject(settings)
        XCTAssertEqual(o["projects"] as? [String], [a.path, b.path])
        XCTAssertEqual(o["scriptsDir"] as? String, "/x/scripts")
        XCTAssertNotNil(o["future"])
    }

    func testTheSameFileOrTheSameIdIsRefused() throws {
        let (r, settings) = registry()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        let other = try dir.write("o/project.json", projectJSON(id: "a"))
        _ = try r.add(projectFile: a)
        XCTAssertThrowsError(try r.add(projectFile: a)) { XCTAssertEqual($0 as? ProjectRegistry.RegistryError, .duplicatePath) }
        XCTAssertThrowsError(try r.add(projectFile: other)) { XCTAssertEqual($0 as? ProjectRegistry.RegistryError, .duplicateID("a")) }
        XCTAssertEqual(try settingsObject(settings)["projects"] as? [String], [a.path])
    }

    func testAnotherProjectOnTheSameRepositoryIsRefused() throws {
        let (r, settings) = registry()
        let a = try dir.write("a/project.json", projectJSON(id: "a").replacingOccurrences(of: "/tmp/a\"", with: "/tmp/shared\""))
        let b = try dir.write("b/project.json", projectJSON(id: "b").replacingOccurrences(of: "/tmp/b\"", with: "/tmp/shared/\""))
        _ = try r.add(projectFile: a)
        XCTAssertThrowsError(try r.add(projectFile: b)) { XCTAssertEqual($0 as? ProjectRegistry.RegistryError, .duplicateRepo("a")) }
        XCTAssertEqual(try settingsObject(settings)["projects"] as? [String], [a.path])
    }

    func testAnInvalidProjectFileIsNotRegistered() throws {
        let (r, settings) = registry()
        let bad = try dir.write("bad/project.json", #"{"id":"bad"}"#)
        XCTAssertThrowsError(try r.add(projectFile: bad)) { guard case .invalidProject = $0 as? ProjectRegistry.RegistryError else { return XCTFail("\($0)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testACorruptSettingsFileIsNeverOverwritten() throws {
        let (r, settings) = registry()
        try "{ not json".write(to: settings, atomically: true, encoding: .utf8)
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        XCTAssertThrowsError(try r.add(projectFile: a)) { guard case .settingsUnreadable = $0 as? ProjectRegistry.RegistryError else { return XCTFail("\($0)") } }
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ not json")
    }

    func testAnEarlierFormatWithoutAProjectsListIsRefusedToo() throws {
        let (r, settings) = registry()
        try #"{"projects":"nope"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        XCTAssertThrowsError(try r.add(projectFile: a))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), #"{"projects":"nope"}"#)
    }

    // MARK: remove

    func testRemovingDropsOnlyThatEntryAndLeavesTheFiles() throws {
        let (r, settings) = registry()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        let b = try dir.write("b/project.json", projectJSON(id: "b"))
        _ = try r.add(projectFile: a); _ = try r.add(projectFile: b)
        try r.remove(projectFile: a)
        XCTAssertEqual(try settingsObject(settings)["projects"] as? [String], [b.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertThrowsError(try r.remove(projectFile: a)) { XCTAssertEqual($0 as? ProjectRegistry.RegistryError, .notRegistered) }
    }

    // MARK: reorder

    func testReorderingWritesTheNewOrderAndKeepsUnknownKeysAndBrokenEntries() throws {
        let (r, settings) = registry()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        let b = try dir.write("b/project.json", projectJSON(id: "b"))
        let c = try dir.write("c/project.json", projectJSON(id: "c"))
        try #"{"scriptsDir":"/x/scripts","future":{"k":1},"projects":["\#(a.path)","/gone/project.json","\#(b.path)","\#(c.path)"]}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try r.reorder(projectFiles: [c, a, b])
        let o = try settingsObject(settings)
        XCTAssertEqual(o["projects"] as? [String], [c.path, "/gone/project.json", a.path, b.path], "an entry that does not load keeps its place")
        XCTAssertEqual(o["scriptsDir"] as? String, "/x/scripts")
        XCTAssertEqual(o["future"] as? [String: Int], ["k": 1])
        XCTAssertEqual(ProjectStore.load(settingsURL: settings).projects.map(\.id), ["c", "a", "b"])
    }

    func testReorderingWithAFileNotInTheListChangesNothing() throws {
        let (r, settings) = registry()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        let b = try dir.write("b/project.json", projectJSON(id: "b"))
        _ = try r.add(projectFile: a)
        XCTAssertThrowsError(try r.reorder(projectFiles: [b, a])) { XCTAssertEqual($0 as? ProjectRegistry.RegistryError, .notRegistered) }
        XCTAssertEqual(try settingsObject(settings)["projects"] as? [String], [a.path])
    }

    // MARK: update

    private func loaded(_ file: URL) throws -> ProjectConfig {
        var p = try JSONDecoder().decode(ProjectConfig.self, from: Data(contentsOf: file))
        p.sourcePath = file.path
        return p
    }

    func testUpdatingChangesTheFieldsAndKeepsKeysThePanelDoesNotKnow() async throws {
        let (r, _) = registry()
        let file = try dir.write("a/project.json", projectJSON(id: "a", extra: #","roles":{"dev":"/r/dev.json"},"somethingNew":{"x":1}"#))
        var p = try loaded(file)
        p = ProjectConfig(id: p.id, name: "Renamed", repoPath: p.repoPath, dataDir: p.dataDir, maxParallel: 3, buildCommand: "make all", xcodeProject: nil,
                          simulator: nil, sharedFiles: ["a.txt"], openWith: nil, screenshots: false, roles: p.roles, mainBranch: nil, sourcePath: file.path)
        try await r.update(p)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(o["name"] as? String, "Renamed"); XCTAssertEqual(o["maxParallel"] as? Int, 3); XCTAssertEqual(o["buildCommand"] as? String, "make all")
        XCTAssertEqual(o["screenshots"] as? Bool, false)
        XCTAssertNotNil(o["somethingNew"]); XCTAssertNotNil(o["roles"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["project.json"], "no temporary file is left")
    }

    func testClearingAnOptionalFieldRemovesItFromTheFile() async throws {
        let (r, _) = registry()
        let file = try dir.write("a/project.json", projectJSON(id: "a"))
        var p = try loaded(file)
        p = ProjectConfig(id: p.id, name: p.name, repoPath: p.repoPath, dataDir: p.dataDir, maxParallel: 2, buildCommand: nil, xcodeProject: nil,
                          simulator: nil, sharedFiles: [], openWith: nil, sourcePath: file.path)
        try await r.update(p)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(o["buildCommand"])
    }

    func testAnUpdateTheValidatorRefusesChangesNothing() async throws {
        let (r, _) = registry(Validator(status: 1, message: "ERROR: maxParallel must be an integer from 1 to 4"))
        let file = try dir.write("a/project.json", projectJSON(id: "a"))
        let before = try String(contentsOf: file, encoding: .utf8)
        var p = try loaded(file); p = ProjectConfig(id: p.id, name: p.name, repoPath: p.repoPath, dataDir: p.dataDir, maxParallel: 9, buildCommand: "make", xcodeProject: nil,
                                                   simulator: nil, sharedFiles: [], openWith: nil, sourcePath: file.path)
        do { try await r.update(p); XCTFail("should be refused") }
        catch let e as ProjectRegistry.RegistryError { XCTAssertEqual(e, .invalidProject("ERROR: maxParallel must be an integer from 1 to 4")) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["project.json"])
    }

    func testAProjectWithoutAFileLocationCannotBeUpdated() async throws {
        let (r, _) = registry()
        let p = ProjectConfig(id: "a", name: "A", repoPath: "/r", dataDir: "/d", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
        do { try await r.update(p); XCTFail("should be refused") } catch let e as ProjectRegistry.RegistryError { XCTAssertEqual(e, .notRegistered) }
    }

    // MARK: polish

    func testFilesAreWrittenWithoutEscapedSlashes() async throws {
        let (r, settings) = registry()
        let file = try dir.write("a/project.json", projectJSON(id: "a"))
        _ = try r.add(projectFile: file)
        XCTAssertFalse(try String(contentsOf: settings, encoding: .utf8).contains("\\/"))
        try await r.update(try loaded(file))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("\\/"))
    }

    func testASymlinkedSettingsFileStaysALinkAndTheTargetIsWritten() throws {
        let (r, settings) = registry()
        let target = dir.url.appendingPathComponent("real/projects.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"projects":[]}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        _ = try r.add(projectFile: a)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: settings.path), "still a link")
        XCTAssertEqual(try settingsObject(target)["projects"] as? [String], [a.path])
    }

    func testASymlinkedProjectFileStaysALinkAndTheTargetIsWritten() async throws {
        let (r, _) = registry()
        let target = try dir.write("real/project.json", projectJSON(id: "a"))
        let link = dir.url.appendingPathComponent("a/project.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var p = try loaded(link); p.sourcePath = link.path
        let renamed = ProjectConfig(id: p.id, name: "Renamed", repoPath: p.repoPath, dataDir: p.dataDir, maxParallel: 2, buildCommand: "make", xcodeProject: nil,
                                    simulator: nil, sharedFiles: [], openWith: nil, sourcePath: link.path)
        try await r.update(renamed)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "still a link")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])["name"] as? String, "Renamed")
    }

    func testRemoveAndAddMatchTheSameFileThroughASymlinkedFolder() throws {
        let (r, settings) = registry()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        _ = try r.add(projectFile: a)
        let alias = dir.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a.deletingLastPathComponent())
        let viaAlias = alias.appendingPathComponent("project.json")
        XCTAssertThrowsError(try r.add(projectFile: viaAlias)) { XCTAssertEqual($0 as? ProjectRegistry.RegistryError, .duplicatePath) }
        try r.remove(projectFile: viaAlias)
        XCTAssertEqual(try settingsObject(settings)["projects"] as? [String], [])
    }

    func testNotRegisteredReadsAsASentence() {
        XCTAssertEqual("\(ProjectRegistry.RegistryError.notRegistered)", "The project is not in the list.")
    }

    func testUpdateKeepsAHandEditToAKeyTheFormDoesNotEdit() async throws {
        let (r, _) = registry()
        let file = try dir.write("a/project.json", projectJSON(id: "a", extra: #","roles":{"dev":"/r/dev.json"}"#))
        let p = try loaded(file)   // the sheet opens here
        try dir.write("a/project.json", projectJSON(id: "a", extra: #","roles":{"dev":"/r/other.json"},"copyFiles":[".env"]"#))   // hand edit
        let edited = ProjectConfig(id: p.id, name: "Renamed", repoPath: p.repoPath, dataDir: p.dataDir, maxParallel: 2, buildCommand: "make", xcodeProject: nil,
                                   simulator: nil, sharedFiles: [], openWith: nil, roles: p.roles, sourcePath: file.path)
        try await r.update(edited)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(o["name"] as? String, "Renamed")
        XCTAssertEqual((o["roles"] as? [String: String])?["dev"], "/r/other.json")
        XCTAssertEqual(o["copyFiles"] as? [String], [".env"])
    }

    func testUpdateKeepsKeysNestedInsideSimulator() async throws {
        let (r, _) = registry()
        let file = try dir.write("a/project.json", projectJSON(id: "a", extra: #","simulator":{"baseDevice":"iPhone 15","runtime":"iOS 17"}"#))
        let p = try loaded(file)
        let edited = ProjectConfig(id: p.id, name: p.name, repoPath: p.repoPath, dataDir: p.dataDir, maxParallel: 2, buildCommand: "make", xcodeProject: nil,
                                   simulator: .init(baseDevice: "iPhone 16"), sharedFiles: [], openWith: nil, sourcePath: file.path)
        try await r.update(edited)
        let sim = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["simulator"] as? [String: String])
        XCTAssertEqual(sim, ["baseDevice": "iPhone 16", "runtime": "iOS 17"])
    }
}
