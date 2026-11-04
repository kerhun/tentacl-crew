import XCTest
@testable import AgentPanel

final class LaunchPreviewTests: XCTestCase {
    private var dir: TempDir!
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    override func setUpWithError() throws { dir = try TempDir() }

    private var claudeHome: URL { dir.url.appendingPathComponent("claude") }

    private func draft(_ patch: (inout RoleConfig) -> Void = { _ in }) -> RoleConfig {
        var r = RoleConfig(name: "ui_dev", kind: "interactive", model: "sonnet", effort: "medium", permissionMode: "acceptEdits", outputStyle: "concise",
                           allowedTools: ["Read", "Edit"], skills: ["keepme"], instructionFile: "ui_dev.md", displayName: nil, advanced: nil)
        patch(&r)
        return r
    }

    private func catalog() throws -> SkillCatalog {
        try dir.write("claude/skills/keepme/SKILL.md", "x"); try dir.write("claude/skills/dropme/SKILL.md", "x")
        try dir.write("claude/settings.json", "{\"enabledPlugins\":{\"superpowers@official\":true,\"caveman@caveman\":true}}")
        return SkillCatalog(claudeHome: claudeHome)
    }

    func testPreviewShowsTheOutputStyleOfTheSettingsFile() async throws {
        let settings = try dir.write("out/settings.json", "{\"outputStyle\":\"Explanatory\"}")
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet --settings \(settings.path)\n", stderr: "") }
        let preview = await makePreview(draft: draft { $0.outputStyle = "explanatory" }, instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(preview.outputStyle, "Explanatory")
        XCTAssertEqual(preview.problems, [], "a built-in style in any casing is known")
    }

    func testPreviewWarnsAboutAnUnknownStyle() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet\n", stderr: "") }
        let preview = await makePreview(draft: draft { $0.outputStyle = "elsewhere" }, instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertTrue(preview.problems.contains { $0.hasPrefix("outputStyle:") })
    }

    func testPreviewRunsPrintFlagsOnATempCopyOfTheDraft() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, args in ScriptResult(status: 0, stdout: "--model sonnet --effort medium --permission-mode acceptEdits\n", stderr: "") }
        let preview = await makePreview(draft: draft(), instructions: "Do UI.", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        let call = try XCTUnwrap(scripts.calls.first)
        XCTAssertEqual(call.script, .spawn)
        XCTAssertEqual(call.args.first, "--print-flags")
        let file = URL(fileURLWithPath: call.args[1])
        XCTAssertEqual(file.lastPathComponent, "ui_dev.json")
        XCTAssertFalse(file.path.hasPrefix(dir.url.appendingPathComponent("base").path), "the real role file is never the argument")
        XCTAssertTrue(preview.flags.contains("--model sonnet"))
        XCTAssertEqual(preview.problems, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the temporary copy is removed afterwards")
    }

    func testInvalidDraftRunsNothingAndReportsProblems() async throws {
        let scripts = FakeScripts()
        let preview = await makePreview(draft: draft { $0.effort = "ultra" }, instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(scripts.calls, [])
        XCTAssertEqual(preview.flags, "")
        XCTAssertTrue(preview.problems.joined().contains("Effort"))
    }

    func testPreviewReportsMissingSkillsAsWarningsNotErrors() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet\n", stderr: "") }
        let preview = await makePreview(draft: draft { $0.skills = ["keepme", "ghostskill"] }, instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(scripts.calls.count, 1, "a missing skill does not stop the preview")
        XCTAssertTrue(preview.problems.contains { $0.contains("ghostskill") && $0.contains("not installed") })
    }

    func testPreviewShowsAdvancedConflicts() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet\n", stderr: "") }
        let preview = await makePreview(draft: draft { $0.advanced = ["model": .string("opus")] }, instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertTrue(preview.problems.contains { $0.contains("Model field wins") })
    }

    func testAScriptFailureIsShownAsAProblem() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 1, stdout: "", stderr: "ERROR: model is missing") }
        let preview = await makePreview(draft: draft(), instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(preview.flags, "")
        XCTAssertTrue(preview.problems.joined().contains("model is missing"))
    }

    func testOverridesListTheSettingsThatAlsoApply() async throws {
        try dir.write("claude/settings.json", "{\"permissions\":{\"allow\":[\"Read\"]}}")
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet\n", stderr: "") }
        let preview = await makePreview(draft: draft(), instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: SkillCatalog(claudeHome: claudeHome), claudeHome: claudeHome)
        XCTAssertTrue(preview.overrides.joined().contains("1 allow rule"))
    }

    /// The preview must show what the real start will use: the saved role, run through the real script, gives the same flags and files.
    func testPreviewMatchesTheRealScriptForTheSavedRole() async throws {
        let cat = try catalog()
        let role = draft { $0.advanced = ["permissions": .object(["deny": .array([.string("Bash(git push:*)")])])]; $0.displayName = "Pixel" }
        let store = RoleStore(baseDir: dir.url.appendingPathComponent("base"))
        let saved = try RoleWriter(store: store).save(role, instructions: "Do UI work.", at: .base, replacing: nil)

        let settings = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        func runner(_ state: URL) -> ScriptRunning {
            ProcessScriptRunner(settings: settings, timeout: 60, extraEnvironment: ["AGENT_PANEL_STATE": state.path, "AGENT_PANEL_CLAUDE_HOME": claudeHome.path])
        }
        let preview = await makePreview(draft: role, instructions: "Do UI work.", project: nil, makeScripts: runner, catalog: cat, claudeHome: claudeHome)

        let realState = dir.url.appendingPathComponent("real-state")
        let real = try await runner(realState).run(.spawn, arguments: ["--print-flags", saved.fileURL.path])
        XCTAssertEqual(real.status, 0, real.stderr)
        func normalised(_ s: String) -> String {
            s.replacingOccurrences(of: #"--settings \S+"#, with: "--settings S", options: .regularExpression)
             .replacingOccurrences(of: #"--append-system-prompt-file \S+"#, with: "--append-system-prompt-file I", options: .regularExpression)
             .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(normalised(preview.flags), normalised(real.stdout))
        XCTAssertFalse(preview.flags.isEmpty)
        let realSettings = try String(contentsOf: realState.appendingPathComponent("ui_dev/settings.json"), encoding: .utf8)
        func parsed(_ s: String) throws -> NSDictionary { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? NSDictionary) }
        XCTAssertEqual(try parsed(preview.settingsJSON), try parsed(realSettings))
        XCTAssertEqual(preview.instructions, try String(contentsOf: realState.appendingPathComponent("ui_dev/instructions.md"), encoding: .utf8))
        XCTAssertTrue(preview.settingsJSON.contains("git push"))
    }

    private func project() throws -> ProjectConfig {
        let source = try dir.write("proj/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"/data\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        return try XCTUnwrap(ProjectStore.load(settingsURL: try dir.write("s.json", "{\"projects\":[\"\(source.path)\"]}")).projects.first)
    }

    func testPreviewPassesTheProjectFileToTheScript() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet\n", stderr: "") }
        let p = try project()
        _ = await makePreview(draft: draft(), instructions: "x", project: p, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(scripts.calls[0].args.count, 4)
        XCTAssertEqual(scripts.calls[0].args[2], "")
        XCTAssertEqual(scripts.calls[0].args[3], p.sourcePath)
        let none = FakeScripts()
        none.handler = scripts.handler
        _ = await makePreview(draft: draft(), instructions: "x", project: nil, makeScripts: { _ in none }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(none.calls[0].args[3], "", "no project: no team section")
    }

    func testThePreviewShowsTheTeamSectionExactlyAsARealStartWould() async throws {
        let cat = try catalog()
        let p = try project()
        try dir.write("proj/team.json", #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"ui_dev","reportsTo":"pm"}]}"#)
        let role = draft()
        let saved = try RoleWriter(store: RoleStore(baseDir: dir.url.appendingPathComponent("base"))).save(role, instructions: "Do UI work.", at: .base, replacing: nil)
        let settings = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        func runner(_ state: URL) -> ScriptRunning {
            ProcessScriptRunner(settings: settings, timeout: 60, extraEnvironment: ["AGENT_PANEL_STATE": state.path, "AGENT_PANEL_CLAUDE_HOME": claudeHome.path])
        }
        let preview = await makePreview(draft: role, instructions: "Do UI work.", project: p, makeScripts: runner, catalog: cat, claudeHome: claudeHome)
        let realState = dir.url.appendingPathComponent("real-state")
        let real = try await runner(realState).run(.spawn, arguments: ["--print-flags", saved.fileURL.path, "", try XCTUnwrap(p.sourcePath)])
        XCTAssertEqual(real.status, 0, real.stderr)
        let realInstructions = try String(contentsOf: realState.appendingPathComponent("ui_dev/instructions.md"), encoding: .utf8)
        XCTAssertEqual(preview.instructions, realInstructions)
        XCTAssertTrue(preview.instructions.contains("You report to: pm"))
    }

    // MARK: Codex

    private func codexDraft() -> RoleConfig {
        draft { $0.tool = "codex"; $0.model = "gpt-5.5"; $0.effort = "high"; $0.permissionMode = "plan"; $0.allowedTools = []; $0.skills = [] }
    }

    func testCodexPreviewIsTheCodexCommandWithTheInstructionsShortened() async throws {
        let scripts = FakeScripts()
        // The flags as spawn-agent.sh prints them with %q: the instructions are one word with escaped spaces.
        let line = #"-m gpt-5.5 -c model_reasoning_effort=high -s read-only -a on-request --add-dir /att -c check_for_update_on_startup=false -c developer_instructions=\"Do\ UI.\\nTwo\ \\\"lines\\\".\\n\" -c projects=\{\"\<worktree\>\"=\{trust_level=\"trusted\"\}\}"#
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: line + " \n", stderr: "") }
        let preview = await makePreview(draft: codexDraft(), instructions: "Do UI.", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(preview.tool, "codex")
        XCTAssertEqual(preview.flags, line, "the raw line is kept")
        XCTAssertEqual(preview.command, #"codex -m gpt-5.5 -c model_reasoning_effort=high -s read-only -a on-request --add-dir /att -c check_for_update_on_startup=false -c developer_instructions=<the instructions> -c projects={"<worktree>"={trust_level="trusted"}}"#, "readable: no shell escapes")
        XCTAssertEqual(preview.problems, [])
        XCTAssertEqual(preview.overrides, [], "Claude settings do not apply to a Codex agent")
        XCTAssertEqual(preview.settingsJSON, "")
    }

    func testCodexPreviewReadsTheInstructionsTheScriptWrote() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "-m gpt-5.5\n", stderr: "") }
        let preview = await makePreview(draft: codexDraft(), instructions: "Do UI.", project: nil, makeScripts: { state in
            try? FileManager.default.createDirectory(at: state.appendingPathComponent("ui_dev"), withIntermediateDirectories: true)
            try? Data("Do UI.\n## Your simulator\n".utf8).write(to: state.appendingPathComponent("ui_dev/instructions.md"))
            return scripts
        }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(preview.instructions, "Do UI.\n## Your simulator\n")
    }

    func testCodexPreviewDoesNotAskForClaudeSkills() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "-m gpt-5.5\n", stderr: "") }
        let preview = await makePreview(draft: codexDraft(), instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(preview.problems, [])
        XCTAssertEqual(preview.command, "codex -m gpt-5.5")
    }

    func testClaudePreviewCommandStartsWithClaude() async throws {
        let scripts = FakeScripts()
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "--model sonnet\n", stderr: "") }
        let preview = await makePreview(draft: draft(), instructions: "x", project: nil, makeScripts: { _ in scripts }, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertEqual(preview.command, "claude --model sonnet")
    }

    func testCodexPreviewMatchesTheRealScriptForTheSavedRole() async throws {
        let cat = try catalog()
        let role = codexDraft()
        let saved = try RoleWriter(store: RoleStore(baseDir: dir.url.appendingPathComponent("base"))).save(role, instructions: "Do UI work.", at: .base, replacing: nil)
        let settings = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        func runner(_ state: URL) -> ScriptRunning {
            ProcessScriptRunner(settings: settings, timeout: 60, extraEnvironment: ["AGENT_PANEL_STATE": state.path, "AGENT_PANEL_CLAUDE_HOME": claudeHome.path, "AGENT_PANEL_ATTACHMENTS": "/att"])
        }
        let preview = await makePreview(draft: role, instructions: "Do UI work.", project: nil, makeScripts: runner, catalog: cat, claudeHome: claudeHome)
        let realState = dir.url.appendingPathComponent("real-state")
        let real = try await runner(realState).run(.spawn, arguments: ["--print-flags", saved.fileURL.path])
        XCTAssertEqual(real.status, 0, real.stderr)
        XCTAssertEqual(preview.flags, real.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(preview.command.hasPrefix("codex --no-daemon -m gpt-5.5 -c model_reasoning_effort=high -c plan_mode_reasoning_effort=high -s read-only -a on-request --add-dir /att"), preview.command)
        XCTAssertTrue(preview.command.contains("developer_instructions=<the instructions>"))
        XCTAssertEqual(preview.instructions, try String(contentsOf: realState.appendingPathComponent("ui_dev/instructions.md"), encoding: .utf8))
        XCTAssertTrue(preview.instructions.contains("Do UI work."))
    }

    func testCodexCommandQuotesAWordWithASpace() {
        let p = LaunchPreview(tool: "codex", flags: #"--add-dir /Users/me/Library/Application\ Support/Tentacl/attachments -c projects=\{\"/a\ b\"=\{trust_level=\"trusted\"\}\}"#)
        XCTAssertEqual(p.command, #"codex --add-dir '/Users/me/Library/Application Support/Tentacl/attachments' -c 'projects={"/a b"={trust_level="trusted"}}'"#)
    }

    func testTheRealScriptPreviewFollowsTheDraftEffort() async throws {
        let settings = AppSettings(scriptsDir: root.appendingPathComponent("scripts"), problems: [])
        func runner(_ state: URL) -> ScriptRunning {
            ProcessScriptRunner(settings: settings, timeout: 60, extraEnvironment: ["AGENT_PANEL_STATE": state.path, "AGENT_PANEL_CLAUDE_HOME": claudeHome.path, "AGENT_PANEL_ATTACHMENTS": "/att"])
        }
        let low = await makePreview(draft: codexDraft(), instructions: "x", project: nil, makeScripts: runner, catalog: try catalog(), claudeHome: claudeHome)
        var changed = codexDraft(); changed.effort = "low"; changed.permissionMode = "manual"
        let other = await makePreview(draft: changed, instructions: "x", project: nil, makeScripts: runner, catalog: try catalog(), claudeHome: claudeHome)
        XCTAssertTrue(low.command.contains("model_reasoning_effort=high -c plan_mode_reasoning_effort=high -s read-only -a on-request"), low.command)
        XCTAssertTrue(other.command.contains("model_reasoning_effort=low -c plan_mode_reasoning_effort=low -s read-only -a on-request"), other.command)
    }
}
