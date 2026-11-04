import XCTest
@testable import AgentPanel

final class RoleSummaryTests: XCTestCase {
    private let chart = TeamChart(members: [TeamMember(role: "pm", reportsTo: nil), TeamMember(role: "reviewer", reportsTo: "pm"),
                                            TeamMember(role: "dev", reportsTo: "reviewer"), TeamMember(role: "ui_dev", reportsTo: "reviewer")])
    private let names = ["reviewer": "UMUT", "dev": "EGE"]

    private func draft(_ edit: (inout RoleDraft) -> Void = { _ in }) -> RoleDraft {
        var d = RoleDraft()
        d.name = "dev"; d.model = "sonnet"; d.effort = "medium"; d.permissionMode = "acceptEdits"; d.allowedTools = ["Read", "Edit", "Bash(git status:*)"]
        edit(&d)
        return d
    }

    func testTheDesignExampleReadsAsFourSentences() {
        XCTAssertEqual(RoleSummary.lines(draft: draft(), modelLabel: "Sonnet (latest)", chart: chart, names: names), [
            "Runs Claude Code with Sonnet at medium effort.",
            "Edits files in its own worktree without asking.",
            "Asks you before any shell command not on the list.",
            "Reports to UMUT (reviewer); gives tasks to nobody.",
        ])
    }

    func testFollowsTheDraftsToolModelAndEffort() {
        let codex = RoleSummary.lines(draft: draft { $0.tool = "codex"; $0.model = "gpt-5.5"; $0.effort = "high" }, modelLabel: "GPT-5.5", chart: chart, names: names)
        XCTAssertEqual(codex.first, "Runs Codex with GPT-5.5 at high effort.")
        let noModel = RoleSummary.lines(draft: draft { $0.model = "" }, modelLabel: "", chart: chart, names: names)
        XCTAssertEqual(noModel.first, "Runs Claude Code with its default model at medium effort.")
    }

    func testEachPermissionModeSaysWhatItEditsAndWhatItAsks() {
        func lines(_ mode: String, _ tools: [String] = ["Read"], codex: Bool = false) -> [String] {
            Array(RoleSummary.lines(draft: draft { $0.permissionMode = mode; $0.allowedTools = tools; if codex { $0.tool = "codex" } }, modelLabel: "x", chart: nil, names: [:])[1...2])
        }
        XCTAssertEqual(lines("plan"), ["Reads and proposes; never edits files.", "Asks you before it changes anything."])
        XCTAssertEqual(lines("manual"), ["Edits nothing without asking.", "Asks you before every edit and command."])
        XCTAssertEqual(lines("acceptEdits"), ["Edits files in its own worktree without asking.", "Asks you before any shell command."])
        XCTAssertEqual(lines("acceptEdits", ["Read", "Bash"]), ["Edits files in its own worktree without asking.", "Runs shell commands without asking."])
        XCTAssertEqual(lines("auto"), ["Edits and runs commands on its own; a safety check stops risky steps.", "Asks you only when that check flags a step."])
        XCTAssertEqual(lines("dontAsk"), ["Edits and runs only what the allowed list permits.", "Never asks you; anything else is refused."])
        XCTAssertEqual(lines("bypassPermissions"), ["Edits and runs anything without asking.", "Never asks you; only for throwaway sandboxes."])
        XCTAssertEqual(lines("acceptEdits", codex: true), ["Edits files in its own worktree without asking.", "Asks you when it needs more than its sandbox allows."])
    }

    func testReportsToAndGivesTasksFollowTheChart() {
        let reviewer = RoleSummary.lines(draft: draft { $0.name = "reviewer" }, modelLabel: "x", chart: chart, names: names)
        XCTAssertEqual(reviewer.last, "Reports to pm; gives tasks to EGE (dev) and ui_dev.")
        let pm = RoleSummary.lines(draft: draft { $0.name = "pm" }, modelLabel: "x", chart: chart, names: names)
        XCTAssertEqual(pm.last, "Reports to you; gives tasks to UMUT (reviewer), EGE (dev) and ui_dev.")
        let outside = RoleSummary.lines(draft: draft { $0.name = "analyst" }, modelLabel: "x", chart: chart, names: names)
        XCTAssertEqual(outside.last, "Not in the team chart: reports to you; gives tasks to nobody.")
        XCTAssertEqual(RoleSummary.lines(draft: draft(), modelLabel: "x", chart: nil, names: names).last, "Not in the team chart: reports to you; gives tasks to nobody.")
    }

    func testAHeadlessRoleSaysThePanelDoesNotStartIt() {
        let lines = RoleSummary.lines(draft: draft { $0.kind = "headless" }, modelLabel: "x", chart: chart, names: names)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.last, "Runs headless, without a terminal; the panel does not start it.")
    }

    private func agent(_ name: String?) -> AgentStatus {
        var a = AgentStatus(paneID: "w:\(name ?? "x")", workspaceID: "w", state: .working, cwd: "/r", title: "t"); a.name = name; return a
    }

    private func card(_ id: String, _ title: String) -> TaskCard {
        TaskCard(id: id, project: "p", status: .doing, agent: nil, branch: nil, kind: nil, files: [], title: title, sections: [:], url: URL(fileURLWithPath: "/c/\(id).md"))
    }

    func testRunningAgentsAreGroupedByRoleWithTheirCardAndStartTime() {
        let start = Date(timeIntervalSince1970: 1000)
        let running = RoleSummary.running([(agent("dev-n157-p"), card("N157", "TentaclBackend")), (agent("dev-n151-p"), card("N151", "Codex question detector")),
                                           (agent("pm-p"), nil), (agent(nil), nil)],
                                          facts: ["N157": AgentCardFacts(startedAt: start, cost: nil)])
        XCTAssertEqual(running["dev"], [RoleRunningAgent(cardID: "N157", title: "TentaclBackend", startedAt: start),
                                        RoleRunningAgent(cardID: "N151", title: "Codex question detector", startedAt: nil)])
        XCTAssertEqual(running["pm"], [RoleRunningAgent(cardID: nil, title: "pm-p", startedAt: nil)])
        XCTAssertEqual(running.count, 2)
    }

    func testTheSideColumnGoesUnderTheSectionsOnANarrowForm() {
        XCTAssertTrue(RoleSummary.sideBySide(width: 1120))
        XCTAssertTrue(RoleSummary.sideBySide(width: 940))
        XCTAssertFalse(RoleSummary.sideBySide(width: 939))
        XCTAssertFalse(RoleSummary.sideBySide(width: 700))
    }

    func testOldSettingsOnlyWhenTheRoleWasSavedAfterTheAgentStarted() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(RoleSummary.hasOldSettings(startedAt: start, savedAt: start.addingTimeInterval(5)))
        XCTAssertFalse(RoleSummary.hasOldSettings(startedAt: start, savedAt: start.addingTimeInterval(-5)))
        XCTAssertFalse(RoleSummary.hasOldSettings(startedAt: nil, savedAt: start))
        XCTAssertFalse(RoleSummary.hasOldSettings(startedAt: start, savedAt: nil))
    }
}
