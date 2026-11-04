import Foundation

struct ScriptResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ScriptError: Error, Equatable {
    case notConfigured(String)
    case timedOut(Int)
    /// A review packet that never took the machine-wide build slot within the wait limit (N264); the run limit did not start.
    case waitTimedOut(Int)
    case launchFailed(String)
}

protocol ScriptRunning: Sendable {
    func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult
    /// The same with extra environment variables for this one run (N280: the PM's session key). A runner that cannot pass them ignores them.
    func run(_ script: ScriptName, arguments: [String], environment: [String: String]) async throws -> ScriptResult
}

extension ScriptRunning {
    func run(_ script: ScriptName, arguments: [String], environment: [String: String]) async throws -> ScriptResult {
        try await run(script, arguments: arguments)
    }
}

/// Runs one of the configured Phase 0 scripts with `/bin/bash <script> <arguments…>`.
/// Arguments are passed as separate arguments (no shell string is ever built), stdin is empty, output on both streams is
/// collected, and a script that runs too long is sent SIGTERM and then SIGKILL.
/// Ends a child process when the awaiting Swift Task is cancelled: SIGTERM at once, SIGKILL to the whole process group
/// after `grace`. The process may be set after the cancellation arrived (the handler can run before the process starts).
final class ProcessCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var onCancel: (@Sendable () -> Void)?
    let grace: TimeInterval
    init(grace: TimeInterval) { self.grace = grace }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// `onCancel` runs once, when the cancellation arrives (or at once when it already did).
    func attach(_ process: Process, onCancel: @escaping @Sendable () -> Void) {
        lock.lock()
        self.process = process; self.onCancel = onCancel
        let already = cancelled
        lock.unlock()
        if already { fire() }
    }

    func cancel() {
        lock.lock(); cancelled = true; let attached = process != nil; lock.unlock()
        if attached { fire() }
    }

    private func fire() {
        lock.lock(); let p = process, callback = onCancel; onCancel = nil; lock.unlock()
        guard let p, let callback else { return }
        if p.isRunning { p.terminate() }
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if p.isRunning { kill(pid, SIGKILL) }
            killpg(pid, SIGKILL)
        }
        callback()
    }
}

struct ProcessScriptRunner: ScriptRunning {
    let settings: AppSettings
    var timeout: TimeInterval = 120
    /// A review packet builds the app, which takes far longer than starting an agent.
    var reviewPacketTimeout: TimeInterval = 1800
    /// N264: the packet's run limit counts from the moment it prints `packetRunMarker` (the build slot is taken); the wait before that
    /// has its own, longer limit (a little above the script's own 2700 s slot timeout, so the script reports its wait first).
    var reviewPacketWaitTimeout: TimeInterval = 3000
    static let packetRunMarker = "PACKET RUN STARTED"
    var killGrace: TimeInterval = 2
    var extraEnvironment: [String: String] = [:]
    /// N105: the action log a script appends to (merge-task.sh). Nil means the app's real log, or under XCTest a temporary file.
    var actionLogURL: URL?
    var shell = URL(fileURLWithPath: "/bin/bash")

    /// Starting an agent may first run the project's setup command (up to 10 minutes in spawn-agent.sh); nil keeps `timeout`.
    var spawnTimeout: TimeInterval?
    func limit(for script: ScriptName) -> TimeInterval { script == .reviewPacket ? reviewPacketTimeout : script == .spawn ? (spawnTimeout ?? timeout) : timeout }

    init(settings: AppSettings, timeout: TimeInterval = 120, killGrace: TimeInterval = 2, extraEnvironment: [String: String] = [:]) {
        self.settings = settings
        self.timeout = timeout
        self.killGrace = killGrace
        self.extraEnvironment = extraEnvironment
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var outEOF = false, errEOF = false, terminated = false, finished = false
        private var status: Int32 = 0
        private var timedOut = false
        private var generation = 0, runStarted = false
        private let continuation: CheckedContinuation<ScriptResult, Error>
        init(_ continuation: CheckedContinuation<ScriptResult, Error>) { self.continuation = continuation }

        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
        var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
        func nextGeneration() -> Int { lock.lock(); generation += 1; defer { lock.unlock() }; return generation }
        /// True once, when the collected output first contains `marker`.
        func sawMarker(_ marker: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !runStarted, String(decoding: out, as: UTF8.self).contains(marker) else { return false }
            runStarted = true; return true
        }
        func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
        func eofOut() { lock.lock(); outEOF = true; lock.unlock(); finishIfDone() }
        func eofErr() { lock.lock(); errEOF = true; lock.unlock(); finishIfDone() }
        func didTerminate(_ code: Int32) { lock.lock(); terminated = true; status = code; lock.unlock(); finishIfDone() }

        private func finishIfDone() {
            lock.lock(); let done = terminated && outEOF && errEOF; lock.unlock()
            if done { finish() }
        }

        /// Finishes with what was collected so far, exactly once (also used when a child keeps a pipe open).
        func finish() {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            let result = ScriptResult(status: status, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
            lock.unlock()
            continuation.resume(returning: result)
        }

        func fail(_ error: Error) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    /// Under XCTest the real log belongs to the user (N93): scripts get one temporary file per test process instead.
    private static let testActionLog = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-script-actions-\(ProcessInfo.processInfo.processIdentifier).log")

    private var resolvedActionLog: URL {
        if let actionLogURL { return actionLogURL }
        return PanelModel.runsUnderXCTest ? Self.testActionLog : ActionLog.defaultURL
    }

    private var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(existing)"
    }

    /// The language agents write their questions to the user in (N279); read when a spawn runs.
    var userLanguage: @Sendable () -> String = { QuestionSettings.language(.standard) }

    func run(_ script: ScriptName, arguments: [String], environment: [String: String]) async throws -> ScriptResult {
        var withEnvironment = self
        withEnvironment.extraEnvironment.merge(environment) { _, new in new }
        return try await withEnvironment.run(script, arguments: arguments)
    }

    func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult {
        guard let url = settings.scriptURL(script) else { throw ScriptError.notConfigured(script.rawValue) }
        if script == .spawn, extraEnvironment["TENTACL_USER_LANGUAGE"] == nil {
            var withLanguage = self
            withLanguage.extraEnvironment["TENTACL_USER_LANGUAGE"] = userLanguage()
            return try await withLanguage.run(file: url, arguments: arguments, timeout: limit(for: script), waitTimeout: nil)
        }
        return try await run(file: url, arguments: arguments, timeout: limit(for: script), waitTimeout: script == .reviewPacket ? reviewPacketWaitTimeout : nil)
    }

    /// Runs a script file that was already checked to lie inside `scriptsDir`, the same way.
    /// With `waitTimeout`, `timeout` only starts when the script prints `packetRunMarker`; until then `waitTimeout` applies.
    func run(file url: URL, arguments: [String], timeout: TimeInterval, waitTimeout: TimeInterval? = nil) async throws -> ScriptResult {
        let canceller = ProcessCanceller(grace: killGrace)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await start(file: url, arguments: arguments, timeout: timeout, waitTimeout: waitTimeout, canceller: canceller)
        } onCancel: { canceller.cancel() }
    }

    private func start(file url: URL, arguments: [String], timeout: TimeInterval, waitTimeout: TimeInterval?, canceller: ProcessCanceller) async throws -> ScriptResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = RunState(continuation)
            let process = Process()
            process.executableURL = shell
            process.arguments = [url.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            environment["TENTACL_ACTION_LOG"] = resolvedActionLog.path
            for (key, value) in extraEnvironment { environment[key] = value }
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err

            func arm(_ seconds: TimeInterval, wait: Bool) {
                let gen = state.nextGeneration()
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    guard !state.isFinished, state.currentGeneration == gen else { return }
                    state.markTimedOut()
                    if process.isRunning { process.terminate() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                        // Foundation runs the script in its own process group; SIGKILL the group so children that ignored SIGTERM die too.
                        let pid = process.processIdentifier
                        if process.isRunning { kill(pid, SIGKILL) }
                        killpg(pid, SIGKILL)
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        let secs = Int(seconds.rounded(.up))
                        state.fail(wait ? ScriptError.waitTimedOut(secs) : ScriptError.timedOut(secs))
                    }
                }
            }

            out.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; state.eofOut() } else { state.appendOut(chunk); if waitTimeout != nil, state.sawMarker(Self.packetRunMarker) { arm(timeout, wait: false) } }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; state.eofErr() } else { state.appendErr(chunk) }
            }
            process.terminationHandler = { p in
                if state.didTimeOut { return }   // the deadline path reports the timeout
                state.didTerminate(p.terminationStatus)
                // A child that inherited a pipe can keep it open; do not wait for EOF longer than a moment.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    state.finish()
                }
            }
            if let waitTimeout { arm(waitTimeout, wait: true) } else { arm(timeout, wait: false) }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                state.fail(ScriptError.launchFailed(error.localizedDescription))
                return
            }
            canceller.attach(process) {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                state.fail(CancellationError())
            }
        }
    }
}
