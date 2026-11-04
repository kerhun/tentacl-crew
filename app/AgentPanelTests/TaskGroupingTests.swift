import XCTest
@testable import AgentPanel

final class TaskGroupingTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus) -> CardLoadResult {
        .card(TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md")))
    }

    func testReviewAndAwaitingStartShareTheDecisionSection() {
        let sections = TaskGrouping.sections(from: [card("A", .review), card("B", .awaitingStartApproval), card("C", .todo)])
        XCTAssertEqual(sections.map(\.title), ["Needs your decision", "Backlog"])
        XCTAssertEqual(sections[0].rows.count, 2)
    }

    func testSectionOrderAndEmptySectionsAreOmitted() {
        let sections = TaskGrouping.sections(from: [card("A", .done), card("B", .doing), card("C", .needsFix), card("D", .blocked)])
        XCTAssertEqual(sections.map(\.title), ["Doing", "Blocked", "Done"])
        XCTAssertEqual(sections[0].rows.count, 2)   // doing and needs-fix are both "in progress"
    }

    func testUnreadableCardsGetTheirOwnSectionLast() {
        let broken = CardLoadResult.unreadable(url: URL(fileURLWithPath: "/tmp/BROKEN.md"), reason: "no front matter")
        let sections = TaskGrouping.sections(from: [broken, card("A", .done)])
        XCTAssertEqual(sections.map(\.title), ["Done", "Unreadable cards"])
    }

    func testUnknownStatusLandsInBacklogWithItsOwnLabel() {
        let sections = TaskGrouping.sections(from: [card("A", .unknown("waiting"))])
        XCTAssertEqual(sections.map(\.title), ["Other"])
    }
}

final class FinishedSortTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    private func card(_ id: String, decision: String? = nil, modified: String? = nil, created: String? = nil, status: TaskStatus = .done) -> CardLoadResult {
        var c = TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id,
                         sections: decision.map { ["Decision": $0] } ?? [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
        c.modified = modified.map(date); c.created = created.map(date)
        return .card(c)
    }
    private func ids(_ rows: [CardLoadResult]) -> [String] { rows.compactMap { if case .card(let c) = $0 { return c.id } else { return nil } } }
    private func sort(_ rows: [CardLoadResult], _ key: FinishedSort.Key, newest: Bool = true) -> [String] {
        ids(TaskGrouping.sortFinished(rows, FinishedSort(key: key, newestFirst: newest), calendar: cal))
    }

    func testDefaultIsFinishedNewestFirst() {
        XCTAssertEqual(FinishedSort.default, FinishedSort(key: .finished, newestFirst: true))
    }

    func testDecisionDateWithTime() {
        let c = card("N1", decision: "Approved 2026-10-18 14:25 by the user.")
        guard case .card(let k) = c else { return XCTFail() }
        XCTAssertEqual(TaskGrouping.finishedDate(k, calendar: cal), date("2026-10-18 14:25"))
    }

    func testDecisionDateWithoutTimeIsMidnight() {
        guard case .card(let k) = card("N1", decision: "Approved 2026-10-18 by the user.") else { return XCTFail() }
        XCTAssertEqual(TaskGrouping.finishedDate(k, calendar: cal), date("2026-10-18 00:00"))
    }

    func testFinishedFallsBackToModified() {
        guard case .card(let k) = card("N1", modified: "2026-10-01 09:00") else { return XCTFail() }
        XCTAssertEqual(TaskGrouping.finishedDate(k, calendar: cal), date("2026-10-01 09:00"))
    }

    func testFinishedKeyBothDirections() {
        let rows = [card("N1", decision: "Approved 2026-10-10 by x"), card("N2", decision: "Approved 2026-10-12 08:00 by x"), card("N3", modified: "2026-10-11 10:00")]
        XCTAssertEqual(sort(rows, .finished), ["N2", "N3", "N1"])
        XCTAssertEqual(sort(rows, .finished, newest: false), ["N1", "N3", "N2"])
    }

    func testCreatedKeyBothDirections() {
        let rows = [card("N1", created: "2026-10-03 10:00"), card("N2", created: "2026-10-01 10:00"), card("N3", created: "2026-10-02 10:00")]
        XCTAssertEqual(sort(rows, .created), ["N1", "N3", "N2"])
        XCTAssertEqual(sort(rows, .created, newest: false), ["N2", "N3", "N1"])
    }

    func testUpdatedKeyBothDirections() {
        let rows = [card("N1", modified: "2026-10-03 10:00"), card("N2", modified: "2026-10-05 10:00"), card("N3", modified: "2026-10-04 10:00")]
        XCTAssertEqual(sort(rows, .updated), ["N2", "N3", "N1"])
        XCTAssertEqual(sort(rows, .updated, newest: false), ["N1", "N3", "N2"])
    }

    func testIdIsNumericAwareAndDirectionIsAscendingOrDescending() {
        let rows = [card("N78"), card("N5"), card("N10")]
        XCTAssertEqual(sort(rows, .id, newest: false), ["N5", "N10", "N78"])
        XCTAssertEqual(sort(rows, .id, newest: true), ["N78", "N10", "N5"])
    }

    func testTiesAreBrokenById() {
        let rows = [card("N9", modified: "2026-10-03 10:00"), card("N2", modified: "2026-10-03 10:00"), card("N30", modified: "2026-10-03 10:00")]
        XCTAssertEqual(sort(rows, .updated), ["N2", "N9", "N30"])
        XCTAssertEqual(sort(rows, .updated, newest: false), ["N2", "N9", "N30"])
    }

    func testCardsWithoutADateGoLast() {
        let rows = [card("N1"), card("N2", created: "2026-10-01 10:00")]
        XCTAssertEqual(sort(rows, .created), ["N2", "N1"])
        XCTAssertEqual(sort(rows, .created, newest: false), ["N2", "N1"])
    }

    func testOnlyDoneAndCancelledSectionsAreSorted() {
        let rows = [card("N1", modified: "2026-10-01 10:00", status: .todo), card("N2", modified: "2026-10-02 10:00", status: .todo),
                    card("N3", modified: "2026-10-01 10:00"), card("N4", modified: "2026-10-02 10:00"),
                    card("N5", modified: "2026-10-01 10:00", status: .cancelled), card("N6", modified: "2026-10-02 10:00", status: .cancelled)]
        let sections = TaskGrouping.sections(from: rows, finishedSort: FinishedSort(key: .updated, newestFirst: true), calendar: cal)
        XCTAssertEqual(sections.map { ids($0.rows) }, [["N1", "N2"], ["N4", "N3"], ["N6", "N5"]])
    }

    func testChoiceIsKeptPerProject() {
        let defaults = makeTestDefaults(prefix: "finished-sort-tests")
        XCTAssertEqual(FinishedSort.load(defaults, project: "a"), .default)
        FinishedSort(key: .id, newestFirst: false).save(defaults, project: "a")
        XCTAssertEqual(FinishedSort.load(defaults, project: "a"), FinishedSort(key: .id, newestFirst: false))
        XCTAssertEqual(FinishedSort.load(defaults, project: "b"), .default)
    }

    func testRowTimeShowsTheSortingDate() {
        guard case .card(let k) = card("N1", decision: "Approved 2026-10-10 by x", modified: "2026-10-12 10:00", created: "2026-10-01 10:00") else { return XCTFail() }
        XCTAssertEqual(TaskGrouping.rowDate(k, FinishedSort(key: .finished, newestFirst: true), calendar: cal), date("2026-10-10 00:00"))
        XCTAssertEqual(TaskGrouping.rowDate(k, FinishedSort(key: .created, newestFirst: true), calendar: cal), date("2026-10-01 10:00"))
        XCTAssertEqual(TaskGrouping.rowDate(k, FinishedSort(key: .updated, newestFirst: true), calendar: cal), date("2026-10-12 10:00"))
        XCTAssertEqual(TaskGrouping.rowDate(k, FinishedSort(key: .id, newestFirst: true), calendar: cal), date("2026-10-12 10:00"))
    }
}

/// The "By round" list (N135): groups from plan.json rounds, then the open cards in no round; finished rounds fold away.
final class RoundGroupingTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus, decision: String? = nil) -> TaskCard {
        TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id,
                 sections: decision.map { ["Decision": $0] } ?? [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }
    private func plan(_ rounds: [(String, [String])]) -> PlanFile {
        PlanFile(rounds: rounds.map { PlanRound(name: $0.0, cards: $0.1, reason: "", status: "") }, questions: [])
    }

    func testRoundsInPlanOrderUnfinishedFirstThenNotInARound() {
        let cards = [card("A", .done), card("B", .doing), card("C", .todo), card("D", .done), card("E", .todo), card("F", .review)]
        let groups = TaskGrouping.rounds(cards: cards, plan: plan([("Old", ["D"]), ("One", ["A", "B"]), ("Two", ["C", "F"])]))
        XCTAssertEqual(groups.open.map(\.name), ["One", "Two", "Not in a round"])
        XCTAssertEqual(groups.open[0].cards.map(\.id), ["A", "B"], "a done card stays in its round")
        XCTAssertEqual(groups.open[2].cards.map(\.id), ["E"], "only open cards outside every round")
        XCTAssertEqual(groups.finished.map(\.name), ["Old"], "a round whose cards are all done folds away")
        XCTAssertEqual(groups.open[0].progressText, "1 of 2 merged")
        XCTAssertEqual(groups.open[2].progressText, "1")
        XCTAssertFalse(groups.open[2].inPlan)
    }

    func testNoPlanPutsEveryOpenCardInNotInARound() {
        let groups = TaskGrouping.rounds(cards: [card("A", .todo), card("B", .done), card("C", .cancelled)], plan: nil)
        XCTAssertEqual(groups.open.map(\.name), ["Not in a round"])
        XCTAssertEqual(groups.open[0].cards.map(\.id), ["A"])
        XCTAssertTrue(groups.finished.isEmpty)
    }

    func testARoundWithACancelledCardFinishesWhenTheRestIsDoneAndUnknownIdsAreSkipped() {
        let groups = TaskGrouping.rounds(cards: [card("A", .done), card("B", .cancelled)], plan: plan([("R", ["A", "B", "ZZ"]), ("Empty", ["ZZ"])]))
        XCTAssertEqual(groups.finished.map(\.name), ["R"])
        XCTAssertEqual(groups.finished[0].cards.map(\.id), ["A", "B"])
        XCTAssertTrue(groups.open.isEmpty, "a round with no known card is not listed")
    }

    // N181: the Done tab lists each finished round with its cards, then the finished cards in no round.
    func testDoneListsFinishedRoundsNewestFirstWithTheirCardsThenNotInARound() {
        var old = card("X", .done); old.modified = Date(timeIntervalSince1970: 100)
        var newer = card("Y", .cancelled); newer.modified = Date(timeIntervalSince1970: 200)
        let cards = [card("A", .done), card("B", .cancelled), card("C", .done), card("D", .done), card("E", .doing), old, newer, card("T", .todo)]
        let p = plan([("Old", ["A", "B"]), ("Mid", ["D", "E"]), ("New", ["C"])])
        let groups = TaskGrouping.doneGroups(cards: cards, plan: p)
        XCTAssertEqual(groups.map(\.name), ["New", "Old", "Not in a round"], "newest finished round first; an unfinished round is not on Done")
        XCTAssertEqual(groups[1].cards.map(\.id), ["A", "B"], "a round keeps its cards, done and cancelled, in plan order")
        XCTAssertEqual(groups[2].cards.map(\.id), ["Y", "X"], "finished cards in no round, with the Done sort")
        XCTAssertFalse(groups[2].inPlan)
        XCTAssertEqual(groups[2].progressText, "2")
        XCTAssertTrue(groups[2].segments.isEmpty)
        XCTAssertEqual(TaskGrouping.doneGroups(cards: cards, plan: p, finishedSort: FinishedSort(key: .finished, newestFirst: false))[2].cards.map(\.id), ["X", "Y"])
        let listed = groups.flatMap(\.cards).map(\.id)
        XCTAssertEqual(listed.count, Set(listed).count, "a card is listed once")
        XCTAssertFalse(listed.contains("D"), "a done card of an unfinished round stays with its round under By round")
    }

    func testDoneWithoutAPlanIsOneNotInARoundGroup() {
        let groups = TaskGrouping.doneGroups(cards: [card("A", .done), card("B", .todo)], plan: nil)
        XCTAssertEqual(groups.map(\.name), ["Not in a round"])
        XCTAssertTrue(TaskGrouping.doneGroups(cards: [card("B", .todo)], plan: nil).isEmpty)
    }

    func testADoneSearchKeepsMatchesAndJudgesARoundOnAllItsCards() {
        let cards = [card("A", .done), card("B", .done), card("C", .done), card("D", .doing), card("E", .done)]
        let p = plan([("R1", ["A", "B"]), ("R2", ["C", "D"])])
        let groups = TaskGrouping.doneGroups(cards: cards, plan: p, matching: ["B", "C"])
        XCTAssertEqual(groups.map(\.name), ["R1"], "R2 is unfinished even when its open card does not match; empty groups go")
        XCTAssertEqual(groups[0].cards.map(\.id), ["B"])
        XCTAssertEqual(groups[0].progressText, "2 of 2 merged", "the header still counts the whole round")
    }

    func testOnlyTheNewestDoneGroupStartsOpenAndASearchOpensAll() {
        let groups = TaskGrouping.doneGroups(cards: [card("A", .done), card("B", .done), card("C", .done)], plan: plan([("R1", ["A"]), ("R2", ["B"])]))
        let ids = groups.map(\.id)
        XCTAssertEqual(TaskGrouping.openDoneGroups(groups, toggled: [], searching: false), [ids[0]])
        XCTAssertEqual(TaskGrouping.openDoneGroups(groups, toggled: [ids[0], ids[2]], searching: false), [ids[2]], "a toggle closes the newest and opens an older one")
        XCTAssertEqual(TaskGrouping.openDoneGroups(groups, toggled: [ids[0]], searching: true), Set(ids), "a match is never hidden")
        XCTAssertEqual(TaskGrouping.visibleDoneCardIDs(groups, open: [ids[0], ids[2]]), ["B", "C"], "arrow keys follow the open groups in order")
    }

    func testSegmentColorsOnePerLiveCard() {
        let cards = [card("A", .done), card("B", .doing), card("C", .review), card("D", .todo), card("E", .cancelled), card("F", .awaitingStartApproval), card("G", .needsFix)]
        let g = TaskGrouping.rounds(cards: cards, plan: plan([("R", ["A", "B", "C", "D", "E", "F", "G"])])).open[0]
        XCTAssertEqual(g.segments, [.done, .doing, .needsYou, .todo, .needsYou, .doing], "a cancelled card has no segment")
        let asking = TaskGrouping.rounds(cards: [card("B", .doing)], plan: plan([("R", ["B"])]), needsYou: { _ in true }).open[0]
        XCTAssertEqual(asking.segments, [.needsYou], "an agent waiting for an answer is orange")
    }

    func testShortRowState() {
        let now = Date(timeIntervalSince1970: 100_000)
        func s(_ c: TaskCard, phase: TaskPhase? = nil, dep: DependencyState = .clear, started: Date? = nil) -> RowState {
            TaskGrouping.rowState(c, phase: phase, dependency: dep, startedAt: started, now: now)
        }
        XCTAssertEqual(s(card("A", .review)), RowState(text: "review", tone: .ask))
        XCTAssertEqual(s(card("A", .doing), phase: .working, started: now.addingTimeInterval(-48 * 60)), RowState(text: "doing 48m", tone: .normal))
        XCTAssertEqual(s(card("A", .doing), phase: .working, started: now.addingTimeInterval(-65 * 60)), RowState(text: "doing 1h", tone: .normal))
        XCTAssertEqual(s(card("A", .doing)), RowState(text: "doing", tone: .normal))
        XCTAssertEqual(s(card("A", .doing), phase: .waitingForYou), RowState(text: "your call", tone: .wait))
        XCTAssertEqual(s(card("A", .awaitingStartApproval)), RowState(text: "your call", tone: .wait))
        XCTAssertEqual(s(card("A", .todo), dep: .waiting(["N133", "N9"])), RowState(text: "waits N133", tone: .wait))
        XCTAssertEqual(s(card("A", .todo)), RowState(text: "todo", tone: .quiet))
        XCTAssertEqual(s(card("A", .needsFix)), RowState(text: "fixing", tone: .normal))
        XCTAssertEqual(s(card("A", .done, decision: "Approved.")), RowState(text: "merged", tone: .quiet), "no date known: the state, never the version")
        XCTAssertEqual(s(card("A", .cancelled)), RowState(text: "cancelled", tone: .quiet))
    }

    // N139: a finished row shows when it finished, not the version.
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testFinishTimeIsTheClockTodayTheDayThisYearAndTheYearOtherwise() {
        let now = at("2026-10-19 18:00")
        XCTAssertEqual(TaskGrouping.finishTimeText(at("2026-10-19 14:32"), now: now, calendar: utc), "14:32")
        XCTAssertEqual(TaskGrouping.finishTimeText(at("2026-10-17 09:05"), now: now, calendar: utc), "Oct 17")
        XCTAssertEqual(TaskGrouping.finishTimeText(at("2025-10-17 09:05"), now: now, calendar: utc), "Oct 17, 2025")
    }

    func testFinishedRowsShowTheirFinishTimeAndOpenRowsTheirState() {
        let now = at("2026-10-19 18:00")
        func s(_ c: TaskCard, sort: FinishedSort = .default, phase: TaskPhase? = nil) -> RowState {
            TaskGrouping.rowState(c, phase: phase, dependency: .clear, startedAt: nil, now: now, finishedSort: sort, calendar: utc)
        }
        let merged = card("A", .done, decision: "Merged 2026-10-19 14:32 by PM (63fef19, stable-80). Cause: x")
        XCTAssertEqual(s(merged), RowState(text: "14:32", tone: .quiet))
        XCTAssertEqual(s(card("A", .cancelled, decision: "Cancelled 2026-10-17 by the user.")), RowState(text: "Oct 17", tone: .quiet))
        XCTAssertEqual(s(card("A", .done, decision: "Merged 2025-10-17 08:00 (stable-3).")), RowState(text: "Oct 17, 2025", tone: .quiet))
        var created = merged; created.created = at("2026-10-01 10:00")
        XCTAssertEqual(s(created, sort: FinishedSort(key: .created, newestFirst: true)), RowState(text: "Oct 1", tone: .quiet), "follows the Done sort key")
        XCTAssertEqual(s(card("A", .review)), RowState(text: "review", tone: .ask), "an open card keeps its state")
        XCTAssertEqual(s(card("A", .doing), phase: .waitingForYou), RowState(text: "your call", tone: .wait))
    }

    func testTheRowTitleDropsTheLeadingId() {
        func titled(_ t: String) -> TaskCard {
            TaskCard(id: "N123", project: "p", status: .done, agent: nil, branch: nil, kind: nil, files: [], title: t, sections: [:], url: URL(fileURLWithPath: "/tmp/N123.md"))
        }
        XCTAssertEqual(TaskGrouping.rowTitle(titled("N123 · Notes pad: a floating pad")), "Notes pad: a floating pad")
        XCTAssertEqual(TaskGrouping.rowTitle(titled("Notes about N123")), "Notes about N123")
    }

    /// By status and Done draw the same one-line rows as By round (N139); AppKit parts stay out (N117).
    @MainActor func testSnapshotOfByStatusAndDone() async throws {
        let model = await DemoSupport.makeModel()
        for mode in [TaskListMode.byStatus, .done] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: TaskListView(model: model, startMode: mode), size: CGSize(width: 420, height: 760)))
            XCTAssertGreaterThan(data.count, 10_000)
            if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("n139-list-\(mode.rawValue).png"))
            }
        }
    }

    /// N181: Done with finished rounds (the newest open, older ones closed), "Not in a round", and a search that opens every match.
    @MainActor func testSnapshotOfDoneRounds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n181-demo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: DemoSupport.demoDir, to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let finished: [(String, String, String, String)] = [
            ("D1", "done", "Onboarding prompt from the probe", "Merged 2026-10-18 10:00 by PM."), ("D2", "done", "Setup installs missing tools", "Merged 2026-10-18 12:30 by PM."),
            ("D3", "cancelled", "Old setup sheet layout", "Cancelled 2026-10-18 by the user."), ("D4", "done", "Choose terminal", "Merged 2026-10-19 09:10 by PM."),
            ("D5", "done", "Approve plan and start round", "Merged 2026-10-20 14:32 by PM."), ("D6", "done", "Setup list scrolls on a small screen", "Merged 2026-10-20 15:05 by PM."),
            ("D7", "done", "Notes pad: a floating pad", "Merged 2026-10-12 by PM."), ("D8", "cancelled", "Share sheet experiment", "Cancelled 2026-10-11 by the user."),
        ]
        for (id, status, title, decision) in finished {
            try "---\nid: \(id)\nproject: demo\nstatus: \(status)\n---\n# \(id) · \(title)\n\n## Decision\n\(decision)\n"
                .write(to: dir.appendingPathComponent("data/tasks/\(id).md"), atomically: true, encoding: .utf8)
        }
        let plan = PlanFile(rounds: [PlanRound(name: "Project setup", cards: ["D1", "D2", "D3"], reason: "", status: "done"),
                                     PlanRound(name: "Codex + terminal", cards: ["D4"], reason: "", status: "done"),
                                     PlanRound(name: "Plan approval", cards: ["D5", "D6"], reason: "", status: "done")], questions: [])
        let previous = ProcessInfo.processInfo.environment["AGENT_PANEL_DEMO_DIR"]
        setenv("AGENT_PANEL_DEMO_DIR", dir.path, 1)
        defer { if let previous { setenv("AGENT_PANEL_DEMO_DIR", previous, 1) } else { unsetenv("AGENT_PANEL_DEMO_DIR") } }
        let model = await DemoSupport.makeModel()
        model.selectedCardID = "D5"
        // "d" matches every id: all groups open, "Not in a round" included.
        for (name, query) in [("done", nil), ("done-search", "setup"), ("done-all-open", "d")] as [(String, String?)] {
            let view = TaskListView(model: model, plan: .constant(plan), startMode: .done, startQuery: query)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 420, height: 640)))
            XCTAssertGreaterThan(data.count, 10_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("n181-\(name).png"))
            }
        }
    }

    func testTheListModeIsKeptPerProject() {
        let d = makeTestDefaults(prefix: "mode")
        XCTAssertEqual(TaskListMode.load(d, project: "p"), .byRound, "by round is the default")
        TaskListMode.done.save(d, project: "p")
        XCTAssertEqual(TaskListMode.load(d, project: "p"), .done)
        XCTAssertEqual(TaskListMode.load(d, project: "q"), .byRound)
    }
}
