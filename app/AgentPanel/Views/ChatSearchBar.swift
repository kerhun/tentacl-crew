import SwiftUI

/// Search in the chat (N291): which rows and texts a query hits, in the order they are drawn, and the bar that replaces the chat header.
enum ChatSearch {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", conversation = "Conversation", panel = "Panel events", questions = "Questions", tools = "Tool calls"
        var id: String { rawValue }
    }

    /// One hit: the `occ`-th place of the query in text `piece` of row `row` (a ChatRow id).
    struct Match: Equatable {
        let row: String
        let piece: Int
        let occ: Int
    }

    /// Conversation only keeps the user's messages and the agent's turns (without their tool lines), and the dividers.
    static func conversationOnly(_ rows: [ChatRow]) -> [ChatRow] {
        rows.compactMap { row -> ChatRow? in
            switch row {
            case .system, .tools, .summary: return nil
            case .turn(var entry): entry.tools = []; return .turn(entry)
            default: return row
            }
        }
    }

    /// The texts of a row a search can hit, in drawing order: a turn's tool lines, then its text; a stack's notes; a tools line's uses.
    private static func pieces(_ row: ChatRow) -> [(kind: Filter, text: String)] {
        switch row {
        case .system(let events): events.map { (.panel, ChatRowText.panelText($0.entry.text)) }
        case .user(let e), .summary(let e): [(.conversation, e.text)]
        case .turn(let e): e.tools.map { (.tools, $0) } + [(.conversation, e.text)]
        case .tools(let e): e.tools.map { (.tools, $0) }
        case .day, .gap: []
        }
    }

    private static func allows(_ filter: Filter, _ piece: (kind: Filter, text: String)) -> Bool {
        switch filter {
        case .all: true
        case .questions: piece.kind == .conversation && piece.text.contains("?")
        default: piece.kind == filter
        }
    }

    /// Where `query` stands in `text`, ignoring case and accents.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    static func matches(_ rows: [ChatRow], query: String, filter: Filter) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return rows.flatMap { row in
            pieces(row).enumerated().filter { allows(filter, $0.element) }.flatMap { i, piece in
                ranges(of: q, in: piece.text).indices.map { Match(row: row.id, piece: i, occ: $0) }
            }
        }
    }

    /// "3 of 7", "No matches".
    static func counter(index: Int, count: Int) -> String { count == 0 ? "No matches" : "\(index + 1) of \(count)" }
}

/// The query on screen: every place of it is lit (`Tok.wait` at 35 %), the current one stronger (70 %).
struct ChatHighlight: Equatable {
    let query: String
    var current: ChatSearch.Match?

    /// `s` (text `piece` of `row`) with the query lit; occurrences count from `from` when only a part of the piece is drawn here.
    func apply(_ s: AttributedString, row: String, piece: Int, from: Int = 0) -> AttributedString {
        let plain = String(s.characters)
        var out = s
        for (i, r) in ChatSearch.ranges(of: query, in: plain).enumerated() {
            let lo = out.index(out.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let hi = out.index(lo, offsetByCharacters: plain.distance(from: r.lowerBound, to: r.upperBound))
            let now = current == ChatSearch.Match(row: row, piece: piece, occ: from + i)
            out[lo..<hi].backgroundColor = Tok.wait.opacity(now ? 0.7 : 0.35)
        }
        return out
    }

    func text(_ s: String, row: String, piece: Int, from: Int = 0) -> Text {
        Text(ChatLinks.linkified(apply(AttributedString(s), row: row, piece: piece, from: from)))
    }

    /// The current match is in this row: a collapsed stack, tools line or cut text opens.
    func reveals(_ row: String) -> Bool { current?.row == row }
}

private struct ChatHighlightKey: EnvironmentKey { static let defaultValue: ChatHighlight? = nil }
private struct ChatColumnWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    /// The conversation column's width (N347): user bubbles are a share of it; 0 until it is measured.
    var chatColumnWidth: CGFloat {
        get { self[ChatColumnWidthKey.self] }
        set { self[ChatColumnWidthKey.self] = newValue }
    }
    var chatHighlight: ChatHighlight? {
        get { self[ChatHighlightKey.self] }
        set { self[ChatHighlightKey.self] = newValue }
    }
}

/// Replaces the chat's header row while searching: the field, "3 of 7", previous and next, Done, and the filter chips.
struct ChatSearchBar: View {
    @Binding var query: String
    @Binding var filter: ChatSearch.Filter
    let index: Int
    let count: Int
    let onStep: (Int) -> Void
    let onDone: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(spacing: Tok.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Tok.ink2)
                    if snapshot {
                        // A text field is an AppKit view the snapshot renderer cannot draw.
                        Text(query).font(Tok.Font.body).foregroundStyle(Tok.ink).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Search the conversation", text: $query)
                            .textFieldStyle(.plain).font(Tok.Font.body).foregroundStyle(Tok.ink)
                            .focused($focused)
                            .onSubmit { onStep(1) }
                            .onKeyPress(.downArrow) { onStep(1); return .handled }
                            .onKeyPress(.upArrow) { onStep(-1); return .handled }
                            .onExitCommand(perform: onDone)
                    }
                    if !query.isEmpty {
                        Text(ChatSearch.counter(index: index, count: count)).font(Tok.Font.small).foregroundStyle(Tok.ink2).monospacedDigit()
                    }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(Tok.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tok.work.opacity(focused ? 0.8 : 0.3)))
                stepButton("chevron.up", -1, help: "Previous match")
                stepButton("chevron.down", 1, help: "Next match")
                Button("Done", action: onDone).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction).help("Close the search (Esc)")
            }
            HStack(spacing: 6) {
                ForEach(ChatSearch.Filter.allCases) { chip in
                    Button { filter = chip } label: {
                        Text(chip.rawValue).font(Tok.Font.small).foregroundStyle(filter == chip ? Tok.ink : Tok.ink2)
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(filter == chip ? Tok.work.opacity(0.25) : Tok.raise, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func stepButton(_ icon: String, _ by: Int, help: String) -> some View {
        Button { onStep(by) } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.ink2).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(count == 0).help(help).accessibilityLabel(help)
    }
}

/// The row at the top of a thread that was read from its middle: where it starts, and a button for the 2 MB before.
struct LoadEarlierRow: View {
    let from: Date?
    let onLoad: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(from.map { "Showing from \(ChatRowText.time($0))" } ?? "Showing the latest part").font(.system(size: 12)).foregroundStyle(Tok.ink2)
            Button("Load earlier", action: onLoad).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tok.work)
                .help("Read the part of the conversation before this one")
        }
        .frame(maxWidth: .infinity, minHeight: 28)
    }
}
