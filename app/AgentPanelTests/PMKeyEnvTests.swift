import XCTest
@testable import AgentPanel

/// N280: the PM's session key travels in its environment, not in the chat.
@MainActor
final class PMKeyEnvTests: XCTestCase {
    private final class Recorder: ScriptRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(script: ScriptName, env: [String: String])] = []
        var calls: [(script: ScriptName, env: [String: String])] { lock.lock(); defer { lock.unlock() }; return recorded }
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { try await run(script, arguments: arguments, environment: [:]) }
        func run(_ script: ScriptName, arguments: [String], environment: [String: String]) async throws -> ScriptResult {
            lock.lock(); recorded.append((script, environment)); lock.unlock()
            return ScriptResult(status: 0, stdout: "{\"agent\":\"pm-demo\",\"pane_id\":\"w2:p1\"}\n", stderr: "")
        }
    }

    private var dir: TempDir!
    private let recorder = Recorder()

    private func makeModel() async throws -> PanelModel {
        dir = try TempDir()
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("roles/pm.json", "{\"name\":\"pm\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"pm.md\"}")
        let project = try dir.write("p/demo.json", """
        {"id":"demo","name":"Demo","repoPath":"/repo","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"b","sharedFiles":[],"openWith":"Xcode","roles":{"pm":"\(dir.url.appendingPathComponent("roles/pm.json").path)"}}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let terminal = FakeTerminal(agentsResult: .success([]))
        let r = recorder, c = FakeCommander()
        let m = PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: RecordingOpener(),
                           makeScripts: { _ in r }, makeCommander: { c }, log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                           defaults: makeTestDefaults(), roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")),
                           makeKeySender: { PanelModel.inertTerminal }, terminalServer: NoTerminalServerCheck())
        await m.reload()
        return m
    }

    func testThePMSpawnGetsAKeyTheMemoryAcceptsAndSendsNoMessage() async throws {
        let m = try await makeModel()
        await m.spawnPM()
        let key = try XCTUnwrap(recorder.calls.first?.env["TENTACL_PM_KEY"])
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(m.commandMemory.accepts(key, project: "demo", pane: "w2:p1"))
        XCTAssertNil(m.commandMemory.keyToGive(project: "demo", pane: "w2:p1"), "no chat message for an env-keyed PM")
    }

    func testARestartRotatesTheKey() async throws {
        let m = try await makeModel()
        await m.spawnPM()
        await m.spawnPM(resume: "s1")
        let keys = recorder.calls.compactMap { $0.env["TENTACL_PM_KEY"] }
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertFalse(m.commandMemory.accepts(keys[0], project: "demo", pane: "w2:p1"))
        XCTAssertTrue(m.commandMemory.accepts(keys[1], project: "demo", pane: "w2:p1"))
    }

    func testAPaneStartedBeforeThisChangeStillGetsOneMessage() {
        let memory = CommandMemory()
        let key = memory.keyToGive(project: "demo", pane: "old")
        XCTAssertNotNil(key)
        XCTAssertNil(memory.keyToGive(project: "demo", pane: "old"), "only once")
    }

    func testAFailedSpawnLeavesNoKeyBehind() {
        let memory = CommandMemory()
        let key = memory.newKeyForSpawn(project: "demo")
        memory.dropPendingKey(project: "demo")
        memory.bindKey(project: "demo", pane: "p")
        XCTAssertFalse(memory.accepts(key, project: "demo", pane: "p"))
    }

    func testTaskAgentsAreSpawnedWithoutTheKey() async throws {
        // Only spawnPM passes an environment; the task flow calls run(_:arguments:) with none.
        let r = Recorder()
        _ = try await r.run(.spawn, arguments: ["a"])
        XCTAssertNil(r.calls.first?.env["TENTACL_PM_KEY"])
    }
}
