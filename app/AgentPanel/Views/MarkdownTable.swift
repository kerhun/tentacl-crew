import SwiftUI
import AppKit

/// A Markdown table: header, the alignment row's column alignment, body rows. Cells split on unescaped `|` (`\|` stays in the cell);
/// short rows get empty cells, long rows keep their extra cells (every row then has `columns` cells).
struct MarkdownTable: Equatable {
    enum Align: Equatable {
        case leading, center, trailing
        var horizontal: HorizontalAlignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
        var text: TextAlignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
    }
    let header: [String]
    let alignments: [Align]
    let rows: [[String]]
    var columns: Int { header.count }

    /// Nil unless the second line is an alignment row (`---`, `:---`, `:---:`, `---:` in every cell).
    static func parse(_ text: String) -> MarkdownTable? {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let head = cells(lines[0]), marks = cells(lines[1]), body = lines.dropFirst(2).map(cells)
        guard marks.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) else { return nil }
        let columns = ([head.count, marks.count] + body.map(\.count)).max() ?? 0
        func pad<T>(_ row: [T], _ filler: T) -> [T] { row + Array(repeating: filler, count: columns - row.count) }
        let alignments: [Align] = marks.map { m in
            switch (m.hasPrefix(":"), m.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
        return MarkdownTable(header: pad(head, ""), alignments: pad(alignments, .leading), rows: body.map { pad($0, "") })
    }

    static func cells(_ line: String) -> [String] {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s = s.dropLast() }
        var out: [String] = [], cell = "", escaped = false
        for ch in s {
            if escaped { cell += ch == "|" ? "|" : "\\\(ch)"; escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "|" { out.append(cell); cell = "" }
            else { cell.append(ch) }
        }
        if escaped { cell += "\\" }
        out.append(cell)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A table drawn as a grid: bold header, column alignment, thin row lines, inline Markdown in cells.
/// Cells wrap at `maxCellWidth`; a wider table scrolls sideways inside its box.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let source: String
    static let maxCellWidth: CGFloat = 280
    /// No Copy line: the table text is selectable and the reply has its own Copy.
    static let copyHelp: String? = nil

    var body: some View {
        MarkdownBlockBox(source: source, copyHelp: Self.copyHelp) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columns, id: \.self) { c in
                        cell(table.header[c], c).font(Tok.Font.body.weight(.semibold)).gridColumnAlignment(table.alignments[c].horizontal)
                    }
                }
                Rectangle().fill(Tok.ink3).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                    if r > 0 { Rectangle().fill(Tok.line).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    GridRow {
                        ForEach(0..<table.columns, id: \.self) { c in cell(row[c], c).font(Tok.Font.body) }
                    }
                }
            }
        }
    }

    private func cell(_ s: String, _ column: Int) -> some View {
        CappedWidth(max: Self.maxCellWidth) {
            MarkdownBlockView.inline(s).foregroundStyle(Tok.ink).multilineTextAlignment(table.alignments[column].text)
        }
        .padding(.horizontal, Tok.Space.s).padding(.vertical, Tok.Space.xs)
    }
}

/// The box around a table or code block: a Copy line above when `copyHelp` is set, the content at its own size; a box as wide as its content when that fits,
/// else as wide as the space, scrolling sideways.
struct MarkdownBlockBox<Content: View>: View {
    let source: String
    let copyHelp: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.snapshotMode) private var snapshot
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let copyHelp {
                Button(copied ? "Copied" : "Copy") { copy() }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink3).help(copyHelp)
            }
            ViewThatFits(in: .horizontal) {
                content().fixedSize()
                sideways
            }
            .background(Tok.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tok.line))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ImageRenderer cannot draw a scroll view: a snapshot shows the start of the content, clipped at the box.
    @ViewBuilder private var sideways: some View {
        if snapshot {
            LeadingClip { content().fixedSize() }.clipped()
        } else {
            ScrollView(.horizontal) { content().fixedSize() }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

/// As wide as offered (the content keeps its own size, from the leading edge); for the snapshot stand-in of a sideways scroll view.
private struct LeadingClip: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? ideal.width, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .unspecified)
    }
}

/// Its content at its natural width, or wrapped at `max` when wider.
private struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        return ideal.width <= max ? ideal : child.sizeThatFits(ProposedViewSize(width: max, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
