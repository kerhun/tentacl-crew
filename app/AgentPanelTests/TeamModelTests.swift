import XCTest
@testable import AgentPanel

@MainActor
final class TeamModelTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet --effort medium\n", stderr: "") }
    }

    private var baseDir: URL { dir.url.appendingPathComponent("base") }
    private var claudeHome: URL { dir.url.appendingPathComponent("claude") }

    private func roleJSON(_ name: String, model: String = "sonnet", extra: String = "") -> String {
        "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"\(model)\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[\"Read\"],\"skills\":[\"superpowers\"],\"instructionFile\":\"\(name).md\"\(extra)}"
    }

    private func project(mapped: [String: String] = [:]) throws -> ProjectConfig {
        let map = mapped.isEmpty ? "" : ",\"roles\":{" + mapped.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"\(dir.url.appendingPathComponent("repo").path)\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"\(map)}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private func model(project: ProjectConfig? = nil, scriptsAvailable: Bool = true) -> TeamModel {
        let s = scripts!
        return TeamModel(store: RoleStore(baseDir: baseDir), catalog: SkillCatalog(claudeHome: claudeHome), claudeHome: claudeHome,
                         makeScripts: { _ in scriptsAvailable ? s : nil }, project: project, codexCatalog: CodexModelCatalog(executable: try? fakeCodex()))
    }

    /// A stand-in `codex` that prints the `codex debug models` fixture (the real one is never run by tests).
    private func fakeCodex() throws -> URL {
        let url = try dir.write("bin/codex", "#!/bin/sh\ncat '\(Fixture.url("codex/debug_models.json").path)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func names(_ roles: [ResolvedRole]) -> [String] { roles.map(\.config.name) }

    // MARK: N275 role files changed outside the app

    private func touch(_ rel: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: dir.url.appendingPathComponent(rel).path)
    }

    func testRoleFilesChangedOutsideShowUpWithoutSwitchingProject() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load()
        try dir.write("base/pm.json", roleJSON("pm")); try dir.write("base/dev.json", roleJSON("dev", model: "opus"))
        m.refreshFromDisk()
        XCTAssertEqual(names(m.groups[0].roles), ["dev", "pm"])
        XCTAssertEqual(m.groups[0].roles.first?.config.model, "opus")
    }

    func testOpenRoleFollowsItsFileWhenThereAreNoEdits() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first))
        try dir.write("base/dev.json", roleJSON("dev", model: "opus")); try touch("base/dev.json")
        m.refreshFromDisk()
        XCTAssertEqual(m.draft.model, "opus")
        XCTAssertFalse(m.diskChanged); XCTAssertFalse(m.isDirty)
    }

    func testUnsavedEditsAreNotOverwrittenWhenTheFileChanges() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first))
        m.draft.displayName = "Mine"
        try dir.write("base/dev.json", roleJSON("dev", model: "opus")); try touch("base/dev.json")
        m.refreshFromDisk()
        XCTAssertTrue(m.diskChanged)
        XCTAssertEqual(m.draft.displayName, "Mine"); XCTAssertEqual(m.draft.model, "sonnet")
        m.refreshFromDisk()
        XCTAssertTrue(m.diskChanged, "stays until answered")
        m.reloadFromDisk()
        XCTAssertFalse(m.diskChanged); XCTAssertEqual(m.draft.model, "opus"); XCTAssertEqual(m.draft.displayName, "")
    }

    func testKeepMineHidesTheBannerUntilTheFileChangesAgain() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first))
        m.draft.displayName = "Mine"
        try dir.write("base/dev.json", roleJSON("dev", model: "opus")); try touch("base/dev.json")
        m.refreshFromDisk()
        m.keepMine()
        XCTAssertFalse(m.diskChanged); XCTAssertEqual(m.draft.displayName, "Mine")
        m.refreshFromDisk()
        XCTAssertFalse(m.diskChanged)
        try dir.write("base/dev.json", roleJSON("dev", model: "haiku")); try touch("base/dev.json")
        m.refreshFromDisk()
        XCTAssertTrue(m.diskChanged)
        XCTAssertEqual(m.draft.displayName, "Mine")
    }

    // MARK: list

    func testGroupsShowBaseAndProjectRolesAndMarkShadowing() throws {
        try dir.write("base/dev.json", roleJSON("dev")); try dir.write("base/pm.json", roleJSON("pm"))
        try dir.write("p/roles/dev.json", roleJSON("dev", model: "mine")); try dir.write("p/roles/ui_dev.json", roleJSON("ui_dev"))
        let m = model(project: try project())
        m.load()
        XCTAssertEqual(m.groups.map(\.title), ["Base roles", "Only in Demo"])
        XCTAssertEqual(names(m.groups[0].roles), ["dev", "pm"])
        XCTAssertEqual(names(m.groups[1].roles), ["dev", "ui_dev"])
        let baseDev = try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" })
        XCTAssertEqual(m.shadowNote(for: baseDev), "Overridden in Demo")
        XCTAssertNil(m.shadowNote(for: try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "pm" })))
    }

    func testWithoutAProjectOnlyBaseRolesAreListed() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load()
        XCTAssertEqual(m.groups.map(\.title), ["Base roles"])
    }

    func testSeedRunsOnceAtFirstLaunch() throws {
        let m = model(); m.load()
        XCTAssertEqual(names(m.groups[0].roles), ["dev", "pm", "reviewer"])
        try FileManager.default.removeItem(at: baseDir.appendingPathComponent("pm.json"))
        let again = model(); again.load()
        XCTAssertEqual(names(again.groups[0].roles), ["dev", "reviewer"], "a deleted default does not come back")
    }

    func testBrokenRoleFilesAreReportedNotHidden() throws {
        try dir.write("base/dev.json", roleJSON("dev")); try dir.write("base/bad.json", "{ nope")
        let m = model(); m.load()
        XCTAssertEqual(names(m.groups[0].roles), ["dev"])
        XCTAssertEqual(m.loadProblems.count, 1)
    }

    // MARK: selecting and editing

    func testSelectingWhileDirtyAsksFirstAndDiscardDropsTheDraft() throws {
        try dir.write("base/dev.json", roleJSON("dev")); try dir.write("base/pm.json", roleJSON("pm"))
        let m = model(); m.load()
        let dev = m.groups[0].roles[0], pm = m.groups[0].roles[1]
        XCTAssertEqual(m.select(dev), .switched)
        XCTAssertFalse(m.isDirty)
        m.draft.model = "opus"
        XCTAssertTrue(m.isDirty)
        XCTAssertEqual(m.select(pm), .needsConfirmation)
        XCTAssertEqual(m.draft.name, "dev", "nothing changed yet")
        m.discardAndSelect(pm)
        XCTAssertEqual(m.draft.name, "pm")
        XCTAssertFalse(m.isDirty)
    }

    func testSelectingTheSameRoleNeverAsks() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load()
        _ = m.select(m.groups[0].roles[0]); m.draft.model = "opus"
        XCTAssertEqual(m.select(m.groups[0].roles[0]), .switched)
        XCTAssertEqual(m.draft.model, "opus", "re-selecting does not drop the edit")
    }

    func testAdvancedTextIsValidatedLive() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.draft.advancedText = "{ not json"
        XCTAssertTrue(m.problems.contains { $0.field == "advanced" && $0.severity == .error && $0.message.contains("not valid JSON") })
        m.draft.advancedText = "[1,2]"
        XCTAssertTrue(m.problems.contains { $0.field == "advanced" && $0.message.contains("object") })
        m.draft.advancedText = "{\"env\":{\"A\":\"b\"}}"
        XCTAssertTrue(m.problems.contains { $0.field == "advanced" && $0.message.contains("env") })
        XCTAssertFalse(m.problems.contains { $0.message.contains("\"b\"") }, "values never appear")
        m.draft.advancedText = "{\"model\":\"opus\"}"
        XCTAssertTrue(m.problems.contains { $0.severity == .warning })
        XCTAssertFalse(m.problems.contains { $0.severity == .error })
        m.draft.advancedText = ""
        XCTAssertEqual(m.problems, [])
        XCTAssertEqual(m.saveDisabledReason, "There are no changes to save.")
    }

    func testSaveIsDisabledWithTheReason() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        XCTAssertEqual(m.saveDisabledReason, "There are no changes to save.")
        m.draft.effort = "ultra"
        XCTAssertTrue(m.saveDisabledReason?.contains("problems") == true)
        m.draft.effort = "high"
        XCTAssertNil(m.saveDisabledReason)
    }

    func testSaveWritesAndKeepsTheRoleSelected() async throws {
        try dir.write("base/dev.json", roleJSON("dev")); try dir.write("base/dev.md", "old text")
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.draft.model = "opus"; m.draft.instructions = "new text"; m.draft.displayName = "Pixel"
        await m.save()
        XCTAssertNil(m.saveError)
        XCTAssertFalse(m.isDirty)
        let saved = try XCTUnwrap(RoleStore(baseDir: baseDir).baseRoles().roles.first)
        XCTAssertEqual(saved.config.model, "opus")
        XCTAssertEqual(saved.config.displayName, "Pixel")
        XCTAssertEqual(RoleStore(baseDir: baseDir).instructions(of: saved), "new text")
        XCTAssertEqual(m.selectedRole?.config.model, "opus")
    }

    func testSaveFailureKeepsTheDraftAndShowsTheReason() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.draft.model = "opus"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: baseDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: baseDir.path) }
        await m.save()
        XCTAssertNotNil(m.saveError)
        XCTAssertEqual(m.draft.model, "opus", "the draft is kept")
        XCTAssertTrue(m.isDirty)
    }

    func testNewRoleThenItAppearsSelected() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(project: try project()); m.load()
        m.newRole(in: .project)
        XCTAssertTrue(m.isNew)
        m.draft.name = "ui_dev"; m.draft.displayName = "Pixel"
        await m.save()
        XCTAssertNil(m.saveError)
        XCTAssertFalse(m.isNew)
        XCTAssertEqual(m.groups.last?.roles.map(\.config.name), ["ui_dev"])
        XCTAssertEqual(m.selectedRole?.config.name, "ui_dev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("p/roles/ui_dev.json").path))
    }

    func testNewRoleNameClashIsReportedBeforeSaving() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); m.newRole(in: .base)
        m.draft.name = "dev"
        XCTAssertTrue(m.problems.contains { $0.field == "name" && $0.message.contains("already") })
        XCTAssertNotNil(m.saveDisabledReason)
    }

    func testRenameUpdatesTheList() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.draft.name = "coder"
        await m.save()
        XCTAssertEqual(names(m.groups[0].roles), ["coder"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("dev.json").path))
    }

    func testRevertRestoresTheSavedRole() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.draft.model = "opus"; m.revert()
        XCTAssertEqual(m.draft.model, "sonnet")
        XCTAssertFalse(m.isDirty)
    }

    func testDeleteNeedsAnExplicitConfirmationAndSelectsANeighbour() async throws {
        try dir.write("base/a.json", roleJSON("a")); try dir.write("base/b.json", roleJSON("b")); try dir.write("base/c.json", roleJSON("c"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[1])
        m.requestDelete()
        XCTAssertEqual(m.pendingDelete?.config.name, "b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("b.json").path), "asking is not deleting")
        m.cancelDelete()
        XCTAssertNil(m.pendingDelete)
        m.requestDelete()
        await m.confirmDelete()
        XCTAssertEqual(names(m.groups[0].roles), ["a", "c"])
        XCTAssertNotNil(m.selectedRole, "a neighbour is selected")
        XCTAssertNil(m.pendingDelete)
    }

    func testMappedRoleIsReadOnlyInTheModel() throws {
        let file = try dir.write("elsewhere/dev.json", roleJSON("dev"))
        let m = model(project: try project(mapped: ["dev": file.path])); m.load()
        let mapped = try XCTUnwrap(m.groups.last?.roles.first { $0.source == .mapped })
        _ = m.select(mapped)
        XCTAssertFalse(m.isEditable)
        XCTAssertTrue(m.readOnlyReason?.contains("project.json") == true)
        XCTAssertNotNil(m.saveDisabledReason)
        m.requestDelete()
        XCTAssertNil(m.pendingDelete, "a read-only role cannot be deleted")
    }

    // MARK: skills

    private func withSkills() throws {
        try dir.write("claude/skills/alpha/SKILL.md", "x"); try dir.write("claude/skills/Beta/SKILL.md", "x")
        try dir.write("claude/settings.json", "{\"enabledPlugins\":{\"superpowers@official\":true}}")
    }

    func testSkillToggleAddsAndRemovesFromTheDraft() throws {
        try withSkills(); try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        XCTAssertEqual(m.draft.skills, ["superpowers"])
        m.toggleSkill("alpha"); XCTAssertEqual(m.draft.skills, ["superpowers", "alpha"])
        m.toggleSkill("superpowers"); XCTAssertEqual(m.draft.skills, ["alpha"])
        XCTAssertTrue(m.isDirty)
    }

    func testMissingSkillStaysInTheListWithAWarning() throws {
        try withSkills(); try dir.write("base/dev.json", roleJSON("dev", extra: ",\"x\":1").replacingOccurrences(of: "\"skills\":[\"superpowers\"]", with: "\"skills\":[\"ghost\"]"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        let ghost = try XCTUnwrap(m.skillEntries().first { $0.name == "ghost" })
        XCTAssertTrue(ghost.isMissing)
        XCTAssertTrue(ghost.isSelected)
        XCTAssertFalse(try XCTUnwrap(m.skillEntries().first { $0.name == "alpha" }).isMissing)
    }

    func testSkillSearchFiltersCaseInsensitively() throws {
        try withSkills(); try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        XCTAssertEqual(m.skillEntries(matching: "BET").map(\.name), ["Beta"])
        XCTAssertEqual(m.skillEntries(matching: "").count, 3)
        XCTAssertEqual(m.skillEntries(matching: "zzz"), [])
    }

    // MARK: preview

    func testPreviewIsRefreshedAfterEditsAndDroppedWhenInvalid() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.flags, "--model sonnet --effort medium")
        XCTAssertEqual(scripts.calls.count, 1)
        m.draft.effort = "ultra"
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.flags, "", "an invalid draft has no flags")
        XCTAssertFalse(m.preview?.problems.isEmpty ?? true)
        XCTAssertEqual(scripts.calls.count, 1, "no script runs for an invalid draft")
    }

    func testBrokenAdvancedJSONGivesNoFlagsAndRunsNothing() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        await m.refreshPreview()
        let before = scripts.calls.count
        m.draft.advancedText = "{ nope"
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.flags, "", "flags from a role without the broken text would be misleading")
        XCTAssertEqual(scripts.calls.count, before)
        XCTAssertEqual(m.previewNotes, [], "the problem is shown once, in the form, not again in the preview")
    }

    func testPreviewNotesKeepOnlyWhatTheFormDoesNotShow() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.toggleSkill("ghost")
        m.draft.advancedText = "{\"model\":\"opus\"}"
        await m.refreshPreview()
        XCTAssertTrue(m.previewNotes.contains { $0.contains("ghost") && $0.contains("not installed") })
        XCTAssertFalse(m.previewNotes.contains { $0.contains("Model field wins") }, "the warning is already listed in the form")
    }

    func testPreviewExplainsWhenScriptsAreNotConfigured() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(scriptsAvailable: false); m.load(); _ = m.select(m.groups[0].roles[0])
        await m.refreshPreview()
        XCTAssertTrue(m.preview?.problems.joined().contains("scriptsDir") == true)
    }

    // MARK: review findings

    func testNewRoleWhileDirtyAsksFirst() throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.draft.model = "opus"
        XCTAssertEqual(m.newRole(in: .base), .needsConfirmation)
        XCTAssertFalse(m.isNew)
        XCTAssertEqual(m.draft.model, "opus", "the edit is still there")
        m.discardAndNewRole(in: .base)
        XCTAssertTrue(m.isNew)
        XCTAssertEqual(m.draft.name, "")
        XCTAssertEqual(model().newRole(in: .base), .switched)
    }

    func testSwitchingProjectsClearsASelectionThatIsNoLongerListed() throws {
        try dir.write("p/roles/ui_dev.json", roleJSON("ui_dev"))
        let m = model(project: try project()); m.load()
        _ = m.select(try XCTUnwrap(m.groups.last?.roles.first))
        XCTAssertEqual(m.selectedRole?.config.name, "ui_dev")
        let otherSource = try dir.write("q/project.json", "{\"id\":\"other\",\"name\":\"Other\",\"repoPath\":\"/r\",\"dataDir\":\"/d\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        m.project = try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s2.json", "{\"projects\":[\"\(otherSource.path)\"]}")).projects.first)
        m.reload()
        XCTAssertNil(m.selectedRole, "the project's role is gone from the list")
        XCTAssertEqual(m.draft, RoleDraft())
        m.requestDelete()
        XCTAssertNil(m.pendingDelete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("p/roles/ui_dev.json").path), "the first project's role is untouched")
    }

    func testSavingKeepsFieldsTheFormDoesNotKnow() async throws {
        try dir.write("base/bot.json", roleJSON("bot", extra: ",\"maxBudgetUsd\":5,\"future\":{\"a\":1}").replacingOccurrences(of: "\"kind\":\"interactive\"", with: "\"kind\":\"headless\""))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        m.draft.model = "opus"
        await m.save()
        XCTAssertNil(m.saveError)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: baseDir.appendingPathComponent("bot.json"))) as? [String: Any]
        XCTAssertEqual(saved?["maxBudgetUsd"] as? Double, 5)
        XCTAssertNotNil(saved?["future"])
        XCTAssertEqual(saved?["model"] as? String, "opus")
    }

    func testAnOlderPreviewNeverOverwritesANewerOne() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let gate = TestGate()
        scripts.handler = { _, _ in await gate.wait(); return ScriptResult(status: 0, stdout: "--model OLD\n", stderr: "") }
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        let slow = Task { await m.refreshPreview() }
        try await Task.sleep(for: .milliseconds(150))
        m.draft.model = "opus"
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model NEW\n", stderr: "") }
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.flags, "--model NEW")
        await gate.release()
        await slow.value
        XCTAssertEqual(m.preview?.flags, "--model NEW", "the slow, older run is dropped")
    }

    // MARK: tool

    func testCodexToolOffersTheCatalogModelsAndHidesTheClaudeFields() async throws {
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        XCTAssertEqual(m.toolOptions, ["claude", "codex"])
        XCTAssertFalse(m.isCodex)
        await m.loadCodexModels()
        m.setTool("codex")
        XCTAssertTrue(m.isCodex)
        XCTAssertEqual(m.draft.tool, "codex")
        XCTAssertEqual(m.modelChoices.map(\.id), ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.2"])
        XCTAssertEqual(m.draft.model, "gpt-5.6-sol", "the first listed model")
        XCTAssertEqual(m.draft.effort, "low", "its default effort")
        XCTAssertEqual(m.effortOptions, m.codexModels.efforts(for: "gpt-5.6-sol"), "the efforts the catalog lists for the model")
        XCTAssertTrue(m.effortOptions.contains("max"))
        XCTAssertEqual(m.permissionModeOptions, ["manual", "acceptEdits", "plan", "bypassPermissions"])
        XCTAssertEqual(m.draft.permissionMode, "acceptEdits", "auto has no Codex meaning")
        XCTAssertEqual(m.draft.skills, []); XCTAssertEqual(m.draft.allowedTools, [])
        XCTAssertFalse(m.problems.contains { $0.field == "skills" || $0.field == "allowedTools" }, "no 'ignored' warnings for fields the form hides")
        m.setTool("claude")
        XCTAssertEqual(m.draft.model, "sonnet"); XCTAssertEqual(m.draft.effort, "medium"); XCTAssertEqual(m.draft.permissionMode, "auto")
        XCTAssertEqual(m.draft.skills, ["superpowers"]); XCTAssertEqual(m.draft.allowedTools, ["Read"])
        XCTAssertFalse(m.isDirty, "switching back gives the role as it was")
    }

    func testCodexPermissionModesShowTheirCodexMeaning() {
        XCTAssertTrue(TeamModel.codexMeaning(of: "plan").contains("-s read-only -a on-request"))
        XCTAssertTrue(TeamModel.codexMeaning(of: "manual").contains("-s read-only -a on-request"))
        XCTAssertTrue(TeamModel.codexMeaning(of: "acceptEdits").contains("-s workspace-write -a on-request"))
        XCTAssertFalse(TeamModel.codexMeaning(of: "manual").contains("untrusted"))
        XCTAssertTrue(TeamModel.codexMeaning(of: "bypassPermissions").contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testPickingACodexModelKeepsTheEffortOneItSupports() async throws {
        let json = #"{"models":[{"slug":"a","display_name":"A","visibility":"list","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},{"slug":"b","display_name":"B","visibility":"list","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"medium"},{"effort":"xhigh"}]}]}"#
        let models = try dir.write("models.json", json)
        let codex = try dir.write("bin/codex2", "#!/bin/sh\ncat '\(models.path)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let m = TeamModel(store: RoleStore(baseDir: baseDir), catalog: SkillCatalog(claudeHome: claudeHome), claudeHome: claudeHome,
                          makeScripts: { _ in nil }, codexCatalog: CodexModelCatalog(executable: codex))
        m.newRole(in: .base)
        await m.loadCodexModels()
        m.setTool("codex")
        XCTAssertEqual(m.draft.model, "a"); XCTAssertEqual(m.draft.effort, "high")
        XCTAssertEqual(m.effortOptions, ["low", "high"])
        m.setModel("b")
        XCTAssertEqual(m.draft.effort, "medium", "high is not offered by b: its default instead")
        m.draft.effort = "xhigh"; m.setModel("a")
        XCTAssertEqual(m.draft.effort, "high")
        m.draft.effort = "low"; m.setModel("a")
        XCTAssertEqual(m.draft.effort, "low", "a supported effort stays")
        m.draft.model = "b"; m.draft.effort = "low"
        XCTAssertTrue(m.problems.contains { $0.field == "effort" && $0.severity == .warning }, "a typed model with an effort it does not list is flagged")
        m.draft.model = "nope"
        XCTAssertTrue(m.problems.contains { $0.field == "model" && $0.message.contains("does not list") })
    }

    func testTheModelIsFilledWhenTheCatalogArrivesAfterPickingCodex() async throws {
        let m = model(); m.load(seed: false); m.newRole(in: .base)
        m.setTool("codex")
        XCTAssertEqual(m.draft.model, "")
        await m.loadCodexModels()
        XCTAssertEqual(m.draft.model, "gpt-5.6-sol"); XCTAssertEqual(m.draft.effort, "low")
    }

    func testAMissingCodexGivesNoModelsAndTheReason() async throws {
        let m = TeamModel(store: RoleStore(baseDir: baseDir), catalog: SkillCatalog(claudeHome: claudeHome), claudeHome: claudeHome,
                          makeScripts: { _ in nil }, codexCatalog: CodexModelCatalog(executable: nil))
        await m.loadCodexModels()
        XCTAssertEqual(m.modelChoices, ModelCatalog.claude)
        m.newRole(in: .base); m.setTool("codex")
        XCTAssertEqual(m.modelChoices, [])
        XCTAssertEqual(m.codexModels.reason, "codex is not installed (or not on PATH)")
        XCTAssertEqual(m.effortOptions, RoleValidator.codexEfforts)
    }

    func testThePMRoleMayUseCodex() throws {
        try dir.write("base/pm.json", roleJSON("pm"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles.first { $0.config.name == "pm" }!)
        XCTAssertEqual(m.toolOptions, ["claude", "codex"])
        m.setTool("codex")
        XCTAssertEqual(m.draft.tool, "codex")
    }

    func testACodexRoleIsReadAndSavedWithItsTool() async throws {
        try dir.write("base/cx.json", roleJSON("cx", model: "gpt-5.5", extra: ",\"tool\":\"codex\"").replacingOccurrences(of: "\"permissionMode\":\"auto\"", with: "\"permissionMode\":\"plan\"").replacingOccurrences(of: "[\"Read\"]", with: "[]").replacingOccurrences(of: "[\"superpowers\"]", with: "[]"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles.first { $0.config.name == "cx" }!)
        XCTAssertTrue(m.isCodex)
        m.draft.effort = "high"
        await m.save()
        XCTAssertNil(m.saveError)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: baseDir.appendingPathComponent("cx.json"))) as? [String: Any]
        XCTAssertEqual(saved?["tool"] as? String, "codex")
        XCTAssertEqual(saved?["effort"] as? String, "high")
    }

    func testCodexPreviewShowsTheCodexCommandAndNoClaudeSettings() async throws {
        try dir.write("claude/settings.json", "{\"permissions\":{\"allow\":[\"Read\"]}}")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "-m gpt-5.5 -c model_reasoning_effort=high -s read-only -a on-request\n", stderr: "") }
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        await m.loadCodexModels()
        m.setTool("codex")
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.command, "codex -m gpt-5.5 -c model_reasoning_effort=high -s read-only -a on-request")
        XCTAssertEqual(m.preview?.overrides, [], "Claude settings do not apply to a Codex agent")
    }

    /// A fake spawn-agent.sh that prints flags from the role file it is given, so a preview shows what the draft says.
    private func echoRoleScript() {
        scripts.handler = { _, args in
            let role = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as? [String: Any] ?? [:]
            return ScriptResult(status: 0, stdout: "-m \(role["model"] ?? "") -c model_reasoning_effort=\(role["effort"] ?? "") mode=\(role["permissionMode"] ?? "")\n", stderr: "")
        }
    }

    func testChangingTheDraftChangesTheCodexPreview() async throws {
        echoRoleScript()
        try dir.write("base/dev.json", roleJSON("dev"))
        let m = model(); m.load(); _ = m.select(m.groups[0].roles[0])
        await m.loadCodexModels()
        m.setTool("codex"); m.setModel("gpt-5.6-terra")
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.command, "codex -m gpt-5.6-terra -c model_reasoning_effort=low mode=acceptEdits")
        m.draft.effort = "high"; m.draft.permissionMode = "plan"; m.setModel("gpt-5.5")
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.command, "codex -m gpt-5.5 -c model_reasoning_effort=high mode=plan", "the preview is built from the unsaved draft")
    }

    func testTheRoleListShowsTheDraftModelAndToolOfTheSelectedRole() async throws {
        try dir.write("base/dev.json", roleJSON("dev")); try dir.write("base/pm.json", roleJSON("pm"))
        let m = model(); m.load()
        let dev = m.groups[0].roles.first { $0.config.name == "dev" }!, pm = m.groups[0].roles.first { $0.config.name == "pm" }!
        _ = m.select(dev)
        await m.loadCodexModels()
        m.setTool("codex"); m.setModel("gpt-5.6-terra")
        XCTAssertEqual(m.listModel(for: dev), "gpt-5.6-terra")
        XCTAssertTrue(m.listIsCodex(for: dev))
        XCTAssertEqual(m.listModel(for: pm), "sonnet", "other rows show their saved file")
        XCTAssertFalse(m.listIsCodex(for: pm))
    }
}
