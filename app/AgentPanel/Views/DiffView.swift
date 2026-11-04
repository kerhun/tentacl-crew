import SwiftUI
import AppKit

/// What the Changes tab starts with (snapshots and tests; the real tab reads it with a `TaskDiffReader`).
struct DiffPreload {
    var files: [DiffFileEntry]
    var diffs: [String: TaskFileDiff] = [:]
    var selected: String? = nil
    /// The branch head the comments belong to (the real tab reads it from the branch).
    var head: String? = nil
}

/// What a diff needs to show and take comments (N249): the store, the card's key in it and the head commit they are made on.
struct DiffCommentContext {
    let store: DiffCommentStore
    let key: String
    let head: String
}

/// The Changes tab (N204): the branch's files against the merge base with the main branch, and the selected file's unified diff under them.
/// ↑/↓ move between files while the list has focus (a click on a file gives it).
struct ChangesPane: View {
    let reader: TaskDiffReader?
    var preload: DiffPreload? = nil
    var openInXcode: ((DiffFileEntry) -> Void)? = nil
    var openInTerminal: ((DiffFileEntry) -> Void)? = nil
    /// Diff comments (N249): the store and the card's key; `onSend` sends the fix request text and says whether it reached the agent.
    var comments: DiffCommentStore? = nil
    var commentKey: String? = nil
    var onSend: ((String) async -> Bool)? = nil

    @State private var files: [DiffFileEntry]?
    @State private var head: String?
    @State private var error: String?
    @State private var selected: String?
    @State private var diffs: [String: TaskFileDiff] = [:]
    @FocusState private var listFocused: Bool

    private var shownFiles: [DiffFileEntry]? { files ?? preload?.files }
    private var current: String? { selected ?? preload?.selected ?? shownFiles?.first?.id }

    private var commentContext: DiffCommentContext? {
        guard let comments, let commentKey, let h = head ?? preload?.head else { return nil }
        return DiffCommentContext(store: comments, key: commentKey, head: h)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            if let error {
                Text(error).font(Tok.Font.small).foregroundStyle(Tok.ink3).textSelection(.enabled)
            } else if let list = shownFiles {
                if list.isEmpty { Text("No changes against the main branch.").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
                else {
                    if let ctx = commentContext { commentBar(ctx) }
                    fileList(list)
                    if let id = current, let entry = list.first(where: { $0.id == id }) {
                        if let d = diffs[id] ?? preload?.diffs[id] {
                            DiffView(entry: entry, file: d, openInXcode: openInXcode.map { f in { f(entry) } },
                                     openInTerminal: openInTerminal.map { f in { f(entry) } }, comments: commentContext)
                                .id(id)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the diff…").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the changes…").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            }
        }
        .task {
            guard let reader, files == nil, preload == nil else { return }
            switch await reader.files() {
            case .success(let list): files = list
            case .failure(let e): error = e.text
            }
        }
        .task {
            guard let reader, comments != nil, head == nil, preload?.head == nil else { return }
            head = await reader.head()
        }
        .onChange(of: head ?? preload?.head, initial: true) { _, h in
            if let h, let comments, let commentKey { comments.sync(commentKey, head: h) }
        }
        .task(id: current) {
            guard let reader, let id = current, diffs[id] == nil, preload?.diffs[id] == nil,
                  let entry = shownFiles?.first(where: { $0.id == id }) else { return }
            let d = await reader.diff(entry)
            diffs[id] = d
        }
    }

    /// "N comments · Send as fix request" over the file list, and the note about comments dropped for a newer commit.
    private func commentBar(_ ctx: DiffCommentContext) -> some View {
        let count = ctx.store.comments(ctx.key).count
        let sending = ctx.store.sending.contains(ctx.key)
        return VStack(alignment: .leading, spacing: Tok.Space.xs) {
            if let dropped = ctx.store.dropped[ctx.key] {
                HStack(spacing: Tok.Space.s) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Tok.ink3)
                    Text(dropped == 1 ? "1 comment was on an older commit and was dropped." : "\(dropped) comments were on an older commit and were dropped.")
                        .font(Tok.Font.small).foregroundStyle(Tok.ink2)
                    Button { ctx.store.dismissDropped(ctx.key) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink3).help("Hide this note")
                }
            }
            HStack(spacing: Tok.Space.s) {
                Image(systemName: "text.bubble").foregroundStyle(count > 0 ? Tok.work : Tok.ink3)
                if count > 0 {
                    Text("\(count) comment\(count == 1 ? "" : "s")").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.ink)
                } else {
                    Text("Hover a line and click + to comment; ⇧-click another + for a range.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
                Spacer(minLength: Tok.Space.s)
                if sending { ProgressView().controlSize(.small) }
                Button("Send as fix request") {
                    guard let onSend else { return }
                    Task { await ctx.store.send(ctx.key, using: onSend) }
                }
                .buttonStyle(PanelButtonStyle(primary: true))
                .disabled(count == 0 || sending || onSend == nil)
                .help(count == 0 ? "Comment on a line first" : "Write the comments into the card's Fix notes and tell the agent")
            }
        }
        .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(count > 0 ? Tok.work.opacity(0.5) : Tok.line))
    }

    private func fileList(_ list: [DiffFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list) { entry in
                let on = entry.id == current
                HStack(spacing: Tok.Space.s) {
                    Text(entry.letter).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Self.tint(entry.status)).frame(width: 12)
                    Text(entry.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(on ? Tok.ink : Tok.ink2)
                        .lineLimit(1).truncationMode(.middle)
                    if let old = entry.oldPath { Text("← \(old)").font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 0)
                    if let ctx = commentContext, case let n = ctx.store.comments(ctx.key).filter({ $0.path == entry.path }).count, n > 0 {
                        Label("\(n)", systemImage: "text.bubble").font(Tok.Font.small).monospacedDigit().foregroundStyle(Tok.work)
                            .help("\(n) comment\(n == 1 ? "" : "s") on this file")
                    }
                }
                .padding(.horizontal, Tok.Space.s).frame(height: 24)
                .background(on ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { selected = entry.id; listFocused = true }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(Tok.Space.xs)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(listFocused ? Tok.ink3 : Tok.line))
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) { move(-1, in: list) }
        .onKeyPress(.downArrow) { move(1, in: list) }
    }

    private func move(_ delta: Int, in list: [DiffFileEntry]) -> KeyPress.Result {
        guard let next = Self.step(from: current, in: list.map(\.id), by: delta) else { return .ignored }
        selected = next
        return .handled
    }

    /// The file `delta` steps away, stopping at the ends.
    static func step(from current: String?, in ids: [String], by delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }

    static func tint(_ status: DiffFileEntry.Status) -> Color {
        switch status {
        case .added: return Tok.go
        case .deleted: return Tok.stop
        case .renamed, .copied: return Tok.work
        default: return Tok.ink2
        }
    }
}

/// One file's unified diff: old and new line numbers, added and removed lines on a faint green or red, hunk headers, unchanged stretches
/// folded behind "Show N more lines", long lines scrolling sideways.
struct DiffView: View {
    let entry: DiffFileEntry
    let file: TaskFileDiff
    var openInXcode: (() -> Void)? = nil
    var openInTerminal: (() -> Void)? = nil
    /// Comments on the lines (N249); nil shows the diff without them.
    var comments: DiffCommentContext? = nil
    /// Rows whose comment box starts open (snapshots).
    var composing: ClosedRange<Int>? = nil
    @State private var expanded: Set<Int>
    @State private var copied = false

    init(entry: DiffFileEntry, file: TaskFileDiff, expanded: Set<Int> = [], openInXcode: (() -> Void)? = nil, openInTerminal: (() -> Void)? = nil,
         comments: DiffCommentContext? = nil, composing: ClosedRange<Int>? = nil) {
        self.entry = entry; self.file = file; self.openInXcode = openInXcode; self.openInTerminal = openInTerminal; self.comments = comments
        self.composing = composing
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            header
            if let error = file.error {
                Text(error).font(Tok.Font.small).foregroundStyle(Tok.ink3).textSelection(.enabled)
            } else if let d = file.diff {
                if d.binary {
                    Self.notice("Binary file: no text to compare.")
                } else if d.hunks.isEmpty {
                    Self.notice(d.kind == .modified ? "No line changes." : "The content is unchanged.")
                } else {
                    let rows = d.rows(newText: file.newText, expanded: expanded)
                    let cut = rows.count > FileDiff.rowLimit
                    if cut { largeNotice(rows.count) }
                    let shown = cut ? Array(rows.prefix(FileDiff.rowLimit)) : rows
                    let mine = comments.map { c in c.store.comments(c.key).filter { $0.path == entry.path } } ?? []
                    let placed = DiffCommentLayout.anchors(rows: shown, comments: mine)
                    DiffLines(rows: shown, path: entry.path, comments: comments, under: placed.under, composing: composing) { expanded.insert($0) }
                    if cut { largeNotice(rows.count) }
                    if let ctx = comments, !placed.unplaced.isEmpty {
                        VStack(alignment: .leading, spacing: Tok.Space.xs) {
                            Text("On lines not shown now:").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                            ForEach(placed.unplaced) { DiffCommentRow(comment: $0, context: ctx) }
                        }
                    }
                }
            } else {
                Self.notice("No changes in this file.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerLine
            if let note = file.diff?.note { Text(note).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
        }
    }

    private var headerLine: some View {
        HStack(spacing: Tok.Space.s) {
            Text(entry.path).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            if let d = file.diff, !d.binary {
                if d.addedCount > 0 { Text("+\(d.addedCount)").foregroundStyle(Tok.go) }
                if d.removedCount > 0 { Text("−\(d.removedCount)").foregroundStyle(Tok.stop) }
            }
            Spacer(minLength: Tok.Space.s)
            if !file.raw.isEmpty {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.raw, forType: .string); copied = true
                }
                .buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink2).help("Copy this file's diff")
            }
        }
        .font(.system(size: 12)).monospacedDigit()
    }

    private func largeNotice(_ total: Int) -> some View {
        HStack(spacing: Tok.Space.m) {
            Text("Large diff: showing the first \(FileDiff.rowLimit) of \(total) lines.").font(Tok.Font.small).foregroundStyle(Tok.ink2)
            if let openInXcode { Button("Open in Xcode", action: openInXcode).buttonStyle(PanelButtonStyle()) }
            if let openInTerminal { Button("Open in Terminal", action: openInTerminal).buttonStyle(PanelButtonStyle()) }
        }
    }

    static func notice(_ text: String) -> some View {
        Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink3)
            .padding(Tok.Space.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}

/// The rows: a fixed gutter (old, new) and the code, which scrolls sideways; every row is one line high, so the two columns and the row
/// backgrounds line up. With comments (N249) a hovered line shows a "+" in the gutter; a comment (or the box for a new one) takes a slot of
/// fixed height under its row in every column, and the full-width comment views lie over those slots.
private struct DiffLines: View {
    let rows: [FileDiff.Row]
    var path = ""
    var comments: DiffCommentContext? = nil
    var under: [Int: [DiffComment]] = [:]
    let onExpand: (Int) -> Void
    @Environment(\.snapshotMode) private var snapshot
    @State private var hovered: Int?
    /// The rows the new comment is for (either way round) while its box is open.
    @State private var pick: Pick?
    @State private var draft = ""

    init(rows: [FileDiff.Row], path: String = "", comments: DiffCommentContext? = nil, under: [Int: [DiffComment]] = [:],
         composing: ClosedRange<Int>? = nil, onExpand: @escaping (Int) -> Void) {
        self.rows = rows; self.path = path; self.comments = comments; self.under = under; self.onExpand = onExpand
        _pick = State(initialValue: composing.map { Pick(anchor: $0.lowerBound, end: $0.upperBound) })
    }

    struct Pick: Equatable {
        var anchor: Int
        var end: Int
        var range: ClosedRange<Int> { min(anchor, end)...max(anchor, end) }
    }

    enum Slot: Hashable {
        case row(Int), comment(UUID), composer
        var height: CGFloat {
            switch self {
            case .row: return DiffLines.rowHeight
            case .comment: return DiffCommentRow.height
            case .composer: return DiffCommentComposer.height
            }
        }
    }

    static let rowHeight: CGFloat = 18
    static let numberWidth: CGFloat = 38
    static let plusWidth: CGFloat = 18

    private var gutterWidth: CGFloat { (comments == nil ? 0 : Self.plusWidth) + Self.numberWidth * 2 }

    private var slots: [Slot] {
        var out: [Slot] = []
        for i in rows.indices {
            out.append(.row(i))
            out += (under[i] ?? []).map { .comment($0.id) }
            if let pick, pick.range.upperBound == i { out.append(.composer) }
        }
        return out
    }

    var body: some View {
        let slots = slots
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(slots, id: \.self) { slot in
                    if case .row(let i) = slot {
                        Self.fill(rows[i]).overlay(pick?.range.contains(i) == true ? Tok.work.opacity(0.16) : .clear).frame(height: slot.height)
                    } else {
                        Tok.raise.frame(height: slot.height)
                    }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(slots, id: \.self) { slot in
                        if case .row(let i) = slot { gutter(rows[i], at: i) } else { Color.clear.frame(width: gutterWidth, height: slot.height) }
                    }
                }
                Rectangle().fill(Tok.line).frame(width: 1)
                sideways {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(slots, id: \.self) { slot in
                            if case .row(let i) = slot { code(rows[i]) } else { Color.clear.frame(width: 1, height: slot.height) }
                        }
                    }
                    .padding(.horizontal, Tok.Space.s)
                }
            }
            if let ctx = comments, slots.contains(where: { if case .row = $0 { return false } else { return true } }) {
                VStack(spacing: 0) {
                    ForEach(slots, id: \.self) { slot in commentLayer(slot, ctx) }
                }
            }
        }
        // The gutter's divider would otherwise take all the height it is offered.
        .fixedSize(horizontal: false, vertical: true)
        .font(Tok.Font.mono)
        .background(Tok.pane)
        .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        // Expanding a gap moves the rows under an open box.
        .onChange(of: rows.count) { pick = nil }
    }

    @ViewBuilder private func commentLayer(_ slot: Slot, _ ctx: DiffCommentContext) -> some View {
        switch slot {
        case .row:
            Color.clear.frame(height: slot.height).allowsHitTesting(false)
        case .comment(let id):
            if let c = under.values.joined().first(where: { $0.id == id }) {
                DiffCommentRow(comment: c, context: ctx).padding(.leading, gutterWidth - 8).frame(height: slot.height)
            }
        case .composer:
            if let pick {
                let lines = DiffCommentLayout.lines(rows: rows, from: pick.anchor, to: pick.end)
                DiffCommentComposer(text: $draft, lines: lines.count,
                                    onSave: {
                                        if ctx.store.add(ctx.key, head: ctx.head, path: path, lines: lines, text: draft) != nil { self.pick = nil; draft = "" }
                                    },
                                    onCancel: { self.pick = nil; draft = "" })
                    .padding(.leading, gutterWidth - 8).frame(height: slot.height)
            }
        }
    }

    @ViewBuilder private func sideways<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if snapshot { DiffLeadingClip { content().fixedSize() }.clipped() }
        else { ScrollView(.horizontal) { content().fixedSize() } }
    }

    private func gutter(_ row: FileDiff.Row, at i: Int) -> some View {
        HStack(spacing: 0) {
            switch row {
            case .line(let l):
                plus(at: i); number(l.old); number(l.new)
            case .gap, .hunk:
                Color.clear.frame(width: gutterWidth)
            }
        }
        .foregroundStyle(Tok.ink3).frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = i } else if hovered == i { hovered = nil } }
    }

    /// The gutter's "+": opens the comment box under the row; with ⇧ it stretches the open box's range to this row.
    @ViewBuilder private func plus(at i: Int) -> some View {
        if comments != nil {
            let on = hovered == i || pick?.range.contains(i) == true
            Button {
                if NSEvent.modifierFlags.contains(.shift), var p = pick { p.end = i; pick = p } else { pick = Pick(anchor: i, end: i); draft = "" }
            } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                    .frame(width: 14, height: 14).background(Tok.work, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .opacity(on ? 1 : 0)
            .frame(width: Self.plusWidth)
            .help("Comment on this line (⇧-click another line's + for a range)")
            .accessibilityLabel("Comment on this line")
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "").monospacedDigit().frame(width: Self.numberWidth, alignment: .trailing).padding(.trailing, 0)
    }

    @ViewBuilder private func code(_ row: FileDiff.Row) -> some View {
        Group {
            switch row {
            case .hunk(let header):
                Text(header).foregroundStyle(Tok.work)
            case .gap(let id, let count, _, _):
                Button { onExpand(id) } label: {
                    Text("⋯ Show \(count) more line\(count == 1 ? "" : "s")").foregroundStyle(Tok.ink2).underline()
                }
                .buttonStyle(.plain).help("Show the unchanged lines git left out")
            case .line(let l):
                HStack(spacing: 6) {
                    Text(Self.sign(l.kind)).foregroundStyle(l.kind == .added ? Tok.go : l.kind == .removed ? Tok.stop : Tok.ink3)
                    Text(Self.display(l.text)).foregroundStyle(Tok.ink)
                    if l.noNewline { Text("⏎̸ no newline at end").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                }
            }
        }
        .lineLimit(1).fixedSize()
        .frame(height: Self.rowHeight, alignment: .leading)
    }

    static func sign(_ kind: FileDiff.Line.Kind) -> String {
        switch kind { case .added: return "+"; case .removed: return "−"; case .context: return " " }
    }

    /// Tabs as four spaces (a Text draws a tab at an odd width).
    static func display(_ text: String) -> String { text.replacingOccurrences(of: "\t", with: "    ") }

    static func fill(_ row: FileDiff.Row) -> Color {
        switch row {
        case .hunk: return Tok.work.opacity(0.08)
        case .gap: return Tok.raise
        case .line(let l):
            switch l.kind {
            case .added: return Tok.go.opacity(0.14)
            case .removed: return Tok.stop.opacity(0.14)
            case .context: return .clear
            }
        }
    }
}

/// A saved comment under its row: the comment in one line (the whole text in its help), Edit and Remove; Edit turns it into a field
/// (Enter saves, Esc cancels, an emptied comment is removed).
struct DiffCommentRow: View {
    let comment: DiffComment
    let context: DiffCommentContext
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: Tok.Space.s) {
            Image(systemName: "text.bubble.fill").font(.system(size: 11)).foregroundStyle(Tok.work)
            if comment.lines.count > 1 {
                Text("\(comment.lines.count) lines").font(Tok.Font.small).monospacedDigit().foregroundStyle(Tok.ink3).help(comment.location)
            }
            if editing {
                TextField("Comment", text: $text).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit { context.store.edit(context.key, id: comment.id, text: text); editing = false }
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
            } else {
                Text(comment.text).font(.system(size: 12)).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail).help(comment.text)
                Spacer(minLength: Tok.Space.s)
                Button("Edit") { text = comment.text; editing = true }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink2)
                Button("Remove") { context.store.remove(context.key, id: comment.id) }.buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink2)
            }
        }
        .padding(.horizontal, Tok.Space.s).frame(height: Self.height - 6)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.work.opacity(0.45)))
        .padding(.vertical, 3).padding(.trailing, Tok.Space.s)
    }
}

/// The one-line box for a new comment: Enter saves, Esc cancels.
struct DiffCommentComposer: View {
    @Binding var text: String
    /// How many lines the comment is for.
    let lines: Int
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshot

    static let height: CGFloat = 34

    var body: some View {
        HStack(spacing: Tok.Space.s) {
            if lines > 1 { Text("\(lines) lines").font(Tok.Font.small).monospacedDigit().foregroundStyle(Tok.ink3) }
            let prompt = lines > 1 ? "Comment on these lines · Enter saves, Esc cancels" : "Comment on this line · Enter saves, Esc cancels"
            // ImageRenderer cannot draw a text field.
            if snapshot { Text(text.isEmpty ? prompt : text).font(.system(size: 12)).foregroundStyle(text.isEmpty ? Tok.ink3 : Tok.ink).frame(maxWidth: .infinity, alignment: .leading) }
            else {
                TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(onSave)
                    .onExitCommand(perform: onCancel)
            }
            Button("Cancel", action: onCancel).buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.ink2)
        }
        .padding(.horizontal, Tok.Space.s).frame(height: Self.height - 8)
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.work))
        .padding(.vertical, 4).padding(.trailing, Tok.Space.s)
        .onAppear { focused = true }
    }
}

/// As wide as offered, the content at its own size from the leading edge (the snapshot stand-in of the sideways scroll view).
private struct DiffLeadingClip: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? ideal.width, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .unspecified)
    }
}

/// Opening a large diff elsewhere: the file in Xcode (from the agent's worktree while it exists), or the whole diff in Terminal (git's pager).
enum DiffOpening {
    static func openInXcode(_ entry: DiffFileEntry, project: ProjectConfig, branch: String) {
        let worktree = project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch))
        let inTree = worktree.appendingPathComponent(entry.path)
        let url = FileManager.default.fileExists(atPath: inTree.path) ? inTree : project.repoURL.appendingPathComponent(entry.path)
        guard let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open([url], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openInTerminal(_ entry: DiffFileEntry, reader: TaskDiffReader) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tentacl-diff-\(UUID().uuidString).command")
        try? terminalScript(entry, reader: reader).write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        Task { do { _ = try await CommandFileOpener.open(file) } catch { try? FileManager.default.removeItem(at: file) } }
    }

    /// The `.command` file: removes itself, then shows the diff in git's pager.
    static func terminalScript(_ entry: DiffFileEntry, reader: TaskDiffReader) -> String {
        let paths = [entry.oldPath, entry.path].compactMap { $0 }.map(quote).joined(separator: " ")
        return "#!/bin/zsh\nrm -f \"$0\"\ngit -C \(quote(reader.repoPath)) diff -M \(quote(reader.range)) -- \(paths)\n"
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
