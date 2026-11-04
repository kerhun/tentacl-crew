import XCTest
@testable import AgentPanel

final class RoleConfigTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func role(_ patch: (inout RoleConfig) -> Void = { _ in }) -> RoleConfig {
        var r = RoleConfig(name: "dev", kind: "interactive", model: "sonnet", effort: "medium", permissionMode: "acceptEdits", outputStyle: "concise",
                           allowedTools: ["Read"], skills: ["superpowers"], instructionFile: "dev.md", displayName: nil, advanced: nil)
        patch(&r)
        return r
    }

    func testRoleDecodesExistingFilesWithoutNewFields() throws {
        for name in ["pm", "dev", "reviewer"] {
            let data = try Data(contentsOf: root.appendingPathComponent("examples/roles/\(name).json"))
            let decoded = try JSONDecoder().decode(RoleConfig.self, from: data)
            XCTAssertEqual(decoded.name, name)
            XCTAssertNil(decoded.displayName)
            XCTAssertNil(decoded.advanced)
            XCTAssertEqual(RoleValidator.problems(for: decoded), [], name)
        }
    }

    func testAdvancedRoundTripsNestedJSON() throws {
        let json = #"{"name":"dev","kind":"interactive","model":"sonnet","effort":"medium","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"dev.md","displayName":"Pixel","advanced":{"permissions":{"deny":["Bash(git push:*)"]},"flag":true,"n":2,"nothing":null}}"#
        let decoded = try JSONDecoder().decode(RoleConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.displayName, "Pixel")
        XCTAssertEqual(decoded.advanced?["permissions"], .object(["deny": .array([.string("Bash(git push:*)")])]))
        XCTAssertEqual(decoded.advanced?["flag"], .bool(true))
        XCTAssertEqual(decoded.advanced?["n"], .number(2))
        XCTAssertEqual(decoded.advanced?["nothing"], JSONValue.null)
        let again = try JSONDecoder().decode(RoleConfig.self, from: try JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
    }

    func testUnknownKeysSurviveARoundTrip() throws {
        let json = #"{"name":"bot","kind":"headless","model":"sonnet","effort":"low","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"bot.md","maxBudgetUsd":5,"future":{"a":[1,2]}}"#
        let decoded = try JSONDecoder().decode(RoleConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.extra["maxBudgetUsd"], .number(5))
        let again = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertEqual(again?["maxBudgetUsd"] as? Double, 5)
        XCTAssertNotNil(again?["future"])
        XCTAssertNotNil(again?["name"])
    }

    func testInstructionFileMustBeAPlainFileName() {
        for bad in ["../secret.txt", "sub/x.md", "..", ".", ""] { XCTAssertEqual(RoleValidator.problems(for: role { $0.instructionFile = bad }).filter { $0.severity == .error }.map(\.field), ["instructionFile"], bad) }
        XCTAssertEqual(RoleValidator.problems(for: role { $0.instructionFile = "dev.md" }), [])
    }

    func testAdvancedThatWidensWhatTheAgentMayDoIsWarnedAbout() {
        func warnings(_ a: [String: JSONValue]) -> Set<String> { Set(RoleValidator.problems(for: role { $0.advanced = a }).filter { $0.severity == .warning }.map(\.field)) }
        XCTAssertEqual(warnings(["permissions": .object(["allow": .array([.string("Bash(*)")])])]), ["advanced.permissions.allow"])
        XCTAssertEqual(warnings(["permissions": .object(["deny": .array([.string("Bash(rm:*)")])])]), ["advanced.permissions.deny"])
        XCTAssertEqual(warnings(["hooks": .object(["PreToolUse": .array([])])]), ["advanced.hooks"])
        XCTAssertEqual(warnings(["apiKeyHelper": .string("x"), "statusLine": .object([:])]), ["advanced.apiKeyHelper", "advanced.statusLine"])
        XCTAssertEqual(warnings(["permissions": .object(["allow": .array([])])]), [], "an empty list adds nothing")
        XCTAssertEqual(warnings(["theme": .string("dark")]), [])
    }

    func testValidNameRules() {
        for ok in ["pm", "dev", "ui_dev", "a", "r2d2", String(repeating: "a", count: 20)] { XCTAssertTrue(RoleValidator.validName(ok), ok) }
        for bad in ["Dev", "a-b", "../x", "a/b", "", "2dev", "_x", String(repeating: "a", count: 21), "dev ", "dév"] { XCTAssertFalse(RoleValidator.validName(bad), bad) }
    }

    func testValidatorMirrorsTheScript() {
        XCTAssertEqual(RoleValidator.problems(for: role()), [])
        func fields(_ patch: (inout RoleConfig) -> Void) -> [String] { RoleValidator.problems(for: role(patch)).filter { $0.severity == .error }.map(\.field) }
        XCTAssertEqual(fields { $0.effort = "ultra" }, ["effort"])
        XCTAssertEqual(fields { $0.permissionMode = "yolo" }, ["permissionMode"])
        XCTAssertEqual(fields { $0.model = "  " }, ["model"])
        XCTAssertEqual(fields { $0.outputStyle = "  " }, ["outputStyle"])
        XCTAssertEqual(fields { $0.outputStyle = "verbose" }, [], "an unknown style is a warning, not an error")
        XCTAssertEqual(fields { $0.kind = "background" }, ["kind"])
        XCTAssertEqual(fields { $0.name = "Dev" }, ["name"])
        XCTAssertEqual(fields { $0.allowedTools = ["Read", ""] }, ["allowedTools"])
        XCTAssertEqual(fields { $0.skills = ["a\nb"] }, ["skills"])
    }

    func testUnknownOutputStyleWarnsOnlyWhenTheCatalogIsGiven() {
        func warnings(_ style: String, known: [String]?) -> [String] {
            RoleValidator.problems(for: role { $0.outputStyle = style }, knownStyles: known).filter { $0.severity == .warning }.map(\.field)
        }
        let known = ["Default", "Concise", "House style"]
        XCTAssertEqual(warnings("concise", known: known), [], "old role files keep loading")
        XCTAssertEqual(warnings("House style", known: known), [])
        XCTAssertEqual(warnings("elsewhere", known: known), ["outputStyle"])
        XCTAssertEqual(warnings("elsewhere", known: nil), [])
    }

    func testDraftKeepsItsOutputStyleThroughTheRoleFile() {
        var d = RoleDraft(); d.name = "dev"; d.outputStyle = "Learning"
        XCTAssertEqual(d.config().role.outputStyle, "Learning")
        XCTAssertEqual(RoleDraft().outputStyle, "concise", "new roles default to concise")
    }

    func testEnvInAdvancedIsAnError() {
        let top = role { $0.advanced = ["env": .object(["TOKEN": .string("x")])] }
        let nested = role { $0.advanced = ["hooks": .object(["x": .array([.object(["env": .string("y")])])])] }
        for r in [top, nested] {
            let p = RoleValidator.problems(for: r).filter { $0.severity == .error }
            XCTAssertEqual(p.map(\.field), ["advanced"])
            XCTAssertTrue(p[0].message.contains("env"))
            XCTAssertFalse(p[0].message.contains("TOKEN"), "values never appear in a message")
        }
    }

    func testAdvancedConflictsAreWarnings() {
        let r = role { $0.advanced = ["model": .string("opus"), "permissions": .object(["defaultMode": .string("plan")]),
                                      "enabledPlugins": .object([:]), "skillOverrides": .object([:])] }
        let p = RoleValidator.problems(for: r)
        XCTAssertEqual(p.filter { $0.severity == .error }, [])
        XCTAssertEqual(Set(p.filter { $0.severity == .warning }.map(\.field)), ["advanced.model", "advanced.permissions.defaultMode", "advanced.enabledPlugins", "advanced.skillOverrides"])
        XCTAssertEqual(RoleValidator.problems(for: role { $0.advanced = ["permissions": .object(["deny": .array([])])] }), [], "an empty deny list is fine")
    }

    func testDisplayNameLimits() {
        XCTAssertEqual(RoleValidator.problems(for: role { $0.displayName = String(repeating: "x", count: 40) }), [])
        XCTAssertEqual(RoleValidator.problems(for: role { $0.displayName = String(repeating: "x", count: 41) }).map(\.field), ["displayName"])
        XCTAssertEqual(RoleValidator.problems(for: role { $0.displayName = "a\nb" }).map(\.field), ["displayName"])
        XCTAssertEqual(RoleValidator.problems(for: role { $0.displayName = "" }), [], "empty means no display name")
    }

    func testToolDefaultsToClaudeAndRoundTrips() throws {
        let old = #"{"name":"dev","kind":"interactive","model":"sonnet","effort":"medium","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"dev.md"}"#
        let decoded = try JSONDecoder().decode(RoleConfig.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.tool, "claude")
        XCTAssertNil(decoded.extra["tool"])
        let codex = try JSONDecoder().decode(RoleConfig.self, from: Data(old.replacingOccurrences(of: #""kind""#, with: #""tool":"codex","kind""#).utf8))
        XCTAssertEqual(codex.tool, "codex")
        XCTAssertNil(codex.extra["tool"])
        let again = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(codex)) as? [String: Any]
        XCTAssertEqual(again?["tool"] as? String, "codex")
    }

    func testToolMustBeClaudeOrCodex() {
        func fields(_ patch: (inout RoleConfig) -> Void) -> [String] { RoleValidator.problems(for: role(patch)).filter { $0.severity == .error }.map(\.field) }
        XCTAssertEqual(fields { $0.tool = "claude" }, [])
        XCTAssertEqual(fields { $0.tool = "codex"; $0.model = "gpt-5.5" }, [])
        XCTAssertEqual(fields { $0.tool = "gemini" }, ["tool"])
    }

    func testCodexRolesUseCodexEffortsAndPermissionModes() {
        func fields(_ patch: (inout RoleConfig) -> Void) -> [String] {
            RoleValidator.problems(for: role { $0.tool = "codex"; $0.model = "gpt-5.5"; patch(&$0) }).filter { $0.severity == .error }.map(\.field)
        }
        for e in ["low", "medium", "high", "xhigh"] { XCTAssertEqual(fields { $0.effort = e }, [], e) }
        XCTAssertEqual(fields { $0.effort = "max" }, [], "fallback list when no catalog is known")
        XCTAssertEqual(RoleValidator.problems(for: role { $0.tool = "codex"; $0.model = "gpt-5.5"; $0.effort = "ultra" }, codexEfforts: ["low", "ultra"]).filter { $0.severity == .error }.map(\.field), [])
        XCTAssertEqual(RoleValidator.problems(for: role { $0.tool = "codex"; $0.model = "gpt-5.5"; $0.effort = "max" }, codexEfforts: ["low", "ultra"]).filter { $0.severity == .error }.map(\.field), ["effort"])
        for m in ["manual", "acceptEdits", "plan", "bypassPermissions"] { XCTAssertEqual(fields { $0.permissionMode = m }, [], m) }
        for m in ["auto", "dontAsk"] { XCTAssertEqual(fields { $0.permissionMode = m }, ["permissionMode"], m) }
        XCTAssertEqual(fields { $0.model = " " }, ["model"])
        XCTAssertEqual(fields { $0.model = "claude-opus" }, [], "any non-empty model until the Codex catalog exists")
    }

    func testCodexRolesReportClaudeOnlyKeysAsIgnored() {
        func warnings(_ patch: (inout RoleConfig) -> Void) -> [String] {
            RoleValidator.problems(for: role { $0.tool = "codex"; $0.model = "gpt-5.5"; $0.skills = []; $0.allowedTools = []; patch(&$0) }, knownStyles: ["Default", "Concise"])
                .filter { $0.severity == .warning }.map(\.field)
        }
        XCTAssertEqual(warnings { _ in }, [], "the default style and empty lists say nothing")
        XCTAssertEqual(warnings { $0.skills = ["superpowers"] }, ["skills"])
        XCTAssertEqual(warnings { $0.allowedTools = ["Read"] }, ["allowedTools"])
        XCTAssertEqual(warnings { $0.outputStyle = "Learning" }, ["outputStyle"])
        XCTAssertEqual(warnings { $0.advanced = ["theme": .string("dark")] }, ["advanced"])
        XCTAssertEqual(RoleValidator.problems(for: role { $0.advanced = ["theme": .string("dark")] }), [], "Claude roles are unchanged")
    }

    func testPMRoleMayUseEitherTool() {
        func fields(_ name: String, _ tool: String) -> [String] {
            RoleValidator.problems(for: role { $0.name = name; $0.tool = tool; $0.model = "gpt-5.5" }).filter { $0.severity == .error }.map(\.field)
        }
        XCTAssertEqual(fields("pm", "codex"), [])
        XCTAssertEqual(fields("pm", "claude"), [])
        XCTAssertEqual(fields("dev", "codex"), [])
    }
}
