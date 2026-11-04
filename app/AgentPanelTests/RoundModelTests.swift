import XCTest
import AppKit
@testable import AgentPanel

@MainActor
final class RoundModelTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus = .todo, deps: String? = nil, files: [String]? = nil, priority: CardPriority = .normal) -> TaskCard {
        var sections = ["Goal": "Goal of \(id)."]
        if let deps { sections["Dependencies"] = deps }
        var c = TaskCard(id: id, project: "d", status: status, agent: nil, branch: nil, kind: nil, files: files ?? ["App/\(id).swift"], title: "Title \(id)",
                         sections: sections, url: URL(fileURLWithPath: "/tmp/\(id).md"))
        c.priority = priority
        return c
    }

    private func plan(_ c: TaskCard) -> StartPlan {
        StartPlan(card: c, agentName: "dev-\(c.id.lowercased())", branch: "task/\(c.id.lowercased())", rolePath: "/roles/dev.json",
                  worktreePath: "/wt/\(c.id)", commandPreview: "spawn-agent.sh", roleName: "dev")
    }

    private func pick(_ ids: String...) -> RoundReply {
        RoundReply(proposal: RoundProposal(cards: ids.map { RoundPick(id: $0, why: "Why \($0).") }), costUSD: 0.02)
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var s: [String] = []
        var started: [String] { lock.withLock { s } }
        func add(_ id: String) { lock.withLock { s.append(id) } }
    }

    private struct Rig {
        let model: RoundModel
        let calls: Calls
        let recorded: () -> [RoundOutcome]
        let request: () -> RoundRequest?
    }

    private func rig(cards: [TaskCard], maxParallel: Int = 3, reply: Result<RoundReply, Error>, enabled: Bool = true,
                     conflict: @escaping (TaskCard, TaskCard) -> String? = { _, _ in nil },
                     deniedAuthority: Set<String> = [], planFails: Set<String> = [], failStart: Set<String> = [], defaults: UserDefaults? = nil) -> Rig {
        let calls = Calls()
        let recorded = Box<[RoundOutcome]>([])
        let request = Box<RoundRequest?>(nil)
        let model = RoundModel(
            enabled: { enabled }, cards: { cards }, maxParallel: { maxParallel }, projectName: { "Demo" },
            propose: { r in request.value = r; return try reply.get() },
            planStart: { c in planFails.contains(c.id) ? .failure(.invalid("no role called \"dev\"")) : .success({ var p = self.plan(c); if deniedAuthority.contains(c.id) { p.authority = .denied("test card") }; return p }()) },
            conflict: { a, b in conflict(a, b) },
            start: { p in calls.add(p.card.id); return failStart.contains(p.card.id) ? "The agent could not be started: boom" : nil },
            record: { recorded.value.append($0) }, projectID: { "demo" }, defaults: defaults)
        return Rig(model: model, calls: calls, recorded: { recorded.value }, request: { request.value })
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private func ready(_ r: Rig) throws -> RoundModel.Round {
        guard case .ready(let round) = r.model.state else { XCTFail("expected a ready round, got \(r.model.state)"); throw CancellationError() }
        return round
    }

    func testStartingARoundTellsTheOwnerOnlyWhenACardStarted() async throws {
        let r = rig(cards: [card("A"), card("B")], reply: .success(pick("A")), failStart: ["A"])
        var count = 0
        r.model.onRoundStarted = { count += 1 }
        await r.model.plan()
        await r.model.start()
        XCTAssertEqual(count, 0, "nothing started")
        let ok = rig(cards: [card("A")], reply: .success(pick("A")))
        ok.model.onRoundStarted = { count += 1 }
        await ok.model.plan()
        await ok.model.start()
        XCTAssertEqual(count, 1)
    }

    func testAValidProposalBecomesARoundWithPlansAndReasons() async throws {
        let r = rig(cards: [card("A"), card("B"), card("C")], reply: .success(pick("A", "B")))
        await r.model.plan()
        let round = try ready(r)
        XCTAssertEqual(round.items.map(\.card.id), ["A", "B"])
        XCTAssertEqual(round.items.map(\.why), ["Why A.", "Why B."])
        XCTAssertEqual(round.items.map(\.plan.branch), ["task/a", "task/b"])
        XCTAssertTrue(round.items.allSatisfy(\.ticked))
        XCTAssertEqual(round.dropped, [])
        XCTAssertEqual(r.request()?.candidates.map(\.id), ["A", "B", "C"], "the PM sees every todo card")
        XCTAssertEqual(r.request()?.slots, 3)
    }

    func testCardsThePanelCannotAcceptAreDroppedWithAReason() async throws {
        let cards = [card("A"), card("B", files: ["App/A.swift"]), card("D", .done), card("W", .doing), card("X", deps: "- Z9 (first)"),
                     card("N1", .done), card("Z9", .todo), card("P"), card("Q"), card("R")]
        let r = rig(cards: cards, maxParallel: 4, reply: .success(pick("A", "NOPE", "D", "W", "X", "B", "A", "P", "Q", "R")),
                    conflict: { a, b in Set([a.id, b.id]) == ["A", "B"] ? "CONFLICT: App/A.swift" : nil }, planFails: ["P"])
        await r.model.plan()
        let round = try ready(r)
        XCTAssertEqual(round.items.map(\.card.id), ["A", "Q", "R"])
        let why = Dictionary(round.dropped.map { ($0.id + ($0.reason.contains("twice") ? "2" : ""), $0.reason) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(why["NOPE"]?.contains("no such card") == true, "\(why)")
        XCTAssertTrue(why["D"]?.contains("not a todo card") == true)
        XCTAssertTrue(why["W"]?.contains("not a todo card") == true)
        XCTAssertTrue(why["X"]?.contains("Z9") == true, "blocked by the unfinished dependency")
        XCTAssertFalse(why["X"]?.contains("N1") == true, "a done dependency does not block")
        XCTAssertTrue(why["B"]?.contains("App/A.swift") == true, "shares a file with A")
        XCTAssertTrue(why["A2"]?.contains("twice") == true)
        XCTAssertTrue(why["P"]?.contains("no role") == true)
    }

    func testCardsThatCannotStartAreNeverSentToThePM() async throws {
        let r = rig(cards: [card("A"), card("U2"), card("X", deps: "- Z9 (first)"), card("Z9"), card("P")], reply: .success(pick("A", "U2")),
                    deniedAuthority: ["U2"], planFails: ["P"])
        await r.model.plan()
        XCTAssertEqual(r.request()?.candidates.map(\.id), ["A", "Z9"], "only startable cards are asked about")
        let round = try ready(r)
        XCTAssertEqual(round.items.map(\.card.id), ["A"])
        let why = Dictionary(round.dropped.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(why["U2"]?.contains("team chart") == true, "\(why)")
        XCTAssertTrue(why["X"]?.contains("Z9") == true)
        XCTAssertTrue(why["P"]?.contains("no role") == true)
        XCTAssertEqual(round.dropped.filter { $0.id == "U2" }.count, 1, "listed once even when the PM picks it")
    }

    func testWhenNoCardCanStartThePMIsNotCalled() async throws {
        let r = rig(cards: [card("U2"), card("X", deps: "Z9"), card("Z9", .doing)], maxParallel: 5, reply: .success(pick("U2")), deniedAuthority: ["U2"])
        await r.model.plan()
        XCTAssertNil(r.request(), "no PM call")
        guard case .failed(let m) = r.model.state else { return XCTFail("\(r.model.state)") }
        XCTAssertTrue(m.hasPrefix("No todo card can start:"), m)
        XCTAssertTrue(m.contains("U2") && m.contains("team chart"), m)
        XCTAssertTrue(m.contains("X") && m.contains("Z9"), m)
    }

    func testMoreCardsThanFreeSlotsAreDropped() async throws {
        let running = card("RUN", .doing)
        let r = rig(cards: [running, card("A"), card("B"), card("C")], maxParallel: 3, reply: .success(pick("A", "B", "C")))
        await r.model.plan()
        let round = try ready(r)
        XCTAssertEqual(round.items.map(\.card.id), ["A", "B"], "3 allowed, 1 running: 2 free")
        XCTAssertEqual(round.dropped.map(\.id), ["C"])
        XCTAssertTrue(round.dropped[0].reason.contains("limit"))
        XCTAssertEqual(r.request()?.slots, 2)
    }

    func testNoFreeSlotOrNoTodoCardNeverCallsThePM() async throws {
        let full = rig(cards: [card("R1", .doing), card("A")], maxParallel: 1, reply: .success(pick("A")))
        await full.model.plan()
        guard case .failed(let m) = full.model.state else { return XCTFail("\(full.model.state)") }
        XCTAssertTrue(m.contains("limit"))
        XCTAssertNil(full.request())
        let none = rig(cards: [card("D", .done)], reply: .success(pick("D")))
        await none.model.plan()
        guard case .failed(let m2) = none.model.state else { return XCTFail("\(none.model.state)") }
        XCTAssertTrue(m2.contains("No todo"))
        XCTAssertNil(none.request())
    }

    func testAnAutopilotThatIsOffOrAFailingPMGivesNoRound() async throws {
        let off = rig(cards: [card("A")], reply: .success(pick("A")), enabled: false)
        await off.model.plan()
        XCTAssertEqual(off.model.state, .idle)
        let bad = rig(cards: [card("A")], reply: .failure(PMDecisionError.unreadable))
        await bad.model.plan()
        guard case .failed(let m) = bad.model.state else { return XCTFail("\(bad.model.state)") }
        XCTAssertTrue(m.contains("could not be read"))
        let empty = rig(cards: [card("A")], reply: .success(pick()))
        await empty.model.plan()
        guard case .failed = empty.model.state else { return XCTFail("a proposal of no valid card is not a round") }
    }

    func testUntickedCardsAreNotStarted() async throws {
        let r = rig(cards: [card("A"), card("B"), card("C")], reply: .success(pick("A", "B", "C")))
        await r.model.plan()
        r.model.toggle("B")
        XCTAssertEqual(try ready(r).items.map(\.ticked), [true, false, true])
        await r.model.start()
        XCTAssertEqual(r.calls.started, ["A", "C"], "one after another, in the PM's order")
        XCTAssertEqual(r.model.state, .idle)
        XCTAssertEqual(r.recorded().first?.started, ["A", "C"])
        XCTAssertNil(r.recorded().first?.failure)
        XCTAssertEqual(r.recorded().first?.reasons["A"], "Why A.")
    }

    func testAFailedStartStopsTheRestAndNamesTheCard() async throws {
        let r = rig(cards: [card("A"), card("B"), card("C")], reply: .success(pick("A", "B", "C")), failStart: ["B"])
        await r.model.plan()
        await r.model.start()
        XCTAssertEqual(r.calls.started, ["A", "B"], "C is never tried")
        guard case .finished(let round) = r.model.state else { return XCTFail("\(r.model.state)") }
        XCTAssertEqual(round.items.map(\.outcome), [.started, .failed("The agent could not be started: boom"), .pending])
        XCTAssertTrue(round.failureText?.contains("B") == true)
        XCTAssertTrue(round.failureText?.contains("boom") == true)
        XCTAssertTrue(round.failureText?.contains("C") == true, "says what was not started")
        let outcome = try XCTUnwrap(r.recorded().first)
        XCTAssertEqual(outcome.started, ["A"])
        XCTAssertTrue(outcome.failure?.contains("B") == true)
        r.model.close()
        XCTAssertEqual(r.model.state, .idle)
    }

    func testNothingTickedStartsNothing() async throws {
        let r = rig(cards: [card("A")], reply: .success(pick("A")))
        await r.model.plan()
        r.model.toggle("A")
        XCTAssertFalse(r.model.canStart)
        await r.model.start()
        XCTAssertEqual(r.calls.started, [])
        XCTAssertEqual(r.recorded().count, 0)
    }

    func testTheRoundSheetRenders() async throws {
        let r = rig(cards: [card("A"), card("B"), card("C", files: ["App/A.swift"])], reply: .success(pick("A", "B", "C")),
                    conflict: { a, b in Set([a.id, b.id]) == ["A", "C"] ? "CONFLICT: App/A.swift" : nil })
        await r.model.plan()
        r.model.toggle("B")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: RoundSheet(model: r.model, onClose: {}), size: CGSize(width: 600, height: 560)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("round.png")) }
    }

    // MARK: the user's note and card priority

    func testTheNoteAndThePrioritiesReachThePromptAndTheNoteIsKept() async throws {
        let r = rig(cards: [card("A", priority: .high), card("B"), card("C", priority: .low)], reply: .success(pick("A", "B")))
        r.model.begin()
        XCTAssertEqual(r.model.state, .asking)
        r.model.note = "  N21 next  "
        await r.model.plan()
        XCTAssertEqual(r.request()?.note, "N21 next")
        XCTAssertEqual(r.request()?.candidates.map(\.priority), [.high, .normal, .low])
        let text = RoundPrompt.message(for: try XCTUnwrap(r.request()))
        XCTAssertTrue(text.contains("The user says: N21 next"))
        XCTAssertTrue(text.contains("Priority: high") && text.contains("Priority: low") && text.contains("Priority: normal"))
        XCTAssertTrue(RoundPrompt.system.contains("high"))
        r.model.close()
        r.model.begin()
        XCTAssertEqual(r.model.note, "  N21 next  ", "kept until changed")
    }

    func testNoNoteMeansNoUserLineInThePrompt() {
        let request = RoundRequest(projectName: "Demo", slots: 2, candidates: [])
        XCTAssertFalse(RoundPrompt.message(for: request).contains("The user says"))
    }

    func testTheNoteIsStoredInTheRoundAndTheOutcome() async throws {
        let r = rig(cards: [card("A"), card("B")], reply: .success(pick("A", "B")))
        r.model.note = "N21 next"
        await r.model.plan()
        XCTAssertEqual(try ready(r).note, "N21 next")
        await r.model.start()
        XCTAssertEqual(r.recorded().last?.note, "N21 next")
    }

    func testTheDecisionRecordKeepsTheNote() throws {
        let dir = try TempDir()
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = .on
        try store.save(p, for: "demo")
        let inbox = AgentInboxModel(reader: StubReader(), keys: StubSender(), commander: StubSender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store)
        m.setProject(ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil))
        m.recordRound(RoundOutcome(started: ["A"], failure: nil, reasons: ["A": "Why A."], cost: nil, note: "N21 next"))
        XCTAssertTrue(try XCTUnwrap(m.records.last).why.contains("You said: N21 next"))
    }

    // MARK: the PM call and the decision feed

    func testThePromptListsEveryTodoCardsGoalDependenciesAndFiles() {
        let request = RoundRequest(projectName: "Demo", slots: 2, candidates: [
            RoundCandidate(id: "A", title: "Title A", goal: "Make A.", dependencies: "N1 first", unmet: ["N1"], files: ["App/A.swift", "App/B.swift"])])
        let text = RoundPrompt.message(for: request)
        for part in ["Demo", "A · Title A", "Make A.", "N1 first", "not done: N1", "App/A.swift", "App/B.swift", "2"] { XCTAssertTrue(text.contains(part), part) }
    }

    func testTheRoundCallUsesTheSameSafetyFlagsAsTheQuestionCall() {
        let d = ClaudePMDecider(model: "sonnet", budgetUSD: 0.5, timeout: 60)
        let args = d.arguments(for: RoundRequest(projectName: "Demo", slots: 2, candidates: []))
        for flag in ["--tools", "--no-session-persistence", "--setting-sources", "--strict-mcp-config", "--max-budget-usd"] { XCTAssertTrue(args.contains(flag), flag) }
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(args[args.firstIndex(of: "--json-schema")! + 1], RoundPrompt.schema)
    }

    func testTheRoundAnswerIsRead() throws {
        let json = #"{"is_error":false,"total_cost_usd":0.04,"structured_output":{"cards":[{"id":"A","why":"first"},{"id":"B","why":"second"}]}}"#
        let reply = try RoundPrompt.parse(Data(json.utf8))
        XCTAssertEqual(reply.proposal.cards, [RoundPick(id: "A", why: "first"), RoundPick(id: "B", why: "second")])
        XCTAssertEqual(reply.costUSD, 0.04)
        XCTAssertThrowsError(try RoundPrompt.parse(Data("{}".utf8)))
    }

    func testARoundIsOneRoundDecisionInTheFeed() throws {
        let dir = try TempDir()
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = .on
        try store.save(p, for: "demo")
        let inbox = AgentInboxModel(reader: StubReader(), keys: StubSender(), commander: StubSender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store)
        m.setProject(ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil))
        m.recordRound(RoundOutcome(started: ["A", "B"], failure: nil, reasons: ["A": "Why A.", "B": "Why B."], cost: 0.02))
        let r = try XCTUnwrap(m.records.last)
        XCTAssertEqual(r.kind, "round")
        XCTAssertEqual(r.cardID, "A, B")
        XCTAssertEqual(r.result, .answered)
        XCTAssertEqual(r.by, .you)
        XCTAssertEqual(DecisionFeed.summary(r), "round started: A, B")
        m.recordRound(RoundOutcome(started: [], failure: "B failed: boom", reasons: [:], cost: nil))
        XCTAssertEqual(m.records.last?.result, .escalated)
        XCTAssertEqual(DecisionFeed.summary(m.records.last!), "round stopped: B failed: boom")
    }

    func testAStartTheUserAskedForIsADecisionOfKindStart() throws {
        let dir = try TempDir()
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        let inbox = AgentInboxModel(reader: StubReader(), keys: StubSender(), commander: StubSender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store)
        m.setProject(ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil))
        func outcome(_ result: StartRequestOutcome.Result, started: [String] = [], refused: [RoundModel.Dropped] = []) -> StartRequestOutcome {
            StartRequestOutcome(requestID: "r", words: "start A and B", requested: ["A", "B"], result: result, started: started, refused: refused, failure: nil, message: "")
        }
        m.recordStart(outcome(.started, started: ["A", "B"]))
        var r = try XCTUnwrap(m.records.last)
        XCTAssertEqual(r.kind, "start")
        XCTAssertEqual(r.cardID, "A, B")
        XCTAssertEqual(r.result, .answered)
        XCTAssertEqual(r.by, .pm)
        XCTAssertEqual(DecisionFeed.summary(r), "started A, B as you asked")
        m.recordStart(outcome(.refused, refused: [RoundModel.Dropped(id: "B", reason: "blocked")]))
        r = try XCTUnwrap(m.records.last)
        XCTAssertEqual(r.result, .escalated)
        XCTAssertTrue(r.why.contains("B: blocked"))
        m.recordStart(outcome(.sheet))
        XCTAssertEqual(m.records.last?.result, .suggested)
    }

    private final class StubReader: TerminalReading, @unchecked Sendable { func screen(of target: String, lines: Int) async throws -> String { "" } }
    private final class StubSender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        func sendKeys(target: String, keys: [String]) async throws {}
        func prompt(target: String, text: String) async throws {}
    }
}

// MARK: Approve plan & start round (N167)

extension RoundModelTests {
    private func planFile(_ rounds: [PlanRound]) -> PlanLoad { .plan(PlanFile(rounds: rounds, questions: [])) }
    private func freshDefaults() -> UserDefaults {
        makeTestDefaults(prefix: "RoundModelTests")
    }

    func testTheWaitingRoundIsTheFirstOneMarkedWaitingWhoseCardsHaveNotStarted() {
        let r1 = PlanRound(name: "1", cards: ["A"], reason: "", status: "done")
        let r2 = PlanRound(name: "2", cards: ["B", "C"], reason: "", status: "Waiting")
        let r3 = PlanRound(name: "3", cards: ["D"], reason: "", status: "waiting")
        let plan = PlanFile(rounds: [r1, r2, r3], questions: [])
        XCTAssertEqual(RoundModel.waitingRound(in: plan, cards: [card("B"), card("C")]), r2)
        XCTAssertEqual(RoundModel.waitingRound(in: plan, cards: [card("B", .doing), card("C")]), r3, "a round already under way is no longer waiting")
        XCTAssertNil(RoundModel.waitingRound(in: PlanFile(rounds: [r1], questions: []), cards: []))
    }

    func testApproveOpensTheRoundSheetWithTheRoundsCardsTickedAndStartsNothing() async throws {
        let r = rig(cards: [card("A"), card("B"), card("C")], reply: .success(pick()))
        r.model.notePlan(planFile([PlanRound(name: "1", cards: ["A", "B"], reason: "First steps.", status: "waiting")]), project: "demo")
        let round = try XCTUnwrap(r.model.waitingPlanRound)
        let result = await r.model.approvePlan(round)
        XCTAssertEqual(result?.sheet, true)
        let ready = try ready(r)
        XCTAssertEqual(ready.items.map(\.card.id), ["A", "B"])
        XCTAssertTrue(ready.items.allSatisfy(\.ticked))
        XCTAssertTrue(ready.items[0].why.contains("Round 1 of the PM's plan"), ready.items[0].why)
        XCTAssertEqual(r.calls.started, [], "nothing starts before Start round")
        await r.model.start()
        XCTAssertEqual(r.calls.started, ["A", "B"])
    }

    func testApproveKeepsTheUsualChecks() async throws {
        let cards = [card("RUN", .doing), card("A"), card("B", files: ["App/A.swift"]), card("X", deps: "- Z9"), card("Z9")]
        let r = rig(cards: cards, maxParallel: 3, reply: .success(pick()), conflict: { a, b in Set([a.id, b.id]) == ["A", "B"] ? "CONFLICT: App/A.swift" : nil })
        r.model.notePlan(planFile([PlanRound(name: "1", cards: ["A", "B", "X", "Z9"], reason: "", status: "waiting")]), project: "demo")
        _ = await r.model.approvePlan(try XCTUnwrap(r.model.waitingPlanRound))
        let round = try ready(r)
        XCTAssertEqual(round.items.map(\.card.id), ["A", "Z9"], "1 running of 3: two slots")
        let why = Dictionary(round.dropped.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(why["B"]?.contains("App/A.swift") == true, "\(why)")
        XCTAssertTrue(why["X"]?.contains("Z9") == true, "\(why)")
    }

    func testApproveWhenNothingCanStartSaysWhyAndOpensNoSheet() async throws {
        let r = rig(cards: [card("A", deps: "- Z9"), card("Z9", .doing)], reply: .success(pick()))
        r.model.notePlan(planFile([PlanRound(name: "1", cards: ["A"], reason: "", status: "waiting")]), project: "demo")
        _ = await r.model.approvePlan(try XCTUnwrap(r.model.waitingPlanRound))
        XCTAssertEqual(r.model.state, .idle)
        XCTAssertTrue(r.model.approveMessage?.contains("Z9") == true, r.model.approveMessage ?? "nil")
    }

    func testApproveIsDisabledWithTheReasonWhenGitOrAToolIsMissing() {
        var codexCard = card("B"); codexCard.roles = ["coder"]
        let cards = [card("A"), codexCard]
        let round = PlanRound(name: "1", cards: ["A", "B"], reason: "", status: "waiting")
        let toolOf: (String) -> AgentTool = { $0 == "coder" ? .codex : .claude }
        let codexMissing = [SetupItem(id: .codex, title: "codex installed", state: .missing, detail: "The codex command (OpenAI Codex CLI) is not installed. A role uses it.")]
        XCTAssertEqual(RoundModel.approveBlocker(round, cards: cards, startReason: "Initialize git first", setup: [], toolOf: toolOf), "Initialize git first")
        XCTAssertEqual(RoundModel.approveBlocker(round, cards: cards, startReason: nil, setup: codexMissing, toolOf: toolOf),
                       "B needs Codex: The codex command (OpenAI Codex CLI) is not installed. A role uses it. See Setup.")
        XCTAssertNil(RoundModel.approveBlocker(round, cards: [card("A")], startReason: nil, setup: codexMissing, toolOf: toolOf), "no card of the round uses Codex")
        let notSignedIn = [SetupItem(id: .claudeSignIn, title: "Claude Code signed in", state: .missing, detail: "No Claude Code login found.")]
        XCTAssertEqual(RoundModel.approveBlocker(round, cards: cards, startReason: nil, setup: notSignedIn, toolOf: toolOf), "A needs Claude Code: No Claude Code login found. See Setup.")
        let unsure = [SetupItem(id: .codex, title: "codex installed", state: .unsure, detail: "?")]
        XCTAssertNil(RoundModel.approveBlocker(round, cards: cards, startReason: nil, setup: unsure, toolOf: toolOf), "only a missing tool blocks")
        XCTAssertEqual(RoundModel.approveBlocker(PlanRound(name: "1", cards: [], reason: "", status: "waiting"), cards: cards, startReason: nil, setup: [], toolOf: toolOf),
                       "Round 1 lists no cards.")
    }

    func testTheFirstRoundNeedsTheUsersClickEvenWhenAStartNeedsNoSheet() async throws {
        let defaults = freshDefaults()
        let r = rig(cards: [card("A"), card("B")], reply: .success(pick()), defaults: defaults)
        let first = await r.model.fulfil(ids: ["A"], words: "go", startNow: true)
        XCTAssertEqual(first?.sheet, true)
        XCTAssertEqual(first?.firstRound, true)
        XCTAssertEqual(r.calls.started, [], "the authority does not start the first round")
        await r.model.start()
        XCTAssertEqual(r.calls.started, ["A"])
        let second = await r.model.fulfil(ids: ["B"], words: "go", startNow: true)
        XCTAssertEqual(second?.started, ["B"], "after the user's first round the usual rules apply")
        XCTAssertEqual(second?.firstRound, false)
    }

    func testAProjectThatAlreadyStartedCardsHasHadItsFirstRound() async throws {
        let r = rig(cards: [card("D", .done), card("A")], reply: .success(pick()), defaults: freshDefaults())
        let result = await r.model.fulfil(ids: ["A"], words: "go", startNow: true)
        XCTAssertEqual(result?.started, ["A"])
        let setupOnly = TaskCard(id: "G1", project: "d", status: .done, agent: nil, branch: nil, kind: "setup", files: [], title: "GitHub", sections: [:], url: URL(fileURLWithPath: "/tmp/G1.md"))
        let s = rig(cards: [setupOnly, card("A")], reply: .success(pick()), defaults: freshDefaults())
        let held = await s.model.fulfil(ids: ["A"], words: "go", startNow: true)
        XCTAssertEqual(held?.sheet, true, "a finished setup card (G1) is not a round")
    }

    func testNotNowHidesTheRoundFromWaitingForYouUntilAnotherRoundWaits() {
        let defaults = freshDefaults()
        let r = rig(cards: [card("A"), card("B")], reply: .success(pick()), defaults: defaults)
        let one = PlanRound(name: "1", cards: ["A"], reason: "", status: "waiting")
        r.model.notePlan(planFile([one]), project: "demo")
        XCTAssertEqual(r.model.waitingForYouPlanRound, one)
        r.model.notNow(one)
        XCTAssertNil(r.model.waitingForYouPlanRound)
        XCTAssertEqual(r.model.waitingPlanRound, one, "the Plan screen still offers it")
        let again = rig(cards: [card("A"), card("B")], reply: .success(pick()), defaults: defaults)
        again.model.notePlan(planFile([one]), project: "demo")
        XCTAssertNil(again.model.waitingForYouPlanRound, "kept across launches")
        let two = PlanRound(name: "2", cards: ["B"], reason: "", status: "waiting")
        again.model.notePlan(planFile([PlanRound(name: "1", cards: ["A"], reason: "", status: "done"), two]), project: "demo")
        XCTAssertEqual(again.model.waitingForYouPlanRound, two)
    }

    func testAWaitingPlanRoundIsListedInWaitingForYou() {
        let items = dashboardWaitingItems(questions: ["q"], fixes: [], cards: [], roundWaiting: [], approveRound: 0, planRound: "1")
        XCTAssertEqual(items.map(\.id), ["question|q", "plan-round"])
        XCTAssertEqual(waitingDecisionCount(items), 2)
    }

    func testThePlanRoundRowRenders() throws {
        let round = PlanRound(name: "1", cards: ["A", "B"], reason: "First steps.", status: "waiting")
        let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"]
        for (name, blocker) in [("plan-approve-row.png", nil), ("plan-approve-row-disabled.png", "B needs Codex: The codex command (OpenAI Codex CLI) is not installed. See Setup.")] {
            let view = PlanRoundApproval(round: round, blocker: blocker, message: nil, onApprove: {}, onEdit: {}, onNotNow: {}).padding(12).background(Tok.bg)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 520, height: 150)))
            XCTAssertGreaterThan(data.count, 1_000)
            if let dir { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        }
    }
}
