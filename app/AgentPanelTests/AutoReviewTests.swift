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
final class AutoReviewTests: XCTestCase {
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
    private let failure = "EVIDENCE MISSING: build failed, see /tmp/log\n** TEST FAILED **\nXCTAssertEqual failed: (\"1\") is not equal to (\"0\")"

    /// Records what the model asked the panel to do.
    private final class Panel: @unchecked Sendable {
        private let lock = NSLock()
        private var packed: [String] = [], fixes: [String] = []
        var outcome: PacketOutcome = .ready
        /// Outcomes handed out first, one per run; `outcome` once they are used up.
        var queue: [PacketOutcome] = []
        var sendError: String?
        var finished = true
        /// For the tests that build "finished" from `TaskPhase` instead of injecting it.
        var agent: AgentState? = .idle
        var selected = true
        var reportChanged = false
        func phaseFinished(_ c: TaskCard) -> Bool {
            guard selected else { return false }
            return TaskPhase.of(TaskPhaseInput(status: c.status, agent: agent, turnBegun: true, hasReport: !(c.sections["Report"] ?? "").isEmpty,
                                               waiting: 0, quiet: 0, pmHandling: false, reportChangedSinceFix: reportChanged)) == .finished
        }
        func phaseWorking(_ c: TaskCard) -> Bool { selected && agent == .working }
        var packets: [String] { lock.withLock { packed } }
        var notes: [String] { lock.withLock { fixes } }
        func prepare(_ c: TaskCard) async -> PacketOutcome { lock.withLock { packed.append(c.id); return queue.isEmpty ? outcome : queue.removeFirst() } }
        func fix(_ c: TaskCard, _ n: String) async -> String? { lock.withLock { fixes.append(n) }; return sendError }
    }

    private func card(_ status: TaskStatus = .doing, report: String? = "0 failures.", id: String = "V1") -> TaskCard {
        TaskCard(id: id, project: "d", status: status, agent: "dev-v1", branch: "test/v1", kind: nil, files: [], title: "V1",
                 sections: report.map { ["Report": $0] } ?? [:], url: dir.url.appendingPathComponent("\(id).md"))
    }

    private func make(_ panel: Panel, mode: AutopilotMode, configure: (inout AutopilotPolicy) -> Void = { _ in }) throws -> AutopilotModel {
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = mode; configure(&p)
        try store.save(p, for: project.id)
        let inbox = AgentInboxModel(reader: IdleReader(), keys: IdleSender(), commander: IdleSender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store, makeDecider: { _ in NoDecider() })
        m.setProject(project)
        m.isFinished = { _ in panel.finished }
        m.isWorking = { _ in !panel.finished }
        m.preparePacket = { await panel.prepare($0) }
        m.packetRetryDelay = .milliseconds(5)
        m.packetLockPollDelay = .milliseconds(5)
        m.requestFix = { await panel.fix($0, $1) }
        return m
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAFinishedAgentGetsOnePacketPerTurn() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { !panel.packets.isEmpty }
        m.process([], cards: [card()])
        m.process([], cards: [card()])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(panel.packets, ["V1"])
        XCTAssertEqual(m.records.last?.kind, "review")
        // The agent works again, then finishes another turn: one more packet.
        panel.finished = false
        m.process([], cards: [card()])
        panel.finished = true
        m.process([], cards: [card()])
        await settle { panel.packets.count == 2 }
        XCTAssertEqual(panel.packets, ["V1", "V1"])
    }

    func testARunningAgentOrAnEmptyReportIsNeverPacked() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        panel.finished = false
        m.process([], cards: [card()])
        panel.finished = true
        m.process([], cards: [card(report: nil)])
        m.process([], cards: [card(report: "  \n")])
        m.process([], cards: [card(.review)])
        // Absence cannot be waited for: a finished card with a report (the control) is packed after them, and only it was.
        m.process([], cards: [card(id: "V2")])
        await settle { !panel.packets.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(panel.packets, ["V2"])
    }

    func testAFailedPacketSendsAFixToTheAgentInOnMode() async throws {
        let panel = Panel()
        panel.outcome = .failed(failure)
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        XCTAssertEqual(panel.notes.count, 1)
        XCTAssertTrue(panel.notes[0].contains("TEST FAILED"))
        XCTAssertTrue(panel.notes[0].hasPrefix("The review packet could not be prepared"))
        XCTAssertEqual(m.fixesForYou, [])
        await settle { m.records.last?.result == .answered }
        XCTAssertEqual(m.records.last?.kind, "fix")
        XCTAssertEqual(m.records.last?.by, .pm)
    }

    /// Two named failing tests (N214).
    private let twoTests = "EVIDENCE MISSING: tests failed, see /tmp/build.log\n** TEST FAILED **\nfailed  AgentPanelTests.AFlowTests.testOne\nfailed  AgentPanelTests.BFlowTests.testTwo"

    func testTestsThatAllFailOnMainRaiseAWaitingItemAndSendNothing() async throws {
        let panel = Panel()
        panel.outcome = .failed(twoTests)
        let m = try make(panel, mode: .on)
        let asked = Box<[String]>([])
        m.checkOnMain = { _, names in asked.set(names); return .failing(["AFlowTests.testOne", "AgentPanelTests.BFlowTests.testTwo"]) }
        m.process([], cards: [card()])
        await settle { !m.fixesForYou.isEmpty }
        XCTAssertEqual(asked.value, ["AgentPanelTests.AFlowTests.testOne", "AgentPanelTests.BFlowTests.testTwo"])
        XCTAssertEqual(panel.notes, [], "nothing goes to the agent")
        XCTAssertEqual(m.fixesForYou.first?.headline, "Fails on main too")
        XCTAssertTrue(m.fixesForYou.first?.entry.contains("AFlowTests.testOne") == true)
        XCTAssertTrue(m.fixesForYou.first?.entry.contains("Log: /tmp/build.log") == true)
        XCTAssertTrue(m.fixesForYou.first?.isRetryablePacket == true)
        // Retry runs the packet again, and a pass clears the item.
        panel.outcome = .ready
        m.retryPacket(cardID: "V1")
        await settle { panel.packets.count == 2 }
        XCTAssertEqual(m.fixesForYou, [])
    }

    func testOnlyTheTestsThatPassOnMainAreSentAndTheOthersAreNamedAsLeftOut() async throws {
        let panel = Panel()
        panel.outcome = .failed(twoTests)
        let m = try make(panel, mode: .on)
        m.checkOnMain = { _, _ in .failing(["BFlowTests.testTwo"]) }
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        await settle { m.records.last?.result == .answered }
        XCTAssertEqual(panel.notes.count, 1)
        let note = panel.notes[0]
        XCTAssertTrue(note.contains("1 test failed"))
        XCTAssertTrue(note.contains("- AgentPanelTests.AFlowTests.testOne"))
        let left = try XCTUnwrap(note.range(of: "Left out because they fail on main too"))
        XCTAssertTrue(note[left.upperBound...].contains("AgentPanelTests.BFlowTests.testTwo"))
        XCTAssertEqual(m.fixesForYou, [])
        XCTAssertTrue(m.records.last?.why.contains("BFlowTests.testTwo") == true, "the log says what was left out")
    }

    func testTestsThatPassOnMainAreAllSentAsBefore() async throws {
        let panel = Panel()
        panel.outcome = .failed(twoTests)
        let m = try make(panel, mode: .on)
        m.checkOnMain = { _, _ in .failing([]) }
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        XCTAssertTrue(panel.notes[0].contains("2 tests failed"))
        XCTAssertFalse(panel.notes[0].contains("Left out"))
    }

    func testAMainRunThatCannotRunSendsTheNoteAndSaysSoInTheLog() async throws {
        let panel = Panel()
        panel.outcome = .failed(twoTests)
        let m = try make(panel, mode: .on)
        m.checkOnMain = { _, _ in .unavailable(reason: "RUNNER RESTARTED") }
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        await settle { m.records.last?.result == .answered }
        XCTAssertTrue(panel.notes[0].contains("2 tests failed"))
        XCTAssertEqual(m.fixesForYou, [])
        XCTAssertTrue(m.records.last?.why.contains("could not be run on main") == true)
    }

    func testAPacketWithoutNamedTestsIsNeverCheckedOnMain() async throws {
        let panel = Panel()
        panel.outcome = .failed(failure.replacingOccurrences(of: "XCTAssertEqual failed", with: "x"))
        let m = try make(panel, mode: .on)
        let called = Box(false)
        m.checkOnMain = { _, _ in called.set(true); return .failing([]) }
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        XCTAssertFalse(called.value)
    }

    func testAFailedPacketShowsACardInShadowAndSendsNothing() async throws {
        let panel = Panel()
        panel.outcome = .failed(failure)
        let m = try make(panel, mode: .shadow)
        m.process([], cards: [card()])
        await settle { !m.fixesForYou.isEmpty }
        XCTAssertEqual(panel.notes, [])
        XCTAssertEqual(m.fixesForYou.count, 1)
        XCTAssertEqual(m.fixesForYou.first?.headline, "Packet failed")
        XCTAssertTrue(m.fixesForYou.first?.entry.contains("TEST FAILED") == true)
    }

    func testTheThirdFailureGoesToTheUser() async throws {
        let panel = Panel()
        panel.outcome = .failed(failure)
        let m = try make(panel, mode: .on)
        for round in 1...3 {
            panel.finished = false
            m.process([], cards: [card()])
            panel.finished = true
            m.process([], cards: [card()])
            await settle { panel.packets.count == round && (round < 3 ? panel.notes.count == round : !m.fixesForYou.isEmpty) }
            await settle { m.records.last?.kind == "fix" }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(panel.packets.count, 3)
        XCTAssertEqual(panel.notes.count, 2)
        XCTAssertEqual(m.fixesForYou.first?.headline, "Packet failed")
    }

    func testATestFailureNoteNamesTheTestsAndTheLogAndShowsThemInTheWaitingItem() async throws {
        let panel = Panel()
        panel.outcome = .failed(PacketFailureTests.testFailure)
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        XCTAssertEqual(panel.packets.count, 1, "a test failure is not retried")
        XCTAssertTrue(panel.notes[0].contains("TestDefaultsTests.testTheSuiteOfTheEarlierTestIsGone — app/AgentPanelTests/TestDefaultsTests.swift:29"))
        XCTAssertTrue(panel.notes[0].contains("/Users/x/Documents/tasks/N177/build.log"))
        XCTAssertFalse(panel.notes[0].contains("0 failures"))
        // Shadow mode: the Waiting for you item shows the names, not only "** TEST FAILED **".
        let p2 = Panel(); p2.outcome = .failed(PacketFailureTests.testFailure)
        let s = try make(p2, mode: .shadow)
        s.process([], cards: [card()])
        await settle { !s.fixesForYou.isEmpty }
        XCTAssertEqual(s.fixesForYou.first?.headline, "Packet failed")
        XCTAssertTrue(s.fixesForYou.first?.entry.contains("testTheSuiteOfTheEarlierTestIsGone") == true)
    }

    func testAnInfrastructureFailureIsRetriedOnceAndThenWaitsForYouWithRetry() async throws {
        let panel = Panel()
        panel.outcome = .failed(PacketFailureTests.hostCrash)
        let m = try make(panel, mode: .on)
        m.infrastructureRetryDelay = .milliseconds(5)
        m.process([], cards: [card()])
        await settle { !m.fixesForYou.isEmpty }
        XCTAssertEqual(panel.packets.count, 2, "one retry by itself")
        XCTAssertEqual(panel.notes, [], "nothing goes to the agent")
        XCTAssertEqual(m.fixesForYou.first?.headline, "Packet could not run")
        XCTAssertTrue(m.fixesForYou.first?.entry.contains("RUNNER RESTARTED") == true)
        // Retry runs the packet again, and a pass clears the item.
        panel.outcome = .ready
        m.retryPacket(cardID: "V1")
        await settle { panel.packets.count == 3 }
        XCTAssertEqual(m.fixesForYou, [])
    }

    func testAnInfrastructureFailureThatPassesOnTheRetryRaisesNothing() async throws {
        let panel = Panel()
        panel.queue = [.failed(PacketFailureTests.timeout)]
        panel.outcome = .ready
        let m = try make(panel, mode: .on)
        m.infrastructureRetryDelay = .milliseconds(5)
        m.process([], cards: [card()])
        await settle { panel.packets.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(m.fixesForYou, [])
        XCTAssertEqual(panel.notes, [])
    }

    private let passing = [
        "EVIDENCE MISSING: the branch changed while the packet was being built; run it again",
        "EVIDENCE MISSING: the card changed while the packet was being built (its changes are kept); run it again",
        "EVIDENCE MISSING: a packet for V1 is already being prepared (pid 42); wait for it to finish",
        "EVIDENCE MISSING: a packet for V1 is already being prepared; wait for it to finish",
    ]

    func testAPassingFailureIsRetriedAndNeverSentToTheAgent() async throws {
        for message in passing {
            let panel = Panel()
            panel.queue = [.failed(message)]
            let m = try make(panel, mode: .on)
            m.process([], cards: [card()])
            await settle { panel.packets.count == 2 && m.records.contains { $0.kind == "review" && $0.answer == "Review prepared" } }
            XCTAssertEqual(panel.packets.count, 2, message)
            XCTAssertEqual(panel.notes, [], message)
            XCTAssertEqual(m.fixesForYou, [], message)
            XCTAssertTrue(m.records.contains { $0.kind == "review" && $0.answer == "Retry" }, message)
            XCTAssertFalse(m.records.contains { $0.kind == "fix" }, message)
        }
    }

    /// N94: a lock held by a live run (the message names its pid) is waited out; it is not a try and never escalates.
    func testALiveLockIsWaitedOutWithoutCountingATry() async throws {
        let panel = Panel()
        let held = passing[2]
        panel.queue = Array(repeating: .failed(held), count: 8)
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { panel.packets.count == 9 && m.records.contains { $0.kind == "review" && $0.answer == "Review prepared" } }
        XCTAssertEqual(panel.packets.count, 9)
        XCTAssertEqual(m.fixesForYou, [])
        XCTAssertEqual(panel.notes, [])
        XCTAssertFalse(m.records.contains { $0.kind == "fix" })
    }

    func testALockThatNeverFreesEscalatesAfterTheTimeout() async throws {
        let panel = Panel()
        panel.outcome = .failed(passing[2])
        let m = try make(panel, mode: .on)
        m.packetLockTimeout = .milliseconds(50)
        m.process([], cards: [card()])
        await settle { !m.fixesForYou.isEmpty }
        XCTAssertEqual(m.fixesForYou.first?.headline, "Packet failed")
        XCTAssertGreaterThan(panel.packets.count, 3)
        XCTAssertEqual(panel.notes, [])
    }

    func testThreePassingFailuresInARowGoToTheUserNotTheAgent() async throws {
        let panel = Panel()
        panel.outcome = .failed(passing[0])
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { !m.fixesForYou.isEmpty }
        XCTAssertEqual(panel.packets.count, 3)
        XCTAssertEqual(panel.notes, [])
        XCTAssertEqual(m.fixesForYou.first?.headline, "Packet failed")
        XCTAssertEqual(m.records.filter { $0.answer == "Retry" }.count, 2)
    }

    func testARealFailureAfterARetryStillSendsAFixAndRetriesAreNotRounds() async throws {
        let panel = Panel()
        panel.queue = [.failed(passing[0]), .failed(failure)]
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { !panel.notes.isEmpty }
        XCTAssertEqual(panel.packets.count, 2)
        XCTAssertEqual(panel.notes.count, 1)
        XCTAssertTrue(panel.notes[0].contains("TEST FAILED"))
        await settle { m.records.last?.kind == "fix" }
        XCTAssertEqual(m.records.filter { $0.kind == "fix" && $0.result == .answered }.count, 1)
    }

    func testAFixThatCannotBeSentGoesToTheUser() async throws {
        let panel = Panel()
        panel.outcome = .failed(failure)
        panel.sendError = "The agent is no longer running."
        let m = try make(panel, mode: .on)
        m.process([], cards: [card()])
        await settle { !m.fixesForYou.isEmpty }
        XCTAssertEqual(m.fixesForYou.count, 1)
    }

    func testOffModeAndTheYouRowDoNothing() async throws {
        let panel = Panel()
        let off = try make(panel, mode: .off)
        off.process([], cards: [card()])
        let you = try make(panel, mode: .on) { $0.setOwner(.you, for: .review) }
        you.process([], cards: [card()])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(panel.packets, [])
        XCTAssertEqual(AutopilotPolicy().owner(of: .review), .pm)
        XCTAssertEqual(DecisionCategory.review.title, "Prepare review when an agent finishes")
    }

    /// N53 #4: the agent fixed the task (needs-fix, new turn, changed Report): the autopilot reviews it again.
    func testAFixedNeedsFixCardIsReviewedAgain() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        m.isFinished = { panel.phaseFinished($0) }
        m.isWorking = { panel.phaseWorking($0) }
        panel.agent = .working
        m.process([], cards: [card(.needsFix)])
        panel.agent = .idle
        m.process([], cards: [card(.needsFix)])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(panel.packets, [], "the agent has not changed its Report yet")
        panel.reportChanged = true
        m.process([], cards: [card(.needsFix, report: "Fixed: 0 failures.")])
        await settle { !panel.packets.isEmpty }
        XCTAssertEqual(panel.packets, ["V1"])
    }

    /// N53 #5: a project switch or a terminal hiccup is not the agent working again.
    func testSwitchingProjectsDoesNotPackTheSameTurnAgain() async throws {
        let panel = Panel()
        let m = try make(panel, mode: .on)
        m.isFinished = { panel.phaseFinished($0) }
        m.isWorking = { panel.phaseWorking($0) }
        m.process([], cards: [card()])
        await settle { !panel.packets.isEmpty }
        panel.selected = false
        m.process([], cards: [card()])
        panel.selected = true
        m.process([], cards: [card()])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(panel.packets, ["V1"])
        // Seen working, then finished again: a new turn gets its packet.
        panel.agent = .working
        m.process([], cards: [card()])
        panel.agent = .idle
        m.process([], cards: [card()])
        await settle { panel.packets.count == 2 }
        XCTAssertEqual(panel.packets.count, 2)
    }
}

/// A value a test closure writes and the test reads.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ v: T) { lock.withLock { stored = v } }
}
