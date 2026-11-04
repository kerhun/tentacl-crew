import SwiftUI

/// The turn the user quotes (N292): shown as a box inside the input, sent as a Markdown quote before the typed text.
struct ChatQuote: Equatable {
    let speaker: String
    let text: String

    /// The first two lines of the text; one "…" when more follows, in place of a final period or ellipsis (N293: never "present.…").
    var preview: String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let shown = lines.prefix(2).joined(separator: "\n")
        guard lines.count > 2 else { return shown }
        var cut = Substring(shown)
        while let last = cut.last, last == "." || last == "…" || last == " " { cut = cut.dropLast() }
        return String(cut) + "…"
    }

    /// What Send sends: the quote as Markdown with the speaker on its first line (`> **Ibrahim:**`, N322), then the typed text.
    /// Without a quote the text alone.
    static func message(quote: ChatQuote?, typed: String) -> String {
        guard let quote else { return typed }
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = quote.speaker.trimmingCharacters(in: .whitespaces)
        let block = (speaker.isEmpty ? "" : "> **\(speaker):**\n") + ChatRowText.quote(quote.text)
        return typed.isEmpty ? block.trimmingCharacters(in: .newlines) : block + typed
    }

    /// A user message split into its quote (the leading `>` block; the speaker when its first line is `**Name:**`, else "") and the
    /// text after it (N322). A message that does not start with `>` has no quote; a `>` further down is part of the text.
    static func split(_ message: String) -> (quote: ChatQuote?, text: String) {
        let lines = message.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        let quoted = lines.prefix { $0.hasPrefix(">") }
        guard !quoted.isEmpty else { return (nil, message) }
        var body = quoted.map { line -> Substring in
            let rest = line.dropFirst()
            return rest.hasPrefix(" ") ? rest.dropFirst() : rest
        }
        var speaker = ""
        if let first = body.first?.trimmingCharacters(in: .whitespaces), first.count > 5, first.hasPrefix("**"), first.hasSuffix(":**") {
            speaker = String(first.dropFirst(2).dropLast(3)); body.removeFirst()
        }
        let text = lines.dropFirst(quoted.count).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return quote.isEmpty ? (nil, message) : (ChatQuote(speaker: speaker, text: quote), text)
    }

    /// The quote's lines as plain text (N322): no code fences or table rule lines, a table row's cells joined by " · ", no `#`,
    /// backticks or bold marks, "• " for a list item. Empty lines stay (paragraphs of the opened quote).
    var plainLines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { return nil }
            if line.hasPrefix("|") {
                if line.allSatisfy({ "|-: ".contains($0) }) { return nil }
                line = MarkdownTable.cells(line).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
            }
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The plain text as the closed quote shows it: the lines without empty ones between.
    var plainPreview: String { plainLines.filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// The quotes waiting in the inputs, one per project and agent: a new Quote replaces the old one, × and Send clear it.
struct ChatQuotes: Equatable {
    private var byKey: [String: ChatQuote] = [:]

    subscript(key: String) -> ChatQuote? { byKey[key] }
    mutating func put(_ quote: ChatQuote, for key: String) { byKey[key] = quote }
    mutating func remove(for key: String) { byKey[key] = nil }

    /// The message Send holds for `key` (the quote, then the typed text); the quote is gone afterwards.
    mutating func send(_ typed: String, for key: String) -> String {
        defer { byKey[key] = nil }
        return ChatQuote.message(quote: byKey[key], typed: typed)
    }

    /// Edit again, Edit and Undo on a message with a quote (N322): the quote goes back into the box for `key`; returns the text
    /// for the field. A message without a quote is returned as it is and the box is left alone.
    mutating func restore(_ message: String, for key: String) -> String {
        let parts = ChatQuote.split(message)
        guard let quote = parts.quote else { return message }
        byKey[key] = quote
        return parts.text
    }
}

/// A sent or held message with a quote (N322): the quote as in the input's box (a 2 pt bar, the speaker small and muted, three
/// lines of plain text, a click opens all of it), the typed text under it in the body font.
struct SentQuoteMessage<Reply: View>: View {
    let quote: ChatQuote
    @ViewBuilder let reply: () -> Reply
    @State private var open = false

    static var shownLines: Int { 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Tok.work).frame(width: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        if !quote.speaker.isEmpty { Text(quote.speaker).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                        Text(open ? quote.plainLines.joined(separator: "\n") : quote.plainPreview)
                            .font(Tok.Font.small).foregroundStyle(Tok.ink2)
                            .lineLimit(open ? nil : Self.shownLines).truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Show less of the quote" : "Show the whole quote")
            .accessibilityLabel("Quote" + (quote.speaker.isEmpty ? "" : " from \(quote.speaker)") + ": " + quote.plainPreview)
            reply()
        }
    }
}

/// The quote above the input's text: a 2 pt bar, the speaker small and muted, two lines of the text, × to remove it.
struct ChatQuoteBox: View {
    let quote: ChatQuote
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Tok.work).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.speaker).font(Tok.Font.small).foregroundStyle(Tok.ink3)
                Text(quote.preview).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(2).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tok.ink2).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove the quote").accessibilityLabel("Remove the quote")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
