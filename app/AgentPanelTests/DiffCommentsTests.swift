import XCTest
import SwiftUI
@testable import AgentPanel

/// N249: comments on diff lines, kept per card and head commit, sent as one fix request.
@MainActor
final class DiffCommentsTests: XCTestCase {
    private let key = DiffCommentStore.key(project: "p", card: "N1")

    private func line(_ old: Int?, _ new: Int?, _ text: String) -> DiffComment.LineRef { DiffComment.LineRef(old: old, new: new, text: text) }

    func testFixNotesForOneComment() {
        let c = DiffComment(path: "app/A.swift", lines: [line(4, 5, "\tlet x = 1")], text: "Rename x.")
        XCTAssertEqual(DiffCommentStore.fixNotes([c]), """
        Comments on the diff (1 comment):

        - `app/A.swift:5`
          >     let x = 1
          Rename x.
        """)
    }

    func testFixNotesForARangeUseTheNewSide() {
        let c = DiffComment(path: "a.txt", lines: [line(5, nil, "5"), line(nil, 5, "five"), line(6, 6, "6")], text: "Why?")
        XCTAssertEqual(c.location, "a.txt:5-6")
        XCTAssertEqual(DiffCommentStore.fixNotes([c]), "Comments on the diff (1 comment):\n\n- `a.txt:5-6`\n  > 5\n  > five\n  > 6\n  Why?")
    }

    func testARemovedLineUsesTheOldSide() {
        let c = DiffComment(path: "a.txt", lines: [line(30, nil, "30")], text: "Keep this line.")
        XCTAssertEqual(c.location, "a.txt:30 (removed)")
        let two = DiffComment(path: "b.txt", lines: [line(7, nil, "x"), line(8, nil, "y")], text: "Both\nplease")
        XCTAssertEqual(DiffCommentStore.fixNotes([c, two]), """
        Comments on the diff (2 comments):

        - `a.txt:30 (removed)`
          > 30
          Keep this line.
        - `b.txt:7-8 (removed)`
          > x
          > y
          Both
          please
        """)
    }

    func testDraftsAreKeptPerCardAndAcrossARestart() {
        let defaults = makeTestDefaults()
        let store = DiffCommentStore(defaults: defaults)
        let other = DiffCommentStore.key(project: "p", card: "N2")
        store.add(key, head: "abc", path: "a.txt", lines: [line(1, 1, "x")], text: "one")
        store.add(other, head: "def", path: "b.txt", lines: [line(nil, 2, "y")], text: "two")
        XCTAssertNil(store.add(key, head: "abc", path: "a.txt", lines: [line(1, 1, "x")], text: "  "), "an empty comment is not kept")

        let restarted = DiffCommentStore(defaults: defaults)
        XCTAssertEqual(restarted.comments(key).map(\.text), ["one"])
        XCTAssertEqual(restarted.comments(other).map(\.text), ["two"])
        restarted.sync(key, head: "abc")
        XCTAssertEqual(restarted.comments(key).count, 1, "the same head keeps the comments")
    }

    func testANewHeadDropsTheDraftsWithANote() {
        let defaults = makeTestDefaults()
        let store = DiffCommentStore(defaults: defaults)
        store.add(key, head: "abc", path: "a.txt", lines: [line(1, 1, "x")], text: "one")
        store.add(key, head: "abc", path: "a.txt", lines: [line(2, 2, "y")], text: "two")
        store.sync(key, head: "new")
        XCTAssertEqual(store.comments(key), [])
        XCTAssertEqual(store.dropped[key], 2)
        XCTAssertEqual(DiffCommentStore(defaults: defaults).comments(key), [], "the drop is saved")
        store.dismissDropped(key)
        XCTAssertNil(store.dropped[key])
    }

    func testEditAndRemove() {
        let store = DiffCommentStore(defaults: makeTestDefaults())
        let a = store.add(key, head: "h", path: "a.txt", lines: [line(1, 1, "x")], text: "one")!
        let b = store.add(key, head: "h", path: "a.txt", lines: [line(2, 2, "y")], text: "two")!
        store.edit(key, id: a.id, text: " better ")
        XCTAssertEqual(store.comments(key).map(\.text), ["better", "two"])
        store.edit(key, id: b.id, text: "")
        XCTAssertEqual(store.comments(key).map(\.text), ["better"], "an emptied comment is removed")
        store.remove(key, id: a.id)
        XCTAssertNil(store.drafts[key])
    }

    func testSendCallsTheFixPathOnceAndClears() async {
        let defaults = makeTestDefaults()
        let store = DiffCommentStore(defaults: defaults)
        store.add(key, head: "h", path: "a.txt", lines: [line(1, 1, "x")], text: "one")
        store.add(key, head: "h", path: "a.txt", lines: [line(nil, 3, "z")], text: "two")
        var calls: [String] = []
        let sent = await store.send(key) { calls.append($0); return true }
        XCTAssertTrue(sent)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first, DiffCommentStore.fixNotes([
            DiffComment(path: "a.txt", lines: [line(1, 1, "x")], text: "one"), DiffComment(path: "a.txt", lines: [line(nil, 3, "z")], text: "two")]))
        XCTAssertEqual(store.comments(key), [])
        XCTAssertEqual(DiffCommentStore(defaults: defaults).comments(key), [])
        let again = await store.send(key) { calls.append($0); return true }
        XCTAssertFalse(again, "nothing to send")
        XCTAssertEqual(calls.count, 1)
    }

    func testAFailedSendKeepsTheComments() async {
        let store = DiffCommentStore(defaults: makeTestDefaults())
        store.add(key, head: "h", path: "a.txt", lines: [line(1, 1, "x")], text: "one")
        let sent = await store.send(key) { _ in false }
        XCTAssertFalse(sent)
        XCTAssertEqual(store.comments(key).map(\.text), ["one"])
    }

    func testNothingIsSavedOrSentWithoutComments() async {
        let defaults = makeTestDefaults()
        let store = DiffCommentStore(defaults: defaults)
        var called = false
        _ = await store.send(key) { _ in called = true; return true }
        XCTAssertFalse(called)
        XCTAssertNil(defaults.data(forKey: DiffCommentStore.defaultsKey))
    }

    func testHeadReadsTheBranchCommit() async {
        let tools = FakeTools()
        tools.handler = { $0.contains("rev-parse") ? FakeTools.ok("0123abc\n") : FakeTools.fail() }
        let reader = TaskDiffReader(runner: tools, repoPath: "/r", base: "main", branch: "task/n1")
        let head = await reader.head()
        XCTAssertEqual(head, "0123abc")
        XCTAssertTrue(tools.joined[0].hasSuffix("rev-parse --verify --quiet task/n1^{commit}"))
    }

    func testCommentRowsAnchorUnderTheirLastLine() {
        let rows: [FileDiff.Row] = [.hunk("@@"), .line(.init(kind: .context, old: 4, new: 4, text: "4")),
                                    .line(.init(kind: .removed, old: 5, new: nil, text: "5")), .line(.init(kind: .added, old: nil, new: 5, text: "five"))]
        let c = DiffComment(path: "a.txt", lines: [line(5, nil, "5"), line(nil, 5, "five")], text: "x")
        let far = DiffComment(path: "a.txt", lines: [line(90, 90, "z")], text: "hidden")
        let placed = DiffCommentLayout.anchors(rows: rows, comments: [c, far])
        XCTAssertEqual(placed.under[3]?.map(\.text), ["x"])
        XCTAssertEqual(placed.unplaced.map(\.text), ["hidden"])
        XCTAssertEqual(DiffCommentLayout.lines(rows: rows, from: 1, to: 3).map(\.text), ["4", "5", "five"])
        XCTAssertEqual(DiffCommentLayout.lines(rows: rows, from: 3, to: 0).map(\.text), ["4", "5", "five"], "a range picked upwards")
    }
}

/// Snapshots → tasks/assets/N249-*.png (AGENT_PANEL_SNAPSHOT_DIR).
@MainActor
final class DiffCommentsSnapshotTests: XCTestCase {
    private func write(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    private var preload: DiffPreload {
        let entries = DiffFileEntry.parseNameStatus(DiffViewTests.nameStatus)
        let parsed = FileDiff.parse(DiffViewTests.diff)
        var diffs: [String: TaskFileDiff] = [:]
        for (e, d) in zip(entries, parsed) { diffs[e.id] = TaskFileDiff(diff: d, raw: "x", newText: e.path == "a.txt" ? DiffViewTests.aAtBranch : nil) }
        return DiffPreload(files: entries, diffs: diffs, selected: "a.txt", head: "h1")
    }

    private func detail(_ store: DiffCommentStore) -> TaskDetailView {
        let card = TaskCard(id: "N249", project: "p", status: .review, agent: nil, branch: "task/n249", kind: nil, files: ["a.txt"], title: "Diff comments",
                            sections: [:], url: URL(fileURLWithPath: "/x/N249.md"), modified: nil)
        return TaskDetailView(card: card, shots: [], opener: nil, startState: StartButtonState(enabled: false, help: ""),
                              reviewState: reviewButtonStates(card: card, canAct: false, reason: "x", worktreeExists: false, busy: false, agentWorking: false),
                              onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}, startTab: .changes, diffPreload: preload,
                              diffComments: store, onSendDiffComments: { _ in true })
    }

    func testTwoCommentsAndTheSendBar() throws {
        let store = DiffCommentStore(defaults: makeTestDefaults())
        let key = DiffCommentStore.key(project: "p", card: "N249")
        store.add(key, head: "h1", path: "a.txt", lines: [.init(old: 5, new: nil, text: "5"), .init(old: nil, new: 5, text: "five")],
                  text: "Keep digits here; the parser expects numbers.")
        store.add(key, head: "h1", path: "a.txt", lines: [.init(old: nil, new: 30, text: "thirty")], text: "Same here.")
        store.add(key, head: "h1", path: "added.txt", lines: [.init(old: nil, new: 1, text: "hello")], text: "Capital H.")
        let data = try XCTUnwrap(SnapshotRenderer.render(view: detail(store), size: CGSize(width: 760, height: 1040)))
        XCTAssertGreaterThan(data.count, 20_000)
        try write(data, "N249-comments.png")
    }

    func testCommentBoxOpenOnARange() throws {
        let store = DiffCommentStore(defaults: makeTestDefaults())
        let p = preload
        let ctx = DiffCommentContext(store: store, key: DiffCommentStore.key(project: "p", card: "N249"), head: "h1")
        store.add(ctx.key, head: "h1", path: "a.txt", lines: [.init(old: 4, new: 4, text: "4")], text: "Is 4 still used?")
        // Rows 0-1 are the gap and the hunk header; 5...6 are "−5" and "+five".
        let view = DiffView(entry: p.files[0], file: p.diffs["a.txt"]!, comments: ctx, composing: 5...6)
            .padding(24).frame(width: 700, alignment: .topLeading).background(Tok.bg)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: Color.clear.overlay(alignment: .top) { view }.clipped(), size: CGSize(width: 700, height: 400)))
        try write(data, "N249-composer.png")
    }

    func testDroppedForANewerCommit() throws {
        let store = DiffCommentStore(defaults: makeTestDefaults())
        let key = DiffCommentStore.key(project: "p", card: "N249")
        store.add(key, head: "old", path: "a.txt", lines: [.init(old: 4, new: 4, text: "4")], text: "x")
        store.add(key, head: "old", path: "a.txt", lines: [.init(old: 6, new: 6, text: "6")], text: "y")
        let view = Color.clear.overlay(alignment: .top) { detail(store) }.clipped()
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 760, height: 420)))
        XCTAssertEqual(store.dropped[key], 2)
        try write(data, "N249-older-commit.png")
    }
}
