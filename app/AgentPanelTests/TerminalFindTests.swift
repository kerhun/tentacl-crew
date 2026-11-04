import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import AgentPanel

/// ⌘F find in a live terminal (N252): SwiftTerm's search over the scrollback, the count, wrap-around, focus. No daemon needed.
@MainActor
final class TerminalFindTests: XCTestCase {
    private var window: NSWindow!
    private var view: LiveTerminalNSView!

    override func setUp() async throws {
        view = LiveTerminalNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: view.frame)
        root.addSubview(view)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    override func tearDown() async throws { view.find.close(); window.orderOut(nil); window = nil; view = nil }

    private func feed(_ lines: [String]) { view.feedQuiet(Array((lines.joined(separator: "\r\n") + "\r\n").utf8)) }
    private func lines(_ n: Int, _ make: (Int) -> String) -> [String] { (0..<n).map(make) }

    private func search(_ q: String) {
        view.find.open()
        view.find.query = q
        view.find.queryChanged()
    }

    func testCountsMatchesInTheScrollbackNotOnlyTheScreen() {
        feed(lines(200) { $0 % 10 == 0 ? "line \($0) needle" : "line \($0)" })
        XCTAssertGreaterThan(view.scrollPosition, 0.9)
        search("needle")
        XCTAssertEqual(view.find.total, 20)
        XCTAssertEqual(view.find.index, 20, "starts at the newest match")
        XCTAssertEqual(view.find.countText, "20 of 20")
        view.find.step(forward: false)
        XCTAssertEqual(view.find.index, 19)
    }

    func testPreviousAndNextWrapAround() {
        feed(["a hit", "b", "c hit", "d hit", "e"])
        search("hit")
        XCTAssertEqual(view.find.total, 3)
        XCTAssertEqual(view.find.index, 3)
        view.find.step(forward: true)
        XCTAssertEqual(view.find.index, 1, "next after the last wraps to the first")
        view.find.step(forward: false)
        XCTAssertEqual(view.find.index, 3, "previous before the first wraps to the last")
        view.find.step(forward: false)
        XCTAssertEqual(view.find.index, 2)
    }

    func testTheCurrentMatchScrollsIntoView() {
        feed(["first needle"] + lines(150) { "filler \($0)" })
        search("needle")
        view.find.step(forward: true)   // wraps to the only match, far up in the scrollback
        XCTAssertLessThan(view.scrollPosition, 0.2)
    }

    func testWideAndTurkishCharacters() {
        feed(["çalışma ağacı", "日本語のテスト 検索", "ışık ve şeker", "中文 検索 again"])
        search("検索")
        XCTAssertEqual(view.find.total, 2)
        search("ağacı")
        XCTAssertEqual(view.find.total, 1)
        search("şeker")
        XCTAssertEqual(view.find.total, 1)
    }

    func testAMatchSplitByAWrapIsFound() {
        let cols = view.columns
        feed([String(repeating: "x", count: cols - 3) + "needle"])   // wraps inside the word
        search("needle")
        XCTAssertEqual(view.find.total, 1)
    }

    func testCaseToggle() {
        feed(["Alpha alpha ALPHA"])
        search("alpha")
        XCTAssertEqual(view.find.total, 3)
        view.find.caseSensitive = true
        view.find.queryChanged()
        XCTAssertEqual(view.find.total, 1)
    }

    func testNewOutputUpdatesTheCountWithoutMovingTheCurrentMatch() async throws {
        feed(["one hit", "two"] + lines(60) { "pad \($0)" })
        search("hit")
        view.find.step(forward: false)
        XCTAssertEqual(view.find.total, 1)
        let position = view.scrollPosition
        feed(["another hit", "and another hit"])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(view.find.total, 3)
        XCTAssertGreaterThan(view.find.index, 0)
        XCTAssertEqual(view.scrollPosition, position, accuracy: 0.05, "the view stays where the match is")
    }

    func testCloseGivesTheKeyboardBackAndKeepsTheBottom() {
        feed(lines(120) { "row \($0)" })
        view.find.open()
        XCTAssertEqual(view.subviews.filter { $0 is NSHostingView<TerminalFindBar> }.count, 1)
        XCTAssertTrue(view.find.isOpen)
        window.makeFirstResponder(nil)
        view.find.close()
        XCTAssertFalse(view.find.isOpen)
        XCTAssertTrue(view.subviews.filter { $0 is NSHostingView<TerminalFindBar> }.isEmpty)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.001, "it was at the bottom before")
    }

    func testCloseDoesNotJumpToTheBottomWhenItWasScrolledUp() {
        feed(lines(120) { "row \($0)" })
        view.scrollTo(row: 0)
        let before = view.scrollPosition
        XCTAssertLessThan(before, 0.1)
        view.find.open()
        view.find.close()
        XCTAssertEqual(view.scrollPosition, before, accuracy: 0.001)
    }

    private func press(_ key: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 3)!
    }

    func testCommandFOpensOnlyInTheFocusedTerminalAndGStepsInIt() {
        feed(["a hit", "b hit", "c"])
        let other = NSTextField(frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        XCTAssertFalse(view.findKey(press("f")), "the keyboard is elsewhere: ⌘F keeps its other meaning")
        XCTAssertFalse(view.find.isOpen)
        window.makeFirstResponder(view)
        XCTAssertFalse(view.findKey(press("f", [.command, .shift, .option])))
        XCTAssertFalse(view.findKey(press("g")), "⌘G does nothing while the bar is closed")
        XCTAssertTrue(view.findKey(press("f")))
        XCTAssertTrue(view.find.isOpen)
        view.find.query = "hit"; view.find.queryChanged()
        XCTAssertEqual(view.find.index, 2)
        XCTAssertTrue(view.findKey(press("g")))
        XCTAssertEqual(view.find.index, 1)
        XCTAssertTrue(view.findKey(press("g", [.command, .shift])))
        XCTAssertEqual(view.find.index, 2)
    }

    func testSnapshotWithTheBarAndAHighlightedMatch() throws {
        TerminalAppearance().apply(to: view)
        feed(lines(40) { $0 == 37 ? "build finished: 1774 tests, 0 failures" : "log line \($0): compiling module \($0 % 7)" })
        search("tests")
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        view.needsDisplay = true
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // The test host's offscreen window does not paint the terminal's glyphs: the capture shows the bar and the dark terminal only.
        let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("N252-find.png"))
        }
    }
}
