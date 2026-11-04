import XCTest
import SwiftUI
@testable import AgentPanel

/// Editing .gitignore (N180): new lines, tracked files they match, where .agent-worktrees/ is ignored and the commit.
@MainActor
final class GitignoreTests: XCTestCase {
    func testPatternsSkipCommentsAndBlanks() {
        XCTAssertEqual(Gitignore.patterns("# c\n\n.DS_Store\n  tmp/  \n!keep\n"), [".DS_Store", "tmp/", "!keep"])
    }

    func testAddedPatternsAreNewAndNotNegations() {
        XCTAssertEqual(Gitignore.addedPatterns(old: ".DS_Store\ntmp/\n", new: ".DS_Store\ntmp/\napp/build.log\n!x\n# note\n.env\n"), ["app/build.log", ".env"])
        XCTAssertEqual(Gitignore.addedPatterns(old: "a\n", new: "a\n"), [])
    }

    func testAddingALineKeepsTheEndingAndSkipsDuplicates() {
        XCTAssertEqual(Gitignore.adding(".env", to: "a\n"), "a\n.env\n")
        XCTAssertEqual(Gitignore.adding(".env", to: "a"), "a\n.env\n")
        XCTAssertEqual(Gitignore.adding(".env", to: ""), ".env\n")
        XCTAssertEqual(Gitignore.adding(".env", to: "a\n.env\n"), "a\n.env\n")
        XCTAssertTrue(Gitignore.contains(".agent-worktrees/", in: "/.agent-worktrees/\n"), "a leading slash names the same root folder")
        XCTAssertFalse(Gitignore.contains(".env", in: ".envrc\n"))
    }

    func testCommitMessage() {
        XCTAssertEqual(Gitignore.commitMessage(old: "a\n", new: "a\n.env\n"), "chore: ignore .env in .gitignore")
        XCTAssertEqual(Gitignore.commitMessage(old: "a\n", new: "a\n.env\nDerivedData/\n"), "chore: ignore .env, DerivedData/ in .gitignore")
        XCTAssertEqual(Gitignore.commitMessage(old: "a\nb\n", new: "a\n"), "chore: update .gitignore", "a line removed")
        XCTAssertEqual(Gitignore.commitMessage(old: "", new: "1\n2\n3\n4\n"), "chore: update .gitignore", "many lines")
    }

    func testAgentWorktreesSourceFromCheckIgnore() {
        XCTAssertEqual(Gitignore.source(checkIgnore: ".gitignore:3:.agent-worktrees/\t.agent-worktrees/\n"), .gitignore)
        XCTAssertEqual(Gitignore.source(checkIgnore: ".git/info/exclude:7:/.agent-worktrees/\t.agent-worktrees/\n"), .exclude)
        XCTAssertEqual(Gitignore.source(checkIgnore: "/Users/me/code/.git/info/exclude:1:/.agent-worktrees/\t.agent-worktrees/\n"), .exclude)
        XCTAssertEqual(Gitignore.source(checkIgnore: "/Users/me/.config/git/ignore:2:.agent-worktrees\t.agent-worktrees/\n"), .other("/Users/me/.config/git/ignore"))
        XCTAssertEqual(Gitignore.source(checkIgnore: ".gitignore:3:!.agent-worktrees/\t.agent-worktrees/\n"), .nowhere, "a negation un-ignores")
        XCTAssertEqual(Gitignore.source(checkIgnore: ""), .nowhere)
    }

    func testAgentWorktreesNote() {
        XCTAssertEqual(Gitignore.agentWorktreesNote(.exclude), ".agent-worktrees/ is ignored in .git/info/exclude (this Mac only). Tentacl Crew needs it ignored somewhere.")
        XCTAssertEqual(Gitignore.agentWorktreesNote(.gitignore), ".agent-worktrees/ is ignored in .gitignore.")
        XCTAssertEqual(Gitignore.agentWorktreesNote(.nowhere), ".agent-worktrees/ is not ignored anywhere: agent worktrees would show up as untracked files. Add it here.")
        XCTAssertEqual(Gitignore.effectiveSource(text: "x\n.agent-worktrees/\n", read: .nowhere), .gitignore, "the edited text counts before it is saved")
        XCTAssertEqual(Gitignore.effectiveSource(text: "x\n", read: .gitignore), .nowhere, "removed from the edited text")
        XCTAssertEqual(Gitignore.effectiveSource(text: "x\n", read: .exclude), .exclude)
    }

    func testTrackedWarning() {
        XCTAssertNil(Gitignore.trackedWarning([]))
        XCTAssertEqual(Gitignore.trackedWarning(["app/build.log", "tmp/notes.txt"]),
                       "2 tracked files match the new lines and stay tracked until you remove them from git: app/build.log, tmp/notes.txt.")
        XCTAssertEqual(Gitignore.trackedWarning(["a"]), "1 tracked file matches the new lines and stays tracked until you remove it from git: a.")
        XCTAssertTrue(Gitignore.trackedWarning((1...12).map { "f\($0)" })!.hasSuffix("f1, f2, f3, f4, f5, f6, f7, f8 and 4 more."))
    }

    // MARK: Real temp repository

    private func makeRepo(_ dir: TempDir) throws -> String {
        let repo = dir.url.path
        func git(_ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"])
        try dir.write("tmp/notes.txt", "n\n"); try dir.write("app/build.log", "l\n"); try dir.write("keep.txt", "k\n"); try dir.write(".gitignore", ".DS_Store\n")
        try git(["add", "-A"])
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "first"])
        try "/.agent-worktrees/\n".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
        return repo
    }

    func testTrackedMatchesAndReadInARealRepository() async throws {
        let dir = try TempDir()
        let repo = try makeRepo(dir)
        let tool = GitignoreTool(runner: ProcessToolRunner(timeout: 20))
        let matches = await tool.trackedMatches(repoPath: repo, patterns: ["tmp/", "*.log", "nothing-here"])
        XCTAssertEqual(matches, ["app/build.log", "tmp/notes.txt"])
        let none = await tool.trackedMatches(repoPath: repo, patterns: [])
        XCTAssertEqual(none, [])
        let info = await tool.read(repoPath: repo)
        XCTAssertEqual(info.text, ".DS_Store\n")
        XCTAssertEqual(info.agentWorktrees, .exclude)
        XCTAssertEqual(info.branch, "main")
    }

    func testSaveWritesTheFileAndCommitsOnlyIt() async throws {
        let dir = try TempDir()
        try dir.write(".gitignore", "a\n")
        let tools = FakeTools()
        let tool = GitignoreTool(runner: tools)
        let error = await tool.save(repoPath: dir.url.path, text: "a\n.env\n", commitMessage: "chore: ignore .env in .gitignore")
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: dir.url.appendingPathComponent(".gitignore"), encoding: .utf8), "a\n.env\n")
        XCTAssertEqual(tools.joined, ["/usr/bin/git -C \(dir.url.path) add -- .gitignore",
                                      "/usr/bin/git -C \(dir.url.path) commit -m chore: ignore .env in .gitignore -- .gitignore"])
    }

    func testSaveWithoutCommitRunsNoGit() async throws {
        let dir = try TempDir()
        let tools = FakeTools()
        let error = await GitignoreTool(runner: tools).save(repoPath: dir.url.path, text: ".env\n", commitMessage: nil)
        XCTAssertNil(error)
        XCTAssertEqual(tools.joined, [])
        XCTAssertEqual(try String(contentsOf: dir.url.appendingPathComponent(".gitignore"), encoding: .utf8), ".env\n")
    }

    func testCommitFailureSaysTheFileWasSaved() async throws {
        let dir = try TempDir()
        let tools = FakeTools(); tools.handler = { $0.contains(" commit ") ? FakeTools.fail("fatal: cannot do a partial commit during a merge.") : FakeTools.ok() }
        let error = await GitignoreTool(runner: tools).save(repoPath: dir.url.path, text: ".env\n", commitMessage: "m")
        XCTAssertEqual(error, ".gitignore is saved but not committed: fatal: cannot do a partial commit during a merge.")
    }

    // MARK: Flow

    func testFlowChipsMatchesAndSave() async throws {
        let dir = try TempDir()
        let repo = try makeRepo(dir)
        let flow = GitignoreFlow(repoPath: repo, projectName: "demo", tool: GitignoreTool(runner: ProcessToolRunner(timeout: 20)))
        await flow.load()
        XCTAssertEqual(flow.text, ".DS_Store\n")
        XCTAssertTrue(flow.commit, "on by default")
        XCTAssertFalse(flow.has(".env"))
        flow.add(".env")
        XCTAssertTrue(flow.has(".env"))
        flow.text += "tmp/\n"
        await flow.findTracked()
        XCTAssertEqual(flow.tracked, ["tmp/notes.txt"])
        XCTAssertEqual(flow.commitLabel, "Commit the change on main (\"chore: ignore .env, tmp/ in .gitignore\")")
        flow.commit = false
        let saved = await flow.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOfFile: repo + "/.gitignore", encoding: .utf8), ".DS_Store\n.env\ntmp/\n")
    }

    // MARK: Screenshot

    private struct NoScripts: ScriptRunning {
        func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { ScriptResult(status: 0, stdout: "", stderr: "") }
    }

    func testScreenshotEditProjectHasTheGitignoreButton() throws {
        let project = ProjectConfig(id: "demo", name: "Demo App", repoPath: "/code/demo", dataDir: "/data/demo", maxParallel: 2, buildCommand: nil,
                                    xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
        let flow = EditProjectFlow(project: project, registry: ProjectRegistry(settingsURL: URL(fileURLWithPath: "/x"), scripts: NoScripts()))
        let view = EditProjectSheet(flow: flow, onSaved: { _ in }, onRemoved: {}, onCancel: {})
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 560, height: 640)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("edit-project-gitignore.png")) }
    }

    func testScreenshotSheet() async throws {
        let flow = GitignoreFlow(repoPath: "/demo", projectName: "agent-panel", tool: nil)
        flow.preview(original: ".DS_Store\ntmp/\n.superpowers/\napp/build/\n**/xcuserdata/\napp/Signing.local.xcconfig\n",
                     text: ".DS_Store\ntmp/\n.superpowers/\napp/build/\n**/xcuserdata/\napp/Signing.local.xcconfig\napp/build.log\n",
                     tracked: ["app/build.log"], source: .exclude, branch: "main")
        let view = GitignoreSheet(flow: flow, onDone: { _ in })
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 600, height: 540)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("gitignore-sheet.png")) }
    }
}
