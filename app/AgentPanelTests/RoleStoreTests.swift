import XCTest
@testable import AgentPanel

final class RoleStoreTests: XCTestCase {
    private var dir: TempDir!
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws { dir = try TempDir() }

    private var baseDir: URL { dir.url.appendingPathComponent("base") }
    private func store() -> RoleStore { RoleStore(baseDir: baseDir) }

    private func roleJSON(_ name: String, model: String = "sonnet", extra: String = "") -> String {
        "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"\(model)\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"\(name).md\"\(extra)}"
    }

    /// A project whose project.json lives in `p/` (so its own roles are in `p/roles/`), optionally mapping role names to files.
    private func project(mapped: [String: String] = [:]) throws -> ProjectConfig {
        let map = mapped.isEmpty ? "" : ",\"roles\":{" + mapped.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"\(map)}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    func testResolutionOrderMappedThenProjectFolderThenBase() throws {
        try dir.write("base/dev.json", roleJSON("dev", model: "base-model"))
        try dir.write("p/roles/dev.json", roleJSON("dev", model: "project-model"))
        let mappedFile = try dir.write("elsewhere/dev.json", roleJSON("dev", model: "mapped-model"))
        let both = try project(mapped: ["dev": mappedFile.path])
        XCTAssertEqual(store().resolve("dev", in: both).role?.config.model, "mapped-model")
        XCTAssertEqual(store().resolve("dev", in: both).role?.source, .mapped)

        let projectOnly = try project()
        XCTAssertEqual(store().resolve("dev", in: projectOnly).role?.config.model, "project-model")
        XCTAssertEqual(store().resolve("dev", in: projectOnly).role?.source, .project)

        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("p/roles/dev.json"))
        XCTAssertEqual(store().resolve("dev", in: projectOnly).role?.config.model, "base-model")
        XCTAssertEqual(store().resolve("dev", in: projectOnly).role?.source, .base)
    }

    func testProjectRoleShadowsBaseRoleOfTheSameNameInTheLists() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        try dir.write("base/pm.json", roleJSON("pm"))
        try dir.write("p/roles/dev.json", roleJSON("dev", model: "mine"))
        let p = try project()
        XCTAssertEqual(store().baseRoles().roles.map(\.config.name), ["dev", "pm"])
        XCTAssertEqual(store().projectRoles(p).roles.map(\.config.name), ["dev"])
        XCTAssertEqual(store().projectRoles(p).roles.first?.source, .project)
    }

    func testMissingRoleListsWhereItLooked() throws {
        let p = try project()
        let result = store().resolve("ghost", in: p)
        XCTAssertNil(result.role)
        XCTAssertEqual(result.searched.count, 3)
        XCTAssertTrue(result.searched.contains { $0.contains("roles") && $0.contains("project.json") })
        XCTAssertTrue(result.searched.contains { $0.contains(dir.url.appendingPathComponent("p/roles/ghost.json").path) })
        XCTAssertTrue(result.searched.contains { $0.contains(baseDir.appendingPathComponent("ghost.json").path) })
    }

    func testHostileRoleNamesAreNeverLookedUp() throws {
        try dir.write("secret.json", roleJSON("secret"))
        let p = try project()
        for name in ["../secret", "a/b", "Dev", "--force", ""] {
            let r = store().resolve(name, in: p)
            XCTAssertNil(r.role, name)
            XCTAssertEqual(r.searched, [], "\(name) must not be turned into a path")
        }
    }

    func testMappedRoleIsReadOnly() throws {
        let file = try dir.write("elsewhere/dev.json", roleJSON("dev"))
        let p = try project(mapped: ["dev": file.path])
        let role = try XCTUnwrap(store().projectRoles(p).roles.first { $0.source == .mapped })
        XCTAssertFalse(role.isEditable)
        XCTAssertFalse(try XCTUnwrap(store().resolve("dev", in: p).role).isEditable)
    }

    func testMappedFileMustCarryTheNameOfItsEntry() throws {
        try dir.write("p/roles/reviewer.json", roleJSON("reviewer", model: "folder"))
        let file = try dir.write("elsewhere/rev.json", roleJSON("reviewer", model: "mapped"))
        let p = try project(mapped: ["dev": file.path])
        XCTAssertNil(store().resolve("dev", in: p).role, "a mapped file whose name is not its entry's key is not used for that entry")
        let listed = store().projectRoles(p)
        XCTAssertFalse(listed.roles.contains { $0.source == .mapped })
        XCTAssertTrue(listed.problems.joined().contains("dev"))
        XCTAssertEqual(listed.roles.first { $0.config.name == "reviewer" }?.config.model, "folder", "the folder's reviewer is not hidden by it")
    }

    func testMalformedFileIsReportedAndOthersStillLoad() throws {
        try dir.write("base/pm.json", roleJSON("pm"))
        try dir.write("base/broken.json", "{ not json")
        try dir.write("base/dev.json", roleJSON("dev"))
        let result = store().baseRoles()
        XCTAssertEqual(result.roles.map(\.config.name), ["dev", "pm"])
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(result.problems[0].contains("broken.json"))
    }

    func testRoleFileNameMustMatchName() throws {
        try dir.write("base/dev.json", roleJSON("pm"))
        let result = store().baseRoles()
        XCTAssertEqual(result.roles, [])
        XCTAssertTrue(result.problems.joined().contains("dev.json"))
    }

    func testSymlinkedRoleFileIsSkippedWithAProblem() throws {
        let real = try dir.write("elsewhere/dev.json", roleJSON("dev"))
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: baseDir.appendingPathComponent("dev.json"), withDestinationURL: real)
        let result = store().baseRoles()
        XCTAssertEqual(result.roles, [])
        XCTAssertTrue(result.problems.joined().contains("symbolic link"))
    }

    func testRoleWithoutNewFieldsLoadsLikeBefore() throws {
        // The shape of Orchard's dev.json: no displayName, no advanced, listed under "roles" in project.json.
        let file = try dir.write("orchard/roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[\"Read\"],\"skills\":[\"superpowers\"],\"instructionFile\":\"dev.md\"}")
        try dir.write("orchard/roles/dev.md", "Be brief.")
        let p = try project(mapped: ["dev": file.path])
        let role = try XCTUnwrap(store().resolve("dev", in: p).role)
        XCTAssertNil(role.config.displayName)
        XCTAssertEqual(store().instructions(of: role), "Be brief.")
    }

    func testInstructionsComeFromTheRolesOwnMarkdownFileOrTheLegacyName() throws {
        try dir.write("base/pm.json", roleJSON("pm"))
        try dir.write("base/pm.md", "pm text")
        try dir.write("base/dev.json", roleJSON("dev", extra: "").replacingOccurrences(of: "dev.md", with: "legacy.md"))
        try dir.write("base/legacy.md", "legacy text")
        let roles = store().baseRoles().roles
        XCTAssertEqual(store().instructions(of: try XCTUnwrap(roles.first { $0.config.name == "pm" })), "pm text")
        XCTAssertEqual(store().instructions(of: try XCTUnwrap(roles.first { $0.config.name == "dev" })), "legacy text")
    }

    // MARK: seeding

    func testSeedCreatesThreeDefaultsOnlyWhenFolderIsMissing() throws {
        XCTAssertTrue(RoleSeeder.seedIfMissing(baseDir: baseDir))
        XCTAssertEqual(store().baseRoles().roles.map(\.config.name), ["dev", "pm", "reviewer"])
        for r in store().baseRoles().roles { XCTAssertFalse(store().instructions(of: r).isEmpty, r.config.name) }

        try FileManager.default.removeItem(at: baseDir.appendingPathComponent("pm.json"))
        XCTAssertFalse(RoleSeeder.seedIfMissing(baseDir: baseDir), "the folder exists: nothing is created again")
        XCTAssertEqual(store().baseRoles().roles.map(\.config.name), ["dev", "reviewer"], "a deleted default stays deleted")

        let empty = dir.url.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(RoleSeeder.seedIfMissing(baseDir: empty))
        XCTAssertEqual(RoleStore(baseDir: empty).baseRoles().roles, [], "an empty existing folder is left alone")
    }

    func testSeedFailureDoesNotThrowAndLeavesNoHalfFolder() throws {
        let blocker = try dir.write("blocker", "i am a file")
        XCTAssertFalse(RoleSeeder.seedIfMissing(baseDir: blocker.appendingPathComponent("roles")))
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix("roles.seed") })
    }

    func testDefaultsAreValidAndConcise() throws {
        _ = RoleSeeder.seedIfMissing(baseDir: baseDir)
        let roles = store().baseRoles().roles
        XCTAssertEqual(roles.count, 3)
        for r in roles {
            XCTAssertEqual(RoleValidator.problems(for: r.config), [], r.config.name)
            XCTAssertEqual(r.config.outputStyle, "concise")
            XCTAssertEqual(r.config.instructionFile, "\(r.config.name).md")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [root.appendingPathComponent("scripts/validate-config.sh").path, r.fileURL.path]
            p.standardOutput = Pipe(); p.standardError = Pipe(); try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "validate-config.sh accepts \(r.config.name)")
        }
        XCTAssertEqual(roles.first { $0.config.name == "pm" }?.config.model, "opus")
        XCTAssertEqual(roles.first { $0.config.name == "dev" }?.config.model, "sonnet")
        XCTAssertEqual(roles.first { $0.config.name == "reviewer" }?.config.model, "opus")
    }
}
