import Foundation
@testable import AgentPanel

/// The terminal's commander, key sender and reader as `term.sh` verbs run against a fake terminal script (tests/fixtures/fake-term):
/// the Swift side and the scripts then talk to the same fake. `FAKE_TERM_STATE` must be set in the environment.
struct ScriptTerminal: TerminalCommanding, TerminalKeySending, TerminalReading {
    let script: URL

    init(fixtures: URL) { script = fixtures.appendingPathComponent("fake-term/term-fake.sh") }

    private func run(_ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw BackendError.failed(message ?? text)
        }
        return text
    }

    func prompt(target: String, text: String) async throws { _ = try run(["prompt", target, text]) }
    func sendKeys(target: String, keys: [String]) async throws {
        guard !keys.isEmpty, keys.allSatisfy(TerminalKeys.isAllowed) else { throw BackendError.failed("these keys are not allowed") }
        _ = try run(["keys", target] + keys)
    }
    func sendText(target: String, text: String) async throws { _ = try run(["text", target, text]) }
    func focus(target: String) async throws { _ = try run(["focus", target]) }
    func screen(of target: String, lines: Int) async throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(try run(["read", target, String(lines)]).utf8)) as? [String: Any]
        return (object?["result"] as? [String: Any])?["text"] as? String ?? ""
    }
}
