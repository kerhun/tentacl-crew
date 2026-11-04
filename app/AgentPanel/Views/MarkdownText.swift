import SwiftUI

/// Markdown text as headings, paragraphs, bullets, code and tables (the blocks of `ChatText`), selectable.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            ForEach(Array(ChatText.blocks(text).enumerated()), id: \.offset) { _, block in MarkdownBlockView(block: block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// One block of `ChatText`, drawn the same in the chat and wherever `MarkdownText` is used.
struct MarkdownBlockView: View {
    let block: ChatText.Block

    var body: some View {
        switch block.kind {
        case .heading: Self.inline(block.text).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
        case .paragraph: Self.inline(block.text).font(Tok.Font.body).foregroundStyle(Tok.ink)
        case .bullet: item(block.level == 0 ? "•" : "◦")
        case .numbered: item("\(block.number ?? 1).")
        case .code: MarkdownCodeBlock(text: block.text, language: block.language)
        case .table:
            if let table = MarkdownTable.parse(block.text) {
                MarkdownTableView(table: table, source: block.text)
                    .overlay(alignment: .topTrailing) { MarkdownCopyButton(source: block.text, help: "Copy the table", label: false).padding(3) }
            } else { MarkdownCodeBlock(text: block.text, language: nil) }
        }
    }

    /// A list item: its marker, indented 18 pt per level below the first.
    private func item(_ marker: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker).foregroundStyle(block.level == 0 ? Tok.ink2 : Tok.ink3).monospacedDigit()
            Self.inline(block.text).foregroundStyle(Tok.ink)
        }
        .font(Tok.Font.body)
        .padding(.leading, CGFloat(block.level) * 18)
    }

    /// Inline Markdown with links; `code` spans in mono on a filled run.
    static func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: 12, design: .monospaced)
            text[run.range].backgroundColor = inlineCodeFill
        }
        return Text(ChatLinks.linkified(text))
    }

    static let inlineCodeFill = Tok.code
}

/// A code block (N288): a header with the fence's language and a Copy for this block only, then the code in mono 12 that never wraps;
/// wide lines scroll sideways (in a snapshot they are clipped).
struct MarkdownCodeBlock: View {
    let text: String
    let language: String?
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(language ?? "").font(Tok.Font.small).foregroundStyle(Tok.ink2)
                Spacer(minLength: 8)
                MarkdownCopyButton(source: text, help: "Copy this block", label: true)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 4)
            Group {
                if snapshot {
                    code.frame(maxWidth: .infinity, alignment: .leading).clipped()
                } else {
                    ViewThatFits(in: .horizontal) {
                        code.frame(maxWidth: .infinity, alignment: .leading)
                        ScrollView(.horizontal) { code }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.rail, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tok.line))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var code: some View {
        Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink).fixedSize()
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
    }
}

/// Copy for one block: the copy icon (and "Copy" when `label`), "Copied" for 1.5 s like the reply's Copy.
struct MarkdownCopyButton: View {
    let source: String
    let help: String
    let label: Bool
    @State private var copied = false

    var body: some View {
        Button { copy() } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                if label || copied { Text(copied ? "Copied" : "Copy").font(Tok.Font.small) }
            }
            .padding(.horizontal, label ? 8 : 5).frame(height: label ? 24 : 20)
            .background(label ? Color.clear : Tok.rail, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if !label { RoundedRectangle(cornerRadius: 6).strokeBorder(Tok.line) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Tok.ink2).help(help)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
