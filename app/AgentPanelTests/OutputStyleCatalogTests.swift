import XCTest
@testable import AgentPanel

final class OutputStyleCatalogTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private var claudeHome: URL { dir.url.appendingPathComponent("claude") }
    private var repo: URL { dir.url.appendingPathComponent("repo") }

    func testBuiltInsComeFirstWithTheCasingClaudeCodeExpects() {
        XCTAssertEqual(OutputStyleCatalog(claudeHome: claudeHome, repo: nil).names(), ["Default", "Proactive", "Concise", "Explanatory", "Learning"])
    }

    func testUserAndProjectStylesAreListedAfterTheBuiltIns() throws {
        try dir.write("claude/output-styles/zebra.md", "no front matter")
        try dir.write("claude/output-styles/alpha.md", "---\nname: Diagrams first\ndescription: x\n---\nbody")
        try dir.write("repo/.claude/output-styles/house.md", "---\nname: \"House style\"\n---\n")
        let names = OutputStyleCatalog(claudeHome: claudeHome, repo: repo).names()
        XCTAssertEqual(Array(names.dropFirst(5)), ["Diagrams first", "zebra", "House style"], "name from the front matter, else the file name; user styles before project ones")
    }

    func testStyleFileWithoutANameInItsFrontMatterUsesTheFileName() throws {
        try dir.write("claude/output-styles/terse.md", "---\ndescription: short\n---\n")
        XCTAssertTrue(OutputStyleCatalog(claudeHome: claudeHome, repo: nil).names().contains("terse"))
    }

    func testAnUnreadableFileIsSkippedAndNonMarkdownIgnored() throws {
        try FileManager.default.createDirectory(at: claudeHome.appendingPathComponent("output-styles/broken.md"), withIntermediateDirectories: true)
        try dir.write("claude/output-styles/notes.txt", "x")
        try dir.write("claude/output-styles/.hidden.md", "x")
        XCTAssertEqual(OutputStyleCatalog(claudeHome: claudeHome, repo: nil).names().count, 5)
    }

    func testDuplicatesAreListedOnce() throws {
        try dir.write("claude/output-styles/a.md", "---\nname: Same\n---\n")
        try dir.write("repo/.claude/output-styles/b.md", "---\nname: Same\n---\n")
        XCTAssertEqual(OutputStyleCatalog(claudeHome: claudeHome, repo: repo).names().filter { $0 == "Same" }.count, 1)
    }

    func testCanonicalFixesTheCasingOfBuiltInsOnly() {
        XCTAssertEqual(OutputStyleCatalog.canonical("concise"), "Concise")
        XCTAssertEqual(OutputStyleCatalog.canonical("EXPLANATORY"), "Explanatory")
        XCTAssertEqual(OutputStyleCatalog.canonical("default"), "Default")
        XCTAssertEqual(OutputStyleCatalog.canonical("my style"), "my style")
    }
}
