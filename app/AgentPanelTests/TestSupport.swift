import Foundation
import XCTest
@testable import AgentPanel

/// Lets a test hold an async operation until it decides to release it.
actor TestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Test-only defaults suites. A suite named by a path keeps its preference file in a folder of its own under the temporary directory
/// instead of ~/Library/Preferences (N116, N186): the preference daemon writes a removed domain's empty file back about a second
/// after the removal and no wait or delete in the test can stop that, but it cannot write into a folder that is gone.
enum TestDefaults {
    /// The name of the suite made last (for the test of this helper).
    nonisolated(unsafe) private(set) static var lastName = ""
    /// A new suite name: a path in a folder of its own, `<tmp>/agent-panel-test-defaults-<uuid>/<prefix>`.
    static func newName(prefix: String = "agent-panel-tests") -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-panel-test-defaults-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(prefix).path
    }
    /// A fresh suite; `owner` removes its domain, its file and its folder when the test ends.
    static func make(_ owner: XCTestCase, prefix: String = "agent-panel-tests") -> UserDefaults {
        let name = newName(prefix: prefix)
        let defaults = open(name)
        lastName = name
        owner.addTeardownBlock { discard(defaults, name: name) }
        return defaults
    }
    /// The one place a test opens a suite by name; everything else goes through `make`.
    static func open(_ name: String) -> UserDefaults { UserDefaults(suiteName: name)! }
    static func discard(_ defaults: UserDefaults, name: String) {
        defaults.removePersistentDomain(forName: name)
        // Pending writes go to the preference daemon first, so the file is not rewritten from a stale copy after it was deleted.
        defaults.synchronize()
        try? FileManager.default.removeItem(at: fileURL(of: name).deletingLastPathComponent())
    }
    /// Where the suite's preference file lives.
    static func fileURL(of name: String) -> URL { URL(fileURLWithPath: name + ".plist") }
}

extension XCTestCase {
    func makeTestDefaults(prefix: String = "agent-panel-tests") -> UserDefaults { TestDefaults.make(self, prefix: prefix) }
}

/// A temporary action log, defaults suite and roles folder, so a test never touches the user's real ones (N93).
struct TestIsolation {
    let log: ActionLog
    let defaults: UserDefaults
    let roleStore: RoleStore
    init(folder: URL, owner: XCTestCase) {
        log = ActionLog(fileURL: folder.appendingPathComponent("actions.log"))
        defaults = TestDefaults.make(owner)
        roleStore = RoleStore(baseDir: folder.appendingPathComponent("no-roles"))
    }
    init(_ dir: TempDir, owner: XCTestCase) { self.init(folder: dir.url, owner: owner) }
}

/// A stand-in for the terminal launcher that records the calls and can fail.
final class RecordingServer: TerminalServerEnsuring, @unchecked Sendable {
    private let lock = NSLock(); private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    var failure: Error?
    var announces = false
    var onCall: (@Sendable () -> Void)?
    func ensureRunning(onStarting: @escaping @Sendable () -> Void) async throws {
        lock.withLock { _calls += 1 }
        onCall?()
        if announces { onStarting() }
        if let failure { throw failure }
    }
}

/// Records the arguments of every call and answers with canned output.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    var output: Data
    var error: Error?
    init(output: Data = Data(), error: Error? = nil) { self.output = output; self.error = error }
    func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        calls.append(arguments)
        if let error { throw error }
        return output
    }
}
