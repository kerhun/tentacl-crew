import XCTest
import SwiftUI
@testable import AgentPanel

/// N204: the Changes tab's diff. The texts below are real `git diff` output (git 2.x, `-M`, `core.quotePath=false`).
final class DiffViewTests: XCTestCase {
    static let nameStatus = "M\0a.txt\0A\0added.txt\0D\0gone.txt\0M\0img.bin\0R087\0old name.txt\0new name.txt\0M\0tail.txt\0"

    static let diff = """
    diff --git a/a.txt b/a.txt
    index 1c99002..a05badf 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -2,7 +2,7 @@
     2
     3
     4
    -5
    +five
     6
     7
     8
    @@ -27,7 +27,7 @@
     27
     28
     29
    -30
    +thirty
     31
     32
     33
    @@ -38,3 +38,4 @@
     38
     39
     40
    +41
    diff --git a/added.txt b/added.txt
    new file mode 100644
    index 0000000..ce01362
    --- /dev/null
    +++ b/added.txt
    @@ -0,0 +1 @@
    +hello
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 286c5f5..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    diff --git a/img.bin b/img.bin
    index 8352675..95d586e 100644
    Binary files a/img.bin and b/img.bin differ
    diff --git a/old name.txt b/new name.txt
    similarity index 87%
    rename from old name.txt
    rename to new name.txt
    index b00a0f1..6830218 100644
    --- a/old name.txt\t
    +++ b/new name.txt\t
    @@ -1,7 +1,7 @@
     one
     two
     three
    -four
    +FOUR
     five
     six
     seven
    diff --git a/tail.txt b/tail.txt
    index e32b0df..09d1eeb 100644
    --- a/tail.txt
    +++ b/tail.txt
    @@ -1 +1,2 @@
    -end
    \\ No newline at end of file
    +end
    +more
    \\ No newline at end of file

    """

    static let aAtBranch = (1...41).map { n in n == 5 ? "five" : n == 30 ? "thirty" : "\(n)" }.joined(separator: "\n") + "\n"

    private func files() -> [FileDiff] { FileDiff.parse(Self.diff) }

    func testNameStatusWithRename() {
        let list = DiffFileEntry.parseNameStatus(Self.nameStatus)
        XCTAssertEqual(list.map(\.path), ["a.txt", "added.txt", "gone.txt", "img.bin", "new name.txt", "tail.txt"])
        XCTAssertEqual(list.map(\.letter), ["M", "A", "D", "M", "R", "M"])
        XCTAssertEqual(list[4].status, .renamed(87))
        XCTAssertEqual(list[4].oldPath, "old name.txt")
        XCTAssertEqual(DiffFileEntry.parseNameStatus(""), [])
    }

    func testParsesEveryFileOfARealDiff() {
        let f = files()
        XCTAssertEqual(f.map(\.path), ["a.txt", "added.txt", "gone.txt", "img.bin", "new name.txt", "tail.txt"])
        XCTAssertEqual(f.map(\.kind), [.modified, .added, .deleted, .modified, .renamed(similarity: 87), .modified])
        XCTAssertEqual(f.map(\.binary), [false, false, false, true, false, false])
        XCTAssertEqual(f[0].hunks.count, 3)
        XCTAssertEqual(f[0].addedCount, 3); XCTAssertEqual(f[0].removedCount, 2)
        XCTAssertTrue(f[3].hunks.isEmpty)
    }

    func testLineNumbersFollowTheHunkHeader() throws {
        let h = try XCTUnwrap(files().first?.hunks[0])
        XCTAssertEqual(h.header, "@@ -2,7 +2,7 @@")
        XCTAssertEqual(h.lines.map(\.old), [2, 3, 4, 5, nil, 6, 7, 8])
        XCTAssertEqual(h.lines.map(\.new), [2, 3, 4, nil, 5, 6, 7, 8])
        XCTAssertEqual(h.lines[3], FileDiff.Line(kind: .removed, old: 5, new: nil, text: "5"))
        XCTAssertEqual(h.lines[4], FileDiff.Line(kind: .added, old: nil, new: 5, text: "five"))
    }

    func testNewAndDeletedFilesStartAtLineOne() {
        let f = files()
        XCTAssertEqual(f[1].hunks[0].lines, [FileDiff.Line(kind: .added, old: nil, new: 1, text: "hello")])
        XCTAssertNil(f[1].oldPath)
        XCTAssertEqual(f[2].hunks[0].lines, [FileDiff.Line(kind: .removed, old: 1, new: nil, text: "gone")])
        XCTAssertEqual(f[2].path, "gone.txt")
        XCTAssertEqual(f[1].note, "New file")
        XCTAssertEqual(f[2].note, "Deleted file")
        XCTAssertEqual(f[3].note, "Binary file, no text diff")
    }

    func testRenameKeepsBothPathsAndTheTabAfterTheNameIsDropped() {
        let r = files()[4]
        XCTAssertEqual(r.oldPath, "old name.txt"); XCTAssertEqual(r.newPath, "new name.txt")
        XCTAssertEqual(r.note, "Renamed from old name.txt (87% similar)")
        XCTAssertEqual(r.hunks[0].lines.filter { $0.kind != .context }.map(\.text), ["four", "FOUR"])
    }

    func testNoNewlineAtEndMarksTheLineBeforeIt() {
        let lines = files()[5].hunks[0].lines
        XCTAssertEqual(lines.map(\.text), ["end", "end", "more"])
        XCTAssertEqual(lines.map(\.noNewline), [true, false, true])
        XCTAssertEqual(lines.map(\.kind), [.removed, .added, .added])
    }

    func testHunkHeaderShapes() throws {
        let one = try XCTUnwrap(FileDiff.parseHunkHeader("@@ -1 +1,2 @@ func x() {"))
        XCTAssertEqual([one.oldStart, one.oldCount, one.newStart, one.newCount], [1, 1, 1, 2])
        let insert = try XCTUnwrap(FileDiff.parseHunkHeader("@@ -5,0 +6,2 @@"))
        XCTAssertEqual([insert.oldStart, insert.newStart], [6, 6], "a 0 count names the line before")
        XCTAssertNil(FileDiff.parseHunkHeader("@@ nonsense"))
    }

    func testRemovedLineThatLooksLikeAHeaderStaysInTheHunk() {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,1 @@\n--- not a header\n keep\n"
        let f = FileDiff.parse(text)[0]
        XCTAssertEqual(f.hunks[0].lines.map(\.text), ["-- not a header", "keep"])
        XCTAssertEqual(f.oldPath, "x")
    }

    func testQuotedPaths() {
        XCTAssertEqual(FileDiff.unquote("\"a/caf\\303\\251 x.txt\""), "a/café x.txt")
        XCTAssertEqual(FileDiff.unquote("plain"), "plain")
        let f = FileDiff.parse("diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"\nindex 1..2 100644\nBinary files differ\n")[0]
        XCTAssertEqual(f.path, "café.txt")
        XCTAssertEqual(FileDiff.gitLinePaths("a/x b/y b/x b/y")?.new, "x b/y", "the same path on both sides wins over the last \" b/\"")
    }

    func testGapsBetweenHunksAndAfterTheLast() {
        let rows = files()[0].rows(newText: Self.aAtBranch)
        let gaps = rows.compactMap { if case .gap(let id, let count, let old, let new) = $0 { return [id, count, old, new] } else { return nil } }
        // Line 1 before the first hunk; 9..26 between the first two; 34..37 between the next; nothing after 41.
        XCTAssertEqual(gaps, [[0, 1, 1, 1], [1, 18, 9, 9], [2, 4, 34, 34]])
        XCTAssertEqual(rows.filter { if case .hunk = $0 { return true } else { return false } }.count, 3)
    }

    func testExpandedGapShowsTheFileLinesWithBothNumbers() {
        let rows = files()[0].rows(newText: Self.aAtBranch, expanded: [1])
        let shown = rows.compactMap { if case .line(let l) = $0, l.new.map({ (9...26).contains($0) }) == true { return l } else { return nil } }
        XCTAssertEqual(shown.count, 18, "the whole gap, 9..26")
        XCTAssertEqual(shown.first { $0.new == 10 }, FileDiff.Line(kind: .context, old: 10, new: 10, text: "10"))
        XCTAssertFalse(rows.contains { if case .gap(1, _, _, _) = $0 { return true } else { return false } })
    }

    func testNoGapsWithoutTheFileOrForNewFiles() {
        let f = files()
        XCTAssertFalse(f[0].rows(newText: nil).contains { if case .gap = $0 { return true } else { return false } })
        XCTAssertEqual(f[1].rows(newText: "hello\n").count, 2)
    }

    func testArrowStepsStopAtTheEnds() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(ChangesPane.step(from: "a", in: ids, by: 1), "b")
        XCTAssertEqual(ChangesPane.step(from: "c", in: ids, by: 1), "c")
        XCTAssertEqual(ChangesPane.step(from: "a", in: ids, by: -1), "a")
        XCTAssertEqual(ChangesPane.step(from: nil, in: ids, by: 1), "a")
        XCTAssertNil(ChangesPane.step(from: nil, in: [], by: 1))
    }

    func testTerminalScriptQuotesPaths() {
        let reader = TaskDiffReader(runner: FakeTools(), repoPath: "/code/it's here", base: "main", branch: "task/n1")
        let s = DiffOpening.terminalScript(DiffFileEntry(status: .renamed(90), path: "new name.txt", oldPath: "old name.txt"), reader: reader)
        XCTAssertTrue(s.contains("git -C '/code/it'\\''s here' diff -M 'main...task/n1' -- 'old name.txt' 'new name.txt'"), s)
        XCTAssertTrue(s.hasPrefix("#!/bin/zsh\nrm -f \"$0\"\n"))
    }

    /// The reader against a throwaway repository with the real git: merge-base diff, only read commands.
    func testReaderOnARealRepository() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("diffreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let runner = ProcessToolRunner(timeout: 30), git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ args: String...) async throws {
            let r = await runner.run(git, ["-C", repo.path, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + args)
            XCTAssertEqual(r.status, 0, "git \(args.joined(separator: " ")): \(r.stderr)")
        }
        try await run("init", "-q", "-b", "main")
        try (1...40).map(String.init).joined(separator: "\n").appending("\n").write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\nfour\n".write(to: repo.appendingPathComponent("old name.txt"), atomically: true, encoding: .utf8)
        try await run("add", "-A"); try await run("commit", "-qm", "base")
        try await run("checkout", "-qb", "task/n1")
        try Self.aAtBranch.write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await run("mv", "old name.txt", "new name.txt")
        try await run("add", "-A"); try await run("commit", "-qm", "change")
        // main moves on after the branch: the merge-base diff must not show it.
        try await run("checkout", "-q", "main")
        try "later\n".write(to: repo.appendingPathComponent("main-only.txt"), atomically: true, encoding: .utf8)
        try await run("add", "-A"); try await run("commit", "-qm", "main later")

        let reader = TaskDiffReader(runner: runner, repoPath: repo.path, base: "main", branch: "task/n1")
        let list = try (await reader.files()).get()
        XCTAssertEqual(list.map(\.path), ["a.txt", "new name.txt"])
        XCTAssertEqual(list[1].status, .renamed(100))
        let a = await reader.diff(list[0])
        XCTAssertNil(a.error)
        XCTAssertEqual(a.diff?.hunks.count, 3)
        XCTAssertEqual(a.newText, Self.aAtBranch)
        XCTAssertTrue(a.raw.hasPrefix("diff --git a/a.txt b/a.txt"))
        let r = await reader.diff(list[1])
        XCTAssertEqual(r.diff?.kind, .renamed(similarity: 100))
        XCTAssertEqual(r.diff?.note, "Renamed from old name.txt")

        let missing = TaskDiffReader(runner: runner, repoPath: repo.path, base: "main", branch: "task/none")
        if case .success = await missing.files() { XCTFail("a missing branch is an error") }
    }
}

/// Snapshots → tasks/assets/N204-*.png (AGENT_PANEL_SNAPSHOT_DIR).
@MainActor
final class DiffViewSnapshotTests: XCTestCase {
    private func write(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    private var preload: DiffPreload {
        let entries = DiffFileEntry.parseNameStatus(DiffViewTests.nameStatus)
        let parsed = FileDiff.parse(DiffViewTests.diff)
        var diffs: [String: TaskFileDiff] = [:]
        for (e, d) in zip(entries, parsed) { diffs[e.id] = TaskFileDiff(diff: d, raw: "x", newText: e.path == "a.txt" ? DiffViewTests.aAtBranch : nil) }
        return DiffPreload(files: entries, diffs: diffs, selected: "a.txt")
    }

    private func detail(_ preload: DiffPreload) -> TaskDetailView {
        let card = TaskCard(id: "N204", project: "p", status: .review, agent: nil, branch: "task/n204", kind: nil, files: ["a.txt"], title: "Diff view",
                            sections: [:], url: URL(fileURLWithPath: "/x/N204.md"), modified: nil)
        return TaskDetailView(card: card, shots: [], opener: nil, startState: StartButtonState(enabled: false, help: ""),
                              reviewState: reviewButtonStates(card: card, canAct: false, reason: "x", worktreeExists: false, busy: false, agentWorking: false),
                              onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}, startTab: .changes, diffPreload: preload)
    }

    func testChangesTabWithModifiedFile() throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: detail(preload), size: CGSize(width: 760, height: 980)))
        XCTAssertGreaterThan(data.count, 20_000)
        try write(data, "N204-changes.png")
    }

    func testRenamedSelected() throws {
        var p = preload; p.selected = "new name.txt"
        let data = try XCTUnwrap(SnapshotRenderer.render(view: detail(p), size: CGSize(width: 760, height: 620)))
        try write(data, "N204-rename.png")
    }

    func testFileStates() throws {
        let p = preload
        let view = VStack(alignment: .leading, spacing: 18) {
            ForEach(["added.txt", "gone.txt", "img.bin", "tail.txt"], id: \.self) { id in
                DiffView(entry: p.files.first { $0.id == id }!, file: p.diffs[id]!)
            }
            DiffView(entry: p.files[0], file: p.diffs["a.txt"]!, expanded: [1])
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Tok.bg).environment(\.snapshotMode, true)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 700, height: 1220)))
        try write(data, "N204-states.png")
    }

    func testLargeDiffShowsTheFirstPartAndOpenButtons() throws {
        let body = (1...3500).map { "+line \($0) " + String(repeating: "long ", count: $0 == 2 ? 60 : 1) }.joined(separator: "\n")
        let d = FileDiff.parse("diff --git a/big.txt b/big.txt\nnew file mode 100644\n--- /dev/null\n+++ b/big.txt\n@@ -0,0 +1,3500 @@\n" + body + "\n")[0]
        XCTAssertEqual(d.hunks[0].lines.count, 3500)
        XCTAssertGreaterThan(d.rows(newText: nil).count, FileDiff.rowLimit)
        let entry = DiffFileEntry(status: .added, path: "big.txt")
        let view = DiffView(entry: entry, file: TaskFileDiff(diff: d, raw: "x"), openInXcode: {}, openInTerminal: {})
            .padding(24).frame(width: 700, alignment: .topLeading).background(Tok.bg).environment(\.snapshotMode, true)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: Color.clear.overlay(alignment: .top) { view }.clipped(), size: CGSize(width: 700, height: 360)))
        try write(data, "N204-large.png")
    }
}
