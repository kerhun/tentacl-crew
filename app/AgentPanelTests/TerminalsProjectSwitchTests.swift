import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

/// N243: the Terminals screen in the whole window, project switched under it. Each project keeps its own saved panes.
@MainActor
final class TerminalsProjectSwitchTests: XCTestCase {
    /// Two terminals in each project's repository; `extra` adds a third one to the project's repository (an agent list that changes).
    private final class Listing: TerminalListing, @unchecked Sendable {
        var extra: [AgentStatus] = []
        let repos: [String: String]
        init(repos: [String: String]) { self.repos = repos }
        func agents() async throws -> [AgentStatus] {
            let base = [("w1:a1", "a"), ("w1:a2", "a"), ("w2:b1", "b"), ("w2:b2", "b")].map {
                AgentStatus(paneID: $0.0, workspaceID: String($0.0.prefix(2)), state: .idle, cwd: repos[$0.1]!, title: "zsh \($0.0)", sessionID: nil)
            }
            return base + extra
        }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
    }

    private var dir: TempDir!
    private var model: PanelModel!
    private var window: NSWindow!
    private var listing: Listing!

    override func setUp() async throws {
        dir = try TempDir()
        let work = dir.url
        let scripts = work.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ScriptName.allCases { try "#!/bin/bash\nexit 0\n".write(to: scripts.appendingPathComponent(name.rawValue), atomically: true, encoding: .utf8) }
        var repos: [String: String] = [:]
        func project(_ id: String, _ name: String) throws -> String {
            let repo = work.appendingPathComponent("repo-\(id)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            repos[id] = repo.path
            return try dir.write("\(id)/project.json", "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"repoPath\":\"\(repo.path)\",\"dataDir\":\"\(work.appendingPathComponent("data-\(id)").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}").path
        }
        let a = try project("a", "Alpha"), b = try project("b", "Beta")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(a)\",\"\(b)\"],\"scriptsDir\":\"\(scripts.path)\"}")
        let iso = TestIsolation(dir, owner: self)
        listing = Listing(repos: repos)
        let shared = listing!
        model = PanelModel(settingsURL: settings, makeTerminal: { shared }, opener: RecordingOpener(), makeScripts: { _ in DemoScripts() },
                           makeCommander: { DemoCommander() }, log: iso.log, writer: DemoCardWriter(), defaults: iso.defaults, roleStore: iso.roleStore)
        await model.reload()
        XCTAssertEqual(model.selectedProjectID, "a")
    }

    override func tearDown() async throws {
        window?.orderOut(nil); window = nil; model = nil
    }

    private func split(_ first: String, _ second: String) -> TerminalPaneLayout {
        var layout = TerminalPaneLayout(terminal: first)
        XCTAssertTrue(layout.drop(second, on: 1, zone: .right))
        return layout
    }

    /// B has its own layout; the one of A, shown before the switch, must not be saved over it.
    func testSwitchingProjectKeepsEachProjectsSavedPanes() async throws {
        let layoutA = split("w1:a1", "w1:a2"), layoutB = TerminalPaneLayout(terminal: "w2:b2")
        TerminalPaneStore.save(model.defaults, project: "a", layoutA)
        TerminalPaneStore.save(model.defaults, project: "b", layoutB)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ShellView(model: model, screen: .terminals))
        window.makeKeyAndOrderFront(nil)
        await model.refreshAgents()
        try await settle()
        XCTAssertEqual(TerminalPaneStore.load(model.defaults, project: "a"), layoutA)

        await model.selectProject("b")
        try await settle()
        // An agent list that changes after the switch is what made the old project's panes reconcile and save under B.
        listing.extra = [AgentStatus(paneID: "w2:b3", workspaceID: "w2", state: .idle, cwd: listing.repos["b"]!, title: "zsh b3", sessionID: nil)]
        await model.refreshAgents()
        try await settle()
        XCTAssertEqual(TerminalPaneStore.load(model.defaults, project: "b"), layoutB, "B's saved panes are not overwritten")
        XCTAssertEqual(TerminalPaneStore.load(model.defaults, project: "a"), layoutA)

        await model.selectProject("a")
        try await settle()
        listing.extra = []
        await model.refreshAgents()
        try await settle()
        XCTAssertEqual(TerminalPaneStore.load(model.defaults, project: "a"), layoutA, "back on A: its panes")
        XCTAssertEqual(TerminalPaneStore.load(model.defaults, project: "b"), layoutB)
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
