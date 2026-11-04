import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

/// Switching rail screens (N124): the whole window in a real NSWindow with a big project, timed from the ⌘-digit to the laid-out screen.
/// Set AGENT_PANEL_PERF_REPORT=1 to print the numbers per screen.
@MainActor
final class ScreenSwitchPerformanceTests: XCTestCase {
    private var dir: TempDir!
    private var window: NSWindow!
    private var model: PanelModel!

    /// Real-size project (N128; Debug test host, a 1440×860 window, ~18 ms of it is the measuring itself - Team, an almost empty screen, takes that).
    /// Before N128: Dashboard ~3,300 ms, Tasks ~850, Stats ~1,600, Plan ~90, Timeline ~100. Now Tasks, Plan and Stats are under 50; the Dashboard
    /// (three columns, a 300-message chat, agent cards) and the Timeline are under 100. A loaded machine needs some room, so the limits are
    /// ~1.5× what is measured.
    static let limit: TimeInterval = 0.1
    static let tightLimit: TimeInterval = 0.075
    static let tight: Set<ShellScreen> = [.tasks, .plan, .stats]

    override func setUp() async throws {
        dir = try TempDir()
        model = try await Self.makeBigModel(dir, owner: self)
        let hosting = NSHostingView(rootView: ShellView(model: model).environment(\.colorScheme, .dark))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.settle(window)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        model = nil
    }

    /// The Tentacl project's size (N128): 130 cards with branches, a 300-message PM chat with Markdown, 8 agents in card worktrees, a plan with 10
    /// rounds, ~2,000 action-log lines, a 3,000-record decision log with the PM's standing authority on, 150 usage files and ~40 MB of session files.
    static func makeBigModel(_ dir: TempDir, owner: XCTestCase) async throws -> PanelModel {
        let work = dir.url
        let data = work.appendingPathComponent("data")
        let repo = work.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let scripts = work.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ScriptName.allCases { try "#!/bin/bash\nexit 0\n".write(to: scripts.appendingPathComponent(name.rawValue), atomically: true, encoding: .utf8) }
        let role = work.appendingPathComponent("dev.json")
        try #"{"name":"dev","kind":"interactive","model":"sonnet","effort":"medium","permissionMode":"auto","outputStyle":"concise","allowedTools":[],"skills":[],"instructionFile":"dev.md"}"#.write(to: role, atomically: true, encoding: .utf8)
        let project = """
        {"id":"big","name":"Big App","repoPath":"\(repo.path)","dataDir":"\(data.path)","maxParallel":4,"buildCommand":"xcodebuild build",
         "xcodeProject":"Big.xcodeproj","simulator":{"baseDevice":"iPhone 17 Pro"},"sharedFiles":[],"openWith":"Xcode","roles":{"dev":"\(role.path)"}}
        """
        try project.write(to: work.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try #"{"projects":["\#(work.path)/project.json"],"scriptsDir":"\#(scripts.path)"}"#.write(to: work.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        // Cards
        let statuses = ["done", "done", "done", "todo", "doing", "review", "needs-fix", "blocked", "cancelled", "awaiting-start-approval"]
        for i in 1...130 {
            let id = "T\(i)"
            let status = statuses[i % statuses.count]
            let card = """
            ---
            id: \(id)
            project: big
            status: \(status)
            agent: \(status == "doing" || status == "review" ? "dev-\(i % 8)" : "")
            branch: feat/t\(i)
            files:
              - App/File\(i).swift
            ---
            # \(id) · Task number \(i) with a reasonably long title

            ## Goal
            Do the thing \(i) and keep the screen fast.

            ## Report
            Done. Changed `File\(i).swift`; tests pass.

            ## Review packet

            ## Decision
            """
            try dir.write("data/tasks/\(id).md", card)
        }

        // Plan: 10 rounds of 12 cards
        let rounds = (0..<10).map { r in
            let cards = (1...12).map { "\"T\(r * 12 + $0)\"" }.joined(separator: ",")
            return #"{"name":"R\#(r + 1)","cards":[\#(cards)],"reason":"Round \#(r + 1) reason","status":"\#(r == 9 ? "waiting" : "")"}"#
        }.joined(separator: ",")
        try dir.write("data/plan.json", #"{"rounds":[\#(rounds)],"questions":["Which one first?"]}"#)

        // Action log: ~2,000 lines
        let iso = ISO8601DateFormatter()
        let log = ActionLog(fileURL: work.appendingPathComponent("actions.log"))
        var lines = ""
        for i in 0..<2000 {
            let when = iso.string(from: Date().addingTimeInterval(Double(i - 2000) * 60))
            lines += "\(when) [big] start T\(i % 120 + 1) agent=dev-\(i % 4) worktree=/x\n"
        }
        try lines.write(to: log.fileURL, atomically: true, encoding: .utf8)

        // PM chat: 300 messages with Markdown
        let session = "pm-session"
        let projects = work.appendingPathComponent("claude-projects")
        let transcript = TranscriptReader.path(projectsRoot: projects, cwd: repo.path, session: session)
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        var jsonl = ""
        for i in 0..<150 {
            jsonl += #"{"type":"user","uuid":"u\#(i)","message":{"role":"user","content":"Question \#(i): what about **T\#(i % 120 + 1)**?"}}"# + "\n"
            let md = "## Answer \(i)\\n\\n- first `item` with **bold**\\n- second item with a [link](https://example.com)\\n\\n```swift\\nlet x = \(i)\\n```\\n\\nSome longer paragraph text that wraps over more than one line in the thread so layout has real work to do."
            jsonl += #"{"type":"assistant","uuid":"a\#(i)","message":{"role":"assistant","content":[{"type":"text","text":"\#(md)"}]}}"# + "\n"
        }
        try jsonl.write(to: transcript, atomically: true, encoding: .utf8)

        let agents = [AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .idle, cwd: repo.path, title: "PM", sessionID: session)]
            + (0..<8).map { AgentStatus(paneID: "w\($0 + 2):p1", workspaceID: "w\($0 + 2)", state: .working,
                                        cwd: repo.appendingPathComponent(".agent-worktrees/feat-t\($0 * 10 + 4)").path, title: "dev-\($0) · T\($0 * 10 + 4)") }
        // Decision log and policy: the PM's standing authority is on, so the Dashboard counts today's starts from the log.
        let autopilot = work.appendingPathComponent("autopilot")
        try FileManager.default.createDirectory(at: autopilot, withIntermediateDirectories: true)
        try #"{"mode":"on","pmAuthority":true,"pmStartsPerDay":20}"#.write(to: autopilot.appendingPathComponent("big.json"), atomically: true, encoding: .utf8)
        var decisions = ""
        for i in 0..<3000 {
            let when = iso.string(from: Date().addingTimeInterval(Double(i - 3000) * 20))
            let start = i % 7 == 0
            decisions += #"{"id":"d\#(i)","time":"\#(when)","cardID":"T\#(i % 130 + 1)","agent":"dev-\#(i % 8)","kind":"\#(start ? "start" : "choice")","question":"\#(start ? "PM authority: start it" : "Which option for the thing number \(i) in the file?")","by":"pm","result":"answered","answer":"\#(start ? "T\(i % 130 + 1)" : "Option one")","why":"The card's Goal says so, and the Scope covers it; nothing else is touched.","costUSD":0.04}"# + "\n"
        }
        try decisions.write(to: autopilot.appendingPathComponent("big.decisions.jsonl"), atomically: true, encoding: .utf8)

        // Plan usage: one file per session, like scripts/usage-statusline.sh leaves them.
        let usage = work.appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
        let nowSeconds = Date().timeIntervalSince1970
        for i in 0..<150 {
            try #"{"session_id":"s\#(i)","seen_at":\#(nowSeconds - Double(i) * 600),"cost":{"total_cost_usd":0.5},"rate_limits":{"five_hour":{"used_percentage":23.0,"resets_at":\#(nowSeconds + 3600)},"seven_day":{"used_percentage":41.0,"resets_at":\#(nowSeconds + 86400)}}}"#
                .write(to: usage.appendingPathComponent("s\(i).json"), atomically: true, encoding: .utf8)
        }

        // Session files of the finished cards (Stats prices them): ~1 MB each, ~40 MB together.
        let line = #"{"type":"assistant","uuid":"u%d","message":{"id":"m%d","model":"claude-sonnet-5-5","usage":{"input_tokens":1200,"output_tokens":400,"cache_creation_input_tokens":3000,"cache_read_input_tokens":90000},"content":[{"type":"text","text":"working on it, a reasonably long line of assistant text so the file has a real size to read and decode"}]}}"# + "\n"
        let chunk = (0..<4000).map { String(format: line, $0, $0) }.joined()
        for i in 1...130 where statuses[i % statuses.count] == "done" {
            let worktree = repo.appendingPathComponent(".agent-worktrees/feat-t\(i)").path
            let file = TranscriptReader.path(projectsRoot: projects, cwd: worktree, session: "s\(i)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try chunk.write(to: file, atomically: true, encoding: .utf8)
        }

        let iso2 = TestIsolation(dir, owner: owner)
        let model = PanelModel(settingsURL: work.appendingPathComponent("settings.json"), makeTerminal: { FixedTerminal(agents: agents) }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() }, log: log, writer: DemoCardWriter(),
                               defaults: iso2.defaults, roleStore: iso2.roleStore, autopilotStore: AutopilotStore(folder: autopilot))
        model.claudeProjectsRoot = projects
        model.usageSource = { UsageReader.read(root: usage) }
        await model.reload()
        model.selectedCardID = "T5"
        return model
    }

    private struct FixedTerminal: TerminalListing {
        let agents: [AgentStatus]
        func agents() async throws -> [AgentStatus] { agents }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
    }

    /// Lets queued SwiftUI updates run and the window lay out and draw.
    static func settle(_ window: NSWindow, passes: Int = 4) {
        for _ in 0..<passes {
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.0005))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func press(_ digit: Int) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "\(digit)", charactersIgnoringModifiers: "\(digit)",
                                     isARepeat: false, keyCode: 0)!
        _ = window.contentView?.performKeyEquivalent(with: event)
    }

    /// Proof that the test can fail: seconds of extra work added to every switch, read from `perf-inject-ms` in the temp folder (milliseconds; absent = none).
    static var injectedDelay: TimeInterval {
        (Double((try? String(contentsOfFile: NSTemporaryDirectory() + "perf-inject-ms", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0) / 1000
    }

    private func timeSwitch(to screen: ShellScreen) -> TimeInterval {
        let start = CACurrentMediaTime()
        press(screen.shortcutDigit)
        Self.settle(window)
        if Self.injectedDelay > 0 { RunLoop.current.run(until: Date().addingTimeInterval(Self.injectedDelay)) }
        let elapsed = CACurrentMediaTime() - start
        let picture = snapshot()
        XCTAssertNotEqual(picture, lastPicture, "pressing ⌘\(screen.shortcutDigit) did not change the window (\(screen.railTitle))")
        lastPicture = picture
        return elapsed
    }

    private var lastPicture: Data?
    private func snapshot() -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// A polling tick that finds nothing new changes nothing the views watch (N128): no redraw, no caches thrown away.
    func testPollingTickWithNothingNewPublishesNothing() async {
        await model.reloadCards()
        await model.refreshAgents()
        try? await Task.sleep(for: .milliseconds(300))   // the first usage read finishes off the main thread
        var changed = false
        withObservationTracking { _ = model.cards; _ = model.agents; _ = model.planUsage } onChange: { changed = true }
        await model.reloadCards()
        await model.refreshAgents()
        try? await Task.sleep(for: .milliseconds(300))   // the usage read finishes off the main thread
        XCTAssertFalse(changed, "a tick with the same cards, agents and usage published a change")
    }

    /// A fixed amount of main-thread CPU work (no UI), timed. Under load (parallel test clones, other agents' builds) it takes longer by the
    /// same factor the screen switches do, so it tells the load apart from a real slowdown of a screen.
    static func calibrationSample() -> TimeInterval {
        let start = CACurrentMediaTime()
        var hasher = Hasher()
        for i in 0..<2_000_000 { hasher.combine(i &* 31) }
        _ = hasher.finalize()
        return CACurrentMediaTime() - start
    }

    /// Same work on an idle machine (Debug test host, measured with `AGENT_PANEL_PERF_REPORT=1`).
    static let idleCalibration: TimeInterval = 0.130

    /// Dashboard → every screen → back. One warm-up round (first render, caches) is not counted; then a few rounds, the median per screen.
    /// The limits are for an idle machine and grow by the load measured in the same run (the calibration work between the switches), never below 1×.
    func testEveryScreenSwitchIsFast() {
        Self.settle(window, passes: 8)
        // On Terminals ⌘1…⌘9 pick a terminal tab, not a screen (N224): it is left out of the keyboard round.
        let order = ShellScreen.railOrder.dropFirst().filter { ShellScreen.railShortcutsActive(on: $0) } + [.dashboard]
        for screen in order { _ = timeSwitch(to: screen) }   // warm-up
        var samples: [ShellScreen: [TimeInterval]] = [:]
        var calibration: [TimeInterval] = []
        for _ in 0..<(Int((try? String(contentsOfFile: NSTemporaryDirectory() + "perf-loops", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 5) {
            for screen in order {
                calibration.append(Self.calibrationSample())
                samples[screen, default: []].append(timeSwitch(to: screen))
            }
        }
        let load = max(1, calibration.sorted()[calibration.count / 2] / Self.idleCalibration)
        var report = String(format: "load factor %.2f (calibration median %.1f ms, idle %.1f ms)\n", load, calibration.sorted()[calibration.count / 2] * 1000, Self.idleCalibration * 1000)
        for screen in ShellScreen.railOrder where samples[screen] != nil {
            let sorted = (samples[screen] ?? []).sorted()
            let median = sorted[sorted.count / 2]
            let limit = (Self.tight.contains(screen) ? Self.tightLimit : Self.limit) * load
            report += String(format: "%@ first %.0f ms, median %.0f ms, max %.0f ms, limit %.0f ms\n", screen.railTitle, (samples[screen]?.first ?? 0) * 1000, median * 1000, (sorted.last ?? 0) * 1000, limit * 1000)
            XCTAssertLessThan(median, limit, "\(screen.railTitle) took too long to switch to (load factor \(String(format: "%.2f", load)))")
        }
        if ProcessInfo.processInfo.environment["AGENT_PANEL_PERF_REPORT"] != nil { print("SCREEN-SWITCH\n" + report) }
        try? report.write(toFile: NSTemporaryDirectory() + "screen-switch-report.txt", atomically: true, encoding: .utf8)
    }
}
