import XCTest
@testable import AgentPanel

final class RepoInspectorTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func git(_ args: [String], in path: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
    }

    private func makeRepo(_ name: String = "r", commit: Bool = true, branch: String = "main") throws -> String {
        let path = dir.url.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", branch], in: path)
        if commit { try git(["commit", "-q", "--allow-empty", "-m", "init"], in: path) }
        return path
    }

    private var inspector: RepoInspector { RepoInspector(runner: ProcessRunner()) }

    func testAnOrdinaryRepositoryIsDescribed() async throws {
        let path = try makeRepo()
        let f = await inspector.inspect(path)
        XCTAssertTrue(f.isGitRepo); XCTAssertTrue(f.isTopLevel); XCTAssertTrue(f.hasCommits)
        XCTAssertEqual(f.branch, "main")
        XCTAssertNil(f.xcodeProject)
        XCTAssertFalse(f.worktreesIgnored)
    }

    func testAFolderThatIsNotARepositoryIsReported() async throws {
        let path = dir.url.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let f = await inspector.inspect(path)
        XCTAssertFalse(f.isGitRepo); XCTAssertFalse(f.hasCommits); XCTAssertNil(f.branch)
    }

    func testASubfolderOfARepositoryIsNotTheTopLevel() async throws {
        let path = try makeRepo()
        let sub = path + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let f = await inspector.inspect(sub)
        XCTAssertTrue(f.isGitRepo); XCTAssertFalse(f.isTopLevel)
    }

    func testARepositoryWithoutCommitsAndAnotherMainBranchAreReported() async throws {
        let empty = try makeRepo("e", commit: false)
        let v1 = await inspector.inspect(empty).hasCommits
        XCTAssertFalse(v1)
        let trunk = try makeRepo("t", branch: "trunk")
        let v2 = await inspector.inspect(trunk).branch
        XCTAssertEqual(v2, "trunk")
    }

    func testAnXcodeProjectAtTheTopLevelIsFound() async throws {
        let path = try makeRepo()
        try FileManager.default.createDirectory(atPath: path + "/Pets.xcodeproj", withIntermediateDirectories: true)
        let v3 = await inspector.inspect(path).xcodeProject
        XCTAssertEqual(v3, "Pets.xcodeproj")
    }

    func testIgnoredWorktreesAreRecognisedFromGitignoreAndFromTheLocalExcludeFile() async throws {
        let a = try makeRepo("a")
        try ".agent-worktrees/\n".write(toFile: a + "/.gitignore", atomically: true, encoding: .utf8)
        let v4 = await inspector.inspect(a).worktreesIgnored
        XCTAssertTrue(v4)
        let b = try makeRepo("b")
        try "/.agent-worktrees/\n".write(toFile: b + "/.git/info/exclude", atomically: true, encoding: .utf8)
        let v5 = await inspector.inspect(b).worktreesIgnored
        XCTAssertTrue(v5)
    }

    func testSimulatorsAreTheInstalledIPhonesWithTheFavouriteFirst() async throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"name":"iPhone 16","isAvailable":true},{"name":"iPhone 17 Pro","isAvailable":true},{"name":"iPad Pro","isAvailable":true},{"name":"iPhone 15","isAvailable":false}],
        "com.apple.CoreSimulator.SimRuntime.iOS-25-0":[{"name":"iPhone 16","isAvailable":true}]}}
        """
        let r = RepoInspector(runner: FakeRunner(output: Data(json.utf8)))
        let list = await r.simulators()
        XCTAssertEqual(list, ["iPhone 17 Pro", "iPhone 16"])
        XCTAssertEqual(RepoInspector.preferredSimulator(in: list), "iPhone 17 Pro")
        XCTAssertEqual(RepoInspector.preferredSimulator(in: ["iPhone 16"]), "iPhone 16")
        XCTAssertNil(RepoInspector.preferredSimulator(in: []))
    }

    func testNoSimulatorsWhenXcodeToolsFail() async throws {
        let r = RepoInspector(runner: FakeRunner(error: ProcessRunner.Failure(message: "xcrun missing")))
        let list = await r.simulators()
        XCTAssertEqual(list, [])
    }

    // MARK: probe

    private func write(_ text: String, _ file: String, in path: String) throws {
        let url = URL(fileURLWithPath: path + "/" + file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testProbeOfAPlainFolderCountsFilesAndStaysEmpty() async throws {
        let path = dir.url.appendingPathComponent("plain").path
        try write("a", "a.txt", in: path); try write("b", "sub/b.txt", in: path)
        let p = await inspector.probe(path)
        XCTAssertFalse(p.facts.isGitRepo)
        XCTAssertEqual(p.fileCount, 2)
        XCTAssertNil(p.remote); XCTAssertEqual(p.mainCandidates, []); XCTAssertEqual(p.ecosystems, [])
    }

    func testProbeReadsRemoteBranchesDirtyTreeAndSize() async throws {
        let path = try makeRepo("g", branch: "trunk")
        try git(["branch", "main"], in: path)
        try git(["remote", "add", "origin", "https://example.com/x.git"], in: path)
        try write("x", "tracked.txt", in: path)
        try git(["add", "."], in: path); try git(["commit", "-q", "-m", "two"], in: path)
        try write("y", "loose.txt", in: path)
        let p = await inspector.probe(path)
        XCTAssertEqual(p.remote, "https://example.com/x.git")
        XCTAssertEqual(p.mainCandidates, ["main", "trunk"])
        XCTAssertEqual(p.dirtyFiles, 1)
        XCTAssertEqual(p.fileCount, 1)
        XCTAssertEqual(p.commitCount, 2)
        XCTAssertNil(p.unpushedCommits)   // no upstream
        XCTAssertNotNil(p.lastCommitDate)
    }

    func testProbeUsesOriginHeadFirstAndCountsUnpushedCommits() async throws {
        let origin = try makeRepo("origin", branch: "develop")
        let clone = dir.url.appendingPathComponent("clone").path
        let c = Process(); c.executableURL = URL(fileURLWithPath: "/usr/bin/git"); c.arguments = ["clone", "-q", origin, clone]
        c.standardOutput = FileHandle.nullDevice; c.standardError = FileHandle.nullDevice
        try c.run(); c.waitUntilExit()
        try git(["commit", "-q", "--allow-empty", "-m", "local"], in: clone)
        let p = await inspector.probe(clone)
        XCTAssertEqual(p.mainCandidates.first, "develop")
        XCTAssertEqual(p.unpushedCommits, 1)
        XCTAssertEqual(p.remote, origin)
    }

    func testProbeFindsEcosystemsAndSuggestsCommands() async throws {
        let swift = try makeRepo("s"); try write("//", "Package.swift", in: swift)
        var p = await inspector.probe(swift)
        XCTAssertEqual(p.ecosystems, [.swiftPackage]); XCTAssertEqual(p.buildCommand, "swift build"); XCTAssertEqual(p.testCommand, "swift test")

        let node = try makeRepo("n")
        try write(#"{"scripts":{"build":"tsc","test":"jest"}}"#, "package.json", in: node); try write("", "pnpm-lock.yaml", in: node)
        p = await inspector.probe(node)
        XCTAssertEqual(p.ecosystems, [.node]); XCTAssertEqual(p.buildCommand, "pnpm run build"); XCTAssertEqual(p.testCommand, "pnpm test")

        let stub = try makeRepo("n2")
        try write(#"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#, "package.json", in: stub)
        p = await inspector.probe(stub)
        XCTAssertNil(p.buildCommand); XCTAssertNil(p.testCommand)

        let py = try makeRepo("p"); try write("[project]", "pyproject.toml", in: py)
        p = await inspector.probe(py)
        XCTAssertEqual(p.ecosystems, [.python]); XCTAssertEqual(p.testCommand, "python3 -m pytest")

        let rust = try makeRepo("r1"); try write("[package]", "Cargo.toml", in: rust)
        p = await inspector.probe(rust)
        XCTAssertEqual(p.ecosystems, [.rust]); XCTAssertEqual(p.testCommand, "cargo test")

        let go = try makeRepo("go"); try write("module x", "go.mod", in: go)
        p = await inspector.probe(go)
        XCTAssertEqual(p.ecosystems, [.go]); XCTAssertEqual(p.buildCommand, "go build ./...")

        let ruby = try makeRepo("rb"); try write("source 'x'", "Gemfile", in: ruby)
        p = await inspector.probe(ruby)
        XCTAssertEqual(p.ecosystems, [.ruby])

        let gradle = try makeRepo("gr"); try write("", "build.gradle.kts", in: gradle); try write("", "gradlew", in: gradle)
        p = await inspector.probe(gradle)
        XCTAssertEqual(p.ecosystems, [.gradle]); XCTAssertEqual(p.buildCommand, "./gradlew build")

        let make = try makeRepo("mk"); try write("build:\n\techo\ntest:\n\techo\n", "Makefile", in: make)
        p = await inspector.probe(make)
        XCTAssertEqual(p.ecosystems, [.make]); XCTAssertEqual(p.buildCommand, "make build"); XCTAssertEqual(p.testCommand, "make test")

        let two = try makeRepo("two"); try write("//", "Package.swift", in: two); try write("{}", "package.json", in: two)
        p = await inspector.probe(two)
        XCTAssertEqual(p.ecosystems, [.swiftPackage, .node])
    }

    func testProbeReadsXcodeSchemesAndBuildsTheXcodebuildTemplate() async throws {
        let path = try makeRepo("x")
        try FileManager.default.createDirectory(atPath: path + "/Pets.xcodeproj", withIntermediateDirectories: true)
        let json = #"{"project":{"name":"Pets","schemes":["PetsKit","Pets"],"targets":["Pets"]}}"#
        let r = RepoInspector(runner: ScriptRunner { exe, args in
            exe.path == "/usr/bin/xcodebuild" ? Data(json.utf8) : try await ProcessRunner().run(exe, args)
        })
        let p = await r.probe(path)
        XCTAssertEqual(p.ecosystems, [.xcode]); XCTAssertEqual(p.xcodeSchemes, ["PetsKit", "Pets"])
        XCTAssertEqual(p.buildCommand, "xcodebuild -project 'Pets.xcodeproj' -scheme 'Pets' -destination 'id=$UDID' -derivedDataPath build/dd build")
        XCTAssertTrue(p.testCommand?.hasSuffix(" test") == true)
    }

    func testProbeListsEveryXcodeProject() async throws {
        let path = try makeRepo("xs")
        for name in ["B.xcodeproj", "A.xcodeproj"] { try FileManager.default.createDirectory(atPath: path + "/" + name, withIntermediateDirectories: true) }
        let r = RepoInspector(runner: ScriptRunner { exe, args in
            if exe.path == "/usr/bin/xcodebuild" { throw ProcessRunner.Failure(message: "no") }
            return try await ProcessRunner().run(exe, args)
        })
        let p = await r.probe(path)
        XCTAssertEqual(p.xcodeProjects, ["A.xcodeproj", "B.xcodeproj"])
        XCTAssertEqual(p.facts.xcodeProject, "A.xcodeproj")
    }

    func testProbeFallsBackToTheProjectNameWhenXcodebuildFails() async throws {
        let path = try makeRepo("x2")
        try FileManager.default.createDirectory(atPath: path + "/Pets.xcodeproj", withIntermediateDirectories: true)
        let r = RepoInspector(runner: ScriptRunner { exe, args in
            if exe.path == "/usr/bin/xcodebuild" { throw ProcessRunner.Failure(message: "boom") }
            return try await ProcessRunner().run(exe, args)
        })
        let p = await r.probe(path)
        XCTAssertEqual(p.xcodeSchemes, [])
        XCTAssertTrue(p.buildCommand?.contains("-scheme 'Pets'") == true)
    }

    func testProbeReadsAgentDocsAndWorkflowNames() async throws {
        let path = try makeRepo("d")
        try write((1...60).map { "line \($0)" }.joined(separator: "\n"), "CLAUDE.md", in: path)
        try write("x", ".codex/config.toml", in: path)
        try write("name: Build and test\non: push\n", ".github/workflows/ci.yml", in: path)
        try write("on: push\n", ".github/workflows/release.yaml", in: path)
        let p = await inspector.probe(path)
        XCTAssertEqual(p.agentDocs.map(\.name), ["CLAUDE.md", ".codex"])
        XCTAssertEqual(p.agentDocs[0].excerpt.split(separator: "\n").count, 40)
        XCTAssertTrue(p.agentDocs[1].isFolder)
        XCTAssertEqual(p.ciWorkflows, ["Build and test", "release.yaml"])
    }

    func testProbeOfARepositoryWithoutCommitsHasNoHistory() async throws {
        let path = try makeRepo("e2", commit: false)
        try write("x", "a.txt", in: path)
        let p = await inspector.probe(path)
        XCTAssertTrue(p.facts.isGitRepo); XCTAssertFalse(p.facts.hasCommits)
        XCTAssertEqual(p.dirtyFiles, 1); XCTAssertEqual(p.commitCount, 0); XCTAssertNil(p.lastCommitDate)
    }

    func testProbeSurvivesACommandThatHangs() async throws {
        let path = try makeRepo("h")
        let script = dir.url.appendingPathComponent("slowgit.sh").path
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        var r = RepoInspector(runner: ProcessRunner(timeout: 0.3, killGrace: 0.2))
        r.git = URL(fileURLWithPath: script)
        let start = Date()
        let p = await r.probe(path)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertFalse(p.facts.isGitRepo)
        XCTAssertNil(p.remote)
    }

    func testProbeWithEveryCommandFailingReturnsEmptyFacts() async throws {
        let r = RepoInspector(runner: FakeRunner(error: ProcessRunner.Failure(message: "no tools")))
        let p = await r.probe(dir.url.path)
        XCTAssertFalse(p.facts.isGitRepo); XCTAssertNil(p.remote); XCTAssertEqual(p.xcodeSchemes, [])
    }
}

/// A runner whose answer comes from a closure, so a test can fake one tool and let git run for real.
struct ScriptRunner: CommandRunner {
    let body: @Sendable (URL, [String]) async throws -> Data
    init(_ body: @escaping @Sendable (URL, [String]) async throws -> Data) { self.body = body }
    func run(_ executable: URL, _ arguments: [String]) async throws -> Data { try await body(executable, arguments) }
}
