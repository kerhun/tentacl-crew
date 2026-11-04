import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class TeamViewTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model opus --effort high --permission-mode manual --settings /tmp/s.json\n", stderr: "") }
    }

    private func roleJSON(_ name: String, model: String = "sonnet", extra: String = "") -> String {
        "{\"name\":\"\(name)\",\"kind\":\"interactive\",\"model\":\"\(model)\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[\"Read\"],\"skills\":[\"superpowers\"],\"instructionFile\":\"\(name).md\"\(extra)}"
    }

    private func project() throws -> ProjectConfig {
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Orchard\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    private func model(skills: Int = 6, codex: CodexModelCatalog = CodexModelCatalog(executable: nil)) throws -> TeamModel {
        try dir.write("base/pm.json", roleJSON("pm", model: "opus", extra: ",\"displayName\":\"Atlas\"")); try dir.write("base/pm.md", "You are the PM.")
        try dir.write("base/dev.json", roleJSON("dev")); try dir.write("p/roles/ui_dev.json", roleJSON("ui_dev"))
        for i in 0..<skills { try dir.write("claude/skills/skill-\(String(format: "%03d", i))/SKILL.md", "x") }
        try dir.write("claude/settings.json", "{\"enabledPlugins\":{\"superpowers@official\":true,\"caveman@caveman\":true},\"permissions\":{\"allow\":[\"Read\"]}}")
        let s = scripts!
        let m = TeamModel(store: RoleStore(baseDir: dir.url.appendingPathComponent("base")), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("claude")),
                          claudeHome: dir.url.appendingPathComponent("claude"), makeScripts: { _ in s }, project: try project(), codexCatalog: codex)
        m.load(seed: false)
        return m
    }

    private func png(_ view: some View, size: CGSize, name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, Int(size.width) * 2)
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png")) }
    }

    func testTeamScreenRenders() async throws {
        let m = try model()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "pm" }))
        await m.refreshPreview()
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 900), size: CGSize(width: 1384, height: 900), name: "team")
    }

    func testChangedOnDiskBannerRenders() async throws {
        let m = try model()
        let dev = try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" })
        _ = m.select(dev)
        m.draft.displayName = "Mine"
        try dir.write("base/dev.json", roleJSON("dev", model: "opus"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: dir.url.appendingPathComponent("base/dev.json").path)
        m.refreshFromDisk()
        XCTAssertTrue(m.diskChanged)
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 900), size: CGSize(width: 1384, height: 900), name: "N275-team-banner")
    }

    func testReadOnlyRoleShowsWhyAndAnInvalidDraftShowsTheProblem() async throws {
        let m = try model()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        m.draft.advancedText = "{ nope"
        await m.refreshPreview()
        XCTAssertNotNil(m.saveDisabledReason)
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 1500), size: CGSize(width: 1384, height: 1500), name: "team-invalid")
    }

    func testTwoHundredSkillsKeepTheListAtAFixedHeight() throws {
        let m = try model(skills: 200)
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        XCTAssertEqual(m.skillEntries().count, 202)
        XCTAssertEqual(SkillPickerView.listHeight, 176)
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 900), size: CGSize(width: 1384, height: 900), name: "team-many-skills")
    }

    func testNewRoleFormRenders() throws {
        let m = try model()
        m.newRole(in: .project)
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 900), size: CGSize(width: 1384, height: 900), name: "team-new")
    }

    // MARK: navigation

    func testSwitchingProjectsWhileEditingARoleAsksFirst() {
        XCTAssertTrue(projectSwitchNeedsConfirmation(screen: .team, teamIsDirty: true))
        XCTAssertFalse(projectSwitchNeedsConfirmation(screen: .team, teamIsDirty: false))
        XCTAssertFalse(projectSwitchNeedsConfirmation(screen: .tasks, teamIsDirty: true))
    }

    func testLeavingTheTeamScreenWithUnsavedChangesAsksFirst() {
        XCTAssertEqual(screenChange(from: .tasks, to: .team, teamIsDirty: false), .go)
        XCTAssertEqual(screenChange(from: .team, to: .tasks, teamIsDirty: false), .go)
        XCTAssertEqual(screenChange(from: .team, to: .tasks, teamIsDirty: true), .askFirst)
        XCTAssertEqual(screenChange(from: .tasks, to: .tasks, teamIsDirty: true), .go)
        XCTAssertEqual(screenChange(from: .team, to: .team, teamIsDirty: true), .go)
    }

    // MARK: PanelModel wiring

    private func panel(seeds: Bool) throws -> (PanelModel, URL) {
        let base = dir.url.appendingPathComponent("home-roles")
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Orchard\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal() }, opener: RecordingOpener(),
                           log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")), defaults: makeTestDefaults(), roleStore: RoleStore(baseDir: base), seedsRoles: seeds)
        return (m, base)
    }

    func testPanelDoesNotCreateRolesUnlessAskedTo() async throws {
        let (m, base) = try panel(seeds: false)
        await m.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "tests and demo mode never write to the real roles folder")
        let (seeded, base2) = try panel(seeds: true)
        await seeded.reload()
        XCTAssertTrue(FileManager.default.fileExists(atPath: base2.appendingPathComponent("dev.json").path))
    }

    func testTeamFollowsTheSelectedProject() async throws {
        let (m, _) = try panel(seeds: false)
        await m.reload()
        XCTAssertEqual(m.team.project?.id, "demo")
        XCTAssertEqual(m.team.groups.map(\.title), ["Base roles", "Only in Orchard"])
        XCTAssertEqual(m.roleActivity, [:], "no agents and no cards yet")
    }

    // MARK: tool

    func testClaudeRoleFormShowsTheToolAndTheClaudeSections() async throws {
        let m = try model()
        _ = m.select(try XCTUnwrap(m.groups[1].roles.first { $0.config.name == "ui_dev" }))
        await m.refreshPreview()
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 1500), size: CGSize(width: 1384, height: 1500), name: "team-role-claude")
    }

    func testClaudeRoleFormShowsThinkingAndReplyLanguage() async throws {
        let m = try model()
        _ = m.select(try XCTUnwrap(m.groups[1].roles.first { $0.config.name == "ui_dev" }))
        m.draft.thinking = "on"; m.draft.language = "turkish"
        await m.refreshPreview()
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 1000), size: CGSize(width: 1384, height: 1000), name: "N220-role-form")
        XCTAssertEqual(m.draft.config().role.thinking, "on")
        XCTAssertEqual(m.draft.config().role.language, "turkish")
    }

    func testCodexRoleFormHidesTheClaudeSectionsAndShowsTheCodexCommand() async throws {
        let codex = try dir.write("bin/codex", "#!/bin/sh\ncat '\(Fixture.url("codex/debug_models.json").path)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let m = try model(codex: CodexModelCatalog(executable: codex))
        _ = m.select(try XCTUnwrap(m.groups[1].roles.first { $0.config.name == "ui_dev" }))
        await m.loadCodexModels()
        m.setTool("codex"); m.setModel("gpt-5.6-terra"); m.draft.permissionMode = "plan"
        await m.save()   // the list shows the saved Codex role
        XCTAssertNil(m.saveError)
        scripts.handler = { _, args in   // flags from the role file the preview passes, so the form and the preview agree
            let role = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as? [String: Any] ?? [:]
            return ScriptResult(status: 0, stdout: "-m \(role["model"]!) -c model_reasoning_effort=\(role["effort"]!) -s read-only -a on-request --add-dir /Users/me/Library/Application\\ Support/Tentacl/attachments -c check_for_update_on_startup=false -c developer_instructions=\\\"You\\ are\\ ui_dev.\\\" -c projects=\\{\\\"\\<worktree\\>\\\"=\\{trust_level=\\\"trusted\\\"\\}\\}\n", stderr: "")
        }
        await m.refreshPreview()
        XCTAssertEqual(m.preview?.tool, "codex")
        XCTAssertTrue(m.preview?.command.contains("model_reasoning_effort=\(m.draft.effort) ") ?? false, m.preview?.command ?? "")
        try png(TeamView(model: m, initialSection: .roles).frame(width: 1384, height: 1100), size: CGSize(width: 1384, height: 1100), name: "team-role-codex")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPanel/Views/RoleFormView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if !model.isCodex"), "the Claude-only sections are hidden for a Codex role")
    }

    // MARK: sectioned editor (N174)

    func testUnsavedChangeCountCountsTheFieldsThatDiffer() throws {
        let m = try model()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        XCTAssertEqual(m.unsavedChangeCount, 0)
        m.draft.model = "opus"
        XCTAssertEqual(m.unsavedChangeCount, 1)
        m.toggleSkill("caveman"); m.toggleSkill("skill-000")   // two skills are still one field
        m.draft.instructions = "New text"
        XCTAssertEqual(m.unsavedChangeCount, 3)
        m.draft.model = "sonnet"
        XCTAssertEqual(m.unsavedChangeCount, 2, "a field changed back is no longer counted")
        m.revert()
        XCTAssertEqual(m.unsavedChangeCount, 0)
    }

    func testRoleSearchMatchesNameDisplayNameModelAndSkill() throws {
        let m = try model()
        XCTAssertEqual(m.filteredGroups.flatMap { $0.roles.map(\.config.name) }, ["dev", "pm", "ui_dev"])
        m.roleQuery = "atlas"
        XCTAssertEqual(m.filteredGroups.flatMap { $0.roles.map(\.config.name) }, ["pm"], "display name")
        m.roleQuery = "OPUS"
        XCTAssertEqual(m.filteredGroups.flatMap { $0.roles.map(\.config.name) }, ["pm"], "model, any case")
        m.roleQuery = "superpow"
        XCTAssertEqual(m.filteredGroups.flatMap { $0.roles.map(\.config.name) }, ["dev", "pm", "ui_dev"], "skill")
        m.roleQuery = "ui_"
        XCTAssertEqual(m.filteredGroups.map(\.title), ["Base roles", "Only in Orchard"], "groups stay so the headings stay")
        XCTAssertEqual(m.filteredGroups.flatMap { $0.roles.map(\.config.name) }, ["ui_dev"])
        m.roleQuery = "  "
        XCTAssertEqual(m.filteredGroups.flatMap { $0.roles }.count, 3)
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        m.draft.model = "opus"; m.roleQuery = "opus"
        XCTAssertEqual(m.filteredGroups.flatMap { $0.roles.map(\.config.name) }, ["dev", "pm"], "the selected role matches the model its row shows")
    }

    func testPermissionChoiceCardsCarryMeaningAndRisk() {
        let claude = PermissionChoice.choices(codex: false)
        XCTAssertEqual(claude.map(\.mode), ["plan", "manual", "acceptEdits", "auto", "dontAsk", "bypassPermissions"])
        XCTAssertEqual(Set(claude.map(\.mode)), Set(RoleValidator.permissionModes), "every mode the validator accepts has a card")
        XCTAssertEqual(claude.first { $0.mode == "plan" }?.risk, .safest)
        XCTAssertEqual(claude.first { $0.mode == "manual" }?.risk, .safe)
        XCTAssertEqual(claude.first { $0.mode == "acceptEdits" }?.risk, .normal)
        XCTAssertEqual(claude.first { $0.mode == "bypassPermissions" }?.risk, .risky)
        XCTAssertEqual(claude.first { $0.mode == "bypassPermissions" }?.risk.label, "Risky")
        XCTAssertTrue(claude.allSatisfy { !$0.title.isEmpty && !$0.meaning.isEmpty })
        let codex = PermissionChoice.choices(codex: true)
        XCTAssertEqual(Set(codex.map(\.mode)), Set(RoleValidator.codexPermissionModes))
        XCTAssertEqual(codex.map(\.mode), ["plan", "manual", "acceptEdits", "bypassPermissions"], "same order, safest first")
    }

    func testRoleActivityCountsRunningAgentsAndDoneCards() {
        func agent(_ name: String?) -> AgentStatus { var a = AgentStatus(paneID: name ?? "x", workspaceID: "w", state: .working, cwd: "/r", title: "t"); a.name = name; return a }
        func card(_ id: String, _ status: TaskStatus, agent: String?, roles: [String] = []) -> TaskCard {
            var c = TaskCard(id: id, project: "p", status: status, agent: agent, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/c/\(id).md"))
            c.roles = roles; return c
        }
        let activity = roleActivity(cards: [card("A", .done, agent: "dev-a-p"), card("B", .done, agent: nil, roles: ["ui_dev"]), card("C", .done, agent: nil),
                                            card("D", .doing, agent: "dev-d-p"), card("E", .done, agent: "ui_dev-e-p")],
                                    agents: [agent("dev-d-p"), agent("dev-f-p"), agent("ui_dev-e-p"), agent(nil)])
        XCTAssertEqual(activity["dev"], RoleActivity(running: 2, done: 2), "a card with no agent and no roles is the default role's")
        XCTAssertEqual(activity["ui_dev"], RoleActivity(running: 1, done: 2))
        XCTAssertNil(activity["pm"])
    }

    func testOverrideForProjectStartsAProjectCopyOfTheBaseRole() async throws {
        let m = try model()
        let dev = try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" })
        _ = m.select(dev)
        XCTAssertTrue(m.canOverride)
        m.draft.effort = "high"
        m.overrideForProject()
        XCTAssertTrue(m.isNew)
        XCTAssertEqual(m.draft.name, "dev")
        XCTAssertEqual(m.draft.effort, "high", "the edits so far go with the copy")
        XCTAssertNil(m.saveDisabledReason)
        await m.save()
        XCTAssertNil(m.saveError)
        XCTAssertEqual(m.selectedRole?.source, .project)
        XCTAssertNotNil(m.shadowNote(for: dev))
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        XCTAssertFalse(m.canOverride, "the project already has its own dev")
        _ = m.select(try XCTUnwrap(m.groups[1].roles.first { $0.config.name == "ui_dev" }))
        XCTAssertFalse(m.canOverride, "only a base role is overridden")
    }

    func testSectionedEditorStatesRender() async throws {
        let m = try model()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        m.draft.model = "opus"; m.toggleSkill("caveman"); m.draft.advancedText = "{ \"includeCoAuthoredBy\": true }"
        await m.refreshPreview()
        let activity = ["dev": RoleActivity(running: 2, done: 118), "pm": RoleActivity(running: 1, done: 0)]
        try png(TeamView(model: m, activity: activity, initialSection: .roles).frame(width: 1384, height: 1700), size: CGSize(width: 1384, height: 1700), name: "team-v2-dirty")
        m.roleQuery = "opus"
        try png(TeamView(model: m, activity: activity, initialSection: .roles).frame(width: 1384, height: 900), size: CGSize(width: 1384, height: 900), name: "team-v2-search")
        try png(SkillPickerView(model: m, editable: true).padding(Tok.Space.l).frame(width: 420, height: 300).background(Tok.bg), size: CGSize(width: 420, height: 300), name: "team-v2-skill-picker")
    }

    func testSideColumnStatesRender() async throws {
        try dir.write("p/team.json", "{\"version\":1,\"members\":[{\"role\":\"pm\",\"reportsTo\":null},{\"role\":\"dev\",\"reportsTo\":\"pm\"},{\"role\":\"ui_dev\",\"reportsTo\":\"pm\"}]}")
        let settings = try dir.write("state/settings.json", "{\n  \"outputStyle\": \"concise\",\n  \"permissions\": { \"allow\": [\"Read\", \"Edit\"] }\n}")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet --effort medium --permission-mode acceptEdits --settings \(settings.path)\n", stderr: "") }
        let m = try model()
        _ = m.select(try XCTUnwrap(m.groups[0].roles.first { $0.config.name == "dev" }))
        m.draft.permissionMode = "acceptEdits"; m.draft.allowedTools = ["Read", "Edit", "Write", "Glob", "Grep", "Bash(git status:*)"]
        m.draft.instructions = "You are the developer. Work in your worktree, commit small steps."
        await m.refreshPreview()
        XCTAssertEqual(RoleSummary.lines(draft: m.draft, modelLabel: m.modelLabel, chart: m.chart.savedChart, names: ["pm": "Atlas"]).last, "Reports to Atlas (pm); gives tasks to nobody.")
        XCTAssertFalse(try XCTUnwrap(m.preview).settingsJSON.isEmpty)
        let saved = try XCTUnwrap(RoleSummary.savedAt(try XCTUnwrap(m.selectedRole).fileURL))
        let running = ["dev": [RoleRunningAgent(cardID: "N157", title: "TentaclBackend", startedAt: saved.addingTimeInterval(-600)),
                               RoleRunningAgent(cardID: "N151", title: "Codex question detector", startedAt: saved.addingTimeInterval(60))]]
        let activity = ["dev": RoleActivity(running: 2, done: 118)]
        try png(TeamView(model: m, activity: activity, running: running, initialSection: .roles).frame(width: 1384, height: 1500), size: CGSize(width: 1384, height: 1500), name: "team-side-wide")
        try png(TeamView(model: m, activity: activity, running: running, initialSection: .roles).frame(width: 1100, height: 2300), size: CGSize(width: 1100, height: 2300), name: "team-side-narrow")
        try png(RoleSideColumn(model: m, running: running["dev"]!, showInstructions: true, showSettings: true).frame(width: 340).padding(Tok.Space.l).frame(width: 380, height: 1100, alignment: .top).background(Tok.bg),
                size: CGSize(width: 380, height: 1100), name: "team-side-open")
        m.draft.tool = "codex"; m.draft.model = "gpt-5.5"; m.draft.effort = "high"
        try png(RoleSideColumn(model: m).frame(width: 340).padding(Tok.Space.l).frame(width: 380, height: 700, alignment: .top).background(Tok.bg),
                size: CGSize(width: 380, height: 700), name: "team-side-codex-none-running")
    }
}
