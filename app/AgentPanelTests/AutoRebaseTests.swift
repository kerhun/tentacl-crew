import XCTest
@testable import AgentPanel

private struct IdleReader: TerminalReading { func screen(of target: String, lines: Int) async throws -> String { "" } }
private struct IdleSender: TerminalKeySending, TerminalCommanding {
    func sendKeys(target: String, keys: [String]) async throws {}
    func prompt(target: String, text: String) async throws {}
}
private struct NoDecider: PMDeciding {
    func decide(_ request: DecisionRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
    func decide(_ request: FixRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
}

@MainActor
final class AutoRebaseTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)

    private final class Panel: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        var behind: Int? = 2
        var finished = true
        var rebase: AutoRebaseResult = .conflict(["A.swift"])  // the older tests are about the agent being asked
        var rebased: [String] = []
        var notes: [String] { lock.withLock { sent } }
        func rebaseNow(_ c: TaskCard) async -> AutoRebaseResult { lock.withLock { rebased.append(c.id) }; return rebase }
        func fix(_ c: TaskCard, _ n: String) async -> String? { lock.withLock { sent.append(n) }; return nil }
    }

    private func card(_ status: TaskStatus = .review, kind: String? = nil, packet: Bool = false) -> TaskCard {
        TaskCard(id: "V1", project: "d", status: status, agent: "dev-v1", branch: "test/v1", kind: kind, files: [], title: "V1", sections: packet ? ["Review packet": "Head: 0123456789abcdef0123456789abcdef01234567"] : [:],
                 url: dir.url.appendingPathComponent("V1.md"))
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func make(_ panel: Panel, mode: AutopilotMode, config: ProjectConfig? = nil) throws -> AutopilotModel {
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = mode
        try store.save(p, for: project.id)
        let inbox = AgentInboxModel(reader: IdleReader(), keys: IdleSender(), commander: IdleSender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store, makeDecider: { _ in NoDecider() }, now: { [unowned self] in clock })
        m.setProject(config ?? project)
        m.isFinished = { _ in panel.finished }
        m.behindMain = { _ in panel.behind }
        m.requestFix = { await panel.fix($0, $1) }
        m.rebaseNow = { await panel.rebaseNow($0) }
        return m
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func pass(_ m: AutopilotModel, _ c: TaskCard) async throws {
        clock.addTimeInterval(60)
        m.process([], cards: [c])
        try await Task.sleep(for: .milliseconds(60))
    }

    func testABehindCardInReviewGetsOneRebaseRequestInOnMode() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        XCTAssertEqual(panel.notes.count, 1)
        for t in ["Rebase", "main", "conflicts", "both test suites", "Report"] { XCTAssertTrue(panel.notes[0].contains(t), t) }
        XCTAssertEqual(m.fixesForYou, [])
        await settle { m.records.last?.kind == AutopilotModel.rebaseKind }
        XCTAssertEqual(m.records.last?.result, .answered)
    }

    /// N15 (an analysis card) was asked to rebase and moved to needs-fix, although it is never merged.
    func testAnAnalysisCardIsNeverAskedToRebase() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        try await pass(m, card(kind: "analysis"))
        try await pass(m, card(.doing, kind: "analysis"))
        XCTAssertEqual(panel.notes, [])
        XCTAssertEqual(m.fixesForYou, [])
    }

    func testAFinishedDoingCardIsAskedToo() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        m.process([], cards: [card(.doing)])
        await settle { !panel.notes.isEmpty }
        XCTAssertEqual(panel.notes.count, 1)
    }

    func testShadowShowsASuggestionAndSendsNothing() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .shadow)
        m.process([], cards: [card()])
        await settle { !m.fixesForYou.isEmpty }
        XCTAssertEqual(panel.notes, [])
        XCTAssertEqual(m.fixesForYou.count, 1)
        XCTAssertEqual(m.fixesForYou.first?.headline, PendingFix.behindMain)
        // The user accepts it: that sends the rebase request, not a stored fix note.
        await m.sendSuggestedFix(cardID: "V1")
        XCTAssertEqual(panel.notes.count, 1)
        XCTAssertTrue(panel.notes[0].contains("Rebase"))
        XCTAssertEqual(m.fixesForYou, [])
    }

    func testUpToDateOrWorkingOrOffGetsNothing() async throws {
        let panel = Panel()
        let on = try make(panel, mode: .on)
        panel.behind = nil
        on.process([], cards: [card()])
        try await Task.sleep(for: .milliseconds(60))
        panel.behind = 2
        panel.finished = false
        on.process([], cards: [card(.doing)])
        on.process([], cards: [card(.needsFix)])
        on.process([], cards: [card(.todo)])
        let off = try make(panel, mode: .off)
        panel.finished = true
        off.process([], cards: [card()])
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(panel.notes, [])
    }

    func testNoSecondRequestForTheSameMainCommit() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { panel.notes.count == 1 }
        try await pass(m, card(.needsFix))
        try await pass(m, card())
        try await pass(m, card())
        XCTAssertEqual(panel.notes.count, 1)
        // Main moves on again: one more request.
        panel.behind = 5
        try await pass(m, card())
        await settle { panel.notes.count == 2 }
        XCTAssertEqual(panel.notes.count, 2)
    }

    /// N53 #6: the agent rebased (branch up to date), then main moved on by the same number of commits.
    func testTheSameBehindCountAfterANewMainCommitAsksAgain() async throws {
        let panel = Panel()
        panel.behind = 1
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { panel.notes.count == 1 }
        try await pass(m, card())
        XCTAssertEqual(panel.notes.count, 1, "same main state: no second request")
        panel.behind = 0
        try await pass(m, card())
        panel.behind = 1
        try await pass(m, card())
        await settle { panel.notes.count == 2 }
        XCTAssertEqual(panel.notes.count, 2)
    }

    /// N66: Approve rebases a card in review with a packet itself, so the autopilot neither asks nor suggests.
    func testNoRebaseRequestOrSuggestionForACardInReviewWithAPacket() async throws {
        let withPacket = card(packet: true)
        for mode in [AutopilotMode.on, .shadow] {
            let panel = Panel()
            let m = try make(panel, mode: mode)
            try await pass(m, withPacket)
            try await pass(m, withPacket)
            XCTAssertEqual(panel.notes, [], "\(mode)")
            XCTAssertEqual(m.fixesForYou, [], "\(mode)")
        }
        // Finished but not yet in review: still asked.
        let panel = Panel()
        let m = try make(panel, mode: .on)
        m.process([], cards: [card(.doing)])
        await settle { !panel.notes.isEmpty }
        XCTAssertEqual(panel.notes.count, 1)
    }

    /// N47 L5: the request names the project's main branch.
    func testTheRequestNamesTheProjectsMainBranch() async throws {
        var other = project
        other.mainBranch = "develop"
        let panel = Panel()
        let m = try make(panel, mode: .on, config: other)
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        XCTAssertTrue(panel.notes[0].contains("behind develop"), panel.notes[0])
        XCTAssertFalse(panel.notes[0].contains("main"), panel.notes[0])
    }
}
