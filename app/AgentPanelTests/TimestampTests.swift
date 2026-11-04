import XCTest
@testable import AgentPanel

final class TimestampTests: XCTestCase {
    func testTheRepositoryReadsTheCardFilesModificationTime() throws {
        let dir = try TempDir()
        let url = try dir.write("data/tasks/A1.md", "---\nid: A1\nstatus: todo\n---\n# A1\n")
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        guard case .card(let card) = CardRepository(dataDir: dir.url.appendingPathComponent("data")).loadAll().first else { return XCTFail("a card") }
        XCTAssertEqual(try XCTUnwrap(card.modified).timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
    }

    func testACardBuiltByHandHasNoTimestamp() {
        XCTAssertNil(TaskCard(id: "A1", project: "d", status: .todo, agent: nil, branch: nil, kind: nil, files: [], title: "A1", sections: [:], url: URL(fileURLWithPath: "/tmp/A1.md")).modified)
    }
}
