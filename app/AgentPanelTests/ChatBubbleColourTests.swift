import XCTest
import SwiftUI
@testable import AgentPanel

/// The user's own messages have their own colour (N194): a violet bubble, the panel's lines stay neutral.
@MainActor
final class ChatBubbleColourTests: XCTestCase {
    private static let entries = [
        ChatEntry(id: "1", kind: .agent, text: "N4 is ready for review. The tests pass (1774/0).", time: nil),
        ChatEntry(id: "2", kind: .user, text: "Thanks, I'll look at it now.", time: nil),
        ChatEntry(id: "3", kind: .panel, text: "Panel: started N5.", time: nil),
        ChatEntry(id: "4", kind: .user, text: "And N7, please.", time: nil, pending: .failed("That agent is no longer running; pick another one.")),
    ]
    private static let held = HeldMessage(text: "Then merge N4.", images: [], stored: [], deadline: .now.addingTimeInterval(5))

    private func thread(fill: Color = Tok.youFill) -> some View {
        ChatThread(place: ChatPlace(), entries: Self.entries, agentLabel: "PM", working: false, held: Self.held, onRetry: { _ in }, youFill: fill)
            .environment(\.snapshotMode, true).padding(12).background(Tok.pane)
    }

    /// WCAG contrast of two sRGB colours.
    private static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func lum(_ c: [Double]) -> Double {
            let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func rgb(_ hex: UInt32) -> [Double] { [Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255] }

    func testTheTextOnTheUserBubbleIsReadableOnEveryBackground() {
        XCTAssertEqual(Tok.Hex.you, 0xA78BFA)
        for back in [Tok.Hex.pane, Tok.Hex.bg] {
            for alpha in [0.12, Tok.youFillOpacity, 0.20] {
                let fill = zip(Self.rgb(Tok.Hex.you), Self.rgb(back)).map { alpha * $0 + (1 - alpha) * $1 }
                XCTAssertGreaterThanOrEqual(Self.contrast(Self.rgb(Tok.Hex.ink), fill), 4.5, "ink on \(alpha) violet over \(String(back, radix: 16))")
            }
        }
    }

    func testThreadWithAllKindsOfMessagesRenders() throws {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: thread(), size: CGSize(width: 340, height: 420)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N194-chat.png")) }
    }

    func testFillStrengthsSideBySideRender() throws {
        let view = HStack(alignment: .top, spacing: 0) {
            ForEach([0.12, 0.20], id: \.self) { alpha in
                VStack(alignment: .leading, spacing: 0) {
                    Text("Fill \(Int(alpha * 100))%").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).padding([.top, .horizontal], 12)
                    self.thread(fill: Tok.you.opacity(alpha))
                }
                .frame(width: 340).background(Tok.pane)
            }
        }
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 680, height: 450)))
        XCTAssertGreaterThan(data.count, 8_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N194-variants.png")) }
    }
}
