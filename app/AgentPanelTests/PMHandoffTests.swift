import XCTest
@testable import AgentPanel

/// One pane that plays terminal and Claude Code: it records what it is sent, and reacts like the real agent would.
final class FakePane: TerminalListing, TerminalCommanding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    var state: AgentState = .idle
    var session: String? = "old"
    var pane = "w2:p1"
    var present = true
    /// What the agent does with a prompt (write the hand-off, change session, …).
    var onPrompt: (String) -> Void = { _ in }

    func agents() async throws -> [AgentStatus] {
        lock.lock(); defer { lock.unlock() }
        return present ? [AgentStatus(paneID: pane, workspaceID: "w2", state: state, cwd: "/repo", title: "pm-demo", sessionID: session, name: "pm-demo")] : []
    }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
    func prompt(target: String, text: String) async throws {
        lock.lock(); events.append(text); lock.unlock()
        onPrompt(text)
    }
}

final class ConversationRestartTests: XCTestCase {
    private var dir: TempDir!
    private var pane: FakePane!
    private var log: ActionLog!
    private var file: URL!

    override func setUpWithError() throws {
        dir = try TempDir()
        pane = FakePane()
        log = ActionLog(fileURL: dir.url.appendingPathComponent("actions.log"))
        file = dir.url.appendingPathComponent("data/pm-handoff.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func restart(timeout: Duration = .seconds(2)) -> ConversationRestart {
        ConversationRestart(adapter: pane, commander: pane, log: log, handoffFile: file, project: "demo",
                            timing: .init(poll: .milliseconds(1), handoff: timeout, session: timeout))
    }

    /// The agent writes the note when asked, goes back to idle, and starts a new session after /clear.
    private func playAgent() {
        let file = file!
        pane.onPrompt = { [unowned pane] text in
            guard let pane else { return }
            if text.contains("hand-off") && text.contains(file.path) { try? "- doing X\n".write(to: file, atomically: true, encoding: .utf8) }
            if text == "/clear" { pane.session = "new" }
        }
    }

    func testHandoffAsksWritesClearsAndStartsTheNewConversation() async throws {
        playAgent()
        let new = try await restart().run(.handoff, pane: "w2:p1", session: "old", progress: { _ in })
        XCTAssertEqual(new, "new")
        XCTAssertEqual(pane.events.count, 3)
        XCTAssertTrue(pane.events[0].contains(file.path), "the prompt names the file")
        XCTAssertEqual(pane.events[1], "/clear")
        XCTAssertEqual(pane.events[2], "Read \(file.path) and your project's roadmap, then continue as the PM.")
        let lines = log.read()
        XCTAssertTrue(lines.contains("[demo] hand-off requested"), lines)
        XCTAssertTrue(lines.contains("hand-off written"), lines)
        XCTAssertTrue(lines.contains("conversation cleared"), lines)
        XCTAssertTrue(lines.contains("new conversation started"), lines)
    }

    func testClearWaitsUntilTheFileChangedAndTheAgentIsIdle() async throws {
        try "old note".write(to: file, atomically: true, encoding: .utf8)
        // The agent answers late: first still working, file unchanged.
        pane.onPrompt = { [unowned pane, file] text in
            guard text.contains("hand-off") else { if text == "/clear" { pane?.session = "new" }; return }
            pane?.state = .working
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                try? "new note".write(to: file!, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .milliseconds(20))
                pane?.state = .idle
            }
        }
        _ = try await restart().run(.handoff, pane: "w2:p1", session: "old", progress: { _ in })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new note")
        XCTAssertEqual(pane.events[1], "/clear")
    }

    func testNoClearWhenTheAgentNeverWritesTheHandoff() async throws {
        pane.onPrompt = { _ in }
        do {
            _ = try await restart(timeout: .milliseconds(30)).run(.handoff, pane: "w2:p1", session: "old", progress: { _ in })
            XCTFail("expected a timeout")
        } catch let error as ConversationRestart.Failure {
            XCTAssertTrue(error.message.contains("hand-off"), error.message)
        }
        XCTAssertEqual(pane.events.count, 1, "nothing but the request was sent")
    }

    func testWithoutHandoffOnlyClearIsSent() async throws {
        playAgent()
        let new = try await restart().run(.clear, pane: "w2:p1", session: "old", progress: { _ in })
        XCTAssertEqual(new, "new")
        XCTAssertEqual(pane.events, ["/clear"])
    }

    func testCompactSendsCompactAndKeepsTheSession() async throws {
        let new = try await restart().run(.compact, pane: "w2:p1", session: "old", progress: { _ in })
        XCTAssertNil(new)
        XCTAssertEqual(pane.events, ["/compact"])
    }

    func testRefusedWhileWorkingOrBlockedOrGone() async throws {
        for state in [AgentState.working, .blocked] {
            pane.state = state
            do { _ = try await restart().run(.clear, pane: "w2:p1", session: "old", progress: { _ in }); XCTFail("expected a refusal") }
            catch let error as ConversationRestart.Failure { XCTAssertFalse(error.message.isEmpty) }
        }
        pane.state = .idle; pane.present = false
        do { _ = try await restart().run(.clear, pane: "w2:p1", session: "old", progress: { _ in }); XCTFail("expected a refusal") }
        catch is ConversationRestart.Failure {}
        pane.present = true; pane.session = "other"
        do { _ = try await restart().run(.clear, pane: "w2:p1", session: "old", progress: { _ in }); XCTFail("a reused pane is not the same agent") }
        catch is ConversationRestart.Failure {}
        XCTAssertTrue(pane.events.isEmpty)
    }

    func testFailsWhenNoNewSessionShowsUp() async throws {
        pane.onPrompt = { _ in }
        do { _ = try await restart(timeout: .milliseconds(30)).run(.clear, pane: "w2:p1", session: "old", progress: { _ in }); XCTFail("expected a failure") }
        catch let error as ConversationRestart.Failure { XCTAssertTrue(error.message.contains("new conversation"), error.message) }
    }
}

@MainActor
final class PanelRestartTests: XCTestCase {
    private var dir: TempDir!
    private var pane: FakePane!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = try TempDir()
        pane = FakePane()
        defaults = makeTestDefaults()
    }

    private func makeModel() async throws -> PanelModel {
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: todo\nagent:\nbranch: pilot/a5\nfiles:\n  - App/A5.swift\n---\n# A5 · Title\n\n## Goal\nGoal.\n")
        let project = try dir.write("p/demo.json", """
        {"id":"demo","name":"Demo","repoPath":"/repo","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"b","sharedFiles":[],"openWith":"Xcode"}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"]}")
        let p = pane!
        let m = PanelModel(settingsURL: settings, makeTerminal: { p }, opener: RecordingOpener(),
                           makeScripts: { _ in FakeScripts() }, makeCommander: { p }, log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                           defaults: defaults, roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")))
        m.restartTiming = .init(poll: .milliseconds(1), handoff: .seconds(2), session: .seconds(2))
        await m.reload()
        await m.refreshAgents()
        return m
    }

    private var handoffFile: URL { dir.url.appendingPathComponent("data/pm-handoff.md") }

    private func playAgent() {
        let file = handoffFile
        pane.onPrompt = { [unowned pane] text in
            if text.contains("hand-off") { try? "- note\n".write(to: file, atomically: true, encoding: .utf8) }
            if text == "/clear" { pane?.session = "new" }
        }
    }

    func testTheRememberedPMAndTheTargetFollowThePaneToItsNewSession() async throws {
        playAgent()
        let m = try await makeModel()
        m.setPMSession("old", forProject: "demo")
        let agent = try XCTUnwrap(m.pmAgent(forProject: "demo"))
        let result = await m.restartConversation(.handoff, agent: agent)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(m.pmSession(forProject: "demo"), "new")
        XCTAssertEqual(m.rememberedTarget, "w2:p1|new")
        XCTAssertEqual(m.restartedSession, "new")
        XCTAssertEqual(pane.events.count, 3)
    }

    func testTheOldThreadStaysAsThePreviousConversation() async throws {
        playAgent()
        let m = try await makeModel()
        let root = dir.url.appendingPathComponent("claude")
        let file = TranscriptReader.path(projectsRoot: root, cwd: "/repo", session: "old")
        try dir.write(file.path.replacingOccurrences(of: dir.url.path + "/", with: ""),
                      #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello"}}"# + "\n")
        let session = m.chats.session(project: "demo", pane: "w2:p1", projectsRoot: root)
        await session.chat.refresh(agent: try XCTUnwrap(m.pmAgent(forProject: "demo")), viewing: true)
        XCTAssertEqual(session.chat.entries.map(\.text), ["hello"])
        let result = await m.restartConversation(.clear, agent: try XCTUnwrap(m.pmAgent(forProject: "demo")))
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(session.previous.map(\.text), ["hello"])
    }

    func testRefusedWhileTheAgentWorksAndNothingIsSent() async throws {
        let m = try await makeModel()
        pane.state = .working
        await m.refreshAgents()
        let result = await m.restartConversation(.handoff, agent: try XCTUnwrap(m.pmAgent(forProject: "demo")))
        guard case .failed = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertTrue(pane.events.isEmpty)
    }

    func testAFailedRestartKeepsTheOldSessionAndShowsTheReason() async throws {
        pane.onPrompt = { _ in }
        let m = try await makeModel()
        m.restartTiming = .init(poll: .milliseconds(1), handoff: .milliseconds(30), session: .milliseconds(30))
        m.setPMSession("old", forProject: "demo")
        let result = await m.restartConversation(.clear, agent: try XCTUnwrap(m.pmAgent(forProject: "demo")))
        guard case .failed = result, case .failed = m.actionState else { return XCTFail("expected a failure") }
        XCTAssertEqual(m.pmSession(forProject: "demo"), "old")
        XCTAssertNil(m.restartedSession)
    }

    func testCompactKeepsTheSessionAndTheThread() async throws {
        let m = try await makeModel()
        let result = await m.restartConversation(.compact, agent: try XCTUnwrap(m.pmAgent(forProject: "demo")))
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(pane.events, ["/compact"])
        XCTAssertTrue(m.chats.session(project: "demo", pane: "w2:p1").previous.isEmpty)
    }

    func testTheSheetListsTheThreeChoicesWithHandoffFirst() throws {
        XCTAssertEqual(RestartMode.allCases, [.handoff, .clear, .compact])
        XCTAssertTrue(RestartMode.handoff.title.contains("recommended"))
        let data = try XCTUnwrap(SnapshotRenderer.render(view: NewConversationSheet(agentLabel: "pm-demo", onStart: { _ in }, onCancel: {}), size: CGSize(width: 520, height: 420)))
        XCTAssertGreaterThan(data.count, 5_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }
}

/// Plays `pgrep -fl pm-serial-merge.sh`: output while `running`, else pgrep's "no match" failure.
fileprivate final class FakeMerge: CommandRunner, @unchecked Sendable {
    var running = false
    var arguments: [String] = []
    func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
        self.arguments = arguments
        if running { return Data("99 /bin/bash /x/pm-serial-merge.sh /data/demo/tasks N1\n".utf8) }
        throw ProcessRunner.Failure(message: "exit 1")
    }
}

// MARK: fresh conversation with hand-off (N171)

@MainActor
final class FreshStartRuleTests: XCTestCase {
    private func agent(_ state: AgentState) -> AgentStatus { AgentStatus(paneID: "w2:p1", workspaceID: "w2", state: state, cwd: "/repo", title: "pm-demo", sessionID: "old", name: "pm-demo") }

    func testTheRuleIsOnByDefaultSurvivesAFileRoundTripAndAnOldFile() throws {
        XCTAssertTrue(AutopilotPolicy().freshConversation)
        XCTAssertTrue(try JSONDecoder().decode(AutopilotPolicy.self, from: Data("{}".utf8)).freshConversation)
        var p = AutopilotPolicy(); p.freshConversation = false
        let back = try JSONDecoder().decode(AutopilotPolicy.self, from: JSONEncoder().encode(p))
        XCTAssertFalse(back.freshConversation)
    }

    func testOnlyAnIdlePMWithNoQuestionAndNoActionRunningMayRestart() {
        func block(rule: Bool = true, pm: AgentStatus?, question: Bool = false, busy: Bool = false, merge: Bool = false) -> FreshStart.Block? {
            FreshStart.blocker(ruleOn: rule, pm: pm, hasQuestion: question, busy: busy, mergeRunning: merge)
        }
        XCTAssertNil(block(pm: agent(.idle)))
        XCTAssertNil(block(pm: agent(.done)))
        XCTAssertEqual(block(rule: false, pm: agent(.idle)), .never)
        XCTAssertEqual(block(pm: nil), .never)
        XCTAssertEqual(block(pm: agent(.working)), .wait)
        XCTAssertEqual(block(pm: agent(.blocked)), .wait)
        XCTAssertEqual(block(pm: agent(.unknown("?"))), .wait)
        XCTAssertEqual(block(pm: agent(.idle), question: true), .wait, "an open PM question is never cleared")
        XCTAssertEqual(block(pm: agent(.idle), busy: true), .wait)
        XCTAssertEqual(block(pm: agent(.idle), merge: true), .wait, "a running merge is never cut off")
        XCTAssertEqual(block(rule: false, pm: agent(.idle), merge: true), .never)
    }

    func testAMergeProcessIsRecognisedByThisProjectsPaths() {
        let mine = "123 /bin/bash /x/pm-serial-merge.sh /data/demo/tasks N1 N2"
        let other = "124 /bin/bash /x/pm-serial-merge.sh /data/other/tasks N9"
        let anon = "125 /bin/bash /x/pm-serial-merge.sh"
        let paths = ["/data/demo", "/repo/demo", "/data/other", "/repo/other"]
        func running(_ out: String) -> Bool { FreshStart.mergeRunning(output: out, ownPaths: ["/data/demo", "/repo/demo"], allPaths: paths) }
        XCTAssertTrue(running(mine))
        XCTAssertFalse(running(other), "another project's merge")
        XCTAssertTrue(running(anon), "a merge that names no project could be this one")
        XCTAssertTrue(running(other + "\n" + mine))
        XCTAssertFalse(running(""))
    }

    func testARoundIsFinishedWhenEveryCardIsDoneAndCancelledOnesDoNotCount() {
        func card(_ id: String, _ s: TaskStatus) -> TaskCard {
            TaskCard(id: id, project: "d", status: s, agent: nil, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        }
        let plan = PlanFile(rounds: [PlanRound(name: "R1", cards: ["A", "B"], reason: "", status: "done"), PlanRound(name: "R2", cards: ["C"], reason: "", status: ""),
                                     PlanRound(name: "R3", cards: [], reason: "", status: ""), PlanRound(name: "R4", cards: ["X"], reason: "", status: "")], questions: [])
        let cards = [card("A", .done), card("B", .cancelled), card("C", .review)]
        XCTAssertEqual(FreshStart.finishedRounds(plan: plan, cards: cards), ["R1"], "a review card is not done; an empty round and an unknown card never finish")
        XCTAssertEqual(FreshStart.finishedRounds(plan: nil, cards: cards), [])
        XCTAssertEqual(FreshStart.finishedRounds(plan: PlanFile(rounds: [PlanRound(name: "R", cards: ["B"], reason: "", status: "")], questions: []), cards: cards), [], "only cancelled cards: nothing was done")
    }

    func testContextWindowByModelAndTheReminderThreshold() {
        XCTAssertEqual(FreshStart.contextWindow(model: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(FreshStart.contextWindow(model: "claude-sonnet-5-5"), 1_000_000)
        XCTAssertEqual(FreshStart.contextWindow(model: "claude-opus-4-1"), 200_000)
        XCTAssertEqual(FreshStart.contextWindow(model: "claude-haiku-5-5"), 200_000)
        XCTAssertEqual(FreshStart.contextWindow(model: "claude-opus-4-1[1m]"), 1_000_000)
        XCTAssertEqual(FreshStart.reminderThreshold, 0.7)
        XCTAssertFalse(FreshStart.shouldRemind(fraction: 0.699))
        XCTAssertTrue(FreshStart.shouldRemind(fraction: 0.7))
        XCTAssertFalse(FreshStart.shouldRemind(fraction: nil))
    }

    func testContextUseIsTheLastReplysInputAndCacheTokens() throws {
        let dir = try TempDir()
        let line: (String, Int, Int, Int) -> String = { id, i, w, r in
            #"{"type":"assistant","uuid":"\#(id)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(i),"output_tokens":9,"cache_creation_input_tokens":\#(w),"cache_read_input_tokens":\#(r)}}}"# + "\n"
        }
        let file = try dir.write("s.jsonl", line("a", 1, 100, 1000) + #"{"type":"user","uuid":"u","message":{"role":"user","content":"hi"}}"# + "\n" + line("b", 5, 200_000, 600_000))
        let use = try XCTUnwrap(CostReader.contextUse(file))
        XCTAssertEqual(use.tokens, 800_005)
        XCTAssertEqual(use.model, "claude-opus-5-5")
        XCTAssertEqual(use.fraction, 0.800005, accuracy: 1e-9)
        XCTAssertNil(CostReader.contextUse(dir.url.appendingPathComponent("missing.jsonl")))
    }

    func testReminderViewRendersWithItsText() throws {
        XCTAssertEqual(PMContextReminder.text, "The PM's conversation is large: restart with hand-off")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: PMContextReminder(percent: 74).frame(width: 640), size: CGSize(width: 640, height: 56)))
        XCTAssertGreaterThan(data.count, 2_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }
}

@MainActor
final class PanelFreshStartTests: XCTestCase {
    private var dir: TempDir!
    private var pane: FakePane!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = try TempDir()
        pane = FakePane()
        defaults = makeTestDefaults()
    }

    private var data: URL { dir.url.appendingPathComponent("data") }
    private var handoffFile: URL { data.appendingPathComponent("pm-handoff.md") }

    private func writeCard(_ id: String, _ status: String) throws {
        try dir.write("data/tasks/\(id).md", "---\nid: \(id)\nproject: demo\nstatus: \(status)\nagent:\nbranch: pilot/\(id.lowercased())\nfiles:\n  - App/\(id).swift\n---\n# \(id) · Title\n\n## Goal\nGoal.\n")
    }

    private func writePlan(_ cards: [String]) throws {
        try dir.write("data/plan.json", #"{"rounds":[{"name":"R1","cards":["\#(cards.joined(separator: "\",\""))"],"reason":"","status":""}]}"#)
    }

    private func makeModel(cardStatus: String = "doing") async throws -> PanelModel {
        try writeCard("A5", cardStatus)
        try writePlan(["A5"])
        let project = try dir.write("p/demo.json", """
        {"id":"demo","name":"Demo","repoPath":"/repo","dataDir":"\(data.path)","maxParallel":3,"buildCommand":"b","sharedFiles":[],"openWith":"Xcode"}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"]}")
        let p = pane!
        let m = PanelModel(settingsURL: settings, makeTerminal: { p }, opener: RecordingOpener(),
                           makeScripts: { _ in FakeScripts() }, makeCommander: { p }, log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                           defaults: defaults, roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")),
                           autopilotStore: AutopilotStore(folder: dir.url.appendingPathComponent("autopilot")))
        m.restartTiming = .init(poll: .milliseconds(1), handoff: .seconds(2), session: .seconds(2))
        m.claudeProjectsRoot = dir.url.appendingPathComponent("claude")
        m.usageSource = { nil }
        m.mergeRunner = FakeMerge()   // never the real pgrep: a real merge on this machine would block the restart
        m.setPMSession("old", forProject: "demo")
        await m.reload()
        await m.refreshAgents()
        return m
    }

    private func playAgent() {
        let file = handoffFile
        pane.onPrompt = { [unowned pane] text in
            if text.contains("hand-off") { try? "- note\n".write(to: file, atomically: true, encoding: .utf8) }
            if text == "/clear" { pane?.session = "new" }
        }
    }

    /// How many times the PM's conversation was cleared (the panel's own card notices to the PM are other prompts).
    private var clears: Int { pane.events.filter { $0 == "/clear" }.count }

    private func setRule(_ on: Bool, _ m: PanelModel) {
        var policy = m.autopilot.policy; policy.freshConversation = on; m.autopilot.update(policy)
    }

    func testARoundStartRestartsTheIdlePMWithHandoff() async throws {
        playAgent()
        let m = try await makeModel()
        m.round.onRoundStarted?()
        XCTAssertEqual(m.freshStartPending, .roundStart)
        await m.evaluateFreshStart()
        XCTAssertNil(m.freshStartPending)
        XCTAssertEqual(pane.events.count, 3, "hand-off request, /clear, first prompt")
        XCTAssertEqual(m.pmSession(forProject: "demo"), "new")
    }

    func testTheRuleOffNeverRestartsAndForgetsTheTrigger() async throws {
        playAgent()
        let m = try await makeModel()
        setRule(false, m)
        m.round.onRoundStarted?()
        await m.evaluateFreshStart()
        XCTAssertNil(m.freshStartPending)
        XCTAssertTrue(pane.events.isEmpty)
    }

    func testABusyPMWaitsUntilIdleAndThenRestartsOnce() async throws {
        playAgent()
        let m = try await makeModel()
        pane.state = .working
        await m.refreshAgents()
        m.round.onRoundStarted?()
        await m.evaluateFreshStart()
        XCTAssertEqual(m.freshStartPending, .roundStart, "still waiting")
        XCTAssertTrue(pane.events.isEmpty, "never in the middle of a turn")
        pane.state = .idle
        await m.refreshAgents()
        XCTAssertEqual(pane.events.count, 3, "the next poll restarts it")
        XCTAssertNil(m.freshStartPending)
        await m.evaluateFreshStart()
        XCTAssertEqual(pane.events.count, 3, "only once")
    }

    func testAFinishedRoundRestartsThePMOnceItsLastCardIsDone() async throws {
        playAgent()
        let m = try await makeModel(cardStatus: "doing")
        await m.evaluateFreshStart()
        XCTAssertNil(m.freshStartPending)
        XCTAssertEqual(clears, 0, "a round still running does not restart")
        try writeCard("A5", "done")
        await m.reload()
        await m.refreshAgents()
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(m.pmSession(forProject: "demo"), "new")
        await m.evaluateFreshStart()
        XCTAssertEqual(clears, 1, "the same round never triggers twice")
    }

    func testARoundThatWasAlreadyFinishedWhenTheAppOpenedDoesNotRestart() async throws {
        playAgent()
        let m = try await makeModel(cardStatus: "done")
        await m.evaluateFreshStart()
        XCTAssertEqual(clears, 0)
    }

    func testTheSafePointWaitsForTheRunningCardsThenRestartsOncePerReach() async throws {
        playAgent()
        let m = try await makeModel(cardStatus: "doing")
        m.usageSource = { PlanUsage(fiveHour: PlanUsage.Window(percent: 95, resetsAt: Date().addingTimeInterval(3600)), week: nil, todayCost: 0) }
        await m.refreshAgents()
        for _ in 0..<200 where !m.safePointReached { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(m.safePointReached)
        await m.evaluateFreshStart()
        XCTAssertEqual(clears, 0, "a card still runs")
        try writeCard("A5", "review")
        await m.reload()
        await m.refreshAgents()
        XCTAssertEqual(clears, 1, "no card runs any more")
        await m.evaluateFreshStart()
        XCTAssertEqual(clears, 1, "once for this reach")
    }

    func testTheContextShareOfThePMComesFromItsSessionFile() async throws {
        let m = try await makeModel()
        let file = TranscriptReader.path(projectsRoot: dir.url.appendingPathComponent("claude"), cwd: "/repo", session: "old")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"assistant","uuid":"a","message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":720000}}}"#.write(to: file, atomically: true, encoding: .utf8)
        await m.refreshPMContext()
        XCTAssertEqual(try XCTUnwrap(m.pmContextFraction), 0.72001, accuracy: 1e-6)
        XCTAssertTrue(m.pmContextLarge)
        try #"{"type":"assistant","uuid":"a","message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":300000}}}"#.write(to: file, atomically: true, encoding: .utf8)
        await m.refreshPMContext()
        XCTAssertFalse(m.pmContextLarge)
        XCTAssertTrue(pane.events.isEmpty, "size alone never restarts")
    }

    func testARunningMergeBlocksEveryTriggerAndTheyFireAfterIt() async throws {
        playAgent()
        let merge = FakeMerge()
        let m = try await makeModel(cardStatus: "doing")
        m.mergeRunner = merge
        merge.running = true
        m.usageSource = { PlanUsage(fiveHour: PlanUsage.Window(percent: 95, resetsAt: Date().addingTimeInterval(3600)), week: nil, todayCost: 0) }
        await m.refreshAgents()
        for _ in 0..<200 where !m.safePointReached { try await Task.sleep(for: .milliseconds(5)) }
        // round start
        m.round.onRoundStarted?()
        await m.evaluateFreshStart()
        XCTAssertEqual(m.freshStartPending, .roundStart)
        XCTAssertEqual(clears, 0, "round start waits for the merge")
        XCTAssertEqual(merge.arguments.first, "-fl")
        // the round finishes and the safe point holds while the merge still runs
        try writeCard("A5", "done")
        await m.reload()
        await m.refreshAgents()
        XCTAssertEqual(clears, 0, "round finished and safe point wait too")
        XCTAssertNotNil(m.freshStartPending)
        merge.running = false
        await m.refreshAgents()
        XCTAssertEqual(clears, 1, "fires once the merge is over")
        XCTAssertNil(m.freshStartPending)
        await m.refreshAgents()
        XCTAssertEqual(clears, 1, "the other triggers were folded into the one restart")
    }

    func testTheFinishedRoundAndTheSafePointEachWaitForAMerge() async throws {
        playAgent()
        let merge = FakeMerge(); merge.running = true
        let m = try await makeModel(cardStatus: "doing")
        m.mergeRunner = merge
        try writeCard("A5", "done")
        await m.reload()
        await m.refreshAgents()
        XCTAssertEqual(m.freshStartPending, .roundFinished)
        XCTAssertEqual(clears, 0)
        merge.running = false
        await m.refreshAgents()
        XCTAssertEqual(clears, 1)
        // safe point alone
        let merge2 = FakeMerge(); merge2.running = true
        let other = try await makeModel(cardStatus: "review")
        other.mergeRunner = merge2
        other.usageSource = { PlanUsage(fiveHour: PlanUsage.Window(percent: 95, resetsAt: Date().addingTimeInterval(3600)), week: nil, todayCost: 0) }
        await other.refreshAgents()
        for _ in 0..<200 where !other.safePointReached { try await Task.sleep(for: .milliseconds(5)) }
        await other.evaluateFreshStart()
        XCTAssertEqual(other.freshStartPending, .safePoint)
        let before = clears
        merge2.running = false
        await other.evaluateFreshStart()
        XCTAssertEqual(clears, before + 1)
    }
}

/// N292 (1): "New conversation…" and the PM context reminder went missing because the chosen PM no longer resolved:
/// it was chosen before its session was known (nil, kept by the poll but never equal to the later session),
/// or the user typed /clear in the terminal (a new session in the same pane, so the target was called gone).
final class ChosenAgentTests: XCTestCase {
    private func pm(_ session: String?) -> AgentStatus {
        AgentStatus(paneID: "pm-agent-panel", workspaceID: "pm-agent-panel", state: .idle, cwd: "/repo", title: "pm-agent-panel", sessionID: session, name: "pm-agent-panel")
    }

    func testAnAgentChosenWithoutASessionStillResolves() {
        let chosen = ChosenTarget(paneID: "pm-agent-panel", sessionID: nil, label: "pm")
        XCTAssertEqual(ChosenAgent.resolve(chosen, in: [pm("s2")])?.sessionID, "s2")
        XCTAssertEqual(ChosenAgent.followed(chosen, in: [pm("s2")], follows: { _ in false })?.sessionID, "s2", "the first session is always taken")
    }

    func testAClearInTheTerminalIsFollowedForAFreeAgent() {
        let chosen = ChosenTarget(paneID: "pm-agent-panel", sessionID: "s1", label: "pm")
        XCTAssertNil(ChosenAgent.resolve(chosen, in: [pm("s2")]), "an old session does not match")
        let next = ChosenAgent.followed(chosen, in: [pm("s2")], follows: { _ in true })
        XCTAssertEqual(next, ChosenTarget(paneID: "pm-agent-panel", sessionID: "s2", label: "pm"))
        XCTAssertEqual(ChosenAgent.resolve(next, in: [pm("s2")])?.paneID, "pm-agent-panel")
        XCTAssertNil(ChosenAgent.followed(chosen, in: [pm("s2")], follows: { _ in false }), "an agent on a card is not followed")
        XCTAssertNil(ChosenAgent.followed(chosen, in: [pm("s1")], follows: { _ in true }), "nothing changed")
        XCTAssertNil(ChosenAgent.followed(chosen, in: [], follows: { _ in true }), "the pane is gone")
    }
}

/// N368: a Codex PM is restarted (stop + spawn + hand-off as first prompt), never typed at; a Claude PM is unchanged.
@MainActor
final class CodexPMRestartTests: XCTestCase {
    private var dir: TempDir!
    private var pane: FakePane!
    private var scripts: FakeScripts!

    override func setUpWithError() throws { dir = try TempDir(); pane = FakePane(); scripts = FakeScripts() }

    private func makeModel(pmTool: String?) async throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        let toolKey = pmTool.map { "\"tool\":\"\($0)\"," } ?? ""
        try dir.write("roles/pm.json", "{\"name\":\"pm\",\"kind\":\"interactive\",\(toolKey)\"model\":\"m\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"pm.md\"}")
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: todo\nagent:\nbranch: pilot/a5\nfiles:\n  - a\n---\n# A5 · Title\n")
        let project = try dir.write("p/demo.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":3,\"buildCommand\":\"b\",\"sharedFiles\":[],\"openWith\":\"Xcode\",\"roles\":{\"pm\":\"\(dir.url.appendingPathComponent("roles/pm.json").path)\"}}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let gate = SignInGate(check: { _ in true }, findTool: { URL(fileURLWithPath: "/fake/bin/\($0)") }, spawn: { _, _ in }, exitCode: { _ in 0 }, open: { _ in })
        let p = pane!, s = scripts!
        let m = PanelModel(settingsURL: settings, makeTerminal: { p }, opener: RecordingOpener(), makeScripts: { _ in s }, makeCommander: { p },
                           log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")), defaults: makeTestDefaults(),
                           roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-base-roles")), signInGate: gate)
        m.restartTiming = .init(poll: .milliseconds(1), handoff: .seconds(2), session: .seconds(2))
        m.codexSessionsRoot = dir.url.appendingPathComponent("codex")
        m.claudeProjectsRoot = dir.url.appendingPathComponent("claude")
        m.usageSource = { nil }
        m.setPMSession("old", forProject: "demo")
        await m.reload(); await m.refreshAgents()
        return m
    }

    private func rollout(_ id: String, tokens: Int? = nil) throws {
        var text = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/repo\"}}\n"
        if let tokens { text += "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(tokens)},\"model_context_window\":200000}}}\n" }
        try dir.write("codex/2026/11/03/rollout-2026-11-03T10-00-00-\(id).jsonl", text)
    }

    private func play() {
        let file = dir.url.appendingPathComponent("data/pm-handoff.md")
        pane.onPrompt = { text in if text.contains("hand-off") && text.contains(file.path) { try? "- note\n".write(to: file, atomically: true, encoding: .utf8) } }
        let rolloutNew = dir.url.appendingPathComponent("codex/2026/11/03/rollout-2026-11-03T11-00-00-new.jsonl")
        try? FileManager.default.createDirectory(at: rolloutNew.deletingLastPathComponent(), withIntermediateDirectories: true)
        scripts.handler = { [unowned pane] script, _ in
            if script == .stop { pane?.present = false }
            if script == .spawn {
                pane?.present = true; pane?.session = "new"
                try? "{\"type\":\"session_meta\",\"payload\":{\"id\":\"new\",\"cwd\":\"/repo\"}}\n".write(to: rolloutNew, atomically: true, encoding: .utf8)
            }
            return ScriptResult(status: 0, stdout: script == .spawn ? "{\"pane_id\":\"w2:p1\"}\n" : "", stderr: "")
        }
    }

    func testACodexPMIsStoppedAndSpawnedAgainWithTheHandoffAsFirstPrompt() async throws {
        try rollout("old")
        let m = try await makeModel(pmTool: "codex")
        play()
        let pm = try XCTUnwrap(m.pmAgent(forProject: "demo"))
        let result = await m.restartConversation(.handoff, agent: pm)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(scripts.calls(of: .stop).count, 1)
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1)
        XCTAssertEqual(scripts.calls(of: .spawn).first?.args.first, "--no-card", "spawned on no card")
        XCTAssertEqual(pane.events.count, 2, "hand-off request, then the first prompt")
        XCTAssertTrue(pane.events[1].contains("pm-handoff.md"))
        XCTAssertFalse(pane.events.contains { $0.hasPrefix("/") }, "no slash command typed into a Codex pane")
        XCTAssertEqual(m.pmSession(forProject: "demo"), "new")
    }

    func testACodexPMWithoutHandoffIsRestartedEmptyAndCompactIsRefused() async throws {
        let m = try await makeModel(pmTool: "codex")
        play()
        let pm = try XCTUnwrap(m.pmAgent(forProject: "demo"))
        XCTAssertFalse(m.restartModes(for: pm).contains(.compact))
        let refused = await m.restartConversation(.compact, agent: pm)
        guard case .failed = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(scripts.calls.isEmpty && pane.events.isEmpty)
        let result = await m.restartConversation(.clear, agent: pm)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(scripts.calls(of: .spawn).count, 1)
        XCTAssertTrue(pane.events.isEmpty, "nothing typed")
    }

    // Claude golden: a PM with no tool, or tool claude, is restarted by typing /clear and /compact, never by stop + spawn.
    func testAClaudePMIsStillRestartedByTypingAndKeepsAllThreeModes() async throws {
        for tool in [nil, "claude"] {
            pane = FakePane(); scripts = FakeScripts()
            let m = try await makeModel(pmTool: tool)
            let file = dir.url.appendingPathComponent("data/pm-handoff.md")
            pane.onPrompt = { [unowned pane] text in
                if text.contains("hand-off") { try? "- note\n".write(to: file, atomically: true, encoding: .utf8) }
                if text == "/clear" { pane?.session = "new" }
            }
            let pm = try XCTUnwrap(m.pmAgent(forProject: "demo"))
            XCTAssertEqual(m.restartModes(for: pm), RestartMode.allCases)
            let result = await m.restartConversation(.handoff, agent: pm)
            XCTAssertEqual(result, .ok)
            XCTAssertEqual(pane.events.count, 3)
            XCTAssertEqual(pane.events[1], "/clear")
            XCTAssertTrue(scripts.calls.isEmpty, "no stop, no spawn")
            let compact = await m.restartConversation(.compact, agent: try XCTUnwrap(m.pmAgent(forProject: "demo")))
            XCTAssertEqual(compact, .ok)
            XCTAssertEqual(pane.events.last, "/compact")
        }
    }

    func testCodexContextFillComesFromTheLastTokenCountAndUnknownIsHidden() async throws {
        try rollout("old", tokens: 150_000)
        let m = try await makeModel(pmTool: "codex")
        await m.refreshPMContext()
        XCTAssertEqual(try XCTUnwrap(m.pmContextFraction), 0.75, accuracy: 1e-9)
        XCTAssertTrue(m.pmContextLarge)
        try rollout("old")   // no token_count line
        await m.refreshPMContext()
        XCTAssertNil(m.pmContextFraction)
    }
}
