import XCTest
import SwiftUI
import AppKit
@testable import AgentPanel

/// N370: agents' questions stand out in Waiting for you and on the agents' rows.
final class WaitingTileTests: XCTestCase {
    private func card(_ id: String, _ status: TaskStatus) -> TaskCard {
        TaskCard(id: id, project: "d", status: status, agent: nil, branch: nil, kind: nil, files: [], title: id, sections: [:], url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private func pending(_ kind: AgentQuestion.Kind, text: String = "Which colour?\nmore", isPM: Bool = false) -> PendingQuestion {
        PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "ui_dev · N370", cardID: isPM ? "" : "N370",
                        question: AgentQuestion(kind: kind, title: "", text: text, options: []), isPM: isPM)
    }

    func testEveryKindOfQuestionSortsAboveTheRestWhichKeepTodaysOrder() {
        let cards = [card("R1", .review), card("S1", .awaitingStartApproval)]
        let items = dashboardWaitingItems(questions: ["perm", "plan", "choice"], fixes: ["F1"], cards: cards, roundWaiting: [], approveRound: 0,
                                          git: [.initializeGit])
        XCTAssertEqual(items.map(\.kind), [.question("perm"), .question("plan"), .question("choice"), .review("R1"), .fix("F1"),
                                           .startApproval("S1"), .git(.initializeGit)])
    }

    func testAQuestionRowReadsKindRoleCardAndLiveMinutes() {
        let asked = Date(timeIntervalSince1970: 1_000)
        let q = pending(.choice)
        let text = WaitingQuestionRowText.make(q, role: "ui_dev", askedAt: asked, now: asked.addingTimeInterval(4 * 60 + 10))
        XCTAssertEqual(text.heading, "Question · ui_dev · N370 · 4 min")
        XCTAssertEqual(text.question, QuestionFocusContent.firstLine(ReadableQuestion(q).title))
        XCTAssertFalse(text.question.contains("\n"), "one line")
        let later = WaitingQuestionRowText.make(q, role: "ui_dev", askedAt: asked, now: asked.addingTimeInterval(12 * 60))
        XCTAssertEqual(later.heading, "Question · ui_dev · N370 · 12 min", "the minutes follow the clock")
    }

    func testPermissionPlanAndPMQuestionsNameThemselves() {
        XCTAssertEqual(WaitingQuestionRowText.make(pending(.permission), role: "dev", askedAt: nil, now: .now).heading, "Permission · dev · N370")
        XCTAssertEqual(WaitingQuestionRowText.make(pending(.plan), role: "dev", askedAt: nil, now: .now).heading, "Plan approval · dev · N370")
        XCTAssertEqual(WaitingQuestionRowText.make(pending(.choice, isPM: true), role: nil, askedAt: nil, now: .now).heading, "Question · PM")
        XCTAssertEqual(WaitingQuestionRowText.make(pending(.choice), role: nil, askedAt: nil, now: .now).heading, "Question · N370",
                       "an unknown role is left out")
    }

    func testReduceMotionHoldsTheFrameStill() {
        XCTAssertEqual(QuestionHighlight.style(reduceMotion: true), .still)
        XCTAssertEqual(QuestionHighlight.style(reduceMotion: false), .pulsing)
        XCTAssertEqual(QuestionHighlight.period, 1.8)
    }

    func testAnAskingAgentsChipSaysAskingYou() {
        XCTAssertEqual(AgentRow.chipLabel(.working, askingYou: true), "asking you")
        XCTAssertEqual(AgentRow.chipLabel(.working, askingYou: false), "Working")
        XCTAssertEqual(DashboardAgentRow.askingWord, "asking you")
    }

    // MARK: live-window shots

    /// Live-window shots → N370-waiting.png (one question, the reviews, git; dark | light) and N370-agents.png (the asking agent's row).
    @MainActor func testTheLiveQuestionShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self, settings: DemoSupport.prepareSettings())
        model.gitSetup.probe = { _ in var facts = RepoFacts(); facts.isGitRepo = false; return ProjectProbe(facts: facts) }
        await model.refreshGitState(force: true)
        let items = model.dashboardWaiting
        XCTAssertEqual(model.questionsForYou.count, 1)
        guard case .question(let id) = items.first?.kind else { return XCTFail("the question comes first: \(items.map(\.id))") }
        XCTAssertTrue(items.contains { if case .review = $0.kind { true } else { false } })
        XCTAssertTrue(items.contains { if case .git = $0.kind { true } else { false } })
        let q = try XCTUnwrap(model.questionsForYou.first { $0.id == id })
        XCTAssertEqual(model.questionRole(q), "dev")
        XCTAssertTrue(model.askingPanes.contains(q.paneID))

        let waiting = FocusHost(model: model).frame(width: 460, height: 420).padding(16)
        try write(await shot(waiting, size: NSSize(width: 492, height: 452)), "N370-waiting.png")
        // The agents' shot: the panel with no project picked lists every agent (the demo project's repo holds none of them).
        let dir2 = try TempDir()
        let all = try await DashboardSnapshotTests.makeModel(dir2, owner: self)
        let asking = try XCTUnwrap(all.questionsForYou.first)
        XCTAssertEqual(DashboardAgentRow.make(all).first { $0.id == asking.paneID }?.state, "asking you")
        let agents = VStack(spacing: 16) {
            AgentsTile(model: all, onOpen: { _ in }, onOpenTerminals: {}).frame(width: 460, height: 220)
            AgentsPane(state: all.visibleAgents, label: { all.agentLabel($0) }, phase: { all.phase(ofAgent: $0) }, feedOnly: true,
                       cards: all.agentCards, askingYou: { [panes = all.askingPanes] in panes.contains($0.paneID) }).frame(width: 460, height: 300)
        }.padding(16)
        try write(await shot(agents, size: NSSize(width: 492, height: 568)), "N370-agents.png")
    }

    private struct FocusHost: View {
        let model: PanelModel
        @FocusState var focused: String?
        var body: some View { WaitingTile(model: model, onOpen: { _ in }, focusedRow: $focused) }
    }

    /// Dark beside light, each drawn by a real window.
    @MainActor private func shot(_ root: some View, size: NSSize) async throws -> Data {
        try png(grid([try await pair(root, size: size)]))
    }

    /// The same view drawn by a real window in dark, then light.
    @MainActor private func pair(_ root: some View, size: NSSize) async throws -> [NSImage] {
        var images: [NSImage] = []
        for dark in [true, false] {
            let theme = AppTheme.current
            AppTheme.current = dark ? .dark : .light
            defer { AppTheme.current = theme }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView: root.background(Tok.bg).environment(\.colorScheme, dark ? .dark : .light))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(1200))
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
            images.append(image)
        }
        return images
    }

    /// Rows of equally sized images, top row first.
    private func grid(_ rows: [[NSImage]]) -> NSImage {
        let one = rows[0][0].size
        let out = NSImage(size: NSSize(width: one.width * CGFloat(rows[0].count), height: one.height * CGFloat(rows.count)))
        out.lockFocus()
        for (r, row) in rows.enumerated() {
            for (c, image) in row.enumerated() {
                image.draw(at: NSPoint(x: one.width * CGFloat(c), y: one.height * CGFloat(rows.count - 1 - r)), from: .zero, operation: .copy, fraction: 1)
            }
        }
        out.unlockFocus()
        return out
    }

    /// `rect` (in points, origin top-left) of `image`, scaled by `scale`.
    private func crop(_ image: NSImage, _ rect: NSRect, scale: CGFloat) -> NSImage {
        let from = NSRect(x: rect.minX, y: image.size.height - rect.maxY, width: rect.width, height: rect.height)
        let out = NSImage(size: NSSize(width: rect.width * scale, height: rect.height * scale))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: NSRect(origin: .zero, size: out.size), from: from, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func png(_ image: NSImage) throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
    }

    /// N375 live-window shots: N375-waiting.png (dark | light), N375-pulse.png (brightest row over dimmest row, dark | light)
    /// and N375-corner.png (the question row's top-left corner at 3×, dark | light). The glow must be soft and uncut.
    @MainActor func testTheSoftGlowShots() async throws {
        let dir = try TempDir()
        let model = try await DashboardSnapshotTests.makeModel(dir, owner: self, settings: DemoSupport.prepareSettings())
        model.gitSetup.probe = { _ in var facts = RepoFacts(); facts.isGitRepo = false; return ProjectProbe(facts: facts) }
        await model.refreshGitState(force: true)
        guard case .question = model.dashboardWaiting.first?.kind else { return XCTFail("the question comes first") }
        let size = NSSize(width: 492, height: 452)
        let tile = { (s: Double?) in FocusHost(model: model).frame(width: 460, height: 420).padding(16).environment(\.questionGlowFixedStrength, s) }
        let still = try await pair(tile(0.5), size: size)  // 0.5 = the Reduce Motion still look
        try write(png(grid([still])), "N375-waiting.png")
        let bright = try await pair(tile(1), size: size), dim = try await pair(tile(0), size: size)
        try write(png(grid([bright, dim])), "N375-pulse.png")
        // The question row is the tile's first row: window gutter 16 + tile padding 20 | 16 + 18 + title 22 + 12 + 3.
        let corner = NSRect(x: 16 + 20 - 14, y: 16 + 18 + 22 + 12 + 3 - 14, width: 60, height: 44)
        try write(png(grid([[crop(bright[0], corner, scale: 3), crop(bright[1], corner, scale: 3)]])), "N375-corner.png")
    }

    func testTheGlowIsLighterInTheLightThemeAndBreathes() {
        XCTAssertLessThan(QuestionGlow.glowOpacity(strength: 0.5, dark: false), QuestionGlow.glowOpacity(strength: 0.5, dark: true))
        XCTAssertLessThan(QuestionGlow.glowOpacity(strength: 0, dark: true), QuestionGlow.glowOpacity(strength: 1, dark: true))
        XCTAssertLessThanOrEqual(CGFloat(QuestionGlow.rings) * QuestionGlow.ringStep, QuestionGlow.reach, "the glow fits the room the tile gives it")
        XCTAssertGreaterThan(QuestionGlow.ringFade(0), QuestionGlow.ringFade(QuestionGlow.rings - 1), "fades outward")
    }

    private func write(_ data: Data, _ file: String) throws {
        XCTAssertGreaterThan(data.count, 10_000, file)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(file)) }
    }
}
