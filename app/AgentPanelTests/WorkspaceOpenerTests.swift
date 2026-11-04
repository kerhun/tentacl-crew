import XCTest
@testable import AgentPanel

final class RecordingOpener: URLOpening, @unchecked Sendable {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

final class WorkspaceOpenerTests: XCTestCase {
    private var dir: TempDir!
    private var repo: URL!
    private var data: URL!
    private var outside: URL!
    private let recorder = RecordingOpener()

    override func setUpWithError() throws {
        dir = try TempDir()
        repo = dir.url.appendingPathComponent("repo")
        data = dir.url.appendingPathComponent("data")
        outside = dir.url.appendingPathComponent("outside")
        let folders: [URL] = [repo.appendingPathComponent("sub"), repo.appendingPathComponent(".agent-worktrees/pilot-a5"), data, outside]
        for d in folders {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    private func opener(xcodeProject: String? = "App.xcodeproj") -> WorkspaceOpener {
        let project = ProjectConfig(id: "demo", name: "Demo", repoPath: repo.path, dataDir: data.path, maxParallel: 4,
                                    buildCommand: "build", xcodeProject: xcodeProject,
                                    simulator: .init(baseDevice: "iPhone 17 Pro"), sharedFiles: [], openWith: "Xcode")
        return WorkspaceOpener(project: project, opener: recorder)
    }

    func testOpensRepoRootAndDataFolder() throws {
        try opener().openFolder(repo)
        try opener().openFolder(data)
        XCTAssertEqual(recorder.opened.map { $0.resolvingSymlinksInPath().path }, [repo.resolvingSymlinksInPath().path, data.resolvingSymlinksInPath().path])
    }

    func testOpensWorktreeInside() throws {
        XCTAssertNoThrow(try opener().openFolder(repo.appendingPathComponent(".agent-worktrees/pilot-a5")))
        XCTAssertEqual(recorder.opened.count, 1)
    }

    func testRejectsDotDotEscape() {
        let escape = repo.appendingPathComponent("../outside")
        XCTAssertThrowsError(try opener().openFolder(escape)) { XCTAssertTrue(($0 as? OpenError).map { if case .notAllowed = $0 { return true } else { return false } } ?? false) }
        XCTAssertEqual(recorder.opened, [])
    }

    func testRejectsOutsideRoot() {
        XCTAssertThrowsError(try opener().openFolder(outside))
        XCTAssertThrowsError(try opener().openFolder(URL(fileURLWithPath: "/etc")))
        XCTAssertEqual(recorder.opened, [])
    }

    func testRejectsSiblingWithSamePrefix() throws {
        let evil = dir.url.appendingPathComponent("repo-evil")
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        XCTAssertThrowsError(try opener().openFolder(evil))
        XCTAssertEqual(recorder.opened, [])
    }

    func testRejectsSymlinkLeavingRoot() throws {
        let link = repo.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try opener().openFolder(link))
        XCTAssertEqual(recorder.opened, [])
    }

    func testAcceptsSymlinkStayingInside() throws {
        let link = repo.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.appendingPathComponent("sub"))
        XCTAssertNoThrow(try opener().openFolder(link))
        XCTAssertEqual(recorder.opened.count, 1)
    }

    func testMissingFolderInsideRootThrowsMissing() {
        XCTAssertThrowsError(try opener().openFolder(repo.appendingPathComponent("nope"))) {
            guard case .missing = $0 as? OpenError else { return XCTFail("expected .missing, got \($0)") }
        }
    }

    func testOpenInXcodeUsesConfiguredProject() throws {
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try opener().openInXcode()
        XCTAssertEqual(recorder.opened.map(\.lastPathComponent), ["App.xcodeproj"])
    }

    func testOpenInXcodeMissingProjectThrows() {
        XCTAssertThrowsError(try opener(xcodeProject: nil).openInXcode())
        XCTAssertThrowsError(try opener(xcodeProject: "Gone.xcodeproj").openInXcode())
        XCTAssertEqual(recorder.opened, [])
    }

    func testXcodeProjectCannotEscapeTheRepo() {
        XCTAssertThrowsError(try opener(xcodeProject: "../outside/Evil.xcodeproj").openInXcode())
        XCTAssertEqual(recorder.opened, [])
    }
}
