import XCTest
@testable import AgentPanel

/// N279: the `critical:`/`user:` lines, the critical rules, who gets a question per mode, the PM's answer typed into the right agent.
@MainActor
final class AgentQuestionRelayTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var dir: TempDir!
    private var state: URL!

    override func setUpWithError() throws {
        dir = try TempDir()
        state = dir.url.appendingPathComponent("term-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        setenv("FAKE_TERM_STATE", state.path, 1)
    }
    override func tearDown() { unsetenv("FAKE_TERM_STATE") }

    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private func detect(_ name: String) throws -> AgentQuestion { try XCTUnwrap(QuestionDetector.detect(screen: try fixture(name), state: .blocked)) }
    private func calls() -> String { (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }
    private func setScreen(_ name: String) throws {
        let screen = state.appendingPathComponent("screen")
        try? FileManager.default.removeItem(at: screen)
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), to: screen)
    }

    private func pending(_ q: AgentQuestion, card: String = "N1") -> PendingQuestion {
        PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "Dev · \(card)", cardID: card, question: q, project: "p")
    }
    private func choice(_ text: String, options: [String] = ["Red", "Green"]) -> AgentQuestion {
        AgentQuestion(kind: .choice, title: "Colour", text: text, options: options.enumerated().map { QuestionOption(number: $0.offset + 1, label: $0.element, detail: "", isSpecial: false) })
    }

    // MARK: the detector

    func testTheDetectorReadsCriticalAndUserLinesAndKeepsThemOutOfTheText() throws {
        let q = try detect("ask-marks-user.txt")
        XCTAssertEqual(q.critical, false)
        // The agent wrapped its `user:` line over two screen lines; it is one sentence again.
        XCTAssertEqual(q.userLine, "Kart yükleyen fonksiyonun adı kötü; her yerde tek seferde mi değiştirelim, yoksa eski adı bir süre kalsın mı?")
        XCTAssertTrue(q.plainText.hasSuffix("Which way do you want it?"), q.plainText)
        XCTAssertFalse(q.plainText.contains("user:"))
        XCTAssertEqual(try detect("ask-marks-critical.txt").critical, true)
    }

    func testQuestionsWithoutTheLinesStillWork() throws {
        let q = try detect("choice-code.txt")
        XCTAssertNil(q.critical)
        XCTAssertNil(q.userLine)
        XCTAssertEqual(q.plainText, q.text)
        XCTAssertEqual(q.options.map(\.label), ["Rename everywhere", "Keep a deprecated alias"].map { $0 } + ["Type something.", "Chat about this"])
    }

    func testMarksAreOnlyReadAtTheEndAndInEitherOrder() {
        XCTAssertEqual(QuestionDetector.marks(in: "Pick one.\nuser: Birini seç.\ncritical: yes").critical, true)
        XCTAssertEqual(QuestionDetector.marks(in: "Pick one.\nuser: Birini seç.\ncritical: yes").user, "Birini seç.")
        XCTAssertEqual(QuestionDetector.marks(in: "Pick one.\nuser: Birini seç.\ncritical: yes").body, "Pick one.")
        let middle = QuestionDetector.marks(in: "The user: field is empty.\nWhat now?")
        XCTAssertNil(middle.user)
        XCTAssertEqual(middle.body, "The user: field is empty.\nWhat now?")
    }

    // MARK: critical

    func testCriticalRules() {
        XCTAssertNotNil(AutopilotRules.criticalReason(choice("Run git push now?\ncritical: no")), "outward words count whatever the agent says")
        XCTAssertNotNil(AutopilotRules.criticalReason(choice("Delete the old folder?")))
        XCTAssertNotNil(AutopilotRules.criticalReason(choice("Ok?\ncritical: yes")))
        XCTAssertNil(AutopilotRules.criticalReason(choice("Which name reads better?\ncritical: no")))
        XCTAssertNil(AutopilotRules.criticalReason(choice("Which name reads better?")))
    }

    func testAPathOutsideTheCardsFilesIsCritical() {
        let files = ["app/AgentPanel/Services/QuestionDetector.swift", "app/AgentPanelTests/"]
        XCTAssertNil(AutopilotRules.criticalReason(choice("Rename it in app/AgentPanel/Services/QuestionDetector.swift?"), cardFiles: files))
        XCTAssertNil(AutopilotRules.criticalReason(choice("Add a test in app/AgentPanelTests/NewTests.swift?"), cardFiles: files))
        XCTAssertNil(AutopilotRules.criticalReason(choice("Edit /Users/me/repo/.agent-worktrees/task-n1/app/AgentPanelTests/NewTests.swift?"), cardFiles: files))
        XCTAssertNotNil(AutopilotRules.criticalReason(choice("Also change scripts/spawn-agent.sh?"), cardFiles: files))
        XCTAssertNotNil(AutopilotRules.criticalReason(choice("Write to ~/.zshrc?"), cardFiles: files))
        XCTAssertNil(AutopilotRules.criticalReason(choice("Use yes/no or and/or here?"), cardFiles: files), "a slash alone is not a path")
        XCTAssertNil(AutopilotRules.criticalReason(choice("Also change scripts/spawn-agent.sh?"), cardFiles: []), "a card without files has no scope to leave")
    }

    // MARK: routing per mode

    private func routing(_ mode: AgentQuestionMode, pm: String? = "pm1") -> QuestionRouting { QuestionRouting(mode: mode, pmPane: pm, cardFiles: ["N1": ["app/"]]) }

    func testModeAllComeToMeHoldsNothing() {
        let relay = QuestionRelay()
        let q = pending(choice("Which name reads better?"))
        relay.update(open: [q], routing: routing(.user))
        XCTAssertFalse(relay.isHeld(q.id))
        XCTAssertTrue(relay.takeOutgoing().isEmpty)
    }

    func testANonCriticalQuestionIsRelayedToThePMOnOneLine() throws {
        let relay = QuestionRelay()
        var q = choice("Which name reads better?\nuser: Hangi ad daha iyi?\ncritical: no", options: ["loadCards (Recommended)", "loadAll"])
        q.title = "Naming"
        let p = pending(q)
        relay.update(open: [p], routing: routing(.pmCritical))
        XCTAssertTrue(relay.isHeld(p.id))
        let lines = relay.takeOutgoing()
        XCTAssertEqual(lines, [.init(pane: "pm1", text: "QUESTION N1-q1 Dev · N1: Which name reads better? · options: 1) loadCards 2) loadAll · recommended: 1")])
        XCTAssertTrue(relay.takeOutgoing().isEmpty, "a line goes out once")
    }

    func testCriticalQuestionsGoStraightToTheUserInEveryMode() {
        for mode in [AgentQuestionMode.pmAll, .pmCritical] {
            let relay = QuestionRelay()
            let q = pending(choice("Delete the build folder?\ncritical: no"))
            relay.update(open: [q], routing: routing(mode))
            XCTAssertFalse(relay.isHeld(q.id), "\(mode)")
        }
    }

    func testPMAnswersAllOnlyCountsTheHardRules() {
        let marked = pending(choice("Which name?\ncritical: yes"))
        let outside = pending(choice("Also touch scripts/x.sh?"))
        let relayAll = QuestionRelay(), relayCritical = QuestionRelay()
        relayAll.update(open: [marked, outside], routing: routing(.pmAll))
        relayCritical.update(open: [marked, outside], routing: routing(.pmCritical))
        XCTAssertTrue(relayAll.isHeld(marked.id) && relayAll.isHeld(outside.id))
        XCTAssertFalse(relayCritical.isHeld(marked.id) || relayCritical.isHeld(outside.id))
    }

    func testWithoutARunningPMNothingIsHeld() {
        let relay = QuestionRelay()
        let q = pending(choice("Which name?"))
        relay.update(open: [q], routing: routing(.pmCritical, pm: nil))
        XCTAssertFalse(relay.isHeld(q.id))
    }

    func testOnlyMenusAndPlainQuestionsAreRelayed() {
        let relay = QuestionRelay()
        var multi = choice("Which?"); multi.terminalOnly = true
        let permission = AgentQuestion(kind: .permission, title: "", text: "Do you want to proceed?", options: [QuestionOption(number: 1, label: "Yes", detail: "", isSpecial: false)])
        let ask = pending(AgentQuestion(kind: .freeText, title: "", text: "Which screen do you mean?", options: []))
        relay.update(open: [pending(multi, card: "A"), pending(permission, card: "B"), ask], routing: routing(.pmCritical))
        XCTAssertEqual(relay.takeOutgoing().count, 1)
        XCTAssertTrue(relay.isHeld(ask.id))
    }

    func testAQuestionTheePMDoesNotAnswerComesBackAfterTenMinutes() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let relay = QuestionRelay()
        relay.now = { clock }
        let q = pending(choice("Which name?"))
        relay.update(open: [q], routing: routing(.pmCritical))
        clock.addTimeInterval(599)
        relay.update(open: [q], routing: routing(.pmCritical))
        XCTAssertTrue(relay.isHeld(q.id))
        clock.addTimeInterval(1)
        relay.update(open: [q], routing: routing(.pmCritical))
        XCTAssertFalse(relay.isHeld(q.id), "10 minutes: it is the user's now")
        relay.update(open: [q], routing: routing(.pmCritical))
        XCTAssertFalse(relay.isHeld(q.id), "and it is not relayed again")
        XCTAssertEqual(relay.takeOutgoing().count, 1)
    }

    func testSwitchingToAllComeToMeOrLosingThePMReturnsHeldQuestions() {
        let relay = QuestionRelay()
        let q = pending(choice("Which name?")), r = pending(choice("Which color?"), card: "N2")
        relay.update(open: [q, r], routing: routing(.pmCritical))
        relay.update(open: [q, r], routing: routing(.pmCritical, pm: nil))
        XCTAssertFalse(relay.isHeld(q.id) || relay.isHeld(r.id))
    }

    func testQuestionIDsCountPerCard() {
        let relay = QuestionRelay()
        let a = pending(choice("One?"), card: "N1"), b = pending(choice("Two?", options: ["Yes", "No"]), card: "N1"), c = pending(choice("Three?"), card: "N2")
        relay.update(open: [a], routing: routing(.pmCritical))
        relay.update(open: [a, b, c], routing: routing(.pmCritical))
        XCTAssertEqual(relay.entries.values.map(\.qid).sorted(), ["N1-q1", "N1-q2", "N2-q1"])
        XCTAssertTrue(relay.knows("N1-q2"))
        XCTAssertFalse(relay.knows("N1-q3"))
        XCTAssertFalse(relay.knows("N9-q1"))
    }

    // MARK: the PM's answer typed into the agent

    private func agent(_ state: AgentState) -> AgentStatus {
        var a = AgentStatus(paneID: "wZ:p1", workspaceID: "wZ", state: state, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "ui_dev-v1"
        return a
    }
    private func card(files: [String] = []) -> TaskCard {
        TaskCard(id: "V1", project: "d", status: .doing, agent: "ui_dev-v1", branch: "test/v1", kind: nil, files: files, title: "V1", sections: [:], url: URL(fileURLWithPath: "/tmp/V1.md"))
    }
    private func inbox(mode: AgentQuestionMode = .pmCritical, screen: String, files: [String] = []) async throws -> AgentInboxModel {
        try setScreen(screen)
        let t = ScriptTerminal(fixtures: root.appendingPathComponent("tests/fixtures"))
        let m = AgentInboxModel(reader: t, keys: t, commander: t, adapter: FakeTerminal(agentsResult: .success([agent(.blocked)])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        m.routing = QuestionRouting(mode: mode, pmPane: "pm1", cardFiles: ["V1": files])
        await m.refresh(agents: [agent(.blocked)], cards: [card(files: files)], projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), label: { _ in "Pixel · V1" })
        return m
    }

    func testARelayedQuestionLeavesTheUsersListAndThePMAnswersIt() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        XCTAssertTrue(m.questions.isEmpty)
        XCTAssertEqual(m.withPM.count, 1)
        var answeredByUser = 0
        m.onAnswered = { _, _ in answeredByUser += 1 }
        let result = await m.answerForPM(question: "V1-q1", answer: "2")
        XCTAssertEqual(try result.get(), "Green")
        XCTAssertTrue(calls().contains("keys wZ:p1 2"), calls())
        XCTAssertEqual(m.relay.answered.map(\.answer), ["Green"])
        XCTAssertEqual(m.relay.answered.first?.id, "V1-q1")
        XCTAssertEqual(answeredByUser, 0, "the autopilot does not count it as the user's answer")
        XCTAssertTrue(m.withPM.isEmpty)
    }

    // MARK: N380: held questions are visible

    func testAHeldQuestionIsListedForTheUserWithMinutesLeftButNotCounted() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        XCTAssertTrue(m.questions.isEmpty, "not a question for the user: no badge, notification or reminder (they read `questions`)")
        XCTAssertEqual(m.heldRows.map(\.id), m.withPM.map(\.id))
        let held = try XCTUnwrap(m.heldRows.first)
        XCTAssertFalse(held.isAnswered)
        let since = try XCTUnwrap(held.since)
        XCTAssertEqual(held.status(now: since), "PM is answering · comes to you in 10 min")
        XCTAssertEqual(held.status(now: since.addingTimeInterval(181)), "PM is answering · comes to you in 7 min")
        XCTAssertEqual(held.status(now: since.addingTimeInterval(599)), "PM is answering · comes to you in 1 min")
        XCTAssertEqual(m.panesWithPM, ["wZ:p1"])
    }

    func testAnswerMyselfMakesItANormalQuestionAndThePMsAnswerIsRefused() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        let id = try XCTUnwrap(m.withPM.first?.id)
        m.answerMyself(id)
        XCTAssertEqual(m.questions.map(\.id), [id], "the user's at once, with its options")
        XCTAssertTrue(m.withPM.isEmpty && m.heldRows.isEmpty)
        XCTAssertEqual(m.questions.first?.question.options.isEmpty, false)
        if case .failure(let e) = await m.answerForPM(question: "V1-q1", answer: "2") { XCTAssertTrue(e.message.contains("not open for you any more"), e.message) }
        else { XCTFail("the PM answered a question the user took") }
        XCTAssertFalse(calls().contains("keys"), calls())
    }

    func testThePMsAnswerGoesAtOnceAndTheRowShowsItBriefly() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        m.answeredShownFor = .milliseconds(150)
        var timeline: [String] = []
        m.onAnsweredByPM = { q, sent in timeline.append("\(q.cardID) \(sent)") }
        _ = try await m.answerForPM(question: "V1-q1", answer: "2").get()
        XCTAssertTrue(calls().contains("keys wZ:p1 2"), "sent right away: \(calls())")
        XCTAssertEqual(timeline, ["V1 Green"], "the card's timeline gets the PM's answer")
        XCTAssertEqual(m.heldRows.map { $0.status(now: Date()) }, ["PM answered: Green"])
        XCTAssertTrue(m.panesWithPM.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(m.heldRows.isEmpty, "gone after the moment")
    }

    func testTheUsersAnswerAfterAnswerMyselfShowsAnsweredBriefly() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        m.answeredShownFor = .milliseconds(150)
        let id = try XCTUnwrap(m.withPM.first?.id)
        m.answerMyself(id)
        let q = try XCTUnwrap(m.questions.first)
        let sent = await m.answer(q, option: try XCTUnwrap(q.question.options.first { $0.number == 1 }))
        XCTAssertTrue(sent)
        XCTAssertEqual(m.heldRows.map { $0.status(now: Date()) }, ["Answered: Red"])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(m.heldRows.isEmpty)
    }

    func testAQuestionLineThatCannotReachThePMReturnsTheQuestionAtOnce() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        XCTAssertEqual(QuestionRelay.qid(ofLine: "QUESTION V1-q1 Pixel · V1: Pick? · options: 1) Red"), "V1-q1")
        XCTAssertNil(QuestionRelay.qid(ofLine: "Panel: answered V1-q1"))
        m.questionUndelivered("V1-q1")
        XCTAssertEqual(m.questions.count, 1)
        XCTAssertTrue(m.withPM.isEmpty)
    }

    func testAnUndeliveredQuestionLineIsTakenOutOfTheOutbox() async {
        let outbox = PanelOutbox()
        outbox.add("QUESTION V1-q1 a: b", pane: "pm1")
        outbox.add("next line", pane: "pm1")
        var sent: [String] = []
        let pm = AgentStatus(paneID: "pm1", workspaceID: "w", state: .idle, cwd: "/repo", title: "pm", sessionID: "s")
        await outbox.deliver(agents: [pm], send: { item, _ in
            if item.text.hasPrefix("QUESTION") { throw BackendError.failed("no") }
            sent.append(item.text)
        }, dropped: { _ in }, failed: { $0.text.hasPrefix("QUESTION") })
        XCTAssertEqual(sent, ["next line"])
        XCTAssertTrue(outbox.items.isEmpty)
    }

    func testThePMPaneChangingOrGoingReturnsHeldQuestions() {
        let relay = QuestionRelay()
        let q = pending(choice("Which name?"))
        relay.update(open: [q], routing: routing(.pmCritical))
        relay.update(open: [q], routing: routing(.pmCritical, pm: "pm2"))
        XCTAssertFalse(relay.isHeld(q.id), "another PM pane never got the line")
    }

    func testTheAgentStatusLineSaysQuestionWithPM() {
        XCTAssertEqual(AgentStatusLine.make(heldByPM: true, question: nil, live: "Editing", transcript: nil, state: "working"), "Question with PM")
        XCTAssertEqual(AgentStatusLine.make(heldByPM: false, question: nil, live: "Editing", transcript: nil, state: "working"), "Editing")
    }

    func testAnswersAreRefusedForClosedUnknownAndWrongOptionQuestions() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        func fails(_ q: String, _ a: String) async -> String { if case .failure(let e) = await m.answerForPM(question: q, answer: a) { return e.message }; return "" }
        let unknown = await fails("V1-q9", "1")
        XCTAssertTrue(unknown.contains("no question V1-q9"), unknown)
        let noOption = await fails("V1-q1", "7")
        XCTAssertTrue(noOption.contains("no option 7"), noOption)
        XCTAssertFalse(calls().contains("keys"), "nothing was sent: \(calls())")
        _ = await m.answerForPM(question: "V1-q1", answer: "1")
        let closed = await fails("V1-q1", "1")
        XCTAssertTrue(closed.contains("not open for you any more"), closed)
    }

    func testWordsAreTypedWhereTheMenuTakesThem() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        let result = await m.answerForPM(question: "V1-q1", answer: "Teal, please")
        XCTAssertEqual(try result.get(), "Teal, please")
        XCTAssertTrue(calls().contains("keys wZ:p1 4"), calls())
        XCTAssertTrue(calls().contains("Teal, please"), calls())
    }

    func testACriticalQuestionIsNeverHeldSoThePMCannotAnswerIt() async throws {
        let m = try await inbox(screen: "ask-marks-critical.txt")
        XCTAssertEqual(m.questions.count, 1)
        XCTAssertTrue(m.withPM.isEmpty)
        if case .success = await m.answerForPM(question: "V1-q1", answer: "2") { XCTFail("answered a critical question") }
        XCTAssertFalse(calls().contains("keys"), calls())
    }

    func testAScopeHintFromTheCardsFilesMakesItCritical() async throws {
        let m = try await inbox(screen: "ask-boxed-code.txt", files: ["app/AgentPanel/"])
        XCTAssertEqual(m.questions.count, 1, "~/Library/… is outside the card's files")
        XCTAssertTrue(m.withPM.isEmpty)
    }

    // MARK: the request handler

    private final class Told: @unchecked Sendable { var lines: [(String, String)] = [] }

    private func handler(_ m: AgentInboxModel, told: Told, memory: CommandMemory) -> AnswerRequestHandler {
        AnswerRequestHandler(projects: { ["p"] }, store: { _ in AnswerRequestStore(dataDir: self.dir.url.appendingPathComponent("data")) }, inbox: { _ in m },
                             pmPane: { _ in "pm1" }, tell: { pane, text in told.lines.append((pane, text)) }, memory: memory, log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
    }
    private func request(_ id: String, question: String, answer: String, key: String?) throws {
        var object: [String: Any] = ["id": id, "requestedBy": "pm", "question": question, "answer": answer]
        if let key { object["key"] = key }
        let folder = dir.url.appendingPathComponent("data/.tentacl/answer-requests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("\(id).json"))
    }

    func testAnAnswerWithTheRightKeyIsTypedIntoTheAgentAndOneWithAWrongKeyIsRefused() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        let memory = CommandMemory(), told = Told()
        let key = memory.key(project: "p", pane: "pm1")
        let h = handler(m, told: told, memory: memory)
        try request("r1", question: "V1-q1", answer: "2", key: "not-the-key")
        try request("r2", question: "V1-q1", answer: "2", key: nil)
        await h.process()
        XCTAssertFalse(calls().contains("keys"), "wrong or missing key: nothing typed")
        XCTAssertEqual(told.lines.count, 2)
        XCTAssertTrue(told.lines.allSatisfy { $0.0 == "pm1" && $0.1.contains("refused") }, "\(told.lines)")
        XCTAssertTrue(told.lines[0].1.contains("wrong key") && told.lines[1].1.contains("no key"), "\(told.lines)")
        XCTAssertTrue(m.relay.isHeld(m.withPM[0].id), "still the PM's")
        try request("r3", question: "V1-q1", answer: "2", key: key)
        await h.process()
        XCTAssertTrue(calls().contains("keys wZ:p1 2"), calls())
        XCTAssertEqual(told.lines.last?.1, "Panel: answered V1-q1 with \"Green\".")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent("data/.tentacl/answer-requests").path)) ?? []
        XCTAssertTrue(left.isEmpty, "requests are used up: \(left)")
    }

    func testRequestsForClosedOrUnknownQuestionsAndBadFilesAreRefusedInThePMsPane() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        let memory = CommandMemory(), told = Told()
        let key = memory.key(project: "p", pane: "pm1")
        let h = handler(m, told: told, memory: memory)
        try request("a", question: "V1-q5", answer: "1", key: key)
        try request("b", question: "not-an-id", answer: "1", key: key)
        await h.process()
        XCTAssertEqual(told.lines.count, 2)
        XCTAssertTrue(told.lines[0].1.contains("no question V1-q5"), "\(told.lines)")
        XCTAssertTrue(told.lines[1].1.contains("question id"), "\(told.lines)")
        XCTAssertFalse(calls().contains("keys"))
    }

    func testRelayedLinesGoToThePMAfterItsKey() async throws {
        let m = try await inbox(screen: "choice-before.txt")
        let memory = CommandMemory(), told = Told()
        let h = handler(m, told: told, memory: memory)
        await h.deliver()
        XCTAssertEqual(told.lines.count, 2)
        XCTAssertTrue(told.lines[0].1.hasPrefix("Panel: new authority key: "), "\(told.lines)")
        XCTAssertTrue(told.lines[1].1.hasPrefix("QUESTION V1-q1 Pixel · V1: Which colour do you prefer? · options: 1) Red 2) Green 3) Blue"), told.lines[1].1)
        await h.deliver()
        XCTAssertEqual(told.lines.count, 2, "each line once")
    }

    // MARK: the answered list

    func testAnsweredByPMKeepsTheLastTwenty() {
        let relay = QuestionRelay()
        for n in 1...25 {
            let p = pending(choice("Question \(n)?"), card: "C\(n)")
            relay.update(open: [p], routing: routing(.pmCritical))
            relay.markAnswered(relay.entries[p.id]!, answer: "Red")
        }
        XCTAssertEqual(relay.answered.count, 20)
        XCTAssertEqual(relay.answered.first?.id, "C25-q1", "newest first")
    }

    // MARK: settings and spawn

    func testTheModeDefaultsToPMAnswersCriticalOnesComeToMe() {
        let defaults = makeTestDefaults(prefix: "question-mode")
        XCTAssertEqual(QuestionSettings.mode(defaults), .pmCritical)
        defaults.set("user", forKey: QuestionSettings.modeKey)
        XCTAssertEqual(QuestionSettings.mode(defaults), .user)
        defaults.set("nonsense", forKey: QuestionSettings.modeKey)
        XCTAssertEqual(QuestionSettings.mode(defaults), .pmCritical)
    }

    func testTheLanguageDefaultsToTheSystemOneAndCanBeSet() {
        let defaults = makeTestDefaults(prefix: "question-language")
        XCTAssertEqual(QuestionSettings.language(defaults), QuestionSettings.systemLanguage)
        XCTAssertFalse(QuestionSettings.systemLanguage.isEmpty)
        defaults.set("  Turkish ", forKey: QuestionSettings.languageKey)
        XCTAssertEqual(QuestionSettings.language(defaults), "Turkish")
        defaults.set("   ", forKey: QuestionSettings.languageKey)
        XCTAssertEqual(QuestionSettings.language(defaults), QuestionSettings.systemLanguage)
    }

    func testSpawnGetsTheUsersLanguageInTheEnvironmentAndOtherScriptsDoNot() async throws {
        for name in ScriptName.allCases { try dir.write("scripts/\(name.rawValue)", "#!/bin/bash\necho \"lang=${TENTACL_USER_LANGUAGE:-none}\"\n") }
        var runner = ProcessScriptRunner(settings: AppSettings(scriptsDir: dir.url.appendingPathComponent("scripts"), problems: []), timeout: 10)
        runner.userLanguage = { "Turkish" }
        let spawn = try await runner.run(.spawn, arguments: [])
        XCTAssertTrue(spawn.stdout.contains("lang=Turkish"), spawn.stdout)
        let stop = try await runner.run(.stop, arguments: [])
        XCTAssertTrue(stop.stdout.contains("lang=none"), stop.stdout)
    }

    // MARK: the readable card

    func testTheTitleIsTheUserLineElseTheFirstSentenceAndNeverCode() throws {
        let withUser = ReadableQuestion(try detect("ask-marks-user.txt"))
        XCTAssertTrue(withUser.title.hasPrefix("Kart yükleyen fonksiyonun adı kötü"), withUser.title)
        let plain = ReadableQuestion(try detect("choice-code.txt"))
        XCTAssertEqual(plain.title, "The helper that loads the cards is called loadStuff today and three callers use it.", "the only question is vague, so the first sentence leads")
        XCTAssertTrue(plain.subtitle.hasPrefix("I can rename it everywhere"), plain.subtitle)
        XCTAssertFalse(plain.title.contains("@available"))
        XCTAssertTrue(plain.details.contains("@available(*, deprecated, renamed: \"loadCards\")\n  func loadStuff() throws -> [Card] {"), plain.details)
        let command = ReadableQuestion(try detect("permission-bash-multiline.txt"))
        XCTAssertEqual(command.title, "Wants to run a command")
        XCTAssertTrue(command.details.contains("for f in src/*.swift"), command.details)
    }

    func testTheTitleIsTheLastRealQuestionAndTheContextIsMuted() {
        let r = ReadableQuestion(choice("The old build folder is 4 GB. Nothing uses it today. Should we keep it until the release is out?"))
        XCTAssertEqual(r.title, "Should we keep it until the release is out?")
        XCTAssertEqual(r.subtitle, "The old build folder is 4 GB.")
        let none = ReadableQuestion(choice("Tell me the name you want. Any name works."))
        XCTAssertEqual(none.title, "Tell me the name you want.")
        XCTAssertEqual(none.subtitle, "")
    }

    func testAPermissionShowsItsOwnDescriptionUnderTheTitle() throws {
        let r = ReadableQuestion(try detect("permission-bash-multiline.txt"))
        XCTAssertTrue(r.subtitle.hasPrefix("Check every Swift file under src for TODO markers"), r.subtitle)
    }

    func testDetailsStartFoldedExceptForAPlan() {
        XCTAssertTrue(ReadableQuestion.detailsOpenByDefault(.plan))
        for kind in [AgentQuestion.Kind.choice, .freeText, .permission] { XCTAssertFalse(ReadableQuestion.detailsOpenByDefault(kind), "\(kind)") }
        XCTAssertFalse(QuestionDetails(text: "x").open, "the card's Details are folded unless a caller opens them")
    }

    func testTheRecommendedOptionIsMarkedAndItsLabelIsClean() throws {
        let r = ReadableQuestion(try detect("ask-marks-user.txt"))
        XCTAssertEqual(r.options.map(\.label), ["Rename everywhere", "Keep a deprecated alias"])
        XCTAssertEqual(r.options.map(\.recommended), [true, false])
    }

    func testDetailsLoseTheBoxAndTerminalFrames() throws {
        let r = ReadableQuestion(try detect("ask-boxed-code.txt"))
        for ch in "│╭╮╰╯─" { XCTAssertFalse(r.details.contains(ch), "\(ch) in \(r.details)") }
        XCTAssertTrue(r.details.contains("\"terminalBackend\": \"tentacl\""), r.details)
        XCTAssertFalse(r.title.contains("{"))
        XCTAssertEqual(ReadableQuestion.cleaned("⏺ Done\n⎿  Plan saved\n────────\n  │ x │\n"), "Done\nPlan saved\n\nx")
    }

    func testTheTitleHoldsNoBackticksAndIsShort() {
        let long = String(repeating: "word ", count: 120) + "end."
        let r = ReadableQuestion(choice("Rename `loadStuff` to `loadCards`. Then more."))
        XCTAssertEqual(r.title, "Rename loadStuff to loadCards.")
        XCTAssertLessThanOrEqual(ReadableQuestion(choice(long)).title.count, 202)
    }
}
