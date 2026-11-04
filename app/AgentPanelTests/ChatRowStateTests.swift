import XCTest
import SwiftUI
import AppKit
@testable import AgentPanel

/// Show all and the opened tool/stack rows are kept in the `ChatSession`, so a tab switch (which rebuilds the thread) keeps them (N296).
@MainActor
final class ChatRowStateTests: XCTestCase {
    private static let long = ChatEntry(id: "t1", kind: .agent, text: (1...20).map { "line \($0)" }.joined(separator: "\n"), time: nil,
                                        pending: nil, tools: ["Bash · ls", "Read · a.swift", "Read · b.swift"], toolSummary: "ran 1 command, read 2 files")

    /// The height a freshly built view takes, as after a tab switch.
    private func height(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 600))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testShowAllIsKeptAndAFreshTurnRowShowsItExpanded() {
        let session = ChatStore().session(project: "p", pane: "%1")
        let folded = height(TurnRow(entry: Self.long, label: "PM", opened: session.opened))
        session.opened.set(.turn, Self.long.id, open: true, default: false)
        XCTAssertEqual(session.opened.states, ["turn:t1": true], "Show all puts the turn's id in the session")
        let expanded = height(TurnRow(entry: Self.long, label: "PM", opened: session.opened))
        XCTAssertGreaterThan(expanded, folded + 100, "a TurnRow built again from the same session shows all 20 lines")
        session.opened.set(.turn, Self.long.id, open: false, default: false)
        XCTAssertTrue(session.opened.states.isEmpty, "Show less removes it")
        XCTAssertEqual(height(TurnRow(entry: Self.long, label: "PM", opened: session.opened)), folded)
    }

    func testClosingADefaultOpenToolsLineIsRemembered() {
        let opened = ChatOpenRows()
        let line = { ToolsLine(summary: "3 tool uses", lines: Self.long.tools, row: "t1", open: true, opened: opened) }
        let open = height(line())
        opened.set(.tools, "t1", open: false, default: true)
        XCTAssertEqual(opened.states, ["tools:t1": false], "a closed default-open row is kept")
        XCTAssertLessThan(height(line()), open, "a fresh tools line stays closed")
        XCTAssertFalse(opened.isOpen(.turn, "t1", default: false), "the turn and its tools line are kept apart")
        opened.set(.tools, "t1", open: true, default: true)
        XCTAssertTrue(opened.states.isEmpty, "back to its default: nothing to keep")
    }

    func testAStackOfPanelNotesKeepsItsOpenState() {
        let opened = ChatOpenRows()
        opened.set(.system, "system-1", open: true, default: false)
        XCTAssertTrue(opened.isOpen(.system, "system-1", default: false))
        XCTAssertFalse(opened.isOpen(.system, "system-2", default: false), "another stack keeps its default")
    }

    func testEachProjectsSessionKeepsItsOwnRows() {
        let store = ChatStore()
        store.session(project: "a", pane: "%1").opened.set(.turn, "t1", open: true, default: false)
        XCTAssertTrue(store.session(project: "a", pane: "%1").opened.isOpen(.turn, "t1", default: false), "the same session after a rebuild")
        XCTAssertFalse(store.session(project: "b", pane: "%1").opened.isOpen(.turn, "t1", default: false), "another project's session is separate")
        XCTAssertFalse(store.session(project: "a", pane: "%2").opened.isOpen(.turn, "t1", default: false), "another agent's session is separate")
    }
}
