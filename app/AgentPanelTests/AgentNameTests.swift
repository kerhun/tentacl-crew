import XCTest
@testable import AgentPanel

final class AgentNameTests: XCTestCase {
    func testTheNameHasTheRoleTheTaskAndAShortProjectTag() {
        XCTAssertEqual(TaskInput.agentName(role: "dev", task: "T1", projectID: "tentacle-sandbox"), "dev-t1-tentacle-san")
        XCTAssertEqual(TaskInput.agentName(role: "dev", task: "T1", projectID: "orchard"), "dev-t1-orchard")
    }

    func testTwoProjectsGiveTheSameTaskDifferentNames() {
        XCTAssertNotEqual(TaskInput.agentName(role: "dev", task: "T1", projectID: "orchard"), TaskInput.agentName(role: "dev", task: "T1", projectID: "pet-diary"))
    }

    func testTheTagNeverEndsWithADashAndTheRoleStaysFirst() {
        let n = TaskInput.agentName(role: "ui_dev", task: "X9", projectID: "abcdefghijk-lmn")
        XCTAssertEqual(n, "ui_dev-x9-abcdefghijk")
        XCTAssertTrue(n.hasPrefix("ui_dev-"))
    }

    func testTheLongestPossibleNameIsStillAValidAgentName() {
        let n = TaskInput.agentName(role: String(repeating: "r", count: 20), task: String(repeating: "t", count: 40), projectID: String(repeating: "p", count: 40))
        XCTAssertTrue(TaskInput.validAgentName(n), n)
        XCTAssertLessThanOrEqual(n.count, 80)
    }

    func testOldShortNamesStayValidAndHostileOnesAreNot() {
        XCTAssertTrue(TaskInput.validAgentName("dev-t1"))
        for bad in ["", "-x", "a b", "a/b", "a;b", String(repeating: "a", count: 81)] { XCTAssertFalse(TaskInput.validAgentName(bad), bad) }
    }
}
