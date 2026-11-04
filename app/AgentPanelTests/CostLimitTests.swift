import XCTest
@testable import AgentPanel

@MainActor
final class CostLimitTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let worktrees = URL(fileURLWithPath: "/repo/.agent-worktrees")
    private let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
    private let agent: AgentStatus = { var a = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .blocked, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "dev-v1"; return a }()
    private var reader: AutopilotModelTests.Reader!
    private var sender: AutopilotModelTests.Sender!
    private var dir: TempDir!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws { reader = AutopilotModelTests.Reader(); sender = AutopilotModelTests.Sender(); dir = try TempDir() }

    private var card: TaskCard {
        TaskCard(id: "V1", project: "d", status: .doing, agent: "dev-v1", branch: "test/v1", kind: nil, files: [], title: "V1", sections: [:], url: dir.url.appendingPathComponent("V1.md"))
    }

    private func make(decider: AutopilotModelTests.Decider, limit: Double?, cost: Double?) throws -> (AutopilotModel, AgentInboxModel) {
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = .on; p.dailyLimitUSD = limit
        try store.save(p, for: project.id)
        try "# V1\n## Goal\nPick green.".write(to: card.url, atomically: true, encoding: .utf8)
        reader.screens["w1:p1"] = try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/choice-before.txt"), encoding: .utf8)
        let inbox = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([agent])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let model = AutopilotModel(inbox: inbox, store: store, makeDecider: { _ in decider }, now: { [unowned self] in clock })
        model.costToday = { cost }
        model.setProject(project)
        return (model, inbox)
    }

    private func tick(_ model: AutopilotModel, _ inbox: AgentInboxModel) async {
        await inbox.refresh(agents: [agent], cards: [card], projectWorktrees: worktrees, label: { _ in "Pixel · V1" })
        model.process(inbox.questions, cards: [card])
    }

    private var answer: PMReply { PMReply(decision: PMDecision(verdict: .answer, option: 2, text: nil, why: "Card picks green.", confidence: .high), costUSD: 0.03) }

    func testUnderTheLimitTheQuestionGoesToThePM() async throws {
        let decider = AutopilotModelTests.Decider(.success(answer))
        let (m, inbox) = try make(decider: decider, limit: 5, cost: 4.99)
        await tick(m, inbox)
        for _ in 0..<200 where decider.calls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(decider.calls, 1)
        XCTAssertFalse(m.limitReached)
    }

    func testAtTheLimitTheQuestionGoesToTheUserWithTheReasonAndThePMIsNotCalled() async throws {
        let decider = AutopilotModelTests.Decider(.success(answer))
        let (m, inbox) = try make(decider: decider, limit: 5, cost: 5)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        XCTAssertEqual(m.escalation(for: q), "Daily cost limit of $5.00 reached (today ≈ $5.00); the PM has stopped deciding.")
        XCTAssertEqual(m.forUser(inbox.questions).count, 1)
        XCTAssertEqual(decider.calls, 0)
        XCTAssertTrue(m.limitReached)
        XCTAssertEqual(m.records.last?.result, .escalated)
    }

    func testNoLimitMeansNoCheck() async throws {
        let decider = AutopilotModelTests.Decider(.success(answer))
        let (m, inbox) = try make(decider: decider, limit: nil, cost: 1000)
        await tick(m, inbox)
        for _ in 0..<200 where decider.calls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(decider.calls, 1)
        XCTAssertFalse(m.limitReached)
    }

    func testAnUnknownCostIsNotALimit() async throws {
        let decider = AutopilotModelTests.Decider(.success(answer))
        let (m, inbox) = try make(decider: decider, limit: 1, cost: nil)
        await tick(m, inbox)
        for _ in 0..<200 where decider.calls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(decider.calls, 1)
    }

    // MARK: policy

    func testPolicyKeepsTheLimitAndOldFilesHaveNone() throws {
        var p = AutopilotPolicy(); p.dailyLimitUSD = 12.5
        let back = try JSONDecoder().decode(AutopilotPolicy.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.dailyLimitUSD, 12.5)
        XCTAssertNil(try JSONDecoder().decode(AutopilotPolicy.self, from: Data("{\"mode\":\"on\"}".utf8)).dailyLimitUSD)
        XCTAssertNil(try JSONDecoder().decode(AutopilotPolicy.self, from: Data("{\"dailyLimitUSD\":0}".utf8)).dailyLimitUSD)
    }

    // MARK: today's cost

    func testTodayCostIsDoneTasksApprovedTodayPlusPMDecisionsOfOtherCardsToday() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
        func card(_ id: String, _ status: TaskStatus) -> TaskCard {
            TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        }
        func rec(_ card: String, _ time: String, _ cost: Double) -> DecisionRecord {
            DecisionRecord(id: UUID().uuidString, time: ISO8601DateFormatter().date(from: time)!, cardID: card, agent: "a", kind: "choice", question: "q", by: .pm, result: .answered, answer: "", why: "", costUSD: cost)
        }
        let events = ActionLogEvents.parse("2026-10-18T09:00:00Z [p] approved A\n2026-10-17T09:00:00Z [p] approved B\n")
        let costs = ["A": CardCost(agent: 1, pm: 0.5), "B": CardCost(agent: 9, pm: 0)]
        let decisions = [rec("A", "2026-10-18T08:00:00Z", 0.5), rec("C", "2026-10-18T10:00:00Z", 0.25), rec("C", "2026-10-17T10:00:00Z", 3)]
        let today = Stats.todayCost(cards: [card("A", .done), card("B", .done), card("C", .doing)], events: events, costs: costs, decisions: decisions, calendar: utc, now: now)
        XCTAssertEqual(today, 1.75, accuracy: 0.0001)
    }
}
