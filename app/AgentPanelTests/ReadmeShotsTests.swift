import AppKit
import SwiftUI
import XCTest
@testable import AgentPanel

/// The README and guide screenshots (N383), taken from a live on-screen window that hosts the real views with the demo data, in light
/// (`<name>.png`) and dark (`<name>-dark.png`). Runs only when `AGENT_PANEL_README_SHOTS` names a folder (docs/screenshots/generate.sh
/// sets it); otherwise every test here is skipped. Needs an unlocked screen: a window on a locked screen draws no materials.
@MainActor
final class ReadmeShotsTests: XCTestCase {
    private static var out: URL? { ProcessInfo.processInfo.environment["AGENT_PANEL_README_SHOTS"].map { URL(fileURLWithPath: $0) } }
    private static let size = CGSize(width: 1600, height: 1000)

    /// The Dashboard reads its layout from the test host's own defaults: the shots set one and put the old value back.
    private var savedLayout: Data?

    override func setUp() async throws {
        guard Self.out != nil else { throw XCTSkip("AGENT_PANEL_README_SHOTS is not set") }
        savedLayout = UserDefaults.standard.data(forKey: DashboardLayoutStore.key)
    }

    override func tearDown() async throws {
        if Self.out == nil { return }
        if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: DashboardLayoutStore.key) } else { UserDefaults.standard.removeObject(forKey: DashboardLayoutStore.key) }
    }

    // MARK: screens

    func testTheScreens() async throws {
        let dir = try TempDir()
        let model = try await Self.makeModel(dir, owner: self)
        model.selectedCardID = "A4"
        let none = Self.closedCard(model)
        try await Self.both("dashboard") { ShellView(model: model, screen: .dashboard, blockedCard: none) }
        try await Self.both("questions", size: CGSize(width: 760, height: 470)) { WaitingAlone(model: model) }
        try await Self.both("tasks") { ShellView(model: model, screen: .tasks, blockedCard: none) }
        try await Self.both("team") { ShellView(model: model, screen: .team, blockedCard: none) }
        try await Self.both("team-chart") { TeamView(model: model.team, initialSection: .chart) }
        try await Self.both("stats") { ShellView(model: model, screen: .stats, blockedCard: none) }
        try await Self.both("settings") { ShellView(model: model, screen: .settings, blockedCard: none) }
    }

    /// The floating question card under the "waiting" pill, with the question glow held at full strength (N375/N376/N380).
    func testTheQuestionCard() async throws {
        let dir = try TempDir()
        let model = try await Self.makeModel(dir, owner: self)
        XCTAssertEqual(model.inbox.questions.count, 1)
        XCTAssertEqual(model.inbox.withPM.count, 1)
        let opened = BlockedBannerModel()
        opened.togglePill(shown: false, open: model.autopilot.forUser(model.inbox.questions).map(\.id))
        try await Self.both("question-card") {
            ShellView(model: model, screen: .tasks, blockedCard: opened).environment(\.questionGlowFixedStrength, 1)
        }
    }

    // MARK: sheets (shown over the window they belong to, as on screen)

    func testTheSheets() async throws {
        let dir = try TempDir()
        let model = try await Self.makeModel(dir, owner: self)
        let none = Self.closedCard(model)
        let b1 = try XCTUnwrap(model.cards.compactMap { r -> TaskCard? in if case .card(let c) = r, c.id == "B1" { return c } else { return nil } }.first)
        model.selectedCardID = "B1"
        let started = model.startPlan(for: b1)
        guard case .success(let raw) = started else { return XCTFail("the demo should be able to plan B1: \(started)") }
        var plan = StartPlan(card: raw.card, agentName: raw.agentName, branch: raw.branch, rolePath: Self.tidy(raw.rolePath), worktreePath: Self.tidy(raw.worktreePath),
                             commandPreview: Self.tidy(raw.commandPreview))
        plan.roleName = raw.roleName; plan.roleDisplayName = raw.roleDisplayName; plan.authority = raw.authority; plan.needsTrust = raw.needsTrust
        let project = try XCTUnwrap(model.selectedProject)
        let shell = { ShellView(model: model, screen: .tasks, blockedCard: none) }
        try await Self.both("start-sheet") {
            Self.sheet(over: shell(), StartTaskSheet(plan: plan, project: project, state: .idle, onConfirm: {}, onCancel: {}), width: 560)
        }
        let a4 = try XCTUnwrap(model.cards.compactMap { r -> TaskCard? in if case .card(let c) = r, c.id == "A4" { return c } else { return nil } }.first)
        let approval = ApprovalPlan(card: a4, agentName: "dev-a4", branch: "docs/a4-open-items", worktreePath: "/Users/you/Projects/demo/.agent-worktrees/docs-a4-open-items",
                                    base: "main", head: "3f2c9a1d0b7e4c6a8f1e2d3c4b5a69788776655a", ahead: 2, filesChanged: 3, screenshotCount: 2, isAnalysis: false,
                                    commandPreview: "merge-task.sh --ff-only docs/a4-open-items")
        model.selectedCardID = "A4"  // the sheet sits over the card it approves
        try await Self.both("approve-sheet") {
            Self.sheet(over: ShellView(model: model, screen: .tasks, blockedCard: none), ApproveSheet(plan: approval, state: .idle, onConfirm: {}, onCancel: {}), width: 560)
        }
        let picks = [("A2", "Compare first: the checklist work depends on what changed in the prototype."),
                     ("A3", "Small and separate from A2's files, so both can run at once.")]
        let round = RoundModel(enabled: { true }, cards: { model.selectedTaskCards }, maxParallel: { 6 }, projectName: { "Demo App" },
                               propose: { _ in RoundReply(proposal: RoundProposal(cards: picks.map { RoundPick(id: $0.0, why: $0.1) }), costUSD: 0.03) },
                               planStart: { model.startPlan(for: $0) }, conflict: { _, _ in nil }, start: { _ in nil }, record: { _ in }, projectID: { "demo" })
        await round.plan()
        try await Self.both("round") { Self.sheet(over: shell(), RoundSheet(model: round, onClose: {}), width: 600) }
        try await Self.both("autopilot") {
            Self.sheet(over: ShellView(model: model, screen: .dashboard, blockedCard: none),
                       AutopilotRulesSheet(policy: model.autopilot.policy, onSave: { _ in }, onCancel: {}), width: 720, top: 24)
        }
        let setup = SetupModel(probes: Self.probes, inputs: { SetupInputs(scriptsDir: URL(fileURLWithPath: "/Users/you/Projects/tentacl-crew/scripts"), scriptsProblem: nil,
                                                                          projects: model.projects, usesClaude: true, usesCodex: true) },
                               settingsURL: dir.url.appendingPathComponent("setup.json"), picker: NoPicker(), roleBaseDir: dir.url.appendingPathComponent("roles"),
                               defaults: TestDefaults.make(self), codexRules: CodexRules(home: dir.url.appendingPathComponent("home")), onSettingsChanged: {})
        await setup.check()
        try await Self.both("setup") {
            Self.sheet(over: ShellView(model: model, screen: .dashboard, blockedCard: none), SetupView(model: setup, onClose: {}, onAddProject: {}), width: 640, height: 800, top: 40)
        }
        struct Scripts: ScriptRunning { func run(_ script: ScriptName, arguments: [String]) async throws -> ScriptResult { ScriptResult(status: 0, stdout: "", stderr: "") } }
        let add = AddProjectFlow(scripts: Scripts(), registry: ProjectRegistry(settingsURL: dir.url.appendingPathComponent("p.json"), scripts: Scripts()),
                                 probe: { _ in ProjectProbe(facts: RepoFacts()) }, listSimulators: { ["iPhone 17 Pro"] }, existingIDs: { [] },
                                 fileExists: { !$0.hasSuffix("/pet-diary") }, repoParent: "/Users/you/Projects", dataRoot: "/Users/you/Documents/notes")
        add.name = "Pet Diary"
        try await Self.both("add-project") {
            Self.sheet(over: ShellView(model: model, screen: .dashboard, blockedCard: none), AddProjectSheet(flow: add, onAdded: { _ in }, onCancel: {}), width: 600)
        }
    }

    // MARK: helpers

    /// Demo settings written for the shots: the demo cards, the example roles and a team chart, with paths that read like a user's own
    /// (`/Users/you/…`) instead of the temporary folder; `tidy` turns the temporary folder back into that path where a view shows it.
    private static func demoSettings(_ dir: TempDir) throws -> (settings: URL, roles: URL) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let work = dir.url.appendingPathComponent("tentacl")
        let roles = work.appendingPathComponent("roles"), scripts = work.appendingPathComponent("scripts"), data = work.appendingPathComponent("demo")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.copyItem(at: root.appendingPathComponent("examples/roles"), to: roles)
        for name in ScriptName.allCases { try "#!/bin/bash\nexit 0\n".write(to: scripts.appendingPathComponent(name.rawValue), atomically: true, encoding: .utf8) }
        let demoData = DemoSupport.demoDir.appendingPathComponent("data")
        for item in try fm.contentsOfDirectory(atPath: demoData.path) {
            try fm.copyItem(at: demoData.appendingPathComponent(item), to: data.appendingPathComponent(item))
        }
        try? fm.removeItem(at: data.appendingPathComponent("tasks/BROKEN.md"))
        // B3's agent asks the user a question, which only a running card does.
        let b3 = data.appendingPathComponent("tasks/B3.md")
        try String(contentsOf: b3, encoding: .utf8).replacingOccurrences(of: "status: blocked", with: "status: doing").write(to: b3, atomically: true, encoding: .utf8)
        for (i, c) in finished.enumerated() {
            let card = "---\nid: \(c.id)\nproject: demo\nstatus: done\nagent: dev-\(i % 3 + 1)\nbranch: \(c.branch)\nfiles:\n  - App/Example.swift\n---\n# \(c.id) · \(c.title)\n\n## Goal\n\(c.title).\n\n## Report\nDone; build and tests pass.\n"
            try card.write(to: data.appendingPathComponent("tasks/\(c.id).md"), atomically: true, encoding: .utf8)
        }
        try "Ship Demo App 1.0: accessible, with the home widget and clean strings.\n".write(to: data.appendingPathComponent("goal.md"), atomically: true, encoding: .utf8)
        let plan = #"{"rounds":[{"name":"Round 1","cards":["C1","C2","C3","C4","C5","C6"],"reason":"Groundwork: onboarding, settings and the widget data.","status":"done"},"#
            + #"{"name":"Round 2","cards":["A1","A4","A5","B3"],"reason":"Clean-up and the accessibility audit before 1.0.","status":"running"}]}"#
        try plan.write(to: data.appendingPathComponent("plan.json"), atomically: true, encoding: .utf8)
        let project = """
        {"id":"demo","name":"Demo App","repoPath":"\(repoPath)","dataDir":"\(data.path)","maxParallel":6,"buildCommand":"xcodebuild build",
         "xcodeProject":"Demo.xcodeproj","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode"}
        """
        try project.write(to: data.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        let team = #"{"version":1,"members":[{"role":"pm","reportsTo":null},{"role":"reviewer","reportsTo":"pm"},{"role":"dev","reportsTo":"reviewer"}]}"#
        try team.write(to: data.appendingPathComponent("team.json"), atomically: true, encoding: .utf8)
        let settings = work.appendingPathComponent("projects.json")
        try #"{"projects":["\#(data.appendingPathComponent("project.json").path)"],"scriptsDir":"\#(scripts.path)"}"#.write(to: settings, atomically: true, encoding: .utf8)
        tidyPrefix = work.path
        return (settings, roles)
    }

    private static let repoPath = "/Users/you/Projects/demo"
    /// Finished cards of the shots' demo copy, so Stats, the Round tile and the history have data.
    private static let finished: [(id: String, title: String, branch: String)] = [
        ("C1", "Onboarding screens", "feat/c1-onboarding"), ("C2", "Settings layout", "feat/c2-settings"),
        ("C3", "Widget data model", "feat/c3-widget-data"), ("C4", "Empty states", "feat/c4-empty-states"),
        ("C5", "Dark mode colours", "feat/c5-dark-mode"), ("C6", "Crash on rotate", "fix/c6-rotate"),
        ("C7", "Search speed", "feat/c7-search"), ("C8", "Share sheet", "feat/c8-share"),
        ("C9", "VoiceOver labels", "feat/c9-voiceover"), ("C10", "Release checklist", "docs/c10-release")]

    /// The action log, session files and PM decisions behind the finished cards: start, review packet (one fix round on some), approval.
    private static func writeHistory(log: URL, projects: URL, decisions: URL) throws {
        let iso = ISO8601DateFormatter(), cal = Calendar.current, today = cal.startOfDay(for: Date())
        let daysAgo = [13, 12, 11, 9, 8, 6, 5, 3, 2, 1, 1]
        var lines = "", records = ""
        for (i, c) in (finished + [("K1", "", "feat/k1-collage")]).enumerated() {
            let start = cal.date(byAdding: .day, value: -daysAgo[i], to: today)!.addingTimeInterval(Double(9 * 3600 + i * 1500))
            var t = start.addingTimeInterval(Double(35 + (i * 17) % 80) * 60)
            lines += "\(iso.string(from: start)) [demo] start \(c.id) agent=dev-\(i % 3 + 1) branch=\(c.branch) pane=w\(i + 10):p1\n"
            lines += "\(iso.string(from: t)) [demo] review packet prepared for \(c.id)\n"
            if i % 4 == 1 {
                t = t.addingTimeInterval(12 * 60)
                lines += "\(iso.string(from: t)) [demo] fix request sent to w\(i + 10):p1 for \(c.id)\n"
                t = t.addingTimeInterval(28 * 60)
                lines += "\(iso.string(from: t)) [demo] review packet prepared for \(c.id)\n"
            }
            t = t.addingTimeInterval(Double(10 + (i * 7) % 40) * 60)
            lines += "\(iso.string(from: t)) [demo] approved \(c.id)\n"
            let worktree = repoPath + "/.agent-worktrees/" + StartTaskFlow.worktreeFolder(for: c.branch)
            let file = TranscriptReader.path(projectsRoot: projects, cwd: worktree, session: "s-\(c.id)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let turns = 40 + (i * 37) % 120
            let line = #"{"type":"assistant","uuid":"u%d","message":{"id":"m%d","model":"claude-sonnet-5-5","usage":{"input_tokens":1500,"output_tokens":600,"cache_creation_input_tokens":4000,"cache_read_input_tokens":60000},"content":[{"type":"text","text":"ok"}]}}"#
            try (0..<turns).map { String(format: line, $0, $0) + "\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
            records += #"{"id":"d\#(i)","time":"\#(iso.string(from: start.addingTimeInterval(1200)))","cardID":"\#(c.id)","agent":"dev-\#(i % 3 + 1)","kind":"choice","question":"Which option?","by":"pm","result":"answered","answer":"1","why":"The card's Goal says so.","costUSD":0.0\#(3 + i % 5)}"# + "\n"
        }
        // Round 2 runs today: its four cards started this morning, A1 and A4 have a passed review packet.
        for (i, c) in [("A1", "feat/a1-cleanup"), ("A4", "docs/a4-open-items"), ("A5", "fix/a5-widget"), ("B3", "feat/b3-a11y")].enumerated() {
            let start = today.addingTimeInterval(Double(8 * 3600 + i * 900))
            lines += "\(iso.string(from: start)) [demo] start \(c.0) agent=dev-\(i + 1) branch=\(c.1) pane=w\(i + 30):p1\n"
            if i < 2 { lines += "\(iso.string(from: start.addingTimeInterval(Double(50 + i * 20) * 60))) [demo] review packet prepared for \(c.0)\n" }
        }
        try lines.write(to: log, atomically: true, encoding: .utf8)
        try records.write(to: decisions, atomically: true, encoding: .utf8)
    }

    /// The PM's conversation: the user asks for the next round, the PM answers with the plan and the question it is holding.
    private static func writePMChat(projects: URL, session: String) throws {
        let file = TranscriptReader.path(projectsRoot: projects, cwd: repoPath, session: session)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let turns: [(String, String)] = [
            ("user", "Where are we with round 2?"),
            ("assistant", "Round 2 is half done. **A1** and **A4** passed review and wait for your approval. **A5** (the widget findings) is working, and I am answering its question about the accent colour from the design notes. **B3** asks you about the release notes; that one is yours."),
            ("user", "Plan the next round, please."),
            ("assistant", "Next I would take **A2** (compare the prototype changes) and **A3** (check the checklist status): they touch different files, so both can run at once. **B1** waits for your start approval first. Shall I start A2 and A3 when A1 and A4 are merged?")]
        var jsonl = ""
        for (i, t) in turns.enumerated() {
            let text = t.1.replacingOccurrences(of: "\"", with: "\\\"")
            jsonl += t.0 == "user"
                ? #"{"type":"user","uuid":"u\#(i)","message":{"role":"user","content":"\#(text)"}}"# + "\n"
                : #"{"type":"assistant","uuid":"a\#(i)","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
        }
        try jsonl.write(to: file, atomically: true, encoding: .utf8)
    }
    private static var tidyPrefix = ""
    /// A path under the shots' temporary folder as it reads on a user's Mac.
    private static func tidy(_ s: String) -> String { tidyPrefix.isEmpty ? s : s.replacingOccurrences(of: tidyPrefix, with: "/Users/you/.config/tentacl") }

    /// The question the user gets: marked critical, so the PM leaves it to the user.
    private static let criticalScreen = """
    ──────────────────────────────────────────────────────────────────────────────────────────
     ☐ Release notes

     The release notes still name the old install path. Fix them before tagging, or tag now and fix them in a patch?

     critical: yes
     user: The release notes still name the old install path. Fix them before tagging?

     ❯ 1. Fix them first (Recommended)
         The tag waits for the fix
       2. Tag now
         The notes follow in a patch
       3. Type something.

       4. Chat about this

     Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    /// The demo project with agents at work on its cards: one question for you (critical), one the PM is answering, two reviews.
    private static func makeModel(_ dir: TempDir, owner: XCTestCase) async throws -> PanelModel {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/agent-screens")
        let held = try String(contentsOf: fixtures.appendingPathComponent("choice-before.txt"), encoding: .utf8)
        let (settings, roles) = try demoSettings(dir)
        let wt = repoPath + "/.agent-worktrees/"
        var b3 = AgentStatus(paneID: "w3:p1", workspaceID: "w3", state: .blocked, cwd: wt + "feat-b3-a11y", title: "dev-1 · B3", sessionID: "s3"); b3.changeSeq = 1; b3.name = "dev-1"
        var a5 = AgentStatus(paneID: "w5:p1", workspaceID: "w5", state: .blocked, cwd: wt + "fix-a5-widget", title: "dev-4 · A5", sessionID: "s5"); a5.changeSeq = 1; a5.name = "dev-4"
        var a4 = AgentStatus(paneID: "w4:p1", workspaceID: "w4", state: .done, cwd: wt + "docs-a4-open-items", title: "dev-2 · A4"); a4.name = "dev-2"
        var a1 = AgentStatus(paneID: "w6:p1", workspaceID: "w6", state: .done, cwd: wt + "feat-a1-cleanup", title: "dev-3 · A1"); a1.name = "dev-3"
        let pm = AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: repoPath, title: "PM", sessionID: "pm-session")
        let agents = [pm, b3, a5, a4, a1]
        let iso = TestIsolation(dir, owner: owner)
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var policy = AutopilotPolicy(); policy.mode = .shadow
        try store.save(policy, for: "demo")
        // Session files live in the shots' own folders: never the ~/.claude or ~/.codex of the Mac the shots run on.
        let projects = dir.url.appendingPathComponent("claude-projects"), codex = dir.url.appendingPathComponent("codex-sessions")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try writeHistory(log: iso.log.fileURL, projects: projects, decisions: try XCTUnwrap(store.decisionsURL("demo")))
        try writePMChat(projects: projects, session: pm.sessionID ?? "")
        let screens = ["w3:p1": criticalScreen, "w5:p1": held]
        let model = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success(agents)) }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() },
                               log: iso.log, writer: DemoCardWriter(), defaults: iso.defaults, roleStore: RoleStore(baseDir: roles),
                               makeReader: { ShotReader(screens) }, makeKeySender: { ShotKeys() }, setupProbes: probes, autopilotStore: store, makeDecider: { _ in ShotDecider() })
        // The Dashboard filled edge to edge: the PM chat, Waiting for you, the agents and the round.
        func t(_ w: DashboardWidget, _ c: Int, _ r: Int, _ width: Int, _ height: Int) -> DashboardTile {
            DashboardTile(widget: w, rect: DashboardCellRect(column: c, row: r, width: width, height: height))
        }
        DashboardLayoutStore().save(DashboardGridLayout([t(.chat, 0, 0, 3, 4), t(.waiting, 3, 0, 3, 2), t(.agents, 3, 2, 3, 1), t(.round, 3, 3, 3, 1)]))
        model.claudeProjectsRoot = projects
        _ = model.chats.session(project: "demo", pane: pm.paneID, projectsRoot: projects)  // the PM chat reads the shots' transcript
        model.codexSessionsRoot = codex
        // Demo plan usage, never the Claude plan of the Mac the shots run on.
        let now = Date()
        model.usageSource = { PlanUsage(fiveHour: .init(percent: 34, resetsAt: now.addingTimeInterval(2 * 3600 + 900)),
                                        week: .init(percent: 41, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600)), todayCost: 4.12) }
        await model.reload()
        await model.refreshAgents()
        model.inbox.routing = QuestionRouting(mode: .pmCritical, pmPane: pm.paneID)
        await model.inbox.refresh(agents: agents, cards: model.selectedTaskCards, projectWorktrees: URL(fileURLWithPath: wt),
                                  label: { $0.title })
        return model
    }

    /// The floating question card closed, so a screen shows only its own content.
    private static func closedCard(_ model: PanelModel) -> BlockedBannerModel {
        let closed = BlockedBannerModel()
        closed.close(open: model.autopilot.forUser(model.inbox.questions).map(\.id))
        return closed
    }

    /// A sheet as macOS shows it: the window dimmed behind it, the sheet near the top with its own background and shadow.
    private static func sheet(over window: some View, _ sheet: some View, width: CGFloat, height: CGFloat? = nil, top: CGFloat = 84) -> some View {
        ZStack(alignment: .top) {
            window
            Color.black.opacity(0.28)
            sheet
                .frame(width: width, height: height)
                .fixedSize(horizontal: false, vertical: height == nil)
                .background(Tok.bg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
                .padding(.top, top)
        }
    }

    private static func both(_ name: String, size: CGSize = size, _ root: () -> some View) async throws {
        for dark in [false, true] {
            let theme = AppTheme.current
            AppTheme.current = dark ? .dark : .light
            defer { AppTheme.current = theme }
            try await shot(root(), size: size, dark: dark, dark ? "\(name)-dark.png" : "\(name).png")
        }
    }

    private static func shot(_ root: some View, size: CGSize, dark: Bool, _ file: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(2500))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 20_000, file)
        if let out { try data.write(to: out.appendingPathComponent(file)) }
    }

    private static let probes = SetupProbes(
        findTool: { URL(fileURLWithPath: "/usr/local/bin/\($0)") }, claudeVersion: { _ in }, terminalServer: { .running },
        claudeSignedIn: { _ in true }, codexSignedIn: { _ in true }, roleExists: { _ in true }, isTrusted: { _ in true },
        github: { .signedIn(GitHubLogin(account: "you", host: "github.com", gitProtocol: "https", others: [])) })
}

private struct NoPicker: FolderPicking { func chooseFolder(message: String) -> String? { nil } }
private final class ShotReader: TerminalReading, @unchecked Sendable {
    let screens: [String: String]
    init(_ s: [String: String]) { screens = s }
    func screen(of target: String, lines: Int) async throws -> String { screens[target] ?? "" }
}
private struct ShotKeys: TerminalKeySending, TerminalCommanding {
    func sendKeys(target: String, keys: [String]) async throws {}
    func prompt(target: String, text: String) async throws {}
}
private struct ShotDecider: PMDeciding {
    func decide(_ request: DecisionRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
    func decide(_ request: FixRequest) async throws -> PMReply { throw PMDecisionError.failed("not used") }
}

/// The Dashboard's Waiting for you tile on its own, as the guide's questions shot.
private struct WaitingAlone: View {
    let model: PanelModel
    @FocusState private var row: String?
    var body: some View {
        WaitingTile(model: model, onOpen: { _ in }, focusedRow: $row)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Tok.bg)
    }
}
