import Foundation

/// Sample agents for demo mode and snapshots.
struct DemoTerminal: TerminalListing {
    func agents() async throws -> [AgentStatus] {
        [AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: "/Users/you/Projects/demo", title: "PM"),
         AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .working, cwd: "/Users/you/Projects/demo/.agent-worktrees/feat-b3-a11y", title: "dev-1 · B3"),
         AgentStatus(paneID: "w5:p1", workspaceID: "w5", state: .working, cwd: "/Users/you/Projects/demo/.agent-worktrees/fix-a5-widget", title: "dev-4 · A5"),
         AgentStatus(paneID: "w4:p1", workspaceID: "w4", state: .blocked, cwd: "/Users/you/Projects/demo/.agent-worktrees/docs-a4-open-items", title: "dev-2 · A4")]
    }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
}

/// Demo actions: they answer like the real scripts but touch nothing, so the whole panel can be tried without side effects.
struct DemoScripts: ScriptRunning {
    func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult {
        switch script {
        case .spawn:
            if arguments.first == "--print-flags" {
                return ScriptResult(status: 0, stdout: "--model sonnet --effort medium --permission-mode acceptEdits --append-system-prompt-file /demo/instructions.md --settings /demo/settings.json\n", stderr: "")
            }
            let id = arguments.count > 2 ? arguments[2].lowercased() : "task"
            return ScriptResult(status: 0, stdout: "{\"agent\":\"dev-\(id)\",\"workspace_id\":\"w9\",\"pane_id\":\"w9:p1\",\"worktree_path\":\"/demo/.agent-worktrees/\(id)\",\"udid\":\"DEMO-UDID\"}\n", stderr: "")
        default: return ScriptResult(status: 0, stdout: "", stderr: "")
        }
    }
}

struct DemoCommander: TerminalCommanding {
    func prompt(target: String, text: String) async throws {}
}

/// Pretends to update the card; the demo data on disk is never changed.
struct DemoCardWriter: CardWriting {
    func update(_ card: TaskCard, set values: [CardField: String], section: SectionEdit?, expectingStatus: TaskStatus) throws {}
}

/// Demo mode (`--demo`): sample project data from app/Demo and fake agents, so the panel can be seen and
/// screenshotted without a real project or terminal. Works from a source checkout (the demo folder is found
/// relative to this file) or with AGENT_PANEL_DEMO_DIR pointing at a folder like app/Demo.
@MainActor
enum DemoSupport {
    static var demoDir: URL {
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_DEMO_DIR"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Demo")
    }

    /// Writes a throwaway project.json and settings file pointing at the demo data; returns the settings file.
    static func prepareSettings() -> URL {
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-demo-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Empty stand-ins for the four scripts and a role file, so the panel sees a complete setup.
        let scriptsDir = work.appendingPathComponent("scripts")
        try? FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        for name in ScriptName.allCases { try? "#!/bin/bash\nexit 0\n".write(to: scriptsDir.appendingPathComponent(name.rawValue), atomically: true, encoding: .utf8) }
        let roleURL = work.appendingPathComponent("dev.json")
        try? "{\"name\":\"dev\",\"kind\":\"interactive\",\"model\":\"sonnet\",\"effort\":\"medium\",\"permissionMode\":\"auto\",\"outputStyle\":\"concise\",\"allowedTools\":[],\"skills\":[],\"instructionFile\":\"dev.md\"}".write(to: roleURL, atomically: true, encoding: .utf8)
        let project = """
        {"id":"demo","name":"Demo App","repoPath":"\(work.path)/repo","dataDir":"\(demoDir.appendingPathComponent("data").path)",
         "maxParallel":4,"buildCommand":"xcodebuild build","xcodeProject":"Demo.xcodeproj",
         "simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode","roles":{"dev":"\(roleURL.path)"}}
        """
        let projectURL = work.appendingPathComponent("project.json")
        let settingsURL = work.appendingPathComponent("settings.json")
        try? project.write(to: projectURL, atomically: true, encoding: .utf8)
        try? "{\"projects\":[\"\(projectURL.path)\"],\"scriptsDir\":\"\(scriptsDir.path)\"}".write(to: settingsURL, atomically: true, encoding: .utf8)
        return settingsURL
    }

    /// The demo model before its first load (used by the app at start-up).
    static func makeUnloadedModel() -> PanelModel {
        PanelModel(settingsURL: prepareSettings(), makeTerminal: { DemoTerminal() }, opener: WorkspaceURLOpener(),
                   makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                   log: ActionLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-panel-demo-actions.log")),
                   writer: DemoCardWriter(), defaults: UserDefaults(suiteName: "agent-panel-demo") ?? .standard,
                   roleStore: RoleStore())
    }

    static func makeModel() async -> PanelModel {
        let model = makeUnloadedModel()
        await model.reload()
        model.selectedCardID = "A1"
        return model
    }
}
