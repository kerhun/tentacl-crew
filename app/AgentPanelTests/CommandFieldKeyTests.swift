import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

/// The top bar's ⌘K field (N134) in the whole window: keys go through the window the way the running app delivers them.
@MainActor
final class CommandFieldKeyTests: XCTestCase {
    private struct RepoAgent: TerminalListing {
        let cwd: String
        func agents() async throws -> [AgentStatus] { [AgentStatus(paneID: "w2:pA", workspaceID: "w2", state: .idle, cwd: cwd, title: "PM", sessionID: "s-pm")] }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
    }

    private var dir: TempDir!
    private var model: PanelModel!
    private var window: NSWindow!
    private var screens: [ShellScreen] = []
    private let noteText = "Ask about the colour of the rings"

    /// Two projects; "Tentacl" (selected) has three cards, a note and its PM running in its repository.
    override func setUp() async throws {
        dir = try TempDir()
        let work = dir.url
        let scripts = work.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ScriptName.allCases { try "#!/bin/bash\nexit 0\n".write(to: scripts.appendingPathComponent(name.rawValue), atomically: true, encoding: .utf8) }
        func project(_ id: String, _ name: String) throws -> String {
            let repo = work.appendingPathComponent("repo-\(id)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            return try dir.write("\(id)/project.json", "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"repoPath\":\"\(repo.path)\",\"dataDir\":\"\(work.appendingPathComponent("data-\(id)").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}").path
        }
        let a = try project("a", "Tentacl"), b = try project("b", "Orchard")
        for (id, status, title) in [("N120", "todo", "Command field"), ("N121", "review", "Notes pad"), ("N3", "done", "Old one")] {
            _ = try dir.write("data-a/tasks/\(id).md", "---\nid: \(id)\nproject: a\nstatus: \(status)\nfiles:\n  - x\n---\n# \(id) · \(title)\n")
        }
        _ = try dir.write("data-a/notes.md", "## 2026-10-19\n- [ ] \(noteText)\n")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(a)\",\"\(b)\"],\"scriptsDir\":\"\(scripts.path)\"}")
        let iso = TestIsolation(dir, owner: self)
        let repo = work.appendingPathComponent("repo-a").path
        model = PanelModel(settingsURL: settings, makeTerminal: { RepoAgent(cwd: repo) }, opener: RecordingOpener(), makeScripts: { _ in DemoScripts() },
                           makeCommander: { DemoCommander() }, log: iso.log, writer: DemoCardWriter(), defaults: iso.defaults, roleStore: iso.roleStore)
        await model.reload()
        XCTAssertEqual(model.selectedProjectID, "a")
        let hosting = NSHostingView(rootView: ShellView(model: model, screen: .dashboard, onScreen: { [weak self] in self?.screens.append($0) }))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() async throws {
        model.chats.existingSession(project: "a", pane: "w2:pA")?.chat.takeBack(editing: false)
        window?.orderOut(nil); window = nil; model = nil
    }

    private func find(_ identifier: String, in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.accessibilityIdentifier() == identifier { return text }
        for sub in view.subviews { if let hit = find(identifier, in: sub) { return hit } }
        return nil
    }

    private func until(_ done: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func event(_ characters: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// A key as NSApplication delivers it: a ⌘ key is offered to the window as a key equivalent first, then sent as a key press.
    private func key(_ characters: String, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) {
        let e = event(characters, keyCode: keyCode, modifiers)
        if modifiers.contains(.command), window.performKeyEquivalent(with: e) { return }
        window.sendEvent(e)
    }

    private func type(_ text: String) { for c in text.map(String.init) { key(c) } }
    private func commandK() { key("k", keyCode: 40, .command) }
    private func down() { key(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125) }
    private func pressReturn() { key("\r", keyCode: 36) }
    private func escape() { key("\u{1b}", keyCode: 53) }

    /// The window with the chat input holding the focus, and the ⌘K field.
    private func ready() async throws -> (chat: NSTextView, field: NSTextView) {
        await until { self.find(CommandBar.inputIdentifier, in: self.window.contentView).map { self.window.firstResponder === $0 } ?? false }
        let chat = try XCTUnwrap(find(CommandBar.inputIdentifier, in: window.contentView), "the Dashboard's chat input")
        XCTAssertTrue(window.firstResponder === chat, "the chat input has the focus at the start")
        await until { self.model.pmAgent(forProject: "a") != nil }
        XCTAssertNotNil(model.pmAgent(forProject: "a"), "the PM is running")
        let field = try XCTUnwrap(find(CommandField.identifier, in: window.contentView), "the ⌘K field is an AppKit text view in the top bar")
        return (chat, field)
    }

    func testCommandKFocusesTheFieldAndEscClearsItAndGivesTheFocusBack() async throws {
        let (chat, field) = try await ready()
        commandK()
        XCTAssertTrue(window.firstResponder === field, "⌘K puts the focus in the field")
        type("N12")
        XCTAssertEqual(field.string, "N12")
        XCTAssertEqual(chat.string, "", "the typing went into the field, not the chat")
        escape()
        XCTAssertEqual(field.string, "", "Esc clears the field")
        await until { self.window.firstResponder === chat }
        XCTAssertTrue(window.firstResponder === chat, "and the chat input takes the focus back")
    }

    func testDownAndReturnOpenTheSecondCard() async throws {
        let (chat, field) = try await ready()
        commandK()
        type("n12")
        down()
        pressReturn()
        XCTAssertEqual(model.selectedCardID, "N121", "N120 is the first row, ↓ picks N121")
        XCTAssertEqual(screens.last, .tasks, "the card opens on the Tasks screen")
        XCTAssertEqual(field.string, "")
        await until { self.window.firstResponder !== field }
        XCTAssertFalse(window.firstResponder === field, "the field gives the focus back")
        XCTAssertEqual(chat.string, "")
    }

    func testAScreenAProjectAndANoteOpenFromTheKeyboard() async throws {
        _ = try await ready()
        commandK(); type("stats"); pressReturn()
        XCTAssertEqual(screens.last, .stats)
        commandK(); type("orch"); pressReturn()
        await until { self.model.selectedProjectID == "b" }
        XCTAssertEqual(model.selectedProjectID, "b", "the project is switched")
        commandK(); type("tentacl"); pressReturn()
        await until { self.model.selectedProjectID == "a" }
        commandK(); type("colour of the"); pressReturn()
        await until { self.find(NoteField.addIdentifier, in: self.window.contentView) != nil }
        XCTAssertNotNil(find(NoteField.addIdentifier, in: window.contentView), "the notes pad opens")
    }

    func testReturnOnAskThePMHoldsTheTextForThePMAndShowsTheDashboard() async throws {
        _ = try await ready()
        commandK(); type("stats"); pressReturn()
        XCTAssertEqual(screens.last, .stats)
        commandK()
        type("plan the next round")
        pressReturn()
        XCTAssertEqual(model.chats.existingSession(project: "a", pane: "w2:pA")?.chat.held?.text, "plan the next round", "held for the PM like the Dashboard's Send")
        XCTAssertEqual(screens.last, .dashboard)
    }
}
