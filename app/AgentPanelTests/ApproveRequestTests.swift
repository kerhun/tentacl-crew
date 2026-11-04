import XCTest
@testable import AgentPanel

@MainActor
final class ApproveRequestTests: XCTestCase {
    private var dir: TempDir!
    private var requests: URL { dir.url.appendingPathComponent(".tentacl/approve-requests") }

    override func setUpWithError() throws { dir = try TempDir() }

    private func card(_ id: String, _ status: TaskStatus = .review, kind: String? = nil, fixNotes: String? = nil) -> TaskCard {
        var sections = ["Goal": "Goal of \(id)."]
        if let fixNotes { sections["Fix notes"] = fixNotes }
        return TaskCard(id: id, project: "d", status: status, agent: "dev-\(id.lowercased())", branch: "task/\(id.lowercased())", kind: kind, files: ["App/\(id).swift"],
                 title: "Title \(id)", sections: sections, url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func write(_ id: String, cards: [String], words: String = "approve N18 and N19", by: String = "pm", key: String? = nil) throws {
        var json: [String: Any] = ["id": id, "requestedBy": by, "userWords": words, "cards": cards]
        if let key { json["key"] = key }
        try dir.write(".tentacl/approve-requests/\(id).json", String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private struct Rig {
        let handler: ApproveRequestHandler
        let memory: CommandMemory
        /// The project each prepare step ran for.
        let prepared: Box<[String]>
        let steps: Box<[String]>
        let opened: Box<[String]>
        let told: Box<[(pane: String, text: String)]>
        let recorded: Box<[ApproveRequestOutcome]>
        let log: ActionLog
        let selected: Box<String?>
    }

    /// `prepareFails` / `planFails` / `approveFails` map a card id to the reason that step gives.
    private func rig(cards: [TaskCard], mode: AutopilotMode, authority: PMAuthority = PMAuthority(), prepareFails: [String: String] = [:], planFails: [String: ReviewError] = [:],
                     approveFails: [String: String] = [:], ready: Bool = true, phases: [String: TaskPhase] = [:], pm: Box<String?> = Box("p-pm"),
                     onPrepare: @escaping (Box<String?>, String) -> Void = { _, _ in }) -> Rig {
        let selected = Box<String?>("d")
        let prepared = Box<[String]>([])
        let steps = Box<[String]>([]), opened = Box<[String]>([]), told = Box<[(pane: String, text: String)]>([]), recorded = Box<[ApproveRequestOutcome]>([])
        let memory = CommandMemory()
        let log = ActionLog(fileURL: dir.url.appendingPathComponent("actions.log"))
        let handler = ApproveRequestHandler(
            projects: { ["d", "other"] }, selected: { selected.value },
            store: { $0 == "d" ? StartRequestStore(dir: self.requests) : StartRequestStore(dir: self.dir.url.appendingPathComponent(".tentacl/other-approve")) },
            mode: { _ in mode }, memory: memory,
            card: { _, id in cards.first { $0.id == id } }, phase: { _, card in phases[card.id] ?? .finished }, ready: { _ in ready },
            prepare: { project, c in steps.value.append("prepare \(c.id)"); prepared.value.append(project); onPrepare(selected, c.id); return prepareFails[c.id] },
            plan: { _, c in
                steps.value.append("plan \(c.id)")
                if let e = planFails[c.id] { return .failure(e) }
                return .success(ApprovalPlan(card: c, agentName: c.agent ?? "", branch: c.branch ?? "", worktreePath: "/wt/\(c.id)", base: "main", head: "abc", ahead: 1,
                                             filesChanged: 1, screenshotCount: 1, isAnalysis: c.kind == "analysis", commandPreview: "merge-task.sh"))
            },
            approve: { _, p in steps.value.append((p.isAnalysis ? "approve-analysis " : "approve ") + p.card.id); return approveFails[p.card.id] },
            openSheet: { opened.value.append($0.id) }, pmPane: { _ in pm.value },
            tell: { pane, text in told.value.append((pane, text)) }, record: { _, outcome in recorded.value.append(outcome) }, log: log,
            authority: { _ in authority })
        return Rig(handler: handler, memory: memory, prepared: prepared, steps: steps, opened: opened, told: told, recorded: recorded, log: log, selected: selected)
    }

    private func remaining() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []).filter { $0.hasSuffix(".json") } }
    private func say(_ r: Rig, _ text: String = "Please approve N18 and N19 now") { r.memory.note(text, to: "p-pm", project: "d") }

    func testABackedRequestInOnModePreparesAndApproves() async throws {
        let r = rig(cards: [card("N18"), card("N19", .doing)], mode: .on)
        say(r); try write("r1", cards: ["N18", "N19"])
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare N18", "plan N18", "approve N18", "prepare N19", "plan N19", "approve N19"])
        XCTAssertEqual(r.opened.value, [], "no sheet")
        XCTAssertEqual(remaining(), [], "the request is consumed")
        let outcome = try XCTUnwrap(r.recorded.value.first)
        XCTAssertEqual(outcome.result, .approved)
        XCTAssertEqual(outcome.approved, ["N18", "N19"])
        XCTAssertEqual(r.told.value.map(\.pane), ["p-pm"])
        XCTAssertTrue(r.told.value[0].text.hasPrefix("Panel:") && r.told.value[0].text.contains("N18"), r.told.value[0].text)
        XCTAssertTrue(r.log.read().contains("approve-request r1"), r.log.read())
    }

    func testShadowAndOffOpenTheSheetForTheFirstCard() async throws {
        for mode in [AutopilotMode.shadow, .off] {
            let r = rig(cards: [card("N18"), card("N19")], mode: mode)
            say(r); try write("r1", cards: ["N18", "N19"])
            await r.handler.process()
            XCTAssertEqual(r.steps.value, [], "\(mode): nothing is prepared or merged")
            XCTAssertEqual(r.opened.value, ["N18"], "\(mode)")
            XCTAssertEqual(r.recorded.value.first?.result, .sheet)
            XCTAssertTrue(r.told.value[0].text.contains("Approve sheet"), r.told.value[0].text)
            XCTAssertEqual(remaining(), [])
        }
    }

    func testARequestWithoutAMatchingUserMessageOpensTheSheet() async throws {
        let r = rig(cards: [card("N18")], mode: .on)
        try write("r1", cards: ["N18"], words: "approve N18")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [])
        XCTAssertEqual(r.opened.value, ["N18"])
        XCTAssertTrue(r.told.value[0].text.contains("did not see"), r.told.value[0].text)
    }

    func testAFailedPacketIsNeverApprovedAndThePMGetsTheReason() async throws {
        let r = rig(cards: [card("N18"), card("N19")], mode: .on, prepareFails: ["N18": "The build failed: EVIDENCE MISSING"], planFails: ["N19": .stale])
        say(r, "approve both N18 N19"); try write("r1", cards: ["N18", "N19"], words: "approve both N18 N19")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare N18", "prepare N19", "plan N19"], "no approve step")
        let outcome = try XCTUnwrap(r.recorded.value.first)
        XCTAssertEqual(outcome.result, .refused)
        XCTAssertEqual(outcome.approved, [])
        XCTAssertTrue(outcome.refused.first { $0.id == "N18" }?.reason.contains("EVIDENCE MISSING") == true, "\(outcome.refused)")
        XCTAssertEqual(outcome.refused.map(\.id), ["N18", "N19"])
        XCTAssertTrue(r.told.value[0].text.contains("EVIDENCE MISSING") && r.told.value[0].text.contains("fix request"), r.told.value[0].text)
    }

    func testAnAnalysisCardIsApprovedWithoutAMerge() async throws {
        let r = rig(cards: [card("A1", .doing, kind: "analysis")], mode: .on)
        say(r, "approve A1"); try write("r1", cards: ["A1"], words: "approve A1")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare A1", "plan A1", "approve-analysis A1"])
        XCTAssertEqual(r.recorded.value.first?.approved, ["A1"])
    }

    func testCardsNotInDoingNeedsFixOrReviewAreRefused() async throws {
        let all = [card("TODO", .todo), card("DONE", .done), card("BLK", .blocked), card("OK", .needsFix)]
        let r = rig(cards: all, mode: .on)
        say(r, "approve TODO DONE BLK NOPE OK"); try write("r1", cards: ["TODO", "DONE", "BLK", "NOPE", "OK"], words: "approve TODO DONE BLK NOPE OK")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare OK", "plan OK", "approve OK"], "only what the panel accepted")
        let why = Dictionary(uniqueKeysWithValues: r.recorded.value[0].refused.map { ($0.id, $0.reason) })
        XCTAssertTrue(why["TODO"]?.contains("todo") == true, "\(why)")
        XCTAssertTrue(why["DONE"]?.contains("done") == true, "\(why)")
        XCTAssertTrue(why["NOPE"]?.contains("no such card") == true, "\(why)")
        let onlyBad = rig(cards: all, mode: .on)
        say(onlyBad, "approve TODO"); try write("r2", cards: ["TODO"], words: "approve TODO")
        await onlyBad.handler.process()
        XCTAssertEqual(onlyBad.opened.value, [], "nothing to open a sheet for")
        XCTAssertEqual(onlyBad.recorded.value.first?.result, .refused)
    }

    func testAFailedApproveStopsTheRest() async throws {
        let r = rig(cards: [card("A"), card("B"), card("C")], mode: .on, approveFails: ["B": "merge failed: boom"])
        say(r, "approve A B C"); try write("r1", cards: ["A", "B", "C"], words: "approve A B C")
        await r.handler.process()
        XCTAssertFalse(r.steps.value.contains("prepare C"))
        let outcome = try XCTUnwrap(r.recorded.value.first)
        XCTAssertEqual(outcome.approved, ["A"])
        XCTAssertTrue(outcome.failure?.contains("boom") == true && outcome.failure?.contains("Not approved: C") == true, outcome.failure ?? "")
    }

    func testAOneWordOrUnrelatedOrOtherProjectMessageDoesNotBackAnApprove() async throws {
        for (said, words) in [("ok", "ok"), ("please approve it", "approve it"), ("approve N19 now please", "now")] {
            let r = rig(cards: [card("N18")], mode: .on)
            say(r, said); try write("r1", cards: ["N18"], words: words)
            await r.handler.process()
            XCTAssertEqual(r.steps.value, [], "\"\(said)\" must not back \"\(words)\"")
            XCTAssertEqual(r.opened.value, ["N18"])
        }
        let other = rig(cards: [card("N18")], mode: .on)
        other.memory.note("please approve N18 right now", to: "p-pm", project: "other")
        try write("r2", cards: ["N18"], words: "please approve N18 right now")
        await other.handler.process()
        XCTAssertEqual(other.steps.value, [])
        let missing = rig(cards: [card("N18"), card("N19")], mode: .on)
        say(missing, "please approve N18 right now"); try write("r3", cards: ["N18", "N19"], words: "please approve N18 right now")
        await missing.handler.process()
        XCTAssertEqual(missing.steps.value, [], "N19 is not in the message")
    }

    func testADoingCardWhoseAgentIsStillWorkingIsRefused() async throws {
        let all = [card("W", .doing), card("F", .doing), card("R", .review), card("X", .needsFix)]
        let r = rig(cards: all, mode: .on, phases: ["W": .working, "F": .finished, "X": .working])
        say(r, "approve W F R X"); try write("r1", cards: ["W", "F", "R", "X"], words: "approve W F R X")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare F", "plan F", "approve F", "prepare R", "plan R", "approve R"])
        let why = Dictionary(uniqueKeysWithValues: r.recorded.value[0].refused.map { ($0.id, $0.reason) })
        XCTAssertTrue(why["W"]?.contains("working") == true && why["X"]?.contains("working") == true, "\(why)")
    }

    func testAProjectSwitchMidRequestDoesNotStopIt() async throws {
        let r = rig(cards: [card("A"), card("B")], mode: .on, onPrepare: { selected, _ in selected.value = "other" })
        say(r, "approve A and B"); try write("r1", cards: ["A", "B"], words: "approve A and B")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare A", "plan A", "approve A", "prepare B", "plan B", "approve B"], "every step belongs to the request's own project")
        XCTAssertEqual(r.prepared.value, ["d", "d"])
        XCTAssertEqual(r.recorded.value.first?.approved, ["A", "B"])
    }

    /// N208: a project that is not open is served like the open one.
    func testARequestOfAProjectThatIsNotOpenIsApprovedWhenItsOwnMessageBacksIt() async throws {
        let r = rig(cards: [card("N18")], mode: .on)
        r.memory.note("please approve N18 right now", to: "p-pm", project: "other")
        try dir.write(".tentacl/other-approve/x.json", "{\"id\":\"x\",\"requestedBy\":\"pm\",\"userWords\":\"please approve N18 right now\",\"cards\":[\"N18\"]}")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare N18", "plan N18", "approve N18"])
        XCTAssertEqual(r.prepared.value, ["other"])
        XCTAssertEqual(r.recorded.value.first?.result, .approved)
        XCTAssertEqual(r.opened.value, [])
    }

    func testARequestOfAProjectThatIsNotOpenWaitsWhenItWouldNeedTheSheet() async throws {
        let r = rig(cards: [card("N18")], mode: .shadow)
        try dir.write(".tentacl/other-approve/x.json", "{\"id\":\"x\",\"requestedBy\":\"pm\",\"userWords\":\"approve N18\",\"cards\":[\"N18\"]}")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [])
        XCTAssertEqual(r.recorded.value, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent(".tentacl/other-approve/x.json").path), "left on disk")
    }

    func testBadRequestsAreRefusedAndABusyPanelMakesItWait() async throws {
        let r = rig(cards: [card("N18")], mode: .on)
        say(r)
        try write("dev", cards: ["N18"], by: "dev")
        try dir.write(".tentacl/approve-requests/broken.json", "{ nope")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [])
        XCTAssertEqual(r.recorded.value.count, 2)
        XCTAssertTrue(r.recorded.value.allSatisfy { $0.result == .refused })
        let busy = rig(cards: [card("N18")], mode: .on, ready: false)
        say(busy); try write("r1", cards: ["N18"])
        await busy.handler.process()
        XCTAssertEqual(remaining(), ["r1.json"], "waits while the panel is busy")
        XCTAssertEqual(busy.recorded.value.count, 0)
    }

    // MARK: standing PM authority (N86)

    /// The key the panel holds for the PM pane `p-pm` of project `d`.
    private func key(_ r: Rig) -> String { r.memory.key(project: "d", pane: "p-pm") }

    private func on(startedToday: Int = 0, costLimitReached: Bool = false) -> PMAuthority {
        PMAuthority(enabled: true, startsPerDay: 6, startedToday: startedToday, costLimitReached: costLimitReached)
    }

    func testWithTheAuthorityOnARequestWithoutWordsApprovesAndIsTagged() async throws {
        let r = rig(cards: [card("N18")], mode: .shadow, authority: on())
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare N18", "plan N18", "approve N18"])
        XCTAssertEqual(r.opened.value, [])
        XCTAssertEqual(r.recorded.value[0].result, .approved)
        XCTAssertTrue(r.recorded.value[0].authority)
        XCTAssertTrue(r.log.read().contains("PM authority"), r.log.read())
    }

    func testWithTheAuthorityOffAnEmptyWordsRequestOpensTheSheet() async throws {
        let r = rig(cards: [card("N18")], mode: .on)
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [])
        XCTAssertEqual(r.opened.value, ["N18"])
        XCTAssertFalse(r.recorded.value[0].authority)
    }

    func testAUserBackedRequestStaysUntagged() async throws {
        let r = rig(cards: [card("N18")], mode: .on, authority: on())
        say(r, "approve N18 please"); try write("r1", cards: ["N18"], words: "approve N18 please", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.recorded.value[0].result, .approved)
        XCTAssertFalse(r.recorded.value[0].authority)
    }

    func testSetupCardsAreNeverApprovedByTheAuthority() async throws {
        let r = rig(cards: [card("S1", kind: "setup"), card("N18")], mode: .on, authority: on())
        try write("r1", cards: ["S1", "N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare N18", "plan N18", "approve N18"])
        XCTAssertEqual(r.recorded.value[0].refused.map(\.id), ["S1"])
        XCTAssertTrue(r.recorded.value[0].refused[0].reason.contains("setup"))
    }

    func testAFailedPacketABranchBehindMainAndOpenFixNotesAreRefused() async throws {
        let r = rig(cards: [card("A"), card("B"), card("C", .needsFix, fixNotes: "### 2026-10-18 · reviewer\nFix the thing.")], mode: .on, authority: on(),
                    planFails: ["A": .packetMissing("The build in the review packet did not pass."), "B": .notFastForward])
        try write("r1", cards: ["A", "B", "C"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.recorded.value[0].approved, [])
        XCTAssertEqual(Set(r.recorded.value[0].refused.map(\.id)), ["A", "B", "C"])
        XCTAssertFalse(r.steps.value.contains { $0.hasPrefix("approve") })
        XCTAssertTrue(r.recorded.value[0].refused.first { $0.id == "C" }?.reason.contains("Fix notes") == true)
    }

    func testACardWithAnOpenFixOrRebaseRequestIsRefusedWithItsReasonAndNeverApproved() async throws {
        let reason = "A fix request to dev-n18 is still open."
        let r = rig(cards: [card("N18")], mode: .on, authority: on(), planFails: ["N18": .invalid(reason)])
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertFalse(r.steps.value.contains { $0.hasPrefix("approve") })
        XCTAssertEqual(r.recorded.value[0].approved, [])
        XCTAssertTrue(r.recorded.value[0].refused.first?.reason.contains(reason) == true, "\(r.recorded.value[0].refused)")
    }

    func testTheDailyCostLimitStopsTheAuthorityApprovals() async throws {
        let r = rig(cards: [card("N18")], mode: .on, authority: on(costLimitReached: true))
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [])
        XCTAssertEqual(r.opened.value, [], "no sheet: the limit is for the PM")
        XCTAssertEqual(r.recorded.value[0].result, .refused)
        XCTAssertTrue(r.told.value.last!.text.contains("cost limit"), r.told.value.last!.text)
    }

    // MARK: session key (N91)

    func testARequestWithoutAKeyIsJudgedAsIfTheAuthorityWereOff() async throws {
        let r = rig(cards: [card("N18")], mode: .on, authority: on())
        try write("r1", cards: ["N18"], words: "")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [])
        XCTAssertEqual(r.opened.value, ["N18"])
        XCTAssertFalse(r.recorded.value[0].authority)
        XCTAssertTrue(r.told.value.last!.text.contains("--key"), r.told.value.last!.text)
        XCTAssertFalse(r.log.read().contains("wrong key"))
    }

    func testAWrongKeyNeverUsesTheAuthorityAndIsLogged() async throws {
        let r = rig(cards: [card("N18")], mode: .on, authority: on())
        try write("r1", cards: ["N18"], words: "", key: "not-the-key")
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [])
        XCTAssertEqual(r.opened.value, ["N18"])
        XCTAssertFalse(r.recorded.value[0].authority)
        XCTAssertTrue(r.log.read().contains("wrong key"), r.log.read())
        XCTAssertTrue(r.recorded.value[0].failure?.contains("wrong key") == true, r.recorded.value[0].failure ?? "nil")
        XCTAssertFalse(r.log.read().contains("not-the-key"))
        XCTAssertFalse(r.told.value.contains { $0.text.contains("not-the-key") })
    }

    func testAWrongKeyStillLetsTheUsersOwnWordsBackTheRequest() async throws {
        let r = rig(cards: [card("N18")], mode: .on, authority: on())
        say(r, "approve N18 please"); try write("r1", cards: ["N18"], words: "approve N18 please", key: "nope")
        await r.handler.process()
        XCTAssertEqual(r.recorded.value[0].result, .approved)
        XCTAssertFalse(r.recorded.value[0].authority)
    }

    func testTheRightKeyUsesTheAuthority() async throws {
        let r = rig(cards: [card("N18")], mode: .shadow, authority: on())
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.steps.value, ["prepare N18", "plan N18", "approve N18"])
        XCTAssertTrue(r.recorded.value[0].authority)
    }

    func testAKeyOfAnOldPMSessionIsWrongAndTheNewSessionGetsTheKey() async throws {
        let pane = Box<String?>("p-pm")
        let r = rig(cards: [card("N18")], mode: .shadow, authority: on(), pm: pane)
        let old = key(r)
        pane.value = "p-new"
        try write("r1", cards: ["N18"], words: "", key: old)
        await r.handler.process()
        XCTAssertEqual(r.steps.value, [], "the old key died with the old session")
        XCTAssertTrue(r.log.read().contains("wrong key"))
        XCTAssertTrue(r.told.value.contains { $0.pane == "p-new" && $0.text.contains(r.memory.key(project: "d", pane: "p-new")) })
        XCTAssertFalse(r.told.value.contains { $0.pane == "p-new" && $0.text.contains(old) })
    }
}
