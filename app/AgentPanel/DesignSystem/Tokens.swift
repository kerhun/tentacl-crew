import SwiftUI

/// Design tokens. Values come from the approved panel mock (docs/design/panel-b-v2.html).
/// Orange (`ask`) is reserved for "waiting for your decision"; do not use it for anything else.
enum Tok {
    enum Hex {
        static let bg: UInt32 = 0x14161B
        static let rail: UInt32 = 0x101216
        static let pane: UInt32 = 0x1A1D23
        /// The Tasks list column (design B, N142).
        static let list: UInt32 = 0x181A20
        static let raise: UInt32 = 0x21252D
        static let line: UInt32 = 0x2A2F39
        static let ink: UInt32 = 0xE9ECF2
        static let ink2: UInt32 = 0xA2A9B8
        static let ink3: UInt32 = 0x8A92A3
        static let go: UInt32 = 0x4CC38A
        /// Text on a green button (Approve).
        static let goInk: UInt32 = 0x08130D
        static let work: UInt32 = 0x5AA2F0
        static let wait: UInt32 = 0xE6B450
        static let stop: UInt32 = 0xEF6B66
        static let ask: UInt32 = 0xFF5A36
        static let askInk: UInt32 = 0x1B0C07
        /// "Waiting for your decision" as text (a row's "review", the Your review step); the bars and dots stay `ask`.
        static let askText: UInt32 = 0xFF8A6E
        /// Waiting for you (N182, design waiting/Final): one colour per kind of item, on its chip and first button. Git suggestions use `ink2`.
        static let waitQuestion: UInt32 = 0xF2A07B
        static let waitReview: UInt32 = 0x7FB0FF
        static let waitFix: UInt32 = 0xE6C35C
        static let waitStart: UInt32 = 0x5CC8A8
        /// The user's own messages in the chat (N194): a soft violet, apart in hue from the status colours; never a status.
        static let you: UInt32 = 0xA78BFA
    }

    static let bg = dynamic(\.bg)
    static let rail = dynamic(\.rail)
    static let pane = dynamic(\.pane)
    static let list = dynamic(\.list)
    static let raise = dynamic(\.raise)
    static let line = dynamic(\.line)
    static let ink = dynamic(\.ink)
    static let ink2 = dynamic(\.ink2)
    static let ink3 = dynamic(\.ink3)
    static let go = dynamic(\.go)
    static let goInk = dynamic(\.goInk)
    static let work = dynamic(\.work)
    static let wait = dynamic(\.wait)
    static let stop = dynamic(\.stop)
    static let ask = dynamic(\.ask)
    static let askInk = dynamic(\.askInk)
    static let askText = dynamic(\.askText)
    static let you = dynamic(\.you)
    static let waitQuestion = dynamic(\.waitQuestion)
    static let waitReview = dynamic(\.waitReview)
    static let waitFix = dynamic(\.waitFix)
    static let waitStart = dynamic(\.waitStart)
    static let code = dynamic(\.code)
    static let chrome = dynamic(\.chrome)
    static let chartA = dynamic(\.chartA)
    static let chartAHover = dynamic(\.chartAHover)
    static let chartB = dynamic(\.chartB)
    static let tintViolet = dynamic(\.tintViolet)
    static let tintTeal = dynamic(\.tintTeal)
    static let claude = dynamic(\.claude)
    static let dotBlue = dynamic(\.dotBlue)
    /// The user's bubble: `you` over the background (ink on it is about 10.9:1 on the pane), with a `you` border.
    static let youFillOpacity = 0.16
    static let youFill = you.opacity(youFillOpacity)
    static let youBorder = you.opacity(0.35)

    static let radius: CGFloat = 10

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        /// The page edge of every screen but Dashboard and Tasks: from the rail to the content, and from the top bar to the title (N222).
        static let page: CGFloat = 28
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        static let small = SwiftUI.Font.system(size: 11)
        static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
    }
}

extension View {
    /// The screen's outer padding: `Tok.Space.page` on the given edges (all by default). Inner card padding stays its own.
    func pageMargin(_ edges: Edge.Set = .all) -> some View { padding(edges, Tok.Space.page) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
