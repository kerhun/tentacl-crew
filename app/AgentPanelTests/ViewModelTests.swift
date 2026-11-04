import XCTest
@testable import AgentPanel

final class ViewModelTests: XCTestCase {
    /// Text as written by scripts/review-packet.sh.
    private let realPacket = """
    Build: passed (`xcodebuild -scheme Demo build`), log: /data/tasks/A5/build.log

    Screenshots:
    - tasks/A5/shots/final.png
    - tasks/A5/shots/lockscreen.png

    Diff summary:
    ```
     a.txt | 1 +
     1 file changed, 1 insertion(+)
    ```
    """

    func testPacketSectionsParsesRealPacket() {
        let parts = packetSections(from: realPacket)
        XCTAssertEqual(parts.build, "passed (`xcodebuild -scheme Demo build`), log: /data/tasks/A5/build.log")
        XCTAssertEqual(parts.screenshots, ["tasks/A5/shots/final.png", "tasks/A5/shots/lockscreen.png"])
        XCTAssertEqual(parts.diff, " a.txt | 1 +\n 1 file changed, 1 insertion(+)")
    }

    func testPacketSectionsParsesHead() {
        XCTAssertEqual(packetSections(from: "Head: 0123456789abcdef0123456789abcdef01234567\n\nBuild: passed (`x`)").head,
                       "0123456789abcdef0123456789abcdef01234567")
        XCTAssertNil(packetSections(from: realPacket).head, "a packet from before the Head line still parses")
    }

    func testPacketSectionsOfEmptyTextIsEmpty() {
        let parts = packetSections(from: "")
        XCTAssertEqual(parts.build, "")
        XCTAssertEqual(parts.screenshots, [])
        XCTAssertEqual(parts.diff, "")
    }

    func testPacketSectionsOfAnalysisNoteLeavesPartsEmpty() {
        let parts = packetSections(from: "Analysis task: no build or screenshots needed.\nReport: 25 lines in the card.")
        XCTAssertEqual(parts.build, "")
        XCTAssertEqual(parts.screenshots, [])
    }

    func testBuildFailureIsRecognised() {
        XCTAssertTrue(packetSections(from: "Build: passed (`x`), log: y").buildPassed)
        XCTAssertFalse(packetSections(from: "Build: FAILED (`x`)").buildPassed)
        XCTAssertFalse(packetSections(from: "").buildPassed)
        let bare = packetSections(from: "Build: none (this project has no build command)\n\nScreenshots: not used in this project\n")
        XCTAssertTrue(bare.buildAcceptable); XCTAssertTrue(bare.screenshotsAcceptable)
        XCTAssertFalse(packetSections(from: "Build: FAILED (`x`)").buildAcceptable)
        XCTAssertFalse(packetSections(from: "Build: passed (`x`)").screenshotsAcceptable, "screenshots are expected unless the packet says they are not used")
    }

    func testAgentSummaryLineUsesLastTwoPathComponents() {
        let agent = AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .idle,
                                cwd: "/Users/you/Projects/demo/.agent-worktrees/pilot-a5", title: "t")
        XCTAssertEqual(agentSummaryLine(agent), "idle · .agent-worktrees/pilot-a5")
        let short = AgentStatus(paneID: "p", workspaceID: "w", state: .working, cwd: "/x", title: "")
        XCTAssertEqual(agentSummaryLine(short), "working · x")
        let unknown = AgentStatus(paneID: "p", workspaceID: "w", state: .unknown("sleeping"), cwd: "", title: "")
        XCTAssertEqual(agentSummaryLine(unknown), "sleeping")
    }

    func testAgentsPaneTextForEachState() {
        XCTAssertEqual(AgentsPane.text(for: .loading), "Checking agents…")
        XCTAssertEqual(AgentsPane.text(for: .available([])), "No agents are running.")
        XCTAssertEqual(AgentsPane.text(for: .unavailable("terminal is not running: no server")), "terminal is not running: no server")
        XCTAssertNil(AgentsPane.text(for: .available([AgentStatus(paneID: "p", workspaceID: "w", state: .idle, cwd: "", title: "")])))
    }

    func testFilesChangedComesFromTheDiffSummary() {
        XCTAssertEqual(packetSections(from: realPacket).filesChanged, 1)
        let two = packetSections(from: "Diff summary:\n```\n a | 1 +\n b | 1 +\n 2 files changed, 2 insertions(+)\n```")
        XCTAssertEqual(two.filesChanged, 2)
        XCTAssertNil(packetSections(from: "Build: passed (`x`), log: y").filesChanged)
    }

    private func card(packet: String) -> TaskCard {
        TaskCard(id: "A1", project: "p", status: .review, agent: nil, branch: nil, kind: nil, files: [], title: "A1",
                 sections: ["Review packet": packet], url: URL(fileURLWithPath: "/tmp/A1.md"))
    }

    /// The panel shows what the latest packet lists, not every image that ever landed in the folder.
    func testShotsComeFromThePacketNotTheFolder() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1/shots/old.png", "old"); try dir.write("tasks/A1/shots/new.png", "new")
        let packet = "Build: passed (`b`), log: l\n\nScreenshots:\n- tasks/A1/shots/new.png\n- tasks/A1/shots/gone.png\n"
        let items = ShotItem.items(for: card(packet: packet), dataDir: dir.url)
        XCTAssertEqual(items.map(\.name), ["new.png", "gone.png"])
        XCTAssertEqual(items.map(\.exists), [true, false])   // a listed file that is missing shows a placeholder
    }

    func testShotsFallBackToTheFolderWhenThePacketListsNone() throws {
        let dir = try TempDir()
        try dir.write("tasks/A1/shots/a.png", "x")
        let items = ShotItem.items(for: card(packet: ""), dataDir: dir.url)
        XCTAssertEqual(items.map(\.name), ["a.png"])
    }

    func testPacketShotPathsCannotLeaveTheDataFolder() throws {
        let dir = try TempDir()
        let secret = try TempDir(); try secret.write("secret.png", "s")
        let packet = "Screenshots:\n- ../\(secret.url.lastPathComponent)/secret.png\n- /etc/hosts\n"
        let items = ShotItem.items(for: card(packet: packet), dataDir: dir.url)
        XCTAssertEqual(items.map(\.exists), [false, false])
    }

    func testMissingScreenshotFileGivesPlaceholderItem() throws {
        let dir = try TempDir()
        let real = try dir.write("shots/a.png", "png")
        let missing = dir.url.appendingPathComponent("shots/gone.png")
        let items = ShotItem.items(for: [real, missing])
        XCTAssertEqual(items.map(\.exists), [true, false])
        XCTAssertEqual(items.map(\.name), ["a.png", "gone.png"])
    }

    func testBuildLineWithTestsCountsAsPassed() {
        let parts = packetSections(from: "Build: passed, tests passed (`b`, `t`), log: /l\n\nScreenshots: not used in this project")
        XCTAssertTrue(parts.buildPassed)
        XCTAssertTrue(parts.buildAcceptable)
    }
}
