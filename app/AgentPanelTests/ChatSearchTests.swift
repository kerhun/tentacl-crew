import XCTest
import SwiftUI
@testable import AgentPanel

/// Chat search and Conversation only (N291); snapshots → tasks/assets/N291-*.png.
@MainActor
final class ChatSearchTests: XCTestCase {
    private static let t0 = Calendar.current.startOfDay(for: Date()).addingTimeInterval(4 * 3600)
    private static func e(_ id: String, _ kind: ChatEntry.Kind, _ text: String, _ min: Int, tools: [String] = [], summary: String = "") -> ChatEntry {
        ChatEntry(id: id, kind: kind, text: text, time: t0.addingTimeInterval(TimeInterval(min * 60)), tools: tools, toolSummary: summary)
    }
    private static let entries = [
        e("p1", .panel, "Panel: N290 started", 0), e("p2", .panel, "Panel: N291 started, plan ready", 1),
        e("u1", .user, "Is the plan ready? Plan again please", 2),
        e("a1", .agent, "Yes, the plan is ready.", 3, tools: ["Read · plan.md", "Bash · git log"], summary: "read 1 file, ran 1 command"),
        e("t1", .tools, "ran 1 command", 4, tools: ["Bash · grep plan"], summary: "ran 1 command"),
        e("s1", .summary, "Summary of the plan", 5),
    ]
    private var rows: [ChatRow] { ChatRows.build(entries: Self.entries) }

    func testCountsAndOrderFollowTheDrawingOrder() {
        let all = ChatSearch.matches(rows, query: "plan", filter: .all)
        XCTAssertEqual(all.map { "\($0.row)/\($0.piece)/\($0.occ)" }, [
            "system-p1/1/0", "u1/0/0", "u1/0/1", "a1/0/0", "a1/2/0", "t1/0/0", "s1/0/0",
        ].map { $0 })
    }

    func testFiltersKeepTheirKind() {
        XCTAssertEqual(ChatSearch.matches(rows, query: "plan", filter: .panel).count, 1)
        XCTAssertEqual(ChatSearch.matches(rows, query: "PLAN", filter: .conversation).count, 4, "user 2, turn 1, summary 1; case is ignored")
        XCTAssertEqual(ChatSearch.matches(rows, query: "plan", filter: .tools).map(\.row), ["a1", "t1"])
        XCTAssertEqual(ChatSearch.matches(rows, query: "plan", filter: .questions).count, 2, "only texts with a question mark")
        XCTAssertTrue(ChatSearch.matches(rows, query: "  ", filter: .all).isEmpty)
    }

    func testConversationOnlyKeepsUserAndTurnsWithoutTools() {
        let kept = ChatSearch.conversationOnly(rows)
        let kinds = kept.map { row -> String in
            switch row { case .day: "day"; case .gap: "gap"; case .user: "user"; case .turn(let e): e.tools.isEmpty ? "turn" : "turn+tools"; default: "other" }
        }
        XCTAssertEqual(kinds, ["day", "user", "turn"])
        XCTAssertTrue(ChatSearch.matches(kept, query: "grep", filter: .all).isEmpty, "a hidden tool line is not searched")
    }

    func testCounterWords() {
        XCTAssertEqual(ChatSearch.counter(index: 2, count: 7), "3 of 7")
        XCTAssertEqual(ChatSearch.counter(index: 0, count: 0), "No matches")
    }

    func testInsertedPutsTextAfterTheDraft() {
        XCTAssertEqual(CommandBar.inserted("> q\n\n", into: ""), "> q\n\n")
        XCTAssertEqual(CommandBar.inserted("old", into: "draft"), "draft\n\nold")
    }

    // MARK: snapshots

    private func card(conversationOnly: Bool, search: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if search {
                ChatSearchBar(query: .constant("plan"), filter: .constant(.all), index: 2, count: 8, onStep: { _ in }, onDone: {})
            }
            ChatThread(place: ChatPlace(), entries: Self.entries, agentLabel: "PM", working: false, conversationOnly: conversationOnly,
                       canLoadEarlier: true, earlierFrom: Self.t0, openAll: true, now: Self.t0)
                .environment(\.chatHighlight, search ? ChatHighlight(query: "plan", current: ChatSearch.Match(row: "u1", piece: 0, occ: 1)) : nil)
        }
        .padding(16).frame(width: 640)
        .background(Tok.pane).environment(\.colorScheme, .dark)
    }

    private func write(_ view: some View, _ name: String) throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 640, height: 520)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }

    func testSearchSnapshot() throws { try write(card(conversationOnly: false, search: true), "N291-search.png") }
    func testConversationOnlySnapshot() throws { try write(card(conversationOnly: true, search: false), "N291-only.png") }
}
