import XCTest
@testable import AgentPanel

final class SkillCatalogTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private var claudeHome: URL { dir.url.appendingPathComponent("claude") }

    private func makeSkill(_ name: String) throws { try dir.write("claude/skills/\(name)/SKILL.md", "---\nname: \(name)\n---\n") }

    func testCatalogListsUserSkillsAndPluginsSorted() throws {
        try makeSkill("zeta"); try makeSkill("alpha")
        try dir.write("claude/skills/.hidden/SKILL.md", "x")
        try dir.write("claude/settings.json", "{\"enabledPlugins\":{\"superpowers@official\":true,\"caveman@caveman\":false,\"wiki@mine\":true}}")
        let all = SkillCatalog(claudeHome: claudeHome).installed()
        XCTAssertEqual(all.map(\.name), ["alpha", "caveman", "superpowers", "wiki", "zeta"])
        XCTAssertEqual(all.first { $0.name == "alpha" }?.kind, .userSkill)
        XCTAssertEqual(all.first { $0.name == "superpowers" }?.kind, .plugin)
        XCTAssertEqual(all.first { $0.name == "caveman" }?.kind, .plugin, "an installed but disabled plugin is still a choice")
    }

    func testPluginAndSkillWithTheSameNameAreBothListed() throws {
        try makeSkill("wiki")
        try dir.write("claude/settings.json", "{\"enabledPlugins\":{\"wiki@mine\":true}}")
        XCTAssertEqual(SkillCatalog(claudeHome: claudeHome).installed().map(\.kind), [.userSkill, .plugin])
    }

    func testMissingClaudeHomeIsEmptyNotACrash() {
        XCTAssertEqual(SkillCatalog(claudeHome: dir.url.appendingPathComponent("nope")).installed(), [])
    }

    func testBrokenSettingsFileGivesTheUserSkillsOnly() throws {
        try makeSkill("alpha"); try dir.write("claude/settings.json", "{ nope")
        XCTAssertEqual(SkillCatalog(claudeHome: claudeHome).installed().map(\.name), ["alpha"])
    }

    // MARK: settings summary

    func testSummaryNeverContainsValues() throws {
        try dir.write("claude/settings.json", """
        {"env":{"GH_TOKEN":"ghp_SECRET123"},"permissions":{"allow":["Bash(ls:*)","Read"],"deny":["Bash(rm:*)"]},
         "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hunter2"}]}],"PreToolUse":[]},
         "mcpServers":{"files":{"command":"x","env":{"KEY":"SECRET456"},"headers":{"Authorization":"SECRET789"}}}}
        """)
        let text = ClaudeSettingsSummary.lines(claudeHome: claudeHome, repo: nil).joined(separator: "\n")
        for secret in ["ghp_SECRET123", "hunter2", "SECRET456", "SECRET789", "GH_TOKEN", "KEY"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertTrue(text.contains("2 allow rules"))
        XCTAssertTrue(text.contains("1 deny rule"))
        XCTAssertTrue(text.contains("PreToolUse") && text.contains("SessionStart"))
        XCTAssertTrue(text.contains("files"), "MCP server names are shown")
        XCTAssertTrue(text.contains("1 environment variable"), "env is only counted")
    }

    func testSummaryCoversUserProjectAndLocalSettingsAndNamesTheFile() throws {
        try dir.write("claude/settings.json", "{\"permissions\":{\"allow\":[\"Read\"]}}")
        try dir.write("repo/.claude/settings.json", "{\"permissions\":{\"allow\":[\"Bash\",\"Edit\"]}}")
        try dir.write("repo/.claude/settings.local.json", "{\"permissions\":{\"deny\":[\"Bash(git push:*)\"]}}")
        let lines = ClaudeSettingsSummary.lines(claudeHome: claudeHome, repo: dir.url.appendingPathComponent("repo"))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("settings.json") && lines[0].contains("1 allow rule"))
        XCTAssertTrue(lines[1].contains(".claude/settings.json") && lines[1].contains("2 allow rules"))
        XCTAssertTrue(lines[2].contains("settings.local.json") && lines[2].contains("1 deny rule"))
    }

    func testEmptyOrMissingSettingsProduceNoLines() throws {
        try dir.write("claude/settings.json", "{}")
        XCTAssertEqual(ClaudeSettingsSummary.lines(claudeHome: claudeHome, repo: dir.url.appendingPathComponent("repo")), [])
    }

    func testPluginsEnabledByTheProjectAreFlagged() throws {
        try dir.write("repo/.claude/settings.json", "{\"enabledPlugins\":{\"extra@market\":true,\"superpowers@official\":true,\"off@market\":false}}")
        let lines = ClaudeSettingsSummary.lines(claudeHome: claudeHome, repo: dir.url.appendingPathComponent("repo"), roleSkills: ["superpowers"])
        let flagged = lines.filter { $0.contains("extra") }
        XCTAssertEqual(flagged.count, 1)
        XCTAssertTrue(flagged[0].lowercased().contains("stays on"), flagged[0])
        XCTAssertFalse(lines.joined().contains("off@market"))
        XCTAssertFalse(lines.contains { $0.contains("stays on") && $0.contains("superpowers") }, "a plugin the role keeps is not a surprise")
    }
}
