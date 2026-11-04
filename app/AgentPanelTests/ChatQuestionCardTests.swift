import SwiftUI
import AppKit
import XCTest
@testable import AgentPanel

/// The chat's question card (N289): buttons by option role, the answered line, and snapshots → tasks/assets/N289-*.png.
@MainActor
final class ChatQuestionCardTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var reader: AgentInboxTests.FakeReader!
    private var sender: AgentInboxTests.FakeSender!
    private var dir: TempDir!

    override func setUpWithError() throws {
        reader = .init(); sender = .init(); dir = try TempDir()
    }

    private func screen(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }

    private func pm(_ pane: String) -> AgentStatus { AgentStatus(paneID: pane, workspaceID: pane, state: .blocked, cwd: "/repo", title: "pm", sessionID: "s-\(pane)") }

    /// The PM's open questions as the inbox reads them, one pane per fixture.
    private var panes = 0
    private func inbox(_ fixtures: [String]) async throws -> AgentInboxModel {
        let agents = fixtures.indices.map { pm("pm\(panes + $0)") }
        for (i, f) in fixtures.enumerated() { reader.screens["pm\(panes + i)"] = try screen(f) }
        panes += fixtures.count
        let m = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success(agents)),
                                log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        for a in agents { await m.refresh(agents: [a], cards: [], projectWorktrees: URL(fileURLWithPath: "/repo/.agent-worktrees"), pm: a, pmProject: "d", label: { _ in "PM" }) }
        return m
    }

    private func question(_ fixture: String) async throws -> PendingQuestion {
        let m = try await inbox([fixture])
        return try XCTUnwrap(m.questions.first)
    }

    func testPermissionButtonsFollowTheOptionRoles() async throws {
        let edit = try await question("permission-edit-menu.txt")
        XCTAssertEqual(ChatQuestionContent.title(edit), "PM needs your permission")
        XCTAssertEqual(ChatQuestionContent.what(edit.question), "Edit a file")
        let actions = ChatQuestionContent.actions(edit)
        XCTAssertEqual(actions.map(\.kind), [.allow, .always, .denyWithNote])
        XCTAssertEqual(actions.map(\.label), ["Allow", "Allow edits this session", "Deny and tell the PM…"])
        XCTAssertEqual(actions.map(\.option.number), [1, 2, 3])

        let bash = try await question("permission-bash-touch.txt")
        XCTAssertEqual(ChatQuestionContent.what(bash.question), "Run a shell command")
        XCTAssertEqual(ChatQuestionContent.actions(bash).first?.label, "Allow")
        XCTAssertEqual(ChatQuestionContent.actions(bash).last?.kind, .denyWithNote)
    }

    func testTheAgentsLabelNamesItsCardAndTheAlwaysLabelNamesTheCommand() {
        let q = AgentQuestion(kind: .permission, title: "Bash command", text: "Do you want to proceed?", options: [
            QuestionOption(number: 1, label: "Yes", detail: "", isSpecial: false, role: .allow),
            QuestionOption(number: 2, label: "Yes, and don't ask again for git log commands in /repo", detail: "", isSpecial: false, role: .allowAlways),
            QuestionOption(number: 3, label: "No", detail: "", isSpecial: false, role: .deny)])
        let p = PendingQuestion(paneID: "w1", sessionID: "s", agentLabel: "Pixel · V1", cardID: "V1", question: q)
        XCTAssertEqual(ChatQuestionContent.title(p), "Pixel · V1 needs your permission")
        XCTAssertEqual(ChatQuestionContent.actions(p).map(\.label), ["Allow", "Allow “git log” always", "Deny"], "no feedback path: a plain Deny")
        XCTAssertEqual(ChatQuestionContent.alwaysLabel("Yes, and always allow access to /tmp from this project"), "Allow this folder always")
    }

    func testAnAnswerFromTheCardGoesThroughTheInboxAndTurnsIntoOneLine() async throws {
        let m = try await inbox(["permission-bash-touch.txt"])
        let p = try XCTUnwrap(m.questions.first)
        let ok = await m.answer(p, option: try XCTUnwrap(p.question.options.first))
        XCTAssertTrue(ok)
        XCTAssertEqual(sender.keys.map(\.keys), [["1"]])
        let a = try XCTUnwrap(m.lastAnswer)
        XCTAssertEqual(a.question.id, p.id)
        XCTAssertEqual(ChatQuestionContent.answered(a).verb, "You allowed")
        XCTAssertEqual(ChatQuestionContent.answered(a).detail, "touch n213-a.txt")

        let menu = try await question("choice-before.txt")
        let answered = SentAnswer(question: menu, sent: "Red", at: Date())
        XCTAssertEqual(ChatQuestionContent.answered(answered).verb, "You answered")
        XCTAssertEqual(ChatQuestionContent.answered(SentAnswer(question: p, sent: "feedback: use touch -c", at: Date())).verb, "You denied")
        XCTAssertEqual(ChatQuestionContent.waited(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 42)), "0:42")
        XCTAssertEqual(ChatQuestionContent.answeredFor, 10)
    }

    func testThePlanShowsItsFirstLines() async throws {
        let plan = try await question("plan-wrapped.txt")
        XCTAssertEqual(ChatQuestionContent.title(plan), "The PM has a plan")
        let head = ChatQuestionContent.planHead(plan.question)
        XCTAssertEqual(head.head.components(separatedBy: "\n").count, 4)
        XCTAssertGreaterThan(head.total, 4)
    }

    /// N293: a digit names the option the terminal gives that number; a choice's, a permission's button, a plan's.
    func testADigitNamesTheOptionWithThatNumber() async throws {
        let edit = try await question("permission-edit-menu.txt")
        XCTAssertEqual(ChatQuestionContent.digitOption(edit, 1)?.number, 1)
        XCTAssertEqual(ChatQuestionContent.digitOption(edit, 3)?.number, 3, "Deny and tell … has its digit too")
        XCTAssertNil(ChatQuestionContent.digitOption(edit, 7), "a digit with no option is typed")
        let menu = try await question("choice-before.txt")
        XCTAssertEqual(ChatQuestionContent.digitOption(menu, 2)?.number, 2)
        let plan = try await question("plan-wrapped.txt")
        XCTAssertEqual(ChatQuestionContent.digitOption(plan, 1)?.number, 1)
    }

    func testADigitOnlyCountsInTheEmptyInputWithoutModifiers() {
        XCTAssertEqual(ChatInput.digit(characters: "2", modifiers: [], text: ""), 2)
        XCTAssertNil(ChatInput.digit(characters: "2", modifiers: [], text: "N29"), "with text in the input digits type as usual")
        XCTAssertNil(ChatInput.digit(characters: "2", modifiers: .command, text: ""))
        XCTAssertNil(ChatInput.digit(characters: "0", modifiers: [], text: ""))
        XCTAssertNil(ChatInput.digit(characters: "a", modifiers: [], text: ""))
    }

    /// The digit from the chat does what the click does: the inbox sends that option's key.
    func testADigitPressAnswersAsAClick() async throws {
        let m = try await inbox(["permission-bash-touch.txt"])
        let p = try XCTUnwrap(m.questions.first)
        let host = NSHostingView(rootView: ChatQuestionCard(inbox: m, questions: [p], paneID: p.paneID, now: Date()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.rootView = ChatQuestionCard(inbox: m, questions: [p], paneID: p.paneID, now: Date(), digit: ChatDigit(number: 1, seq: 1))
        host.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(3)
        while sender.keys.isEmpty, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(sender.keys.map(\.keys), [["1"]])
        window.contentView = nil
    }

    // MARK: snapshots

    private func write(_ view: some View, _ size: CGSize, _ name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view.padding(Tok.Space.m).frame(maxHeight: .infinity, alignment: .bottom).background(Tok.pane), size: size))
        XCTAssertGreaterThan(data.count, 5_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    private func later(_ m: AgentInboxModel, _ p: PendingQuestion) -> Date { (m.askedAt[p.id] ?? Date()).addingTimeInterval(42) }

    func testSnapshots() async throws {
        let m = try await inbox(["permission-bash-multiline.txt"])
        let menu = try await question("choice-before.txt"), plan = try await question("plan-wrapped.txt")
        let qs = [try XCTUnwrap(m.questions.first), menu, plan]
        try write(ChatQuestionCard(inbox: m, questions: qs, paneID: "pm0", now: later(m, qs[0])), CGSize(width: 560, height: 330), "N289-permission.png")
        try write(ChatQuestionCard(inbox: m, questions: [qs[1]], paneID: menu.paneID, now: later(m, qs[1])), CGSize(width: 560, height: 330), "N289-menu.png")
        try write(ChatQuestionCard(inbox: m, questions: [qs[2]], paneID: plan.paneID, now: later(m, qs[2])), CGSize(width: 560, height: 400), "N289-plan.png")
        try write(ChatQuestionCard(inbox: m, questions: [qs[0]], paneID: "pm0", now: later(m, qs[0]), noteOpen: true), CGSize(width: 560, height: 300), "N289-deny-note.png")
        let ok = await m.answer(qs[0], option: try XCTUnwrap(qs[0].question.options.first))
        XCTAssertTrue(ok)
        try write(ChatQuestionCard(inbox: m, questions: [], paneID: "pm0", now: try XCTUnwrap(m.lastAnswer).at.addingTimeInterval(3)), CGSize(width: 560, height: 80), "N289-answered.png")
    }
}
