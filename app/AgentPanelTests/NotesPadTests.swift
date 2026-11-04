import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class NotesPadTests: XCTestCase {
    private func defaults() -> UserDefaults {
        makeTestDefaults(prefix: "notes-pad-tests")
    }

    // MARK: open, close, quick capture

    func testRailIconTogglesThePad() {
        XCTAssertEqual(NotesPadMode.closed.railTapped(), .open)
        XCTAssertEqual(NotesPadMode.open.railTapped(), .closed)
        XCTAssertEqual(NotesPadMode.capture.railTapped(), .open)
    }

    func testShortcutOpensQuickCaptureThenThePad() {
        XCTAssertEqual(NotesPadMode.closed.shortcut(), .capture)
        XCTAssertEqual(NotesPadMode.capture.shortcut(), .open)
        XCTAssertEqual(NotesPadMode.open.shortcut(), .open)
    }

    func testQuickCaptureAddsALineAndCloses() throws {
        let dir = try TempDir()
        let notes = NotesModel(fileURL: dir.url.appendingPathComponent("notes.md"))
        XCTAssertEqual(NotesPadMode.capture.captured("an idea", into: notes), .closed)
        XCTAssertEqual(notes.groups.first?.lines.map(\.text), ["an idea"])
        XCTAssertEqual(NotesPadMode.capture.captured("  ", into: notes), .capture)
    }

    // MARK: typing (a real window: keys go through `NSWindow.sendEvent`, as in CommandBarKeyTests)

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil); window = nil
    }

    private func host<V: SwiftUI.View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        return window
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

    private func key(_ characters: String, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        window.sendEvent(event)
    }

    private func press(_ text: String, in window: NSWindow) { for c in text.map(String.init) { key(c, in: window) } }
    private func pressReturn(_ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) { key("\r", keyCode: 36, modifiers, in: window) }

    func testTypingGoesIntoTheAddBoxAsSoonAsThePadOpensAndShiftReturnMakesANewLine() async throws {
        let dir = try TempDir()
        let notes = NotesModel(fileURL: dir.url.appendingPathComponent("notes.md"))
        let state = PadHarness.State()
        let window = host(PadHarness(notes: notes, state: state))
        await until { self.find(CommandBar.inputIdentifier, in: window.contentView).map { window.firstResponder === $0 } ?? false }
        let chat = try XCTUnwrap(find(CommandBar.inputIdentifier, in: window.contentView))
        XCTAssertTrue(window.firstResponder === chat, "the chat input has the focus before the pad opens")
        state.mode = .open
        await until { self.find(NoteField.addIdentifier, in: window.contentView).map { window.firstResponder === $0 } ?? false }
        let add = try XCTUnwrap(find(NoteField.addIdentifier, in: window.contentView))
        XCTAssertTrue(window.firstResponder === add, "the add box has the focus without a click")
        press("one", in: window)
        pressReturn(.shift, in: window)
        press("two", in: window)
        XCTAssertEqual(add.string, "one\ntwo")
        XCTAssertTrue(notes.groups.isEmpty, "Shift-Return adds nothing")
        pressReturn(in: window)
        XCTAssertEqual(notes.groups.first?.lines.map(\.text), ["one\ntwo"], "Return adds one note with both lines")
        await until { add.string.isEmpty }
        XCTAssertEqual(add.string, "")
        XCTAssertTrue(window.firstResponder === add, "the box keeps the focus for the next note")
        key("\u{1b}", keyCode: 53, in: window)
        XCTAssertEqual(state.mode, .closed, "Esc in the add box closes the pad")
        await until { window.firstResponder === chat }
        XCTAssertTrue(window.firstResponder === chat, "the chat input takes the focus back when the pad closes")
    }

    func testThePadDoesNotTakeTheFocusFromALineBeingEdited() async throws {
        let dir = try TempDir()
        let notes = NotesModel(fileURL: dir.url.appendingPathComponent("notes.md"))
        let state = PadHarness.State()
        state.editing = true
        let window = host(PadHarness(notes: notes, state: state))
        await until { self.find(NoteField.editIdentifier, in: window.contentView).map { window.firstResponder === $0 } ?? false }
        let edit = try XCTUnwrap(find(NoteField.editIdentifier, in: window.contentView))
        XCTAssertTrue(window.firstResponder === edit, "the edit box takes the focus when it appears")
        state.mode = .open
        await until { self.find(NoteField.addIdentifier, in: window.contentView) != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder === edit, "the line being edited keeps the focus")
        press("x", in: window)
        pressReturn(.shift, in: window)
        press("y", in: window)
        XCTAssertEqual(edit.string, "x\ny")
        pressReturn(in: window)
        XCTAssertEqual(state.saved, ["x\ny"], "Return saves the edit with its new line")
    }

    func testQuickCaptureTakesTheFocusAndShiftReturnMakesANewLine() async throws {
        var added: [String] = []
        let window = host(QuickCapture(projectName: "Agent Panel", onAdd: { added.append($0) }, onClose: {}))
        await until { self.find(NoteField.addIdentifier, in: window.contentView).map { window.firstResponder === $0 } ?? false }
        let box = try XCTUnwrap(find(NoteField.addIdentifier, in: window.contentView))
        XCTAssertTrue(window.firstResponder === box)
        press("one", in: window)
        pressReturn(.shift, in: window)
        press("two", in: window)
        XCTAssertEqual(added, [])
        pressReturn(in: window)
        XCTAssertEqual(added, ["one\ntwo"])
    }

    func testTheBoxGrowsToFiveLinesThenScrolls() async throws {
        let window = host(QuickCapture(projectName: "Agent Panel", onAdd: { _ in }, onClose: {}))
        await until { self.find(NoteField.addIdentifier, in: window.contentView) != nil }
        let box = try XCTUnwrap(find(NoteField.addIdentifier, in: window.contentView))
        let scroll = try XCTUnwrap(box.enclosingScrollView)
        let line = NoteField.lineHeight
        await until { scroll.frame.height > 0 }
        let one = scroll.frame.height
        XCTAssertEqual(one, line, accuracy: 2, "one line tall when empty")
        box.insertText("1\n2\n3", replacementRange: box.selectedRange())
        await until { scroll.frame.height > line * 2.5 }
        XCTAssertEqual(scroll.frame.height, line * 3, accuracy: 2, "three lines show three lines")
        box.insertText((4...10).map { "\n\($0)" }.joined(), replacementRange: box.selectedRange())
        await until { scroll.frame.height > line * 4.5 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scroll.frame.height, line * 5, accuracy: 2, "no taller than five lines")
        XCTAssertGreaterThan(box.frame.height, scroll.contentView.bounds.height, "the rest scrolls inside")
    }

    // MARK: ticking (a real window: clicks go through `NSWindow.sendEvent`)

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
    }

    private func doneTexts(_ notes: NotesModel) -> [String] { notes.groups.flatMap(\.lines).filter(\.done).map(\.text) }

    /// Where each note's checkbox sits, top to bottom: the window has no accessibility tree in tests, so this clicks down the checkbox
    /// column (the harness puts the pad 40 pt from the left, the box 16 pt into it) a point at a time. The first point that ticks a note
    /// is its box's top edge (the click is undone); the box's middle is 8 pt below it.
    private func checkboxes(in window: NSWindow, notes: NotesModel) async -> [(text: String, middle: NSPoint)] {
        let x: CGFloat = 40 + 16 + 8, height = window.contentView?.bounds.height ?? 0
        var found: [(text: String, middle: NSPoint)] = []
        var top: CGFloat = 30
        while top < 30 + 456 {
            let point = NSPoint(x: x, y: height - top)
            click(point, in: window)
            try? await Task.sleep(for: .milliseconds(5))
            if let text = doneTexts(notes).first {
                click(point, in: window)
                await until { self.doneTexts(notes).isEmpty }
                found.append((text, NSPoint(x: x, y: height - top - 8)))
                top += 18
            } else {
                top += 1
            }
        }
        return found
    }

    /// A pad with four notes under two days, the first of them two lines tall.
    private func padToTick() async throws -> (TempDir, NotesModel, NSWindow) {
        let dir = try TempDir()
        let today = NotesFile.day(Date()), yesterday = NotesFile.day(Date().addingTimeInterval(-86_400))
        try dir.write("notes.md", "## \(today)\n- [ ] one\n  one, second line\n- [ ] two\n\n## \(yesterday)\n- [ ] three\n- [ ] four\n")
        let notes = NotesModel(fileURL: dir.url.appendingPathComponent("notes.md"))
        let state = PadHarness.State()
        state.mode = .open
        let window = host(PadHarness(notes: notes, state: state))
        await until { self.find(NoteField.addIdentifier, in: window.contentView) != nil }
        try await Task.sleep(for: .milliseconds(200))
        return (dir, notes, window)
    }

    func testEveryNotesCheckboxTicksAndUnticks() async throws {
        let (dir, notes, window) = try await padToTick()
        let boxes = await checkboxes(in: window, notes: notes)
        XCTAssertEqual(boxes.map(\.text), ["one\none, second line", "two", "three", "four"])
        let before = try String(contentsOf: notes.fileURL, encoding: .utf8).components(separatedBy: "\n")
        for (text, middle) in boxes.dropFirst() + boxes.prefix(1) {
            click(middle, in: window)
            await until { self.doneTexts(notes) == [text] }
            XCTAssertEqual(doneTexts(notes), [text], "a click in the middle of the box ticks that note only")
            let after = try String(contentsOf: notes.fileURL, encoding: .utf8).components(separatedBy: "\n")
            let changed = zip(before, after).filter { $0 != $1 }
            XCTAssertEqual(after.count, before.count)
            XCTAssertEqual(changed.count, 1, "notes.md changes one line")
            XCTAssertTrue(changed.first.map { $1.hasPrefix("- [x] \(text.components(separatedBy: "\n")[0]) <!-- done ") } ?? false)
            click(middle, in: window)
            await until { self.doneTexts(notes).isEmpty }
            XCTAssertEqual(doneTexts(notes), [], "a second click unticks it")
            XCTAssertEqual(try String(contentsOf: notes.fileURL, encoding: .utf8).components(separatedBy: "\n"), before)
        }
        _ = dir
    }

    func testALowerNoteTicksAfterTheFileIsWrittenFromOutside() async throws {
        let (dir, notes, window) = try await padToTick()
        let today = NotesFile.day(Date()), yesterday = NotesFile.day(Date().addingTimeInterval(-86_400))
        try "## \(today)\n- [ ] new by hand\n- [ ] one\n  one, second line\n- [ ] two\n\n## \(yesterday)\n- [ ] three\n- [ ] four\n"
            .write(to: notes.fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: notes.fileURL.path)
        XCTAssertTrue(notes.reloadIfChanged())
        try await Task.sleep(for: .milliseconds(200))
        let boxes = await checkboxes(in: window, notes: notes)
        XCTAssertEqual(boxes.map(\.text), ["new by hand", "one\none, second line", "two", "three", "four"])
        guard let three = boxes.first(where: { $0.text == "three" }) else { return }
        click(three.middle, in: window)
        await until { self.doneTexts(notes) == ["three"] }
        XCTAssertEqual(doneTexts(notes), ["three"])
        XCTAssertTrue(try String(contentsOf: notes.fileURL, encoding: .utf8).contains("- [x] three <!-- done"))
        _ = dir
    }

    // MARK: place

    func testPadStartsAboveTheRailIcon() {
        let place = NotesPadPlace()
        XCTAssertEqual(place.size, CGSize(width: 340, height: 456))
        XCTAssertEqual(place.origin(in: CGSize(width: 1400, height: 788)), CGPoint(x: 80, y: 788 - 16 - 456))
        var big = place; big.big = true
        XCTAssertEqual(big.size, CGSize(width: 560, height: 708))
    }

    func testMovingKeepsThePadInsideTheWindow() {
        let bounds = CGSize(width: 1400, height: 788)
        var place = NotesPadPlace()
        place.move(by: CGSize(width: 300, height: -200), in: bounds)
        XCTAssertEqual(place.origin(in: bounds), CGPoint(x: 380, y: 116))
        place.move(by: CGSize(width: 5000, height: -5000), in: bounds)
        XCTAssertEqual(place.origin(in: bounds), CGPoint(x: 1400 - 340, y: 0))
        // A smaller window pulls a pad that would fall outside back in.
        XCTAssertEqual(place.origin(in: CGSize(width: 900, height: 500)), CGPoint(x: 900 - 340, y: 0))
    }

    func testPlaceAndSizeAreRemembered() {
        let d = defaults()
        var place = NotesPadPlace()
        place.move(by: CGSize(width: 120, height: -40), in: CGSize(width: 1400, height: 788))
        place.big = true
        place.save(d)
        XCTAssertEqual(NotesPadPlace.load(d), place)
        XCTAssertEqual(NotesPadPlace.load(defaults()), NotesPadPlace())
    }

    // MARK: snapshots

    private func sampleNotes() throws -> (TempDir, NotesModel) {
        let dir = try TempDir()
        try dir.write("notes.md", """
        ## \(NotesFile.day(Date()))
        - [ ] Tasks: show how many cards each section has
        - [ ] Ask the PM: install stable automatically after a round merges?
        - [x] Notes panel: compare A and B <!-- done \(NotesFile.day(Date())) -->
        ## \(NotesFile.day(Date().addingTimeInterval(-86_400)))
        - [ ] Team settings: thinking level, reply language, status line
        - [ ] Chat: type a card id (N119) and show it as a link <!-- task N124 -->
        a hand-written line the pad keeps as it is
        """)
        return (dir, NotesModel(fileURL: dir.url.appendingPathComponent("notes.md")))
    }

    private func render<V: SwiftUI.View>(_ view: V, _ size: CGSize, name: String) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    func testPadWithAMultiLineNoteRendersInLightAndDark() throws {
        let dir = try TempDir()
        try dir.write("notes.md", "## \(NotesFile.day(Date()))\n- [ ] Notes pad: a note can have\n  more than one line\n  and stays one item\n- [ ] a one-line note\n")
        let notes = NotesModel(fileURL: dir.url.appendingPathComponent("notes.md"))
        XCTAssertEqual(notes.groups.first?.lines.count, 2)
        let size = CGSize(width: 1000, height: 788)
        let light = try render(NotesPadPreview(notes: notes, projectName: "Agent Panel", mode: .open, place: NotesPadPlace()).environment(\.colorScheme, .light),
                               size, name: "notes-pad-multiline-light")
        let dark = try render(NotesPadPreview(notes: notes, projectName: "Agent Panel", mode: .open, place: NotesPadPlace()).environment(\.colorScheme, .dark),
                              size, name: "notes-pad-multiline-dark")
        // The app draws one palette (Tok) in both appearances; both are rendered so either system setting is covered.
        for rep in [light, dark] { XCTAssertEqual(rep.pixelsWide, 2000) }
    }

    func testPadRendersNormalBiggerAndQuickCapture() throws {
        let (dir, notes) = try sampleNotes()
        _ = dir
        let size = CGSize(width: 1000, height: 788)
        let normal = try render(NotesPadPreview(notes: notes, projectName: "Agent Panel", mode: .open, place: NotesPadPlace()), size, name: "notes-pad")
        var bigPlace = NotesPadPlace(); bigPlace.big = true
        let big = try render(NotesPadPreview(notes: notes, projectName: "Agent Panel", mode: .open, place: bigPlace), size, name: "notes-pad-big")
        let capture = try render(NotesPadPreview(notes: notes, projectName: "Agent Panel", mode: .capture, place: NotesPadPlace()), size, name: "notes-capture")
        for rep in [normal, big, capture] { XCTAssertEqual(rep.pixelsWide, 2000) }
        // The pad's surface is drawn where the pad sits (probes in its side padding), and only there: the bigger pad reaches higher.
        func color(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? { rep.colorAt(x: x * 2, y: y * 2) }
        func isPad(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool { color(rep, x, y) != color(rep, 990, 10) }
        XCTAssertTrue(isPad(normal, 410, 500))
        XCTAssertFalse(isPad(normal, 410, 200))
        XCTAssertTrue(isPad(big, 630, 300))
        XCTAssertFalse(isPad(capture, 410, 500))
        XCTAssertTrue(isPad(capture, 371, 770))
    }

    func testRailShowsTheNotesButtonWithItsCount() throws {
        let plain = try render(Rail(screen: .tasks, onSelect: { _ in }), CGSize(width: 64, height: 600), name: "rail-plain")
        let withNotes = try render(Rail(screen: .tasks, notes: RailNotes(open: 4, active: false, onTap: {}), onSelect: { _ in }), CGSize(width: 64, height: 600), name: "rail-notes")
        XCTAssertNotEqual(plain.representation(using: .png, properties: [:]), withNotes.representation(using: .png, properties: [:]))
    }
}

/// The chat input above, the pad (and a line edit box) shown or hidden by the test, the way the window stacks them.
private struct PadHarness: View {
    @Observable @MainActor final class State {
        var mode = NotesPadMode.closed
        var editing = false
        var saved: [String] = []
    }

    let notes: NotesModel
    let state: State
    @SwiftUI.State private var chat = ""
    @SwiftUI.State private var edit = ""

    var body: some View {
        VStack(spacing: 0) {
            ChatInput(text: $chat, returnSends: true, maxHeight: 80, focusRequest: 0, onSend: {}).frame(height: 30)
            if state.editing {
                NoteField(text: $edit, identifier: NoteField.editIdentifier, takesFocus: .always, onSubmit: { state.saved.append(edit) }).frame(height: 60)
            }
            if state.mode == .open {
                NotesPad(notes: notes, projectName: "Agent Panel", projects: [], onPickProject: { _ in }, big: false, onToggleBig: {},
                         onClose: { state.mode = .closed }, actions: NoteActions(makeTask: nil, sendToPM: nil), onDrag: { _ in }, onDragEnd: { _ in })
                    .frame(width: 340, height: 456)
            }
            Spacer(minLength: 0)
        }
    }
}
