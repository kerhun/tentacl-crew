import XCTest

/// Tests never open a defaults suite on their own: a suite by name lands in ~/Library/Preferences and stays there (N190).
/// Everything goes through `TestDefaults` / `makeTestDefaults` (TestSupport.swift), which keeps the file in a temporary folder.
final class TestHygieneTests: XCTestCase {
    func testNoTestSourceOpensADefaultsSuiteOutsideTestSupport() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let needle = "UserDefaults(" + "suiteName:"   // split, so this file does not match itself
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "the scan found the test sources")
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "TestSupport.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains(needle) {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "use makeTestDefaults(prefix:) instead")
    }
}
