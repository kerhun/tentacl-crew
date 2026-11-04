import XCTest
@testable import AgentPanel

final class ProjectAgentsTests: XCTestCase {
    private func agent(_ cwd: String, pane: String = "w1:p1") -> AgentStatus { AgentStatus(paneID: pane, workspaceID: "w1", state: .working, cwd: cwd, title: "t", sessionID: "s") }

    func testAgentsInTheRepositoryOrItsWorktreesBelongToTheProject() {
        let list = [agent("/code/app", pane: "a"), agent("/code/app/.agent-worktrees/feat-x", pane: "b"), agent("/code/app/sub", pane: "c")]
        XCTAssertEqual(agents(list, belongingToRepo: "/code/app").map(\.paneID), ["a", "b", "c"])
    }

    func testOtherProjectsAndSiblingFoldersWithTheSamePrefixAreLeftOut() {
        let list = [agent("/code/app-evil", pane: "a"), agent("/code/other", pane: "b"), agent("/code/app", pane: "c"), agent("", pane: "d")]
        XCTAssertEqual(agents(list, belongingToRepo: "/code/app").map(\.paneID), ["c"])
    }

    func testSpellingsOfTheSameFolderMatch() {
        XCTAssertEqual(agents([agent("/code/app/")], belongingToRepo: "/code//app/.").count, 1)
    }
}
