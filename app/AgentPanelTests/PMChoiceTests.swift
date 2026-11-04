import SwiftUI
import XCTest
@testable import AgentPanel

/// A project's PM lives in that project's folder (N129): candidates and implicit choices are agents inside `repoPath`;
/// an outside choice keeps working but is flagged; Start a PM here opens a session in the folder and chooses it.
@MainActor
final class PMChoiceTests: XCTestCase {
    private var dir: TempDir!
    private var iso: TestIsolation!
    private var scripts: FakeScripts!
    private var repo: String { dir.url.appendingPathComponent("repo").path }

    override func setUpWithError() throws {
        dir = try TempDir(); iso = TestIsolation(dir, owner: self); scripts = FakeScripts()
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("repo/.agent-worktrees/task-n1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("other"), withIntermediateDirectories: true)
    }

    private func agent(_ pane: String, cwd: String, session: String?, title: String = "claude") -> AgentStatus {
        AgentStatus(paneID: pane, workspaceID: "w", state: .idle, cwd: cwd, title: title, sessionID: session)
    }

    private func panel(agents: [AgentStatus], repoPath: String? = nil) async throws -> PanelModel {
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        try dir.write("roles/pm.json", "{\"name\":\"pm\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"pm.md\"}")
        let project = try dir.write("a/project.json", "{\"id\":\"a\",\"name\":\"Project A\",\"repoPath\":\"\(repoPath ?? repo)\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"sharedFiles\":[],\"openWith\":\"Xcode\",\"roles\":{\"pm\":\"\(dir.url.appendingPathComponent("roles/pm.json").path)\"}}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(project.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let s = scripts!, c = FakeCommander()
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(agents)) }, opener: RecordingOpener(),
                           makeScripts: { _ in s }, makeCommander: { c }, log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        await m.reload()
        return m
    }

    func testOnlyAgentsInsideTheRepoAreCandidates() async throws {
        let inside = agent("p1", cwd: repo, session: "s1"), sub = agent("p2", cwd: repo + "/app", session: "s2")
        let outside = agent("p3", cwd: dir.url.appendingPathComponent("other").path, session: "s3")
        let m = try await panel(agents: [inside, sub, outside])
        XCTAssertEqual(m.pmCandidates.map(\.paneID), ["p1", "p2"], "the agent outside the folder is not offered")
    }

    func testAWorktreeAgentOfACardIsNotACandidate() async throws {
        try dir.write("data/tasks/N1.md", "---\nid: N1\nproject: a\nstatus: doing\nbranch: task/n1\nagent:\nfiles:\n  - A.swift\n---\n# N1 · T\n\n## Goal\nG.\n")
        let m = try await panel(agents: [agent("p4", cwd: repo + "/.agent-worktrees/task-n1", session: "s4"), agent("p1", cwd: repo, session: "s1")])
        await m.reload()
        XCTAssertEqual(m.pmCandidates.map(\.paneID), ["p1"])
    }

    func testPathsAreStandardized() async throws {
        let link = dir.url.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: repo)
        let m = try await panel(agents: [agent("p1", cwd: repo + "/", session: "s1"), agent("p2", cwd: link, session: "s2"), agent("p3", cwd: repo + "/../other", session: "s3")])
        XCTAssertEqual(m.pmCandidates.map(\.paneID), ["p1", "p2"], "trailing slash and symlink count as inside, ../ out does not")
        let viaLink = try await panel(agents: [agent("p1", cwd: repo, session: "s1")], repoPath: link + "/")
        XCTAssertEqual(viaLink.pmCandidates.map(\.paneID), ["p1"], "a repoPath given as a symlink with a trailing slash")
    }

    func testAChoiceOutsideTheFolderIsKeptAndFlagged() async throws {
        let outside = agent("p3", cwd: dir.url.appendingPathComponent("other").path, session: "s3", title: "Tentacl PM")
        iso.defaults.set("s3", forKey: "pmSession.a")
        let m = try await panel(agents: [outside])
        XCTAssertEqual(m.pmAgent(forProject: "a")?.paneID, "p3", "still works")
        XCTAssertEqual(m.pmOutsideFolder, ResolvedPaths.shared.resolved(dir.url.appendingPathComponent("other").path))
        XCTAssertEqual(PMOutsideWarning.text(folder: "/x/other", repo: "/x/repo"),
                       "This PM runs in /x/other, not in /x/repo. Its history and memory go to the other project.")
    }

    func testAPMInsideTheFolderIsNotFlagged() async throws {
        iso.defaults.set("s1", forKey: "pmSession.a")
        let m = try await panel(agents: [agent("p1", cwd: repo, session: "s1")])
        XCTAssertNotNil(m.pmAgent(forProject: "a"))
        XCTAssertNil(m.pmOutsideFolder)
    }

    func testChoosingOrMessagingAnOutsideAgentDoesNotMakeItThePM() async throws {
        let outside = agent("p3", cwd: dir.url.appendingPathComponent("other").path, session: "s3")
        let m = try await panel(agents: [outside])
        m.choosePM(outside, forProject: "a")
        XCTAssertNil(m.pmSession(forProject: "a"))
        _ = await m.sendCommand("hi", to: "p3", session: "s3")
        XCTAssertNil(m.pmSession(forProject: "a"), "the first message to an outside agent chooses nothing")
        let inside = agent("p1", cwd: repo, session: "s1")
        let n = try await panel(agents: [inside])
        _ = await n.sendCommand("hi", to: "p1", session: "s1")
        XCTAssertEqual(n.pmSession(forProject: "a"), "s1", "an agent inside is chosen as before")
    }

    func testStartAPMHereSpawnsInTheFolderAndChoosesIt() async throws {
        let outside = agent("p3", cwd: dir.url.appendingPathComponent("other").path, session: "s3", title: "Tentacl PM")
        let fresh = agent("w9:p1", cwd: repo, session: "s9", title: "pm")
        iso.defaults.set("s3", forKey: "pmSession.a")
        scripts.handler = { _, _ in ScriptResult(status: 0, stdout: "{\"agent\":\"pm-a\",\"workspace_id\":\"w9\",\"pane_id\":\"w9:p1\"}\n", stderr: "") }
        let m = try await panel(agents: [outside, fresh])
        await m.startPMHere()
        let call = try XCTUnwrap(scripts.calls(of: .spawn).first)
        XCTAssertEqual(call.args.first, "--no-card")
        XCTAssertEqual(m.pmSession(forProject: "a"), "s9")
        XCTAssertEqual(m.pmAgent(forProject: "a")?.paneID, "w9:p1")
        XCTAssertNil(m.pmOutsideFolder)
    }

    /// Snapshots of the Dashboard chat header with the outside-folder warning and with "Start a PM here" (set AGENT_PANEL_SNAPSHOT_DIR to save them).
    func testSnapshotsOfTheWarningAndTheStartBar() throws {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = VStack(spacing: 0) {
                PMChatHeader(status: .idle, projectName: "Tentacl")
                PMOutsideWarning(folder: "/Users/me/Documents/GitHub/orchard", repo: "/Users/me/Documents/GitHub/agent-panel")
                Divider()
                PMChatHeader(status: .missing, projectName: "Tentacl")
            }.frame(width: 760).padding(.vertical, 8).background(Tok.bg).environment(\.colorScheme, scheme)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 760, height: 190)))
            XCTAssertGreaterThan(data.count, 1_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("pm-folder-\(name).png")) }
        }
    }
}
