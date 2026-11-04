import XCTest
import SwiftUI
import AppKit
@testable import AgentPanel

/// N385: the Review packets, Fix loops and PM decisions tiles: what they read, and live-window shots with demo data.
@MainActor
final class DashboardFeedsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("feeds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("tasks"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func card(_ id: String, _ status: TaskStatus, title: String = "A card", files: [String] = [], sections: [String: String] = [:]) -> TaskCard {
        TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: files, title: title, sections: sections,
                 url: folder.appendingPathComponent("tasks/\(id).md"))
    }

    private func write(_ text: String, _ path: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func t(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private func ev(_ time: String, _ text: String, project: String? = "p") -> ActionLogEvent { ActionLogEvent(time: t(time), text: text, project: project) }
    private func rec(_ id: String, _ time: String, card: String, kind: String = "choice", question: String = "Title: Which colour?",
                     by: DecisionRecord.By = .pm, result: DecisionRecord.Result = .answered, answer: String = "Blue", why: String = "") -> DecisionRecord {
        DecisionRecord(id: id, time: t(time), cardID: card, agent: "dev", kind: kind, question: question, by: by, result: result, answer: answer, why: why)
    }

    // MARK: Review packets

    func testPacketSummaryFromTheDataFolder() throws {
        try write("ok  a.test.sh  -- 3 passed, 0 failed\nALL PASSED\n", "tasks/A1/build.log")
        try write("x", "tasks/A1/shots/one.png"); try write("x", "tasks/A1/shots/two.jpg"); try write("x", "tasks/A1/shots/notes.txt")
        try write("Test Case '-[T testX]' failed\n** TEST FAILED **\n", "tasks/A2/build.log")
        let a1 = card("A1", .review, title: "Move items", files: ["app/AgentPanel/State/", "tests/run.sh"],
                      sections: ["Report": "- Tests: `scripts/app-test.sh` 2950 run / 0 failed (1 skipped)"])
        let a2 = card("A2", .review, sections: ["Report": "Result: done"])
        let diff = DashboardFeeds.parseNumstat("10\t2\tapp/AgentPanel/State/X.swift\n3\t0\ttests/run.sh\n1\t1\tapp/AgentPanel.xcodeproj/project.pbxproj\n-\t-\tdocs/shot.png\n")
        let packets = DashboardFeeds.reviewPackets(cards: [a1, a2, card("A3", .doing)], dataDir: folder, diffs: ["A1": diff])
        XCTAssertEqual(packets.map(\.id), ["A1", "A2"], "only cards in review")
        XCTAssertEqual(packets[0].build, .passed)
        XCTAssertEqual(packets[0].tests, "2950 / 0")
        XCTAssertEqual(packets[0].shots, 2, "png and jpg only")
        XCTAssertEqual(packets[0].diff?.text, "+14 −3 · 4 files")
        XCTAssertEqual(packets[0].outside, ["app/AgentPanel.xcodeproj/project.pbxproj", "docs/shot.png"], "files outside the card's list")
        XCTAssertEqual(packets[1].build, .failed)
        XCTAssertNil(packets[1].tests, "no Tests line: shown as —")
        XCTAssertEqual(packets[1].testsText, "tests —")
        XCTAssertEqual(packets[1].shots, 0)
        XCTAssertEqual(packets[1].outside, [], "no file list read: no warning")
    }

    func testBuildResult() {
        XCTAssertEqual(DashboardFeeds.build(log: "ok a -- 2 passed, 0 failed\nALL PASSED"), .passed)
        XCTAssertEqual(DashboardFeeds.build(log: "FAIL x.test.sh\nFAILURES"), .failed)
        XCTAssertEqual(DashboardFeeds.build(log: "** BUILD SUCCEEDED **\nExecuted 10 tests, with 2 failures (0 unexpected)"), .failed)
        XCTAssertEqual(DashboardFeeds.build(log: "Executed 10 tests, with 0 failures\n** TEST SUCCEEDED **"), .passed)
        XCTAssertEqual(DashboardFeeds.build(log: nil, packet: "Head: abc\n\nBuild: passed (`x`), log: y"), .passed, "no log: the packet's Build line")
        XCTAssertEqual(DashboardFeeds.build(log: nil, packet: "Build: FAILED"), .failed)
        XCTAssertEqual(DashboardFeeds.build(log: nil), .unknown)
    }

    func testTestsLineShapes() {
        XCTAssertEqual(DashboardFeeds.testsRun(report: "### Tests\n`scripts/app-test.sh` 2904 run / 0 failed; `bash tests/run.sh` ALL PASSED"), "2904 / 0")
        XCTAssertEqual(DashboardFeeds.testsRun(report: "- **Tests**: tests 1774/3"), "1774 / 3")
        XCTAssertEqual(DashboardFeeds.testsRun(report: "Tests: Executed 12 tests, with 1 failure"), "12 / 1")
        XCTAssertNil(DashboardFeeds.testsRun(report: "Tests: all green"))
        XCTAssertNil(DashboardFeeds.testsRun(report: ""))
        XCTAssertEqual(ReviewPacketsTile.testsTint("10 / 0"), Tok.go)
        XCTAssertEqual(ReviewPacketsTile.testsTint("10 / 2"), Tok.stop)
        XCTAssertNil(ReviewPacketsTile.testsTint(nil))
    }

    func testDiffAndOutsideList() {
        XCTAssertEqual(DashboardFeeds.packetDiff("```\n 6 files changed, 112 insertions(+), 1 deletion(-)\n```"), BranchDiff(added: 112, deleted: 1, files: 6))
        XCTAssertEqual(DashboardFeeds.packetDiff("1 file changed, 3 deletions(-)"), BranchDiff(added: 0, deleted: 3, files: 1))
        XCTAssertNil(DashboardFeeds.packetDiff("Screenshots: none"))
        XCTAssertEqual(DashboardFeeds.renamedTo("app/{Old.swift => New.swift}"), "app/New.swift")
        XCTAssertEqual(DashboardFeeds.renamedTo("a.txt => b.txt"), "b.txt")
        XCTAssertEqual(DashboardFeeds.outside(["app/AgentPanel/Views/X.swift", "AgentPanel/State/Y.swift", "README.md"],
                                              cardFiles: ["app/AgentPanel/Views/", "AgentPanel/State/Y.swift"]), ["README.md"])
        XCTAssertEqual(DashboardFeeds.outside(["anything"], cardFiles: []), [], "a card without a list has nothing outside it")
        XCTAssertEqual(ReviewPacketsTile.outsideNames(["app/AgentPanel.xcodeproj/project.pbxproj", "x"]), "project.pbxproj, …")
    }

    func testNoPacketsIsEmpty() {
        XCTAssertEqual(DashboardFeeds.reviewPackets(cards: [card("A1", .doing)], dataDir: folder), [])
    }

    // MARK: Fix loops

    static let log = """
    2026-11-04T08:00:00Z [p] start N1 agent=dev-n1 branch=task/n1 pane=dev-n1
    2026-11-04T09:00:00Z [p] review packet prepared for N1
    2026-11-04T09:10:00Z [p] fix request sent to dev-n1 for N1
    2026-11-04T10:00:00Z [p] review packet prepared for N1
    2026-11-04T10:05:00Z [p] fix request (passed on) sent to dev-n1 for N1
    2026-11-04T11:00:00Z [p] review packet prepared for N1
    2026-11-04T11:05:00Z [p] fix request sent to dev-n1 for N1
    2026-11-04T11:30:00Z [p] fix request sent to dev-n2 for N2
    2026-11-04T11:40:00Z [p] review packet prepared for N2
    2026-11-04T11:50:00Z [p] fix request sent to dev-n3 for N3
    2026-11-04T11:55:00Z [other] fix request sent to dev-n3 for N3
    2026-11-04T12:00:00Z [p] fix request sent to dev-n4 for N4
    """

    func testFixRoundFromTheActionLog() {
        let events = ActionLogEvents.parse(Self.log)
        XCTAssertEqual(DashboardFeeds.fixRound("N1", events: events, project: "p"), 3)
        XCTAssertEqual(DashboardFeeds.fixRound("N3", events: events, project: "p"), 1, "another project's line is not counted")
        let rebase = rec("r", "2026-11-04T12:00:30Z", card: "N4", kind: AutopilotModel.rebaseKind, answer: "Rebased")
        XCTAssertEqual(DashboardFeeds.fixRound("N4", events: events, decisions: [rebase], project: "p"), 0, "a rebase turn is not a fix round")
    }

    func testFixLoopsListAndRedState() {
        let events = ActionLogEvents.parse(Self.log)
        let notes = """
        ### 2026-11-04 09:10

        - F1 hero shot is cropped at the top.
        - **F2** (stats): numbers overlap
        F3: sheet too tall

        ### Fix round 1
        - F1 fixed
        - F9 not a note
        """
        let cards = [card("N1", .needsFix, title: "README shots", sections: ["Fix notes": notes]), card("N2", .doing), card("N3", .doing, title: "Usage ring"),
                     card("N5", .needsFix), card("N6", .review)]
        let loops = DashboardFeeds.fixLoops(cards: cards, events: events, decisions: [], project: "p")
        XCTAssertEqual(loops.map(\.id), ["N1", "N3", "N5"], "N2 has a packet after its fix (back in review); N6 is in review")
        XCTAssertEqual(loops[0].round, 3)
        XCTAssertTrue(loops[0].isRed)
        XCTAssertEqual(FixLoopsTile.tint(loops[0]), Tok.stop)
        XCTAssertEqual(loops[0].notes.map(\.label), ["F1", "F2", "F3"], "F-numbers under Fix round N are answers, left out")
        XCTAssertEqual(loops[0].notesText, "F1 hero shot is, F2 stats numbers overlap, F3 sheet too tall")
        XCTAssertEqual(loops[1].round, 1)
        XCTAssertFalse(loops[1].isRed)
        XCTAssertEqual(FixLoopsTile.tint(loops[1]), Tok.wait)
        XCTAssertEqual(loops[2].round, 1, "needs-fix without a log line is round 1")
        XCTAssertEqual(loops[2].notes, [])
        XCTAssertEqual(FixLoopsTile.meta(2), "2 cards back from review")
        XCTAssertNil(FixLoopsTile.meta(0))
        XCTAssertEqual(DashboardFeeds.fixLoops(cards: [card("N9", .doing)], events: events, decisions: [], project: "p"), [], "empty")
    }

    // MARK: PM decisions

    func testPMDecisionsTodayGroupedAnsweredAndToYou() {
        let now = t("2026-11-04T16:00:00Z")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let records = [
            rec("1", "2026-11-04T14:58:00Z", card: "A5", question: "Test: Which colour?", answer: "Circle"),
            rec("2", "2026-11-04T14:31:00Z", card: "N384", kind: "freeText", question: "Demo name?", answer: "Demo App"),
            rec("3", "2026-11-04T15:10:00Z", card: "B3", question: "Fix release notes before tagging?", result: .escalated, answer: "", why: "The agent marked it critical."),
            rec("4", "2026-11-04T15:20:00Z", card: "B4", kind: "permission", question: "Run it?", result: .escalated, answer: "", why: "PM is not sure."),
            rec("5", "2026-11-03T15:00:00Z", card: "A1", question: "Yesterday?"),
            rec("6", "2026-11-04T15:00:00Z", card: "A2", question: "Mine", by: .you),
            rec("7", "2026-11-04T15:00:00Z", card: "A3", kind: "start", question: "PM authority: go"),
            rec("8", "2026-11-04T15:00:00Z", card: "A4", kind: "rebase", question: "Branch is behind main"),
            rec("9", "2026-11-04T15:30:00Z", card: "A6", result: .suggested),
        ]
        let events = ActionLogEvents.parse("""
        2026-11-04T14:57:40Z [p] relayed to the PM: QUESTION A5-q1 CENK · A5: Which colour? · options: 1) Circle 2) Square
        2026-11-04T14:58:01Z [p] answered-by-pm A5-q1 (A5): Circle
        2026-11-04T15:05:00Z [p] relayed to the PM: QUESTION B4-q2 CENK · B4: Run it? · options: 1) Yes 2) No
        """)
        let day = DashboardFeeds.pmDecisions(records, events: events, project: "p", now: now, calendar: utc)
        XCTAssertEqual(day.answered.map(\.id), ["1", "2"], "the PM's answers of today, newest first")
        XCTAssertEqual(day.toYou.map(\.id), ["4", "3"])
        XCTAssertEqual(day.header, "today: 2 answered · 2 sent to you")
        XCTAssertEqual(day.answered[0].ref, "A5-q1", "the relay's question id")
        XCTAssertEqual(day.answered[0].question, "Which colour?")
        XCTAssertEqual(day.answered[0].answer, "Circle")
        XCTAssertEqual(day.answered[1].ref, "N384", "no relay line: the card id")
        XCTAssertEqual(day.toYou[0].ref, "B4-q2")
        XCTAssertFalse(day.toYou[0].critical)
        XCTAssertTrue(day.toYou[1].critical)
        XCTAssertEqual(day.rows.map(\.id), ["4", "3", "1", "2"], "sent to you first")
        XCTAssertTrue(DashboardFeeds.pmDecisions([], now: now).isEmpty)
        XCTAssertEqual(DashboardFeeds.pmDecisions([], now: now).header, "today: 0 answered · 0 sent to you")
    }

    // MARK: layout

    func testTheNewWidgetsAreSmallAndInTheGallery() {
        for w in [DashboardWidget.reviewPackets, .fixLoops, .pmDecisions] {
            XCTAssertEqual(w.defaultSize, .small)
            XCTAssertEqual(w.minColumns, 1); XCTAssertEqual(w.minRows, 1)
            XCTAssertTrue(WidgetGallery.widgets.contains(w))
        }
        XCTAssertEqual(DashboardWidget.reviewPackets.title, "Review packets")
    }

    func testASavedLayoutWithoutTheNewWidgetsLoadsAsBefore() throws {
        let old = #"[{"id":"chat","x":0,"y":0,"w":4,"h":4},{"id":"waiting","x":4,"y":0,"w":2,"h":1},{"id":"git","x":4,"y":1,"w":2,"h":1}]"#
        let layout = try XCTUnwrap(DashboardGridLayout.decode(Data(old.utf8)))
        XCTAssertEqual(layout.tiles.map(\.widget), [.chat, .waiting, .git])
        let added = layout.applying(.add(.fixLoops))
        XCTAssertEqual(added.tile(.fixLoops)?.rect.width, 2)
        XCTAssertEqual(added.tile(.fixLoops)?.rect.height, 1)
        XCTAssertEqual(DashboardGridLayout.decode(added.encoded()), added, "the new case is saved and read back")
    }

    // MARK: live-window shots (demo data)

    static let demoPackets = [
        ReviewPacketSummary(id: "A4", title: "Move open items into the backlog", build: .passed, tests: "2950 / 0", shots: 4,
                            diff: BranchDiff(added: 112, deleted: 8, files: 6), outside: ["app/Demo.xcodeproj/project.pbxproj", "docs/notes.md"]),
        ReviewPacketSummary(id: "B2", title: "Calendar week starts on Monday", build: .failed, tests: "814 / 2", shots: 2,
                            diff: BranchDiff(added: 40, deleted: 12, files: 3)),
        ReviewPacketSummary(id: "C7", title: "Empty state for the inbox", build: .unknown, tests: nil, shots: 0, diff: nil),
    ]
    static let demoLoops = [
        FixLoopSummary(id: "N372", title: "Usage ring overlaps the search hint", notes: [FixNoteLabel(label: "F1", text: "ring position")], round: 3),
        FixLoopSummary(id: "N383", title: "README shots", notes: [FixNoteLabel(label: "F1", text: "hero"), FixNoteLabel(label: "F2", text: "stats"),
                                                                  FixNoteLabel(label: "F3", text: "sheet")], round: 1),
        FixLoopSummary(id: "B9", title: "Search field keeps focus", notes: [], round: 2),
    ]
    static var demoDecisions: PMDecisionsDay {
        let f = ISO8601DateFormatter()
        func row(_ id: String, _ time: String, _ card: String, _ qid: String?, _ q: String, _ a: String, toYou: Bool = false, critical: Bool = false) -> PMDecisionRow {
            PMDecisionRow(id: id, time: f.date(from: time)!, cardID: card, qid: qid, question: q, answer: a, toYou: toYou, critical: critical)
        }
        return PMDecisionsDay(answered: [row("1", "2026-11-04T11:58:00Z", "A5", "A5-q1", "Which colour?", "Circle"),
                                         row("2", "2026-11-04T11:31:00Z", "N384", "N384-q1", "Demo name?", "Demo App"),
                                         row("3", "2026-11-04T10:02:00Z", "C7", "C7-q1", "Keep the old empty text?", "No")],
                              toYou: [row("4", "2026-11-04T12:10:00Z", "B3", "B3-q1", "Fix release notes before tagging?", "", toYou: true, critical: true)])
    }

    func testTheLiveTileShots() async throws {
        let s = CGSize(width: 440, height: 180), tall = CGSize(width: 440, height: 380)
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            try await shot(ReviewPacketsTile(packets: [Self.demoPackets[0]], onOpen: { _ in }), s, "N385-review-packets-S-\(mode).png", dark: dark)
            try await shot(ReviewPacketsTile(packets: Self.demoPackets, onOpen: { _ in }), tall, "N385-review-packets-T-\(mode).png", dark: dark)
            try await shot(ReviewPacketsTile(packets: [], onOpen: { _ in }), s, "N385-review-packets-empty-\(mode).png", dark: dark)
            try await shot(FixLoopsTile(loops: Array(Self.demoLoops.prefix(2)), onOpen: { _ in }), s, "N385-fix-loops-S-\(mode).png", dark: dark)
            try await shot(FixLoopsTile(loops: Self.demoLoops, onOpen: { _ in }), tall, "N385-fix-loops-T-\(mode).png", dark: dark)
            try await shot(FixLoopsTile(loops: [], onOpen: { _ in }), s, "N385-fix-loops-empty-\(mode).png", dark: dark)
            let day = Self.demoDecisions
            try await shot(PMDecisionsTile(day: PMDecisionsDay(answered: Array(day.answered.prefix(2)), toYou: day.toYou), onOpen: { _ in }), s,
                           "N385-pm-decisions-S-\(mode).png", dark: dark)
            try await shot(PMDecisionsTile(day: day, onOpen: { _ in }), tall, "N385-pm-decisions-T-\(mode).png", dark: dark)
            try await shot(PMDecisionsTile(day: PMDecisionsDay(), onOpen: { _ in }), s, "N385-pm-decisions-empty-\(mode).png", dark: dark)
            let gallery = DashboardGridLayout([DashboardGridTests.t(.chat, 0, 0, 4, 4), DashboardGridTests.t(.waiting, 4, 0, 2, 1)])
            try await shot(WidgetGallery(layout: gallery, onAdd: { _ in }, onClose: {}), CGSize(width: WidgetGallery.width, height: 1000),
                           "N385-gallery-\(mode).png", dark: dark, pad: 30)
            try await shot(WidgetGallery(layout: gallery, onAdd: { _ in }, onClose: {}).frame(maxHeight: 600, alignment: .top),
                           CGSize(width: WidgetGallery.width, height: 600), "N385-gallery-short-\(mode).png", dark: dark, pad: 30)
        }
    }

    /// An on-screen NSWindow hosting the view (not ImageRenderer).
    private func shot<V: View>(_ view: V, _ size: CGSize, _ file: String, dark: Bool, pad: CGFloat = 16) async throws {
        let theme = AppTheme.current
        AppTheme.current = dark ? .dark : .light
        defer { AppTheme.current = theme }
        let root = view.frame(width: size.width, height: size.height).padding(pad).background(Tok.bg).environment(\.colorScheme, dark ? .dark : .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 5_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(file)) }
    }
}
