import XCTest
@testable import AgentPanel

final class RoleWriterTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private var baseDir: URL { dir.url.appendingPathComponent("base") }
    private func writer() -> RoleWriter { RoleWriter(store: RoleStore(baseDir: baseDir)) }

    private func role(_ name: String = "ui_dev", patch: (inout RoleConfig) -> Void = { _ in }) -> RoleConfig {
        var r = RoleConfig(name: name, kind: "interactive", model: "sonnet", effort: "medium", permissionMode: "acceptEdits", outputStyle: "concise",
                           allowedTools: ["Read"], skills: ["superpowers"], instructionFile: "wrong.md", displayName: "Pixel", advanced: nil)
        patch(&r)
        return r
    }

    private func project() throws -> ProjectConfig {
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private func files(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    func testSaveWritesJsonAndInstructionsAtomically() throws {
        let saved = try writer().save(role(), instructions: "Do UI work.", at: .base, replacing: nil)
        XCTAssertEqual(files(baseDir), ["ui_dev.json", "ui_dev.md"], "no temporary file is left")
        XCTAssertEqual(saved.config.instructionFile, "ui_dev.md", "the panel owns the instruction file name")
        XCTAssertEqual(saved.source, .base)
        let store = RoleStore(baseDir: baseDir)
        XCTAssertEqual(store.baseRoles().roles.first?.config, saved.config)
        XCTAssertEqual(store.instructions(of: saved), "Do UI work.")
    }

    func testSaveToTheProjectFolder() throws {
        let p = try project()
        let saved = try writer().save(role(), instructions: "x", at: .project(p), replacing: nil)
        XCTAssertEqual(saved.source, .project)
        XCTAssertEqual(files(dir.url.appendingPathComponent("p/roles")), ["ui_dev.json", "ui_dev.md"])
        XCTAssertEqual(files(baseDir), [], "the shared library is untouched")
    }

    func testSaveRefusesErrorsFromTheValidatorAndWritesNothing() throws {
        XCTAssertThrowsError(try writer().save(role { $0.effort = "ultra" }, instructions: "x", at: .base, replacing: nil)) {
            guard case .problems(let p) = $0 as? RoleWriteError else { return XCTFail("\($0)") }
            XCTAssertEqual(p.map(\.field), ["effort"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseDir.path))
        XCTAssertThrowsError(try writer().save(role { $0.advanced = ["env": .object([:])] }, instructions: "x", at: .base, replacing: nil))
    }

    func testRejectsTraversalAndBadNames() throws {
        for name in ["../x", "a/b", "Dev", "", "..", "a b"] {
            XCTAssertThrowsError(try writer().save(role(name), instructions: "x", at: .base, replacing: nil), name) { XCTAssertEqual($0 as? RoleWriteError, .invalidName) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("x.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseDir.path))
    }

    func testRefusesSymlinkedFileOrFolder() throws {
        let outside = dir.url.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: baseDir, withDestinationURL: outside)
        XCTAssertThrowsError(try writer().save(role(), instructions: "x", at: .base, replacing: nil)) { XCTAssertEqual($0 as? RoleWriteError, .isSymlink) }
        XCTAssertEqual(files(outside), [])
        try FileManager.default.removeItem(at: baseDir)

        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let victim = try dir.write("victim.json", "precious")
        try FileManager.default.createSymbolicLink(at: baseDir.appendingPathComponent("ui_dev.json"), withDestinationURL: victim)
        XCTAssertThrowsError(try writer().save(role(), instructions: "x", at: .base, replacing: nil)) { XCTAssertEqual($0 as? RoleWriteError, .isSymlink) }
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "precious")
    }

    func testNewRoleOverExistingNameIsRefused() throws {
        _ = try writer().save(role(), instructions: "first", at: .base, replacing: nil)
        XCTAssertThrowsError(try writer().save(role(), instructions: "second", at: .base, replacing: nil)) { XCTAssertEqual($0 as? RoleWriteError, .exists) }
        XCTAssertEqual(RoleStore(baseDir: baseDir).instructions(of: try XCTUnwrap(RoleStore(baseDir: baseDir).baseRoles().roles.first)), "first")
    }

    func testEditingAnExistingRoleOverwritesIt() throws {
        let first = try writer().save(role(), instructions: "first", at: .base, replacing: nil)
        let second = try writer().save(role { $0.model = "opus" }, instructions: "second", at: .base, replacing: first)
        XCTAssertEqual(second.config.model, "opus")
        XCTAssertEqual(RoleStore(baseDir: baseDir).instructions(of: second), "second")
        XCTAssertEqual(files(baseDir), ["ui_dev.json", "ui_dev.md"])
    }

    func testEditingMappedRoleIsReadOnly() throws {
        let mapped = ResolvedRole(config: role(), fileURL: dir.url.appendingPathComponent("elsewhere/ui_dev.json"), source: .mapped)
        XCTAssertThrowsError(try writer().save(role(), instructions: "x", at: .base, replacing: mapped)) { XCTAssertEqual($0 as? RoleWriteError, .readOnly) }
        XCTAssertThrowsError(try writer().delete(mapped)) { XCTAssertEqual($0 as? RoleWriteError, .readOnly) }
    }

    func testRenameMovesBothFilesAndNeverLeavesTwoCopies() throws {
        let old = try writer().save(role("old_name"), instructions: "text", at: .base, replacing: nil)
        let renamed = try writer().save(role("new_name"), instructions: "text", at: .base, replacing: old)
        XCTAssertEqual(files(baseDir), ["new_name.json", "new_name.md"])
        XCTAssertEqual(renamed.config.name, "new_name")
        // renaming onto another existing role is refused and changes nothing
        _ = try writer().save(role("taken"), instructions: "t", at: .base, replacing: nil)
        XCTAssertThrowsError(try writer().save(role("taken"), instructions: "x", at: .base, replacing: renamed)) { XCTAssertEqual($0 as? RoleWriteError, .exists) }
        XCTAssertEqual(files(baseDir), ["new_name.json", "new_name.md", "taken.json", "taken.md"])
    }

    func testDeleteRemovesOnlyThatRolesTwoFiles() throws {
        let a = try writer().save(role("a"), instructions: "a", at: .base, replacing: nil)
        _ = try writer().save(role("b"), instructions: "b", at: .base, replacing: nil)
        try dir.write("base/notes.txt", "keep me")
        try writer().delete(a)
        XCTAssertEqual(files(baseDir), ["b.json", "b.md", "notes.txt"])
    }

    func testDeleteOfAProjectRoleNeedsThatProject() throws {
        let p = try project()
        let saved = try writer().save(role("mine"), instructions: "x", at: .project(p), replacing: nil)
        XCTAssertThrowsError(try writer().delete(saved)) { XCTAssertEqual($0 as? RoleWriteError, .outsideRolesFolder) }
        let otherSource = try dir.write("q/project.json", "{\"id\":\"other\",\"name\":\"Other\",\"repoPath\":\"/r\",\"dataDir\":\"/d\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let other = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s2.json", "{\"projects\":[\"\(otherSource.path)\"]}")).projects.first)
        XCTAssertThrowsError(try writer().delete(saved, project: other)) { XCTAssertEqual($0 as? RoleWriteError, .outsideRolesFolder) }
        XCTAssertEqual(files(dir.url.appendingPathComponent("p/roles")), ["mine.json", "mine.md"], "another project's role is never deleted")
        try writer().delete(saved, project: p)
        XCTAssertEqual(files(dir.url.appendingPathComponent("p/roles")), [])
    }

    func testDeleteRefusesAFileOutsideTheRolesFolders() throws {
        let stray = try dir.write("somewhere/else/dev.json", "{}")
        let fake = ResolvedRole(config: role("dev"), fileURL: stray, source: .base)
        XCTAssertThrowsError(try writer().delete(fake)) { XCTAssertEqual($0 as? RoleWriteError, .outsideRolesFolder) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func testLegacyInstructionFileIsLeftAloneAndTheTextMovesToTheRolesOwnFile() throws {
        try dir.write("base/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"legacy.md\"}")
        try dir.write("base/legacy.md", "legacy text")
        let existing = try XCTUnwrap(RoleStore(baseDir: baseDir).baseRoles().roles.first)
        let saved = try writer().save(existing.config, instructions: RoleStore(baseDir: baseDir).instructions(of: existing), at: .base, replacing: existing)
        XCTAssertEqual(saved.config.instructionFile, "dev.md")
        XCTAssertEqual(try String(contentsOf: baseDir.appendingPathComponent("dev.md"), encoding: .utf8), "legacy text")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("legacy.md").path), "the old file is not deleted")
    }

    func testWriteFailureKeepsOldFilesIntact() throws {
        let first = try writer().save(role(), instructions: "first", at: .base, replacing: nil)
        let before = try String(contentsOf: first.fileURL, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: baseDir.path)   // the folder cannot be written to
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: baseDir.path) }
        XCTAssertThrowsError(try writer().save(role { $0.model = "opus" }, instructions: "second", at: .base, replacing: first)) {
            guard case .writeFailed = $0 as? RoleWriteError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try String(contentsOf: first.fileURL, encoding: .utf8), before, "the role file was not changed")
        XCTAssertEqual(try String(contentsOf: baseDir.appendingPathComponent("ui_dev.md"), encoding: .utf8), "first")
        XCTAssertEqual(files(baseDir), ["ui_dev.json", "ui_dev.md"], "no temporary file is left")
    }

    // MARK: thinking and reply language (N220)

    /// The form's draft saved as a role file, then started through the real `spawn-agent.sh --print-flags`: the settings file it writes.
    private func generatedSettings(_ patch: (inout RoleDraft) -> Void) throws -> (role: [String: Any], settings: [String: Any]) {
        var draft = RoleDraft(); draft.name = "ui_dev"; draft.skills = ["keepme"]; patch(&draft)
        let (config, problems) = draft.config()
        XCTAssertEqual(problems, [])
        let saved = try writer().save(config, instructions: "Do UI work.", at: .base, replacing: RoleStore(baseDir: baseDir).baseRoles().roles.first)
        let role = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: saved.fileURL)) as? [String: Any])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/spawn-agent.sh").path, "--print-flags", saved.fileURL.path]
        var env = ProcessInfo.processInfo.environment
        env["AGENT_PANEL_STATE"] = dir.url.appendingPathComponent("state").path
        env["AGENT_PANEL_CLAUDE_HOME"] = root.appendingPathComponent("tests/fixtures/claude-home").path
        env["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.url.appendingPathComponent("state/ui_dev/settings.json"))) as? [String: Any]
        return (role, try XCTUnwrap(settings))
    }

    func testThinkingAndLanguageGoFromTheFormThroughTheRoleFileIntoTheAgentsSettings() throws {
        var r = try generatedSettings { $0.thinking = "on"; $0.language = " turkish " }
        XCTAssertEqual(r.role["thinking"] as? String, "on"); XCTAssertEqual(r.role["language"] as? String, "turkish")
        XCTAssertEqual(r.settings["alwaysThinkingEnabled"] as? Bool, true); XCTAssertEqual(r.settings["language"] as? String, "turkish")

        r = try generatedSettings { $0.thinking = "off"; $0.language = "" }
        XCTAssertEqual(r.role["thinking"] as? String, "off"); XCTAssertNil(r.role["language"], "an empty language is left out of the role file")
        XCTAssertEqual(r.settings["alwaysThinkingEnabled"] as? Bool, false); XCTAssertNil(r.settings["language"])

        r = try generatedSettings { $0.thinking = "default" }
        XCTAssertNil(r.role["thinking"]); XCTAssertNil(r.settings["alwaysThinkingEnabled"], "default leaves Claude Code's own setting alone")
        XCTAssertEqual(r.settings["outputStyle"] as? String, "Concise")
    }

    func testThinkingAndLanguageRoundTripAndCodexDropsThem() throws {
        var draft = RoleDraft(); draft.name = "ui_dev"; draft.thinking = "off"; draft.language = "english"
        let saved = try writer().save(draft.config().role, instructions: "x", at: .base, replacing: nil)
        let back = RoleDraft(role: saved, instructions: "x")
        XCTAssertEqual(back.thinking, "off"); XCTAssertEqual(back.language, "english")
        var edited = back; edited.thinking = "on"
        XCTAssertEqual(edited.changeCount(from: back), 1)
        draft.tool = "codex"
        XCTAssertNil(draft.config().role.thinking, "Codex has no thinking switch; its effort is the reasoning level")
        XCTAssertNil(draft.config().role.language)
        XCTAssertTrue(RoleValidator.problems(for: role { $0.thinking = "maybe" }).contains { $0.field == "thinking" && $0.severity == .error })
        XCTAssertTrue(RoleValidator.problems(for: role { $0.thinking = "off"; $0.effort = "max" }).contains { $0.field == "thinking" && $0.severity == .warning })
    }
}
