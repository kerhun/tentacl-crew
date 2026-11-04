import XCTest
@testable import AgentPanel

@MainActor
final class AutopilotModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private let worktrees = URL(fileURLWithPath: "/repo/.agent-worktrees")

    final class Reader: TerminalReading, @unchecked Sendable {
        var screens: [String: String] = [:]
        func screen(of target: String, lines: Int) async throws -> String { screens[target] ?? "" }
    }

    final class Sender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        private let lock = NSLock()
        private var k: [[String]] = [], p: [String] = []
        var keys: [[String]] { lock.lock(); defer { lock.unlock() }; return k }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return p }
        func sendKeys(target: String, keys: [String]) async throws { lock.withLock { k.append(keys) } }
        func prompt(target: String, text: String) async throws { lock.withLock { p.append(text) } }
    }

    /// Answers with a fixed decision (or error), optionally only once `release()` is called.
    final class Decider: PMDeciding, @unchecked Sendable {
        private let lock = NSLock()
        var result: Result<PMReply, Error>
        private var count = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var held: Bool
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        var lastRequest: DecisionRequest?
        var lastFixRequest: FixRequest?
        init(_ result: Result<PMReply, Error>, held: Bool = false) { self.result = result; self.held = held }
        func decide(_ request: DecisionRequest) async throws -> PMReply {
            let wait = lock.withLock { count += 1; lastRequest = request; return held }
            if wait {
                await withCheckedContinuation { c in
                    let stillHeld = lock.withLock { if held { gate = c }; return held }
                    if !stillHeld { c.resume() }  // released before the gate was set
                }
            }
            return try result.get()
        }
        func decide(_ request: FixRequest) async throws -> PMReply {
            lock.withLock { count += 1; lastFixRequest = request }
            return try result.get()
        }
        func release() { let g = lock.withLock { held = false; let g = gate; gate = nil; return g }; g?.resume() }
    }

    private var reader: Reader!
    private var sender: Sender!
    private var dir: TempDir!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws { reader = Reader(); sender = Sender(); dir = try TempDir() }

    private let agent: AgentStatus = { var a = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .blocked, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "dev-v1"; return a }()
    private var card: TaskCard {
        TaskCard(id: "V1", project: "d", status: .doing, agent: "dev-v1", branch: "test/v1", kind: nil, files: [], title: "V1", sections: [:], url: dir.url.appendingPathComponent("V1.md"))
    }
    private let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)

    private func reply(_ verdict: PMDecision.Verdict = .answer, option: Int? = 2, text: String? = nil, confidence: PMDecision.Confidence = .high) -> PMReply {
        PMReply(decision: PMDecision(verdict: verdict, option: option, text: text, why: "Card picks green.", confidence: confidence), costUSD: 0.03)
    }

    private func make(_ decider: Decider, mode: AutopilotMode, configure: (inout AutopilotPolicy) -> Void = { _ in }) throws -> (AutopilotModel, AgentInboxModel) {
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = mode; configure(&p)
        try store.save(p, for: project.id)
        try "# V1\n## Goal\nPick green.".write(to: card.url, atomically: true, encoding: .utf8)
        let inbox = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([agent])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let model = AutopilotModel(inbox: inbox, store: store, makeDecider: { _ in decider }, now: { [unowned self] in clock })
        model.setProject(project)
        return (model, inbox)
    }

    private func tick(_ model: AutopilotModel, _ inbox: AgentInboxModel) async {
        await inbox.refresh(agents: [agent], cards: [card], projectWorktrees: worktrees, label: { _ in "Pixel · V1" })
        model.process(inbox.questions, cards: [card])
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: PM authority count reset (N117)

    private func authorityStart(_ ids: [String]) -> StartRequestOutcome {
        StartRequestOutcome(requestID: "r", words: "", requested: ids, result: .started, started: ids, refused: [], failure: nil, message: "", authority: true)
    }

    func testResettingTheAuthorityCountStartsFromZeroAndSurvivesARestart() throws {
        clock = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_000_000))!
        let (m, _) = try make(Decider(.success(reply())), mode: .on) { $0.pmAuthority = true; $0.pmStartsPerDay = 2 }
        m.recordStart(authorityStart(["A", "B"]))
        XCTAssertEqual(m.authorityStartsToday(), 2)
        XCTAssertEqual(m.authority().startedToday, 2)

        clock += 60
        m.resetAuthorityCount()
        XCTAssertEqual(m.authorityStartsToday(), 0)
        XCTAssertEqual(m.authority().startedToday, 0, "a start request is accepted again at once")
        let r = try XCTUnwrap(m.records.last)
        XCTAssertEqual(r.kind, AutopilotModel.authorityResetKind)
        XCTAssertEqual(r.by, .you)
        XCTAssertEqual(r.why, "count reset by the user")
        XCTAssertEqual(DecisionFeed.summary(r), "PM start count reset to 0 by you")

        clock += 60
        m.recordStart(authorityStart(["C"]))
        XCTAssertEqual(m.authorityStartsToday(), 1, "only starts after the reset count")

        // A restart reads the same decision log.
        let (again, _) = try make(Decider(.success(reply())), mode: .on) { $0.pmAuthority = true; $0.pmStartsPerDay = 2 }
        XCTAssertEqual(again.authorityStartsToday(), 1)

        // The next day starts at 0 as before.
        clock += 24 * 3600
        XCTAssertEqual(again.authorityStartsToday(), 0)
    }

    func testShadowModeShowsThePMsSuggestionAndSendsNothing() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let decider = Decider(.success(reply()))
        let (m, inbox) = try make(decider, mode: .shadow)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        await settle { m.suggestion(for: q) != nil }
        XCTAssertEqual(m.suggestion(for: q)?.summary, "Green")
        XCTAssertEqual(m.forUser(inbox.questions).count, 1, "the user still answers")
        XCTAssertEqual(sender.keys, [])
        XCTAssertEqual(m.records.last?.result, .suggested)
        XCTAssertTrue(decider.lastRequest?.cardText.contains("Pick green.") == true)
    }

    func testOnModeSendsThePMsAnswerAndHidesTheQuestionMeanwhile() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let decider = Decider(.success(reply()), held: true)
        let (m, inbox) = try make(decider, mode: .on)
        await tick(m, inbox)
        await settle { decider.calls == 1 }
        XCTAssertEqual(m.forUser(inbox.questions), [], "the PM is deciding: nothing waits for the user")
        XCTAssertTrue(m.isHandledByPM(pane: "w1:p1"))
        XCTAssertEqual(m.deciding.count, 1)
        decider.release()
        await settle { !sender.keys.isEmpty }
        XCTAssertEqual(sender.keys, [["2"]])
        XCTAssertEqual(m.records.last?.result, .answered)
        XCTAssertEqual(m.records.last?.by, .pm)
        XCTAssertEqual(m.records.count, 1, "the PM's own answer is not logged again as the user's")
        XCTAssertEqual(inbox.questions, [])
    }

    func testAnEscalationReachesTheUserWithTheReason() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let (m, inbox) = try make(Decider(.success(reply(.escalate, option: nil))), mode: .on)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        await settle { m.escalation(for: q) != nil }
        XCTAssertEqual(m.escalation(for: q), "PM: Card picks green.")
        XCTAssertEqual(m.forUser(inbox.questions).count, 1)
        XCTAssertEqual(sender.keys, [])
    }

    func testAFailedCallOrAForbiddenAnswerGoesToTheUser() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let (m, inbox) = try make(Decider(.failure(PMDecisionError.notInstalled)), mode: .on)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        await settle { m.escalation(for: q) != nil }
        XCTAssertEqual(m.escalation(for: q), "PM could not decide: claude is not installed (or not on PATH)")

        let (m2, inbox2) = try make(Decider(.success(reply(option: 4))), mode: .on)  // "Type something." needs the terminal
        await tick(m2, inbox2)
        await settle { m2.escalation(for: q) != nil }
        XCTAssertEqual(m2.escalation(for: q), "PM gave an answer it may not give.")
        XCTAssertEqual(sender.keys, [])
    }

    func testAQuestionThePMDoesNotAnswerInTimeGoesToTheUserAndALateAnswerIsOnlyShown() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let decider = Decider(.success(reply()), held: true)
        let (m, inbox) = try make(decider, mode: .on) { $0.timeoutSeconds = 60 }
        await tick(m, inbox)
        await settle { decider.calls == 1 }
        clock = clock.addingTimeInterval(61)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        XCTAssertEqual(m.escalation(for: q), "PM did not decide within 1 min.")
        decider.release()
        await settle { m.suggestion(for: q) != nil }
        XCTAssertEqual(m.suggestion(for: q)?.option, 2)
        XCTAssertEqual(sender.keys, [], "once the user owns it the PM never sends")
    }

    func testOffModeOrAUserOwnedCategoryNeverCallsThePM() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let off = Decider(.success(reply()))
        let (m, inbox) = try make(off, mode: .off)
        await tick(m, inbox)
        let mine = Decider(.success(reply()))
        let (m2, inbox2) = try make(mine, mode: .on) { $0.setOwner(.you, for: .choice) }
        await tick(m2, inbox2)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(off.calls + mine.calls, 0)
        XCTAssertEqual(m.forUser(inbox.questions).count, 1)
        XCTAssertEqual(m2.forUser(inbox2.questions).count, 1)
    }

    /// N53 #14: switching to Off cancels the PM's calls and the questions it was thinking about come back.
    func testTurningOffShowsTheQuestionsThePMWasThinkingAbout() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let decider = Decider(.success(reply()), held: true)
        let (m, inbox) = try make(decider, mode: .on)
        await tick(m, inbox)
        await settle { decider.calls == 1 }
        XCTAssertEqual(m.forUser(inbox.questions), [])
        m.setMode(.off)
        XCTAssertEqual(m.forUser(inbox.questions).count, 1)
        XCTAssertEqual(m.deciding, [])
        XCTAssertFalse(m.isHandledByPM(pane: "w1:p1"))
        decider.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sender.keys, [], "the cancelled call sends nothing")
        XCTAssertEqual(m.forUser(inbox.questions).count, 1)
    }

    /// Sends keys only once opened, so an answer stays "being sent".
    final class GatedSender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        private let lock = NSLock()
        private var gate: CheckedContinuation<Void, Never>?
        private var open = false
        private var entered = false
        var isWaiting: Bool { lock.withLock { entered } }
        func sendKeys(target: String, keys: [String]) async throws {
            await withCheckedContinuation { c in
                let go = lock.withLock { entered = true; if open { return true }; gate = c; return false }
                if go { c.resume() }
            }
        }
        func prompt(target: String, text: String) async throws {}
        func release() { let g = lock.withLock { open = true; let g = gate; gate = nil; return g }; g?.resume() }
    }

    /// N45 #17: a refused send (another answer is in flight) must not show an old inbox error as the reason.
    func testARefusedSendDoesNotShowAnOldInboxError() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let gated = GatedSender()
        let decider = Decider(.success(reply()), held: true)
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = .on
        try store.save(p, for: project.id)
        try "# V1\n## Goal\nPick green.".write(to: card.url, atomically: true, encoding: .utf8)
        let inbox = AgentInboxModel(reader: reader, keys: gated, commander: gated, adapter: FakeTerminal(agentsResult: .success([agent])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let m = AutopilotModel(inbox: inbox, store: store, makeDecider: { _ in decider }, now: { [unowned self] in clock })
        m.setProject(project)
        await tick(m, inbox)
        await settle { decider.calls == 1 }
        let q = try XCTUnwrap(m.deciding.first)
        let special = try XCTUnwrap(q.question.options.first { $0.isSpecial })
        let refused = await inbox.answer(q, option: special)
        XCTAssertFalse(refused)
        XCTAssertNotNil(inbox.error, "an old error is on the inbox")
        let green = try XCTUnwrap(q.question.options.first { $0.number == 2 })
        let user = Task { await inbox.answer(q, option: green) }
        await settle { gated.isWaiting }
        decider.release()
        await settle { m.escalation(for: q) != nil }
        let reason = try XCTUnwrap(m.escalation(for: q))
        XCTAssertFalse(reason.contains("terminal"), reason)
        XCTAssertTrue(reason.contains("another answer"), reason)
        gated.release()
        _ = await user.value
    }

    func testAnOutwardPermissionSkipsThePM() async throws {
        reader.screens["w1:p1"] = try fixture("permission-fetch-before.txt")
        let decider = Decider(.success(reply(option: 1)))
        let (m, inbox) = try make(decider, mode: .on)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        XCTAssertEqual(q.question.kind, .permission)
        XCTAssertNotNil(m.escalation(for: q))
        XCTAssertEqual(decider.calls, 0)
    }

    func testTheUsersOwnAnswerIsLoggedForThePMToReadLater() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let (m, inbox) = try make(Decider(.success(reply())), mode: .shadow)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        await settle { m.suggestion(for: q) != nil }
        let green = try XCTUnwrap(q.question.options.first { $0.number == 2 })
        let sent = await inbox.answer(q, option: green)
        XCTAssertTrue(sent)
        XCTAssertEqual(m.records.last?.by, .you)
        XCTAssertEqual(m.records.last?.why, "Used PM's suggestion.")
        let log = DecisionLog(fileURL: try XCTUnwrap(AutopilotStore(folder: dir.url.appendingPathComponent("autopilot")).decisionsURL("demo")))
        XCTAssertEqual(log.recent(limit: 5, cardID: "V1").map(\.result), [.suggested, .answered])
    }

    func testTheAgentsPaneShowsTheSwitchTheSuggestionAndTheDecisions() async throws {
        clock = Date()
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let (m, inbox) = try make(Decider(.success(reply())), mode: .shadow)
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        await settle { m.suggestion(for: q) != nil }
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AgentsPane(state: .available([agent]), inbox: inbox, autopilot: m).frame(width: 340, height: 820), size: CGSize(width: 340, height: 820)))
        XCTAssertGreaterThan(data.count, 6_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("autopilot.png")) }
        let sheet = try XCTUnwrap(SnapshotRenderer.render(view: AutopilotRulesSheet(policy: m.policy, onSave: { _ in }, onCancel: {}), size: CGSize(width: 720, height: 560)))
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try sheet.write(to: URL(fileURLWithPath: out).appendingPathComponent("autopilot-rules.png")) }
    }

    // MARK: fix notes from a reviewer

    private let firstNote = "### 2026-10-17 10:00\n\n- Title is cut off."
    private let secondNote = "### 2026-10-17 11:00\n\n- Button is too small."

    private func fixCard(_ notes: String?, status: TaskStatus = .review) -> TaskCard {
        TaskCard(id: "V1", project: "d", status: status, agent: "dev-v1", branch: "test/v1", kind: nil, files: [], title: "V1",
                 sections: notes.map { ["Fix notes": $0] } ?? [:], url: dir.url.appendingPathComponent("V1.md"))
    }

    private func passOn(_ confidence: PMDecision.Confidence = .high) -> PMReply {
        PMReply(decision: PMDecision(verdict: .answer, why: "Inside the card's Scope.", confidence: confidence), costUSD: 0.02)
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        var error: String?
        var cards: [String] { lock.withLock { ids } }
        func send(_ card: TaskCard) async -> String? { lock.withLock { ids.append(card.id) }; return error }
    }

    /// A model that has already seen the card without a new note, so only later notes count.
    private func makeFix(_ decider: Decider, mode: AutopilotMode, sent: Sent, configure: (inout AutopilotPolicy) -> Void = { _ in }) async throws -> (AutopilotModel, AgentInboxModel) {
        let (m, inbox) = try make(decider, mode: mode, configure: configure)
        m.sendFix = { await sent.send($0) }
        m.process([], cards: [fixCard(firstNote)])
        return (m, inbox)
    }

    func testANewReviewerNoteIsPassedOnInOnMode() async throws {
        let decider = Decider(.success(passOn()))
        let sent = Sent()
        let (m, _) = try await makeFix(decider, mode: .on, sent: sent)
        XCTAssertEqual(decider.calls, 0, "notes that were already there are not new")
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { !sent.cards.isEmpty }
        XCTAssertEqual(sent.cards, ["V1"])
        XCTAssertEqual(decider.lastFixRequest?.entry, secondNote)
        XCTAssertTrue(decider.lastFixRequest?.cardText.contains("Pick green.") == true)
        XCTAssertEqual(m.fixesForYou, [])
        await settle { m.records.last?.result == .answered }
        XCTAssertEqual(m.records.last?.kind, "fix")
        XCTAssertEqual(m.records.last?.by, .pm)
        XCTAssertEqual(m.records.last?.result, .answered)
    }

    func testShadowModeSuggestsPassingTheFixOnAndTheUserSendsIt() async throws {
        let decider = Decider(.success(passOn()))
        let sent = Sent()
        let (m, _) = try await makeFix(decider, mode: .shadow, sent: sent)
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote, status: .doing)])
        await settle { m.fixesForYou.count == 1 }
        XCTAssertEqual(m.fixesForYou.first?.state, .suggested(why: "Inside the card's Scope."))
        XCTAssertEqual(sent.cards, [], "shadow sends nothing")
        XCTAssertEqual(m.records.last?.result, .suggested)
        await m.sendSuggestedFix(cardID: "V1")
        XCTAssertEqual(sent.cards, ["V1"])
        XCTAssertEqual(m.fixesForYou, [])
        XCTAssertEqual(m.records.last?.by, .you)
        XCTAssertEqual(m.records.last?.kind, "fix")
    }

    func testTheUserSendsAnEscalatedFixOnceAndItIsRecordedAsTheirs() async throws {
        let sent = Sent()
        let escalate = PMReply(decision: PMDecision(verdict: .escalate, why: "Needs a new screen.", confidence: .high), costUSD: nil)
        let (m, _) = try await makeFix(Decider(.success(escalate)), mode: .on, sent: sent)
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { m.fixesForYou.count == 1 }
        guard case .escalated = m.fix(for: "V1")?.state else { return XCTFail("\(String(describing: m.fix(for: "V1")))") }
        await m.sendSuggestedFix(cardID: "V1")
        XCTAssertEqual(sent.cards, ["V1"])
        XCTAssertEqual(m.fixesForYou, [])
        XCTAssertEqual(m.records.last?.by, .you)
        XCTAssertEqual(m.records.last?.result, .answered)
        XCTAssertEqual(m.records.last?.kind, "fix")
        await m.sendSuggestedFix(cardID: "V1")
        XCTAssertEqual(sent.cards, ["V1"], "the card is gone: nothing is sent twice")
    }

    func testAFailedSendKeepsTheEscalatedFixCardWithTheReason() async throws {
        let sent = Sent()
        let escalate = PMReply(decision: PMDecision(verdict: .escalate, why: "Needs a new screen.", confidence: .high), costUSD: nil)
        let (m, _) = try await makeFix(Decider(.success(escalate)), mode: .on, sent: sent)
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { m.fixesForYou.count == 1 }
        sent.error = "no pane"
        await m.sendSuggestedFix(cardID: "V1")
        guard case .escalated(let reason) = m.fix(for: "V1")?.state else { return XCTFail("card should stay") }
        XCTAssertTrue(reason.contains("no pane"), reason)
        XCTAssertEqual(m.fixesForYou.count, 1)
    }

    func testOffModeOrAYouOwnedRowIgnoresReviewerNotes() async throws {
        let sent = Sent()
        let off = Decider(.success(passOn()))
        let (m, _) = try await makeFix(off, mode: .off, sent: sent)
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        let mine = Decider(.success(passOn()))
        let (m2, _) = try await makeFix(mine, mode: .on, sent: sent) { $0.setOwner(.you, for: .fix) }
        m2.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(off.calls + mine.calls, 0)
        XCTAssertEqual(sent.cards, [])
        XCTAssertEqual(m.fixesForYou + m2.fixesForYou, [])
    }

    func testAnEntryWithoutADateStampIsTheAgentsOwnAnswerAndCostsNoCall() async throws {
        let decider = Decider(.success(passOn()))
        let sent = Sent()
        let (m, _) = try await makeFix(decider, mode: .on, sent: sent)
        m.process([], cards: [fixCard(firstNote, status: .needsFix)])
        m.process([], cards: [fixCard(firstNote + "\n\n### Rebase done\n\n- Rebased onto main.", status: .needsFix)])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(decider.calls, 0)
        XCTAssertEqual(m.fixesForYou + m.decidingFixes, [])
        m.process([], cards: [fixCard(firstNote + "\n\n### Rebase done\n\n- Rebased onto main.\n\n" + secondNote, status: .needsFix)])
        await settle { decider.calls == 1 }
        XCTAssertEqual(decider.lastFixRequest?.entry, secondNote, "a real stamped note still goes to the PM")
    }

    func testThePanelsOwnFixNotesWriteAndOtherStatusesAreIgnored() async throws {
        let decider = Decider(.success(passOn()))
        let sent = Sent()
        let (m, _) = try await makeFix(decider, mode: .on, sent: sent)
        m.expectOwnFixNote(cardID: "V1", quoted: "> Please fix the title.")
        m.process([], cards: [fixCard(firstNote + "\n\n### 2026-10-17 11:00\n\n> Please fix the title.", status: .needsFix)])
        let (m2, _) = try await makeFix(decider, mode: .on, sent: sent)
        m2.process([], cards: [fixCard(firstNote + "\n\n" + secondNote, status: .done)])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(decider.calls, 0)
        XCTAssertEqual(m.fixesForYou + m2.fixesForYou, [])
    }

    func testTheThirdPMFixRoundGoesToTheUser() async throws {
        let decider = Decider(.success(passOn()))
        let sent = Sent()
        let (m, _) = try await makeFix(decider, mode: .on, sent: sent)
        for i in 0..<2 {
            let notes = [firstNote, secondNote, "### 2026-10-17 12:00\n\n- Third."][0...(i + 1)].joined(separator: "\n\n")
            m.process([], cards: [fixCard(notes)])
            await settle { sent.cards.count == i + 1 && m.fix(for: "V1") == nil }
        }
        XCTAssertEqual(sent.cards.count, 2)
        m.process([], cards: [fixCard([firstNote, secondNote, "### 2026-10-17 12:00\n\n- Third.", "### 2026-10-17 13:00\n\n- Fourth."].joined(separator: "\n\n"))])
        XCTAssertEqual(decider.calls, 2, "the PM is not asked for the third round")
        guard case .escalated(let reason) = m.fix(for: "V1")?.state else { return XCTFail("\(String(describing: m.fix(for: "V1")))") }
        XCTAssertTrue(reason.contains("2"), reason)
        XCTAssertEqual(m.records.last?.result, .escalated)
        XCTAssertEqual(m.fixesForYou.count, 1)
        XCTAssertEqual(sent.cards.count, 2)
    }

    func testAPMEscalationOrAFailureReachesTheUser() async throws {
        let sent = Sent()
        let escalate = PMReply(decision: PMDecision(verdict: .escalate, why: "Needs a new screen.", confidence: .high), costUSD: nil)
        let (m, _) = try await makeFix(Decider(.success(escalate)), mode: .on, sent: sent)
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { m.fixesForYou.count == 1 }
        XCTAssertEqual(m.fix(for: "V1")?.state, .escalated(reason: "PM: Needs a new screen."))

        let (m2, _) = try await makeFix(Decider(.failure(PMDecisionError.notInstalled)), mode: .on, sent: sent)
        m2.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { m2.fixesForYou.count == 1 }
        XCTAssertEqual(m2.fix(for: "V1")?.state, .escalated(reason: "PM could not decide: claude is not installed (or not on PATH)"))

        let failing = Sent(); failing.error = "The agent did not get the fix request."
        let (m3, _) = try await makeFix(Decider(.success(passOn())), mode: .on, sent: failing)
        m3.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { m3.fixesForYou.count == 1 }
        XCTAssertEqual(m3.fix(for: "V1")?.state, .escalated(reason: "The fix request could not be sent: The agent did not get the fix request."))
        XCTAssertEqual(sent.cards, [])
    }

    func testALowConfidencePassOnIsEscalated() async throws {
        let sent = Sent()
        let (m, _) = try await makeFix(Decider(.success(passOn(.low))), mode: .on, sent: sent)
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { m.fixesForYou.count == 1 }
        XCTAssertEqual(m.fix(for: "V1")?.state, .escalated(reason: "PM is not sure."))
        XCTAssertEqual(sent.cards, [])
    }

    func testTheAgentsPaneShowsTheSuggestedFixCard() async throws {
        let (m, inbox) = try await makeFix(Decider(.success(passOn())), mode: .shadow, sent: Sent())
        m.process([], cards: [fixCard(firstNote + "\n\n" + secondNote)])
        await settle { m.fixesForYou.count == 1 }
        let data = try XCTUnwrap(SnapshotRenderer.render(view: AgentsPane(state: .available([agent]), inbox: inbox, autopilot: m).frame(width: 340, height: 520), size: CGSize(width: 340, height: 520)))
        XCTAssertGreaterThan(data.count, 6_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("autopilot-fix.png")) }
    }

    func testWithoutAStoreTheAutopilotIsOff() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let inbox = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([agent])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let decider = Decider(.success(reply()))
        let m = AutopilotModel(inbox: inbox, store: nil, makeDecider: { _ in decider })
        m.setProject(project)
        XCTAssertFalse(m.isAvailable)
        await tick(m, inbox)
        XCTAssertEqual(decider.calls, 0)
    }

    func testSwitchingToOnAsksFirstAndCancelKeepsTheOldMode() throws {
        let (m, _) = try make(Decider(.success(reply())), mode: .shadow)
        m.requestMode(.on)
        XCTAssertTrue(m.confirmingOn)
        XCTAssertEqual(m.policy.mode, .shadow, "nothing changes until the user confirms")
        m.cancelOn()
        XCTAssertFalse(m.confirmingOn)
        XCTAssertEqual(m.policy.mode, .shadow)
        m.requestMode(.on)
        m.confirmOn()
        XCTAssertFalse(m.confirmingOn)
        XCTAssertEqual(m.policy.mode, .on)
    }

    func testSwitchingToSafeModesNeedsNoConfirmation() throws {
        let (m, _) = try make(Decider(.success(reply())), mode: .on)
        m.requestMode(.off)
        XCTAssertFalse(m.confirmingOn)
        XCTAssertEqual(m.policy.mode, .off)
        m.requestMode(.shadow)
        XCTAssertEqual(m.policy.mode, .shadow)
        m.requestMode(.on)
        m.requestMode(.on)
        XCTAssertTrue(m.confirmingOn)
        XCTAssertTrue(AutopilotModel.onWarning.contains("allow"))
        XCTAssertTrue(AutopilotModel.onWarning.contains("merge"))
    }

    func testAPMQuestionIsNeverSentToThePMNorAnsweredByARule() async throws {
        let pm: AgentStatus = { var a = AgentStatus(paneID: "w9:pm", workspaceID: "w9", state: .blocked, cwd: "/repo", title: "PM", sessionID: "spm"); a.changeSeq = 1; return a }()
        reader.screens["w9:pm"] = try fixture("choice-before.txt")
        let decider = Decider(.success(reply()))
        let (m, inbox) = try make(decider, mode: .on)
        await inbox.refresh(agents: [pm], cards: [card], projectWorktrees: worktrees, pm: pm, label: { _ in "x" })
        XCTAssertEqual(inbox.questions.count, 1)
        m.process(inbox.questions, cards: [card])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(decider.calls, 0, "the PM is never asked about its own question")
        XCTAssertEqual(sender.keys, [])
        XCTAssertEqual(m.forUser(inbox.questions).count, 1, "it waits for the user")
        XCTAssertEqual(m.records, [])
    }

}

/// One real `claude --print` decision; runs only with TEST_RUNNER_TENTACL_LIVE_PM=1 because it costs a few cents.
final class PMDeciderLiveTests: XCTestCase {
    func testARealPMCallReturnsAUsableDecision() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TENTACL_LIVE_PM"] == "1", "set TEST_RUNNER_TENTACL_LIVE_PM=1 to run")
        let q = AgentQuestion(kind: .choice, title: "Tests", text: "Which tests should I run before reporting?",
                              options: [QuestionOption(number: 1, label: "Only the unit tests I changed", detail: "", isSpecial: false),
                                        QuestionOption(number: 2, label: "bash tests/run.sh (everything)", detail: "", isSpecial: false)])
        let request = DecisionRequest(projectName: "Tentacl", cardID: "N4", cardText: "# N4 · Fix a typo\n## Acceptance criteria\n`bash tests/run.sh` passes.",
                                      agentLabel: "dev-n4", question: q, earlier: [])
        let reply = try await ClaudePMDecider(model: "haiku", budgetUSD: 0.2, timeout: 120).decide(request)
        XCTAssertEqual(AutopilotRules.outcome(of: reply.decision, for: q).suggestion?.option, 2, "\(reply.decision)")
    }
}
