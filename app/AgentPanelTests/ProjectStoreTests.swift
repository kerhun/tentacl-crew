import XCTest
@testable import AgentPanel

final class ProjectStoreTests: XCTestCase {
    private func projectJSON(id: String = "demo", maxParallel: Int = 4, repo: String = "/tmp/demo") -> String {
        """
        {"id":"\(id)","name":"Demo \(id)","repoPath":"\(repo)","dataDir":"/tmp/demo-data","maxParallel":\(maxParallel),
         "buildCommand":"xcodebuild build","simulator":{"baseDevice":"iPhone 17 Pro"},
         "sharedFiles":["App/Localizable.xcstrings"],"openWith":"Xcode"}
        """
    }

    private func settings(_ paths: [String]) -> String {
        "{\"projects\": [" + paths.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
    }

    func testLoadsTwoValidProjects() throws {
        let dir = try TempDir()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        let b = try dir.write("b/project.json", projectJSON(id: "b"))
        let s = try dir.write("settings.json", settings([a.path, b.path]))
        let result = ProjectStore.load(settingsURL: s)
        XCTAssertEqual(result.projects.map(\.id), ["a", "b"])
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.projects[0].repoURL.path, "/tmp/demo")
        XCTAssertEqual(result.projects[0].worktreesURL.path, "/tmp/demo/.agent-worktrees")
    }

    func testDefaultSettingsLocationIsTentaclWithFallbackToTheOldFolder() throws {
        let home = try TempDir()
        XCTAssertEqual(ProjectStore.defaultSettingsURL(home: home.url).path, home.url.appendingPathComponent(".config/tentacl/projects.json").path)
        try home.write(".config/agent-panel/projects.json", "{}")
        XCTAssertEqual(ProjectStore.defaultSettingsURL(home: home.url).path, home.url.appendingPathComponent(".config/agent-panel/projects.json").path,
                       "an existing settings file from before the rename keeps working")
        try home.write(".config/tentacl/projects.json", "{}")
        XCTAssertEqual(ProjectStore.defaultSettingsURL(home: home.url).path, home.url.appendingPathComponent(".config/tentacl/projects.json").path)
    }

    func testProjectKnowsItsFile() throws {
        let dir = try TempDir()
        let a = try dir.write("a/project.json", projectJSON(id: "a"))
        let s = try dir.write("settings.json", settings([a.path]))
        XCTAssertEqual(ProjectStore.load(settingsURL: s).projects.first?.sourcePath, a.path)
    }

    func testMissingSettingsFileGivesEmptyWithProblem() throws {
        let dir = try TempDir()
        let result = ProjectStore.load(settingsURL: dir.url.appendingPathComponent("nope.json"))
        XCTAssertEqual(result.projects, [])
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(result.problems[0].contains("No settings file"))
    }

    func testInvalidProjectJsonReportedOthersLoaded() throws {
        let dir = try TempDir()
        let good = try dir.write("good/project.json", projectJSON(id: "good"))
        let bad = try dir.write("bad/project.json", "{\"id\": \"bad\",")
        let tooMany = try dir.write("many/project.json", projectJSON(id: "many", maxParallel: 9))
        let s = try dir.write("settings.json", settings([bad.path, good.path, tooMany.path]))
        let result = ProjectStore.load(settingsURL: s)
        XCTAssertEqual(result.projects.map(\.id), ["good"])
        XCTAssertEqual(result.problems.count, 2)
        XCTAssertTrue(result.problems.contains { $0.hasPrefix(bad.path) })
        XCTAssertTrue(result.problems.contains { $0.contains("maxParallel") })
    }

    func testParallelAgentsAcceptTwoToEightAndOneLoadsAsTwo() throws {
        let dir = try TempDir()
        for n in 2...8 {
            let f = try dir.write("n\(n)/project.json", projectJSON(id: "n\(n)", maxParallel: n))
            let p = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s\(n).json", settings([f.path]))).projects.first)
            XCTAssertEqual(p.maxParallel, n); XCTAssertFalse(p.raisedToMinimum)
        }
        let one = try dir.write("one/project.json", projectJSON(id: "one", maxParallel: 1))
        let p = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s1.json", settings([one.path]))).projects.first)
        XCTAssertEqual(p.maxParallel, 2); XCTAssertTrue(p.raisedToMinimum)
        let zero = try dir.write("zero/project.json", projectJSON(id: "zero", maxParallel: 0))
        XCTAssertEqual(ProjectStore.load(settingsURL: try dir.write("s0.json", settings([zero.path]))).projects.count, 0)
        XCTAssertEqual(ProjectConfig.parallelRange, 2...8)
    }

    func testMainBranchDefaultsToMainAndRejectsHostileNames() throws {
        let dir = try TempDir()
        func project(_ extra: String) throws -> ProjectLoadResult {
            let p = try dir.write("p\(extra.count).json", "{\"id\":\"d\(extra.count)\",\"name\":\"D\",\"repoPath\":\"/r\",\"dataDir\":\"/d\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"\(extra)}")
            let s = try dir.write("s\(extra.count).json", "{\"projects\":[\"\(p.path)\"]}")
            return ProjectStore.load(settingsURL: s)
        }
        XCTAssertEqual(try project("").projects.first?.baseBranch, "main")
        XCTAssertEqual(try project(",\"mainBranch\":\"trunk\"").projects.first?.baseBranch, "trunk")
        let bad = try project(",\"mainBranch\":\"--force\"")
        XCTAssertTrue(bad.projects.isEmpty)
        XCTAssertTrue(bad.problems.joined().contains("mainBranch"))
    }

    func testRelativePathInSettingsIsRejected() throws {
        let dir = try TempDir()
        let s = try dir.write("settings.json", settings(["relative/project.json"]))
        let result = ProjectStore.load(settingsURL: s)
        XCTAssertEqual(result.projects, [])
        XCTAssertTrue(result.problems[0].contains("absolute"))
    }

    func testTildeIsNotExpandedButReported() throws {
        let dir = try TempDir()
        let s = try dir.write("settings.json", settings(["~/projects/project.json"]))
        let result = ProjectStore.load(settingsURL: s)
        XCTAssertEqual(result.projects, [])
        XCTAssertTrue(result.problems[0].contains("~"))
    }

    func testPathWithSpacesWorks() throws {
        let dir = try TempDir()
        let p = try dir.write("with space/project.json", projectJSON(id: "spaced", repo: "/tmp/my repo"))
        let s = try dir.write("settings.json", settings([p.path]))
        let result = ProjectStore.load(settingsURL: s)
        XCTAssertEqual(result.projects.map(\.id), ["spaced"])
        XCTAssertEqual(result.projects[0].repoURL.path, "/tmp/my repo")
    }

    func testDuplicateIdIsReportedAndSkipped() throws {
        let dir = try TempDir()
        let a = try dir.write("a/project.json", projectJSON(id: "same"))
        let b = try dir.write("b/project.json", projectJSON(id: "same"))
        let s = try dir.write("settings.json", settings([a.path, b.path]))
        let result = ProjectStore.load(settingsURL: s)
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertTrue(result.problems[0].contains("duplicate"))
    }

    func testAProjectWithoutBuildSimulatorXcodeOrOpenWithLoads() throws {
        let dir = try TempDir()
        let f = try dir.write("m/project.json", #"{"id":"m","name":"M","repoPath":"/tmp/m","dataDir":"/tmp/m-data","maxParallel":2,"sharedFiles":[],"screenshots":false}"#)
        let r = ProjectStore.load(settingsURL: try dir.write("settings.json", settings([f.path])))
        XCTAssertEqual(r.problems, [])
        let p = try XCTUnwrap(r.projects.first)
        XCTAssertNil(p.buildCommand); XCTAssertNil(p.simulator); XCTAssertNil(p.xcodeProject); XCTAssertNil(p.openWith)
        XCTAssertFalse(p.screenshotsEnabled)
    }

    func testScreenshotsAreOnWhenTheFieldIsMissingSoOldProjectsKeepWorking() throws {
        let dir = try TempDir()
        let f = try dir.write("a/project.json", projectJSON(id: "a"))
        let p = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("settings.json", settings([f.path]))).projects.first)
        XCTAssertTrue(p.screenshotsEnabled)
    }

    func testEmptyOptionalValuesAreStillRejected() throws {
        let dir = try TempDir()
        let f = try dir.write("e/project.json", #"{"id":"e","name":"E","repoPath":"/tmp/e","dataDir":"/tmp/e-data","maxParallel":2,"sharedFiles":[],"buildCommand":""}"#)
        let r = ProjectStore.load(settingsURL: try dir.write("settings.json", settings([f.path])))
        XCTAssertEqual(r.projects, [])
        XCTAssertTrue(r.problems.joined().contains("buildCommand"))
    }

    func testCopyFilesAreReadFromTheProjectFile() throws {
        let dir = try TempDir()
        let f = try dir.write("c/project.json", #"{"id":"c","name":"C","repoPath":"/tmp/c","dataDir":"/tmp/c-data","maxParallel":2,"sharedFiles":[],"copyFiles":["app/Signing.local.xcconfig"]}"#)
        let p = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("settings.json", settings([f.path]))).projects.first)
        XCTAssertEqual(p.copyFiles, ["app/Signing.local.xcconfig"])
    }
}
