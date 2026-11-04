import Foundation

/// What a failed review packet came to (N202): tests that failed, a run that never completed (not the agent's fault), or work the agent left undone.
enum PacketFailure: Equatable {
    struct FailedTest: Equatable {
        /// "AgentPanelTests.TestDefaultsTests.testX"
        var name: String
        /// "app/AgentPanelTests/TestDefaultsTests.swift:29", nil when the log does not say.
        var location: String?
        var message: String?
        var line: String {
            guard let location else { return "- \(name)" }
            return "- \(name) — \(location)" + (message.map { ": \($0)" } ?? "")
        }
    }

    /// Named failing tests: the agent fixes them.
    case tests([FailedTest], log: String?)
    /// The test host crashed or restarted, the run timed out, xcodebuild failed before any test, or no test is named: retried by itself, never sent to the agent.
    case infrastructure(reason: String)
    /// Uncommitted files, a failed build, an empty report and the like: the agent's to fix, as before.
    case workLeft(lines: [String])

    /// Lines that mean the run itself broke, not the code (each is a wording of review-packet.sh, app-test.sh or xcodebuild).
    static let infrastructureMarkers = [
        "RUNNER RESTARTED", "Restarting after unexpected exit", "unexpected exit", "Test crashed", "host exit:", "crash report:",
        "test host crashed", "lost connection", "Lost connection", "timed out", "test timeout", "Test runner",
        "for another packet to finish", "for another test run to finish", "xcodegen failed", "Unable to find a destination",
        "No space left on device", "could not create a build worktree", "Testing failed because",
    ]
    /// Lines that say the build or the work itself is wrong.
    static let workMarkers = ["build failed", "** BUILD FAILED **", "uncommitted work", "report section is empty", "changed files in the worktree", "TEST LEFTOVERS"]

    static func classify(_ text: String) -> PacketFailure {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let marker = lines.first(where: { line in infrastructureMarkers.contains { line.contains($0) } }) {
            return .infrastructure(reason: String(marker.prefix(200)))
        }
        if lines.contains(where: { line in workMarkers.contains { line.contains($0) } }) {
            return .workLeft(lines: lines.filter { !isPassingSummary($0) })
        }
        let tests = failedTests(in: lines)
        if !tests.isEmpty { return .tests(tests, log: logPath(in: text)) }
        // "** TEST FAILED **" and no test named: a crash or restart left no name, so there is nothing for the agent to fix.
        if lines.contains(where: { $0.contains("** TEST FAILED **") || $0.contains("tests failed") }) {
            return .infrastructure(reason: "The test run failed without naming a failing test.")
        }
        return .workLeft(lines: lines.filter { !isPassingSummary($0) })
    }

    /// "Executed 9 tests, with 0 failures": says nothing about what went wrong.
    static func isPassingSummary(_ line: String) -> Bool {
        line.range(of: #"Executed \d+ tests?, with (\d+ tests? skipped and )?0 failures"#, options: .regularExpression) != nil
    }

    static func logPath(in text: String) -> String? {
        guard let r = text.range(of: #"see (/\S+)"#, options: .regularExpression) else { return nil }
        return String(text[r].dropFirst(4))
    }

    /// Failing tests from the app-test summary: `failed  Class.test` lines, with file, line and message from the matching `path:N: error: -[Class test] : message`.
    static func failedTests(in lines: [String]) -> [FailedTest] {
        var tests: [FailedTest] = []
        func key(_ name: String) -> String { testKey(name) }
        func add(_ name: String, _ location: String?, _ message: String?) {
            if let i = tests.firstIndex(where: { key($0.name) == key(name) }) {
                if name.count > tests[i].name.count { tests[i].name = name }
                if tests[i].location == nil { tests[i].location = location; tests[i].message = message }
            } else {
                tests.append(FailedTest(name: name, location: location, message: message))
            }
        }
        for raw in lines {
            let line = raw.hasPrefix("RAW ") ? String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces) : raw
            if let m = line.firstMatch(#"^(.+?):(\d+): error: -\[([\w.]+) (\w+)\] : (.*)$"#) {
                var path = m[1]
                if let r = path.range(of: "/app/") { path = "app/" + path[r.upperBound...] }
                add("\(m[3]).\(m[4])", "\(path):\(m[2])", m[5])
            } else if let m = line.firstMatch(#"^failed\s+(\S+)$"#) {
                add(m[1], nil, nil)
            }
        }
        return tests
    }

    /// "AgentPanelTests.Class.test" and "Class.test" are one test: compared on their last two parts.
    static func testKey(_ name: String) -> String { name.split(separator: ".").suffix(2).joined(separator: ".") }

    /// The failing tests split by whether they also fail on main (N214): `own` are the agent's to fix, `onMain` are not its doing.
    static func split(_ tests: [FailedTest], failingOnMain names: [String]) -> (own: [FailedTest], onMain: [FailedTest]) {
        let keys = Set(names.map(testKey))
        return (tests.filter { !keys.contains(testKey($0.name)) }, tests.filter { keys.contains(testKey($0.name)) })
    }

    /// The note for the agent: each failing test with file:line and message, and the log. `leftOut` are tests that also fail on main: named, but not asked for.
    static func fixNotes(_ tests: [FailedTest], log: String?, leftOut: [FailedTest] = []) -> (notes: String, shown: String) {
        let list = tests.map(\.line).joined(separator: "\n")
        let tail = log.map { "\n\nFull log: \($0)" } ?? ""
        let skipped = leftOut.isEmpty ? "" : "\n\nLeft out because they fail on main too (not caused by this branch):\n" + leftOut.map(\.line).joined(separator: "\n")
        return ("The review packet could not be prepared: \(tests.count) test\(tests.count == 1 ? "" : "s") failed. Fix this, commit, redo the build and screenshots, and update the Report:\n\n\(list)\(skipped)\(tail)",
                list + (leftOut.isEmpty ? "" : "\nAlso fail on main, left out: " + leftOut.map(\.name).joined(separator: ", ")) + (log.map { "\nLog: \($0)" } ?? ""))
    }
}

/// What running the named tests on main came to (N214).
enum MainCheck: Equatable {
    /// The run completed: these of the named tests fail on main (none when all pass).
    case failing([String])
    /// The run itself could not be made (checkout, build, crash, timeout).
    case unavailable(reason: String)
}

private extension String {
    /// Capture groups of the first match (index 0 is the whole match); nil when there is none.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: self).map { String(self[$0]) } ?? "" }
    }
}
