import XCTest
import AppKit
@testable import AgentPanel

@MainActor
final class ChatSendDelayTests: XCTestCase {
    private let short: Duration = .milliseconds(80)

    func testTheHoldIsThreeSeconds() {
        XCTAssertEqual(ChatSendDelay.hold, .seconds(3))
        XCTAssertEqual(ChatSendDelay.seconds, 3)
    }

    func testAHeldMessageIsDeliveredOnceWhenTheTimeRunsOut() async throws {
        let chat = ChatModel()
        var delivered: [String] = []
        // Waits for the delivery itself (up to 5 s), so a loaded machine cannot make it late.
        let sent = expectation(description: "delivered")
        chat.hold(text: "hello", images: [], stored: [], delay: short) { delivered.append($0.text); sent.fulfill() }
        XCTAssertEqual(chat.held?.text, "hello")
        XCTAssertEqual(delivered, [], "nothing goes to the agent during the hold")
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(delivered, ["hello"])
        XCTAssertNil(chat.held)
        chat.release()
        XCTAssertEqual(delivered, ["hello"], "never delivered twice")
    }

    func testUndoTakesTheMessageBackAndNothingIsDelivered() async throws {
        let chat = ChatModel()
        var delivered = 0
        chat.hold(text: "oops", images: [], stored: [], delay: short) { _ in delivered += 1 }
        let back = chat.takeBack(editing: false)
        XCTAssertEqual(back?.text, "oops")
        XCTAssertNil(chat.held)
        XCTAssertFalse(chat.editing)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(delivered, 0)
    }

    func testEditTakesItBackMarkedEditingAndTheNextSendStartsANewHold() {
        let chat = ChatModel()
        var delivered: [String] = []
        chat.hold(text: "draft", images: [], stored: [], delay: .seconds(60)) { delivered.append($0.text) }
        XCTAssertEqual(chat.takeBack(editing: true)?.text, "draft")
        XCTAssertTrue(chat.editing)
        chat.hold(text: "draft, fixed", images: [], stored: [], delay: .seconds(60)) { delivered.append($0.text) }
        XCTAssertFalse(chat.editing)
        XCTAssertEqual(chat.held?.text, "draft, fixed")
        XCTAssertEqual(delivered, [], "the new hold waits again")
        chat.release()
    }

    func testSendingAnotherDeliversTheHeldOneFirst() {
        let chat = ChatModel()
        var delivered: [String] = []
        chat.hold(text: "one", images: [], stored: [], delay: .seconds(60)) { delivered.append($0.text) }
        chat.hold(text: "two", images: [], stored: [], delay: .seconds(60)) { delivered.append($0.text) }
        XCTAssertEqual(delivered, ["one"])
        XCTAssertEqual(chat.held?.text, "two")
        chat.release()
        XCTAssertEqual(delivered, ["one", "two"], "order kept")
    }

    func testReleaseDeliversAtOnceAndOnlyOnce() async throws {
        let chat = ChatModel()
        var delivered = 0
        chat.release()
        chat.hold(text: "leaving", images: [], stored: [], delay: short) { _ in delivered += 1 }
        chat.release()
        XCTAssertEqual(delivered, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(delivered, 1, "the timer does not send it again")
    }

    func testTheCountdownNeverShowsZero() {
        let start = Date(timeIntervalSince1970: 1000)
        let held = HeldMessage(text: "x", images: [], stored: [], deadline: start.addingTimeInterval(5))
        XCTAssertEqual(held.secondsLeft(now: start), 5)
        XCTAssertEqual(held.secondsLeft(now: start.addingTimeInterval(0.2)), 5)
        XCTAssertEqual(held.secondsLeft(now: start.addingTimeInterval(4.5)), 1)
        XCTAssertEqual(held.secondsLeft(now: start.addingTimeInterval(9)), 1)
        XCTAssertEqual(HeldMessage.mark(seconds: 3), "Sending in 3 s…")
    }

    func testUndoPutsTheTextBeforeWhatWasTypedSince() {
        XCTAssertEqual(CommandBar.restoredText("held", current: ""), "held")
        XCTAssertEqual(CommandBar.restoredText("held", current: "new"), "held\nnew")
        XCTAssertEqual(CommandBar.restoredText("", current: "new"), "new")
    }

    func testReturnFollowsTheToggle() {
        XCTAssertEqual(CommandBar.returnKey(returnSends: false, modifiers: []), .pass, "off: the field keeps today's behaviour (a new line)")
        XCTAssertEqual(CommandBar.returnKey(returnSends: false, modifiers: .shift), .pass)
        XCTAssertEqual(CommandBar.returnKey(returnSends: true, modifiers: []), .send)
        XCTAssertEqual(CommandBar.returnKey(returnSends: true, modifiers: [.capsLock]), .send)
        XCTAssertEqual(CommandBar.returnKey(returnSends: true, modifiers: .shift), .newline)
        XCTAssertEqual(CommandBar.returnKey(returnSends: true, modifiers: .command), .pass, "⌘Return is the Send button's shortcut")
        XCTAssertEqual(CommandBar.returnKey(returnSends: false, modifiers: .command), .pass)
        XCTAssertEqual(CommandBar.returnKey(returnSends: true, modifiers: .option), .pass)
    }

    func testTheSendTooltipNamesTheShortcut() {
        XCTAssertEqual(CommandBar.sendHelp(returnSends: false), "Send to the selected agent (⌘↵)")
        XCTAssertEqual(CommandBar.sendHelp(returnSends: true), "Send to the selected agent (↵; ⇧↵ for a new line)")
        XCTAssertEqual(CommandBar.returnSendsKey, "chatReturnSends")
    }

    func testCommandBoxWithAHeldMessageAndTheToggleRenders() async throws {
        let model = await DemoSupport.makeModel()
        let session = model.chats.session(project: model.selectedProjectID ?? "", pane: "")
        session.chat.hold(text: "Please start N8 next.", images: [], stored: [], delay: .seconds(60)) { _ in }
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: CommandBar.returnSendsKey)
        defaults.set(true, forKey: CommandBar.returnSendsKey)
        defer { defaults.set(before, forKey: CommandBar.returnSendsKey); session.chat.takeBack(editing: false) }
        let data = try XCTUnwrap(SnapshotRenderer.render(view: CommandBar(model: model), size: CGSize(width: 340, height: 520)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("command-box-held.png")) }
    }
}
