import XCTest
@testable import AgentPanel

@MainActor
final class ChatPreviousThreadTests: XCTestCase {
    func testStartingANewThreadKeepsTheOldOneAsPrevious() {
        let s = ChatSession(chat: ChatModel())
        let old = [ChatEntry(id: "1", kind: .user, text: "hi", time: nil), ChatEntry(id: "2", kind: .agent, text: "hello", time: nil)]
        s.startNewThread(keeping: old)
        XCTAssertEqual(s.previous.map(\.text), ["hi", "hello"])
        s.startNewThread(keeping: [ChatEntry(id: "3", kind: .user, text: "again", time: nil)])
        XCTAssertEqual(s.previous.map(\.text), ["hi", "hello", "again"], "earlier conversations stay readable")
    }

    func testAnEmptyThreadAddsNothing() {
        let s = ChatSession(chat: ChatModel())
        s.startNewThread(keeping: [])
        XCTAssertTrue(s.previous.isEmpty)
    }
}
