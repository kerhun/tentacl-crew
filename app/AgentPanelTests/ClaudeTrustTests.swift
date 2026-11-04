import XCTest
@testable import AgentPanel

final class ClaudeTrustTests: XCTestCase {
    private var dirs: [TempDir] = []   // kept alive for the whole test: the folder is deleted with its TempDir

    private func trust(_ json: String?) throws -> ClaudeTrust {
        let dir = try TempDir()
        dirs.append(dir)
        let url = dir.url.appendingPathComponent("claude.json")
        if let json { try json.write(to: url, atomically: true, encoding: .utf8) }
        return ClaudeTrust(configURL: url)
    }

    func testAFolderWithTheTrustFlagIsTrusted() throws {
        let t = try trust(#"{"projects":{"/code/app":{"hasTrustDialogAccepted":true}}}"#)
        XCTAssertTrue(t.isTrusted("/code/app"))
        XCTAssertTrue(t.isTrusted("/code/app/"))
    }

    func testASubfolderOfATrustedFolderIsTrusted() throws {
        XCTAssertTrue(try trust(#"{"projects":{"/code/app":{"hasTrustDialogAccepted":true}}}"#).isTrusted("/code/app/.agent-worktrees/x"))
    }

    func testUnknownFalseSiblingAndMissingFileAreNotTrusted() throws {
        let t = try trust(#"{"projects":{"/code/app":{"hasTrustDialogAccepted":false},"/code/other":{"hasTrustDialogAccepted":true}}}"#)
        XCTAssertFalse(t.isTrusted("/code/app"))
        XCTAssertFalse(t.isTrusted("/code/app-evil"))
        XCTAssertFalse(t.isTrusted("/code/new"))
        XCTAssertFalse(try trust(nil).isTrusted("/code/app"))
        XCTAssertFalse(try trust("{ broken").isTrusted("/code/app"))
    }
}
