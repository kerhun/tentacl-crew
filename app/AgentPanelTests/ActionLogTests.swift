import XCTest
@testable import AgentPanel

final class ActionLogTests: XCTestCase {
    func testAppendsOneLinePerAction() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("support/actions.log")
        let log = ActionLog(fileURL: url)
        log.append("start A5 agent=dev-a5")
        log.append("command to w3:p1: hello")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("start A5 agent=dev-a5"))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(lines[0].prefix(20))), "line starts with an ISO 8601 timestamp: \(lines[0])")
    }

    func testMultiLineTextStaysOnOneLine() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("actions.log")
        ActionLog(fileURL: url).append("command: first\nsecond\rthird")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 1)
    }

    func testFailureToWriteIsSilent() throws {
        let dir = try TempDir()
        let blocker = try dir.write("blocker", "file")
        ActionLog(fileURL: blocker.appendingPathComponent("sub/actions.log")).append("nothing happens")   // must not crash or throw
    }

    /// Every `log.append(` of the flows, the command bar and the request handlers must pass `project:`.
    func testNoUntaggedAppendInTheSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPanel")
        for file in ["Services/StartTaskFlow.swift", "Services/ReviewFlow.swift", "State/CommandCenter.swift", "State/StartRequestHandler.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            var rest = Substring(text)
            while let r = rest.range(of: "log.append(") {
                var depth = 1, i = r.upperBound
                while i < rest.endIndex, depth > 0 { if rest[i] == "(" { depth += 1 } else if rest[i] == ")" { depth -= 1 }; i = rest.index(after: i) }
                XCTAssertTrue(rest[r.lowerBound..<i].contains("project:"), "\(file): \(rest[r.lowerBound..<i].prefix(70))")
                rest = rest[i...]
            }
        }
    }
}
