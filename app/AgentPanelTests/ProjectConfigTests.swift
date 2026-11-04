import XCTest
@testable import AgentPanel

final class ProjectConfigTests: XCTestCase {
    private let base = #"{"id":"a","name":"A","repoPath":"/tmp/a","dataDir":"/tmp/a-data","maxParallel":4,"sharedFiles":[]"#

    func testTestCommandIsOptional() throws {
        let p = try JSONDecoder().decode(ProjectConfig.self, from: Data((base + "}").utf8))
        XCTAssertNil(p.testCommand)
    }

    func testTestCommandIsReadAndWritten() throws {
        let p = try JSONDecoder().decode(ProjectConfig.self, from: Data((base + #","testCommand":"make test"}"#).utf8))
        XCTAssertEqual(p.testCommand, "make test")
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any]
        XCTAssertEqual(back?["testCommand"] as? String, "make test")
    }

    func testTestCommandIsAKnownKey() {
        XCTAssertTrue(ProjectConfig.knownKeys.contains("testCommand"))
    }
}
