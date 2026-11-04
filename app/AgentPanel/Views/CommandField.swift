import SwiftUI
import AppKit

/// The top bar's middle (design B, N134): "Ask the PM, jump to a card or a screen…". ⌘K anywhere in the window puts the focus in it;
/// what is typed is searched by `CommandSearch` and the results drop down under it (↑/↓ and Return, or a click). Esc clears it and
/// gives the focus back to the window, where the chat input takes it (N125).
struct CommandField: View {
    @Binding var query: String
    /// The results for a query. Keys are handled before SwiftUI draws again, so they search what the input holds at that moment.
    let search: (String) -> [CommandSearch.Row]
    let onRun: (CommandSearch.Target) -> Void
    @State private var selection = 0
    @State private var focused = false
    /// The pointer is over the list: a click there moves the focus out of the field before the row runs, so the list stays.
    @State private var overList = false
    /// The field's width: a crowded top bar narrows it, and below `hintMinWidth` the ⌘K hint gives its room to the text (N388).
    @State private var width: CGFloat = 520
    @Environment(\.snapshotMode) private var snapshot

    static let identifier = "command-field"
    static let placeholder = "Ask the PM, jump to a card or a screen…"
    static let height: CGFloat = 30
    /// The list keeps room for a card's title when the window is narrow and the field shrinks.
    static let listMinWidth: CGFloat = 420
    static let hintMinWidth: CGFloat = 200

    var body: some View {
        let rows = search(query)
        let listShown = !rows.isEmpty && (focused || overList || snapshot)
        HStack(spacing: Tok.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Tok.ink3)
            input
            if width >= Self.hintMinWidth {
                Text("⌘K").font(Tok.Font.mono).foregroundStyle(Tok.ink3)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Tok.line))
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Tok.Space.s + 2)
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Tok.work.opacity(0.6) : Tok.line))
        .overlay(alignment: .topLeading) {
            if listShown {
                CommandResults(rows: rows, selection: selection, onHover: { selection = $0 }, onRun: { run($0) })
                    .frame(minWidth: Self.listMinWidth)
                    // An overlay is offered the field's own height: the list takes the height its rows need.
                    .fixedSize(horizontal: false, vertical: true)
                    .onHover { overList = $0 }
                    .offset(y: Self.height + Tok.Space.xs)
            }
        }
        .onChange(of: rows.count) { _, count in selection = min(selection, max(count - 1, 0)) }
        .help("Ask the PM, open a card, a screen, a project or a note (⌘K)")
    }

    /// A snapshot cannot draw an AppKit text view, so it shows the text (or placeholder) as plain text.
    @ViewBuilder private var input: some View {
        if snapshot {
            Text(query.isEmpty ? Self.placeholder : query).font(Tok.Font.body).foregroundStyle(query.isEmpty ? Tok.ink3 : Tok.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CommandInput(text: $query, onEdit: { selection = 0 }, onMove: { selection = CommandSearch.moved(selection, by: $0, count: search(query).count) },
                         onSubmit: { let rows = search(query); return rows.indices.contains(selection) ? run(rows[selection]) : false },
                         onCancel: { query = "" }, onFocus: { focused = $0 })
                .overlay(alignment: .leading) {
                    if query.isEmpty { Text(Self.placeholder).font(Tok.Font.body).foregroundStyle(Tok.ink3).lineLimit(1).allowsHitTesting(false) }
                }
                .accessibilityLabel("Command")
        }
    }

    /// Runs a row that can run; the field is cleared. Returns whether it ran (the input then gives the focus back).
    @discardableResult private func run(_ row: CommandSearch.Row) -> Bool {
        guard row.disabledReason == nil else { return false }
        query = ""; overList = false
        onRun(row.target)
        return true
    }
}

/// The list under the field: rows grouped by kind with a small heading, "Ask the PM" last.
struct CommandResults: View {
    let rows: [CommandSearch.Row]
    let selection: Int
    var onHover: (Int) -> Void = { _ in }
    var onRun: (CommandSearch.Row) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if let heading = row.kind.heading, i == 0 || rows[i - 1].kind != row.kind {
                    Text(heading.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Tok.ink3)
                        .padding(.horizontal, Tok.Space.s).padding(.top, i == 0 ? 2 : Tok.Space.s).padding(.bottom, 2)
                }
                if row.kind == .askPM, i > 0 { Divider().overlay(Tok.line).padding(.vertical, 2) }
                CommandResultRow(row: row, selected: i == selection)
                    .onHover { if $0 { onHover(i) } }
                    .onTapGesture { onRun(row) }
            }
        }
        .padding(Tok.Space.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.line))
        .shadow(color: .black.opacity(Tok.shadowOpacity(0.45)), radius: 18, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Results")
    }
}

private struct CommandResultRow: View {
    let row: CommandSearch.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: Tok.Space.s) {
            icon.frame(width: 16)
            if let badge = row.badge { Text(badge).font(Tok.Font.mono.weight(.semibold)).foregroundStyle(Tok.ink2) }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(Tok.Font.body).foregroundStyle(row.disabledReason == nil ? Tok.ink : Tok.ink3).lineLimit(1).truncationMode(.tail)
                if let reason = row.disabledReason {
                    Text(reason).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tok.Space.s)
            if row.disabledReason == nil, let detail = row.detail { Text(detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1) }
            if selected && row.disabledReason == nil { Text("↵").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
        }
        .padding(.horizontal, Tok.Space.s).padding(.vertical, row.disabledReason == nil ? 0 : Tok.Space.xs).frame(minHeight: 28)
        .background(selected ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help(row.disabledReason ?? row.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch row.target {
        case .card: StatusDot(status: row.status ?? .todo)
        case .screen(let screen): symbol(screen.railSymbol)
        case .project: symbol("folder")
        case .note: symbol("note.text")
        case .askPM: symbol("bubble.left").foregroundStyle(Tok.work)
        case .tour, .allTours: symbol("questionmark.circle")
        }
    }

    private func symbol(_ name: String) -> some View { Image(systemName: name).font(.system(size: 12)).foregroundStyle(Tok.ink2) }
}

/// The field's one-line AppKit text view: ↑/↓, Return and Esc are decided in its own keyDown (Return is left to an input method that is
/// composing), and ⌘K, offered to every view of the window as a key equivalent, puts the focus in it.
struct CommandInput: NSViewRepresentable {
    @Binding var text: String
    /// The text changed: the highlight goes back to the first row.
    var onEdit: () -> Void
    var onMove: (Int) -> Void
    /// Return: true when a row ran, and the focus goes back to the window.
    var onSubmit: () -> Bool
    var onCancel: () -> Void
    var onFocus: (Bool) -> Void

    final class TextView: NSTextView {
        var onMove: (Int) -> Void = { _ in }
        var onSubmit: () -> Bool = { false }
        var onCancel: () -> Void = {}
        var onFocus: (Bool) -> Void = { _ in }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command, event.charactersIgnoringModifiers?.lowercased() == "k",
                  let window, !isHiddenOrHasHiddenAncestor else { return super.performKeyEquivalent(with: event) }
            window.makeFirstResponder(self)
            selectAll(nil)
            return true
        }

        override func keyDown(with event: NSEvent) {
            if !hasMarkedText() {
                switch event.keyCode {
                case 125: onMove(1); return
                case 126: onMove(-1); return
                case 36, 76: if onSubmit() { string = ""; giveBackFocus() }; return
                case 53: onCancel(); string = ""; giveBackFocus(); return
                default: break
                }
            }
            super.keyDown(with: event)
        }

        /// The window itself becomes the first responder, so the chat input (when shown) takes the focus as it does when a field closes.
        private func giveBackFocus() { window?.makeFirstResponder(nil) }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { DispatchQueue.main.async { [onFocus] in onFocus(true) } }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { DispatchQueue.main.async { [onFocus] in onFocus(false) } }
            return ok
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandInput
        init(_ parent: CommandInput) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            // One line: a pasted line break becomes a space.
            let line = view.string.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            if line != view.string { view.string = line }
            parent.text = line
            parent.onEdit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TextView {
        let view = TextView()
        view.setAccessibilityIdentifier(CommandField.identifier)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.font = ChatInput.font
        view.textColor = NSColor(Tok.ink)
        view.insertionPointColor = NSColor(Tok.ink)
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = 1
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.unregisterDraggedTypes()
        view.string = text
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        view.onMove = onMove
        view.onSubmit = onSubmit
        view.onCancel = onCancel
        view.onFocus = onFocus
        if view.string != text, !view.hasMarkedText() { view.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: ceil(ChatInput.lineHeight))
    }
}
