import SwiftUI
import AppKit

/// The notes pad's text box (the add box, a line's edit box, quick capture): an AppKit text view, like the chat's `ChatInput`, so
/// Return and Shift-Return are decided in its own keyDown from the key itself. Return submits, Shift-Return starts a new line in the
/// same note; it grows with its text up to five lines, then scrolls inside. It takes the keyboard focus when it comes on screen.
struct NoteField: NSViewRepresentable {
    enum TakeFocus {
        /// Whatever has the focus (a line's edit box, quick capture).
        case always
        /// Unless a line of the pad is being edited (the add box).
        case unlessEditing
    }

    static let addIdentifier = "notes-add"
    static let editIdentifier = "notes-edit"
    static let maxLines: CGFloat = 5
    /// Tok.Font.body as an AppKit font.
    static let font = NSFont.systemFont(ofSize: 13)
    static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

    @Binding var text: String
    var identifier: String
    var takesFocus: TakeFocus
    /// Each change puts the keyboard focus in the box (an edit ended: back to the add box).
    var focusRequest = 0
    var onSubmit: () -> Void
    /// Esc; nil leaves it to the window (the pad's own Esc button).
    var onCancel: (() -> Void)?

    final class TextView: NSTextView {
        var onSubmit: () -> Void = {}
        var onCancel: (() -> Void)?
        var takesFocus = TakeFocus.always

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76, isEditable, !hasMarkedText() {
                switch CommandBar.returnKey(returnSends: true, modifiers: event.modifierFlags) {
                case .send: onSubmit(); return
                case .newline: insertNewlineIgnoringFieldEditor(nil); return
                case .pass: break
                }
            }
            if event.keyCode == 53, !hasMarkedText(), let onCancel { onCancel(); return }
            super.keyDown(with: event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.takeFocus() }
        }

        func takeFocus() {
            guard let window, isEditable, !isHiddenOrHasHiddenAncestor else { return }
            if takesFocus == .unlessEditing, let other = window.firstResponder as? NSTextView, other !== self,
               other.accessibilityIdentifier() == NoteField.editIdentifier { return }
            window.makeFirstResponder(self)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteField
        var focusRequest: Int
        init(_ parent: NoteField) { self.parent = parent; focusRequest = parent.focusRequest }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ChatInput.ScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = TextView()
        view.setAccessibilityIdentifier(identifier)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.font = Self.font
        view.textColor = NSColor(Tok.ink)
        view.insertionPointColor = NSColor(Tok.ink)
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TextView else { return }
        view.onSubmit = onSubmit
        view.onCancel = onCancel
        view.takesFocus = takesFocus
        if view.string != text, !view.hasMarkedText() { view.string = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    /// As tall as the text at the offered width, from one line up to five; past that the text scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let width = proposal.width ?? scroll.frame.width
        if width > 0, container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = max(layout.usedRect(for: container).height, Self.lineHeight)
        return CGSize(width: width, height: min(ceil(used), ceil(Self.lineHeight * Self.maxLines)))
    }
}
