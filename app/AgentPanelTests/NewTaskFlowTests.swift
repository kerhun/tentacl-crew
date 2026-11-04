import XCTest
import SwiftUI
@testable import AgentPanel

@MainActor
final class NewTaskFlowTests: XCTestCase {
    private func flow(_ dir: TempDir, existing: Set<String> = [], roles: [String] = ["dev", "reviewer"]) -> NewTaskFlow {
        let f = NewTaskFlow(projectID: "demo", tasksDir: dir.url.appendingPathComponent("tasks"), roles: roles, existingIDs: { existing })
        f.title = "Add a search box"
        f.goal = "Let people search the list."
        return f
    }

    // MARK: next free id

    func testNextIDIsOnePastTheHighestForThePrefix() {
        XCTAssertEqual(NewTaskFlow.nextID(prefix: "T", existing: []), "T1")
        XCTAssertEqual(NewTaskFlow.nextID(prefix: "T", existing: ["T1", "T2", "T7", "N20", "TX9"]), "T8")
        XCTAssertEqual(NewTaskFlow.nextID(prefix: "N", existing: ["N20", "T7"]), "N21")
    }

    func testNextIDSkipsAnIdTakenByAFileOnDisk() throws {
        let dir = try TempDir()
        try dir.write("tasks/T1.md", "x")
        let f = NewTaskFlow(projectID: "demo", tasksDir: dir.url.appendingPathComponent("tasks"), roles: ["dev"], existingIDs: { [] })
        XCTAssertEqual(f.nextID, "T2")
    }

    // MARK: validation

    func testAValidFormHasNoProblems() throws {
        let f = flow(try TempDir())
        XCTAssertEqual(f.problems, [])
        XCTAssertTrue(f.canSubmit)
    }

    func testTitleAndGoalAreRequired() throws {
        let f = flow(try TempDir()); f.title = "  "; f.goal = ""
        XCTAssertEqual(f.problems.count, 2)
        XCTAssertFalse(f.canSubmit)
    }

    func testPrefixMustBeShortAsciiLetters() throws {
        let f = flow(try TempDir())
        for bad in ["", "1", "T-", "ü", "../x", "ABCDEFGHI"] { f.prefix = bad; XCTAssertFalse(f.problems.isEmpty, bad) }
        f.prefix = "Fix"; XCTAssertEqual(f.problems, []); XCTAssertEqual(f.nextID, "Fix1")
    }

    func testFilesMustBeRelativePathsInsideTheRepository() throws {
        let f = flow(try TempDir())
        for bad in ["/etc/passwd", "../x.swift", "a/../../b", "~/x"] { f.files = bad; XCTAssertFalse(f.problems.isEmpty, bad) }
        f.files = "App/A.swift\n\n  App/B.swift  "
        XCTAssertEqual(f.problems, [])
        XCTAssertEqual(f.fileList, ["App/A.swift", "App/B.swift"])
    }

    func testBranchIsOptionalButValidatedWithTheTaskInputRule() throws {
        let f = flow(try TempDir())
        f.branch = "feat/search"; XCTAssertEqual(f.problems, [])
        for bad in ["bad branch", "a..b", "-x", "x.lock"] { f.branch = bad; XCTAssertFalse(f.problems.isEmpty, bad) }
    }

    func testDependenciesMustBeExistingCardIds() throws {
        let f = flow(try TempDir(), existing: ["A1", "A2"])
        f.dependencies = "A1, A2"; XCTAssertEqual(f.problems, [])
        f.dependencies = "A1 Z9"; XCTAssertEqual(f.problems.count, 1)
        f.dependencies = "bad id!"; XCTAssertFalse(f.problems.isEmpty)
    }

    func testRoleMustBeOneOfTheProjectsRoles() throws {
        let f = flow(try TempDir()); f.role = "ghost"
        XCTAssertFalse(f.problems.isEmpty)
        XCTAssertEqual(NewTaskFlow(projectID: "d", tasksDir: URL(fileURLWithPath: "/nonexistent"), roles: [], existingIDs: { [] }).roles, ["dev"])
    }

    func testBodyLinesCannotStartASectionOrHeading() throws {
        let f = flow(try TempDir()); f.scope = "fine\n## Report\nsneaky"
        XCTAssertFalse(f.problems.isEmpty)
        f.scope = "a line with # inside"; XCTAssertEqual(f.problems, [])
    }

    // MARK: writing

    func testSubmitWritesACardThatParsesAndRoundTrips() throws {
        let dir = try TempDir()
        let f = flow(dir, existing: ["A1"])
        f.scope = "Only the list view."; f.acceptance = "A test passes."; f.files = "App/List.swift\nApp/Search.swift"
        f.role = "reviewer"; f.kind = .analysis; f.branch = "feat/search"; f.dependencies = "A1"
        let id = try XCTUnwrap(f.submit())
        XCTAssertEqual(id, "T1")
        let url = dir.url.appendingPathComponent("tasks/T1.md")
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        XCTAssertEqual(card.id, "T1"); XCTAssertEqual(card.project, "demo"); XCTAssertEqual(card.status, .todo)
        XCTAssertEqual(card.from, "user"); XCTAssertEqual(card.roles, ["reviewer"]); XCTAssertEqual(card.kind, "analysis")
        XCTAssertEqual(card.branch, "feat/search"); XCTAssertEqual(card.files, ["App/List.swift", "App/Search.swift"])
        XCTAssertEqual(card.title, "T1 · Add a search box")
        XCTAssertEqual(card.sections["Goal"], "Let people search the list.")
        XCTAssertEqual(card.sections["Scope"], "Only the list view.")
        XCTAssertEqual(card.sections["Acceptance criteria"], "A test passes.")
        XCTAssertEqual(card.sections["Dependencies"], "- A1")
        XCTAssertEqual(card.sections["Report"], "")
        XCTAssertNil(card.agent)
    }

    func testANormalCardWithoutDependenciesSaysNone() throws {
        let dir = try TempDir(); let f = flow(dir)
        XCTAssertEqual(f.submit(), "T1")
        let url = dir.url.appendingPathComponent("tasks/T1.md")
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        XCTAssertNil(card.kind); XCTAssertEqual(card.roles, ["dev"]); XCTAssertEqual(card.sections["Dependencies"], "None.")
    }

    func testSubmitNeverOverwritesAnExistingCard() throws {
        let dir = try TempDir()
        let url = try dir.write("tasks/T1.md", "mine")
        let f = flow(dir)
        f.prefix = "T"
        XCTAssertEqual(f.submit(), "T2")   // the file on disk is seen, so T1 is skipped
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine")
        // A card that appears between the check and the write is refused, not replaced.
        XCTAssertThrowsError(try CardCreator().create(text: "other", id: "T1", in: dir.url.appendingPathComponent("tasks")))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine")
    }

    func testSubmitWithProblemsWritesNothing() throws {
        let dir = try TempDir(); let f = flow(dir); f.title = ""
        XCTAssertNil(f.submit())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("tasks").path))
    }

    // MARK: edit

    private let original = """
    ---
    id: B1
    project: demo
    status: todo
    custom: keep me
    roles: [dev]
    from: user
    files:
      - App/A.swift
    ---
    # B1 · Old title

    ## Goal
    Old goal.

    ## Notes
    Mine, untouched.

    ## Dependencies
    None.

    ## Report

    """

    /// A TempDir deletes its folder when released, so the ones made for edit tests live as long as the test case.
    private var dirs: [TempDir] = []

    private func editing(_ dir: TempDir, _ text: String? = nil, existing: Set<String> = ["A1", "B1"]) throws -> (NewTaskFlow, URL) {
        dirs.append(dir)
        let url = try dir.write("tasks/B1.md", text ?? original)
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        return (NewTaskFlow(editing: card, tasksDir: url.deletingLastPathComponent(), roles: ["dev", "reviewer"], existingIDs: { existing }), url)
    }

    func testEditShowsTheCardsValues() throws {
        let (f, _) = try editing(try TempDir())
        XCTAssertTrue(f.isEditing); XCTAssertEqual(f.nextID, "B1")
        XCTAssertEqual(f.title, "Old title"); XCTAssertEqual(f.goal, "Old goal."); XCTAssertEqual(f.files, "App/A.swift"); XCTAssertEqual(f.dependencies, "")
        XCTAssertEqual(f.role, "dev"); XCTAssertEqual(f.priority, .normal)
        XCTAssertEqual(f.problems, [])
    }

    func testEditRoundTripKeepsUnknownKeysAndOtherSections() throws {
        let (f, url) = try editing(try TempDir())
        f.title = "New title"; f.goal = "New goal."; f.scope = "A scope."; f.files = "App/A.swift\nApp/B.swift"
        f.dependencies = "A1"; f.role = "reviewer"; f.kind = .analysis; f.priority = .high; f.branch = "feat/x"
        XCTAssertEqual(f.submit(), "B1")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("custom: keep me\n"))
        XCTAssertTrue(text.contains("## Notes\nMine, untouched.\n"))
        let card = try CardParser.parse(text, url: url)
        XCTAssertEqual(card.title, "B1 · New title"); XCTAssertEqual(card.sections["Goal"], "New goal."); XCTAssertEqual(card.sections["Scope"], "A scope.")
        XCTAssertEqual(card.sections["Dependencies"], "- A1"); XCTAssertEqual(card.sections["Report"], "")
        XCTAssertEqual(card.files, ["App/A.swift", "App/B.swift"]); XCTAssertEqual(card.roles, ["reviewer"]); XCTAssertEqual(card.kind, "analysis")
        XCTAssertEqual(card.priority, .high); XCTAssertEqual(card.branch, "feat/x"); XCTAssertEqual(card.status, .todo); XCTAssertEqual(card.from, "user")
    }

    func testEditWithoutChangesLeavesTheFileAsItWas() throws {
        let (f, url) = try editing(try TempDir())
        XCTAssertEqual(f.submit(), "B1")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testEditCanClearKindBranchFilesAndPriority() throws {
        let text = original.replacingOccurrences(of: "from: user", with: "from: user\nkind: analysis\nbranch: feat/y\npriority: high")
        let (f, url) = try editing(try TempDir(), text)
        f.kind = .normal; f.branch = ""; f.files = ""; f.priority = .low
        XCTAssertEqual(f.submit(), "B1")
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        XCTAssertNil(card.kind); XCTAssertNil(card.branch); XCTAssertEqual(card.files, []); XCTAssertEqual(card.priority, .low)
        XCTAssertEqual(card.sections["Notes"], "Mine, untouched.")
    }

    func testACardChangedSinceItWasReadIsNotOverwritten() throws {
        let dir = try TempDir()
        let (f, url) = try editing(dir)
        let changed = original.replacingOccurrences(of: "Old goal.", with: "Someone else wrote this.")
        try changed.write(to: url, atomically: true, encoding: .utf8)
        f.title = "Mine"
        XCTAssertNil(f.submit()); XCTAssertNotNil(f.failure)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
        // Same for a front matter change.
        let (g, url2) = try editing(try TempDir())
        let moved = original.replacingOccurrences(of: "custom: keep me", with: "custom: other")
        try moved.write(to: url2, atomically: true, encoding: .utf8)
        g.goal = "Mine"
        XCTAssertNil(g.submit())
        XCTAssertEqual(try String(contentsOf: url2, encoding: .utf8), moved)
    }

    func testARunningCardCannotBeEditedOrGetStatusActions() throws {
        for status in ["doing", "review", "needs-fix"] {
            let (f, url) = try editing(try TempDir(), original.replacingOccurrences(of: "status: todo", with: "status: \(status)"))
            XCTAssertEqual(f.statusActions, [], status)
            f.title = "x"
            XCTAssertNil(f.submit(), status); XCTAssertFalse(f.setStatus(.cancelled), status)
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("status: \(status)"))
        }
    }

    func testStatusActionsMoveANonRunningCardAndKeepTheRest() throws {
        let (f, url) = try editing(try TempDir())
        XCTAssertEqual(f.statusActions, [.blocked, .cancelled])
        XCTAssertTrue(f.setStatus(.blocked))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original.replacingOccurrences(of: "status: todo", with: "status: blocked"))
        let card = try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        let g = NewTaskFlow(editing: card, tasksDir: url.deletingLastPathComponent(), roles: ["dev"], existingIDs: { [] })
        XCTAssertEqual(g.statusActions, [.todo, .cancelled])
        XCTAssertTrue(g.setStatus(.todo))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testPriorityIsWrittenOnNewTasksOnlyWhenNotNormal() throws {
        let dir = try TempDir(); let f = flow(dir)
        XCTAssertEqual(f.submit(), "T1")
        XCTAssertFalse(try String(contentsOf: dir.url.appendingPathComponent("tasks/T1.md"), encoding: .utf8).contains("priority:"))
        let g = flow(dir); g.priority = .high
        XCTAssertEqual(g.submit(), "T2")
        let url = dir.url.appendingPathComponent("tasks/T2.md")
        XCTAssertEqual(try CardParser.parse(try String(contentsOf: url, encoding: .utf8), url: url).priority, .high)
    }

    func testEditSheetRendersToAPNG() throws {
        let (f, _) = try editing(try TempDir())
        let data = try XCTUnwrap(SnapshotRenderer.render(view: NewTaskSheet(flow: f, onCreated: { _ in }, onCancel: {}), size: CGSize(width: 620, height: 860)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH_EDIT"] { try data.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: sheet

    func testSheetRendersToAPNG() throws {
        let f = flow(try TempDir())
        f.scope = "Only the list view."; f.files = "App/List.swift"; f.dependencies = ""
        let data = try XCTUnwrap(SnapshotRenderer.render(view: NewTaskSheet(flow: f, onCreated: { _ in }, onCancel: {}), size: CGSize(width: 620, height: 820)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }
}
