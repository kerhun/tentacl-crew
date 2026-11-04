import XCTest
@testable import AgentPanel

@MainActor
final class RoleChoicesTests: XCTestCase {
    // MARK: model catalog

    func testTheCatalogHasTheLatestAliasesIncludingHaikuAndPinnedVersions() {
        let ids = ModelCatalog.claude.map(\.id)
        for alias in ["opus", "sonnet", "haiku", "fable"] { XCTAssertTrue(ids.contains(alias), alias) }
        for pinned in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"] { XCTAssertTrue(ids.contains(pinned), pinned) }
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate ids")
        XCTAssertEqual(Set(ModelCatalog.claude.map(\.group)), [ModelCatalog.latestGroup, ModelCatalog.pinnedGroup])
    }

    func testLabelsShowTheVersionAndUnknownModelsKeepTheirId() {
        XCTAssertEqual(ModelCatalog.label(for: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelCatalog.label(for: "haiku"), "Haiku (latest)")
        XCTAssertEqual(ModelCatalog.label(for: "my-custom-model"), "my-custom-model")
        XCTAssertEqual(ModelCatalog.label(for: ""), "")
    }

    func testEveryCatalogModelPassesTheRoleValidator() {
        for m in ModelCatalog.claude {
            var r = DefaultRoles.all[0].0; r.model = m.id
            XCTAssertEqual(RoleValidator.problems(for: r).filter { $0.field == "model" }, [], m.id)
        }
    }

    // MARK: tools

    func testToolCatalogListsTheCommonToolsWithASummary() {
        let names = ToolCatalog.claude.map(\.name)
        for tool in ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "WebFetch", "WebSearch"] { XCTAssertTrue(names.contains(tool), tool) }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(ToolCatalog.claude.allSatisfy { !$0.summary.isEmpty })
    }

    func testDraftToggleAddsAndRemovesAKnownTool() {
        var d = RoleDraft()
        XCTAssertEqual(d.allowedTools, ["Read", "Edit", "Write", "Bash"])
        d.toggleTool("Bash"); XCTAssertEqual(d.allowedTools, ["Read", "Edit", "Write"])
        d.toggleTool("Grep"); XCTAssertEqual(d.allowedTools, ["Read", "Edit", "Write", "Grep"])
    }

    func testCustomRulesAreKeptSeparateFromTheTickBoxes() {
        var d = RoleDraft()
        d.allowedTools = ["Read", "Bash(git status:*)", "mcp__files__read"]
        XCTAssertEqual(d.customToolsText, "Bash(git status:*), mcp__files__read")
        d.toggleTool("Read")
        XCTAssertEqual(d.allowedTools, ["Bash(git status:*)", "mcp__files__read"], "ticking a box never touches the custom rules")
        d.customToolsText = "Bash(npm test:*)"
        d.toggleTool("Edit")
        XCTAssertEqual(Set(d.allowedTools), ["Edit", "Bash(npm test:*)"])
        d.customToolsText = "  ,  "
        XCTAssertEqual(d.allowedTools, ["Edit"])
    }

    func testCustomRulesSurviveALoadAndSave() throws {
        let dir = try TempDir()
        try dir.write("base/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[\"Read\",\"Bash(git *)\"],\"skills\":[],\"instructionFile\":\"dev.md\"}")
        let store = RoleStore(baseDir: dir.url.appendingPathComponent("base"))
        let role = try XCTUnwrap(store.baseRoles().roles.first)
        let draft = RoleDraft(role: role, instructions: "")
        XCTAssertEqual(draft.allowedTools, ["Read", "Bash(git *)"])
        XCTAssertEqual(draft.config().role.allowedTools, ["Read", "Bash(git *)"])
    }

    func testTeamModelListsToolChoicesWithTheirState() throws {
        let dir = try TempDir()
        try dir.write("base/dev.json", "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[\"Read\",\"Bash\"],\"skills\":[],\"instructionFile\":\"dev.md\"}")
        let m = TeamModel(store: RoleStore(baseDir: dir.url.appendingPathComponent("base")), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("c")),
                          claudeHome: dir.url.appendingPathComponent("c"), makeScripts: { _ in nil })
        m.load(seed: false); _ = m.select(m.groups[0].roles[0])
        XCTAssertEqual(m.toolChoices().filter(\.isSelected).map(\.name), ["Read", "Bash"])
        m.toggleTool("Grep")
        XCTAssertTrue(m.toolChoices().first { $0.name == "Grep" }?.isSelected == true)
        XCTAssertTrue(m.isDirty)
    }
}
