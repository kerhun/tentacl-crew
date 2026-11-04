import XCTest
@testable import AgentPanel

/// Runs the built helper (Contents/Helpers/tentacld of the test host) on a temp socket, never on the real term.sock.
final class TentacldTests: XCTestCase {
    private var dir: String!
    private var socket: String!
    private var daemon: Process!
    private var client: TentacldClient!

    override func setUpWithError() throws {
        dir = "/tmp/tld-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        socket = dir + "/s.sock"
        client = TentacldClient(socketPath: socket)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: client.helper.path), "helper missing: \(client.helper.path)")
        daemon = Process()
        daemon.executableURL = client.helper
        daemon.arguments = ["--socket", socket]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CODE_X": "1", "TMUX": "x", "HERDR_ENV": "1", "LANG": "C"]) { $1 }   // what a child must not inherit
        try daemon.run()
    }

    override func tearDown() {
        daemon?.terminate()
        daemon?.waitUntilExit()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 8, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await cond()) == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func start() async throws {
        try await waitUntil("daemon answers") { await client.ping() }
    }

    private func shell(_ id: String = "s1") async throws {
        try await start()
        try await client.spawn(id: id, argv: ["/bin/sh"], cwd: dir, cols: 100, rows: 30)
    }

    func testWriteThenReadSeesOutput() async throws {
        try await shell()
        try await client.write(id: "s1", text: "echo hi-$((6*7))\n")
        try await waitUntil("hi-42") { try await client.read(id: "s1").split(separator: "\n").contains("hi-42") }
    }

    func testResizeChangesSttySize() async throws {
        try await shell()
        try await client.resize(id: "s1", cols: 90, rows: 20)
        try await client.write(id: "s1", text: "stty size\n")
        try await waitUntil("20 90") { try await client.read(id: "s1").split(separator: "\n").contains("20 90") }
        let info = try await client.list().first { $0.id == "s1" }
        XCTAssertEqual(info?.cols, 90)
        XCTAssertEqual(info?.rows, 20)
    }

    func testKillEndsTheSession() async throws {
        try await shell()
        try await client.kill(id: "s1")
        try await waitUntil("session ended") { try await client.list().first { $0.id == "s1" }?.alive == false }
        let dead = try await client.list().first { $0.id == "s1" }
        XCTAssertNotNil(dead?.exitCode ?? (dead?.alive == false ? -1 : nil))
        try await client.kill(id: "s1")   // a second kill removes the entry
        let left = try await client.list()
        XCTAssertFalse(left.contains { $0.id == "s1" })
    }

    func testChildExitMarksSessionDead() async throws {
        try await shell()
        try await client.write(id: "s1", text: "exit 3\n")
        try await waitUntil("exit code 3") { try await client.list().first { $0.id == "s1" }?.exitCode == 3 }
    }

    func testClientDisconnectKeepsSession() async throws {
        try await shell()
        let a = try await client.attach(id: "s1")
        a.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        let info = try await client.list().first { $0.id == "s1" }
        XCTAssertEqual(info?.alive, true)
        try await client.write(id: "s1", text: "echo still-$((1+1))\n")
        try await waitUntil("still-2") { try await client.read(id: "s1").split(separator: "\n").contains("still-2") }
    }

    func testReattachGetsTheRingThenLiveBytes() async throws {
        try await shell()
        try await client.write(id: "s1", text: "echo ring-$((5+5))\n")
        try await waitUntil("ring-10") { try await client.read(id: "s1").split(separator: "\n").contains("ring-10") }
        let a = try await client.attach(id: "s1")
        XCTAssertTrue(String(decoding: a.ring, as: UTF8.self).contains("ring-10"))
        XCTAssertEqual(a.cols, 100)
        a.send(Data("echo live-$((2+2))\n".utf8))   // typed through the attach connection
        var seen = ""
        for await chunk in a.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("live-4\r\n") { break }
        }
        XCTAssertTrue(seen.contains("live-4"))
        a.close()
    }

    func testOSC7501QueryIsAnsweredAndStatusIsKept() async throws {
        try await start()
        let script = dir + "/fake.sh"
        try """
        stty raw -echo
        printf '\\033]7501;?\\007'
        r=$(dd bs=1 count=9 2>/dev/null | od -An -c | tr -d ' ')
        stty sane
        printf '\\033]7501;state=working:app=fake\\007'
        printf 'GOT:%s\\n' "$r"
        sleep 30
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try await client.spawn(id: "f", argv: ["/bin/sh", script], cwd: dir)
        try await waitUntil("answer reached the program") { try await client.read(id: "f").contains("GOT:033]7501;?\\a") }
        try await waitUntil("working status") { try await client.status(id: "f")?.state == "working" }
        let st = try await client.status(id: "f")
        XCTAssertEqual(st?.app, "fake")
        XCTAssertEqual(st?.live, true)
        let listed = try await client.list().first { $0.id == "f" }
        XCTAssertEqual(listed?.status?.state, "working")
    }

    func testSecondDaemonOnTheSameSocketExits() async throws {
        try await start()
        let second = Process()
        second.executableURL = client.helper
        second.arguments = ["--socket", socket]
        try second.run()
        let end = Date().addingTimeInterval(8)
        while second.isRunning && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(second.isRunning, "the second daemon should exit")
        if !second.isRunning { XCTAssertEqual(second.terminationStatus, 0) } else { second.terminate() }
        let ok = await client.ping()
        XCTAssertTrue(ok, "the first daemon still answers")
        XCTAssertTrue(daemon.isRunning)
    }

    func testEnsureRunningStartsTheHelperWhenNothingAnswers() async throws {
        daemon.terminate(); daemon.waitUntilExit()
        let c = TentacldClient(socketPath: dir + "/e.sock")
        try await c.ensureRunning()
        let ok = await c.ping()
        XCTAssertTrue(ok)
        try await c.ensureRunning()   // already running: no error
        // the helper outlives this client; stop it through its session-less pid
        let out = Process(); out.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        out.arguments = ["-f", "tentacld --socket \(dir!)/e.sock"]
        try out.run(); out.waitUntilExit()
    }

    func testStrippedEnvironmentAndTurkishRoundTrip() async throws {
        try await start()
        try await client.spawn(id: "t", argv: ["/bin/sh"], cwd: dir)
        try await client.write(id: "t", text: "echo çğıöşü | wc -c\n")
        try await waitUntil("13 bytes") { try await client.read(id: "t").split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "13" } }
        try await client.write(id: "t", text: "echo çğıöşü\n")
        try await waitUntil("text back") { try await client.read(id: "t").split(separator: "\n").filter { $0 == "çğıöşü" }.count == 1 }
        try await client.write(id: "t", text: "env | grep -c -E '^(CLAUDE_CODE_|TMUX|HERDR_)'; echo TERM=$TERM\n")
        try await waitUntil("env stripped") {
            let s = try await client.read(id: "t")
            return s.contains("TERM=xterm-256color") && s.split(separator: "\n").contains("0")
        }
    }

    func testSpawnErrorsAreReported() async throws {
        try await start()
        do { _ = try await client.spawn(id: "bad", argv: ["/no/such/program"], cwd: dir); XCTFail("should fail") }
        catch { XCTAssertTrue(error is TentacldClient.TentacldError) }
        do { _ = try await client.read(id: "nope"); XCTFail("should fail") }
        catch { XCTAssertEqual((error as? TentacldClient.TentacldError)?.message, "no such session") }
    }
}
