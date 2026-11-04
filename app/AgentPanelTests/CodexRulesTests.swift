import XCTest
import SwiftUI
@testable import AgentPanel

/// N367: "Copy my Claude rules to Codex…" against a temp HOME.
@MainActor
final class CodexRulesTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private var agents: URL { dir.url.appendingPathComponent(".codex/AGENTS.md") }
    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func testPreviewIsTheClaudeRulesBetweenMarkers() throws {
        try dir.write(".claude/CLAUDE.md", "\n# graphify\n- use the graph\n\n# Brain wiki\n- wiki first\n\n")
        let rules = CodexRules(home: dir.url)
        let flow = try XCTUnwrap(CodexRulesFlow(rules: rules))
        XCTAssertEqual(flow.preview, "\(CodexRules.begin)\n# graphify\n- use the graph\n\n# Brain wiki\n- wiki first\n\(CodexRules.end)\n")
        XCTAssertFalse(flow.replaces)
        XCTAssertTrue(rules.needsOffer)
        XCTAssertEqual(flow.agentsPath.hasSuffix(".codex/AGENTS.md"), true)
    }

    func testAddAppendsWithMarkersAndKeepsTheFile() throws {
        try dir.write(".claude/CLAUDE.md", "- wiki first")
        try dir.write(".codex/AGENTS.md", "# My Codex notes\nkeep me")
        let flow = try XCTUnwrap(CodexRulesFlow(rules: CodexRules(home: dir.url)))
        flow.add()
        XCTAssertEqual(flow.phase, .added)
        XCTAssertEqual(text(agents), "# My Codex notes\nkeep me\n\n\(CodexRules.begin)\n- wiki first\n\(CodexRules.end)\n")
        XCTAssertFalse(CodexRules(home: dir.url).needsOffer)
    }

    func testASecondRunReplacesTheBlock() throws {
        try dir.write(".claude/CLAUDE.md", "- old rule")
        try dir.write(".codex/AGENTS.md", "top\n")
        try XCTUnwrap(CodexRulesFlow(rules: CodexRules(home: dir.url))).add()
        try text(agents)!.appending("bottom\n").write(to: agents, atomically: true, encoding: .utf8)
        try dir.write(".claude/CLAUDE.md", "- new rule")
        let rules = CodexRules(home: dir.url)
        XCTAssertTrue(rules.needsOffer, "changed rules are offered again")
        let flow = try XCTUnwrap(CodexRulesFlow(rules: rules))
        XCTAssertTrue(flow.replaces)
        flow.add()
        let after = try XCTUnwrap(text(agents))
        XCTAssertEqual(after, "top\n\n\(CodexRules.begin)\n- new rule\n\(CodexRules.end)\nbottom\n")
        XCTAssertEqual(after.components(separatedBy: CodexRules.begin).count, 2, "one block, not two")
    }

    func testNothingIsWrittenWithoutAdd() throws {
        try dir.write(".claude/CLAUDE.md", "- wiki first")
        let flow = try XCTUnwrap(CodexRulesFlow(rules: CodexRules(home: dir.url)))
        _ = flow.preview
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.deletingLastPathComponent().path))
    }

    func testNoClaudeRulesNoOffer() throws {
        XCTAssertNil(CodexRulesFlow(rules: CodexRules(home: dir.url)))
        XCTAssertFalse(CodexRules(home: dir.url).needsOffer)
        try dir.write(".claude/CLAUDE.md", "  \n")
        XCTAssertNil(CodexRules(home: dir.url).block)
    }

    func testRulesSheetSnapshot() throws {
        try dir.write(".claude/CLAUDE.md", """
        # graphify
        - **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`

        # Brain wiki (all projects)
        - Shared knowledge base: `~/notes/wiki`.
        - Code questions: (1) graphify query, (2) wiki pages, (3) raw code last.
        """)
        let flow = try XCTUnwrap(CodexRulesFlow(rules: CodexRules(home: dir.url)))
        let data = try XCTUnwrap(SnapshotRenderer.render(view: CodexRulesSheet(flow: flow, onClose: {}), size: CGSize(width: 600, height: 460)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N367-rules.png")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path))
    }
}
