import SwiftUI
import XCTest
@testable import AgentPanel

/// N265: the Preview icon beside Stop PM.
@MainActor final class PMPreviewIconTests: XCTestCase {
    func testHiddenWithoutAPageOffWithOneSelectedWhileOpen() {
        XCTAssertNil(PMChatHeader.previewIcon(hasPage: false, showing: false))
        XCTAssertEqual(PMChatHeader.previewIcon(hasPage: true, showing: false), false)
        XCTAssertEqual(PMChatHeader.previewIcon(hasPage: true, showing: true), true)
    }

    func testTheIconFollowsThePreviewAndTogglesItBack() {
        let state = ChatPreviewState(defaults: makeTestDefaults(prefix: "n265"))
        XCTAssertNil(PMChatHeader.previewIcon(hasPage: state.url(for: "p") != nil, showing: state.shown("p")))
        state.open(URL(string: "http://localhost:5173/")!, project: "p")
        XCTAssertEqual(PMChatHeader.previewIcon(hasPage: true, showing: state.shown("p")), true)
        state.toggle("p")
        XCTAssertEqual(state.layout("p"), .chat)
        XCTAssertEqual(PMChatHeader.previewIcon(hasPage: true, showing: state.shown("p")), false)
        state.toggle("p")
        XCTAssertEqual(state.layout("p"), .inChat)
        state.setExpanded(true, project: "p")
        XCTAssertTrue(state.escape("p"))
        XCTAssertEqual(state.layout("p"), .inChat, "Esc still steps back from expanded first (N254)")
    }

    /// The header with the icon off, selected, and without a page (set AGENT_PANEL_SNAPSHOT_DIR to save it).
    func testSnapshotOfTheHeader() throws {
        for (name, scheme) in [("", ColorScheme.light), ("-dark", ColorScheme.dark)] {
            let view = VStack(spacing: 0) {
                PMChatHeader(status: .idle, projectName: "Tentacl", previewShown: false)
                Divider()
                PMChatHeader(status: .running, projectName: "Tentacl", previewShown: true)
                Divider()
                PMChatHeader(status: .idle, projectName: "Tentacl")
            }.frame(width: 640).padding(.vertical, 8).background(Tok.pane).environment(\.colorScheme, scheme)
            let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 640, height: 180)))
            XCTAssertGreaterThan(data.count, 1_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N265-preview-icon\(name).png")) }
        }
    }

    /// The Dashboard with the Preview open (icon selected, the PM bar above the Preview) and back on the chat (icon off).
    func testSnapshotsOfTheDashboard() async throws {
        let dir = try TempDir()
        let iso = TestIsolation(dir, owner: self)
        let model = PanelModel(settingsURL: DemoSupport.prepareSettings(), makeTerminal: { DemoTerminal() }, opener: WorkspaceURLOpener(),
                               makeScripts: { _ in DemoScripts() }, makeCommander: { DemoCommander() }, log: iso.log, writer: DemoCardWriter(),
                               defaults: iso.defaults, roleStore: iso.roleStore, autopilotStore: AutopilotStore(folder: dir.url.appendingPathComponent("autopilot")))
        await model.reload()
        let project = model.selectedProjectID ?? ""
        let state = ChatPreviewState(defaults: makeTestDefaults(prefix: "n265d"))
        state.open(URL(string: "http://localhost:5173/settings")!, project: project)
        for name in ["N265-dashboard-preview.png", "N265-dashboard-chat.png"] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: DashboardView(model: model, chatPreview: state), size: CGSize(width: 1600, height: 900)))
            XCTAssertGreaterThan(data.count, 20_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
            state.toggle(project)
        }
    }
}
