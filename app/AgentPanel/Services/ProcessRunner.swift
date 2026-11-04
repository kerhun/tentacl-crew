import Foundation

/// Runs a command with `Process` and returns its standard output.
/// A command that runs longer than `timeout` is sent SIGTERM and, after `killGrace`, SIGKILL; the caller is released
/// at that point even when a child process still holds the output pipe open.
struct ProcessRunner: CommandRunner {
    var timeout: TimeInterval = 10
    var killGrace: TimeInterval = 1

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Shared state of one run; every callback may arrive on a different queue.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var finished = false
        private var terminated = false
        private var sawEOF = false
        private var terminationFailure: Failure?
        private var timeoutFailure: Failure?
        private let continuation: CheckedContinuation<Data, Error>

        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var timeout: Failure? { lock.lock(); defer { lock.unlock() }; return timeoutFailure }
        func setTimedOut(_ failure: Failure) { lock.lock(); timeoutFailure = failure; lock.unlock() }
        func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }

        func markEOF() { lock.lock(); sawEOF = true; lock.unlock(); finishIfDone() }
        func markTerminated(_ failure: Failure?) { lock.lock(); terminated = true; terminationFailure = failure; lock.unlock(); finishIfDone() }

        /// Done when the process has ended and its output reached EOF.
        private func finishIfDone() {
            lock.lock()
            let done = terminated && sawEOF
            lock.unlock()
            if done { finish() }
        }

        /// Finishes with whatever was collected (or the termination failure), exactly once.
        func finish() {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            let data = buffer, failure = terminationFailure
            lock.unlock()
            if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: data) }
        }

        func fail(_ error: Error) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    /// Reads what is in the pipe right now without waiting for more (a child may still hold its write end open).
    private static func drain(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        let canceller = ProcessCanceller(grace: killGrace)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await start(executable, arguments, canceller: canceller)
        } onCancel: { canceller.cancel() }
    }

    private func start(_ executable: URL, _ arguments: [String], canceller: ProcessCanceller) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let state = RunState(continuation)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let out = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice

            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; state.markEOF() } else { state.append(chunk) }
            }
            process.terminationHandler = { p in
                let failure = state.timeout ?? (p.terminationReason == .uncaughtSignal ? Failure(message: "the command was stopped by signal \(p.terminationStatus)") : nil)
                state.markTerminated(failure)
                // A child that inherited the pipe can keep it open; do not wait for EOF longer than a moment.
                // Under load the read callback can lag behind the exit: take what is already in the pipe before finishing.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    out.fileHandleForReading.readabilityHandler = nil
                    state.append(Self.drain(out.fileHandleForReading.fileDescriptor))
                    state.finish()
                }
            }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                state.fail(error)
                return
            }
            canceller.attach(process) {
                out.fileHandleForReading.readabilityHandler = nil
                state.fail(CancellationError())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !state.isFinished else { return }
                let timedOut = Failure(message: "the command did not finish within \(Int(timeout.rounded(.up))) seconds")
                state.setTimedOut(timedOut)
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                    let pid = process.processIdentifier
                    if process.isRunning { kill(pid, SIGKILL) }
                    killpg(pid, SIGKILL)
                    out.fileHandleForReading.readabilityHandler = nil
                    state.fail(timedOut)
                }
            }
        }
    }
}
