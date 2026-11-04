import XCTest
@testable import AgentPanel

final class CardRepositoryTests: XCTestCase {
    private func card(_ id: String, status: String = "todo") -> String {
        "---\nid: \(id)\nproject: demo\nstatus: \(status)\n---\n# \(id) · Title\n\n## Goal\nDo \(id).\n"
    }

    private func cards(_ results: [CardLoadResult]) -> [TaskCard] {
        results.compactMap { if case .card(let c) = $0 { return c } else { return nil } }
    }

    func testLoadsAllCardsSortedById() throws {
        let dir = try TempDir()
        try dir.write("tasks/B2.md", card("B2")); try dir.write("tasks/A1.md", card("A1")); try dir.write("tasks/A10.md", card("A10"))
        let loaded = cards(CardRepository(dataDir: dir.url).loadAll())
        XCTAssertEqual(loaded.map(\.id), ["A1", "A10", "B2"])
    }

    func testBrokenCardBecomesUnreadableOthersLoad() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1.md", card("A1"))
        try dir.write("tasks/BROKEN.md", "no front matter at all")
        try dir.write("tasks/HALF.md", "---\nid: H\nstatus: doing\n")
        let results = CardRepository(dataDir: dir.url).loadAll()
        XCTAssertEqual(cards(results).map(\.id), ["A1"])
        let unreadable = results.compactMap { r -> String? in if case .unreadable(let url, _) = r { return url.lastPathComponent } else { return nil } }
        XCTAssertEqual(unreadable.sorted(), ["BROKEN.md", "HALF.md"])
    }

    func testMissingDataDirGivesEmpty() throws {
        let dir = try TempDir()
        XCTAssertEqual(CardRepository(dataDir: dir.url.appendingPathComponent("nope")).loadAll(), [])
    }

    func testEmptyTasksDirGivesEmpty() throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        XCTAssertEqual(CardRepository(dataDir: dir.url).loadAll(), [])
    }

    func testOnlyMarkdownFilesAreCards() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1.md", card("A1")); try dir.write("tasks/notes.txt", "x"); try dir.write("tasks/A1/shots/a.png", "png")
        XCTAssertEqual(cards(CardRepository(dataDir: dir.url).loadAll()).map(\.id), ["A1"])
    }

    func testScreenshotsListedSortedPngAndJpg() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1.md", card("A1"))
        try dir.write("tasks/A1/shots/b.png", "x"); try dir.write("tasks/A1/shots/a.jpg", "x"); try dir.write("tasks/A1/shots/c.txt", "x")
        let repo = CardRepository(dataDir: dir.url)
        let a1 = try XCTUnwrap(cards(repo.loadAll()).first)
        XCTAssertEqual(repo.screenshots(for: a1).map(\.lastPathComponent), ["a.jpg", "b.png"])
    }

    func testScreenshotsMissingFolderGivesEmpty() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1.md", card("A1"))
        let repo = CardRepository(dataDir: dir.url)
        XCTAssertEqual(repo.screenshots(for: try XCTUnwrap(cards(repo.loadAll()).first)), [])
    }

    /// The panel is read-only in phase 1: loading and reloading must not change a single byte under the data folder.
    func testLoadingNeverModifiesFiles() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1.md", card("A1")); try dir.write("tasks/BROKEN.md", "oops"); try dir.write("tasks/A1/shots/a.png", "png")
        func snapshot() -> [String: String] {
            var result: [String: String] = [:]
            let e = FileManager.default.enumerator(at: dir.url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])!
            for case let url as URL in e {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                result[url.path] = "\((try? Data(contentsOf: url))?.hashValue ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
            return result
        }
        let before = snapshot()
        let repo = CardRepository(dataDir: dir.url)
        _ = repo.loadAll(); _ = repo.loadAll()
        _ = repo.screenshots(for: try XCTUnwrap(cards(repo.loadAll()).first))
        XCTAssertEqual(snapshot(), before)
    }

    func testCardWithoutTrailingNewlineParses() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1.md", "---\nid: A1\nstatus: done\n---\n# A1")
        XCTAssertEqual(cards(CardRepository(dataDir: dir.url).loadAll()).map(\.status), [.done])
    }
}
