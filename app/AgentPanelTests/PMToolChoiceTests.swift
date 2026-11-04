import XCTest
@testable import AgentPanel

/// N367: the PM's tool per project (Add / Edit project). The Claude golden tests were written on main's behaviour first.
@MainActor
final class PMToolChoiceTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private struct Validator: ScriptRunning {
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { ScriptResult(status: 0, stdout: "", stderr: "") }
    }

    private func editSetup() throws -> (EditProjectFlow, URL) {
        let file = try dir.write("p/project.json", #"{"id":"p","name":"P","repoPath":"/r","dataDir":"/d","maxParallel":2,"sharedFiles":[]}"#)
        let settings = try dir.write("projects.json", #"{"projects":["\#(file.path)"]}"#)
        var project = try JSONDecoder().decode(ProjectConfig.self, from: Data(contentsOf: file)); project.sourcePath = file.path
        return (EditProjectFlow(project: project, registry: ProjectRegistry(settingsURL: settings, scripts: Validator())), file)
    }

    // MARK: Claude golden (N367)

    func testClaudeGoldenEditSaveWritesNoRoleFile() async throws {
        let (flow, file) = try editSetup()
        flow.name = "Q"
        let saved = await flow.save()
        XCTAssertNotNil(saved)
        let roles = file.deletingLastPathComponent().appendingPathComponent("roles")
        XCTAssertFalse(FileManager.default.fileExists(atPath: roles.path), "a Claude project gets no pm role file of its own")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(object["roles"]); XCTAssertNil(object["pmTool"])
    }

    // MARK: N367 · PM tool per project

    private static let codexModels = CodexCatalog(models: [CodexModel(id: "gpt-5.5-codex", label: "GPT-5.5 Codex", efforts: ["low", "medium", "high"], defaultEffort: "medium")])

    /// A shared library with the shipped pm role (Claude) and a project with a known project.json.
    private func library() throws -> (RoleStore, ProjectConfig) {
        try dir.write("base/pm.json", #"{"name":"pm","kind":"interactive","tool":"claude","model":"opus","effort":"high","permissionMode":"manual","outputStyle":"concise","allowedTools":["Read","Bash"],"skills":["superpowers"],"instructionFile":"pm.md"}"#)
        try dir.write("base/pm.md", "You are the PM.")
        let file = try dir.write("proj/project.json", #"{"id":"p","name":"P","repoPath":"/r","dataDir":"/d","maxParallel":2,"sharedFiles":[]}"#)
        var project = try JSONDecoder().decode(ProjectConfig.self, from: Data(contentsOf: file)); project.sourcePath = file.path
        return (RoleStore(baseDir: dir.url.appendingPathComponent("base")), project)
    }

    func testDefaultToolIsTheSignedInOneClaudeIfBoth() {
        XCTAssertEqual(PMToolChoice.defaultTool(PMToolStatus()), .claude)
        XCTAssertEqual(PMToolChoice.defaultTool(PMToolStatus(signedIn: [.claude, .codex])), .claude)
        XCTAssertEqual(PMToolChoice.defaultTool(PMToolStatus(signedIn: [.codex])), .codex)
        XCTAssertEqual(PMToolChoice.defaultTool(PMToolStatus(signedIn: [.claude])), .claude)
    }

    func testAToolThatIsNotInstalledIsDisabledWithTheReason() {
        let status = PMToolStatus(installed: [.claude], signedIn: [.claude])
        XCTAssertEqual(PMToolChoice.disabledReason(.codex, status), "Codex is not installed (Setup installs it).")
        XCTAssertNil(PMToolChoice.disabledReason(.claude, status))
        XCTAssertEqual(PMToolChoice.disabledReason(.codex, PMToolStatus(installed: [.codex], codexModels: CodexCatalog(reason: "timed out"))), "Codex lists no models: timed out.")
    }

    func testCodexWritesTheProjectPMRoleAndClaudeTakesItBack() throws {
        let (store, project) = try library()
        XCTAssertEqual(PMToolChoice.current(project: project, store: store), .claude)
        XCTAssertFalse(try PMToolChoice.apply(.claude, project: project, store: store, codexModels: Self.codexModels), "Claude on Claude writes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("proj/roles").path))

        XCTAssertTrue(try PMToolChoice.apply(.codex, project: project, store: store, codexModels: Self.codexModels))
        let role = try XCTUnwrap(store.resolve("pm", in: project).role)
        XCTAssertEqual(role.source, .project)
        XCTAssertEqual(role.config.tool, "codex"); XCTAssertEqual(role.config.model, "gpt-5.5-codex"); XCTAssertEqual(role.config.effort, "medium")
        XCTAssertEqual(role.config.permissionMode, "acceptEdits"); XCTAssertEqual(role.config.skills, []); XCTAssertEqual(role.config.allowedTools, [])
        XCTAssertEqual(store.instructions(of: role), "You are the PM.")
        XCTAssertEqual(PMToolChoice.current(project: project, store: store), .codex)
        let shared = try XCTUnwrap(store.baseRoles().roles.first { $0.config.name == "pm" })
        XCTAssertEqual(shared.config.tool, "claude", "the shared pm role is not touched")

        XCTAssertTrue(try PMToolChoice.apply(.claude, project: project, store: store, codexModels: Self.codexModels))
        let back = try XCTUnwrap(store.resolve("pm", in: project).role).config
        XCTAssertEqual(back.tool, "claude"); XCTAssertEqual(back.model, "opus"); XCTAssertEqual(back.effort, "high"); XCTAssertEqual(back.permissionMode, "manual")
        XCTAssertEqual(back.skills, ["superpowers"]); XCTAssertEqual(back.allowedTools, ["Read", "Bash"])
    }

    func testCodexWithoutAModelIsRefused() throws {
        let (store, project) = try library()
        XCTAssertThrowsError(try PMToolChoice.apply(.codex, project: project, store: store, codexModels: CodexCatalog())) {
            XCTAssertEqual($0 as? PMToolChoice.ChangeError, .noCodexModel)
        }
    }

    func testPickerFollowsTheSignedInToolAndSaysRestart() async throws {
        let add = PMToolPicker(current: .claude, followsDefault: true, rules: CodexRules(home: dir.url),
                               status: { PMToolStatus(installed: [.claude, .codex], signedIn: [.codex], codexModels: Self.codexModels) })
        await add.load()
        XCTAssertEqual(add.choice, .codex)
        XCTAssertNil(add.restartNote, "a new project has no running PM")
        let notInstalled = PMToolPicker(current: .claude, followsDefault: true, status: { PMToolStatus(installed: [.claude], signedIn: [.codex]) })
        await notInstalled.load()
        XCTAssertEqual(notInstalled.choice, .claude, "a tool that is not installed is never picked by default")
        XCTAssertNotNil(notInstalled.reason(.codex))
        let edit = PMToolPicker(current: .claude, followsDefault: false, pmRunning: true, status: { PMToolStatus(installed: [.claude, .codex], signedIn: [.codex], codexModels: Self.codexModels) })
        await edit.load()
        XCTAssertEqual(edit.choice, .claude, "Edit project shows the stored tool")
        edit.choice = .codex
        XCTAssertEqual(edit.restartNote, "Restart the PM to switch: it keeps running on Claude Code until then.")
    }

    func testPickerOffersTheRulesOnlyForCodex() async throws {
        try dir.write("home/.claude/CLAUDE.md", "- wiki first")
        let picker = PMToolPicker(current: .claude, followsDefault: false, rules: CodexRules(home: dir.url.appendingPathComponent("home")), status: { PMToolStatus() })
        XCTAssertFalse(picker.offersRules)
        picker.choice = .codex
        XCTAssertTrue(picker.offersRules)
    }

    func testEditProjectSavesOnlyThePMRoleWhenOnlyTheToolChanged() async throws {
        let (store, project) = try library()
        let settings = try dir.write("projects.json", #"{"projects":["\#(project.sourcePath!)"]}"#)
        let before = try Data(contentsOf: URL(fileURLWithPath: project.sourcePath!))
        let picker = PMToolPicker(current: .claude, followsDefault: false, status: { PMToolStatus(installed: [.claude, .codex], codexModels: Self.codexModels) })
        await picker.load()
        let flow = EditProjectFlow(project: project, registry: ProjectRegistry(settingsURL: settings, scripts: Validator()), pmTool: picker, roleStore: store)
        XCTAssertFalse(flow.isDirty)
        picker.choice = .codex
        XCTAssertTrue(flow.isDirty)
        let saved = await flow.save()
        XCTAssertNotNil(saved)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: project.sourcePath!)), before, "project.json is not rewritten")
        XCTAssertEqual(PMToolChoice.current(project: project, store: store), .codex)
    }

    func testPMToolPickerSnapshot() async throws {
        try dir.write("home/.claude/CLAUDE.md", "- wiki first")
        let code = dir.url.appendingPathComponent("code").path, wiki = dir.url.appendingPathComponent("wiki").path
        try FileManager.default.createDirectory(atPath: code, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: wiki, withIntermediateDirectories: true)
        let flow = AddProjectFlow(scripts: Validator(), registry: ProjectRegistry(settingsURL: dir.url.appendingPathComponent("projects.json"), scripts: Validator()),
                                  probe: { _ in ProjectProbe(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "main")) },
                                  listSimulators: { [] }, existingIDs: { [] }, repoParent: code, dataRoot: wiki)
        flow.name = "Recipe Box"
        let picker = PMToolPicker(current: .claude, followsDefault: true, rules: CodexRules(home: dir.url.appendingPathComponent("home")),
                                  status: { PMToolStatus(installed: [.claude, .codex], signedIn: [.codex], codexModels: Self.codexModels) })
        await picker.load()
        flow.pmTool = picker
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AddProjectSheet(flow: flow, onAdded: { _ in }, onCancel: {}), size: CGSize(width: 640, height: 820)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N367-pm-tool.png")) }
    }
}
