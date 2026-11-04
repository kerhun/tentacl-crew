import XCTest
@testable import AgentPanel

final class TeamChartTests: XCTestCase {
    private func chart(_ pairs: [(String, String?)]) -> TeamChart { TeamChart(members: pairs.map { TeamMember(role: $0.0, reportsTo: $0.1) }) }

    /// user -> pm -> reviewer -> dev, ui_dev
    private var standard: TeamChart { chart([("pm", nil), ("reviewer", "pm"), ("dev", "reviewer"), ("ui_dev", "reviewer")]) }

    func testCanAssignRules() {
        let c = standard
        for from: String? in [nil, "user"] { for to in ["pm", "reviewer", "dev", "ghost"] { XCTAssertTrue(c.canAssign(from: from, to: to), "\(from ?? "nil") -> \(to)") } }
        XCTAssertTrue(c.canAssign(from: "pm", to: "reviewer"))
        XCTAssertTrue(c.canAssign(from: "pm", to: "dev"), "a grandchild is below too")
        XCTAssertTrue(c.canAssign(from: "reviewer", to: "ui_dev"))
        XCTAssertFalse(c.canAssign(from: "dev", to: "pm"), "never upwards")
        XCTAssertFalse(c.canAssign(from: "dev", to: "ui_dev"), "peers cannot give each other tasks")
        XCTAssertFalse(c.canAssign(from: "dev", to: "dev"), "nobody gives a task to itself")
        XCTAssertFalse(c.canAssign(from: "reviewer", to: "pm"))
        XCTAssertFalse(c.canAssign(from: "pm", to: "ghost"), "a role that is not in the chart reports to the user: only the user may assign it")
        XCTAssertFalse(c.canAssign(from: "ghost", to: "dev"), "a giver that is not in the chart cannot be verified")
    }

    func testDevAbovePmMakesPmReportToDev() {
        let c = chart([("dev", nil), ("pm", "dev")])
        XCTAssertTrue(c.canAssign(from: "dev", to: "pm"))
        XCTAssertFalse(c.canAssign(from: "pm", to: "dev"))
    }

    func testAncestorsDescendantsAndManager() {
        let c = standard
        XCTAssertEqual(c.ancestors(of: "dev"), ["reviewer", "pm"])
        XCTAssertEqual(c.ancestors(of: "pm"), [])
        XCTAssertEqual(Set(c.descendants(of: "pm")), ["reviewer", "dev", "ui_dev"])
        XCTAssertEqual(c.descendants(of: "dev"), [])
        XCTAssertEqual(c.manager(of: "dev"), "reviewer")
        XCTAssertNil(c.manager(of: "pm"))
        XCTAssertNil(c.manager(of: "ghost"))
    }

    func testWalkingACyclicChartNeverLoopsForever() {
        let c = chart([("a", "b"), ("b", "a")])
        XCTAssertEqual(Set(c.ancestors(of: "a")), ["b"])
        _ = c.descendants(of: "a")
        XCTAssertFalse(c.canAssign(from: "a", to: "a"))
    }

    func testProblemsFindDuplicateUnknownManagerCycleSelfAndBadNames() {
        XCTAssertEqual(standard.problems, [])
        func messages(_ c: TeamChart) -> String { c.problems.map(\.message).joined(separator: " | ") }
        XCTAssertTrue(messages(chart([("pm", nil), ("pm", nil)])).contains("more than once"))
        XCTAssertTrue(messages(chart([("dev", "ghost")])).contains("ghost"))
        XCTAssertTrue(messages(chart([("a", "b"), ("b", "c"), ("c", "a")])).contains("cycle"))
        XCTAssertTrue(messages(chart([("pm", "pm")])).contains("itself"))
        XCTAssertTrue(messages(chart([("../x", nil)])).contains("../x") == false, "a bad name is reported without being echoed into a path")
        XCTAssertFalse(chart([("Dev", nil)]).problems.isEmpty)
        XCTAssertTrue(chart([("pm", nil), ("dev", "Bad")]).problems.contains { $0.severity == .error })
        XCTAssertTrue(chart([("pm", nil), ("a", "b"), ("b", "a")]).problems.allSatisfy { $0.severity == .error })
    }

    func testDefaultChartUsesOnlyResolvableRoles() {
        let all = TeamChart.defaultChart(resolvable: ["pm", "dev", "reviewer", "ui_dev", "analyst", "other"])
        XCTAssertEqual(all, standard)
        XCTAssertEqual(TeamChart.defaultChart(resolvable: ["pm", "dev"]), chart([("pm", nil), ("dev", "pm")]))
        XCTAssertEqual(TeamChart.defaultChart(resolvable: ["dev"]), chart([("dev", nil)]))
        XCTAssertEqual(TeamChart.defaultChart(resolvable: ["reviewer", "dev"]), chart([("reviewer", nil), ("dev", "reviewer")]))
        XCTAssertEqual(TeamChart.defaultChart(resolvable: ["analyst", "other"]), chart([]))
        XCTAssertEqual(TeamChart.defaultChart(resolvable: []), chart([]))
    }

    func testRemovingARoleRewiresItsReportsToItsManager() {
        let c = standard.removing(role: "reviewer")
        XCTAssertEqual(c, chart([("pm", nil), ("dev", "pm"), ("ui_dev", "pm")]))
        XCTAssertEqual(standard.removing(role: "pm"), chart([("reviewer", nil), ("dev", "reviewer"), ("ui_dev", "reviewer")]), "reports of a top role report to the user")
        XCTAssertEqual(standard.removing(role: "ghost"), standard)
        XCTAssertEqual(standard.removing(role: "dev"), chart([("pm", nil), ("reviewer", "pm"), ("ui_dev", "reviewer")]))
    }

    func testCodableKeepsUnknownKeysAndWritesNullForTheTop() throws {
        let json = #"{"version":1,"members":[{"role":"pm","reportsTo":null,"note":"x"},{"role":"dev","reportsTo":"pm"}],"future":{"a":1}}"#
        let decoded = try JSONDecoder().decode(TeamChart.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.members.map(\.role), ["pm", "dev"])
        XCTAssertNil(decoded.members[0].reportsTo)
        XCTAssertEqual(decoded.extra["future"], .object(["a": .number(1)]))
        let out = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertNotNil(out?["future"])
        let first = (out?["members"] as? [[String: Any]])?.first
        XCTAssertTrue(first?["reportsTo"] is NSNull, "the top of the chart is written as an explicit null")
        let again = try JSONDecoder().decode(TeamChart.self, from: try JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
    }
}
