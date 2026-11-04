import XCTest
@testable import AgentPanel

@MainActor
final class RoleTemplateTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func template(_ id: String) throws -> RoleTemplate { try XCTUnwrap(RoleTemplates.all.first { $0.id == id }, id) }

    func testTheTemplateSetIsPmDevReviewerUiDevAnalystAndEmpty() {
        XCTAssertEqual(RoleTemplates.all.map(\.id), ["pm", "dev", "reviewer", "ui_dev", "analyst", "empty"])
        XCTAssertTrue(RoleTemplates.all.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
    }

    func testEveryTemplateIsAValidRoleAndPassesTheScript() throws {
        let dir = try TempDir()
        let writer = RoleWriter(store: RoleStore(baseDir: dir.url.appendingPathComponent("base")))
        for t in RoleTemplates.all where t.id != "empty" {
            let (config, parse) = t.draft.config()
            XCTAssertEqual(parse, [], t.id)
            XCTAssertEqual(RoleValidator.problems(for: config), [], t.id)
            XCTAssertEqual(config.outputStyle, "concise")
            let saved = try writer.save(config, instructions: t.draft.instructions, at: .base, replacing: nil)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [root.appendingPathComponent("scripts/validate-config.sh").path, saved.fileURL.path]
            p.standardOutput = Pipe(); p.standardError = Pipe(); try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "validate-config.sh accepts \(t.id)")
        }
    }

    func testTemplateValuesMatchTheDesign() throws {
        func values(_ id: String) throws -> (String, String, String, [String]) { let d = try template(id).draft; return (d.model, d.effort, d.permissionMode, d.allowedTools) }
        XCTAssertTrue(try values("pm") == ("opus", "high", "manual", ["Read", "Bash"]))
        XCTAssertTrue(try values("dev") == ("sonnet", "medium", "acceptEdits", ["Read", "Edit", "Write", "Bash"]))
        XCTAssertTrue(try values("reviewer") == ("opus", "high", "plan", ["Read", "Bash"]))
        XCTAssertEqual(try template("ui_dev").draft.model, "sonnet")
        XCTAssertTrue(try values("analyst") == ("opus", "medium", "plan", ["Read", "Grep", "Glob", "WebSearch"]))
        XCTAssertEqual(try RoleTemplates.all.map { $0.id == "empty" ? "" : $0.draft.name }, ["pm", "dev", "reviewer", "ui_dev", "analyst", ""])
    }

    func testTemplateInstructionsExplainTheJobAndReportingButNotTheChart() throws {
        for t in RoleTemplates.all where t.id != "empty" {
            let text = t.draft.instructions
            XCTAssertFalse(text.isEmpty, t.id)
            XCTAssertTrue(text.contains("concise"), "\(t.id) keeps the concise baseline")
            XCTAssertTrue(text.lowercased().contains("report"), "\(t.id) says how to report")
            XCTAssertFalse(text.lowercased().contains("your manager"), "the team chart adds who your manager is; the template must not")
            XCTAssertFalse(text.contains("You report to"))
        }
    }

    func testEmptyTemplateIsTheBlankForm() throws {
        XCTAssertEqual(try template("empty").draft, RoleDraft())
    }

    // MARK: in the model

    private func model(_ dir: TempDir, existing: [String] = []) throws -> TeamModel {
        for n in existing {
            try dir.write("base/\(n).json", "{\"name\":\"\(n)\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"\(n).md\"}")
        }
        let m = TeamModel(store: RoleStore(baseDir: dir.url.appendingPathComponent("base")), catalog: SkillCatalog(claudeHome: dir.url.appendingPathComponent("c")),
                          claudeHome: dir.url.appendingPathComponent("c"), makeScripts: { _ in nil })
        m.load(seed: false)
        return m
    }

    func testNewRoleFromTemplateFillsTheFormAndIsEditable() throws {
        let m = try model(try TempDir())
        XCTAssertEqual(m.newRole(from: try template("reviewer"), in: .base), .switched)
        XCTAssertTrue(m.isNew)
        XCTAssertEqual(m.draft.name, "reviewer")
        XCTAssertEqual(m.draft.model, "opus")
        XCTAssertTrue(m.isDirty, "a filled template can be saved at once")
        XCTAssertNil(m.saveDisabledReason)
        m.draft.model = "haiku"
        XCTAssertEqual(m.draft.model, "haiku")
    }

    func testTemplateNameClashShowsTheErrorBeforeSaving() throws {
        let m = try model(try TempDir(), existing: ["pm"])
        m.newRole(from: try template("pm"), in: .base)
        XCTAssertTrue(m.problems.contains { $0.field == "name" && $0.message.contains("already") })
        XCTAssertNotNil(m.saveDisabledReason)
        m.draft.name = "pm2"
        XCTAssertNil(m.saveDisabledReason)
    }

    func testTemplateAsksBeforeReplacingADirtyDraft() throws {
        let dir = try TempDir()
        let m = try model(dir, existing: ["dev"])
        _ = m.select(m.groups[0].roles[0]); m.draft.model = "opus"
        XCTAssertEqual(m.newRole(from: try template("pm"), in: .base), .needsConfirmation)
        XCTAssertEqual(m.draft.name, "dev")
        m.discardAndNewRole(from: try template("pm"), in: .base)
        XCTAssertEqual(m.draft.name, "pm")
        XCTAssertTrue(m.isNew)
    }

    func testSavedRoleCarriesNoTemplateReference() async throws {
        let dir = try TempDir()
        let m = try model(dir)
        m.newRole(from: try template("analyst"), in: .base)
        await m.save()
        XCTAssertNil(m.saveError)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.url.appendingPathComponent("base/analyst.json"))) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["name", "kind", "model", "effort", "permissionMode", "outputStyle", "allowedTools", "skills", "instructionFile"])
        XCTAssertEqual(try String(contentsOf: dir.url.appendingPathComponent("base/analyst.md"), encoding: .utf8), try template("analyst").draft.instructions)
    }
}
