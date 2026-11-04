import XCTest
@testable import AgentPanel

@MainActor
final class AddProjectFlowTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir(); calls = []; trustCalls = [] }

    private var code: String { dir.url.appendingPathComponent("code").path }
    private var wiki: String { dir.url.appendingPathComponent("wiki").path }
    private var settings: URL { dir.url.appendingPathComponent("projects.json") }

    nonisolated(unsafe) private var calls: [[String]] = []
    nonisolated(unsafe) private var trustCalls: [[String]] = []

    /// Plays create-project.sh: writes the folders and a valid project.json, or fails.
    /// Plays trust-folder.sh too (recorded apart, so `calls` stays the create-project.sh runs).
    private struct FakeScripts: ScriptRunning {
        let record: @Sendable ([String]) -> Void
        var fail: String?
        var trust: (@Sendable ([String]) -> Void)? = nil
        var trustFails = false
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult {
            if script == .trustFolder {
                trust?(arguments)
                return trustFails ? ScriptResult(status: 1, stdout: "", stderr: "ERROR: ~/.claude.json is not valid JSON") : ScriptResult(status: 0, stdout: "", stderr: "")
            }
            record(arguments)
            if let fail { return ScriptResult(status: 1, stdout: "", stderr: fail) }
            var a = arguments
            let existing = a.first == "--existing"
            while let first = a.first, first.hasPrefix("--") { a.removeFirst(["--branch", "--build-command", "--test-command"].contains(first) ? 2 : 1) }
            let (repo, data, id, name) = (a[0], a[1], a[2], a[3])
            let fm = FileManager.default
            if !existing { try fm.createDirectory(atPath: repo, withIntermediateDirectories: true) }
            try fm.createDirectory(atPath: data + "/agent-panel", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: data + "/tasks", withIntermediateDirectories: true)
            let json = #"{"id":"\#(id)","name":"\#(name)","repoPath":"\#(repo)","dataDir":"\#(data)","maxParallel":2,"sharedFiles":[],"screenshots":false}"#
            try json.write(toFile: data + "/agent-panel/project.json", atomically: true, encoding: .utf8)
            return ScriptResult(status: 0, stdout: "\(data)/agent-panel/project.json\n", stderr: "")
        }
    }

    private struct NoValidation: ScriptRunning {
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { ScriptResult(status: 0, stdout: "", stderr: "") }
    }

    private static let gitRepo = RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "main")

    private func flow(fail: String? = nil, ids: Set<String> = [], registered: Set<String> = [], facts: RepoFacts = gitRepo, probe: ProjectProbe? = nil,
                      trustFails: Bool = false) -> AddProjectFlow {
        try? FileManager.default.createDirectory(atPath: code, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: wiki, withIntermediateDirectories: true)
        let box = self
        let found = probe ?? ProjectProbe(facts: facts)
        return AddProjectFlow(scripts: FakeScripts(record: { args in DispatchQueue.main.sync { box.calls.append(args) } }, fail: fail,
                                                   trust: { args in DispatchQueue.main.sync { box.trustCalls.append(args) } }, trustFails: trustFails),
                              registry: ProjectRegistry(settingsURL: settings, scripts: NoValidation()),
                              probe: { _ in found }, listSimulators: { ["iPhone 17 Pro", "iPhone 16"] },
                              existingIDs: { ids }, registeredRepoPaths: { registered }, repoParent: code, dataRoot: wiki)
    }

    // MARK: N7
    func testAMissingParentFolderIsReportedBeforeAnythingIsWritten() {
        let f = flow()
        f.name = "Recipe Box"
        f.repoParent = dir.url.appendingPathComponent("nope").path
        XCTAssertTrue(f.problems.contains { $0.contains("nope") && $0.contains("does not exist") }, "\(f.problems)")
        XCTAssertFalse(f.canSubmit)
    }

    func testWithoutSimulatorsTheIOSPresetSaysSoAndWritesNoDefault() async {
        let box = self
        let f = AddProjectFlow(scripts: FakeScripts(record: { args in DispatchQueue.main.sync { box.calls.append(args) } }),
                               registry: ProjectRegistry(settingsURL: settings, scripts: NoValidation()),
                               probe: { _ in ProjectProbe(facts: Self.gitRepo) }, listSimulators: { [] },
                               existingIDs: { [] }, repoParent: code, dataRoot: wiki)
        try? FileManager.default.createDirectory(atPath: code, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: wiki, withIntermediateDirectories: true)
        f.name = "Recipe Box"
        f.preset = .ios
        await f.loadSimulators()
        XCTAssertTrue(f.problems.contains { $0.contains("no simulators") }, "\(f.problems)")
        let project = await f.submit()
        XCTAssertNil(project)
        XCTAssertTrue(calls.isEmpty, "the script must not run with an invented simulator")
    }

    // MARK: checks before anything is written

    func testAnEmptyNameBlocksSubmitting() {
        let f = flow()
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.problems.joined().contains("name"))
        f.name = "Recipe Box"
        XCTAssertTrue(f.canSubmit)
        XCTAssertEqual(f.names?.slug, "recipe-box")
    }

    func testAnExistingIdOrFolderBlocksAndSaysWhat() throws {
        let f = flow(ids: ["recipe-box"])
        f.name = "Recipe Box"
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.problems.joined().contains("already in the list"))
        let g = flow()
        g.name = "Recipe Box"
        try FileManager.default.createDirectory(atPath: code + "/recipe-box", withIntermediateDirectories: true)
        XCTAssertFalse(g.canSubmit)
        XCTAssertTrue(g.problems.joined().contains(code + "/recipe-box"))
    }

    func testAnOwnerThatIsNotAGitHubNameBlocksOnlyWhenARepositoryIsWanted() {
        let f = flow(); f.name = "Recipe Box"; f.githubOwner = "a b"
        XCTAssertTrue(f.canSubmit, "GitHub is not wanted yet")
        f.github = .privateRepo
        XCTAssertFalse(f.canSubmit)
    }

    // MARK: new project

    func testANewProjectIsCreatedRegisteredAndReported() async throws {
        let f = flow()
        f.name = "Recipe Box"
        let created = await f.submit()
        XCTAssertEqual(created?.id, "recipe-box")
        XCTAssertEqual(calls.first, [code + "/recipe-box", wiki + "/recipe-box", "recipe-box", "Recipe Box", "other", "RecipeBox", ""])
        XCTAssertEqual(f.phase, .done("recipe-box"))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((o["projects"] as? [String])?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki + "/recipe-box/tasks/G1.md"), "GitHub was not asked for")
    }

    func testTheIOSPresetIsPassedOn() async {
        let f = flow(); f.name = "Çiçek"; f.preset = .ios; f.simulator = "iPhone 16"
        _ = await f.submit()
        XCTAssertEqual(Array(calls[0].suffix(3)), ["ios", "Cicek", "iPhone 16"])
    }

    func testAScriptFailureIsShownAndNothingIsRegistered() async {
        let f = flow(fail: "ERROR: git init failed")
        f.name = "Recipe Box"
        let created = await f.submit()
        XCTAssertNil(created)
        XCTAssertEqual(f.phase, .failed("ERROR: git init failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testARegistrationFailureRemovesTheFoldersThisRunMade() async throws {
        let f = flow()
        f.name = "Recipe Box"
        // The settings file is unreadable, so registering fails after the script has made the folders.
        try "{ broken".write(to: settings, atomically: true, encoding: .utf8)
        let created = await f.submit()
        XCTAssertNil(created)
        guard case .failed = f.phase else { return XCTFail("\(f.phase)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: code + "/recipe-box"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki + "/recipe-box"))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ broken")
    }

    func testAGitHubChoiceOnlyAsksForTheSheetAfterTheProjectExists() async throws {
        let f = flow(); f.name = "Recipe Box"; f.github = .privateRepo; f.githubOwner = "my-org"
        _ = await f.submit()
        XCTAssertEqual(f.publishRequest?.visibility, .privateRepo)
        XCTAssertEqual(f.publishRequest?.owner, "my-org")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki + "/recipe-box/tasks/G1.md"), "no G1 card any more")
        let failing = flow(fail: "boom"); failing.name = "Other One"; failing.github = .publicRepo
        _ = await failing.submit()
        XCTAssertNil(failing.publishRequest)
    }

    func testASecondSubmitWhileWorkingIsIgnored() async {
        let f = flow(); f.name = "Recipe Box"
        async let first = f.submit()
        async let second = f.submit()
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: review fixes

    func testCodeAndDataInTheSameParentFolderIsRefused() {
        let f = flow(); f.name = "Recipe Box"; f.dataRoot = code
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.problems.joined().contains("same folder"))
    }

    func testTheDataFolderCannotBeInsideAnExistingRepository() async {
        let f = flow(); f.mode = .existing
        await f.chooseRepo(code + "/old")
        f.dataRoot = code + "/old"
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.problems.joined().contains("inside"))
    }

    func testARepositoryThatAnotherProjectUsesIsRefused() async {
        let f = flow(registered: [code + "/old"]); f.mode = .existing
        await f.chooseRepo(code + "/old")
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.problems.joined().contains("already used"))
    }

    func testAnXcodeProjectNameWithASpaceIsFineAndOneWithAQuoteIsNot() async {
        let ok = flow(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "main", xcodeProject: "My App.xcodeproj")); ok.mode = .existing
        await ok.chooseRepo(code + "/aa")
        XCTAssertEqual(ok.names?.xcodeName, "My App")
        XCTAssertTrue(ok.canSubmit)
        let bad = flow(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "main", xcodeProject: "A'b.xcodeproj")); bad.mode = .existing
        await bad.chooseRepo(code + "/bb")
        XCTAssertFalse(bad.canSubmit)
        XCTAssertTrue(bad.problems.joined().contains("Xcode"))
    }

    func testTheGitHubChoiceIsIgnoredForAnExistingRepository() async throws {
        let f = flow(); f.mode = .existing
        await f.chooseRepo(code + "/old")
        f.github = .publicRepo
        let created = await f.submit()
        XCTAssertNotNil(created)
        XCTAssertNil(f.publishRequest)
    }

    // MARK: existing data folder

    func testADataFolderThatAlreadyExistsIsUsedForAnExistingRepository() async throws {
        let f = flow(); f.mode = .existing
        try FileManager.default.createDirectory(atPath: wiki + "/old/tasks", withIntermediateDirectories: true)
        await f.chooseRepo(code + "/old")
        XCTAssertTrue(f.canSubmit, f.problems.joined(separator: "; "))
        XCTAssertTrue(f.usesExistingData)
        let created = await f.submit()
        XCTAssertNotNil(created, "\(f.phase)")
    }

    func testSettingsInTheDataFolderThatBelongToAnotherRepositoryBlock() async throws {
        let f = flow(); f.mode = .existing
        try FileManager.default.createDirectory(atPath: wiki + "/old/agent-panel", withIntermediateDirectories: true)
        try #"{"id":"old","name":"Old","repoPath":"/somewhere/else","dataDir":"x","maxParallel":2,"sharedFiles":[]}"#.write(toFile: wiki + "/old/agent-panel/project.json", atomically: true, encoding: .utf8)
        await f.chooseRepo(code + "/old")
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.problems.joined().contains("another repository"))
    }

    func testAFailedRegistrationNeverRemovesADataFolderThatWasThereBefore() async throws {
        let f = flow(); f.mode = .existing
        try FileManager.default.createDirectory(atPath: wiki + "/keep", withIntermediateDirectories: true)
        try "mine".write(toFile: wiki + "/keep/notes.md", atomically: true, encoding: .utf8)
        await f.chooseRepo(code + "/keep")
        try "{ broken".write(to: settings, atomically: true, encoding: .utf8)
        _ = await f.submit()
        XCTAssertEqual(try String(contentsOfFile: wiki + "/keep/notes.md", encoding: .utf8), "mine")
    }

    // MARK: existing project

    func testChoosingARepositoryFillsInWhatIsKnownAboutIt() async {
        let f = flow(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "trunk", xcodeProject: "Pets.xcodeproj", worktreesIgnored: false))
        f.mode = .existing
        await f.chooseRepo(code + "/Pets App")
        XCTAssertEqual(f.name, "Pets App")
        XCTAssertEqual(f.preset, .ios)
        XCTAssertEqual(f.simulator, "iPhone 17 Pro")
        XCTAssertEqual(f.names?.repoDir, code + "/Pets App")
        XCTAssertEqual(f.names?.dataDir, wiki + "/pets-app")
        XCTAssertTrue(f.canSubmit)
    }

    func testAnExistingRepositoryIsRegisteredWithoutCreatingIt() async throws {
        let f = flow(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "trunk"))
        f.mode = .existing
        await f.chooseRepo(code + "/old")
        let created = await f.submit()
        XCTAssertEqual(created?.id, "old")
        XCTAssertEqual(Array(calls[0].prefix(3)), ["--existing", "--branch", "trunk"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: code + "/old"), "an existing repository is never created")
    }

    func testASubfolderOfARepositoryOrARepositoryWithoutCommitsBlocks() async {
        for facts in [RepoFacts(isGitRepo: true, isTopLevel: false, hasCommits: true, branch: "main"), RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: false, branch: "main")] {
            let f = flow(facts: facts); f.mode = .existing
            await f.chooseRepo(code + "/x")
            XCTAssertFalse(f.canSubmit)
            XCTAssertFalse(f.problems.isEmpty)
        }
    }

    func testAFailedRegistrationNeverRemovesAnExistingRepository() async throws {
        let f = flow(); f.mode = .existing
        await f.chooseRepo(code + "/keep")
        try FileManager.default.createDirectory(atPath: code + "/keep", withIntermediateDirectories: true)
        try "mine".write(toFile: code + "/keep/file.txt", atomically: true, encoding: .utf8)
        try "{ broken".write(to: settings, atomically: true, encoding: .utf8)
        _ = await f.submit()
        XCTAssertEqual(try String(contentsOfFile: code + "/keep/file.txt", encoding: .utf8), "mine")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki + "/keep"))
    }

    // MARK: N164 detected facts, questions, no git, trust, Start the PM

    private func nodeProbe(_ candidates: [String] = ["main"], branch: String = "main", ecosystems: [ProjectProbe.Ecosystem] = [.node]) -> ProjectProbe {
        ProjectProbe(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: branch), mainCandidates: candidates,
                     ecosystems: ecosystems, buildCommand: "npm run build", testCommand: "npm test")
    }

    private func xcodeProbe(projects: [String] = ["Pets.xcodeproj"], schemes: [String] = ["Pets"]) -> ProjectProbe {
        let head = "xcodebuild -project '\(projects[0])' -scheme '\(schemes.first ?? "Pets")' -destination 'id=$UDID' -derivedDataPath build/dd"
        return ProjectProbe(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "main", xcodeProject: projects[0]), mainCandidates: ["main"],
                            ecosystems: [.xcode], buildCommand: head + " build", testCommand: head + " test", xcodeSchemes: schemes, xcodeProjects: projects)
    }

    func testChoosingAFolderFillsTheFormFromTheProbeAndMarksItDetected() async {
        let f = flow(probe: nodeProbe()); f.mode = .existing
        await f.chooseRepo(code + "/shop")
        XCTAssertEqual(f.mainBranch, "main"); XCTAssertEqual(f.buildCommand, "npm run build"); XCTAssertEqual(f.testCommand, "npm test")
        for field in [AddProjectFlow.Field.name, .mainBranch, .preset, .buildCommand, .testCommand] { XCTAssertTrue(f.isDetected(field), "\(field)") }
        XCTAssertEqual(f.questions, [])
        XCTAssertTrue(f.canSubmit, f.problems.joined(separator: "; "))
        f.buildCommand = "make"
        XCTAssertFalse(f.isDetected(.buildCommand), "an edited value is the user's, not detected")
        f.name = "Shop Two"
        XCTAssertFalse(f.isDetected(.name))
    }

    func testTheReviewedBranchAndCommandsAreWritten() async {
        let f = flow(probe: nodeProbe()); f.mode = .existing
        await f.chooseRepo(code + "/shop")
        f.testCommand = "npm test -- --ci"
        _ = await f.submit()
        XCTAssertEqual(Array(calls[0].prefix(7)), ["--existing", "--branch", "main", "--build-command", "npm run build", "--test-command", "npm test -- --ci"])
    }

    func testEmptyCommandsAreLeftOutAndALineBreakBlocks() async {
        let f = flow(probe: nodeProbe()); f.mode = .existing
        await f.chooseRepo(code + "/shop")
        f.buildCommand = "  "; f.testCommand = ""
        _ = await f.submit()
        XCTAssertFalse(calls[0].contains("--build-command")); XCTAssertFalse(calls[0].contains("--test-command"))
        let g = flow(); g.name = "Recipe Box"; g.testCommand = "a\nb"
        XCTAssertFalse(g.canSubmit)
        XCTAssertTrue(g.problems.joined().contains("line break"))
    }

    func testANewProjectTakesATestCommand() async {
        let f = flow(); f.name = "Recipe Box"; f.testCommand = "swift test"
        _ = await f.submit()
        XCTAssertEqual(Array(calls[0].prefix(2)), ["--test-command", "swift test"])
        XCTAssertEqual(f.questions, [], "a new project has nothing to ask")
    }

    func testABranchMismatchIsAskedAndBlocksUntilChosen() async {
        let f = flow(probe: nodeProbe(["main", "feature"], branch: "feature")); f.mode = .existing
        await f.chooseRepo(code + "/shop")
        XCTAssertEqual(f.questions, [.mainBranch])
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.problems.joined().contains("main branch"))
        XCTAssertFalse(f.isDetected(.mainBranch), "an unclear guess is not shown as detected")
        f.chooseMainBranch("feature")
        XCTAssertEqual(f.questions, [])
        XCTAssertTrue(f.canSubmit, f.problems.joined(separator: "; "))
        _ = await f.submit()
        XCTAssertEqual(Array(calls[0].prefix(3)), ["--existing", "--branch", "feature"])
    }

    func testSeveralEcosystemsAskToConfirmTheCommands() async {
        let f = flow(probe: nodeProbe(ecosystems: [.node, .python])); f.mode = .existing
        await f.chooseRepo(code + "/shop")
        XCTAssertEqual(f.questions, [.commands])
        XCTAssertFalse(f.canSubmit)
        XCTAssertTrue(f.questionText(.commands).contains("Node") && f.questionText(.commands).contains("Python"), f.questionText(.commands))
        f.confirmCommands()
        XCTAssertTrue(f.canSubmit)
        let g = flow(probe: nodeProbe(ecosystems: [.node, .make])); g.mode = .existing
        await g.chooseRepo(code + "/shop2")
        g.testCommand = "make test"
        XCTAssertEqual(g.questions, [], "editing a command answers the question")
    }

    func testSeveralXcodeProjectsAskWhichOneAndTheChoiceUpdatesTheCommands() async {
        let f = flow(probe: xcodeProbe(projects: ["Pets.xcodeproj", "Tools.xcodeproj"])); f.mode = .existing
        await f.chooseRepo(code + "/pets")
        XCTAssertEqual(f.preset, .ios)
        XCTAssertEqual(f.questions, [.xcodeProject])
        XCTAssertFalse(f.canSubmit)
        f.chooseXcodeProject("Tools.xcodeproj")
        XCTAssertEqual(f.questions, [])
        XCTAssertEqual(f.names?.xcodeName, "Tools")
        XCTAssertEqual(f.xcodeScheme, "Tools")
        XCTAssertEqual(f.buildCommand, "xcodebuild -project 'Tools.xcodeproj' -scheme 'Tools' -destination 'id=$UDID' -derivedDataPath build/dd build")
        XCTAssertTrue(f.testCommand.hasPrefix("xcodebuild -project 'Tools.xcodeproj' -scheme 'Tools'"))
        _ = await f.submit()
        XCTAssertEqual(Array(calls[0].suffix(3)), ["ios", "Tools", "iPhone 17 Pro"])
    }

    func testSeveralSchemesAskWhichOne() async {
        let f = flow(probe: xcodeProbe(schemes: ["Pets", "PetsKit"])); f.mode = .existing
        await f.chooseRepo(code + "/pets")
        XCTAssertEqual(f.xcodeScheme, "Pets")
        XCTAssertEqual(f.questions, [.xcodeScheme])
        f.chooseScheme("PetsKit")
        XCTAssertEqual(f.questions, [])
        XCTAssertTrue(f.buildCommand.contains("-scheme 'PetsKit'") && f.testCommand.contains("-scheme 'PetsKit'"))
        f.preset = .other
        XCTAssertEqual(f.questions, [], "the scheme only matters for an iOS project")
    }

    func testAFolderWithoutGitIsAddedAndInitializeGitComesLater() async {
        let f = flow(facts: RepoFacts()); f.mode = .existing
        await f.chooseRepo(code + "/plain")
        XCTAssertTrue(f.canSubmit, f.problems.joined(separator: "; "))
        XCTAssertTrue(addProjectPreviewRows(f).first { $0.label == "Repository" }?.value.contains("Initialize git") == true)
        XCTAssertFalse(f.startsPM, "the PM cannot start before git is there")
        XCTAssertFalse(f.isDetected(.mainBranch), "\"main\" is a default here, not something found")
        let created = await f.submit()
        XCTAssertNotNil(created, "\(f.phase)")
        XCTAssertEqual(Array(calls[0].prefix(4)), ["--existing", "--no-git", "--branch", "main"])
    }

    func testRegisteringTrustsTheFolderForClaudeCode() async {
        let f = flow(); f.mode = .existing
        await f.chooseRepo(code + "/old")
        _ = await f.submit()
        XCTAssertEqual(trustCalls, [[code + "/old"]])
        let g = flow(); g.name = "Recipe Box"
        _ = await g.submit()
        XCTAssertEqual(trustCalls.last, [code + "/recipe-box"])
    }

    func testATrustFailureIsANoticeAndTheProjectStays() async {
        let f = flow(trustFails: true); f.name = "Recipe Box"
        let created = await f.submit()
        XCTAssertNotNil(created)
        XCTAssertEqual(f.phase, .done("recipe-box"))
        XCTAssertTrue(f.notice?.contains("trust") == true, "\(String(describing: f.notice))")
    }

    func testNothingIsTrustedWhenTheProjectWasNotAdded() async {
        let f = flow(fail: "boom"); f.name = "Recipe Box"
        _ = await f.submit()
        XCTAssertEqual(trustCalls, [])
    }

    func testStartThePMIsOnByDefault() async {
        let f = flow(); f.name = "Recipe Box"
        XCTAssertTrue(f.startPM); XCTAssertTrue(f.startsPM)
        f.startPM = false
        XCTAssertFalse(f.startsPM)
    }

    func testANewFolderChoiceForgetsTheOldAnswers() async {
        let f = flow(probe: nodeProbe(["main", "feature"], branch: "feature")); f.mode = .existing
        await f.chooseRepo(code + "/shop")
        f.chooseMainBranch("feature")
        await f.chooseRepo(code + "/shop2")
        XCTAssertEqual(f.questions, [.mainBranch])
        XCTAssertEqual(f.mainBranch, "main")
    }
}

@MainActor
final class AddProjectSheetTests: XCTestCase {
    private func flow(github: AddProjectFlow.GitHubChoice = .notNow) throws -> AddProjectFlow {
        let dir = try TempDir()
        struct Scripts: ScriptRunning { func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { ScriptResult(status: 0, stdout: "", stderr: "") } }
        let f = AddProjectFlow(scripts: Scripts(), registry: ProjectRegistry(settingsURL: dir.url.appendingPathComponent("p.json"), scripts: Scripts()),
                               probe: { _ in ProjectProbe(facts: RepoFacts()) }, listSimulators: { ["iPhone 17 Pro"] }, existingIDs: { [] }, repoParent: "/code", dataRoot: "/wiki")
        f.name = "Recipe Box"; f.github = github
        return f
    }

    func testThePreviewListsEveryNameBeforeAnythingIsCreated() throws {
        let rows = addProjectPreviewRows(try flow())
        XCTAssertEqual(rows.map(\.label), ["Project id", "Repository", "Data", "Trust"])
        XCTAssertEqual(rows[3].value, "Claude Code will trust this folder")
        XCTAssertEqual(rows[0].value, "recipe-box")
        XCTAssertTrue(rows[1].value.contains("/code/recipe-box"))
        XCTAssertEqual(rows[2].value, "/wiki/recipe-box")
    }

    func testTheTrustRowNamesTheToolsInUse() throws {
        let f = try flow()
        XCTAssertEqual(trustText(f), "Claude Code will trust this folder")
        f.pmTool = PMToolPicker(current: .codex, followsDefault: false, status: { PMToolStatus() })
        XCTAssertEqual(trustText(f), "Codex will trust this folder")
        let dir = try TempDir()
        try dir.write("roles/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"m\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"d.md\"}")
        f.roleStore = RoleStore(baseDir: dir.url.appendingPathComponent("roles"))
        XCTAssertEqual(trustText(f), "Claude Code and Codex will trust this folder")
    }

    func testThePreviewSaysTheGitHubStepNeedsYourConfirmation() throws {
        let rows = addProjectPreviewRows(try flow(github: .publicRepo))
        let github = try XCTUnwrap(rows.first { $0.label == "GitHub" })
        XCTAssertTrue(github.value.contains("public"))
        XCTAssertTrue(github.value.contains("you confirm"))
    }

    func testThePreviewSaysAnExistingDataFolderIsKept() throws {
        let f = try flow(); f.mode = .existing
        let dir = try TempDir()
        let g = AddProjectFlow(scripts: f_scripts(), registry: ProjectRegistry(settingsURL: dir.url.appendingPathComponent("p.json"), scripts: f_scripts()),
                               probe: { _ in ProjectProbe(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "main")) }, listSimulators: { [] }, existingIDs: { [] },
                               fileExists: { _ in true }, repoParent: "/code", dataRoot: "/wiki")
        g.mode = .existing; g.name = "Old"
        let semaphore = expectation(description: "chosen")
        Task { await g.chooseRepo("/code/old"); semaphore.fulfill() }
        wait(for: [semaphore], timeout: 5)
        XCTAssertTrue(addProjectPreviewRows(g).first { $0.label == "Data" }?.value.contains("already there") == true)
    }

    private func f_scripts() -> ScriptRunning {
        struct S: ScriptRunning { func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { ScriptResult(status: 0, stdout: "", stderr: "") } }
        return S()
    }

    func testThePreviewIsEmptyWithoutAUsableName() throws {
        let f = try flow(); f.name = "!!!"
        XCTAssertEqual(addProjectPreviewRows(f), [])
    }

    func testTheSheetShowsDetectedValuesAndQuestionsForAnExistingFolder() async throws {
        let dir = try TempDir()
        let head = "xcodebuild -project 'Pets.xcodeproj' -scheme 'Pets' -destination 'id=$UDID' -derivedDataPath build/dd"
        let probe = ProjectProbe(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "feature", xcodeProject: "Pets.xcodeproj"),
                                 mainCandidates: ["main", "feature"], ecosystems: [.xcode, .swiftPackage], buildCommand: head + " build", testCommand: head + " test",
                                 xcodeSchemes: ["Pets", "PetsKit"], xcodeProjects: ["Pets.xcodeproj"])
        let g = AddProjectFlow(scripts: f_scripts(), registry: ProjectRegistry(settingsURL: dir.url.appendingPathComponent("p.json"), scripts: f_scripts()),
                               probe: { _ in probe }, listSimulators: { ["iPhone 17 Pro"] }, existingIDs: { [] }, fileExists: { _ in false }, repoParent: "/code", dataRoot: "/wiki")
        g.mode = .existing
        await g.chooseRepo("/code/Pets")
        XCTAssertEqual(g.questions, [.mainBranch, .commands, .xcodeScheme])
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AddProjectSheet(flow: g, onAdded: { _ in }, onCancel: {}), size: CGSize(width: 640, height: 980)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("add-project-questions.png")) }
        g.chooseMainBranch("main"); g.confirmCommands(); g.chooseScheme("Pets")
        let answered = try XCTUnwrap(SnapshotRenderer.render(view: AddProjectSheet(flow: g, onAdded: { _ in }, onCancel: {}), size: CGSize(width: 640, height: 820)))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try answered.write(to: URL(fileURLWithPath: out).appendingPathComponent("add-project-detected.png")) }
        let plain = AddProjectFlow(scripts: f_scripts(), registry: ProjectRegistry(settingsURL: dir.url.appendingPathComponent("p.json"), scripts: f_scripts()),
                                   probe: { _ in ProjectProbe(facts: RepoFacts()) }, listSimulators: { [] }, existingIDs: { [] }, fileExists: { _ in false }, repoParent: "/code", dataRoot: "/wiki")
        plain.mode = .existing
        await plain.chooseRepo("/code/notes")
        let nogit = try XCTUnwrap(SnapshotRenderer.render(view: AddProjectSheet(flow: plain, onAdded: { _ in }, onCancel: {}), size: CGSize(width: 640, height: 720)))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try nogit.write(to: URL(fileURLWithPath: out).appendingPathComponent("add-project-no-git.png")) }
    }

    func testTheSheetRendersInBothModes() throws {
        let f = try flow(github: .privateRepo)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AddProjectSheet(flow: f, onAdded: { _ in }, onCancel: {}), size: CGSize(width: 600, height: 760)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("add-project-new.png")) }
        f.mode = .existing
        let existing = try XCTUnwrap(SnapshotRenderer.render(view: AddProjectSheet(flow: f, onAdded: { _ in }, onCancel: {}), size: CGSize(width: 600, height: 700)))
        XCTAssertGreaterThan(existing.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try existing.write(to: URL(fileURLWithPath: out).appendingPathComponent("add-project-existing.png")) }
    }
}
