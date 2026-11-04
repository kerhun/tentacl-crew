import SwiftUI
import AppKit

/// The conversation above the Command input, newest at the bottom, drawn from `ChatRows` (N290): day and gap dividers, the panel's
/// notes as quiet lines, the agent's turns without a bubble, the user's messages on the right. Content is at most 680 pt wide, centred.
/// A message not delivered yet carries a circle mark.
struct ChatThread: View {
    /// Where the user left the thread (the bottom, or a place higher up), kept by the caller's session.
    let place: ChatPlace
    /// The rows the user opened or closed, kept by the caller's session so they survive a tab switch (N296).
    var opened: ChatOpenRows? = nil
    let entries: [ChatEntry]
    /// Conversations before the last restart, drawn dimmed above a divider.
    var previous: [ChatEntry] = []
    let agentLabel: String
    /// The role drawn muted beside a display name on the agent's turns (N292); nil when the label is the role.
    var agentRole: String? = nil
    let working: Bool
    /// Stop at the end of the working line (N293); without it the button is not shown.
    var onStop: (() -> Void)? = nil
    /// A message the user sent that waits out its hold; drawn last with its countdown, Edit and Undo.
    var held: HeldMessage? = nil
    var onEdit: () -> Void = {}
    var onUndo: () -> Void = {}
    /// Retry and Remove on a message that failed or was not seen; Retry only on the user's own messages (the panel's lines go through its outbox).
    var onRetry: ((ChatEntry) -> Void)? = nil
    var onRemove: (ChatEntry) -> Void = { _ in }
    /// Quote on a turn (its text, for the input's quote box) and Edit again on the user's message (into the field); without them the buttons are not shown.
    var onQuote: ((String) -> Void)? = nil
    var onEditAgain: ((String) -> Void)? = nil
    /// Hides the panel's notes, tool lines, tool stacks and summaries (N291).
    var conversationOnly = false
    /// The first read began past the start of the session file: a top row offers the part before it (`earlierFrom`: its first time).
    var canLoadEarlier = false
    var earlierFrom: Date? = nil
    var onLoadEarlier: () -> Void = {}
    /// The fill of the user's bubbles; only a snapshot comparing strengths changes it.
    var youFill: Color = Tok.youFill
    /// Opens every stack of panel notes and every tools line; only a snapshot sets it.
    var openAll = false
    /// The clock of the working line's timer; only a snapshot fixes it.
    var now: Date? = nil
    @Environment(\.snapshotMode) private var snapshot
    @Environment(\.chatHighlight) private var highlight
    @State private var viewing: ViewerSet?
    /// The row that was first when Load earlier was pressed: the thread scrolls back to it once the older rows are above it.
    @State private var keepRow: String?

    /// The widest the conversation column gets (N347): below it the thread spans the column, the same width as the composer and the header.
    static let readingWidth: CGFloat = 960
    @State private var columnWidth: CGFloat = 0

    var body: some View {
        // The viewer is a window-level modifier ImageRenderer cannot draw (it paints a "prohibited" sign over the snapshot).
        if snapshot { content } else { content.imageViewer($viewing) }
    }

    @ViewBuilder private var content: some View {
        if entries.isEmpty && previous.isEmpty && !working && held == nil {
            Text("No conversation yet").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                .frame(maxWidth: .infinity, minHeight: 40)
        } else if snapshot {
            Color.clear.overlay(alignment: .bottom) { Self.unsqueezed(list) }.clipped()
        } else {
            // The probe keeps the place: the bottom while following (new messages, the held bubble, a growing input),
            // else the same top; and it brings the place back when the thread is shown again.
            ScrollViewReader { proxy in
                ScrollView {
                    list.background(ThreadScrollProbe(place: place, messages: ChatPlace.messages(entries), jumpRequest: place.jumpRequest))
                }
                .overlay(alignment: .bottomTrailing) { if place.far { jumpButton } }
                // After the match's row has opened, so the scroll lands on its final place.
                .onChange(of: highlight?.current) { _, match in
                    guard let match else { return }
                    DispatchQueue.main.async { proxy.scrollTo(match.row, anchor: .center) }
                }
                .onChange(of: entries.first?.id) {
                    guard let id = keepRow else { return }
                    keepRow = nil
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    /// N347 F1: the rows keep their full height when the thread is shorter (the snapshot's bottom-aligned overlay); the thread clips
    /// the top instead of squeezing a long answer to "…".
    static func unsqueezed(_ rows: some View) -> some View { rows.fixedSize(horizontal: false, vertical: true) }

    static let jumpHelp = "Jump to latest"

    /// Shown when the thread is scrolled up more than a screen-height: a pill with the number of messages that came since.
    private var jumpButton: some View {
        let count = place.newCount(in: entries)
        return Button { place.jump() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold))
                Text(count == 0 ? "Latest" : "\(count > 99 ? "99+" : "\(count)") new").monospacedDigit()
            }
            .font(.system(size: 12)).foregroundStyle(Tok.ink)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Tok.raise, in: Capsule())
            .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
            .shadow(color: .black.opacity(Tok.shadowOpacity(0.35)), radius: 7, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, Tok.Space.s).padding(.bottom, Tok.Space.l)
        .help(Self.jumpHelp)
        .accessibilityLabel(count > 0 ? "\(Self.jumpHelp), \(count) new" : Self.jumpHelp)
    }

    private var list: some View {
        let built = ChatRows.build(entries: entries, previous: previous)
        let rows = conversationOnly ? ChatSearch.conversationOnly(built) : built
        let split = previous.isEmpty ? 0 : Self.firstNewRow(rows, entries: entries)
        return VStack(alignment: .leading, spacing: Tok.Space.m) {
            if canLoadEarlier {
                LoadEarlierRow(from: earlierFrom) {
                    keepRow = rows.first { if case .day = $0 { false } else if case .gap = $0 { false } else { true } }?.id
                    onLoadEarlier()
                }
            }
            if split > 0 {
                Text("Previous conversation").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                VStack(alignment: .leading, spacing: Tok.Space.m) { ForEach(rows[..<split]) { row($0) } }.opacity(0.6)
                HStack(spacing: Tok.Space.s) {
                    Rectangle().fill(Tok.line).frame(height: 1)
                    Text("New conversation").font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize()
                    Rectangle().fill(Tok.line).frame(height: 1)
                }
            }
            ForEach(rows[split...]) { row($0) }
            if let held { heldBubble(held) }
            if working { workingLine }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .environment(\.chatColumnWidth, columnWidth)
        // N350: the rows sit a little inside the composer's edges; the measured column (bubbles' 75%) is the inset one.
        .padding(.horizontal, Self.contentInset)
    }

    /// N350: the messages' extra side gap inside the column the composer spans (`CommandBar.inset` from the tile edge).
    static let contentInset: CGFloat = Tok.Space.m

    /// The rows' leading/trailing distance from the tile edge.
    static var contentEdge: CGFloat { CommandBar.inset + contentInset }

    /// The first row of the new conversation: the first one holding an entry of `entries`, with the dividers right above it.
    static func firstNewRow(_ rows: [ChatRow], entries: [ChatEntry]) -> Int {
        let ids = Set(entries.map(\.id))
        guard var i = rows.firstIndex(where: { row in
            switch row {
            case .day, .gap: false
            case .system(let events): events.contains { ids.contains($0.id) }
            case .user(let e), .turn(let e), .tools(let e), .summary(let e): ids.contains(e.id)
            }
        }) else { return rows.count }
        while i > 0, case .day = rows[i - 1] { i -= 1 }
        while i > 0, case .gap = rows[i - 1] { i -= 1 }
        return i
    }

    @ViewBuilder private func row(_ row: ChatRow) -> some View {
        switch row {
        case .day(let date): DayDivider(date: date)
        case .gap(let seconds): GapDivider(seconds: seconds)
        case .system(let events): SystemRow(events: events, open: openAll, opened: opened, onRetry: onRetry, onRemove: onRemove)
        case .turn(let entry): TurnRow(entry: entry, label: agentLabel, role: agentRole, openTools: openAll, opened: opened, onQuote: onQuote)
        case .tools(let entry): ToolsLine(summary: entry.text, lines: entry.tools, row: entry.id, open: openAll, opened: opened)
        case .summary(let entry): SummaryRow(entry: entry)
        case .user(let entry):
            UserRow(entry: entry, youFill: youFill, onEditAgain: onEditAgain, onRetry: onRetry, onRemove: onRemove) { images, i in
                viewing = ViewerSet(images: images, index: i)
            }
        }
    }

    static func needsAction(_ pending: ChatEntry.Pending) -> Bool { pending != .queued }
    static let notSeenText = "Not seen in the conversation"

    /// "PM is working · Bash · git log… · 0:12": the turn's last tool use and the time since the message it answers.
    private var workingLine: some View {
        let tool = Self.lastTool(entries)
        let since = Self.turnStart(entries)
        return HStack(spacing: 8) {
            Circle().fill(Tok.work).frame(width: 6, height: 6)
            HStack(spacing: 0) {
                Text("\(agentLabel) is working")
                if let tool { Text(" · "); Text(tool).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
                if let since {
                    if snapshot || now != nil {
                        Text(" · " + ChatRowText.elapsed((now ?? Date()).timeIntervalSince(since)))
                    } else {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(" · " + ChatRowText.elapsed(context.date.timeIntervalSince(since))).monospacedDigit()
                        }
                    }
                }
            }
            .font(.system(size: 12)).foregroundStyle(Tok.ink2)
            .accessibilityElement(children: .combine)
            if let onStop {
                Button(action: onStop) {
                    Text("Stop").font(Tok.Font.small).foregroundStyle(Tok.ink2)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Tok.raise, in: Capsule())
                        .overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Self.stopHelp).accessibilityLabel(Self.stopHelp)
                .tutorialAnchor(.chatStop)
            }
        }
    }

    static let stopHelp = "Interrupt the PM (Esc)"

    /// The last tool use of the turn under way (after the last message to the agent).
    static func lastTool(_ entries: [ChatEntry]) -> String? {
        for entry in entries.reversed() {
            if entry.kind == .user || entry.kind == .panel { return nil }
            if let last = entry.tools.last { return last }
        }
        return nil
    }

    /// When the message the agent is answering came in.
    static func turnStart(_ entries: [ChatEntry]) -> Date? {
        entries.last { ($0.kind == .user || $0.kind == .panel) && $0.pending == nil && $0.time != nil }?.time
    }

    private func heldText(_ text: String) -> some View {
        Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    /// The user's message during its hold: the bubble as it will look, and under it the countdown with Edit and Undo.
    private func heldBubble(_ held: HeldMessage) -> some View {
        let (images, files) = Attachments.split(held.stored)
        return VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .trailing, spacing: 4) {
                if !images.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                            ThreadImage(image: image) { viewing = ViewerSet(images: images, index: i) }
                        }
                    }
                }
                if !files.isEmpty { FileChips(files: files) }
                if !held.text.isEmpty {
                    let parts = ChatQuote.split(held.text)
                    if let quote = parts.quote {
                        SentQuoteMessage(quote: quote) { if !parts.text.isEmpty { heldText(parts.text) } }
                    } else {
                        heldText(held.text)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(youFill, in: UserRow.shape)
            .overlay(UserRow.shape.strokeBorder(Tok.youBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .frame(maxWidth: UserRow.maxWidth(column: columnWidth), alignment: .trailing)
            HStack(spacing: Tok.Space.s) {
                countdown(held)
                Button("Edit", action: onEdit).buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work)
                    .help("Take the message back into the input to change it")
                Button("Undo", action: onUndo).buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.work)
                    .help("Do not send; put the message back into the input")
            }
        }
        .padding(.leading, 36)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// A snapshot draws the full hold; on screen the number counts down once a second.
    @ViewBuilder private func countdown(_ held: HeldMessage) -> some View {
        if snapshot {
            Text(HeldMessage.mark(seconds: ChatSendDelay.seconds)).font(Tok.Font.small).foregroundStyle(Tok.ink3)
        } else {
            SwiftUI.TimelineView(.periodic(from: .now, by: 0.25)) { context in
                Text(HeldMessage.mark(seconds: held.secondsLeft(now: context.date))).font(Tok.Font.small).foregroundStyle(Tok.ink3).monospacedDigit()
            }
        }
    }
}
