import SwiftUI

/// The Terminals screen's Preview (N229, N234): which terminal serves which local page and when Preview may be open. It opens only for
/// the focused pane's terminal and only when that terminal serves a local page, so its "No local page found" state never shows here.
enum TerminalPreview {
    /// ⌘P and the toolbar's Preview button: closes an open Preview; opens it only when the focused terminal serves a page.
    static func toggled(open: Bool, page: LocalPage?) -> Bool { open ? false : page != nil }
    /// Preview stays open while the focused terminal serves a page.
    static func stays(open: Bool, page: LocalPage?) -> Bool { open && page != nil }

    /// The dimmed Preview button's tooltip; nil when Preview can open.
    static func disabledReason(label: String?, page: LocalPage?) -> String? {
        page != nil ? nil : label.map { "Preview needs a local page. \($0)\u{2019}s terminal serves none." } ?? "Preview needs a local page."
    }
    /// The toolbar's grey hint while Preview cannot open.
    static func hint(label: String) -> String { "Preview: \(label) serves no local page" }
    /// The yellow note when focus moved to a terminal without a page.
    static func closedNote(label: String) -> String { "\(label) has no local page · Preview closed" }

    /// `:5173` for the tab's port label and the LOCAL PAGES row; a page with no port shows its host.
    static func port(_ url: URL) -> String { PreviewLink.isArtifact(url) ? "artifact" : url.port.map { ":\($0)" } ?? (url.host ?? url.absoluteString) }
    /// `localhost:5173` for the card header's Preview button.
    static func host(_ url: URL) -> String { (url.host ?? "localhost") + (url.port.map { ":\($0)" } ?? "") }

    /// One LOCAL PAGES row (the sidebar): a page found in a terminal of the project, in the sidebar's order.
    struct Row: Equatable, Identifiable {
        let paneID: String
        let label: String
        let page: LocalPage
        var id: String { paneID }
    }

    static func rows(tabs: [TerminalTab], pages: [String: LocalPage]) -> [Row] {
        tabs.compactMap { tab in pages[tab.paneID].map { Row(paneID: tab.paneID, label: tab.label, page: $0) } }
    }
}

/// What Close in the preview goes back to (the N229 bug: it showed "No local page found" although a page was found): the terminal
/// when its page was found, the empty state with the address field only when nothing was.
enum PreviewClose: Equatable {
    case terminal, empty
    static func after(found: LocalPage?) -> PreviewClose { found == nil ? .empty : .terminal }
}

/// The local page each terminal of the project shows (`LocalPageFinder` on its last lines). The last page found stays while the
/// terminal is open (it scrolls off the screen long before the server stops) and something listens on its port (N242); a terminal
/// that closes, or a server that stops, drops its page.
@MainActor @Observable
final class TerminalPageWatch {
    private(set) var pages: [String: LocalPage] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Whether something listens on the page's port; replaced in tests.
    @ObservationIgnored private let isOpen: @Sendable (URL) async -> Bool

    init(isOpen: @escaping @Sendable (URL) async -> Bool = { await LoopbackPort.isOpen($0) }) { self.isOpen = isOpen }

    /// Like `update`, but a page counts only while its port is open.
    func consider(pane: String, text: String) async {
        guard let page = PreviewLink.page(in: text), pages[pane] != page else { return }
        // An artifact link is not on this machine: there is no port to check.
        if !PreviewLink.isArtifact(page.url), !(await isOpen(page.url)) { return }
        pages[pane] = page
    }

    /// Drops every page whose port is closed now.
    func recheck() async {
        for (pane, page) in pages where !PreviewLink.isArtifact(page.url) {
            if !(await isOpen(page.url)), pages[pane] == page { pages[pane] = nil }
        }
    }

    func update(pane: String, text: String) {
        if let page = PreviewLink.page(in: text), pages[pane] != page { pages[pane] = page }
    }

    func keep(_ panes: Set<String>) {
        let gone = pages.keys.filter { !panes.contains($0) }
        for pane in gone { pages[pane] = nil }
    }

    /// Reads every terminal `panes` returns, one after another, every `interval`.
    func start(reader: TerminalReading, interval: Duration = .seconds(3), panes: @escaping @MainActor () -> [String]) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let list = panes()
                self?.keep(Set(list))
                await self?.recheck()
                for pane in list {
                    guard let text = try? await reader.screen(of: pane, lines: 120), !Task.isCancelled else { continue }
                    await self?.consider(pane: pane, text: text)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}

/// One line of a card's `## Fix notes`: a preview note (`- <url> <selector>: <note>`), a console error (`- <url> console: <error>`)
/// or any other line the PM or the user wrote.
struct FixNoteItem: Equatable, Identifiable {
    enum Kind: Equatable { case element, console, text }
    let kind: Kind
    /// The selector, `console`, or nil for a plain line.
    let place: String?
    let text: String
    let id: Int
}

enum FixNotes {
    private static let preview = try! NSRegularExpression(pattern: #"^-\s+(?:https?|file)://\S+\s+(.+?):\s+(.+)$"#)

    /// The section's items: one per `- ` line (a line without a dash is part of the item above it).
    static func items(in section: String) -> [FixNoteItem] {
        var raw: [String] = []
        for line in section.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("<!--") { continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || raw.isEmpty { raw.append(t) } else { raw[raw.count - 1] += " " + t }
        }
        return raw.enumerated().map { i, line in
            let ns = NSRange(line.startIndex..., in: line)
            if let m = preview.firstMatch(in: line, range: ns), let p = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line) {
                let place = String(line[p])
                return FixNoteItem(kind: place == PreviewNote.consolePlace ? .console : .element, place: place, text: String(line[n]), id: i)
            }
            let plain = line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line
            return FixNoteItem(kind: .text, place: nil, text: plain, id: i)
        }
    }

    /// The card's items, read fresh from disk (an append just wrote there; the panel's own copy of the card updates later).
    static func items(cardAt url: URL) -> [FixNoteItem] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let card = try? CardParser.parse(text.replacingOccurrences(of: "\r\n", with: "\n"), url: url) else { return [] }
        return items(in: card.sections[CardSection.fixNotes.rawValue] ?? "")
    }
}

extension PreviewNote {
    static let consolePlace = "console"

    /// "Add errors to fix notes": one line per distinct console error, in the order they came; nil when there is none.
    static func consoleLines(url: URL, console: [PreviewConsoleLine]) -> String? {
        var seen = Set<String>()
        let errors = console.filter { $0.level == .error }.map { $0.text.components(separatedBy: .newlines).first ?? $0.text }
            .filter { seen.insert($0).inserted }
        return errors.isEmpty ? nil : errors.map { "- \(url.absoluteString) \(consolePlace): \($0)" }.joined(separator: "\n")
    }
}

/// A card's `## Fix notes`, where Pick element and the console errors go (in a Terminals pane header's "i" popover).
struct FixNotesColumn: View {
    let cardID: String?
    let items: [FixNoteItem]
    var onOpenCard: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m + 2) {
            VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
                Text(items.isEmpty ? "FIX NOTES" : "FIX NOTES · \(items.count)").font(Tok.Font.small.weight(.semibold)).tracking(0.9).foregroundStyle(Tok.ink2)
                if cardID == nil {
                    Text("This terminal is on no task card, so its notes have nowhere to go.").font(Tok.Font.small).foregroundStyle(Tok.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if items.isEmpty {
                    Text("No fix notes yet. Pick an element in the page and add a note, or add the console errors.").font(Tok.Font.small).foregroundStyle(Tok.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(items.suffix(8)) { item in row(item) }
                    if items.count > 8 { Text("\(items.count - 8) earlier on the card").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                }
                if let onOpenCard { Button("Open card", action: onOpenCard).buttonStyle(PanelButtonStyle()).padding(.top, Tok.Space.xs) }
            }
            .padding(Tok.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            if cardID != nil {
                Text("Pick element and the console's Add errors write to the card's Fix notes. The agent reads them on its next fix round.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Fix notes")
    }

    private func row(_ item: FixNoteItem) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.xs) {
            if let place = item.place {
                Text(place).font(Tok.Font.mono).foregroundStyle(item.kind == .console ? Tok.stop : Tok.you).lineLimit(1).truncationMode(.middle)
            }
            Text(item.text).font(.system(size: 12)).foregroundStyle(Tok.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tok.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
    }
}
