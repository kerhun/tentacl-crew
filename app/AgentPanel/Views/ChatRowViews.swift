import SwiftUI
import AppKit

/// The words and small helpers of the thread's rows (N290), kept apart from the views so tests can check them.
enum ChatRowText {
    /// "TODAY", "YESTERDAY", "OCT 25" (with the year when it is not this year's).
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "YESTERDAY" }
        var style = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style).uppercased()
    }

    /// "9 h 35 min later", "2 h later", "45 min later".
    static func gap(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60), h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min later" }
        return m == 0 ? "\(h) h later" : "\(h) h \(m) min later"
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "03:15–04:42" for a stack of panel notes; one time when they all came in the same minute.
    static func range(_ events: [PanelEvent]) -> String? {
        let times = events.compactMap(\.entry.time).map(time)
        guard let first = times.first, let last = times.last else { return nil }
        return first == last ? first : "\(first)–\(last)"
    }

    /// The label already says "Panel"; the text does not repeat it.
    static func panelText(_ text: String) -> String { text.hasPrefix("Panel: ") ? String(text.dropFirst(7)) : text }

    /// The text as a Markdown quote for the input, a blank line after it for the answer.
    static func quote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n") + "\n\n"
    }

    /// An agent turn's label (N292): the role's display name with the role beside it ("Ibrahim", "pm"); without a display name
    /// the role alone; a name with no role in it (a session started by hand) as it is.
    static func turnLabel(agent: String, displayNames: [String: String]) -> (name: String, role: String?) {
        guard let role = AgentRowName.role(ofAgent: agent) else { return (agent, nil) }
        let display = displayNames[role]?.trimmingCharacters(in: .whitespaces) ?? ""
        return display.isEmpty ? (role, nil) : (display, role)
    }

    /// "Bash · git log" → ("Bash", "git log"); a tool with nothing to show is its name alone.
    static func tool(_ line: String) -> (kind: String, what: String) {
        guard let r = line.range(of: " · ") else { return (line, "") }
        return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }

    /// "0:12", "12:05".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Puts the whole text on the pasteboard (a turn's Copy copies all of it, also the part under Show all).
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The fonts of the rows: the design's 12 pt secondary line beside the 13 pt body.
private enum RowFont {
    static let line = Font.system(size: 12)
    static let lineStrong = Font.system(size: 12, weight: .semibold)
    static let mono = Font.system(size: 11, design: .monospaced)
}

extension ChatHighlight? {
    /// The text as the row shows it: plain with links, or with the search's query lit.
    func text(_ s: String, row: String, piece: Int, from: Int = 0) -> Text {
        self?.text(s, row: row, piece: piece, from: from) ?? ChatLinks.text(s)
    }

    func reveals(_ row: String) -> Bool { self?.reveals(row) == true }
}

/// A small text button that lights up under the pointer (Copy, Quote, Edit again, View summary).
struct GhostButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Tok.ink2
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                Text(title)
            }
            .font(RowFont.line).foregroundStyle(hovering ? Tok.ink : tint)
            .padding(.horizontal, 8).frame(height: 24)
            .background(hovering ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? title)
    }
}

/// A Copy button that says "Copied" for a moment.
private struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied = false

    var body: some View {
        GhostButton(title: copied ? "Copied" : "Copy", icon: "doc.on.doc", help: help) {
            ChatRowText.copy(text)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
    }
}

/// Centered small caps between two 1 pt rules: "TODAY".
struct DayDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Tok.line).frame(height: 1)
            Text(ChatRowText.day(date)).font(.system(size: 11, weight: .semibold)).tracking(0.44).foregroundStyle(Tok.ink2).fixedSize()
            Rectangle().fill(Tok.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dashed rule with how long nothing happened: "9 h 35 min later".
struct GapDivider: View {
    let seconds: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            dash
            Text(ChatRowText.gap(seconds)).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize()
            dash
        }
        .accessibilityElement(children: .combine)
    }

    private var dash: some View {
        HLine().stroke(Tok.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
    }
}

private struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: 0, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

/// The green check of a panel note the PM answered with a bare ✓.
private struct AckMark: View {
    var body: some View {
        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Tok.go)
            .accessibilityLabel("Acknowledged by the PM")
    }
}

/// The panel's own notes as one quiet line: one note as it is, two or more as "6 events · …" that open into a line per note.
/// A note that failed or was not seen is a row of its own, with its problem and Retry/Remove under it.
struct SystemRow: View {
    let events: [PanelEvent]
    var onRetry: ((ChatEntry) -> Void)?
    var onRemove: (ChatEntry) -> Void
    /// Where the open state is kept past a tab switch; nil keeps it in the view only.
    var opened: ChatOpenRows?
    private let openByDefault: Bool
    @State private var open: Bool
    @Environment(\.chatHighlight) private var highlight
    private var rowID: String { ChatRow.system(events).id }

    init(events: [PanelEvent], open: Bool = false, opened: ChatOpenRows? = nil, onRetry: ((ChatEntry) -> Void)? = nil, onRemove: @escaping (ChatEntry) -> Void) {
        self.events = events; self.opened = opened; self.onRetry = onRetry; self.onRemove = onRemove; openByDefault = open
        _open = State(initialValue: opened?.isOpen(.system, ChatRow.system(events).id, default: open) ?? open)
    }

    var body: some View {
        if events.count == 1, let event = events.first { single(event) } else { stack }
    }

    private func single(_ event: PanelEvent) -> some View {
        let entry = event.entry
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Color.clear.frame(width: 12, height: 1)
                Text("Panel").font(RowFont.lineStrong).foregroundStyle(Tok.ink)
                highlight.text(ChatRowText.panelText(entry.text), row: rowID, piece: 0).font(RowFont.line).foregroundStyle(Tok.ink2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let pending = entry.pending { PendingMark(pending: pending) }
                if event.acked { AckMark() }
                if let time = entry.time, entry.pending == nil { Text(ChatRowText.time(time)).font(RowFont.line).foregroundStyle(Tok.ink2).monospacedDigit() }
            }
            if entry.pending.map(ChatThread.needsAction) == true { ChatProblem(entry: entry, onRetry: onRetry, onRemove: onRemove) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel message: \(entry.text)")
    }

    private var stack: some View {
        let range = ChatRowText.range(events)
        let acked = events.last?.acked == true
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() }; opened?.set(.system, rowID, open: open, default: openByDefault) } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Tok.ink2).frame(width: 12)
                    Text("Panel").font(RowFont.lineStrong).foregroundStyle(Tok.ink)
                    Text(open ? "\(events.count) events" : "\(events.count) events · \(ChatRowText.panelText(events.last?.entry.text ?? ""))")
                        .font(RowFont.line).foregroundStyle(Tok.ink2).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if acked, !open { AckMark() }
                    if let range { Text(range).font(RowFont.line).foregroundStyle(Tok.ink2).monospacedDigit() }
                }
                .padding(.horizontal, 8).frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Panel, \(events.count) events")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                ForEach(Array(events.enumerated()), id: \.element.id) { i, event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(event.entry.time.map(ChatRowText.time) ?? "").font(RowFont.line).foregroundStyle(Tok.ink2).monospacedDigit()
                            .frame(minWidth: 40, alignment: .leading)
                        highlight.text(ChatRowText.panelText(event.entry.text), row: rowID, piece: i).font(RowFont.line).foregroundStyle(Tok.ink)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let pending = event.entry.pending { PendingMark(pending: pending) }
                        if event.acked { AckMark() }
                    }
                    .padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 3)
                }
            }
        }
        .padding(.vertical, open ? 4 : 0)
        .background(open ? Tok.list : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: highlight.reveals(rowID), initial: true) { _, reveal in if reveal { open = true } }
    }
}

/// A turn's tool uses as one dim line ("read 2 files, ran 3 commands") that opens into a `Bash · …` row per use.
struct ToolsLine: View {
    let summary: String
    let lines: [String]
    /// The row the lines belong to, for the search (a turn's, or the tools row's own id).
    var row = ""
    /// Where the open state is kept past a tab switch; nil keeps it in the view only.
    var opened: ChatOpenRows?
    private let openByDefault: Bool
    @State private var open: Bool
    @Environment(\.chatHighlight) private var highlight

    init(summary: String, lines: [String], row: String = "", open: Bool = false, opened: ChatOpenRows? = nil) {
        self.summary = summary; self.lines = lines; self.row = row; self.opened = opened; openByDefault = open
        _open = State(initialValue: opened?.isOpen(.tools, row, default: open) ?? open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() }; opened?.set(.tools, row, open: open, default: openByDefault) } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).frame(width: 12)
                    Text(summary.isEmpty ? "\(lines.count) tool uses" : summary).font(RowFont.line).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Tok.ink2)
                .padding(.horizontal, 8).frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(lines.isEmpty)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    let tool = ChatRowText.tool(line)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        highlight.text(tool.kind, row: row, piece: i).font(RowFont.line).foregroundStyle(Tok.ink2).frame(minWidth: 40, alignment: .leading)
                        highlight.text(tool.what, row: row, piece: i, from: highlight.map { ChatSearch.ranges(of: $0.query, in: tool.kind).count } ?? 0).font(RowFont.mono).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 2)
                    .help(line)
                }
            }
        }
        .padding(.vertical, open ? 4 : 0)
        .background(open ? Tok.list : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: highlight.reveals(row), initial: true) { _, reveal in if reveal { open = true } }
    }
}

/// One turn of the agent, no bubble: its label and time with Copy and Quote under the pointer, its tool uses as a dim line
/// above the text, and the Markdown text cut to a few lines (Show all).
struct TurnRow: View {
    let entry: ChatEntry
    let label: String
    /// The role beside a display name, muted ("Ibrahim  pm"); nil when the label is the role itself.
    var role: String? = nil
    var openTools = false
    /// Where Show all and the tools line's open state are kept past a tab switch; nil keeps them in the view only.
    var opened: ChatOpenRows?
    /// Gets the turn's text; the input shows it as a quote box.
    var onQuote: ((String) -> Void)?
    @State private var expanded: Bool
    @State private var hovering = false
    @Environment(\.snapshotMode) private var snapshot
    @Environment(\.chatHighlight) private var highlight

    static let maxLines = 6

    init(entry: ChatEntry, label: String, role: String? = nil, openTools: Bool = false, opened: ChatOpenRows? = nil, onQuote: ((String) -> Void)? = nil) {
        self.entry = entry; self.label = label; self.role = role; self.openTools = openTools; self.opened = opened; self.onQuote = onQuote
        _expanded = State(initialValue: opened?.isOpen(.turn, entry.id, default: false) ?? false)
    }

    var body: some View {
        let shown = expanded ? (entry.text, false) : ChatText.preview(entry.text, maxLines: Self.maxLines)
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(spacing: 8) {
                Text(label).font(RowFont.lineStrong).foregroundStyle(Tok.work)
                if let role { Text(role).font(RowFont.line).foregroundStyle(Tok.ink3) }
                if let time = entry.time { Text(ChatRowText.time(time)).font(RowFont.line).foregroundStyle(Tok.ink2).monospacedDigit() }
                Spacer()
                HStack(spacing: 2) {
                    CopyButton(text: entry.text, help: "Copy the whole answer")
                    if let onQuote { GhostButton(title: "Quote", help: "Quote this answer in the input") { onQuote(entry.text) } }
                }
                .opacity(hovering || snapshot ? 1 : 0)
            }
            .frame(height: 24)
            if !entry.tools.isEmpty { ToolsLine(summary: entry.toolSummary, lines: entry.tools, row: entry.id, open: openTools, opened: opened) }
            if !entry.text.isEmpty {
                VStack(alignment: .leading, spacing: Tok.Space.s) {
                    if let highlight, !ChatSearch.ranges(of: highlight.query, in: entry.text).isEmpty {
                        // While a search lights the text, the blocks are drawn as plain text so the query can be marked.
                        let blocks = ChatText.blocks(shown.0)
                        ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                            let before = blocks[..<i].reduce(0) { $0 + ChatSearch.ranges(of: highlight.query, in: $1.text).count }
                            highlight.text(block.text, row: entry.id, piece: entry.tools.count, from: before)
                                .font(block.kind == .code ? .system(size: 12, design: .monospaced) : Tok.Font.body).foregroundStyle(Tok.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(Array(ChatText.blocks(shown.0).enumerated()), id: \.offset) { _, block in MarkdownBlockView(block: block) }
                    }
                    if shown.1 { Text("…").foregroundStyle(Tok.ink3) }
                }
                .textSelection(.enabled)
            }
            if shown.1 || expanded, entry.text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.maxLines {
                Button(expanded ? "Show less" : "Show all") { expanded.toggle(); opened?.set(.turn, entry.id, open: expanded, default: false) }.buttonStyle(.plain).font(RowFont.line).foregroundStyle(Tok.work)
                    .tutorialAnchor(.chatShowAll)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: highlight.reveals(entry.id), initial: true) { _, reveal in if reveal { expanded = true } }
    }
}

/// The user's message on the right: a violet bubble with a short bottom-right corner, at most 520 pt wide;
/// Copy and Edit again under it while the pointer is over it.
struct UserRow: View {
    let entry: ChatEntry
    var youFill: Color = Tok.youFill
    var onEditAgain: ((String) -> Void)?
    var onRetry: ((ChatEntry) -> Void)?
    var onRemove: (ChatEntry) -> Void
    var onOpenImage: ([ChatImage], Int) -> Void
    @State private var hovering = false
    @Environment(\.snapshotMode) private var snapshot
    @Environment(\.chatHighlight) private var highlight

    static let maxWidth: CGFloat = 520
    /// N347: a bubble is at most three quarters of the conversation column (`maxWidth` until the column is measured).
    static func maxWidth(column: CGFloat) -> CGFloat { column > 0 ? (column * 0.75).rounded() : maxWidth }
    @Environment(\.chatColumnWidth) private var columnWidth
    static let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12)

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if let time = entry.time, entry.pending == nil { Text(ChatRowText.time(time)).font(RowFont.line).foregroundStyle(Tok.ink2).monospacedDigit() }
                Text("You").font(RowFont.lineStrong).foregroundStyle(Tok.you)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if let pending = entry.pending { PendingMark(pending: pending).padding(.bottom, 9) }
                VStack(alignment: .trailing, spacing: 4) {
                    if !entry.images.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(entry.images.enumerated()), id: \.offset) { i, image in
                                ThreadImage(image: image) { onOpenImage(entry.images, i) }
                            }
                        }
                    }
                    if !entry.files.isEmpty { FileChips(files: entry.files) }
                    if !entry.text.isEmpty {
                        let parts = ChatQuote.split(entry.text)
                        if let quote = parts.quote {
                            SentQuoteMessage(quote: quote) {
                                if !parts.text.isEmpty { messageText(parts.text) }
                            }
                        } else {
                            messageText(entry.text)
                        }
                    }
                    if entry.pending.map(ChatThread.needsAction) == true { ChatProblem(entry: entry, onRetry: onRetry, onRemove: onRemove) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(youFill, in: Self.shape)
                .overlay(Self.shape.strokeBorder(Tok.youBorder, lineWidth: 1))
            }
            .frame(maxWidth: Self.maxWidth(column: columnWidth), alignment: .trailing)
            if !entry.text.isEmpty {
                HStack(spacing: 2) {
                    CopyButton(text: entry.text, help: "Copy the message")
                    if let onEditAgain { GhostButton(title: "Edit again", help: "Put this message into the input to change and send it again") { onEditAgain(entry.text) } }
                }
                .opacity(hovering || snapshot ? 1 : 0)
            }
        }
        .padding(.leading, 36)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func messageText(_ text: String) -> some View {
        highlight.text(text, row: entry.id, piece: 0).font(Tok.Font.body).foregroundStyle(Tok.ink).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where the conversation was summarized: a rounded row with View summary, which opens the summary's text.
struct SummaryRow: View {
    let entry: ChatEntry
    @State private var showing = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft").font(.system(size: 12)).foregroundStyle(Tok.ink2)
            Text("Conversation summarized").font(RowFont.line).foregroundStyle(Tok.ink2).frame(maxWidth: .infinity, alignment: .leading)
            if let time = entry.time { Text(ChatRowText.time(time)).font(RowFont.line).foregroundStyle(Tok.ink2).monospacedDigit() }
            if !entry.text.isEmpty { GhostButton(title: "View summary", tint: Tok.work, help: "Read the summary the agent continues from") { showing = true } }
        }
        .padding(.horizontal, 10).padding(.vertical, 4).frame(minHeight: 34)
        .background(Tok.list, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tok.line.opacity(0.7), lineWidth: 1))
        .sheet(isPresented: $showing) { SummarySheet(text: entry.text) }
    }
}

private struct SummarySheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            Text("Conversation summary").font(Tok.Font.heading).foregroundStyle(Tok.ink)
            ScrollView { MarkdownText(text: text).padding(.trailing, Tok.Space.s) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tok.Space.l)
        .frame(width: 560, height: 520)
        .background(Tok.pane)
    }
}

/// Why a message is stuck, with Retry (when the panel can re-send it) and Remove; nothing is sent by itself.
struct ChatProblem: View {
    let entry: ChatEntry
    var onRetry: ((ChatEntry) -> Void)?
    var onRemove: (ChatEntry) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch entry.pending {
            case .failed(let why): Text("Not sent: \(why)").font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
            default: Text(ChatThread.notSeenText).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            HStack(spacing: Tok.Space.s) {
                if entry.kind == .user, let onRetry { Button("Retry") { onRetry(entry) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work).help("Send this message again") }
                Button("Remove") { onRemove(entry) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work).help("Take this message out of the thread; nothing is sent")
            }
        }
    }
}

/// The mark next to a message the agent has not received yet: an empty circle while it waits, a warning when sending failed.
struct PendingMark: View {
    let pending: ChatEntry.Pending
    static let queuedHelp = "Queued: the agent is busy; it will get this when its turn ends"

    var body: some View {
        switch pending {
        case .queued:
            Image(systemName: "circle").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tok.ink3)
                .help(Self.queuedHelp).accessibilityLabel("Queued, not delivered yet")
        case .failed(let why):
            Image(systemName: "exclamationmark.circle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.wait)
                .help("Not sent: \(why)").accessibilityLabel("Not sent")
        case .notSeen:
            Image(systemName: "questionmark.circle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.ink3)
                .help(ChatThread.notSeenText).accessibilityLabel(ChatThread.notSeenText)
        }
    }
}

/// A thumbnail of an image in the user's message; a click opens it in the image viewer with the message's other images.
struct ThreadImage: View {
    let image: ChatImage
    let onOpen: () -> Void
    static let maxPixel = 128   // twice the 64 pt thumbnail, for Retina

    private var nsImage: NSImage? {
        switch image {
        case .file(let path): return Thumbnail.load(URL(fileURLWithPath: path), maxPixel: Self.maxPixel)
        case .inline(let data): return Thumbnail.load(data, maxPixel: Self.maxPixel)
        }
    }

    var body: some View {
        if let nsImage {
            Button(action: onOpen) {
                Image(nsImage: nsImage).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Open the image")
            .accessibilityLabel("Image in the message")
        } else {
            Text("Image not found").font(Tok.Font.small).foregroundStyle(Tok.ink3)
        }
    }
}

/// The files and folders of a message, one chip each, right-aligned like the bubble's text.
struct FileChips: View {
    let files: [ChatFile]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                FileChip(name: file.name, folder: file.folder, detail: Self.detail(file)) { FileChip.reveal(file.path) }
            }
        }
    }

    /// The size read from disk now (nothing for a file that is gone), and "linked, not copied" for what the panel did not copy.
    static func detail(_ file: ChatFile) -> String {
        let size = file.folder ? nil : (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        return Attachments.chipDetail(size: size, folder: file.folder, linked: !file.copied)
    }
}

/// One attached file or folder: its icon, name and size (or "linked, not copied"); a click shows it in Finder.
struct FileChip: View {
    let name: String
    let folder: Bool
    let detail: String
    var onOpen: (() -> Void)?

    var body: some View {
        let chip = HStack(spacing: 8) {
            Image(systemName: folder ? "folder" : "doc").font(.system(size: 15)).foregroundStyle(Tok.ink2).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Tok.Font.small.weight(.medium)).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                if !detail.isEmpty { Text(detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1) }
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tok.line))
        if let onOpen {
            Button(action: onOpen) { chip }.buttonStyle(.plain)
                .help("Show \(name) in Finder").accessibilityLabel("\(folder ? "Folder" : "File") \(name), \(detail)")
        } else {
            chip.accessibilityElement(children: .combine)
        }
    }

    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
