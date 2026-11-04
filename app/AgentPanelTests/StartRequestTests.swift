import XCTest
@testable import AgentPanel

@MainActor
final class StartRequestTests: XCTestCase {
    private var dir: TempDir!
    private var requests: URL { dir.url.appendingPathComponent(".tentacl/start-requests") }

    override func setUpWithError() throws { dir = try TempDir() }

    private func card(_ id: String, _ status: TaskStatus = .todo, deps: String? = nil, files: [String]? = nil, kind: String? = nil) -> TaskCard {
        var sections = ["Goal": "Goal of \(id)."]
        if let deps { sections["Dependencies"] = deps }
        return TaskCard(id: id, project: "d", status: status, agent: nil, branch: nil, kind: kind, files: files ?? ["App/\(id).swift"], title: "Title \(id)",
                        sections: sections, url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func write(_ id: String, cards: [String], words: String = "start N18 and N19", by: String = "pm", key: String? = nil) throws {
        var json: [String: Any] = ["id": id, "requestedBy": by, "userWords": words, "cards": cards]
        if let key { json["key"] = key }
        try dir.write(".tentacl/start-requests/\(id).json", String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private struct Rig {
        let handler: StartRequestHandler
        let round: RoundModel
        /// The round model the handler uses for the project "other" (not the open one).
        let otherRound: RoundModel
        let started: Box<[String]>
        let told: Box<[(pane: String, text: String)]>
        let recorded: Box<[StartRequestOutcome]>
        let log: ActionLog
        let selected: Box<String?>
    }

    private func rig(cards: [TaskCard], mode: AutopilotMode, authority: PMAuthority = PMAuthority(), maxParallel: Int = 3, failStart: Set<String> = [], planFails: Set<String> = [],
                     pm: Box<String?> = Box("p-pm"), noPMIn: Set<String> = [], told shared: Box<[(pane: String, text: String)]>? = nil,
                     conflict: @escaping (Box<String?>, TaskCard, TaskCard) -> String? = { _, _, _ in nil },
                     onStart: @escaping (Box<String?>, String) -> Void = { _, _ in }) throws -> Rig {
        let selected = Box<String?>("d")
        let started = Box<[String]>([]), told = shared ?? Box<[(pane: String, text: String)]>([]), recorded = Box<[StartRequestOutcome]>([])
        func makeRound(_ project: @escaping () -> String?) -> RoundModel {
            RoundModel(
                enabled: { true }, cards: { cards }, maxParallel: { maxParallel }, projectName: { "Demo" },
                propose: { _ in throw PMDecisionError.failed("not used") },
                planStart: { c in planFails.contains(c.id) ? .failure(.invalid("no role called \"dev\"")) :
                    .success(StartPlan(card: c, agentName: "dev-\(c.id.lowercased())", branch: "task/\(c.id.lowercased())", rolePath: "/roles/dev.json",
                                       worktreePath: "/wt/\(c.id)", commandPreview: "spawn-agent.sh", roleName: "dev")) },
                conflict: { a, b in conflict(selected, a, b) },
                start: { p in started.value.append(p.card.id); onStart(selected, p.card.id); return failStart.contains(p.card.id) ? "The agent could not be started: boom" : nil },
                record: { _ in }, projectID: project)
        }
        let round = makeRound { selected.value }, otherRound = makeRound { "other" }
        let log = ActionLog(fileURL: dir.url.appendingPathComponent("actions.log"))
        let handler = StartRequestHandler(projects: { ["d", "other"] }, selected: { selected.value },
                                          store: { StartRequestStore(dir: $0 == "d" ? self.requests : self.dir.url.appendingPathComponent(".tentacl/other-requests")) },
                                          mode: { _ in mode }, round: { $0 == "d" ? round : otherRound }, pmPane: { noPMIn.contains($0) ? nil : pm.value },
                                          tell: { pane, text in told.value.append((pane, text)) }, record: { _, outcome in recorded.value.append(outcome) }, log: log,
                                          authority: { _ in authority }, card: { _, id in cards.first { $0.id == id } })
        return Rig(handler: handler, round: round, otherRound: otherRound, started: started, told: told, recorded: recorded, log: log, selected: selected)
    }

    private var cards: [TaskCard] { [card("N18"), card("N19")] }
    private func remaining() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []).filter { $0.hasSuffix(".json") } }

    func testRequestLineNamesTheProject() async throws {
        let r = try rig(cards: cards, mode: .on)
        say(r); try write("r1", cards: ["N18"])
        await r.handler.process()
        XCTAssertTrue(r.log.read().contains(" [d] start-request r1"), r.log.read())
    }

    func testAChatBackedRequestStartsTheCardsInOnMode() async throws {
        let r = try rig(cards: cards, mode: .on)
        say(r); try write("r1", cards: ["N18", "N19"])
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18", "N19"])
        XCTAssertFalse(r.round.isOpen, "no sheet")
        XCTAssertEqual(remaining(), [], "the request is consumed")
        XCTAssertEqual(r.recorded.value.count, 1)
        XCTAssertEqual(r.recorded.value[0].result, .started)
        XCTAssertEqual(r.recorded.value[0].started, ["N18", "N19"])
        XCTAssertEqual(r.told.value.map(\.pane), ["p-pm"])
        XCTAssertTrue(r.told.value[0].text.contains("N18") && r.told.value[0].text.lowercased().contains("started"), r.told.value[0].text)
        XCTAssertTrue(r.log.read().contains("start-request r1"), r.log.read())
    }

    func testAwaitingStartApprovalCardsCanBeStarted() async throws {
        let r = try rig(cards: [card("N18", .awaitingStartApproval)], mode: .on)
        say(r); try write("r1", cards: ["N18"])
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18"])
    }

    func testShadowAndOffOpenTheSheetWithTheCardsTicked() async throws {
        for mode in [AutopilotMode.shadow, .off] {
            let r = try rig(cards: cards, mode: mode)
            say(r); try write("r1", cards: ["N18", "N19"])
            await r.handler.process()
            XCTAssertEqual(r.started.value, [], "\(mode)")
            guard case .ready(let round) = r.round.state else { return XCTFail("\(mode): \(r.round.state)") }
            XCTAssertEqual(round.items.map(\.card.id), ["N18", "N19"])
            XCTAssertTrue(round.items.allSatisfy(\.ticked))
            XCTAssertEqual(r.recorded.value.first?.result, .sheet)
            XCTAssertTrue(r.told.value[0].text.contains("Round sheet"), r.told.value[0].text)
            XCTAssertEqual(remaining(), [])
        }
    }

    func testARequestWithoutAMatchingUserMessageOpensTheSheet() async throws {
        let r = try rig(cards: cards, mode: .on)
        try write("r1", cards: ["N18"], words: "start N18")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        guard case .ready = r.round.state else { return XCTFail("\(r.round.state)") }
        XCTAssertTrue(r.told.value[0].text.contains("did not see"), r.told.value[0].text)
    }

    func testAnOldOrAlreadyUsedUserMessageDoesNotBackARequest() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let box = Box(clock)
        let r = try rig(cards: cards, mode: .on)
        r.handler.now = { box.value }
        say(r, "start N18")
        clock = clock.addingTimeInterval(StartRequestHandler.chatWindow + 60); box.value = clock
        try write("old", cards: ["N18"], words: "start N18")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [], "the message is too old")
        r.round.close()
        say(r, "start N19")
        try write("a", cards: ["N19"], words: "start N19")
        try write("b", cards: ["N19"], words: "start N19")
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N19"], "one message backs one request")
        if case .ready = r.round.state {} else { XCTFail("the second request opened the sheet: \(r.round.state)") }
    }

    func testAMessageThatDoesNotContainTheWordsIsNotTheUsers() async throws {
        let r = try rig(cards: cards, mode: .on)
        r.handler.noteCommand("start N18", to: "p-pm", project: "d")
        try write("r1", cards: ["N18"], words: "something the user never typed")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
    }

    func testBadRequestsAreRefusedWithAReason() async throws {
        let all = [card("N18"), card("RUN", .doing), card("BLK", .blocked), card("DONE", .done), card("DEP", deps: "- N18 (first)"), card("NOROLE")]
        let r = try rig(cards: all, mode: .on, planFails: ["NOROLE"])
        say(r, "start N18 RUN BLK DONE DEP NOROLE NOPE")
        try write("r1", cards: ["N18", "RUN", "BLK", "DONE", "DEP", "NOROLE", "NOPE"], words: "start N18 RUN BLK DONE DEP NOROLE NOPE")
        await r.handler.process()
        let outcome = try XCTUnwrap(r.recorded.value.first)
        XCTAssertEqual(r.started.value, ["N18"], "only what the panel accepted")
        XCTAssertEqual(outcome.started, ["N18"])
        let why = Dictionary(outcome.refused.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(why["RUN"]?.contains("doing") == true, "\(why)")
        XCTAssertTrue(why["BLK"]?.contains("blocked") == true, "\(why)")
        XCTAssertTrue(why["DONE"]?.contains("done") == true, "\(why)")
        XCTAssertTrue(why["DEP"]?.contains("N18") == true, "\(why)")
        XCTAssertTrue(why["NOROLE"]?.contains("no role") == true, "\(why)")
        XCTAssertTrue(why["NOPE"]?.contains("no such card") == true, "\(why)")
        for id in why.keys { XCTAssertTrue(r.told.value[0].text.contains(id), "the PM is told about \(id)") }
    }

    func testNothingStartableIsRefusedWithoutASheet() async throws {
        let r = try rig(cards: [card("RUN", .doing)], mode: .on)
        say(r, "start RUN"); try write("r1", cards: ["RUN"], words: "start RUN")
        await r.handler.process()
        XCTAssertFalse(r.round.isOpen)
        XCTAssertEqual(r.recorded.value.first?.result, .refused)
        XCTAssertTrue(r.told.value[0].text.contains("RUN"), r.told.value[0].text)
    }

    func testCardsOverTheLimitAreRefused() async throws {
        let all = [card("RUN", .doing), card("A"), card("B")]
        let r = try rig(cards: all, mode: .on, maxParallel: 2)
        say(r, "start A and B"); try write("r1", cards: ["A", "B"], words: "start A and B")
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["A"])
        XCTAssertTrue(r.recorded.value[0].refused.first { $0.id == "B" }?.reason.contains("limit") == true, "\(r.recorded.value[0].refused)")
        let full = try rig(cards: [card("RUN", .doing), card("A")], mode: .on, maxParallel: 1)
        say(full, "start A"); try write("r2", cards: ["A"], words: "start A")
        await full.handler.process()
        XCTAssertEqual(full.started.value, [])
        XCTAssertTrue(full.recorded.value[0].refused.first?.reason.contains("slot") == true, "\(full.recorded.value[0].refused)")
    }

    func testAFailedStartRollsBackAndStopsTheRest() async throws {
        let r = try rig(cards: [card("A"), card("B"), card("C")], mode: .on, failStart: ["B"])
        say(r, "start A B C"); try write("r1", cards: ["A", "B", "C"], words: "start A B C")
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["A", "B"], "C is not tried after B failed")
        let outcome = r.recorded.value[0]
        XCTAssertEqual(outcome.started, ["A"])
        XCTAssertTrue(outcome.failure?.contains("B failed to start") == true, outcome.failure ?? "")
        XCTAssertTrue(outcome.failure?.contains("Not started: C") == true, outcome.failure ?? "")
        XCTAssertTrue(r.told.value[0].text.contains("boom"), r.told.value[0].text)
        XCTAssertFalse(r.round.isOpen)
    }

    func testRequestsFromAnyoneButThePMOrBrokenFilesAreRefused() async throws {
        let r = try rig(cards: cards, mode: .on)
        say(r, "start N18")
        try write("dev", cards: ["N18"], words: "start N18", by: "dev")
        try dir.write(".tentacl/start-requests/broken.json", "{ nope")
        try write("empty", cards: [], words: "start N18")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        XCTAssertEqual(remaining(), [], "all consumed")
        XCTAssertEqual(r.recorded.value.count, 3)
        XCTAssertTrue(r.recorded.value.allSatisfy { $0.result == .refused })
    }

    func testARequestWaitsWhileTheRoundSheetIsBusy() async throws {
        let r = try rig(cards: cards, mode: .shadow)
        say(r, "start N18"); try write("first", cards: ["N18"], words: "start N18")
        await r.handler.process()
        guard case .ready = r.round.state else { return XCTFail("\(r.round.state)") }
        say(r, "start N19"); try write("second", cards: ["N19"], words: "start N19")
        await r.handler.process()
        XCTAssertEqual(remaining(), ["second.json"], "it waits for the open sheet instead of replacing it")
        XCTAssertEqual(r.recorded.value.count, 1)
        r.round.close()
        await r.handler.process()
        XCTAssertEqual(remaining(), [])
        guard case .ready(let round) = r.round.state else { return XCTFail("\(r.round.state)") }
        XCTAssertEqual(round.items.map(\.card.id), ["N19"])
    }

    // MARK: N49: what backs a request

    func testAOneWordOrUnrelatedMessageDoesNotBackARequest() async throws {
        for (said, words) in [("the", "the"), ("ok", "ok"), ("please start it", "start it"), ("start N18 please now", "now"), ("N18", "start N18")] {
            let r = try rig(cards: cards, mode: .on)
            say(r, said); try write("r1", cards: ["N18"], words: words)
            await r.handler.process()
            XCTAssertEqual(r.started.value, [], "\"\(said)\" must not back \"\(words)\"")
        }
    }

    func testTheQuotedWordsMustBeTheWholeMessageOrAtLeastThreeWords() async throws {
        let whole = try rig(cards: cards, mode: .on)
        say(whole, "Start N18"); try write("r1", cards: ["N18"], words: "start n18")
        await whole.handler.process()
        XCTAssertEqual(whole.started.value, ["N18"], "the whole message")
        let part = try rig(cards: cards, mode: .on)
        say(part, "hello, please start N18 right now"); try write("r1", cards: ["N18"], words: "please start N18")
        await part.handler.process()
        XCTAssertEqual(part.started.value, ["N18"], "three words of it")
    }

    func testEveryRequestedCardIdMustAppearInTheMessage() async throws {
        let r = try rig(cards: cards, mode: .on)
        say(r, "please start N18 right now"); try write("r1", cards: ["N18", "N19"], words: "please start N18 right now")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [], "N19 is not in the user's message")
        guard case .ready = r.round.state else { return XCTFail("\(r.round.state)") }
    }

    func testAMessageToAnotherProjectDoesNotBackARequest() async throws {
        let r = try rig(cards: cards, mode: .on)
        r.handler.noteCommand("please start N18 right now", to: "p-pm", project: "other")
        try write("r1", cards: ["N18"], words: "please start N18 right now")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
    }

    func testARestoredMessageKeepsItsTimeSoTheWindowDoesNotGrow() async throws {
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        let r = try rig(cards: cards, mode: .on)
        r.handler.now = { clock.value }
        try write("pre", cards: ["N19"], words: "nobody said this at all")
        await r.handler.process()   // an unbacked request opens the sheet, so it is in use
        guard case .ready = r.round.state else { return XCTFail("\(r.round.state)") }
        say(r, "please start N18 right now"); try write("r1", cards: ["N18"], words: "please start N18 right now")
        for _ in 0..<3 { clock.value = clock.value.addingTimeInterval(240); await r.handler.process() }   // 12 minutes
        XCTAssertEqual(remaining(), ["r1.json"], "still waiting")
        r.round.close()
        await r.handler.process()
        XCTAssertEqual(r.started.value, [], "the message is older than the window by now")
    }

    private func writeOther(_ id: String, cards: [String], words: String, key: String? = nil) throws {
        var json: [String: Any] = ["id": id, "requestedBy": "pm", "userWords": words, "cards": cards]
        if let key { json["key"] = key }
        try dir.write(".tentacl/other-requests/\(id).json", String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }
    private func remainingOther() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent(".tentacl/other-requests").path)) ?? []).filter { $0.hasSuffix(".json") } }

    /// N208: a project that is not open is served like the open one.
    func testARequestOfAProjectThatIsNotOpenIsStartedWhenItsOwnMessageBacksIt() async throws {
        let r = try rig(cards: cards, mode: .on)
        r.handler.noteCommand("please start N18 right now", to: "p-pm", project: "other")
        try writeOther("x", cards: ["N18"], words: "please start N18 right now")
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18"])
        XCTAssertEqual(r.recorded.value.first?.result, .started)
        XCTAssertEqual(remainingOther(), [], "consumed")
        XCTAssertFalse(r.round.isOpen)
    }

    func testARequestOfAProjectThatIsNotOpenIsCheckedAgainstItsOwnKey() async throws {
        let r = try rig(cards: cards, mode: .shadow, authority: on())
        let own = r.handler.memory.key(project: "other", pane: "p-pm")
        try writeOther("x", cards: ["N18"], words: "", key: key(r))   // the open project's key is wrong for "other"
        try writeOther("y", cards: ["N19"], words: "", key: own)
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N19"], "only the request with the project's own key was carried out under the authority")
        XCTAssertEqual(remainingOther(), ["x.json"], "the keyless one needs the sheet, which only an open project has")
    }

    func testARequestThatNeedsTheSheetWaitsUntilItsProjectIsOpened() async throws {
        let r = try rig(cards: cards, mode: .shadow)
        try writeOther("x", cards: ["N18"], words: "start N18")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        XCTAssertEqual(remainingOther(), ["x.json"], "left on disk")
        XCTAssertEqual(r.recorded.value, [])
        XCTAssertEqual(r.told.value.count, 0, "nothing is told while it waits")
        r.selected.value = "other"
        await r.handler.process()
        XCTAssertEqual(remainingOther(), [])
        XCTAssertEqual(r.recorded.value.first?.result, .sheet)
    }

    func testAProjectSwitchMidRequestStopsIt() async throws {
        let before = try rig(cards: cards, mode: .on, conflict: { selected, _, _ in selected.value = "other"; return nil })
        say(before, "start N18 and N19"); try write("r1", cards: ["N18", "N19"], words: "start N18 and N19")
        await before.handler.process()
        XCTAssertEqual(before.started.value, [], "switched while the cards were checked")
        let between = try rig(cards: cards, mode: .on, onStart: { selected, _ in selected.value = "other" })
        say(between, "start N18 and N19"); try write("r1", cards: ["N18", "N19"], words: "start N18 and N19")
        await between.handler.process()
        XCTAssertEqual(between.started.value, ["N18"], "N19 is not started in the other project")
        XCTAssertTrue(between.recorded.value[0].failure?.contains("project") == true, between.recorded.value[0].failure ?? "")
    }

    private func say(_ r: Rig, _ text: String = "Please start N18 and N19 now") { r.handler.noteCommand(text, to: "p-pm", project: "d") }

    // MARK: standing PM authority (N86)

    /// The key the panel holds for the PM pane `p-pm` of project `d`.
    private func key(_ r: Rig) -> String { r.handler.memory.key(project: "d", pane: "p-pm") }

    private func on(startsPerDay: Int = 6, startedToday: Int = 0, costLimitReached: Bool = false) -> PMAuthority {
        PMAuthority(enabled: true, startsPerDay: startsPerDay, startedToday: startedToday, costLimitReached: costLimitReached)
    }

    func testAnEmptyWordsRequestIsReadable() throws {
        try write("r1", cards: ["N18"], words: "")
        let pending = StartRequestStore(dir: requests).pending()
        XCTAssertEqual(pending.first?.request?.cards, ["N18"], pending.first?.problem ?? "")
    }

    func testPolicyKeepsTheAuthorityRuleOffByDefaultAndClamped() throws {
        XCTAssertFalse(AutopilotPolicy().pmAuthority)
        XCTAssertEqual(AutopilotPolicy().pmStartsPerDay, 6)
        var p = AutopilotPolicy(); p.pmAuthority = true; p.pmStartsPerDay = 3
        let back = try JSONDecoder().decode(AutopilotPolicy.self, from: JSONEncoder().encode(p))
        XCTAssertTrue(back.pmAuthority); XCTAssertEqual(back.pmStartsPerDay, 3)
        XCTAssertEqual(try JSONDecoder().decode(AutopilotPolicy.self, from: Data(#"{"pmStartsPerDay":0}"#.utf8)).pmStartsPerDay, 1)
        XCTAssertFalse(try JSONDecoder().decode(AutopilotPolicy.self, from: Data("{}".utf8)).pmAuthority)
    }

    func testWithTheAuthorityOnARequestWithoutWordsStartsTheCards() async throws {
        let r = try rig(cards: cards, mode: .shadow, authority: on())
        try write("r1", cards: ["N18", "N19"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18", "N19"])
        XCTAssertFalse(r.round.isOpen)
        XCTAssertTrue(r.recorded.value[0].authority)
        XCTAssertEqual(r.recorded.value[0].result, .started)
        XCTAssertTrue(r.log.read().contains("PM authority"), r.log.read())
        XCTAssertTrue(r.told.value.last!.text.contains("started N18, N19"), r.told.value.last!.text)
    }

    func testUserWordsThatBackTheRequestKeepTheOldPathUntagged() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on())
        say(r); try write("r1", cards: ["N18", "N19"], key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18", "N19"])
        XCTAssertFalse(r.recorded.value[0].authority, "the user's own message backed it")
        XCTAssertFalse(r.log.read().contains("PM authority"))
    }

    func testWordsTheUserNeverSaidAreRecordedWhenTheAuthorityStarts() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on())
        try write("r1", cards: ["N18"], words: "start N18", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18"])
        XCTAssertEqual(r.recorded.value[0].words, "start N18")
        XCTAssertTrue(r.recorded.value[0].authority)
    }

    func testWithTheAuthorityOffNothingChangesNoWordsOpensTheSheet() async throws {
        let r = try rig(cards: cards, mode: .on)
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        guard case .ready = r.round.state else { return XCTFail("\(r.round.state)") }
        XCTAssertFalse(r.recorded.value[0].authority)
    }

    func testTheDailyCountCapsHowManyCardsStart() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on(startsPerDay: 6, startedToday: 5))
        try write("r1", cards: ["N18", "N19"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18"])
        XCTAssertEqual(r.recorded.value[0].refused.map(\.id), ["N19"])
        XCTAssertTrue(r.recorded.value[0].refused[0].reason.contains("6"), r.recorded.value[0].refused[0].reason)
    }

    func testNothingStartsOnceTheDailyCountIsUsedUp() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on(startsPerDay: 6, startedToday: 6))
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        XCTAssertFalse(r.round.isOpen, "no sheet either: the limit is for the PM")
        XCTAssertEqual(r.recorded.value[0].result, .refused)
        XCTAssertTrue(r.told.value.last!.text.contains("limit"), r.told.value.last!.text)
    }

    func testSetupCardsAreNeverStartedByTheAuthority() async throws {
        let r = try rig(cards: [card("S1", kind: "setup"), card("N19")], mode: .on, authority: on())
        try write("r1", cards: ["S1", "N19"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N19"])
        XCTAssertEqual(r.recorded.value[0].refused.map(\.id), ["S1"])
        XCTAssertTrue(r.recorded.value[0].refused[0].reason.contains("setup"))
    }

    func testTheDailyCostLimitStopsTheAuthority() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on(costLimitReached: true))
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        XCTAssertEqual(r.recorded.value[0].result, .refused)
        XCTAssertTrue(r.told.value.last!.text.contains("cost limit"), r.told.value.last!.text)
    }

    func testTheUsualChecksStillApplyUnderTheAuthority() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on(), maxParallel: 1, planFails: ["N19"])
        try write("r1", cards: ["N18", "N19"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18"])
        XCTAssertEqual(r.recorded.value[0].refused.map(\.id), ["N19"])
    }

    // MARK: session key (N91)

    func testARequestWithoutAKeyIsJudgedAsIfTheAuthorityWereOff() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on())
        try write("r1", cards: ["N18"], words: "")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        guard case .ready = r.round.state else { return XCTFail("\(r.round.state)") }
        XCTAssertFalse(r.recorded.value[0].authority)
        XCTAssertTrue(r.told.value.last!.text.contains("--key"), r.told.value.last!.text)
        XCTAssertFalse(r.log.read().contains("wrong key"), "a missing key is not a wrong one")
    }

    func testTheWrongKeyNoteSaysWhatToDoAndNotToResend() {
        let note = keyNote(.wrong, authorityOn: true) ?? ""
        XCTAssertTrue(note.contains("--key") && note.contains("do not send it again"), note)
    }

    func testAWrongKeyNeverUsesTheAuthorityAndIsLogged() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on())
        try write("r1", cards: ["N18"], words: "", key: "not-the-key")
        await r.handler.process()
        XCTAssertEqual(r.started.value, [])
        XCTAssertFalse(r.recorded.value[0].authority)
        XCTAssertTrue(r.log.read().contains("wrong key"), r.log.read())
        XCTAssertTrue(r.recorded.value[0].failure?.contains("wrong key") == true, "the decision feed shows it: \(r.recorded.value[0].failure ?? "nil")")
        XCTAssertFalse(r.log.read().contains("not-the-key"))
        XCTAssertFalse(r.told.value.contains { $0.text.contains("not-the-key") })
    }

    func testAWrongKeyStillLetsTheUsersOwnWordsBackTheRequest() async throws {
        let r = try rig(cards: cards, mode: .on, authority: on())
        say(r); try write("r1", cards: ["N18", "N19"], key: "nope")
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18", "N19"])
        XCTAssertFalse(r.recorded.value[0].authority)
        let told = r.told.value.map(\.text).joined()
        XCTAssertTrue(told.contains("do not send it again"), told)
        XCTAssertFalse(told.contains("sent to the user"), told)
    }

    func testTheRightKeyUsesTheAuthority() async throws {
        let r = try rig(cards: cards, mode: .shadow, authority: on())
        try write("r1", cards: ["N18"], words: "", key: key(r))
        await r.handler.process()
        XCTAssertEqual(r.started.value, ["N18"])
        XCTAssertTrue(r.recorded.value[0].authority)
        XCTAssertFalse(r.log.read().contains("wrong key"))
    }

    func testTheKeyIsLongRandomAndPerSession() {
        let m = CommandMemory()
        let a = m.key(project: "d", pane: "p1")
        XCTAssertGreaterThanOrEqual(a.count, 32, "at least 128 bits as hex")
        XCTAssertEqual(m.key(project: "d", pane: "p1"), a, "stable within a session")
        XCTAssertNotEqual(CommandMemory().key(project: "d", pane: "p1"), a)
        XCTAssertNotEqual(m.key(project: "other", pane: "p1"), a, "another project has its own")
    }

    func testANewPMSessionGetsANewKeyAndTheOldOneStopsWorking() {
        let m = CommandMemory()
        let old = m.key(project: "d", pane: "p1")
        XCTAssertTrue(m.accepts(old, project: "d", pane: "p1"))
        XCTAssertFalse(m.accepts(old, project: "d", pane: "p2"), "the PM moved to another pane")
        let new = m.key(project: "d", pane: "p2")
        XCTAssertNotEqual(new, old)
        XCTAssertFalse(m.accepts(old, project: "d", pane: "p2"))
        XCTAssertTrue(m.accepts(new, project: "d", pane: "p2"))
        XCTAssertFalse(m.accepts(nil, project: "d", pane: "p2"))
        XCTAssertFalse(m.accepts("", project: "d", pane: "p2"))
        XCTAssertFalse(CommandMemory().accepts(old, project: "d", pane: "p1"), "a restarted panel knows no old key")
    }

    func testThePMGetsTheKeyOnceWhenTheAuthorityIsOnAndAgainAfterTheSessionChanges() async throws {
        let pane = Box<String?>("p-pm")
        let told = Box<[(pane: String, text: String)]>([])
        let r = try rig(cards: cards, mode: .on, authority: on(), pm: pane, noPMIn: ["other"], told: told)
        await r.handler.process()
        XCTAssertEqual(told.value.count, 1)
        XCTAssertTrue(told.value[0].text.hasPrefix("Panel:") && told.value[0].text.contains(r.handler.memory.key(project: "d", pane: "p-pm")), told.value[0].text)
        XCTAssertTrue(told.value[0].text.hasPrefix("Panel: new authority key: ") && told.value[0].text.hasSuffix("(pass as --key)"), told.value[0].text)
        XCTAssertLessThan(told.value[0].text.count, 120, "one short line")
        await r.handler.process()
        XCTAssertEqual(told.value.count, 1, "only once per session")
        pane.value = "p-new"
        await r.handler.process()
        XCTAssertEqual(told.value.count, 2)
        XCTAssertEqual(told.value[1].pane, "p-new")
        XCTAssertTrue(told.value[1].text.contains(r.handler.memory.key(project: "d", pane: "p-new")))
    }

    func testEveryProjectsPMGetsItsOwnKeyNotOnlyTheOpenOne() async throws {
        let told = Box<[(pane: String, text: String)]>([])
        let r = try rig(cards: cards, mode: .on, authority: on(), told: told)
        await r.handler.process()
        XCTAssertEqual(told.value.count, 2, "one key for the open project's PM and one for the other's")
        XCTAssertTrue(told.value.contains { $0.text.contains(r.handler.memory.key(project: "d", pane: "p-pm")) })
        XCTAssertTrue(told.value.contains { $0.text.contains(r.handler.memory.key(project: "other", pane: "p-pm")) })
    }

    func testNoKeyIsSentWhileTheAuthorityIsOffOrNoPMRuns() async throws {
        let told = Box<[(pane: String, text: String)]>([])
        let off = try rig(cards: cards, mode: .on, told: told)
        await off.handler.process()
        XCTAssertEqual(told.value.count, 0)
        let none = try rig(cards: cards, mode: .on, authority: on(), pm: Box<String?>(nil), told: told)
        await none.handler.process()
        XCTAssertEqual(told.value.count, 0)
    }

    func testTheKeyNeverReachesTheDiskThroughThePanel() async throws {
        let r = try rig(cards: cards, mode: .shadow, authority: on())
        await r.handler.process()
        let k = key(r)
        try write("r1", cards: ["N18"], words: "", key: k)
        await r.handler.process()
        XCTAssertFalse(r.log.read().contains(k))
        XCTAssertFalse(r.recorded.value.contains { ($0.message + $0.words + ($0.failure ?? "")).contains(k) })
        XCTAssertEqual(remaining(), [], "the request file that carried it is deleted")
    }
}
