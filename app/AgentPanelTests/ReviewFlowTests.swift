import XCTest
@testable import AgentPanel

private let headSHA = "0123456789abcdef0123456789abcdef01234567"

final class ReviewFlowTests: XCTestCase {
    private var dir: TempDir!
    private var scripts: FakeScripts!
    private var commander: FakeCommander!
    private var head: String { headSHA }
    private let source = "/etc/demo/project.json"

    override func setUpWithError() throws {
        dir = try TempDir()
        scripts = FakeScripts()
        commander = FakeCommander()
        scripts.handler = { script, args in
            switch script {
            case .sim: return ScriptResult(status: 0, stdout: "UDID-1\n", stderr: "")
            case .merge where args.first == "--inspect":
                return ScriptResult(status: 0, stdout: "{\"head\":\"\(headSHA)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":2,\"behind\":0,\"dirtyOverlap\":[],\"worktreeDirty\":false}\n", stderr: "")
            case .merge: return ScriptResult(status: 0, stdout: "{\"merged\":\"\(headSHA)\"}\n", stderr: "")
            default: return ScriptResult(status: 0, stdout: "", stderr: "")
            }
        }
    }

    private var repoPath = "/repo"
    private var hasSimulator = true
    private var hasBuild = true
    private var screenshotsOn: Bool? = nil

    private var project: ProjectConfig {
        ProjectConfig(id: "demo", name: "Demo", repoPath: repoPath, dataDir: dir.url.appendingPathComponent("data").path, maxParallel: 4,
                      buildCommand: hasBuild ? "build" : nil, xcodeProject: nil, simulator: hasSimulator ? .init(baseDevice: "iPhone 17 Pro") : nil, sharedFiles: [], openWith: "Xcode",
                      screenshots: screenshotsOn, sourcePath: source)
    }

    private func packet(head h: String? = nil, build: Bool = true, shots: Int = 1) -> String {
        var s = "Head: \(h ?? head)\n\n"
        s += build ? "Build: passed (`b`), log: /l\n\nScreenshots:\n" : "Build: failed\n\nScreenshots:\n"
        for i in 0..<shots { s += "- tasks/T1/shots/\(i).png\n" }
        return s + "\nDiff summary:\n```\n a.txt | 1 +\n 1 file changed, 1 insertion(+)\n```\n"
    }

    @discardableResult
    private func makeCard(status: String = "review", kind: String? = nil, branch: String = "feat/t1", agent: String = "dev-t1", packet p: String? = nil, id: String = "T1") throws -> TaskCard {
        let k = kind.map { "kind: \($0)\n" } ?? ""
        let url = try dir.write("data/tasks/\(id).md", "---\nid: \(id)\nproject: demo\nstatus: \(status)\nagent: \(agent)\nbranch: \(branch)\n\(k)files:\n  - a.txt\n---\n# \(id) · Title\n\n## Goal\nGoal.\n\n## Report\nDone.\n\n## Review packet\n\n\(p ?? packet())\n## Decision\n")
        return try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
    }

    private func reload(_ card: TaskCard) throws -> TaskCard {
        try CardParser.parse(try String(contentsOf: card.url, encoding: .utf8), url: card.url)
    }

    private func flow(writer: CardWriting = CardWriter(), agents: [AgentStatus]? = nil) -> ReviewFlow {
        let list = agents ?? [{ var a = AgentStatus(paneID: "wT:p1", workspaceID: "wT", state: .idle, cwd: "/repo/.agent-worktrees/feat-t1", title: "t1", sessionID: "s1"); a.name = "dev-t1"; return a }()]
        return ReviewFlow(project: project, scripts: scripts, adapter: FakeTerminal(agentsResult: .success(list)), commander: commander, writer: writer,
                          log: ActionLog(fileURL: dir.url.appendingPathComponent("log")), now: { Date(timeIntervalSince1970: 1_792_000_000) })
    }

    func testPacketStartIsLoggedBeforeItsEnd() async throws {
        try await flow().preparePacket(for: try makeCard(status: "doing"))
        let text = ActionLog(fileURL: dir.url.appendingPathComponent("log")).read()
        let start = text.range(of: "[demo] review packet started for T1"), end = text.range(of: "[demo] review packet prepared for T1")
        XCTAssertNotNil(start, text); XCTAssertNotNil(end, text)
        if let start, let end { XCTAssertLessThan(start.lowerBound, end.lowerBound) }
    }

    func testPacketStartIsLoggedEvenWhenItFails() async throws {
        scripts.handler = { _, _ in ScriptResult(status: 1, stdout: "", stderr: "boom") }
        _ = try? await flow().preparePacket(for: try makeCard(status: "doing"))
        let text = ActionLog(fileURL: dir.url.appendingPathComponent("log")).read()
        XCTAssertTrue(text.contains("[demo] review packet started for T1"), text)
        XCTAssertFalse(text.contains("review packet prepared"), text)
    }

    func testPacketAndMergeLinesNameTheProject() async throws {
        let log = dir.url.appendingPathComponent("log")
        try await flow().preparePacket(for: try makeCard(status: "doing"))
        let plan = try await flow().approvalPlan(for: try makeCard(id: "T2"))
        try await flow().approve(plan)
        let text = ActionLog(fileURL: log).read()
        XCTAssertTrue(text.contains("[demo] review packet prepared for T1"), text)
        XCTAssertTrue(text.contains("[demo] merged "), text)
        XCTAssertTrue(text.contains("[demo] approved T2"), text)
    }

    // MARK: rebase on approve (N66)

    private let rebasedSHA = "89abcdef0123456789abcdef0123456789abcdef"

    /// Main is ahead until `--rebase` runs; `conflict` makes it answer 9. Preparing the review writes the new head into the card's packet.
    private func behindScripts(conflict: Bool = false, dirty: Bool = false) {
        let rebased = rebasedSHA
        let state = Box()
        scripts.handler = { script, args in
            switch script {
            case .sim: return ScriptResult(status: 0, stdout: "UDID-1\n", stderr: "")
            case .merge where args.first == "--inspect":
                let h = state.rebased ? rebased : headSHA
                return ScriptResult(status: 0, stdout: "{\"head\":\"\(h)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":2,\"behind\":\(state.rebased ? 0 : 3),\"dirtyOverlap\":[],\"worktreeDirty\":\(dirty)}\n", stderr: "")
            case .merge where args.first == "--rebase":
                if conflict { return ScriptResult(status: 9, stdout: "a.txt\nb.txt\n", stderr: "conflicts") }
                state.rebased = true
                return ScriptResult(status: 0, stdout: "{\"rebased\":\"\(rebased)\"}\n", stderr: "")
            case .reviewPacket:
                let url = URL(fileURLWithPath: args[0])
                if let text = try? String(contentsOf: url, encoding: .utf8) { try? text.replacingOccurrences(of: headSHA, with: rebased).write(to: url, atomically: true, encoding: .utf8) }
                return ScriptResult(status: 0, stdout: "", stderr: "")
            case .merge: return ScriptResult(status: 0, stdout: "{\"merged\":\"\(rebased)\"}\n", stderr: "")
            default: return ScriptResult(status: 0, stdout: "", stderr: "")
            }
        }
    }
    private final class Box: @unchecked Sendable { var rebased = false }

    func testApproveOnABehindCardRebasesPreparesAgainAndMerges() async throws {
        behindScripts()
        let card = try makeCard()
        let plan = try await flow().approvalPlanRebasing(for: card, agentWorking: false)
        XCTAssertEqual(plan.head, rebasedSHA)
        try await flow().approve(plan)
        let calls = scripts.calls.map { ($0.script, $0.args.first ?? "") }
        let order = calls.compactMap { c -> String? in
            switch (c.0, c.1) {
            case (.merge, "--rebase"): return "rebase"
            case (.reviewPacket, _): return "prepare"
            case (.merge, let a) where a != "--inspect": return "merge"
            default: return nil
            }
        }
        XCTAssertEqual(order, ["rebase", "prepare", "merge"])
        XCTAssertEqual(try reload(card).status, .done)
        XCTAssertTrue(commander.prompts.isEmpty)
    }

    func testAConflictingRebaseSendsOneFixRequestNamingTheFilesAndChangesNothingElse() async throws {
        behindScripts(conflict: true)
        let card = try makeCard()
        do { _ = try await flow().approvalPlanRebasing(for: card, agentWorking: false); XCTFail("conflict") }
        catch let error as ReviewError { XCTAssertEqual(error, .rebaseConflict(["a.txt", "b.txt"])) }
        XCTAssertEqual(commander.prompts.count, 1)
        let after = try reload(card)
        XCTAssertEqual(after.status, .needsFix)
        let notes = try XCTUnwrap(after.sections["Fix notes"])
        XCTAssertTrue(notes.contains("a.txt, b.txt"), notes)
        XCTAssertFalse(scripts.calls.contains { $0.script == .reviewPacket })
    }

    func testAWorkingAgentOrADirtyTreeIsNeverRebased() async throws {
        behindScripts()
        do { _ = try await flow().approvalPlanRebasing(for: try makeCard(), agentWorking: true); XCTFail("working") }
        catch let error as ReviewError { XCTAssertEqual(error, .notFastForward) }
        behindScripts(dirty: true)
        do { _ = try await flow().approvalPlanRebasing(for: try makeCard(id: "T2"), agentWorking: false); XCTFail("dirty") }
        catch let error as ReviewError { XCTAssertEqual(error, .worktreeDirty) }
        XCTAssertFalse(scripts.calls.contains { $0.args.first == "--rebase" })
        XCTAssertTrue(commander.prompts.isEmpty)
    }

    func testACardThatIsNotBehindIsNotRebased() async throws {
        let plan = try await flow().approvalPlanRebasing(for: try makeCard(), agentWorking: false)
        XCTAssertEqual(plan.head, headSHA)
        XCTAssertFalse(scripts.calls.contains { $0.args.first == "--rebase" })
        XCTAssertFalse(scripts.calls.contains { $0.script == .reviewPacket })
    }

    // MARK: prepare

    func testPreparePacketRunsSimThenReviewPacketWithCardAndWorktree() async throws {
        let card = try makeCard(status: "doing")
        try await flow().preparePacket(for: card)
        XCTAssertEqual(scripts.calls.map(\.script), [.sim, .reviewPacket])
        XCTAssertEqual(scripts.calls[0].args, ["dev-t1", source])
        XCTAssertEqual(scripts.calls[1].args, [card.url.path, "/repo/.agent-worktrees/feat-t1", "UDID-1", source])
    }

    func testPreparePacketForAProjectWithoutSimulatorSkipsTheSimulatorLookup() async throws {
        hasSimulator = false
        let card = try makeCard(status: "doing")
        try await flow().preparePacket(for: card)
        XCTAssertEqual(scripts.calls.map(\.script), [.reviewPacket])
        XCTAssertEqual(scripts.calls[0].args, [card.url.path, "/repo/.agent-worktrees/feat-t1", "", source])
    }

    func testApprovalPlanAcceptsAPacketOfAProjectWithoutBuildOrScreenshots() async throws {
        hasBuild = false; hasSimulator = false; screenshotsOn = false
        let card = try makeCard(packet: "Head: \(headSHA)\n\nBuild: none (this project has no build command)\n\nScreenshots: not used in this project\n\nDiff summary:\n```\n a.txt | 1 +\n 1 file changed, 1 insertion(+)\n```\n")
        let plan = try await flow().approvalPlan(for: card)
        XCTAssertEqual(plan.screenshotCount, 0)
    }

    func testAPacketCannotClaimThereIsNoBuildForAProjectThatHasOne() async throws {
        let bare = "Head: \(headSHA)\n\nBuild: none (this project has no build command)\n\nScreenshots:\n- tasks/T1/shots/0.png\n\nDiff summary:\n```\n a.txt | 1 +\n 1 file changed, 1 insertion(+)\n```\n"
        let card = try makeCard(packet: bare)
        do { _ = try await flow().approvalPlan(for: card); XCTFail("a build exists for this project") }
        catch let error as ReviewError { guard case .packetMissing(let m) = error else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("build")) }
    }

    func testAPacketCannotSayScreenshotsAreNotUsedWhenTheProjectTakesThem() async throws {
        let notUsed = "Head: \(headSHA)\n\nBuild: passed (`b`), log: /l\n\nScreenshots: not used in this project\n\nDiff summary:\n```\n a.txt | 1 +\n 1 file changed, 1 insertion(+)\n```\n"
        let card = try makeCard(packet: notUsed)
        do { _ = try await flow().approvalPlan(for: card); XCTFail("screenshots are required here") }
        catch let error as ReviewError { guard case .packetMissing(let m) = error else { return XCTFail("\(error)") }; XCTAssertTrue(m.lowercased().contains("screenshot")) }
    }

    func testApproveStopsTheAgentWithoutTouchingSimulatorsOnlyForAProjectWithoutOne() async throws {
        for (simulator, id) in [(false, "T8"), (true, "T9")] {
            hasSimulator = simulator; hasBuild = simulator; screenshotsOn = simulator ? nil : false
            let build = simulator ? "passed (`b`), log: /l" : "none (this project has no build command)"
            let shots = simulator ? "Screenshots:\n- tasks/T1/shots/0.png" : "Screenshots: not used in this project"
            let packet = "Head: \(headSHA)\n\nBuild: \(build)\n\n\(shots)\n\nDiff summary:\n```\n a.txt | 1 +\n 1 file changed, 1 insertion(+)\n```\n"
            scripts.handler = { script, args in
                switch script {
                case .merge where args.first == "--inspect":
                    return ScriptResult(status: 0, stdout: "{\"head\":\"\(headSHA)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":2,\"behind\":0,\"dirtyOverlap\":[],\"worktreeDirty\":false}\n", stderr: "")
                case .merge: return ScriptResult(status: 0, stdout: "{\"merged\":\"\(headSHA)\"}", stderr: "")
                default: return ScriptResult(status: 0, stdout: "", stderr: "")
                }
            }
            let plan = try await flow().approvalPlan(for: try makeCard(packet: packet, id: id))
            try await flow().approve(plan)
            let stop = try XCTUnwrap(scripts.calls.last { $0.script == .stop })
            XCTAssertEqual(stop.args.contains("--no-sim"), !simulator, "simulator: \(simulator)")
        }
    }

    func testApproveTreatsStopExit4AsDone() async throws {
        hasSimulator = false; hasBuild = false; screenshotsOn = false
        let packet = "Head: \(headSHA)\n\nBuild: none (this project has no build command)\n\nScreenshots: not used in this project\n\nDiff summary:\n```\n a.txt | 1 +\n 1 file changed, 1 insertion(+)\n```\n"
        scripts.handler = { script, args in
            switch script {
            case .merge where args.first == "--inspect":
                return ScriptResult(status: 0, stdout: "{\"head\":\"\(headSHA)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":2,\"behind\":0,\"dirtyOverlap\":[],\"worktreeDirty\":false}\n", stderr: "")
            case .merge: return ScriptResult(status: 0, stdout: "{\"merged\":\"\(headSHA)\"}", stderr: "")
            case .stop: return ScriptResult(status: 4, stdout: "", stderr: "ERROR: no terminal workspace")
            default: return ScriptResult(status: 0, stdout: "", stderr: "")
            }
        }
        let plan = try await flow().approvalPlan(for: try makeCard(packet: packet, id: "T10"))
        try await flow().approve(plan)
    }

    func testPreparePacketEvidenceMissingSurfacesScriptMessageAndLeavesCard() async throws {
        let card = try makeCard(status: "doing")
        let before = try String(contentsOf: card.url, encoding: .utf8)
        scripts.handler = { script, _ in
            script == .sim ? ScriptResult(status: 0, stdout: "UDID-1\n", stderr: "")
                           : ScriptResult(status: 1, stdout: "EVIDENCE MISSING: build failed, see /l\nerror: x\n", stderr: "")
        }
        do { try await flow().preparePacket(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .packetMissing("EVIDENCE MISSING: build failed, see /l\nerror: x")) }
        XCTAssertEqual(try String(contentsOf: card.url, encoding: .utf8), before)
    }

    func testPreparePacketOnlyForDoingOrNeedsFixCards() async throws {
        for status in ["todo", "done", "blocked"] {
            let card = try makeCard(status: status)
            do { try await flow().preparePacket(for: card); XCTFail("\(status) should be refused") }
            catch let error as ReviewError { guard case .invalid = error else { return XCTFail("\(error)") } }
        }
        XCTAssertEqual(scripts.calls, [])
    }

    func testPreparePacketRunsAgainForACardAlreadyInReviewWithoutAPacket() async throws {
        // an agent may move its card to review itself; without a packet Approve cannot work, so the packet can be built from review
        let card = try makeCard(status: "review", packet: "")
        try await flow().preparePacket(for: card)
        XCTAssertEqual(scripts.calls.map(\.script), [.sim, .reviewPacket])
    }

    func testPreparePacketWithoutASimulatorFails() async throws {
        let card = try makeCard(status: "doing")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "", stderr: "") }
        do { try await flow().preparePacket(for: card); XCTFail("should throw") }
        catch let error as ReviewError { guard case .failed = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(scripts.calls.map(\.script), [.sim])
    }

    // MARK: approval plan

    func testApprovalPlanFillsInTheFactsTheSheetShows() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        XCTAssertEqual(plan.agentName, "dev-t1")
        XCTAssertEqual(plan.branch, "feat/t1")
        XCTAssertEqual(plan.base, "main")
        XCTAssertEqual(plan.head, head)
        XCTAssertEqual(plan.ahead, 2)
        XCTAssertEqual(plan.filesChanged, 1)
        XCTAssertFalse(plan.isAnalysis)
        XCTAssertEqual(plan.worktreePath, "/repo/.agent-worktrees/feat-t1")
        XCTAssertEqual(scripts.calls.first?.args, ["--inspect", source, "feat/t1", "/repo/.agent-worktrees/feat-t1"])
        XCTAssertTrue(plan.commandPreview.contains("merge-task.sh"))
    }

    func testApprovalPlanIsStaleWhenPacketHeadDiffersFromBranchHead() async throws {
        let card = try makeCard(packet: packet(head: String(repeating: "a", count: 40)))
        do { _ = try await flow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .stale) }
    }

    func testApprovalPlanTreatsAPacketWithoutHeadAsStale() async throws {
        let card = try makeCard(packet: "Build: passed (`b`), log: /l\n\nScreenshots:\n- tasks/T1/shots/0.png\n")
        do { _ = try await flow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .stale) }
    }

    func testApprovalPlanRefusesNonReviewCardAndMissingEvidence() async throws {
        for (card, name) in [(try makeCard(status: "doing", id: "T2"), "doing"),
                             (try makeCard(packet: packet(build: false), id: "T3"), "failed build"),
                             (try makeCard(packet: packet(shots: 0), id: "T4"), "no screenshots"),
                             (try makeCard(packet: "Head: \(headSHA)\n", id: "T5"), "empty packet")] {
            do { _ = try await flow().approvalPlan(for: card); XCTFail("\(name) should be refused") }
            catch is ReviewError {}
        }
    }

    func testApprovalPlanReportsWhatIsInTheWay() async throws {
        let card = try makeCard()
        scripts.handler = { script, _ in
            ScriptResult(status: 0, stdout: "{\"head\":\"\(headSHA)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":1,\"behind\":0,\"dirtyOverlap\":[\"a.txt\",\"b.txt\"],\"worktreeDirty\":false}", stderr: "")
        }
        do { _ = try await flow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .userFilesInTheWay(["a.txt", "b.txt"])) }

        scripts.handler = { _, _ in
            ScriptResult(status: 0, stdout: "{\"head\":\"\(headSHA)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":1,\"behind\":3,\"dirtyOverlap\":[],\"worktreeDirty\":false}", stderr: "")
        }
        do { _ = try await flow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .notFastForward) }

        scripts.handler = { _, _ in
            ScriptResult(status: 0, stdout: "{\"head\":\"\(headSHA)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":1,\"behind\":0,\"dirtyOverlap\":[],\"worktreeDirty\":true}", stderr: "")
        }
        do { _ = try await flow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .worktreeDirty) }
    }

    func testHostileBranchNeverReachesAScript() async throws {
        for branch in ["--force", "x; rm -rf ~", "../x"] {
            let card = try makeCard(branch: branch)
            do { _ = try await flow().approvalPlan(for: card); XCTFail("\(branch) should be refused") }
            catch let error as ReviewError { guard case .invalid = error else { return XCTFail("\(error)") } }
            do { try await flow().requestFix(for: card, notes: "x"); XCTFail("\(branch) should be refused") }
            catch is ReviewError {}
        }
        XCTAssertEqual(scripts.calls, [])
        XCTAssertEqual(commander.prompts.count, 0)
    }

    // MARK: approve

    func testApproveMergesThenMarksDoneThenStopsAgent() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        scripts.handler = { script, _ in
            script == .merge ? ScriptResult(status: 0, stdout: "{\"merged\":\"\(headSHA)\"}", stderr: "") : ScriptResult(status: 0, stdout: "", stderr: "")
        }
        try await flow().approve(plan)
        let calls = scripts.calls.dropFirst()   // the first call is the --inspect of the plan
        XCTAssertEqual(calls.map(\.script), [.merge, .stop])
        XCTAssertEqual(calls.first?.args, [source, "feat/t1", "/repo/.agent-worktrees/feat-t1", "--expect-head", head])
        XCTAssertEqual(calls.last?.args, ["dev-t1", "/repo/.agent-worktrees/feat-t1", "--remove-worktree", "--delete-branch", "--expect-branch", "feat/t1"])
        let after = try reload(plan.card)
        XCTAssertEqual(after.status, .done)
        XCTAssertTrue(after.sections["Decision"]?.contains("Approved") == true)
        XCTAssertTrue(after.sections["Decision"]?.contains(String(head.prefix(7))) == true)
        XCTAssertEqual(after.sections["Report"], "Done.", "the rest of the card is untouched")
    }

    func testApproveExitCodesMapToErrorsAndChangeNothing() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        let before = try String(contentsOf: plan.card.url, encoding: .utf8)
        let cases: [(Int32, String, String, ReviewError)] = [
            (3, "", "ERROR: the repository is on 'x'", .invalid("ERROR: the repository is on 'x'")),
            (4, "", "ERROR: not a fast-forward", .notFastForward),
            (5, "a.txt\nb.txt\n", "ERROR: in the way", .userFilesInTheWay(["a.txt", "b.txt"])),
            (6, "wip.txt\n", "ERROR: unsaved", .worktreeDirty),
            (7, "", "ERROR: tip moved", .headMoved),
            (8, "", "ERROR: git could not fast-forward main to the reviewed commit: index.lock exists", .failed("ERROR: git could not fast-forward main to the reviewed commit: index.lock exists")),
        ]
        for (code, out, err, expected) in cases {
            scripts.handler = { script, _ in script == .merge ? ScriptResult(status: code, stdout: out, stderr: err) : ScriptResult(status: 0, stdout: "", stderr: "") }
            do { try await flow().approve(plan); XCTFail("exit \(code) should throw") }
            catch let error as ReviewError { XCTAssertEqual(error, expected) }
            XCTAssertEqual(try String(contentsOf: plan.card.url, encoding: .utf8), before, "exit \(code) leaves the card alone")
        }
        XCTAssertFalse(scripts.calls.contains { $0.script == .stop }, "the agent is never stopped when the merge did not happen")
    }

    func testApproveWhenCardWriteFailsAfterMergeReportsMergedButIncomplete() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        do { try await flow(writer: FailingWriter()).approve(plan); XCTFail("should throw") }
        catch let error as ReviewError {
            guard case .mergedButIncomplete(let done, let failed, let manual) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(done.contains("merged"))
            XCTAssertTrue(failed.contains("disk full"))
            XCTAssertTrue(manual.contains(plan.card.url.path))
        }
        XCTAssertFalse(scripts.calls.contains { $0.script == .stop }, "the agent stays open when the card could not be updated")
    }

    func testApproveWhenStopFailsKeepsCardDoneAndReportsManualCleanup() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        scripts.handler = { script, _ in
            switch script {
            case .merge: return ScriptResult(status: 0, stdout: "{\"merged\":\"\(headSHA)\"}", stderr: "")
            case .stop: return ScriptResult(status: 1, stdout: "", stderr: "ERROR: could not remove worktree")
            default: return ScriptResult(status: 0, stdout: "", stderr: "")
            }
        }
        do { try await flow().approve(plan); XCTFail("should throw") }
        catch let error as ReviewError {
            guard case .mergedButIncomplete(_, let failed, let manual) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(failed.contains("could not remove worktree"))
            XCTAssertTrue(manual.contains("dev-t1"))
        }
        XCTAssertEqual(try reload(plan.card).status, .done)
    }

    func testAnalysisApproveDoesNotCallMerge() async throws {
        let card = try makeCard(kind: "analysis", packet: "Head: \(headSHA)\n\nAnalysis task: no build or screenshots needed.\n")
        let plan = try await flow().approvalPlan(for: card)
        XCTAssertTrue(plan.isAnalysis)
        try await flow().approve(plan)
        XCTAssertEqual(scripts.calls.filter { $0.script == .merge }.count, 1, "only the --inspect of the plan")
        XCTAssertEqual(scripts.calls.last?.script, .stop)
        XCTAssertEqual(try reload(card).status, .done)
    }

    func testApproveRefusesACardThatIsNoLongerInReview() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        try CardWriter().update(plan.card, set: [.status: "done"], expectingStatus: .review)
        let calls = scripts.calls.count
        do { try await flow().approve(plan); XCTFail("should throw") }
        catch is ReviewError {}
        XCTAssertEqual(scripts.calls.count, calls, "no script ran")
    }

    func testSecondApproveWhileFirstRunsIsRejected() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        let gate = TestGate()
        scripts.handler = { script, _ in
            if script == .merge { await gate.wait(); return ScriptResult(status: 0, stdout: "{\"merged\":\"\(headSHA)\"}", stderr: "") }
            return ScriptResult(status: 0, stdout: "", stderr: "")
        }
        let first = Task { try await self.flow().approve(plan) }
        try await Task.sleep(for: .milliseconds(150))
        do { try await flow().approve(plan); XCTFail("second approve should be refused") }
        catch let error as ReviewError { XCTAssertEqual(error, .alreadyRunning) }
        await gate.release()
        try await first.value
        XCTAssertEqual(scripts.calls.filter { $0.script == .merge && $0.args.first != "--inspect" }.count, 1)
    }

    // MARK: request fix

    func testRequestFixWritesNotesStatusNeedsFixThenPrompts() async throws {
        let card = try makeCard()
        try await flow().requestFix(for: card, notes: "The title is cut off on small phones.")
        let after = try reload(card)
        XCTAssertEqual(after.status, .needsFix)
        XCTAssertTrue(after.sections["Fix notes"]?.contains("The title is cut off on small phones.") == true)
        XCTAssertEqual(commander.prompts.count, 1)
        XCTAssertEqual(commander.prompts[0].target, "wT:p1")
        XCTAssertTrue(commander.prompts[0].text.contains(card.url.path))
        XCTAssertTrue(commander.prompts[0].text.contains("## Fix notes"))
    }

    @MainActor func testFixAndRebaseRequestsSayToAnswerInTheReportNotInFixNotes() {
        XCTAssertTrue(ReviewFlow.fixMessage("/x/N1.md").contains("### Fix round N"))
        XCTAssertTrue(AutopilotModel.rebaseNotes(behind: 2).contains("answer in the Report, not in Fix notes"))
    }

    @MainActor func testFixMessageAsksForBuildOnlyFromBuildingRoles() {
        for r in ["dev", "ui_dev"] { XCTAssertTrue(ReviewFlow.fixMessage("/x", roles: [r]).contains("screenshots")) }
        for r in ["analyst", "reviewer"] {
            let m = ReviewFlow.fixMessage("/x", roles: [r])
            XCTAssertFalse(m.contains("screenshots")); XCTAssertTrue(m.contains("output file"))
        }
    }

    // MARK: no merge while a fix or rebase request is open (N95)

    /// A request was sent and the card is back in review (as after Prepare review) with the Report the agent has not answered in yet.
    private func openRequest(id: String, notes: String) async throws -> TaskCard {
        let card = try makeCard(id: id)
        try await flow().requestFix(for: card, notes: notes)
        let sent = try reload(card)
        try CardWriter().update(sent, set: [.status: "review"], expectingStatus: .needsFix)
        return try reload(card)
    }

    func testApprovalPlanRefusesACardWhoseFixRequestIsStillOpen() async throws {
        let card = try await openRequest(id: "F1", notes: "The title is cut off.")
        do { _ = try await flow().approvalPlan(for: card); XCTFail("open fix") }
        catch let error as ReviewError { XCTAssertTrue(error.message.contains("fix request") && error.message.contains("still open"), error.message) }
        do { _ = try await flow().approvalPlanRebasing(for: card, agentWorking: false); XCTFail("open fix") }
        catch let error as ReviewError { XCTAssertTrue(error.message.contains("still open"), error.message) }
        XCTAssertFalse(scripts.calls.contains { $0.script == .merge && $0.args.first != "--inspect" })
    }

    func testApproveRefusesAPlanMadeBeforeAFixRequestWasSent() async throws {
        let card = try makeCard(id: "F2")
        let plan = try await flow().approvalPlan(for: card)
        try await flow().requestFix(for: try reload(card), notes: "Wrong colour.")
        try CardWriter().update(try reload(card), set: [.status: "review"], expectingStatus: .needsFix)
        do { try await flow().approve(plan); XCTFail("open fix") }
        catch let error as ReviewError { XCTAssertTrue(error.message.contains("still open"), error.message) }
        XCTAssertFalse(scripts.calls.contains { $0.script == .merge && $0.args.first != "--inspect" })
        XCTAssertEqual(try reload(card).status, .review)
    }

    func testAFixRequestIsClosedOnceTheAgentAnswersInTheReportOrIsGone() async throws {
        let card = try await openRequest(id: "F3", notes: "Fix it.")
        let text = try String(contentsOf: card.url, encoding: .utf8).replacingOccurrences(of: "## Report\nDone.", with: "## Report\nFixed and rebuilt.")
        try text.write(to: card.url, atomically: true, encoding: .utf8)
        _ = try await flow().approvalPlan(for: try reload(card))

        let gone = try await openRequest(id: "F4", notes: "Fix it.")
        _ = try await flow(agents: []).approvalPlan(for: gone)
    }

    @MainActor func testAnOpenRebaseRequestOfAnIdleAgentIsWithdrawnAndTheAgentIsTold() async throws {
        behindScripts()
        let card = try await openRequest(id: "F5", notes: AutopilotModel.rebaseNotes(behind: 3))
        let plan = try await flow().approvalPlanRebasing(for: card, agentWorking: false)
        XCTAssertEqual(plan.head, rebasedSHA, "the panel rebased it itself")
        XCTAssertEqual(commander.prompts.count, 2)
        XCTAssertTrue(commander.prompts[1].text.contains("Withdrawn") && commander.prompts[1].text.contains("do not rebase"), commander.prompts[1].text)
        try await flow().approve(plan)
        XCTAssertEqual(try reload(card).status, .done)
    }

    @MainActor func testAnOpenRebaseRequestOfAWorkingAgentBlocksApprove() async throws {
        behindScripts()
        let card = try await openRequest(id: "F6", notes: AutopilotModel.rebaseNotes(behind: 3))
        do { _ = try await flow().approvalPlanRebasing(for: card, agentWorking: true); XCTFail("working") }
        catch let error as ReviewError { XCTAssertTrue(error.message.contains("rebase request") && error.message.contains("still open"), error.message) }
        XCTAssertEqual(commander.prompts.count, 1, "nothing withdrawn")
        XCTAssertFalse(scripts.calls.contains { $0.args.first == "--rebase" })
    }

    func testARebaseRequestAfterAConflictIsAFixRequestThatBlocks() async throws {
        behindScripts(conflict: true)
        let card = try makeCard(id: "F7")
        do { _ = try await flow().approvalPlanRebasing(for: card, agentWorking: false); XCTFail("conflict") }
        catch let error as ReviewError { XCTAssertEqual(error, .rebaseConflict(["a.txt", "b.txt"])) }
        try CardWriter().update(try reload(card), set: [.status: "review"], expectingStatus: .needsFix)
        do { _ = try await flow().approvalPlanRebasing(for: try reload(card), agentWorking: false); XCTFail("open") }
        catch let error as ReviewError { XCTAssertTrue(error.message.contains("still open"), error.message) }
        XCTAssertEqual(commander.prompts.count, 1, "the conflict request is not withdrawn")
    }

    @MainActor func testOnlyThePanelsRebaseNotesCountAsAPlainRebaseRequest() {
        XCTAssertTrue(ReviewFlow.isRebaseRequest(AutopilotModel.rebaseNotes(behind: 1)))
        XCTAssertFalse(ReviewFlow.isRebaseRequest(ReviewFlow.conflictNotes(files: ["a"], base: "main")))
        XCTAssertFalse(ReviewFlow.isRebaseRequest("Title is cut off."))
    }

    func testACardIsMarkedAsBeingApprovedWhileItsPlanIsMade() async throws {
        let card = try makeCard(id: "F8")
        let seen = Box()
        scripts.handler = { script, args in
            if script == .merge, args.first == "--inspect" { seen.rebased = ReviewFlow.isApproving(card) }
            return ScriptResult(status: 0, stdout: "{\"head\":\"\(headSHA)\",\"base\":\"main\",\"repoBranch\":\"main\",\"ahead\":2,\"behind\":0,\"dirtyOverlap\":[],\"worktreeDirty\":false}\n", stderr: "")
        }
        XCTAssertFalse(ReviewFlow.isApproving(card))
        _ = try await flow().approvalPlanRebasing(for: card, agentWorking: false)
        XCTAssertTrue(seen.rebased)
        XCTAssertFalse(ReviewFlow.isApproving(card))
    }

    // MARK: pass on fix notes

    private func withFixNotes(_ status: String) throws -> TaskCard {
        let card = try makeCard(status: status)
        let current = try reload(card)
        try CardWriter().update(current, set: [:], section: SectionEdit(.fixNotes, "### 2026-10-17 10:00\n\n> Title is cut off."), expectingStatus: current.status)
        return try reload(card)
    }

    func testPassOnFixNotesMovesTheCardToNeedsFixAndPromptsWithoutWritingNotes() async throws {
        for (i, status) in ["review", "doing", "needs-fix"].enumerated() {
            let card = try withFixNotes(status)
            let notes = card.sections["Fix notes"]
            try await flow().passOnFixNotes(for: card)
            let after = try reload(card)
            XCTAssertEqual(after.status, .needsFix, status)
            XCTAssertEqual(after.sections["Fix notes"], notes, "nothing is appended (\(status))")
            XCTAssertEqual(commander.prompts.count, i + 1)
            XCTAssertTrue(commander.prompts[i].text.contains("## Fix notes"))
        }
    }

    func testPassOnFixNotesNeedsNotesAndARunningAgentAndRestoresTheStatus() async throws {
        let bare = try makeCard()
        do { try await flow().passOnFixNotes(for: bare); XCTFail("should throw") } catch let error as ReviewError { guard case .invalid = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(commander.prompts.count, 0)

        let card = try withFixNotes("review")
        do { try await flow(agents: []).passOnFixNotes(for: card); XCTFail("should throw") } catch let error as ReviewError { XCTAssertEqual(error, .agentGone) }
        XCTAssertEqual(try reload(card).status, .review)

        commander.error = BackendError.failed("pane closed")
        do { try await flow().passOnFixNotes(for: card); XCTFail("should throw") } catch let error as ReviewError { guard case .failed(let m) = error else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("pane closed")) }
        XCTAssertEqual(try reload(card).status, .review, "back to where it was")
        XCTAssertNotNil(try reload(card).sections["Fix notes"])

        let done = try makeCard(status: "done", id: "T2")
        do { try await flow().passOnFixNotes(for: done); XCTFail("should throw") } catch let error as ReviewError { guard case .invalid = error else { return XCTFail("\(error)") } }
    }

    func testRequestFixWhenAgentGoneLeavesCardUntouched() async throws {
        let card = try makeCard()
        let before = try String(contentsOf: card.url, encoding: .utf8)
        do { try await flow(agents: []).requestFix(for: card, notes: "x"); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .agentGone) }
        XCTAssertEqual(try String(contentsOf: card.url, encoding: .utf8), before)
        XCTAssertEqual(commander.prompts.count, 0)
    }

    func testRequestFixIgnoresAnAgentInAnotherWorktree() async throws {
        let other = [AgentStatus(paneID: "wX:p1", workspaceID: "wX", state: .idle, cwd: "/repo/.agent-worktrees/feat-other", title: "o")]
        do { try await flow(agents: other).requestFix(for: try makeCard(), notes: "x"); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .agentGone) }
        XCTAssertEqual(commander.prompts.count, 0)
    }

    /// N53 #7: a session the user or a reviewer opened inside the worktree is not the card's agent.
    func testFixRequestsNeverGoToAUserSessionInTheWorktree() async throws {
        let user = AgentStatus(paneID: "wU:p1", workspaceID: "wU", state: .idle, cwd: "/repo/.agent-worktrees/feat-t1", title: "me")
        var named = AgentStatus(paneID: "wT:p1", workspaceID: "wT", state: .idle, cwd: "/repo/.agent-worktrees/feat-t1", title: "t1"); named.name = "dev-t1"
        let card = try makeCard()
        do { try await flow(agents: [user]).requestFix(for: card, notes: "x"); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertEqual(error, .agentGone) }
        XCTAssertEqual(commander.prompts.count, 0)
        try await flow(agents: [user, named]).requestFix(for: card, notes: "x")
        XCTAssertEqual(commander.prompts.map(\.target), ["wT:p1"])
        do { try await flow(agents: [user]).passOnFixNotes(for: try reload(card)); XCTFail("should throw") } catch let error as ReviewError { XCTAssertEqual(error, .agentGone) }
    }

    func testRequestFixPromptFailureRestoresReviewStatus() async throws {
        let card = try makeCard()
        commander.error = BackendError.failed("pane closed")
        do { try await flow().requestFix(for: card, notes: "Please fix X."); XCTFail("should throw") }
        catch let error as ReviewError { guard case .failed(let m) = error else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("pane closed")) }
        let after = try reload(card)
        XCTAssertEqual(after.status, .review)
        XCTAssertTrue(after.sections["Fix notes"]?.contains("Please fix X.") == true, "the user's note is kept")
    }

    func testRequestFixRejectsEmptyNotes() async throws {
        let card = try makeCard()
        do { try await flow().requestFix(for: card, notes: "  \n "); XCTFail("should throw") }
        catch let error as ReviewError { guard case .invalid = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(commander.prompts.count, 0)
    }

    func testRequestFixFromDoingAndNeedsFixKeepsCardInNeedsFix() async throws {
        for status in ["doing", "needs-fix"] {
            let card = try makeCard(status: status)
            try await flow().requestFix(for: card, notes: "Fix from \(status).")
            let after = try reload(card)
            XCTAssertEqual(after.status, .needsFix, status)
            XCTAssertTrue(after.sections["Fix notes"]?.contains("Fix from \(status).") == true)
        }
        XCTAssertEqual(commander.prompts.count, 2)
    }

    func testRequestFixPromptFailureRestoresDoingStatus() async throws {
        let card = try makeCard(status: "doing")
        commander.error = BackendError.failed("pane closed")
        do { try await flow().requestFix(for: card, notes: "x"); XCTFail("should throw") }
        catch let error as ReviewError { guard case .failed = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try reload(card).status, .doing)
    }

    func testRequestFixRefusedForTodoDoneCancelled() async throws {
        for status in ["todo", "done", "cancelled"] {
            let card = try makeCard(status: status)
            do { try await flow().requestFix(for: card, notes: "x"); XCTFail("\(status) should throw") }
            catch let error as ReviewError { guard case .invalid = error else { return XCTFail("\(error)") } }
        }
        XCTAssertEqual(commander.prompts.count, 0)
    }

    // MARK: review findings

    func testNoteWithHeadingsStaysInsideFixNotes() async throws {
        let card = try makeCard()
        let before = Set(card.sections.keys)
        try await flow().requestFix(for: card, notes: "Two things:\n## Steps\n- one\n## Decision\nfake decision")
        let after = try reload(card)
        XCTAssertEqual(Set(after.sections.keys), before.union(["Fix notes"]), "no section was invented or split")
        XCTAssertTrue(after.sections["Fix notes"]?.contains("## Steps") == true)
        XCTAssertTrue(after.sections["Fix notes"]?.contains("fake decision") == true)
        XCTAssertEqual(after.sections["Decision"], "", "the real Decision section is still empty")
        try CardWriter().update(after, set: [:], section: SectionEdit(.decision, "Approved."), expectingStatus: .needsFix)
        let later = try reload(card)
        XCTAssertTrue(later.sections["Fix notes"]?.contains("fake decision") == true, "writing the decision does not eat the note")
        XCTAssertEqual(later.sections["Decision"], "Approved.")
    }

    func testManualCleanupCommandIsShellQuoted() async throws {
        let plan = try await flow().approvalPlan(for: try makeCard())
        let spaced = ApprovalPlan(card: plan.card, agentName: plan.agentName, branch: plan.branch, worktreePath: "/my repo/.agent-worktrees/feat-t1", base: plan.base,
                                  head: plan.head, ahead: plan.ahead, filesChanged: plan.filesChanged, screenshotCount: plan.screenshotCount, isAnalysis: plan.isAnalysis,
                                  commandPreview: plan.commandPreview)
        do { try await flow(writer: FailingWriter()).approve(spaced); XCTFail("should throw") }
        catch let error as ReviewError {
            guard case .mergedButIncomplete(_, _, let manual) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(manual.contains("'/my repo/.agent-worktrees/feat-t1'"), manual)
        }
    }

    // MARK: close a task whose agent is gone

    func testCloseTaskWithoutAnAgentMarksItDoneAndRunsNothing() async throws {
        for status in ["review", "doing", "needs-fix"] {
            let card = try makeCard(status: status, agent: "", id: "C\(status.count)")
            try await flow().closeTask(card)
            let after = try reload(card)
            XCTAssertEqual(after.status, .cancelled, status)
            XCTAssertTrue(after.sections["Decision"]?.contains("Cancelled") == true)
            XCTAssertTrue(after.sections["Decision"]?.contains("without merge") == true)
            XCTAssertEqual(after.sections["Report"], "Done.")
        }
        XCTAssertEqual(scripts.calls, [])
        XCTAssertEqual(commander.prompts.count, 0)
    }

    func testCloseTaskWhenTheWorktreeIsGone() async throws {
        let card = try makeCard()   // agent and branch are set, but /repo/.agent-worktrees/feat-t1 does not exist
        try await flow().closeTask(card)
        XCTAssertEqual(try reload(card).status, .cancelled)
    }

    func testCloseTaskIsRefusedWhileTheAgentAndWorktreeStillExist() async throws {
        repoPath = dir.url.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repoPath + "/.agent-worktrees/feat-t1", withIntermediateDirectories: true)
        let card = try makeCard()
        do { try await flow().closeTask(card); XCTFail("should throw") }
        catch let error as ReviewError { guard case .invalid(let m) = error else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("Approve")) }
        XCTAssertEqual(try reload(card).status, .review)
    }

    func testCloseTaskOnlyForTasksThatHoldAnAgent() async throws {
        for status in ["todo", "awaiting-start-approval", "done", "blocked"] {
            let card = try makeCard(status: status, agent: "", id: "D\(status.count)")
            do { try await flow().closeTask(card); XCTFail("\(status) should be refused") }
            catch let error as ReviewError { guard case .invalid = error else { return XCTFail("\(error)") } }
        }
    }

    func testMissingAgentMessageSaysWhatToDo() async throws {
        let card = try makeCard(agent: "")
        do { _ = try await flow().approvalPlan(for: card); XCTFail("should throw") }
        catch let error as ReviewError { XCTAssertTrue(error.message.contains("Close task"), error.message) }
    }
}
