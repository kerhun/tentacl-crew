import XCTest
@testable import AgentPanel

/// The Tentacl backend against the built helper on a temp socket (never the real term.sock).
final class TentaclBackendTests: XCTestCase {
    private var dir: String!
    private var socket: String!
    private var daemon: Process!
    private var client: TentacldClient!
    private var cache: TempDir!
    private var activated = 0

    override func setUpWithError() throws {
        dir = "/tmp/tlb-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        socket = dir + "/s.sock"
        client = TentacldClient(socketPath: socket)
        cache = try TempDir()
        activated = 0
    }

    override func tearDown() {
        stopDaemon(daemon)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func startDaemon() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: client.helper.path), "helper missing: \(client.helper.path)")
        daemon = Process()
        daemon.executableURL = client.helper
        daemon.arguments = ["--socket", socket]
        try daemon.run()
        try await waitUntil("daemon answers") { await client.ping() }
    }

    private func backend() -> TentaclBackend {
        TentaclBackend(client: client, cache: cache.url, activate: { [unowned self] in activated += 1 }, pasteDelay: .zero)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 8, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await cond()) == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// A fake agent: answers every line it is typed as `got:[<line>]`.
    private func fakeAgent(_ id: String) async throws {
        try await client.spawn(id: id, argv: ["/bin/sh", "-c", #"echo ready; while IFS= read -r l; do echo "got:[$l]"; done"#], cwd: dir)
        try await waitUntil("ready") { try await client.read(id: id).contains("ready") }
    }

    private func screenHas(_ b: TentaclBackend, _ id: String, _ text: String) async throws {
        try await waitUntil(text) { try await b.screen(of: id, lines: 40).contains(text) }
    }

    func testNoDaemonMeansNoAgentsAndNothingIsStarted() async throws {
        let b = backend()
        let agents = try await b.agents()
        let workspaces = try await b.workspaces()
        XCTAssertEqual(agents, [])
        XCTAssertEqual(workspaces, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }

    func testAgentsJoinSessionsWithStateFiles() async throws {
        try await startDaemon()
        try await fakeAgent("pilot-a5")
        try await fakeAgent("pilot-b1")
        try cache.write("pilot-a5/state.json", #"{"v":1,"agent":"pilot-a5","status":"blocked","session_id":"sess-1","seq":7,"completion_seq":2}"#)
        let agents = try await backend().agents().sorted { $0.paneID < $1.paneID }
        XCTAssertEqual(agents.map(\.paneID), ["pilot-a5", "pilot-b1"])
        XCTAssertEqual(agents.map(\.state), [.blocked, .unknown("unknown")], "a missing state file is unknown")
        XCTAssertEqual(agents[0].name, "pilot-a5")
        XCTAssertEqual(agents[0].workspaceID, "pilot-a5")
        XCTAssertEqual(agents[0].sessionID, "sess-1")
        XCTAssertEqual(agents[0].changeSeq, 7)
        XCTAssertEqual(URL(fileURLWithPath: agents[0].cwd).resolvingSymlinksInPath().path, URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
        XCTAssertNil(agents[1].sessionID)
    }

    /// A fake program that prints the OSC 7501 records typed to it as `rec:<text>` lines (`printf` of the record).
    private func oscAgent(_ id: String) async throws {
        try await client.spawn(id: id, argv: ["/bin/sh", "-c", #"echo ready; while IFS= read -r l; do printf "\033]7501;$l\007"; done"#], cwd: dir)
        try await waitUntil("ready") { try await client.read(id: id).contains("ready") }
    }

    private func record(_ id: String, _ r: String) async throws {
        try await client.write(id: id, text: r + "\n")
    }

    private func state(_ id: String, changeSeq: ((Int?) -> Bool)? = nil) async throws -> AgentStatus? {
        try await backend().agents().first { $0.paneID == id }
    }

    func testStateComesFromTheOSC7501RecordHookFileIsOnlyTheFallback() async throws {
        try await startDaemon()
        try await oscAgent("o")
        try cache.write("o/state.json", #"{"status":"idle","seq":9,"completion_seq":4,"session_id":"h1"}"#)
        var s = try await state("o")
        XCTAssertEqual(s?.state, .idle, "no record yet: the hook file")
        XCTAssertEqual(s?.changeSeq, 9)

        try await record("o", "state=working:app=fake")
        try await waitUntil("working") { try await state("o")?.state == .working }
        s = try await state("o")
        XCTAssertEqual(s?.sessionID, "h1")
        XCTAssertNotEqual(s?.changeSeq, 9, "the record's own counter, not the hook file's")

        try await record("o", "state=blocked:app=fake:kind=permission:msg=YXBwcm92ZQ==")
        try await waitUntil("blocked") { try await state("o")?.state == .blocked }
        try await record("o", "state=error:app=fake")
        try await waitUntil("error reads as blocked") { try await state("o")?.changeSeq ?? 0 > (s?.changeSeq ?? 0) + 1 }
        let e = try await state("o")
        XCTAssertEqual(e?.state, .blocked)

        try await record("o", "state=working:app=fake")
        try await waitUntil("working again") { try await state("o")?.state == .working }
        let before = try await client.status(id: "o")?.completionSeq ?? -1
        try await record("o", "state=done:app=fake")
        try await waitUntil("done") { try await state("o")?.state == .done }
        let after = try await client.status(id: "o")?.completionSeq ?? -1
        XCTAssertEqual(after, before + 1, "a finished turn bumps completion_seq")

        try await record("o", "state=clear")
        try await waitUntil("clear falls back to the hook file") { try await state("o")?.state == .idle }
        let f = try await state("o")
        XCTAssertEqual(f?.changeSeq, 9)
    }

    func testNoRecordAndNoHookFileIsUnknownAndAnEndedSessionWinsOverARecord() async throws {
        try await startDaemon()
        try await oscAgent("n")
        var s = try await state("n")
        XCTAssertEqual(s?.state, .unknown("unknown"))
        try await record("n", "state=working:app=fake")
        try await waitUntil("working") { try await state("n")?.state == .working }
        try await client.kill(id: "n")
        try await waitUntil("ended") { try await client.list().first { $0.id == "n" }?.alive == false }
        s = try await state("n")
        XCTAssertEqual(s?.state, .unknown("unknown"))
    }

    func testAnEndedSessionIsUnknownAndWorkspacesCarryTheFolder() async throws {
        try await startDaemon()
        try await client.spawn(id: "gone", argv: ["/bin/sh", "-c", "exit 0"], cwd: dir)
        try cache.write("gone/state.json", #"{"status":"working","seq":1}"#)
        try await waitUntil("session ended") { try await client.list().first { $0.id == "gone" }?.alive == false }
        let b = backend()
        let agents = try await b.agents()
        XCTAssertEqual(agents.map(\.state), [.unknown("unknown")])
        let workspaces = try await b.workspaces()
        XCTAssertEqual(workspaces.map(\.workspaceID), ["gone"])
        XCTAssertEqual(workspaces.first?.label, "gone")
        XCTAssertNotNil(workspaces.first?.checkoutPath)
    }

    func testPromptPastesTheTextWholeThenEnter() async throws {
        try await startDaemon()
        try await fakeAgent("a")
        let b = backend()
        try await b.prompt(target: "a", text: "hello çğı")
        try await screenHas(b, "a", "got:[hello çğı]")
    }

    func testKeysAndTextReachTheAgent() async throws {
        try await startDaemon()
        try await fakeAgent("a")
        let b = backend()
        try await b.sendText(target: "a", text: "typed")
        try await b.sendKeys(target: "a", keys: ["1", "2", "enter"])
        try await screenHas(b, "a", "got:[typed12]")
    }

    func testKeysAreCheckedAndTargetsMustBePlainNames() async throws {
        try await startDaemon()
        try await fakeAgent("a")
        let b = backend()
        await XCTAssertThrowsErrorAsync(try await b.sendKeys(target: "a", keys: ["f5"]))
        await XCTAssertThrowsErrorAsync(try await b.sendKeys(target: "a", keys: []))
        await XCTAssertThrowsErrorAsync(try await b.prompt(target: "a", text: "  "))
        await XCTAssertThrowsErrorAsync(try await b.screen(of: "../x", lines: 5))
        await XCTAssertThrowsErrorAsync(try await b.sendText(target: "a b", text: "x"))
        await XCTAssertThrowsErrorAsync(try await b.screen(of: "nobody", lines: 5), "a session that is not there is an error")
    }

    func testScreenReturnsTheLastLinesTrimmed() async throws {
        try await startDaemon()
        try await fakeAgent("a")
        let b = backend()
        for n in 1...5 { try await b.sendText(target: "a", text: "l\(n)\r") }
        try await screenHas(b, "a", "got:[l5]")
        let two = try await b.screen(of: "a", lines: 2)
        XCTAssertEqual(two, "l5\ngot:[l5]", "the tty echoes each line before the answer")
    }

    // N239: a real session; the scrollback read of the daemon trims every line, the screen read keeps the margin
    func testScreenKeepsTheIndentationOfCode() async throws {
        try await startDaemon()
        try await client.spawn(id: "c", argv: ["/bin/sh", "-c", #"printf 'old\n'; i=0; while [ $i -lt 30 ]; do echo "line $i"; i=$((i+1)); done; printf 'for f in *; do\n  if [ -f "$f" ]; then\n    echo "$f"\n  fi\ndone\n'; sleep 30"#], cwd: dir)
        let b = backend()
        try await screenHas(b, "c", "done")
        let text = try await b.screen(of: "c", lines: 200)
        XCTAssertTrue(text.contains("for f in *; do\n  if [ -f \"$f\" ]; then\n    echo \"$f\"\n  fi\ndone"), text)
        XCTAssertTrue(text.contains("line 0"), "the older lines come from the scrollback")
    }

    func testMergedTakesTheMarginOnlyFromRowsThatAreTheSame() {
        XCTAssertEqual(TentaclBackend.merged(history: "a\nb\nc", visible: "  b\n    c", lines: 10), "a\n  b\n    c")
        XCTAssertEqual(TentaclBackend.merged(history: "a\nb\nc", visible: "x\n    c", lines: 10), "a\nb\n    c", "a different row is not trusted")
        XCTAssertEqual(TentaclBackend.merged(history: "a\nb\nc", visible: nil, lines: 2), "b\nc")
    }

    func testFocusActivatesTheApp() async throws {
        try await startDaemon()
        try await fakeAgent("a")
        try await backend().focus(target: "a")
        XCTAssertEqual(activated, 1)
    }
}

private func XCTAssertThrowsErrorAsync(_ body: @autoclosure () async throws -> some Any, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await body(); XCTFail("expected an error. \(message)", file: file, line: line) } catch {}
}

/// Ends a test daemon without ever blocking the run (N338): SIGTERM, then SIGKILL after 3 s; a bare `waitUntilExit()` waits for ever on a daemon that does not end.
func stopDaemon(_ p: Process?) {
    guard let p, p.isRunning else { return }
    p.terminate()
    let end = Date().addingTimeInterval(3)
    while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    p.waitUntilExit()
}
