import XCTest
@testable import AgentPanel

/// The launcher against the built tentacld helper on a temp socket; never the real term.sock. A helper the launcher starts outlives the
/// test on purpose (it is meant to), so tearDown stops it by its socket path.
final class TerminalServerTests: XCTestCase {
    private var dir: String!
    private var socket: String!

    override func setUpWithError() throws {
        dir = "/tmp/tls-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        socket = dir + "/s.sock"
    }

    override func tearDown() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "tentacld --socket \(socket!)"]
        try? kill.run(); kill.waitUntilExit()
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testTheLauncherStartsTentacldWhenNothingAnswersAndAnnouncesIt() async throws {
        let client = TentacldClient(socketPath: socket)
        let launcher = TentacldLauncher(client: client)
        let pingedBefore = await client.ping()
        XCTAssertFalse(pingedBefore)
        let seen = Seen()
        try await launcher.ensureRunning(onStarting: { seen.add("starting") })
        let pingedAfter = await client.ping()
        XCTAssertTrue(pingedAfter)
        XCTAssertEqual(seen.all, ["starting"])
        try await launcher.ensureRunning(onStarting: { seen.add("again") })
        XCTAssertEqual(seen.all, ["starting"], "a daemon that answers is left alone")
    }

    func testAMissingHelperIsOnePlainFailure() async {
        let client = TentacldClient(socketPath: socket, helper: URL(fileURLWithPath: "/nonexistent/tentacld"))
        do { try await TentacldLauncher(client: client).ensureRunning(onStarting: {}); XCTFail("should fail") }
        catch let BackendError.failed(message) { XCTAssertTrue(message.contains("/nonexistent/tentacld"), message) }
        catch { XCTFail("wrong error \(error)") }
    }

    func testRawJSONIsCutToTheMessage() {
        let raw = #"ERROR: the terminal is not reachable: {"id":"x","error":{"code":"unreachable","message":"tentacld does not answer"}}"#
        XCTAssertEqual(TerminalMessage.plain(raw), "ERROR: the terminal is not reachable: tentacld does not answer")
        XCTAssertEqual(TerminalMessage.plain("the script exited with status 3"), "the script exited with status 3")
        XCTAssertEqual(TerminalMessage.plain("bad {not json"), "bad {not json")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        var all: [String] { lock.withLock { items } }
        func add(_ s: String) { lock.withLock { items.append(s) } }
    }
}
