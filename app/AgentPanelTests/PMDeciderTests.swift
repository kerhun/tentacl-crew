import XCTest
@testable import AgentPanel

/// N368: the Codex decider (a fake `codex` binary) and which decider is picked. Claude's decider has its own tests (AutopilotRulesTests).
final class PMDeciderTests: XCTestCase {
    private final class Reader: TerminalReading, @unchecked Sendable { func screen(of target: String, lines: Int) async throws -> String { "" } }
    private final class Sender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        func sendKeys(target: String, keys: [String]) async throws {}
        func prompt(target: String, text: String) async throws {}
    }
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private let request = DecisionRequest(projectName: "Demo", cardID: "A5", cardText: "# A5", agentLabel: "dev", question: AgentQuestion(kind: .choice, title: "T", text: "Which?", options: [QuestionOption(number: 1, label: "A", detail: "", isSpecial: false)]), earlier: [])

    /// A `codex` that records its arguments and writes `answer` to the `-o` file (or sleeps).
    private func fakeCodex(body: String) throws -> URL {
        try dir.write("bin/codex", "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"\(dir.url.path)/args.txt\"\nout=\"\"; while [ $# -gt 0 ]; do [ \"$1\" = -o ] && out=\"$2\"; shift; done\n\(body)\n")
        let url = dir.url.appendingPathComponent("bin/codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private var args: [String] { ((try? String(contentsOf: dir.url.appendingPathComponent("args.txt"), encoding: .utf8)) ?? "").components(separatedBy: "\n") }

    func testCodexRunsReadOnlyWithTheExactArgsAndReadsTheAnswerFile() async throws {
        let exe = try fakeCodex(body: "cp \"$(dirname \"$out\")/schema.json\" \"\(dir.url.path)/schema-seen.json\"\necho '{\"verdict\":\"answer\",\"option\":2,\"options\":null,\"text\":null,\"why\":\"card says so\",\"confidence\":\"high\"}' > \"$out\"")
        let reply = try await CodexPMDecider(model: "gpt-x", timeout: 20, executable: exe).decide(request)
        XCTAssertEqual(reply.decision.verdict, .answer)
        XCTAssertEqual(reply.decision.option, 2)
        XCTAssertNil(reply.costUSD)
        let a = args
        XCTAssertEqual(Array(a.prefix(4)), ["exec", "--json", "--output-schema", a[3]])
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules"] { XCTAssertTrue(a.contains(flag), flag) }
        XCTAssertEqual(a[a.firstIndex(of: "-s")! + 1], "read-only")
        XCTAssertEqual(a[a.firstIndex(of: "-m")! + 1], "gpt-x")
        XCTAssertTrue(a[a.firstIndex(of: "-o")! + 1].hasSuffix("/answer.json"))
        XCTAssertTrue(a[3].hasSuffix("/schema.json"))
        let schema = try String(contentsOf: dir.url.appendingPathComponent("schema-seen.json"), encoding: .utf8)
        XCTAssertEqual(schema, PMPrompt.codexSchema, "the schema file holds the Codex schema")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a[3]), "the temporary folder is removed")
    }

    func testNoModelMeansNoMFlag() async throws {
        let exe = try fakeCodex(body: "echo '{\"verdict\":\"escalate\",\"option\":null,\"options\":null,\"text\":null,\"why\":\"w\",\"confidence\":\"low\"}' > \"$out\"")
        _ = try await CodexPMDecider(model: "", timeout: 20, executable: exe).decide(request)
        XCTAssertFalse(args.contains("-m"))
    }

    func testUnreadableAnswerAndMissingBinaryAreErrors() async throws {
        let bad = try fakeCodex(body: "echo 'not json' > \"$out\"")
        do { _ = try await CodexPMDecider(model: "m", timeout: 20, executable: bad).decide(request); XCTFail() } catch { XCTAssertEqual(error as? PMDecisionError, .unreadable) }
        do { _ = try await CodexPMDecider(model: "m", timeout: 20, locate: { nil }).decide(request); XCTFail() } catch { XCTAssertEqual(error as? PMDecisionError, .notInstalled) }
    }

    func testASlowCodexIsStoppedAtTheTimeout() async throws {
        let slow = try fakeCodex(body: "sleep 30")
        let started = Date()
        do { _ = try await CodexPMDecider(model: "m", timeout: 1, executable: slow).decide(request); XCTFail() } catch { guard case .failed = error as? PMDecisionError else { return XCTFail("\(error)") } }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testTheCodexSchemaNeedsEveryPropertyAndParsesAsPMDecision() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PMPrompt.codexSchema.utf8)) as? [String: Any])
        let props = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(props.keys))
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
    }

    // MARK: which decider

    @MainActor
    func testClaudeDecidesWhileSignedInAndCodexOnlyWhenItIsTheOnlyOne() {
        let dir = try! TempDir()
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        let inbox = AgentInboxModel(reader: Reader(), keys: Sender(), commander: Sender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store)
        m.setProject(ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil))
        XCTAssertTrue(m.pickDecider() is ClaudePMDecider, "default: Claude, whatever the PM runs on")
        m.codexDecides = { true }
        m.codexDefaultModel = { "gpt-d" }
        let codex = m.pickDecider() as? CodexPMDecider
        XCTAssertEqual(codex?.model, "gpt-d")
        var policy = m.policy; policy.codexModel = "gpt-own"; m.update(policy)
        XCTAssertEqual((m.pickDecider() as? CodexPMDecider)?.model, "gpt-own")
        m.codexDecides = { false }
        XCTAssertTrue(m.pickDecider() is ClaudePMDecider)
    }

    func testAnOldPolicyFileHasNoCodexModelAndTheOneWrittenKeepsIt() throws {
        XCTAssertEqual(try JSONDecoder().decode(AutopilotPolicy.self, from: Data(#"{"model":"sonnet"}"#.utf8)).codexModel, "")
        var p = AutopilotPolicy(); p.codexModel = "gpt-x"
        XCTAssertEqual(try JSONDecoder().decode(AutopilotPolicy.self, from: JSONEncoder().encode(p)).codexModel, "gpt-x")
    }
}

/// N368 F1: Codex decides only when Claude is known signed out and Codex is known signed in; anything unknown stays on Claude.
@MainActor
final class CodexDeciderGateTests: XCTestCase {
    private func decides(claude: Bool?, codex: Bool?, warm: Bool = true, claudeInstalled: Bool = true) async throws -> Bool {
        let dir = try TempDir()
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: todo\nagent:\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5 · Title\n")
        let project = try dir.write("p/demo.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":3,\"buildCommand\":\"b\",\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"]}")
        let gate = SignInGate(check: { $0 == .claude ? claude : codex }, findTool: { $0 == "claude" && !claudeInstalled ? nil : URL(fileURLWithPath: "/fake/bin/\($0)") }, spawn: { _, _ in }, exitCode: { _ in 0 }, open: { _ in })
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success([])) }, opener: RecordingOpener(), makeScripts: { _ in FakeScripts() },
                           log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")), defaults: makeTestDefaults(),
                           roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), signInGate: gate)
        await m.reload()
        await gate.refresh(.claude)
        if warm { await gate.refresh(.codex) }
        return m.autopilot.codexDecides()
    }

    func testOnlyClaudeSignedOutAndCodexSignedInGivesCodex() async throws {
        let signedOutAndIn = try await decides(claude: false, codex: true)
        XCTAssertTrue(signedOutAndIn)
        let claudeIn = try await decides(claude: true, codex: true)
        XCTAssertFalse(claudeIn)
        let neverChecked = try await decides(claude: false, codex: true, warm: false)
        XCTAssertFalse(neverChecked, "Codex never checked → Claude")
        let cannotTell = try await decides(claude: false, codex: nil)
        XCTAssertFalse(cannotTell)
        let codexOut = try await decides(claude: false, codex: false)
        XCTAssertFalse(codexOut)
        let claudeUnknown = try await decides(claude: nil, codex: true)
        XCTAssertFalse(claudeUnknown, "Claude's state unknown → Claude")
        let notInstalled = try await decides(claude: nil, codex: true, claudeInstalled: false)
        XCTAssertTrue(notInstalled, "Claude not installed + Codex signed in → Codex (N378)")
        let notInstalledCodexUnknown = try await decides(claude: nil, codex: nil, claudeInstalled: false)
        XCTAssertFalse(notInstalledCodexUnknown)
    }
}
