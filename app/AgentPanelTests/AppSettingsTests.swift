import XCTest
@testable import AgentPanel

final class AppSettingsTests: XCTestCase {
    private func makeScripts(_ dir: TempDir, names: [String] = ScriptName.allCases.map(\.rawValue)) throws -> URL {
        for n in names { try dir.write("scripts/\(n)", "#!/bin/bash\n") }
        return dir.url.appendingPathComponent("scripts")
    }

    private func settingsFile(_ dir: TempDir, scriptsDir: String?, projects: [String] = []) throws -> URL {
        let list = projects.map { "\"\($0)\"" }.joined(separator: ",")
        let extra = scriptsDir.map { ",\"scriptsDir\":\"\($0)\"" } ?? ""
        return try dir.write("settings.json", "{\"projects\":[\(list)]\(extra)}")
    }

    func testLoadsScriptsDir() throws {
        let dir = try TempDir()
        let scripts = try makeScripts(dir)
        let s = AppSettingsStore.load(settingsURL: try settingsFile(dir, scriptsDir: scripts.path))
        XCTAssertEqual(s.scriptsDir?.resolvingSymlinksInPath().path, scripts.resolvingSymlinksInPath().path)
        XCTAssertEqual(s.problems, [])
        XCTAssertNotNil(s.scriptURL(.spawn))
    }

    func testRelativeScriptsDirRejected() throws {
        let dir = try TempDir()
        let s = AppSettingsStore.load(settingsURL: try settingsFile(dir, scriptsDir: "scripts"))
        XCTAssertNil(s.scriptsDir)
        XCTAssertTrue(s.problems.joined().contains("absolute"))
    }

    func testTildeScriptsDirReportedNotExpanded() throws {
        let dir = try TempDir()
        let s = AppSettingsStore.load(settingsURL: try settingsFile(dir, scriptsDir: "~/agent-panel/scripts"))
        XCTAssertNil(s.scriptsDir)
        XCTAssertTrue(s.problems.joined().contains("~"))
    }

    func testMissingScriptReportedAndDisablesActions() throws {
        let dir = try TempDir()
        let scripts = try makeScripts(dir, names: ["spawn-agent.sh", "check-conflicts.sh"])
        let s = AppSettingsStore.load(settingsURL: try settingsFile(dir, scriptsDir: scripts.path))
        XCTAssertNil(s.scriptsDir)
        XCTAssertTrue(s.problems.joined().contains("stop-agent.sh"))
        XCTAssertNil(s.scriptURL(.spawn))
    }

    func testMissingFolderReported() throws {
        let dir = try TempDir()
        let s = AppSettingsStore.load(settingsURL: try settingsFile(dir, scriptsDir: dir.url.appendingPathComponent("nope").path))
        XCTAssertNil(s.scriptsDir)
        XCTAssertFalse(s.problems.isEmpty)
    }

    func testScriptURLStaysInsideScriptsDir() throws {
        let dir = try TempDir()
        let scripts = try makeScripts(dir)
        let outside = try dir.write("outside/evil.sh", "#!/bin/bash\n")
        try FileManager.default.removeItem(at: scripts.appendingPathComponent("spawn-agent.sh"))
        try FileManager.default.createSymbolicLink(at: scripts.appendingPathComponent("spawn-agent.sh"), withDestinationURL: outside)
        let s = AppSettings(scriptsDir: scripts, problems: [])
        XCTAssertNil(s.scriptURL(.spawn), "a script that resolves outside scriptsDir must not be used")
        XCTAssertNotNil(s.scriptURL(.stop))
        // and the loader treats such a folder as unusable as a whole
        XCTAssertNil(AppSettingsStore.load(settingsURL: try settingsFile(dir, scriptsDir: scripts.path)).scriptsDir)
    }

    func testNoScriptsDirKeyIsNotAnError() throws {
        let dir = try TempDir()
        let s = AppSettingsStore.load(settingsURL: try settingsFile(dir, scriptsDir: nil))
        XCTAssertNil(s.scriptsDir)
        XCTAssertEqual(s.problems, [])
    }

    // MARK: N233 old terminal choices

    /// A settings file written before Tentacl's own terminal was the only one: the `terminalBackend` key is ignored, with no problem
    /// and no warning, and every other key still loads.
    func testAnOldHerdrOrTmuxChoiceLoadsWithoutErrorOrWarning() throws {
        let dir = try TempDir()
        let scripts = try makeScripts(dir)
        for old in ["herdr", "tmux", "tentacl", "something-else"] {
            let file = try dir.write("\(old).json", "{\"projects\":[],\"scriptsDir\":\"\(scripts.path)\",\"terminalBackend\":\"\(old)\"}")
            let s = AppSettingsStore.load(settingsURL: file)
            XCTAssertEqual(s.problems, [], old)
            XCTAssertEqual(s.scriptsDir?.path, scripts.path, old)
        }
    }

    func testUpdatingTheSettingsKeepsAnOldTerminalKeyAndEveryOtherKey() throws {
        let dir = try TempDir()
        let file = try dir.write("cfg/projects.json", #"{"projects":["/p/project.json"],"terminalBackend":"herdr","future":{"x":1}}"#)
        try AppSettingsStore.update(file) { $0["scriptsDir"] = "/s" }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(object["terminalBackend"] as? String, "herdr")
        XCTAssertEqual(object["scriptsDir"] as? String, "/s")
        XCTAssertEqual((object["future"] as? [String: Int])?["x"], 1)
    }

    func testProjectRolesDecoded() throws {
        let dir = try TempDir()
        let role = try dir.write("roles/dev.json", "{}")
        let json = """
        {"id":"p","name":"P","repoPath":"/tmp/p","dataDir":"/tmp/d","maxParallel":2,"buildCommand":"b",
         "simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode","roles":{"dev":"\(role.path)"}}
        """
        let project = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        XCTAssertEqual(project.roles?["dev"], role.path)
        XCTAssertEqual(project.roleURL("dev")?.path, role.path)
    }

    func testRoleURLNilWhenFileMissingOrRelative() throws {
        let json = """
        {"id":"p","name":"P","repoPath":"/tmp/p","dataDir":"/tmp/d","maxParallel":2,"buildCommand":"b",
         "simulator":{"baseDevice":"x"},"sharedFiles":[],"openWith":"Xcode","roles":{"dev":"/nope/dev.json","qa":"dev.json"}}
        """
        let project = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        XCTAssertNil(project.roleURL("dev"))
        XCTAssertNil(project.roleURL("qa"))
        XCTAssertNil(project.roleURL("missing"))
    }

    func testExistingProjectsStillLoadWhenScriptsDirIsPresent() throws {
        let dir = try TempDir()
        let p = try dir.write("p/project.json", """
        {"id":"demo","name":"Demo","repoPath":"/tmp/demo","dataDir":"/tmp/data","maxParallel":4,"buildCommand":"b",
         "simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"}
        """)
        let s = try settingsFile(dir, scriptsDir: "/tmp/x", projects: [p.path])
        XCTAssertEqual(ProjectStore.load(settingsURL: s).projects.map(\.id), ["demo"])
    }
}
