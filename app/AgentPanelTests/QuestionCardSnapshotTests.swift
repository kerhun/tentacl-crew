import XCTest
import SwiftUI
@testable import AgentPanel

/// N279: real question screens as cards (set AGENT_PANEL_SNAPSHOT_DIR to write the PNGs; `-before` ones are made from the commit before N279).
@MainActor
final class QuestionCardSnapshotTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private func screen(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private func inbox() -> AgentInboxModel {
        AgentInboxModel(reader: Silent(), keys: Silent(), commander: Silent(), adapter: FakeTerminal(agentsResult: .success([])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
    }
    private final class Silent: TerminalKeySending, TerminalCommanding, TerminalReading, @unchecked Sendable {
        func sendKeys(target: String, keys: [String]) async throws {}
        func sendText(target: String, text: String) async throws {}
        func prompt(target: String, text: String) async throws {}
        func screen(of target: String, lines: Int) async throws -> String { "" }
    }
    private func pending(_ q: AgentQuestion) -> PendingQuestion { PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "Dev · N279", cardID: "N279", question: q) }

    private func write(_ view: some View, _ name: String, size: CGSize) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.padding(16).background(Tok.raise), size: size))
        XCTAssertGreaterThan(data.count, 8_000, name)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N279-\(name).png")) }
    }

    private static let screens: [(file: String, state: AgentState)] = [
        ("ask-marks-user.txt", .blocked), ("ask-marks-critical.txt", .blocked), ("choice-code.txt", .blocked), ("ask-boxed-code.txt", .blocked),
        ("permission-bash-multiline.txt", .blocked), ("plan-wrapped.txt", .blocked), ("freetext-before.txt", .done),
    ]

    func testEveryScreenRendersAsACard() throws {
        for (file, state) in Self.screens {
            let q = try XCTUnwrap(QuestionDetector.detect(screen: try screen(file), state: state), file)
            try write(QuestionCard(inbox: inbox(), question: pending(q), detailsOpen: true), "question-\(file.replacingOccurrences(of: ".txt", with: ""))-after", size: CGSize(width: 520, height: 760))
        }
    }

    /// The pair the card lists: the same question before and after (the main fixture, with the agent's `user:` line).
    func testTheMainQuestion() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try screen("ask-marks-user.txt"), state: .blocked))
        try write(QuestionCard(inbox: inbox(), question: pending(q), detailsOpen: true), "question-after", size: CGSize(width: 520, height: 760))
    }

    /// What the user sees first: Details folded.
    func testFoldedByDefault() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try screen("ask-marks-user.txt"), state: .blocked))
        try write(QuestionCard(inbox: inbox(), question: pending(q)), "question-after-folded", size: CGSize(width: 520, height: 520))
        let plain = try XCTUnwrap(QuestionDetector.detect(screen: try screen("choice-code.txt"), state: .blocked))
        try write(QuestionCard(inbox: inbox(), question: pending(plain)), "question-choice-code-after-folded", size: CGSize(width: 520, height: 520))
    }

    /// Waiting for you: the list item and the PM's answers under it.
    func testAnsweredByPM() throws {
        let q = try XCTUnwrap(QuestionDetector.detect(screen: try screen("ask-marks-user.txt"), state: .blocked))
        let t = Date(timeIntervalSince1970: 1_793_000_000)
        let items = [
            AnsweredByPM(id: "N279-q3", agent: "Dev · N279", cardID: "N279", question: "Which name reads better for the helper?", answer: "loadCards", time: t),
            AnsweredByPM(id: "N277-q1", agent: "Dev · N277", cardID: "N277", question: "Keep the old summary format or print the new one?", answer: "Print the new one", time: t.addingTimeInterval(-540)),
            AnsweredByPM(id: "N276-q2", agent: "Dev · N276", cardID: "N276", question: "Should the test use a fixture file?", answer: "Yes, a fixture file", time: t.addingTimeInterval(-3_600)),
        ]
        let view = VStack(alignment: .leading, spacing: Tok.Space.m) {
            Text("WAITING FOR YOU · 1").font(Tok.Font.small.weight(.semibold)).tracking(0.7).foregroundStyle(Tok.ask)
            QuestionCard(inbox: inbox(), question: pending(q), tint: .question, onOpen: { _ in })
            Text("Answered by PM · 3").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink2)
            AnsweredByPMList(items: items).rows
        }
        try write(view, "answered-by-pm", size: CGSize(width: 520, height: 520))
    }
}
