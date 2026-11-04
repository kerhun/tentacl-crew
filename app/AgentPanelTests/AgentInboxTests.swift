import XCTest
@testable import AgentPanel

@MainActor
final class AgentInboxTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private let worktrees = URL(fileURLWithPath: "/repo/.agent-worktrees")

    final class FakeReader: TerminalReading, @unchecked Sendable {
        private let lock = NSLock()
        var screens: [String: String] = [:]
        var error: Error?
        private var count = 0
        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
        func screen(of target: String, lines: Int) async throws -> String {
            lock.lock(); count += 1; lock.unlock()
            if let error { throw error }
            return screens[target] ?? ""
        }
    }

    final class FakeSender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        private let lock = NSLock()
        private var k: [(String, [String])] = [], p: [(String, String)] = [], e: [String] = []
        /// Every call in order: "keys:down,down", "text:…", "prompt:…".
        var events: [String] { lock.lock(); defer { lock.unlock() }; return e }
        var keys: [(target: String, keys: [String])] { lock.lock(); defer { lock.unlock() }; return k.map { ($0.0, $0.1) } }
        var prompts: [(target: String, text: String)] { lock.lock(); defer { lock.unlock() }; return p.map { ($0.0, $0.1) } }
        var failure: Error?
        func sendKeys(target: String, keys: [String]) async throws { if let failure { throw failure }; lock.lock(); k.append((target, keys)); e.append("keys:" + keys.joined(separator: ",")); lock.unlock() }
        func sendText(target: String, text: String) async throws { if let failure { throw failure }; lock.lock(); e.append("text:" + text); lock.unlock() }
        func prompt(target: String, text: String) async throws { if let failure { throw failure }; lock.lock(); p.append((target, text)); e.append("prompt:" + text); lock.unlock() }
    }

    private var reader: FakeReader!
    private var sender: FakeSender!
    private var dir: TempDir!

    override func setUpWithError() throws {
        reader = FakeReader(); sender = FakeSender(); dir = try TempDir()
    }

    private func card(_ id: String = "V1", branch: String = "test/v1", status: TaskStatus = .doing) -> TaskCard {
        TaskCard(id: id, project: "d", status: status, agent: "ui_dev-\(id.lowercased())", branch: branch, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func agent(_ state: AgentState, pane: String = "w1:p1", cwd: String = "/repo/.agent-worktrees/test-v1", session: String? = "s1", seq: Int? = 1, name: String? = "ui_dev-v1") -> AgentStatus {
        var a = AgentStatus(paneID: pane, workspaceID: "w1", state: state, cwd: cwd, title: "t", sessionID: session)
        a.name = name
        a.changeSeq = seq
        return a
    }

    private func inbox(listing: [AgentStatus]? = nil) -> AgentInboxModel {
        let m = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success(listing ?? [agent(.blocked)])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        m.callWait = (.milliseconds(1), 3)
        return m
    }
    /// The keys sent, without ← and → (the panel moves between the tabs of a call to read it; that answers nothing).
    private var answerKeys: [[String]] { sender.keys.map(\.keys).filter { $0.first != "left" && $0.first != "right" } }

    private func refresh(_ m: AgentInboxModel, _ agents: [AgentStatus], cards: [TaskCard]? = nil) async {
        await m.refresh(agents: agents, cards: cards ?? [card()], projectWorktrees: worktrees, label: { _ in "Pixel · V1" })
    }

    func testALoginScreenIsASignInItemThatOpensTheLoginAndClearsOnceTheScreenIsClean() async throws {
        reader.screens["w1:p1"] = "Some work\n\n  ⎿  Invalid API key · Please run /login\n\n> "
        let m = inbox()
        var signedIn: [AgentTool] = []
        m.signIn = { signedIn.append($0) }
        await refresh(m, [agent(.idle)])
        let item = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(item.question.kind, .signIn)
        XCTAssertEqual(item.question.signInTool, .claude)
        await m.signIn(for: item)
        XCTAssertEqual(signedIn, [.claude])
        reader.screens["w1:p1"] = "Back to work\n\n> "
        await refresh(m, [agent(.idle)])  // same state counter: the sign-in forced a re-read
        XCTAssertTrue(m.questions.isEmpty)
        XCTAssertTrue(sender.events.isEmpty, "the panel types nothing into the agent")
    }

    func testABlockedAgentOfARunningTaskShowsItsChoiceQuestion() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox()
        await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(m.questions.count, 1)
        XCTAssertEqual(q.question.kind, .choice)
        XCTAssertEqual(q.agentLabel, "Pixel · V1")
        XCTAssertEqual(q.cardID, "V1")
        XCTAssertEqual(m.waitingCount(forCard: "V1"), 1)
    }

    func testANewQuestionIsLoggedOnceWithItsProject() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let log = ActionLog(fileURL: dir.url.appendingPathComponent("asked.log"))
        let m = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([agent(.blocked)])), log: log)
        await refresh(m, [agent(.blocked)])
        await refresh(m, [agent(.blocked)])
        await refresh(m, [agent(.blocked, seq: 2)])
        let events = ActionLogEvents.parse(log.read())
        XCTAssertEqual(events.map(\.text), ["asked V1 (choice)"])
        XCTAssertEqual(events.map(\.project), ["d"])
    }

    func testAPlainQuestionAfterAFinishedTurnShowsAsFreeText() async throws {
        reader.screens["w1:p1"] = try fixture("freetext-before.txt")
        let m = inbox(); await refresh(m, [agent(.done)])
        XCTAssertEqual(m.questions.first?.question.kind, .freeText)
    }

    func testAgentsWithoutARunningTaskOrWhileWorkingAreNotRead() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt"); reader.screens["w2:pA"] = try fixture("choice-before.txt")
        let m = inbox()
        await refresh(m, [agent(.blocked, pane: "w2:pA", cwd: "/Users/me/project", session: "pm"), agent(.working)])
        XCTAssertEqual(m.questions, [])
        XCTAssertEqual(reader.reads, 0, "no card or still working: the screen is not even read")
        await refresh(m, [agent(.blocked)], cards: [card(status: .done)])
        XCTAssertEqual(m.questions, [], "a finished task has no one to ask")
    }

    func testAFinishedAgentsScreenIsReadOnlyWhenTheStateChanged() async throws {
        reader.screens["w1:p1"] = try fixture("freetext-before.txt")
        let m = inbox()
        await refresh(m, [agent(.done, seq: 5)]); await refresh(m, [agent(.done, seq: 5)]); await refresh(m, [agent(.done, seq: 5)])
        XCTAssertEqual(reader.reads, 1)
        await refresh(m, [agent(.done, seq: 6)])
        XCTAssertEqual(reader.reads, 2)
    }

    // N239: a menu on the terminal that never reached Waiting for you
    func testAMenuDrawnAfterTheStateChangedStillArrives() async throws {
        let m = inbox()
        reader.screens["w1:p1"] = "⏺ Bash(touch a)\n  ⎿  Waiting…\n"   // the blocked record came before the menu was drawn
        await refresh(m, [agent(.blocked, seq: 5)])
        XCTAssertEqual(m.questions, [])
        reader.screens["w1:p1"] = try fixture("permission-bash-multiline.txt")
        await refresh(m, [agent(.blocked, seq: 5)])
        XCTAssertEqual(m.questions.first?.question.kind, .permission, "the same state and counter: the nothing read before is not kept")
    }

    func testTheNextMenuOfABlockedAgentReplacesTheAnsweredOne() async throws {
        let m = inbox()
        reader.screens["w1:p1"] = try fixture("permission-bash-multiline.txt")
        await refresh(m, [agent(.blocked, seq: 5)])
        let first = try XCTUnwrap(m.questions.first)
        reader.screens["w1:p1"] = try fixture("plan-wrapped.txt")   // answered in the terminal; a second prompt, same state and counter
        await refresh(m, [agent(.blocked, seq: 5)])
        XCTAssertEqual(m.questions.count, 1)
        XCTAssertEqual(m.questions.first?.question.kind, .plan)
        XCTAssertNotEqual(m.questions.first?.id, first.id)
        reader.screens["w1:p1"] = "⏺ Working…\n"
        await refresh(m, [agent(.blocked, seq: 5)])
        XCTAssertEqual(m.questions, [], "gone from the screen: gone from the list")
    }

    func testAMenuBelowALongPlanIsReadFromEnoughLines() async throws {
        XCTAssertGreaterThanOrEqual(AgentInboxModel.screenLines, 150)
    }

    func testDismissHidesTheQuestionUntilItGoesAwayAndComesBack() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox()
        await refresh(m, [agent(.blocked, seq: 1)])
        m.dismiss(try XCTUnwrap(m.questions.first))
        XCTAssertEqual(m.questions, [])
        await refresh(m, [agent(.blocked, seq: 2)])
        XCTAssertEqual(m.questions, [], "the same question stays dismissed")
        await refresh(m, [agent(.working, seq: 3)])
        await refresh(m, [agent(.blocked, seq: 4)])
        XCTAssertEqual(m.questions.count, 1, "after the agent moved on and asked again, the question is shown again")
    }

    func testPickingAnOptionPressesItsKeyInTheRightAgent() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        let green = try XCTUnwrap(q.question.options.first { $0.label == "Green" })
        let ok = await m.answer(q, option: green)
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.keys.count, 1)
        XCTAssertEqual(sender.keys[0].target, "w1:p1")
        XCTAssertEqual(sender.keys[0].keys, ["2"])
        XCTAssertEqual(m.questions, [], "an answered question leaves at once")
    }

    func testOptionsThePanelCannotAnswerAreRefused() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        let special = try XCTUnwrap(q.question.options.first { $0.isSpecial })
        let ok = await m.answer(q, option: special)
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
        XCTAssertNotNil(m.error)
    }

    func testATypedAnswerIsSentAsOnePromptAndBlankOnesAreNot() async throws {
        reader.screens["w1:p1"] = try fixture("freetext-before.txt")
        let m = inbox(listing: [agent(.done)]); await refresh(m, [agent(.done)])
        let q = try XCTUnwrap(m.questions.first)
        let blank = await m.answer(q, text: "  \n ")
        XCTAssertFalse(blank)
        XCTAssertEqual(sender.prompts.count, 0)
        let text = "The home screen; also $(whoami) \"quoted\""
        let ok = await m.answer(q, text: text)
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.prompts.count, 1)
        XCTAssertEqual(sender.prompts[0].target, "w1:p1")
        XCTAssertEqual(sender.prompts[0].text, text)
    }

    func testNothingIsSentWhenThePaneNowRunsAnotherSession() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(listing: [agent(.blocked, session: "someone-else")]); await refresh(m, [agent(.blocked, session: "s1")])
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: try XCTUnwrap(q.question.options.first))
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
        XCTAssertTrue(m.error?.contains("no longer") == true, m.error ?? "")
    }

    func testNothingIsSentWhenTheAgentIsGone() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(listing: []); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: try XCTUnwrap(q.question.options.first))
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
    }

    func testATerminalReadErrorIsShownAndKeepsTheOtherQuestions() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked, seq: 1)])
        XCTAssertEqual(m.questions.count, 1)
        reader.error = BackendError.failed("terminal stopped")
        await refresh(m, [agent(.blocked, seq: 1), agent(.done, pane: "w3:p1", cwd: "/repo/.agent-worktrees/test-v2", session: "s3", seq: 7, name: "ui_dev-v2")], cards: [card(), card("V2", branch: "test/v2")])
        XCTAssertEqual(m.questions.count, 1, "the question that was already known stays")
        XCTAssertTrue(m.error?.contains("terminal stopped") == true)
        reader.error = nil
        await refresh(m, [agent(.blocked, seq: 1)])
        XCTAssertNil(m.error)
    }

    func testASendFailureIsReportedAndTheQuestionStays() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        sender.failure = BackendError.failed("pane closed")
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: try XCTUnwrap(q.question.options.first))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.questions.count, 1)
        XCTAssertTrue(m.error?.contains("pane closed") == true)
    }

    func testASecondAnswerWhileOneIsBeingSentIsIgnored() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        async let first = m.answer(q, option: q.question.options[0])
        async let second = m.answer(q, option: q.question.options[1])
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(sender.keys.count, 1)
    }

    // MARK: wiring into the panel

    private func panel(agents: [AgentStatus]) throws -> PanelModel {
        try dir.write("data/tasks/V1.md", "---\nid: V1\nproject: demo\nstatus: doing\nagent: ui_dev-v1\nbranch: test/v1\nfiles:\n  - a\n---\n# V1\n")
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")
        let r = reader!, s = sender!
        let iso = TestIsolation(dir, owner: self)
        return PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(agents)) }, opener: RecordingOpener(),
                          makeCommander: { s }, log: iso.log, defaults: iso.defaults,
                          roleStore: iso.roleStore, makeReader: { r }, makeKeySender: { s })
    }

    func testThePanelFillsTheInboxWhenItRefreshesAgents() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = try panel(agents: [agent(.blocked, cwd: "/repo/.agent-worktrees/test-v1")])
        await m.reload()
        XCTAssertEqual(m.inbox.questions.count, 1)
        XCTAssertEqual(m.inbox.questions.first?.cardID, "V1")
        XCTAssertEqual(m.waitingForYouCount, m.pendingApprovalCount + 1)
    }

    func testAWorkingAgentLeavesTheInboxEmpty() async throws {
        let m = try panel(agents: [agent(.working, cwd: "/repo/.agent-worktrees/test-v1")])
        await m.reload()
        XCTAssertEqual(m.inbox.questions, [])
        XCTAssertEqual(reader.reads, 0)
    }

    // MARK: the user's own shells (N247)

    /// A shell of the user's that looks exactly like the card's agent (its name, its folder) and shows a menu.
    private func userShell() -> AgentStatus { agent(.blocked, pane: "my-shell-1") }

    func testAUserShellShowingAMenuIsNeverReadAskedAboutOrAnswered() async throws {
        let screen = try fixture("choice-before.txt")
        reader.screens["my-shell-1"] = screen
        let shell = userShell()
        let m = inbox(listing: [shell])
        await refresh(m, [shell])
        XCTAssertEqual(m.questions, [])
        // Not even as the project's PM.
        await m.refresh(agents: [shell], cards: [card()], projectWorktrees: worktrees, pm: shell, pmProject: "d", label: { _ in "PM" })
        XCTAssertEqual(m.questions, [])
        XCTAssertEqual(reader.reads, 0, "its screen is never read")
        // A question made by hand for it is refused: no keys, no prompt.
        let question = try XCTUnwrap(QuestionDetector.detect(screen: screen, state: .blocked))
        let pending = PendingQuestion(paneID: "my-shell-1", sessionID: "s1", agentLabel: "Shell 1", cardID: "V1", question: question)
        let answered = await m.answer(pending, option: question.options[0])
        let skipped = await m.skip(pending)
        XCTAssertFalse(answered)
        XCTAssertFalse(skipped)
        XCTAssertEqual(sender.events, [])
    }

    func testThePanelNeverReadsCountsOrWritesToAUserShell() async throws {
        reader.screens["my-shell-1"] = try fixture("choice-before.txt")
        let m = try panel(agents: [userShell()])
        await m.reload()
        await m.refreshAgents()
        XCTAssertEqual(m.inbox.questions, [])
        XCTAssertEqual(reader.reads, 0)
        XCTAssertEqual(m.pmCandidates, [])
        // A panel line for it waits in the outbox and is never sent.
        await m.tellPM(pane: "my-shell-1", "Panel: hello")
        XCTAssertEqual(sender.prompts.count, 0)
        XCTAssertEqual(sender.keys.count, 0)
        // A working shell is not a running task for the sleep guard and the autopilot.
        let working = agent(.working, pane: "my-shell-1")
        let w = try panel(agents: [working])
        await w.refreshAgents()
        XCTAssertEqual(w.pmCandidates, [])
        XCTAssertFalse(TerminalShells.withoutUserShells([working]).contains { $0.state == .working })
    }

    // MARK: skip

    func testSkippingAMenuPressesEscapeInTheAgent() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let ok = await m.skip(try XCTUnwrap(m.questions.first))
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.keys.count, 1)
        XCTAssertEqual(sender.keys[0].target, "w1:p1")
        XCTAssertEqual(sender.keys[0].keys, ["esc"])
        XCTAssertEqual(m.questions, [])
    }

    func testSkippingAPlainQuestionTellsTheAgentToCarryOn() async throws {
        reader.screens["w1:p1"] = try fixture("freetext-before.txt")
        let m = inbox(listing: [agent(.done)]); await refresh(m, [agent(.done)])
        let ok = await m.skip(try XCTUnwrap(m.questions.first))
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.prompts.count, 1)
        XCTAssertTrue(sender.prompts[0].text.lowercased().contains("skip"))
        XCTAssertTrue(sender.prompts[0].text.lowercased().contains("carry on") || sender.prompts[0].text.lowercased().contains("continue"))
        XCTAssertEqual(sender.keys.count, 0)
    }

    func testSkipGoesOnlyToTheSameAgentSession() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(listing: [agent(.blocked, session: "someone-else")]); await refresh(m, [agent(.blocked, session: "s1")])
        let ok = await m.skip(try XCTUnwrap(m.questions.first))
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
    }

    func testDismissKeepsAQuietWaitingMarkerForTheCard() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked, seq: 1)])
        XCTAssertEqual(m.quietWaitingCount(forCard: "V1"), 0)
        m.dismiss(try XCTUnwrap(m.questions.first))
        XCTAssertEqual(m.waitingCount(forCard: "V1"), 0)
        XCTAssertEqual(m.quietWaitingCount(forCard: "V1"), 1)
        await refresh(m, [agent(.blocked, seq: 2)])
        XCTAssertEqual(m.quietWaitingCount(forCard: "V1"), 1, "still stuck, still marked")
        await refresh(m, [agent(.working, seq: 3)])
        XCTAssertEqual(m.quietWaitingCount(forCard: "V1"), 0, "the marker goes when the agent moves on")
    }

    func testASessionThatIsNotTheTaskAgentIsNeverReadOrAnswered() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox()
        await refresh(m, [agent(.blocked, name: nil)])
        XCTAssertEqual(m.questions, [])
        await refresh(m, [agent(.blocked, name: "someone-else")])
        XCTAssertEqual(m.questions, [])
        XCTAssertEqual(reader.reads, 0)
    }

    func testDismissNeverTouchesTheAgent() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        m.dismiss(try XCTUnwrap(m.questions.first))
        XCTAssertEqual(sender.keys.count, 0)
        XCTAssertEqual(sender.prompts.count, 0)
    }

    // MARK: review fixes

    func testAnAnswerIsNotSentWhenTheScreenNoLongerShowsThatQuestion() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        reader.screens["w1:p1"] = "⏺ Working on it\n"
        let ok = await m.answer(q, option: q.question.options[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
        XCTAssertEqual(m.questions, [])
        XCTAssertNotNil(m.error)
    }

    func testNothingIsSentWhenTheSessionWasUnknownWhenTheQuestionWasRead() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(listing: [agent(.blocked, session: nil)]); await refresh(m, [agent(.blocked, session: nil)])
        let ok = await m.answer(try XCTUnwrap(m.questions.first), option: m.questions[0].question.options[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
    }

    func testAReusedPaneWithAnotherSessionDoesNotInheritTheCachedQuestion() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked, session: "s1")])
        XCTAssertEqual(m.questions.count, 1)
        reader.screens["w1:p1"] = "⏺ fresh agent\n"
        await refresh(m, [agent(.blocked, session: "s2")])
        XCTAssertEqual(m.questions, [])
    }

    func testADismissedQuestionStaysHiddenAfterAFailedRead() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked, seq: nil)])
        m.dismiss(try XCTUnwrap(m.questions.first))
        reader.error = BackendError.failed("busy")
        await refresh(m, [agent(.blocked, seq: nil)])
        reader.error = nil
        await refresh(m, [agent(.blocked, seq: nil)])
        XCTAssertEqual(m.questions, [])
    }

    func testASendErrorSurvivesTheNextSuccessfulRefresh() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        let m = inbox(listing: [agent(.blocked, session: "other")]); await refresh(m, [agent(.blocked)])
        _ = await m.skip(try XCTUnwrap(m.questions.first))
        XCTAssertNotNil(m.error)
        reader.screens["w1:p1"] = try fixture("choice-before.txt")
        await refresh(m, [agent(.blocked, seq: 2)])
        XCTAssertNotNil(m.error)
    }

    // MARK: permission and plan cards

    func testDenyingAPermissionPressesEscape() async throws {
        reader.screens["w1:p1"] = try fixture("permission-fetch-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(q.question.kind, .permission)
        let ok = await m.answer(q, option: try XCTUnwrap(q.question.options.first { $0.role == .deny }))
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.keys.map(\.keys), [["esc"]])
    }

    func testSkipDoesNotApplyToPermissionOrPlanCards() async throws {
        for name in ["permission-fetch-before.txt", "plan-approval-before.txt"] {
            reader.screens["w1:p1"] = try fixture(name)
            let m = inbox(); await refresh(m, [agent(.blocked)])
            let ok = await m.skip(try XCTUnwrap(m.questions.first))
            XCTAssertFalse(ok, name)
        }
        XCTAssertEqual(sender.keys.count, 0)
        XCTAssertEqual(sender.prompts.count, 0)
    }

    func testApprovingAPlanPressesItsNumber() async throws {
        reader.screens["w1:p1"] = try fixture("plan-approval-before.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: q.question.options[1])
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.keys.map(\.keys), [["2"]])
    }

    // MARK: feedback on plan and permission cards

    /// Blocked until the keys contain "esc", done afterwards: the agent after its tool call was rejected.
    private struct EscapeAdapter: TerminalListing {
        let sender: FakeSender
        func agents() async throws -> [AgentStatus] {
            var a = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: sender.keys.contains { $0.keys == ["esc"] } ? .done : .blocked, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1")
            a.name = "ui_dev-v1"; a.changeSeq = 1
            return [a]
        }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
    }

    func testPlanFeedbackSelectsOption3TypesTheTextAndPressesEnter() async throws {
        reader.screens["w1:p1"] = try fixture("plan-feedback-menu.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(q.question.kind, .plan)
        let ok = await m.feedback(q, text: "Use bye instead of hi")
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.events, ["keys:down,down", "text:Use bye instead of hi", "keys:enter"])
        XCTAssertEqual(sender.prompts.count, 0)
    }

    func testEditPermissionFeedbackSelectsNoPressesTabTypesAndPressesEnter() async throws {
        reader.screens["w1:p1"] = try fixture("permission-edit-menu.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(q.question.kind, .permission)
        let ok = await m.feedback(q, text: "Write BYE")
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.events, ["keys:down,down", "keys:tab", "text:Write BYE", "keys:enter"])
    }

    func testMenuWithoutTabToAmendPressesEscapeWaitsForDoneThenPrompts() async throws {
        reader.screens["w1:p1"] = try fixture("permission-fetch-before.txt")
        let m = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: EscapeAdapter(sender: sender), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.feedback(q, text: "Do not fetch, read the local file")
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.events, ["keys:esc", "prompt:Do not fetch, read the local file"])
    }

    func testEmptyFeedbackSendsNothing() async throws {
        reader.screens["w1:p1"] = try fixture("plan-feedback-menu.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let ok = await m.feedback(try XCTUnwrap(m.questions.first), text: " \n ")
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.events, [])
    }

    func testFeedbackStopsWhenTheScreenChangedBetweenSteps() async throws {
        reader.screens["w1:p1"] = try fixture("permission-edit-menu.txt")
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        reader.screens["w1:p1"] = try fixture("permission-edit-after.txt").replacingOccurrences(of: "Do you want to create hello.txt?", with: "Do you want to delete hello.txt?")
        let ok = await m.feedback(q, text: "x")
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.events, [])
        XCTAssertNotNil(m.error)
    }

    func testFeedbackPathIsPickedFromTheScreen() throws {
        let fix = { (n: String, s: AgentState) in try XCTUnwrap(QuestionDetector.detect(screen: try self.fixture(n), state: s)) }
        XCTAssertEqual(try fix("plan-feedback-menu.txt", .blocked).feedbackPath, .inline(select: ["down", "down"], tab: false))
        XCTAssertEqual(try fix("permission-edit-menu.txt", .blocked).feedbackPath, .inline(select: ["down", "down"], tab: true))
        XCTAssertEqual(try fix("permission-fetch-before.txt", .blocked).feedbackPath, .escapeThenPrompt)
        XCTAssertNil(try fix("choice-before.txt", .blocked).feedbackPath)
    }

    func testLineBreaksInFeedbackBecomeSpacesOnBothPaths() async throws {
        reader.screens["w1:p1"] = try fixture("plan-feedback-menu.txt")
        var m = inbox(); await refresh(m, [agent(.blocked)])
        _ = await m.feedback(try XCTUnwrap(m.questions.first), text: "Use bye\nnot hi\r\n\r\nplease")
        XCTAssertEqual(sender.events, ["keys:down,down", "text:Use bye not hi please", "keys:enter"])

        let other = FakeSender()
        reader.screens["w1:p1"] = try fixture("permission-fetch-before.txt")
        m = AgentInboxModel(reader: reader, keys: other, commander: other, adapter: EscapeAdapter(sender: other), log: ActionLog(fileURL: dir.url.appendingPathComponent("log2")))
        await refresh(m, [agent(.blocked)])
        _ = await m.feedback(try XCTUnwrap(m.questions.first), text: "line one\nline two")
        XCTAssertEqual(other.events, ["keys:esc", "prompt:line one line two"])
    }

    // MARK: the PM's own questions (N79)

    private func pm(_ state: AgentState, seq: Int? = 1) -> AgentStatus { agent(state, pane: "w9:pm", cwd: "/repo", session: "spm", seq: seq, name: nil) }
    private func refreshWithPM(_ m: AgentInboxModel, _ agents: [AgentStatus], pm: AgentStatus?) async {
        await m.refresh(agents: agents, cards: [card()], projectWorktrees: worktrees, pm: pm, pmProject: "d", label: { _ in "Pixel · V1" })
    }

    func testThePMsChoiceMenuBecomesAQuestionThatBelongsToNoCard() async throws {
        reader.screens["w9:pm"] = try fixture("choice-before.txt")
        let m = inbox(listing: [pm(.blocked)])
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(q.question.kind, .choice)
        XCTAssertTrue(q.isPM)
        XCTAssertEqual(q.agentLabel, "PM")
        XCTAssertEqual(q.cardID, "")
        XCTAssertEqual(m.waitingCount(forCard: "V1"), 0)
        XCTAssertEqual(m.waitingCount(forCard: ""), 0)
    }

    /// N289: a PM permission is the user's even while questions go to the PM; it is never held for the PM itself.
    func testThePMsPermissionReachesTheUserAndIsNotHeldForThePM() async throws {
        reader.screens["w9:pm"] = try fixture("permission-edit-menu.txt")
        let m = inbox(listing: [pm(.blocked)])
        m.routing = QuestionRouting(mode: .pmAll, pmPane: "w9:pm")
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        XCTAssertEqual(m.questions.count, 1)
        XCTAssertEqual(m.questions.first?.isPM, true)
        XCTAssertEqual(m.questions.first?.question.kind, .permission)
        XCTAssertEqual(m.withPM, [])
    }

    private struct NoMerge: CommandRunner {
        func run(_ executable: URL, _ arguments: [String]) async throws -> Data { throw CocoaError(.fileNoSuchFile) }
    }

    /// N289, the bug: the panel restarted the PM with hand-off from inside the agent poll and waited there for the note; the PM stopped at the
    /// permission menu for writing that note, and no poll read it, so the user never saw it. The poll now keeps reading questions meanwhile.
    func testThePMsPermissionDuringAHandoffReachesTheUserWhileThePanelWaits() async throws {
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: doing\nagent:\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5\n")
        try dir.write("data/plan.json", #"{"rounds":[{"name":"R1","cards":["A5"],"reason":"","status":""}]}"#)
        let data = dir.url.appendingPathComponent("data")
        let source = try dir.write("p/demo.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(data.path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"]}")
        let pane = FakePane()
        reader.screens[pane.pane] = try fixture("permission-edit-menu.txt")
        // The PM asks to write the note: it stops at the permission menu until it is answered.
        pane.onPrompt = { [unowned pane] text in if text.contains("hand-off") { pane.state = .blocked } }
        let r = reader!, s = sender!
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: settings, makeTerminal: { pane }, opener: RecordingOpener(), makeCommander: { pane }, log: iso.log,
                           defaults: iso.defaults, roleStore: iso.roleStore, makeReader: { r }, makeKeySender: { s },
                           autopilotStore: AutopilotStore(folder: dir.url.appendingPathComponent("autopilot")))
        m.restartTiming = .init(poll: .milliseconds(5), handoff: .seconds(20), session: .seconds(5))
        m.claudeProjectsRoot = dir.url.appendingPathComponent("claude")
        m.usageSource = { nil }
        m.mergeRunner = NoMerge()
        m.setPMSession("old", forProject: "demo")
        await m.reload()
        await m.refreshAgents()
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: done\nagent:\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5\n")
        // The polls see the card done and start the hand-off themselves (a reload by hand would wait for it).
        m.startPolling(interval: .milliseconds(20))
        defer { m.stopPolling() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !m.inbox.questions.contains(where: \.isPM) { try await Task.sleep(for: .milliseconds(20)) }
        let q = try XCTUnwrap(m.inbox.questions.first { $0.isPM }, "the PM's permission shows while the panel waits for the hand-off")
        XCTAssertEqual(q.question.kind, .permission)
        XCTAssertTrue(pane.events.contains { $0.contains("hand-off") }, "\(pane.events)")
        // Allowed: the PM writes the note and the restart goes on.
        let allow = try XCTUnwrap(q.question.options.first)
        let sent = await m.inbox.answer(q, option: allow)
        XCTAssertTrue(sent)
        try "- note\n".write(to: data.appendingPathComponent("pm-handoff.md"), atomically: true, encoding: .utf8)
        pane.onPrompt = { [unowned pane] text in if text == "/clear" { pane.session = "new" } }
        pane.state = .idle
        let end = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < end, m.pmSession(forProject: "demo") != "new" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.pmSession(forProject: "demo"), "new", "\(pane.events) \(m.actionState)")
    }

    func testThePMsPlainQuestionIsIgnored() async throws {
        reader.screens["w9:pm"] = try fixture("freetext-before.txt")
        let m = inbox(listing: [pm(.done)])
        await refreshWithPM(m, [pm(.done)], pm: pm(.done))
        await refreshWithPM(m, [pm(.idle)], pm: pm(.idle))
        XCTAssertEqual(m.questions, [])
    }

    func testTaskAgentsStillShowNextToThePM() async throws {
        reader.screens["w1:p1"] = try fixture("choice-before.txt"); reader.screens["w9:pm"] = try fixture("choice-before.txt")
        let m = inbox()
        await refreshWithPM(m, [agent(.blocked), pm(.blocked)], pm: pm(.blocked))
        XCTAssertEqual(m.questions.map(\.isPM).sorted { !$0 && $1 }, [false, true])
        XCTAssertEqual(m.waitingCount(forCard: "V1"), 1)
    }

    func testWithoutAPMNothingChanges() async throws {
        reader.screens["w9:pm"] = try fixture("choice-before.txt")
        let m = inbox()
        await refreshWithPM(m, [pm(.blocked)], pm: nil)
        XCTAssertEqual(m.questions, [])
    }

    func testAPMQuestionIsLoggedForThePMAndAnsweringIsLoggedForThePM() async throws {
        reader.screens["w9:pm"] = try fixture("choice-before.txt")
        let log = ActionLog(fileURL: dir.url.appendingPathComponent("pm.log"))
        let m = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([pm(.blocked)])), log: log)
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: q.question.options[1])
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.keys.map(\.target), ["w9:pm"])
        XCTAssertEqual(ActionLogEvents.parse(log.read()).map(\.text), ["asked PM (choice)", "answered PM (w9:pm)"])
    }

    func testThePMsAnswerStillNeedsTheSameSession() async throws {
        reader.screens["w9:pm"] = try fixture("choice-before.txt")
        var other = pm(.blocked); other.sessionID = "other"
        let m = inbox(listing: [other])
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: q.question.options[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
    }

    // MARK: menus the panel cannot answer safely

    func testPreviewLayoutYieldsTheRealOptions() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-preview.txt"), state: .blocked))
        XCTAssertEqual(q.kind, .choice)
        XCTAssertEqual(q.title, "Layout")
        XCTAssertEqual(q.text, "Which layout?")
        XCTAssertEqual(q.options.map(\.label), ["Compact", "Wide", "Split"])
        XCTAssertEqual(q.options.map(\.detail), ["", "", ""])
        XCTAssertFalse(q.terminalOnly)
    }

    func testMultiSelectAndSeveralQuestionsAreTerminalOnly() throws {
        let multi = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-multiselect.txt"), state: .blocked))
        XCTAssertEqual(multi.options.prefix(3).map(\.label), ["[ ] Cheese", "[ ] Ham", "[ ] Olives"])
        XCTAssertTrue(multi.terminalOnly)
        let tabs = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-tabs.txt"), state: .blocked))
        XCTAssertEqual(tabs.options.prefix(2).map(\.label), ["Red", "Green"])
        XCTAssertEqual(tabs.title, "Question 1 of 2 · Colour · Size")
        XCTAssertEqual(tabs.text, "Colour?")
        XCTAssertFalse(tabs.terminalOnly, "tabs are answered from the panel since N187; multiSelect stays terminal-only")
    }

    func testATabbedQuestionIsAnsweredWithTheDigitAndTheNextStepShowsAfterwards() async throws {
        let steps = ["choice-tabs3-1.txt", "choice-tabs3-2.txt", "choice-tabs3-3.txt", "choice-tabs3-4-submit.txt"]
        let expectedKeys = ["2", "1", "2", "1"]
        reader.screens["w9:pm"] = try fixture(steps[0])
        let m = inbox(listing: [pm(.blocked)])
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        for (i, step) in steps.enumerated() {
            let q = try XCTUnwrap(m.questions.first, step)
            let option = try XCTUnwrap(q.question.options.first { $0.number == Int(expectedKeys[i]) })
            let ok = await m.answer(q, option: option)
            XCTAssertTrue(ok, step)
            XCTAssertEqual(answerKeys.last, [expectedKeys[i]])
            XCTAssertTrue(m.questions.isEmpty)
            guard i + 1 < steps.count else { break }
            reader.screens["w9:pm"] = try fixture(steps[i + 1])
            await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
            XCTAssertEqual(m.questions.first?.question.step, i + 2 <= 3 ? i + 2 : nil, "the next step shows as the next question")
            XCTAssertEqual(m.questions.first?.question.isReview, i + 2 > 3)
        }
        XCTAssertEqual(answerKeys.count, 4)
    }

    func testTheSubmitStepIsPressedOnlyByTheUserAndCanBeCancelled() async throws {
        reader.screens["w9:pm"] = try fixture("choice-tabs2-3-submit.txt")
        let m = inbox(listing: [pm(.blocked)])
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        XCTAssertEqual(sender.keys.count, 0, "nothing is submitted by looking")
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: try XCTUnwrap(q.question.options.first { $0.label == "Cancel" }))
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.keys.last?.keys, ["2"])
    }

    func testAnOptionOfAnEarlierTabIsNotSentToALaterOne() async throws {
        reader.screens["w9:pm"] = try fixture("choice-tabs3-1.txt")
        let m = inbox(listing: [pm(.blocked)])
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        let q = try XCTUnwrap(m.questions.first)
        reader.screens["w9:pm"] = try fixture("choice-tabs3-2.txt")
        let ok = await m.answer(q, option: q.question.options[0])
        XCTAssertFalse(ok, "the agent moved to the next tab: the answer is not sent")
        XCTAssertEqual(answerKeys.count, 0)
    }

    func testATerminalOnlyQuestionIsNeverAnsweredByKey() async throws {
        reader.screens["w9:pm"] = try fixture("choice-multiselect.txt")
        let m = inbox(listing: [pm(.blocked)])
        await refreshWithPM(m, [pm(.blocked)], pm: pm(.blocked))
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(q, option: q.question.options[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
    }

    func testNothingIsSentWhenTheCommandOnScreenChangedAfterTheUserSawIt() async throws {
        let seen = try fixture("permission-bash-multiline.txt")
        reader.screens["w1:p1"] = seen
        let m = inbox(); await refresh(m, [agent(.blocked)])
        let q = try XCTUnwrap(m.questions.first)
        reader.screens["w1:p1"] = seen.replacingOccurrences(of: "echo \"$f has a TODO\"", with: "rm -rf \"$f\"")   // a different command, same question
        let ok = await m.answer(q, option: try XCTUnwrap(q.question.options.first))
        XCTAssertFalse(ok)
        XCTAssertEqual(sender.keys.count, 0)
        XCTAssertTrue(m.error?.contains("no longer") == true, m.error ?? "")
    }

    func testThePermissionWithANewCommandShowsUpAfterTheFirstWasDismissed() async throws {
        let seen = try fixture("permission-bash-multiline.txt")
        reader.screens["w1:p1"] = seen
        let m = inbox(); await refresh(m, [agent(.blocked)])
        m.dismiss(try XCTUnwrap(m.questions.first))
        XCTAssertEqual(m.questions, [])
        reader.screens["w1:p1"] = seen.replacingOccurrences(of: "echo \"$f has a TODO\"", with: "rm -rf \"$f\"")
        await refresh(m, [agent(.blocked)])
        XCTAssertEqual(m.questions.count, 1, "a new command is a new question, not the dismissed one")
    }

    // MARK: N380: the top bar's Inbox lists questions the PM has, uncounted

    func testTheInboxListsHeldQuestionsWithoutCountingThem() {
        let q = PendingQuestion(paneID: "w1:p1", sessionID: "s", agentLabel: "ui_dev · N7", cardID: "N7",
                                question: AgentQuestion(kind: .choice, title: "Which name?", text: "", options: []))
        let now = Date(timeIntervalSince1970: 5_000)
        let source = TopBarInbox.Source(id: "p", name: "P", questions: [], held: [HeldQuestion(question: q, since: now.addingTimeInterval(-120))])
        let content = TopBarInbox.content(sources: [source], selected: "p", ready: [], now: now)
        XCTAssertEqual(content.count, 0, "no badge for a question the PM has")
        XCTAssertEqual(content.withPM.map(\.title), ["N7 asks: Which name?"])
        XCTAssertEqual(content.withPM.first?.detail, "ui_dev · N7 · PM is answering · comes to you in 8 min")
        XCTAssertEqual(content.withPM.first?.questionID, q.id)
    }
}
