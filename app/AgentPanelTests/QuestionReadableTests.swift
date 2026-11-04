import XCTest
import SwiftUI
@testable import AgentPanel

/// N239: permission, plan and choice cards before and after (set AGENT_PANEL_SNAPSHOT_DIR to write the PNGs).
@MainActor
final class QuestionReadableTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func pending(_ q: AgentQuestion) -> PendingQuestion {
        PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "Dev · N239", cardID: "N239", question: q)
    }

    private func snapshot(_ q: AgentQuestion, _ name: String) throws {
        let inbox = AgentInboxModel(reader: Reader(), keys: Sender(), commander: Sender(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let view = QuestionCard(inbox: inbox, question: pending(q)).padding(16).background(Tok.raise)
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 520, height: 560)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N239-\(name).png")) }
    }
    private final class Sender: TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        func sendKeys(target: String, keys: [String]) async throws {}
        func sendText(target: String, text: String) async throws {}
        func prompt(target: String, text: String) async throws {}
    }
    private final class Reader: TerminalReading, @unchecked Sendable { func screen(of target: String, lines: Int) async throws -> String { "" } }

    /// What the card showed before: the whole prompt in one monospaced text, indentation and paragraphs gone, wrapped lines kept apart.
    private func before(_ q: AgentQuestion, text: String, context: String? = nil) -> AgentQuestion {
        AgentQuestion(kind: q.kind, title: q.title, text: text, options: q.options, context: context ?? "")
    }

    func testPermissionCardWithAMultiLineCommand() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("permission-bash-multiline.txt"), state: .blocked))
        try snapshot(before(q, text: "Bash command\nTip: auto mode handles these prompts for you — choose \"switch to auto mode\" below\nCheck every Swift file under src for TODO markers and print the names of the files that\nhave one so the list can be pasted into the card's Report section under the heading\nFindings\nfor f in src/*.swift; do\nif grep -q \"TODO\" \"$f\"; then\necho \"$f has a TODO\"\nfi\ndone\nDo you want to proceed?"), "permission-before")
        try snapshot(q, "permission-after")
    }

    func testPlanCard() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("plan-wrapped.txt"), state: .blocked))
        let old = "Plan: rename the helper\nContext\nThe helper is called from three places and its name no longer says what it does, so a\nreader has to open the file to find out what it returns. Rename it and update the callers\nin one commit.\nSteps\n1. Rename `loadStuff` to `loadCards` in Services/CardRepository.swift.\n2. Update the three callers:\nlet cards = try repo.loadCards()\nfor card in cards { show(card) }"
        try snapshot(before(q, text: q.text, context: old), "plan-before")
        try snapshot(q, "plan-after")
    }

    func testChoiceCardWithCodeInTheQuestion() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-code.txt"), state: .blocked))
        XCTAssertEqual(q.kind, .choice)
        XCTAssertEqual(q.text, "The helper that loads the cards is called loadStuff today and three callers use it. I can rename it everywhere in one commit, or leave the old name as a deprecated alias for a while:\n\n  @available(*, deprecated, renamed: \"loadCards\")\n  func loadStuff() throws -> [Card] {\n      try loadCards()\n  }\n\nWhich way do you want it?")
        try snapshot(q, "choice-after")
        let old = "The helper that loads the cards is called loadStuff today and three callers use it. I can\nrename it everywhere in one commit, or leave the old name as a deprecated alias for a while:\n@available(*, deprecated, renamed: \"loadCards\")\nfunc loadStuff() throws -> [Card] {\ntry loadCards()\n}\nWhich way do you want it?"
        try snapshot(before(q, text: old), "choice-before")
    }

    func testIndentedLinesBecomeCodeAndTheRestStaysProse() {
        let text = "Rename it:\n\n  @available(*, deprecated)\n  func a() {\n\n      b()\n  }\n\nWhich way?"
        XCTAssertEqual(QuestionSegments.split(text), [
            .init(code: false, text: "Rename it:"),
            .init(code: true, text: "@available(*, deprecated)\nfunc a() {\n\n    b()\n}"),
            .init(code: false, text: "Which way?"),
        ])
        XCTAssertEqual(QuestionSegments.split("one line"), [.init(code: false, text: "one line")])
    }
}
