import XCTest
@testable import AgentPanel

/// Saved commands on the Terminals screen (N272): the store per project and global, and how a command reaches a shell or an agent pane.
@MainActor
final class TerminalSnippetTests: XCTestCase {
    private func store() -> TerminalSnippetStore { TerminalSnippetStore(defaults: makeTestDefaults()) }
    private let demo = TerminalSnippetScope.project("demo")

    func testAddEditDeleteReorder() {
        let s = store()
        let a = s.add(name: "Tests", text: " bash tests/run.sh \n", runAtOnce: true, to: demo)!
        let b = s.add(name: "", text: "git status", runAtOnce: false, to: demo)!
        XCTAssertEqual(a.text, "bash tests/run.sh", "trimmed")
        XCTAssertEqual(b.name, "git status", "a blank name takes the text")
        XCTAssertNil(s.add(name: "x", text: "  \n", runAtOnce: false, to: demo), "empty text is not saved")
        s.move(b.id, by: -1, in: demo)
        XCTAssertEqual(s.load(demo).map(\.name), ["git status", "Tests"])
        s.move(b.id, by: -1, in: demo)
        XCTAssertEqual(s.load(demo).map(\.name), ["git status", "Tests"], "the top one stays")
        var edited = a; edited.name = "Run tests"; edited.runAtOnce = false
        s.update(edited, in: demo)
        XCTAssertEqual(s.load(demo).last, edited)
        edited.text = " "
        s.update(edited, in: demo)
        XCTAssertEqual(s.load(demo).last?.text, "bash tests/run.sh", "an empty edit is refused")
        s.delete(a.id, from: demo)
        XCTAssertEqual(s.load(demo).map(\.name), ["git status"])
    }

    func testProjectsAndGlobalAreSeparate() {
        let s = store()
        s.add(name: "p", text: "ls", runAtOnce: false, to: demo)
        s.add(name: "g", text: "pwd", runAtOnce: false, to: .global)
        XCTAssertEqual(s.load(demo).map(\.name), ["p"])
        XCTAssertEqual(s.load(.project("other")), [])
        XCTAssertEqual(s.load(.global).map(\.name), ["g"])
        XCTAssertNotEqual(TerminalSnippetStore.key(demo), TerminalSnippetStore.key(.global))
    }

    func testShellGetsTheTextAndReturnOnlyWhenRunAtOnce() {
        var item = TerminalSnippet(name: "n", text: "ls -la", runAtOnce: false)
        XCTAssertEqual(TerminalSnippetSend.route(item, pane: "my-shell-1"), .shell(bytes: Array("ls -la".utf8)), "typed, waits")
        item.runAtOnce = true
        XCTAssertEqual(TerminalSnippetSend.route(item, pane: "my-shell-1"), .shell(bytes: Array("ls -la".utf8) + [0x0D]))
    }

    func testAgentPaneNeverGetsRawKeystrokes() {
        var item = TerminalSnippet(name: "n", text: "run the tests", runAtOnce: false)
        XCTAssertEqual(TerminalSnippetSend.route(item, pane: "w4:p1"), .agentBox(text: "run the tests"), "into the ⌘L box to read first")
        item.runAtOnce = true
        XCTAssertEqual(TerminalSnippetSend.route(item, pane: "w4:p1"), .agentPrompt(text: "run the tests"), "the ⌘L send path")
    }
}
