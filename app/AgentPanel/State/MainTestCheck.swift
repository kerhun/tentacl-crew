import Foundation

/// Runs only the tests a packet failed on in a throwaway detached checkout of main (N214), to tell a test the branch broke from one main already fails.
/// `scripts/app-test.sh` of that checkout does the run, so it waits for the machine-wide build slot like every other run.
struct MainTestCheck: Sendable {
    typealias Exec = @Sendable (_ args: [String], _ cwd: String) async -> (status: Int32, output: String)

    let repo: String
    let base: String
    /// Where the checkout is made; removed afterwards.
    let folder: URL
    var exec: Exec = MainTestCheck.process

    static let testTarget = "AgentPanelTests"

    /// "AgentPanelTests.Class.test" and "Class.test" both become `-only-testing:AgentPanelTests/Class/test`.
    static func onlyTesting(_ name: String) -> String {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return "-only-testing:\(testTarget)/\(name)" }
        return "-only-testing:\(testTarget)/\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    func run(_ tests: [String]) async -> MainCheck {
        let add = await exec(["git", "worktree", "add", "--detach", folder.path, base], repo)
        guard add.status == 0 else { return .unavailable(reason: "could not check out \(base): \(add.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))") }
        let result: MainCheck
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("scripts/app-test.sh").path) {
            let run = await exec(["bash", "scripts/app-test.sh"] + tests.map(Self.onlyTesting), folder.path)
            result = Self.interpret(status: run.status, output: run.output)
        } else {
            result = .unavailable(reason: "\(base) has no scripts/app-test.sh")
        }
        _ = await exec(["git", "worktree", "remove", "--force", folder.path], repo)
        try? FileManager.default.removeItem(at: folder)
        _ = await exec(["git", "worktree", "prune"], repo)
        return result
    }

    /// The run's result: named failures are the answer; a pass is "none fail"; anything else (crash, timeout, build error) is no answer.
    static func interpret(status: Int32, output: String) -> MainCheck {
        switch PacketFailure.classify(output) {
        case .tests(let tests, _): return .failing(tests.map(\.name))
        case .infrastructure(let reason): return status == 0 ? .failing([]) : .unavailable(reason: reason)
        case .workLeft(let lines):
            return status == 0 ? .failing([]) : .unavailable(reason: lines.suffix(2).joined(separator: " ").prefix(160).description)
        }
    }

    static let process: Exec = { args, cwd in
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var data = Data()
            let lock = NSLock()
            pipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.withLock { data.append(d) } }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = lock.withLock { data.append(rest); return String(decoding: data, as: UTF8.self) }
                cont.resume(returning: (proc.terminationStatus, out))
            }
            do { try p.run() } catch { cont.resume(returning: (127, "could not start \(args.first ?? ""): \(error.localizedDescription)")); return }
            // A run that hangs is ended after 30 minutes: "timed out" classifies as infrastructure.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1800) {
                if p.isRunning { lock.withLock { data.append(Data("\ntimed out after 30 min\n".utf8)) }; p.terminate() }
            }
        }
    }
}
