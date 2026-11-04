import SwiftUI
import AppKit
import SwiftTerm

/// ⌘F find in one live terminal (N252), over everything the view holds (scrollback included). Search itself is SwiftTerm's
/// (`findNext` / `findPrevious` / `searchMatchSummary`); this keeps the query, the count and the bar.
@MainActor @Observable
final class TerminalFind {
    var isOpen = false
    var query = ""
    var caseSensitive = false
    /// 1-based position of the current match (0: none) and the number of matches.
    private(set) var index = 0
    private(set) var total = 0
    /// Bumped to ask the field for the keyboard (⌘F again while open).
    private(set) var focusRequest = 0

    @ObservationIgnored private weak var view: LiveTerminalNSView?
    @ObservationIgnored private var wasAtBottom = true
    @ObservationIgnored private var bar: NSHostingView<TerminalFindBar>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(view: LiveTerminalNSView) { self.view = view }

    private var options: SearchOptions { SearchOptions(caseSensitive: caseSensitive) }
    var countText: String { query.isEmpty ? "" : total == 0 ? "No matches" : index == 0 ? "\(total) matches" : "\(index) of \(total)" }

    func open() {
        guard let view else { return }
        if isOpen { focusRequest += 1; return }
        wasAtBottom = !view.canScroll || view.scrollPosition >= 1
        isOpen = true
        let bar = NSHostingView(rootView: TerminalFindBar(find: self))
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
        self.bar = bar
        focusRequest += 1
        if !query.isEmpty { search(from: .last) }
    }

    func close() {
        guard isOpen, let view else { return }
        isOpen = false
        refreshTask?.cancel(); refreshTask = nil
        bar?.removeFromSuperview(); bar = nil
        view.clearSearch()
        index = 0; total = 0
        view.window?.makeFirstResponder(view)
        if wasAtBottom { view.scrollTo(row: Int.max) }
    }

    func step(forward: Bool) {
        guard isOpen, let view, !query.isEmpty else { return }
        _ = forward ? view.findNext(query, options: options) : view.findPrevious(query, options: options)
        recount()
    }

    /// The query or the case option changed: start again from the newest match.
    func queryChanged() { search(from: .last) }

    private enum Start { case first, last }
    private func search(from start: Start) {
        guard let view else { return }
        view.clearSearch()
        guard !query.isEmpty else { index = 0; total = 0; return }
        _ = start == .last ? view.findPrevious(query, options: options) : view.findNext(query, options: options)
        recount()
    }

    private func recount() {
        guard let view else { return }
        let s = view.searchMatchSummary(query, options: options)
        index = s.index; total = s.total
    }

    /// New output arrived: the count follows, the current match stays where it is (no scrolling, no new search).
    func outputArrived() {
        guard isOpen, !query.isEmpty, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            refreshTask = nil
            let before = index
            recount()
            if index == 0, before > 0, total > 0 { index = min(before, total) }
        }
    }
}

struct TerminalFindBar: View {
    let find: TerminalFind
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var find = find
        HStack(spacing: 6) {
            TextField("Find", text: $find.query)
                .textFieldStyle(.plain).font(Tok.Font.body).foregroundStyle(Tok.ink)
                .focused($focused)
                .frame(width: 170)
                .onSubmit { find.step(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { find.close() }
                .onChange(of: find.query) { find.queryChanged() }
                .accessibilityLabel("Find in terminal")
            Text(find.countText).font(Tok.Font.small).foregroundStyle(Tok.ink2).frame(minWidth: 52, alignment: .trailing)
                .accessibilityLabel("Matches")
            button("chevron.up", "Previous match (⇧↩ or ⇧⌘G)") { find.step(forward: false) }
            button("chevron.down", "Next match (↩ or ⌘G)") { find.step(forward: true) }
            Toggle("Aa", isOn: $find.caseSensitive).toggleStyle(.button).controlSize(.small).font(Tok.Font.small)
                .help("Match case").onChange(of: find.caseSensitive) { find.queryChanged() }
            button("xmark", "Close (Esc)") { find.close() }
        }
        .padding(.horizontal, Tok.Space.s).padding(.vertical, 6)
        .background(Tok.rail, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .fixedSize()
        .onChange(of: find.focusRequest, initial: true) { focused = true }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18) }
            .buttonStyle(.plain).foregroundStyle(Tok.ink2).help(help).accessibilityLabel(help)
    }
}
