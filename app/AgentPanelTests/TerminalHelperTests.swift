import XCTest
@testable import AgentPanel

/// The first of two callers wins (a result or a timeout).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// N275: the history switch, the old-helper notice and its restart, on a helper started on a temp socket (never the real term.sock).
@MainActor
final class TerminalHelperTests: XCTestCase {
    private var dir: String!
    private var socket: String!
    private var daemon: Process?
    private var client: TentacldClient!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = "/tmp/tlh-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        socket = dir + "/s.sock"
        client = TentacldClient(socketPath: socket)
        defaults = makeTestDefaults(prefix: "terminal-helper")
    }

    override func tearDown() async throws {
        // The daemon this test started goes first and without asking the socket, so a test that failed or timed out never leaves one behind (N346 F1).
        if let p = daemon, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        if let pid = await bounded(seconds: 5, { try? await self.client.helperPID() }).value ?? nil { kill(pid, SIGKILL) }
        if let p = daemon {
            let end = Date().addingTimeInterval(5)
            while p.isRunning, Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Runs `work` but gives up after `seconds`: a call to the helper that never comes back fails the test instead of stalling the run (N346 F1).
    private func bounded<T>(seconds: Double = 10, _ work: @escaping @MainActor () async -> T) async -> (value: T?, timedOut: Bool) {
        let once = ResumeOnce()
        return await withCheckedContinuation { cont in
            Task { @MainActor in let v = await work(); if once.take() { cont.resume(returning: (v, false)) } }
            // The timer is on the main queue, not a global one: when the stall is a full dispatch pool, a global timer would wait too.
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if once.take() { cont.resume(returning: (nil, true)) } }
        }
    }

    private func helperInfo(_ line: UInt = #line) async -> HelperInfo? {
        let r = await bounded { await self.client.helperInfo() }
        if r.timedOut { XCTFail("the helper did not answer ping within 10 s", line: line) }
        return r.value ?? nil
    }

    private func startHelper() async throws {
        let p = Process()
        p.executableURL = client.helper
        p.arguments = ["--socket", socket]
        try p.run()
        daemon = p
        let end = Date().addingTimeInterval(8)
        while Date() < end, await !client.ping() { try await Task.sleep(nanoseconds: 50_000_000) }
        let up = await client.ping()
        XCTAssertTrue(up, "helper answers")
    }

    private struct NoGit: CommandRunner { func run(_ executable: URL, _ arguments: [String]) async throws -> Data { Data() } }
    private struct NoLogin: LoginItemControlling { var isEnabled: Bool { false }; func setEnabled(_ on: Bool) throws {} }

    private func flow(bundled: Date?) -> SettingsFlow {
        let c = client!
        return SettingsFlow(settings: AppSettings(scriptsDir: nil, problems: []), settingsURL: URL(fileURLWithPath: dir + "/projects.json"),
                            stableDir: URL(fileURLWithPath: dir + "/stable"), signingConfigured: false, git: NoGit(),
                            release: { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") }, appURL: URL(fileURLWithPath: dir + "/App.app"), processID: 1,
                            launch: { _, _ in },
                            extras: SettingsExtras(defaults: defaults, loginItem: NoLogin(), toolProbe: { _ in nil }, terminal: { c }, bundledHelperDate: bundled))
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while Date() < end { if cond() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("timed out waiting for \(what)")
    }

    private var historyFiles: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir + "/history")) ?? []).filter { $0.hasSuffix(".json") } }

    // MARK: version compare

    func testHelperIsOldWhenBuiltBeforeTheBundledOneOrNotReported() {
        let now = Date()
        XCTAssertTrue(HelperInfo(built: now.addingTimeInterval(-3600), started: nil).isOld(bundled: now))
        XCTAssertFalse(HelperInfo(built: now, started: nil).isOld(bundled: now), "same is current")
        XCTAssertFalse(HelperInfo(built: now.addingTimeInterval(5), started: nil).isOld(bundled: now), "newer is current")
        XCTAssertTrue(HelperInfo(built: nil, started: nil).isOld(bundled: now), "an old daemon reports nothing")
        XCTAssertFalse(HelperInfo(built: now, started: nil).isOld(bundled: nil), "nothing to compare with")
    }

    /// An in-place update replaces the binary under a running daemon: its `built` stays the one it started with.
    func testBuiltIsReadAtStartNotAtTheFirstPing() async throws {
        let copy = URL(fileURLWithPath: dir + "/tentacld")
        try FileManager.default.copyItem(at: client.helper, to: copy)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: copy.path)
        let p = Process()
        p.executableURL = copy
        p.arguments = ["--socket", socket]
        try p.run()
        daemon = p
        let end = Date().addingTimeInterval(8)
        while Date() < end, !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(nanoseconds: 50_000_000) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)   // the update
        let got = await helperInfo()
        XCTAssertEqual(got?.built?.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
    }

    func testPingReportsBuildAndStart() async throws {
        try await startHelper()
        let got = await helperInfo()
        let info = try XCTUnwrap(got)
        XCTAssertNotNil(info.built); XCTAssertNotNil(info.started)
        XCTAssertFalse(info.isOld(bundled: HelperInfo.bundledDate()), "the bundled helper is not older than itself")
    }

    // MARK: history switch

    func testRestoreHistoryDefaultsOnAndIsRemembered() {
        XCTAssertTrue(flow(bundled: nil).restoreHistory)
        let f = flow(bundled: nil)
        f.setRestoreHistory(false)
        XCTAssertFalse(TerminalSettings.restoreHistory(defaults))
        XCTAssertFalse(flow(bundled: nil).restoreHistory)
    }

    func testHistoryOffSpawnSavesNothingAndOnSaves() async throws {
        try await startHelper()
        _ = try await TerminalShells.open(client: client, cwd: dir, argv: ["/bin/sh", "-c", "echo off-run"], history: false)
        _ = try await TerminalShells.open(client: client, cwd: dir, argv: ["/bin/sh", "-c", "echo on-run"], history: true)
        try await waitUntil("the shell with history saves its file") { historyFiles == ["my-shell-2.json"] }
        XCTAssertFalse(historyFiles.contains("my-shell-1.json"), "history: false saves no file")
    }

    func testDeleteSavedHistoryRemovesTheFilesButTurningOffDoesNot() async throws {
        try await startHelper()
        _ = try await TerminalShells.open(client: client, cwd: dir, argv: ["/bin/sh", "-c", "echo x"])
        try await waitUntil("a saved file") { !historyFiles.isEmpty }
        let f = flow(bundled: nil)
        f.setRestoreHistory(false)
        XCTAssertFalse(historyFiles.isEmpty, "the switch deletes nothing")
        await f.deleteSavedHistory()
        XCTAssertTrue(historyFiles.isEmpty)
    }

    // MARK: old helper

    func testCurrentHelperShowsNoNoticeAndOldOneAllowsRestart() async throws {
        try await startHelper()
        let current = flow(bundled: Date(timeIntervalSince1970: 1))
        await current.refreshHelper()
        XCTAssertEqual(current.helper, .current)
        XCTAssertFalse(current.canRestartHelper)

        let old = flow(bundled: Date().addingTimeInterval(3600))
        await old.refreshHelper()
        guard case .old(let started) = old.helper else { return XCTFail("expected old, got \(old.helper)") }
        XCTAssertNotNil(started)
        XCTAssertTrue(old.canRestartHelper)
    }

    func testRestartIsDisabledWhileAnAgentSessionRuns() async throws {
        try await startHelper()
        try await client.spawn(id: "w1:p1", argv: ["/bin/sh"], cwd: dir)
        let f = flow(bundled: Date().addingTimeInterval(3600))
        await f.refreshHelper()
        XCTAssertEqual(f.agentSessions, 1)
        XCTAssertFalse(f.canRestartHelper)
        await f.restartHelper()
        let sessions = try await client.list()
        XCTAssertTrue(sessions.contains { $0.id == "w1:p1" && $0.alive }, "nothing was closed")
    }

    func testRestartNamesTheShellsAndStartsANewHelper() async throws {
        try await startHelper()
        _ = try await TerminalShells.open(client: client, cwd: dir, argv: ["/bin/sh"])
        _ = try await TerminalShells.open(client: client, cwd: dir, argv: ["/bin/sh"])
        let f = flow(bundled: Date().addingTimeInterval(3600))
        await f.refreshHelper()
        XCTAssertEqual(f.shellCount, 2)
        XCTAssertTrue(f.restartQuestion.contains("2 open shells will close"), f.restartQuestion)
        XCTAssertTrue(f.restartQuestion.contains("their text will not come back this time"))
        let before = try await client.helperPID()
        await f.restartHelper()
        XCTAssertNil(f.terminalError)
        let after = try await client.helperPID()
        XCTAssertNotEqual(before, after)
        let left = try await client.list()
        XCTAssertTrue(left.isEmpty, "the shells closed")
    }

    func testTerminalsSettingsRender() async throws {
        try await startHelper()
        let f = flow(bundled: Date().addingTimeInterval(3600))
        f.show(.terminals)
        await f.refreshHelper()
        guard case .old = f.helper else { return XCTFail("expected an old helper") }
        let size = CGSize(width: 900, height: 560)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: SettingsView(flow: f), size: size))
        XCTAssertGreaterThan(data.count, 20_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N275-terminals-settings.png")) }
    }
}
