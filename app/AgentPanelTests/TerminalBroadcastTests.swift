import XCTest
@testable import AgentPanel

/// Broadcast on the Terminals screen (N271): which panes it reaches, the keys it copies, the stop rules.
@MainActor
final class TerminalBroadcastTests: XCTestCase {
    private let panes = ["my-shell-1", "my-shell-2", "w4:p1", "my-shell-3"]

    private func started() -> TerminalBroadcast {
        var b = TerminalBroadcast()
        b.start(panes: panes)
        return b
    }

    func testStartPicksEveryShellPaneAndNoAgent() {
        let b = started()
        XCTAssertEqual(b.picked, ["my-shell-1", "my-shell-2", "my-shell-3"])
        XCTAssertFalse(b.isPicked("w4:p1"))
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(TerminalBroadcast.banner(count: b.count), "Typing into 3 panes")
    }

    func testOffPicksNothingAndReachesNobody() {
        let b = TerminalBroadcast()
        XCTAssertFalse(b.isPicked("my-shell-1"))
        XCTAssertEqual(b.targets(from: "my-shell-1", panes: panes), [])
    }

    func testAPaneCanBeUntickedAndTickedAgain() {
        var b = started()
        XCTAssertEqual(b.toggle("my-shell-2"), .unpicked)
        XCTAssertEqual(b.targets(from: "my-shell-1", panes: panes), ["my-shell-3"])
        XCTAssertEqual(b.toggle("my-shell-2"), .picked)
        XCTAssertEqual(b.targets(from: "my-shell-1", panes: panes), ["my-shell-2", "my-shell-3"])
    }

    func testAnAgentPaneNeedsAnExplicitYesAskedOnce() {
        var b = started()
        XCTAssertEqual(b.toggle("w4:p1"), .needsAgentConsent)
        XCTAssertFalse(b.isPicked("w4:p1"), "asking does not pick it")
        XCTAssertEqual(b.targets(from: "my-shell-1", panes: panes), ["my-shell-2", "my-shell-3"], "still no agent")
        b.allowAgents(andPick: "w4:p1")
        XCTAssertTrue(b.isPicked("w4:p1"))
        XCTAssertEqual(b.targets(from: "my-shell-1", panes: panes), ["my-shell-2", "w4:p1", "my-shell-3"])
        XCTAssertEqual(b.toggle("w4:p1"), .unpicked)
        XCTAssertEqual(b.toggle("w4:p1"), .picked, "asked once: no second question")
    }

    func testTypingIntoAnUnpickedOrAgentPaneIsNotBroadcast() {
        var b = started()
        XCTAssertEqual(b.targets(from: "w4:p1", panes: panes), [], "an agent pane that is not picked does not broadcast")
        _ = b.toggle("my-shell-1")
        XCTAssertEqual(b.targets(from: "my-shell-1", panes: panes), [])
    }

    func testTheSourceNeverGetsItsOwnInputBack() {
        XCTAssertFalse(started().targets(from: "my-shell-2", panes: panes).contains("my-shell-2"))
    }

    func testPanesThatLeaveDropOutAndNewShellsAreTickedOnce() {
        var b = started()
        _ = b.toggle("my-shell-2")
        b.reconcile(panes: ["my-shell-1", "my-shell-2", "my-shell-4", "w9:p1"])
        XCTAssertEqual(b.picked, ["my-shell-1", "my-shell-4"], "my-shell-3 left, my-shell-2 stays unticked, the new shell is ticked, the new agent is not")
        b.reconcile(panes: ["my-shell-1", "my-shell-2", "my-shell-4", "w9:p1"])
        XCTAssertEqual(b.picked, ["my-shell-1", "my-shell-4"], "a second pass changes nothing")
    }

    func testStopClearsEverythingIncludingTheAgentYes() {
        var b = started()
        b.allowAgents(andPick: "w4:p1")
        b.stop()
        XCTAssertFalse(b.isOn)
        XCTAssertEqual(b.picked, [])
        b.start(panes: panes)
        XCTAssertEqual(b.toggle("w4:p1"), .needsAgentConsent, "asks again in the next broadcast")
    }

    func testTheBannerAsksForASecondPaneWhenOnlyOneIsPicked() {
        XCTAssertTrue(TerminalBroadcast.banner(count: 1).contains("second pane"))
        XCTAssertEqual(TerminalBroadcast.banner(count: 2), "Typing into 2 panes")
    }

    func testEscapeTwiceStops() {
        var t = TerminalEscapeTracker()
        let now = Date()
        XCTAssertFalse(t.press(at: now))
        XCTAssertTrue(t.press(at: now.addingTimeInterval(0.3)))
        XCTAssertFalse(t.press(at: now.addingTimeInterval(0.4)), "a pair is used up")
        XCTAssertFalse(t.press(at: now.addingTimeInterval(2)))
        XCTAssertFalse(t.press(at: now.addingTimeInterval(3)), "too slow")
        t.reset()
        XCTAssertFalse(t.press(at: now.addingTimeInterval(3.1)))
    }

    // MARK: keys

    private func keys(_ code: UInt16, _ chars: String? = nil, plain: String? = nil, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) -> TerminalBroadcastKeys.Output {
        TerminalBroadcastKeys.output(keyCode: code, characters: chars, plain: plain ?? chars, command: command, control: control, option: option, shift: shift)
    }

    func testKeysBecomeWhatTheTerminalSends() {
        XCTAssertEqual(keys(0, "a"), .bytes([0x61]))
        XCTAssertEqual(keys(0, "é"), .bytes(Array("é".utf8)))
        XCTAssertEqual(keys(36, "\r"), .bytes([0x0D]))
        XCTAssertEqual(keys(51, "\u{7F}"), .bytes([0x7F]))
        XCTAssertEqual(keys(48, "\t"), .bytes([0x09]))
        XCTAssertEqual(keys(48, "\t", shift: true), .bytes([0x1B, 0x5B, 0x5A]))
        XCTAssertEqual(keys(53), .bytes([0x1B]))
        XCTAssertEqual(keys(126, "\u{F700}"), .bytes([0x1B, 0x5B, 0x41]))
        XCTAssertEqual(keys(123, "\u{F702}"), .bytes([0x1B, 0x5B, 0x44]))
        XCTAssertEqual(keys(8, "\u{03}", plain: "c", control: true), .bytes([0x03]))
        XCTAssertEqual(keys(2, "\u{04}", plain: "d", control: true), .bytes([0x04]))
        XCTAssertEqual(keys(11, "∫", plain: "b", option: true), .bytes([0x1B, 0x62]), "option sends Esc before the key")
    }

    func testShortcutsAndFunctionKeysAreNotCopied() {
        XCTAssertEqual(keys(8, "c", command: true), .none)
        XCTAssertEqual(keys(0, "a", command: true), .none)
        XCTAssertEqual(keys(122, "\u{F704}"), .none, "F1")
        XCTAssertEqual(keys(9, "v", command: true), .paste)
        XCTAssertEqual(keys(9, "v", command: true, option: true), .none)
    }

    func testPastedLinesEndWithReturnLikeATerminalPaste() {
        XCTAssertEqual(TerminalBroadcastKeys.pasteBytes("ls\npwd\r\n"), Array("ls\rpwd\r".utf8))
    }

    // MARK: fan-out

    @MainActor private final class FakeWriter: TerminalWriting {
        private(set) var writes: [(String, Data)] = []
        var delayFirst = false
        func write(id: String, data: Data) async throws {
            if delayFirst && writes.isEmpty { try? await Task.sleep(for: .milliseconds(80)) }
            writes.append((id, data))
        }
    }

    func testInputFansOutToEveryPickedSessionInOrder() async {
        let writer = FakeWriter()
        writer.delayFirst = true
        let router = TerminalBroadcastRouter(writer: writer)
        let b = started()
        let targets = b.targets(from: "my-shell-1", panes: panes)
        router.send(Array("l".utf8), to: targets)
        router.send(Array("s".utf8), to: targets)
        await router.settle()
        XCTAssertEqual(writer.writes.filter { $0.0 == "my-shell-2" }.map { String(decoding: $0.1, as: UTF8.self) }, ["l", "s"])
        XCTAssertEqual(writer.writes.filter { $0.0 == "my-shell-3" }.map { String(decoding: $0.1, as: UTF8.self) }, ["l", "s"])
        XCTAssertFalse(writer.writes.contains { $0.0 == "my-shell-1" || $0.0 == "w4:p1" }, "not the source, not an agent")
    }

    func testNothingIsWrittenWithoutTargetsOrBytes() async {
        let writer = FakeWriter()
        let router = TerminalBroadcastRouter(writer: writer)
        router.send([], to: ["my-shell-2"])
        router.send([0x61], to: [])
        await router.settle()
        XCTAssertTrue(writer.writes.isEmpty)
    }
}
