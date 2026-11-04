import Foundation
import SwiftTerm

/// The screen as bytes (N237): what a client feeds a fresh terminal of the same size (after RIS) to show what the headless terminal shows
/// now, instead of replaying the raw output ring, which a full-screen program drew at other sizes. Scrollback of the normal buffer first
/// (colors and attributes kept), the alternate screen when it is active, the cursor, and the input modes the program switched on.
enum ScreenSnapshot {
    /// Scrollback rows sent with the screen.
    static let scrollbackRows = 1000

    static func bytes(of terminal: Terminal) -> [UInt8] {
        var out: [UInt8] = []
        let normal = terminal.contentSnapshot(region: .history(maximumScrollbackRows: scrollbackRows), buffer: .normal)
        let state = normal.inputState
        emit(normal, into: &out)
        if state.isAlternateBuffer {
            // 1049 saves the cursor of the normal buffer and clears the alternate one.
            out += csi("?1049h")
            emit(terminal.contentSnapshot(region: .viewport, buffer: .alt), into: &out)
        }
        let cursor = terminal.makeRenderSnapshot(scope: .dirty).cursor
        if state.applicationCursor { out += csi("?1h") }
        if state.applicationKeypad { out += [0x1B, UInt8(ascii: "=")] }
        if state.bracketedPasteMode { out += csi("?2004h") }
        switch state.mouseMode {
        case .off: break
        case .x10: out += csi("?9h")
        case .vt200: out += csi("?1000h")
        case .buttonEventTracking: out += csi("?1002h")
        case .anyEvent: out += csi("?1003h")
        }
        // The encoding is not readable; every program that asks for the mouse today asks for SGR.
        if state.mouseMode != .off { out += csi("?1006h") }
        if state.focusReportingEnabled { out += csi("?1004h") }
        if !state.keyboardEnhancementFlags.isEmpty { out += csi("=\(state.keyboardEnhancementFlags.rawValue);1u") }
        if cursor.hidden { out += csi("?25l") }
        return out
    }

    /// The buffer's rows (history first) from the top-left, then the cursor. The last row has no line break, so nothing scrolls past it.
    private static func emit(_ snap: TerminalContentSnapshot, into out: inout [UInt8]) {
        for (n, row) in snap.rows.enumerated() {
            // A row the next one continues is written to its end and left by the terminal's own wrap, so the new terminal flags the
            // continuation as wrapped too (a later resize joins the two again).
            let wraps = n + 1 < snap.rows.count && snap.rows[n + 1].isWrapped
            emit(row.cells, whole: wraps, into: &out)
            if n + 1 < snap.rows.count && !wraps { out += [13, 10] }
        }
        let screenRow = max(0, snap.cursorRow - snap.liveTopRow)
        let col = min(snap.cursorColumn, max(0, snap.inputState.dimensions.cols - 1))
        out += csi("\(screenRow + 1);\(col + 1)H")
    }

    private static func emit(_ cells: [TerminalCellSnapshot], whole: Bool, into out: inout [UInt8]) {
        // Trailing cells that are blank in the default look carry nothing.
        var end = cells.count
        while !whole, end > 0, isBlank(cells[end - 1]), isPlain(cells[end - 1].attribute) { end -= 1 }
        var pen = Attribute.empty
        var plain = true
        for cell in cells[0..<end] {
            if cell.width == 0 { continue }
            if cell.attribute != pen { out += csi(sgr(cell.attribute)); pen = cell.attribute; plain = isPlain(pen) }
            out += isBlank(cell) ? [0x20] : Array(cell.text.utf8)
        }
        if !plain { out += csi("0m") }
    }

    /// The default look: default colors, no style.
    private static func isPlain(_ a: Attribute) -> Bool {
        if !a.style.isEmpty || a.underlineStyle != .none { return false }
        switch (a.fg, a.bg) {
        case (.defaultColor, .defaultColor), (.defaultColor, .defaultInvertedColor), (.defaultInvertedColor, .defaultColor), (.defaultInvertedColor, .defaultInvertedColor): return true
        default: return false
        }
    }

    private static func isBlank(_ cell: TerminalCellSnapshot) -> Bool { cell.text.isEmpty || cell.text == "\u{0}" || cell.text == " " }

    private static func csi(_ s: String) -> [UInt8] { [0x1B, UInt8(ascii: "[")] + Array(s.utf8) }

    private static func sgr(_ a: Attribute) -> String {
        var p = ["0"]
        let s = a.style
        if s.contains(.bold) { p.append("1") }
        if s.contains(.dim) { p.append("2") }
        if s.contains(.italic) { p.append("3") }
        if s.contains(.underline) { p.append("4") }
        if s.contains(.blink) { p.append("5") }
        if s.contains(.inverse) { p.append("7") }
        if s.contains(.invisible) { p.append("8") }
        if s.contains(.crossedOut) { p.append("9") }
        p += color(a.fg, base: 30)
        p += color(a.bg, base: 40)
        return p.joined(separator: ";") + "m"
    }

    private static func color(_ c: Attribute.Color, base: Int) -> [String] {
        switch c {
        case .defaultColor, .defaultInvertedColor: return []
        case .ansi256(let code):
            if code < 8 { return ["\(base + Int(code))"] }
            if code < 16 { return ["\(base + 60 + Int(code) - 8)"] }
            return ["\(base + 8)", "5", "\(code)"]
        case .trueColor(let r, let g, let b): return ["\(base + 8)", "2", "\(r)", "\(g)", "\(b)"]
        }
    }
}
