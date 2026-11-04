import XCTest
@testable import AgentPanel

@MainActor
final class ReviewStateTests: XCTestCase {
    private let head = "0123456789abcdef0123456789abcdef01234567"
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
    }

    // MARK: button states

    private func card(_ status: TaskStatus, kind: String? = nil, packet: String = "") -> TaskCard {
        TaskCard(id: "A5", project: "demo", status: status, agent: "dev-a5", branch: "pilot/a5", kind: kind, files: ["a"], title: "A5",
                 sections: packet.isEmpty ? [:] : ["Review packet": packet], url: URL(fileURLWithPath: "/tmp/A5.md"))
    }
    private let good = "Head: abc\n\nBuild: passed (`b`), log: /l\n\nScreenshots:\n- tasks/A5/shots/a.png\n"

    func testEveryButtonIsOffWhileAnotherActionRuns() {
        let s = reviewButtonStates(card: card(.review, packet: good), canAct: true, reason: nil, busy: true)
        for state in [s.prepare, s.approve, s.requestFix] {
            XCTAssertFalse(state.enabled)
            XCTAssertTrue(state.help.contains("running"), state.help)
        }
        let orphan = reviewButtonStates(card: card(.review, packet: good), canAct: true, reason: nil, worktreeExists: false, busy: true)
        XCTAssertFalse(orphan.close.enabled)
        XCTAssertTrue(reviewButtonStates(card: card(.doing), canAct: true, reason: nil, busy: false).prepare.enabled, "idle: unchanged")
        let start = startButtonState(card: card(.todo), canStart: true, reason: nil, busy: true)
        XCTAssertFalse(start.enabled)
        XCTAssertTrue(start.help.contains("running"))
        XCTAssertTrue(startButtonState(card: card(.todo), canStart: true, reason: nil).enabled)
    }

    func testPrepareIsOffWhileTheCardsAgentIsWorking() {
        let working = reviewButtonStates(card: card(.doing), canAct: true, reason: nil, agentWorking: true)
        XCTAssertFalse(working.prepare.enabled)
        XCTAssertTrue(working.prepare.help.contains("working"), working.prepare.help)
        XCTAssertTrue(working.requestFix.enabled, "only Prepare waits for the agent")
        XCTAssertTrue(reviewButtonStates(card: card(.doing), canAct: true, reason: nil, agentWorking: false).prepare.enabled)
    }

    func testPrepareReviewAlsoFromReviewToRebuildAMissingOrStalePacket() {
        XCTAssertTrue(reviewButtonStates(card: card(.review), canAct: true, reason: nil).prepare.enabled)
    }

    func testPrepareReviewOnlyForDoingOrNeedsFix() {
        for s: TaskStatus in [.doing, .needsFix] { XCTAssertTrue(reviewButtonStates(card: card(s), canAct: true, reason: nil).prepare.enabled, "\(s)") }
        for s: TaskStatus in [.todo, .awaitingStartApproval, .done, .blocked, .cancelled, .unknown("x")] {
            let state = reviewButtonStates(card: card(s), canAct: true, reason: nil).prepare
            XCTAssertFalse(state.enabled, "\(s)")
            XCTAssertFalse(state.help.isEmpty)
        }
    }

    func testApproveNeedsReviewStatusAndEvidence() {
        XCTAssertTrue(reviewButtonStates(card: card(.review, packet: good), canAct: true, reason: nil).approve.enabled)
        XCTAssertFalse(reviewButtonStates(card: card(.doing, packet: good), canAct: true, reason: nil).approve.enabled)
        XCTAssertFalse(reviewButtonStates(card: card(.review), canAct: true, reason: nil).approve.enabled, "no packet")
        let failed = reviewButtonStates(card: card(.review, packet: "Head: abc\n\nBuild: failed\n\nScreenshots:\n- a.png\n"), canAct: true, reason: nil).approve
        XCTAssertFalse(failed.enabled)
        XCTAssertTrue(failed.help.contains("build"))
        let noShots = reviewButtonStates(card: card(.review, packet: "Head: abc\n\nBuild: passed (`b`)\n"), canAct: true, reason: nil).approve
        XCTAssertFalse(noShots.enabled)
        XCTAssertTrue(noShots.help.contains("screenshot"))
    }

    func testApproveNeedsNoBuildOrScreenshotsWhenThePacketSaysTheProjectHasNone() {
        let bare = "Head: abc\n\nBuild: none (this project has no build command)\n\nScreenshots: not used in this project\n"
        XCTAssertTrue(reviewButtonStates(card: card(.review, packet: bare), canAct: true, reason: nil).approve.enabled)
    }

    func testAnalysisApproveNeedsNoBuildOrScreenshots() {
        XCTAssertTrue(reviewButtonStates(card: card(.review, kind: "analysis", packet: "Head: abc\n\nAnalysis task: no build or screenshots needed.\n"), canAct: true, reason: nil).approve.enabled)
        XCTAssertFalse(reviewButtonStates(card: card(.review, kind: "analysis"), canAct: true, reason: nil).approve.enabled)
    }

    func testCloseTaskIsOfferedOnlyForOrphans() {
        func close(_ c: TaskCard, exists: Bool = true) -> StartButtonState { reviewButtonStates(card: c, canAct: true, reason: nil, worktreeExists: exists).close }
        XCTAssertFalse(close(card(.review)).enabled, "agent and worktree are there")
        XCTAssertTrue(close(card(.review), exists: false).enabled, "worktree is gone")
        let noAgent = TaskCard(id: "A5", project: "demo", status: .doing, agent: nil, branch: "pilot/a5", kind: nil, files: [], title: "A5", sections: [:], url: URL(fileURLWithPath: "/tmp/A5.md"))
        XCTAssertTrue(close(noAgent).enabled)
        let noBranch = TaskCard(id: "A5", project: "demo", status: .needsFix, agent: "dev-a5", branch: nil, kind: nil, files: [], title: "A5", sections: [:], url: URL(fileURLWithPath: "/tmp/A5.md"))
        XCTAssertTrue(close(noBranch).enabled)
        XCTAssertFalse(close(card(.done), exists: false).enabled)
        XCTAssertFalse(close(card(.todo), exists: false).enabled)
        XCTAssertFalse(reviewButtonStates(card: card(.review), canAct: false, reason: "x", worktreeExists: false).close.enabled)
    }

    func testRequestFixForDoingNeedsFixAndReview() {
        for s: TaskStatus in [.doing, .needsFix] { XCTAssertTrue(reviewButtonStates(card: card(s), canAct: true, reason: nil).requestFix.enabled, "\(s)") }
        XCTAssertTrue(reviewButtonStates(card: card(.review, packet: good), canAct: true, reason: nil).requestFix.enabled)
        for s: TaskStatus in [.todo, .done, .cancelled] { XCTAssertFalse(reviewButtonStates(card: card(s), canAct: true, reason: nil).requestFix.enabled, "\(s)") }
    }

    func testEverythingClosedWithAReasonWhenSetupIsMissing() {
        let s = reviewButtonStates(card: card(.review, packet: good), canAct: false, reason: "Set scriptsDir.")
        for state in [s.prepare, s.approve, s.requestFix] { XCTAssertFalse(state.enabled); XCTAssertEqual(state.help, "Set scriptsDir.") }
    }

    // MARK: model actions

    private func makeModel(status: String, agents: [AgentStatus] = [], packetHead: String? = nil, kind: String? = nil) throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        let k = kind.map { "kind: \($0)\n" } ?? ""
        let packet = "Head: \(packetHead ?? head)\n\nBuild: passed (`b`), log: /l\n\nScreenshots:\n- tasks/A5/shots/a.png\n"
        try dir.write("data/tasks/A5.md", "---\nid: A5\nproject: demo\nstatus: \(status)\nagent: dev-a5\nbranch: pilot/a5\n\(k)files:\n  - a\n---\n# A5 · T\n\n## Report\nDone.\n\n## Review packet\n\n\(packet)\n## Decision\n")
        let project = try dir.write("p/demo.json", """
        {"id":"demo","name":"Demo","repoPath":"/repo","dataDir":"\(dir.url.appendingPathComponent("data").path)","maxParallel":3,
         "buildCommand":"b","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"}
        """)
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let terminal = FakeTerminal(agentsResult: .success(agents))
        let s = scripts!, c = commander!
        scripts.handler = { [head] script, args in
            switch script {
            case .sim: return ScriptResult(status: 0, stdout: "UDID-1\n", stderr: "")
            case .merge where args.first == "--inspect":
                return ScriptResult(status: 0, stdout: "{\"head\":\"\(head)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":1,\"behind\":0,\"dirtyOverlap\":[],\"worktreeDirty\":false}", stderr: "")
            case .merge: return ScriptResult(status: 0, stdout: "{\"merged\":\"\(head)\"}", stderr: "")
            default: return ScriptResult(status: 0, stdout: "", stderr: "")
            }
        }
        return PanelModel(settingsURL: settings, makeTerminal: { terminal }, opener: RecordingOpener(), makeScripts: { _ in s }, makeCommander: { c },
                          log: ActionLog(fileURL: dir.url.appendingPathComponent("actions.log")),
                          defaults: makeTestDefaults(),
                          roleStore: RoleStore(baseDir: dir.url.appendingPathComponent("no-roles")))
    }

    private func a5(_ m: PanelModel) throws -> TaskCard {
        try XCTUnwrap(m.cards.compactMap { r -> TaskCard? in if case .card(let c) = r { return c } else { return nil } }.first)
    }

    func testReviewDisabledReasonNamesTheMissingSetup() async throws {
        let m = try makeModel(status: "review")
        XCTAssertNotNil(m.reviewDisabledReason, "before the projects are loaded")
        await m.reload()
        XCTAssertNil(m.reviewDisabledReason)
    }

    func testPrepareReviewReportsDoneAndRunsTheScripts() async throws {
        let m = try makeModel(status: "doing")
        await m.reload()
        await m.prepareReview(try a5(m))
        guard case .done = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertEqual(scripts.calls.map(\.script), [.sim, .reviewPacket])
    }

    func testPrepareReviewShowsTheScriptMessageWhenEvidenceIsMissing() async throws {
        let m = try makeModel(status: "doing")
        scripts.handler = { script, _ in script == .sim ? ScriptResult(status: 0, stdout: "U\n", stderr: "") : ScriptResult(status: 1, stdout: "EVIDENCE MISSING: screenshot\n", stderr: "") }
        await m.reload()
        await m.prepareReview(try a5(m))
        guard case .failed(let message) = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertTrue(message.contains("EVIDENCE MISSING: screenshot"))
    }

    func testApprovalPlanFailureIsReturnedNotThrown() async throws {
        let m = try makeModel(status: "review", packetHead: String(repeating: "f", count: 40))
        await m.reload()
        guard case .failure(let error) = await m.approvalPlan(for: try a5(m)) else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .stale)
    }

    func testConfirmApproveMarksTheCardDoneAndRefreshes() async throws {
        let m = try makeModel(status: "review")
        await m.reload()
        guard case .success(let plan) = await m.approvalPlan(for: try a5(m)) else { return XCTFail("expected a plan") }
        await m.confirmApprove(plan)
        guard case .done = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertEqual(try a5(m).status, .done)
        XCTAssertEqual(m.mergeQueue.items.last?.card, "A5")   // N209: Approve goes through the merge queue
        XCTAssertEqual(m.mergeQueue.items.last?.state, .done(detail: String(plan.head.prefix(7))))
    }

    func testConfirmApproveShowsPartialFailureAsFailedWithTheManualSteps() async throws {
        let m = try makeModel(status: "review")
        await m.reload()
        guard case .success(let plan) = await m.approvalPlan(for: try a5(m)) else { return XCTFail("expected a plan") }
        let inspect = scripts.handler
        scripts.handler = { script, args in script == .stop ? ScriptResult(status: 1, stdout: "", stderr: "ERROR: could not remove worktree") : try await inspect(script, args) }
        await m.confirmApprove(plan)
        guard case .failed(let message) = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertTrue(message.contains("merged"))
        XCTAssertTrue(message.contains("stop-agent.sh"))
        XCTAssertEqual(try a5(m).status, .done)
    }

    func testSendFixRequestMovesCardToNeedsFixAndReturnsTrue() async throws {
        var agent = AgentStatus(paneID: "wA:p1", workspaceID: "wA", state: .idle, cwd: "/repo/.agent-worktrees/pilot-a5", title: "a5", sessionID: "s"); agent.name = "dev-a5"
        let m = try makeModel(status: "review", agents: [agent])
        await m.reload()
        let sent = await m.sendFixRequest(try a5(m), notes: "Make the title bigger.")
        XCTAssertTrue(sent)
        XCTAssertEqual(try a5(m).status, .needsFix)
        XCTAssertEqual(commander.prompts.count, 1)
    }

    func testSendFixRequestReturnsFalseAndShowsWhyWhenTheAgentIsGone() async throws {
        let m = try makeModel(status: "review", agents: [])
        await m.reload()
        let sent = await m.sendFixRequest(try a5(m), notes: "x")
        XCTAssertFalse(sent)
        guard case .failed(let message) = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertTrue(message.contains("no longer running"))
        XCTAssertEqual(try a5(m).status, .review)
    }

    func testSecondActionWhileOneRunsReturnsAtOnce() async throws {
        let m = try makeModel(status: "doing")
        await m.reload()
        let card = try a5(m)
        let gate = TestGate()
        let inner = scripts.handler
        scripts.handler = { script, args in if script == .reviewPacket { await gate.wait() }; return try await inner(script, args) }
        let first = Task { await m.prepareReview(card) }
        try await Task.sleep(for: .milliseconds(200))
        await m.prepareReview(card)
        XCTAssertEqual(scripts.calls.filter { $0.script == .reviewPacket }.count, 1)
        await gate.release()
        await first.value
    }

    func testCloseTaskModelActionMarksTheCardDone() async throws {
        let m = try makeModel(status: "review")
        await m.reload()
        await m.closeTask(try a5(m))   // repoPath is /repo, so there is no worktree: an orphan
        guard case .done = m.actionState else { return XCTFail("\(m.actionState)") }
        XCTAssertEqual(try a5(m).status, .cancelled)
    }

    func testCancelledIsItsOwnStatusSectionAndLabel() {
        XCTAssertEqual(TaskStatus(raw: "cancelled"), .cancelled)
        XCTAssertEqual(TaskStatus.cancelled.label, "cancelled")
        XCTAssertFalse(TaskStatus.cancelled.holdsAgent)
        let c = TaskCard(id: "X", project: "d", status: .cancelled, agent: nil, branch: nil, kind: nil, files: [], title: "X", sections: [:], url: URL(fileURLWithPath: "/tmp/X.md"))
        XCTAssertEqual(TaskGrouping.sections(from: [.card(c)]).map(\.title), ["Cancelled"])
        XCTAssertFalse(reviewButtonStates(card: c, canAct: true, reason: nil, worktreeExists: false).close.enabled, "a cancelled task is not closed again")
    }

    // MARK: approve a whole round

    private func roundCard(_ id: String, deps: String = "", status: TaskStatus = .review, packet: String? = nil, fix: String? = nil) -> TaskCard {
        var sections = ["Review packet": packet ?? good]
        if !deps.isEmpty { sections["Dependencies"] = deps }
        if let fix { sections["Fix notes"] = fix }
        return TaskCard(id: id, project: "d", status: status, agent: "dev-\(id.lowercased())", branch: "task/\(id.lowercased())", kind: nil, files: [], title: "T \(id)", sections: sections,
                        url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func roundPlan(_ c: TaskCard) -> ApprovalPlan {
        ApprovalPlan(card: c, agentName: c.agent ?? "", branch: c.branch ?? "", worktreePath: "/wt/\(c.id)", base: "main", head: "abc", ahead: 1, filesChanged: 2, screenshotCount: 1,
                     isAnalysis: false, commandPreview: "merge-task.sh")
    }

    func testRoundMergesDependenciesFirstThenByID() {
        let cards = [roundCard("N3", deps: "- N1"), roundCard("N2"), roundCard("N1")]
        XCTAssertEqual(ApproveRound.order(cards).map(\.id), ["N1", "N2", "N3"])
        XCTAssertEqual(ApproveRound.order([roundCard("N9", deps: "- N5"), roundCard("N5", deps: "- N2"), roundCard("N2")]).map(\.id), ["N2", "N5", "N9"])
    }

    func testRoundListsOnlyCardsInReviewWithAPacket() {
        let cards = [roundCard("N1"), roundCard("N2", status: .doing), roundCard("N3", packet: " "), roundCard("N4")]
        XCTAssertEqual(ApproveRound.candidates(in: cards).map(\.id), ["N1", "N4"])
    }

    func testRoundRowShowsTheChecks() {
        let row = ApproveRound.row(roundCard("N1", fix: "- fix the label"), behind: 2)
        let values = Dictionary(uniqueKeysWithValues: row.checks.map { ($0.label, $0.value) })
        XCTAssertEqual(values["Build"], "passed")
        XCTAssertEqual(values["Screenshots"], "1")
        XCTAssertEqual(values["Behind main"], "2 commits: rebased before its merge")
        XCTAssertTrue(values["PM review"]?.contains("fix notes") == true, "\(values)")
        let clean = ApproveRound.row(roundCard("N2"), behind: nil)
        XCTAssertEqual(clean.checks.first { $0.label == "Behind main" }?.value, "up to date")
    }

    func testRoundMergesInOrderAndSkipsUntickedCards() async {
        var steps: [String] = []
        var rows = ["N2", "N1", "N3"].map { ApproveRound.row(roundCard($0), behind: nil) }
        rows[2].ticked = false
        let result = await ApproveRound.run(rows: rows, plan: { steps.append("plan \($0.id)"); return .success(self.roundPlan($0)) }, approve: { steps.append("approve \($0.card.id)"); return nil })
        XCTAssertEqual(steps, ["plan N1", "approve N1", "plan N2", "approve N2"])
        XCTAssertEqual(result.merged, ["N1", "N2"])
        XCTAssertEqual(result.skipped, ["N3"])
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.text, "Approved and merged N1, N2. Skipped N3.")
    }

    func testRoundStopsAtTheFirstFailedPlanAndSaysWhatIsLeft() async {
        var steps: [String] = []
        let rows = ["N1", "N2", "N3"].map { ApproveRound.row(roundCard($0), behind: nil) }
        let result = await ApproveRound.run(rows: rows, plan: { c in
            steps.append("plan \(c.id)")
            return c.id == "N2" ? .failure(.stale) : .success(self.roundPlan(c))
        }, approve: { steps.append("approve \($0.card.id)"); return nil })
        XCTAssertEqual(steps, ["plan N1", "approve N1", "plan N2"])
        XCTAssertEqual(result.merged, ["N1"])
        XCTAssertEqual(result.failure?.id, "N2")
        XCTAssertEqual(result.notRun, ["N3"])
        XCTAssertTrue(result.text.contains("Merged: N1."), result.text)
        XCTAssertTrue(result.text.contains("N2 stopped the round"), result.text)
        XCTAssertTrue(result.text.contains("Not merged: N2, N3."), result.text)
    }

    func testRoundStopsWhenAMergeFails() async {
        var steps: [String] = []
        let rows = ["N1", "N2"].map { ApproveRound.row(roundCard($0), behind: nil) }
        let result = await ApproveRound.run(rows: rows, plan: { .success(self.roundPlan($0)) }, approve: { steps.append($0.card.id); return $0.card.id == "N1" ? "merge refused" : nil })
        XCTAssertEqual(steps, ["N1"])
        XCTAssertTrue(result.merged.isEmpty)
        XCTAssertEqual(result.failure?.message, "merge refused")
        XCTAssertTrue(result.text.contains("Nothing was merged."), result.text)
        XCTAssertTrue(result.text.contains("Not merged: N1, N2."), result.text)
    }
}
