import XCTest
import SwiftUI
@testable import AgentPanel

/// The ⌘K field's search (N134): what is found, in which order, and the "Ask the PM" row.
final class CommandSearchTests: XCTestCase {
    private func card(_ id: String, _ title: String, _ status: TaskStatus = .todo) -> TaskCard {
        TaskCard(id: id, project: "p", status: status, agent: nil, branch: nil, kind: nil, files: [], title: title, sections: [:],
                 url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    private let projects = [CommandSearch.Project(id: "tentacl", name: "Tentacl"), CommandSearch.Project(id: "orchard", name: "Orchard")]
    private let noteID = UUID()

    private func search(_ q: String, cards: [TaskCard] = [], notes: [CommandSearch.Note] = [], pmMissing: String? = nil) -> [CommandSearch.Row] {
        CommandSearch.rows(query: q, cards: cards, projects: projects, selectedProject: "tentacl", notes: notes, pmMissing: pmMissing)
    }

    func testAnIdPrefixFindsTheCardsInIdOrderWithTheExactIdFirst() {
        let cards = [card("N125", "Chat focus"), card("N12", "Old one", .done), card("N121", "Prefix"), card("N3", "Other"), card("N120", "Zero")]
        let rows = search("n12", cards: cards)
        XCTAssertEqual(rows.compactMap(\.badge), ["N12", "N120", "N121", "N125"])
        XCTAssertEqual(rows.first?.title, "Old one")
        XCTAssertEqual(rows.first?.detail, "done", "a card row carries its status")
        XCTAssertEqual(rows.first?.target, .card("N12"))
    }

    func testTitleWordsFindCardsWithThePrefixBeforeContains() {
        let cards = [card("N130", "N130 · Fix the notes checkbox"), card("N129", "Notes pad opens at the line"), card("N1", "Unrelated")]
        let rows = search("notes", cards: cards)
        XCTAssertEqual(rows.compactMap(\.badge), ["N129", "N130"], "the title prefix ranks first")
        XCTAssertEqual(rows[1].title, "Fix the notes checkbox", "the id is shown on its own, not again in the title")
        XCTAssertEqual(search("checkbox fix", cards: cards).compactMap(\.badge), ["N130"], "every word, in any order")
    }

    func testScreensProjectsAndNotesAreFoundGroupedByKind() {
        let notes = [CommandSearch.Note(id: noteID, text: "Ask about the timeline colours")]
        let rows = search("t", cards: [card("T1", "Timer")], notes: notes)
        XCTAssertEqual(rows.map(\.kind), [.card, .screen, .screen, .screen, .screen, .screen, .project, .askPM], "the note only contains it and is left out")
        XCTAssertEqual(rows.filter { $0.kind == .screen }.map(\.title), ["Tasks", "Terminals", "Timeline", "Team", "Git"], "prefixes first, each in rail order (Terminals, N224)")
        XCTAssertEqual(rows.first { $0.kind == .project }?.detail, "current")
        let tl = search("timeline", notes: notes)
        XCTAssertEqual(tl.map(\.target), [.screen(.timeline), .note(noteID), .askPM("timeline")], "the screen's exact name before the note that contains it")
        XCTAssertEqual(search("orch").first?.target, .project("orchard"))
    }

    func testCaseAndAccentsDoNotCount() {
        XCTAssertEqual(search("DASH").first?.target, .screen(.dashboard))
        XCTAssertEqual(search("cafe", notes: [CommandSearch.Note(id: noteID, text: "Café menu")]).first?.target, .note(noteID))
    }

    func testAtMostEightRowsKeepTheBestMatchesAndAskThePMLast() {
        let cards = (1...20).map { card("N1\($0)", "Card \($0)") } + [card("X1", "Mentions n1 somewhere")]
        let rows = search("n1", cards: cards)
        XCTAssertEqual(rows.count, CommandSearch.maxRows)
        XCTAssertEqual(rows.last?.target, .askPM("n1"))
        XCTAssertFalse(rows.contains { $0.badge == "X1" }, "a title that only contains it loses to id prefixes")
        XCTAssertEqual(rows.compactMap(\.badge), ["N11", "N12", "N13", "N14", "N15", "N16", "N17"])
    }

    func testAskThePMIsTheOnlyRowWhenNothingMatchesAndCarriesTheReasonWithoutAPM() {
        let rows = search("  please plan the next round  ")
        XCTAssertEqual(rows.map(\.title), ["Ask the PM: please plan the next round"])
        XCTAssertNil(rows[0].disabledReason)
        let none = search("zzz", pmMissing: CommandSearch.pmMissingReason(project: "Tentacl"))
        XCTAssertEqual(none[0].disabledReason, "No PM is running in Tentacl. Start one or choose one on the Dashboard.")
    }

    func testAnEmptyQueryShowsNothing() {
        XCTAssertEqual(search("   ", cards: [card("N1", "One")]), [])
    }

    func testTheHighlightStopsAtBothEnds() {
        XCTAssertEqual(CommandSearch.moved(0, by: -1, count: 3), 0)
        XCTAssertEqual(CommandSearch.moved(0, by: 1, count: 3), 1)
        XCTAssertEqual(CommandSearch.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(CommandSearch.moved(5, by: 1, count: 0), 0)
    }

    // MARK: Snapshots (static: the field draws its text, no AppKit views)

    @MainActor
    func testSnapshotsOfTheBarWithResultsOpen() async throws {
        let model = await DemoSupport.makeModel()
        let notes = [CommandSearch.Note(id: noteID, text: "Ask about the accessibility audit colours")]
        let inbox = TopBarInbox.content(sources: [], selected: "demo", ready: [], now: Date())
        let shots: [(String, String, String?)] = [("cards", "a", nil), ("ask-only", "please plan the next round", nil),
                                                  ("no-pm", "zzz", CommandSearch.pmMissingReason(project: "Demo App")), ("empty", "", nil)]
        for (name, query, pmMissing) in shots {
            let search: (String) -> [CommandSearch.Row] = { q in
                CommandSearch.rows(query: q, cards: model.selectedTaskCards, projects: self.projects, selectedProject: "tentacl", notes: notes, pmMissing: pmMissing)
            }
            if !query.isEmpty { XCTAssertFalse(search(query).isEmpty, name) }
            let view = VStack(spacing: 0) {
                TopBar(model: model, screen: .dashboard, inbox: inbox, autopilotLook: nil, usage: nil, query: query, search: search)
                Spacer(minLength: 0)
            }
            .background(Tok.bg)
            for width in [1440, 1024] as [CGFloat] {
                let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: width, height: 360)), name)
                XCTAssertGreaterThan(data.count, 3_000, name)
                if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                    try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("command-field-\(name)-\(Int(width)).png"))
                }
            }
        }
    }
}
