import SwiftUI
import AppKit

/// The chat composer's text input: an AppKit text view that grows with its text up to `maxHeight`, then scrolls inside.
/// Return is decided in the text view's own keyDown from the key itself, so it follows the "Return sends" toggle without a key
/// monitor, and Return while text is being composed (IME) stays with the input method.
/// It takes the keyboard focus when it comes on screen and whenever the focus falls back to the window (another field closed),
/// never from a field the user is typing in.
struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    var returnSends: Bool
    var maxHeight: CGFloat
    /// Each change puts the keyboard focus in the input.
    var focusRequest: Int
    /// Each change (another agent chosen) puts the focus in the input when no other field has it.
    var focusKey: String = ""
    var onSend: () -> Void
    /// A digit key 1–9 typed into the empty input (N293): true when it picked an option of the open question, so it is not typed.
    var onDigit: ((Int) -> Bool)? = nil

    /// The option digit a key press is, when the input is empty and no modifier but Shift is held; nil types the key as usual.
    static func digit(characters: String?, modifiers: NSEvent.ModifierFlags, text: String) -> Int? {
        guard text.isEmpty, modifiers.intersection([.command, .option, .control]).isEmpty,
              let c = characters, c.count == 1, let n = Int(c), (1...9).contains(n) else { return nil }
        return n
    }

    /// Tok.Font.body as an AppKit font.
    static let font = NSFont.systemFont(ofSize: 13)
    static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

    final class TextView: NSTextView {
        var returnSends = false
        var onSend: () -> Void = {}
        var onDigit: ((Int) -> Bool)?
        private var responderWatch: NSKeyValueObservation?
        private var keyWatch: NSObjectProtocol?

        /// Return and keypad Enter are decided here, not in `insertNewline:`: in the active app the input method may answer the key
        /// after keyDown has returned, when the event (and its Shift) is no longer known, so Shift-Return was read as Return and sent.
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76, isEditable, !hasMarkedText() {
                switch CommandBar.returnKey(returnSends: returnSends, modifiers: event.modifierFlags) {
                case .send: onSend(); return
                case .newline: insertNewlineIgnoringFieldEditor(nil); return
                case .pass: break
                }
            }
            if isEditable, !hasMarkedText(), let onDigit,
               let n = ChatInput.digit(characters: event.characters, modifiers: event.modifierFlags, text: string), onDigit(n) { return }
            super.keyDown(with: event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            responderWatch = nil
            if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }; keyWatch = nil
            guard let window else { return }
            responderWatch = window.observe(\.firstResponder) { [weak self] _, _ in DispatchQueue.main.async { self?.takeFreeFocus() } }
            keyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.takeFreeFocus() }
            }
            DispatchQueue.main.async { [weak self] in self?.takeFreeFocus() }
        }

        /// Takes the focus when nothing holds it: the window itself (or its root view) is the first responder.
        func takeFreeFocus() {
            guard let window, isEditable, !isHiddenOrHasHiddenAncestor, ChatInput.focusIsFree(window.firstResponder, in: window) else { return }
            window.makeFirstResponder(self)
        }
    }

    /// No text field or other control has the focus: it is on the window or on its root view (where a removed field leaves it).
    static func focusIsFree(_ responder: NSResponder?, in window: NSWindow) -> Bool {
        responder == nil || responder === window || responder === window.contentView
    }

    /// When the input grows or shrinks the caret stays in view; any other time the user's own scroll position is kept.
    final class ScrollView: NSScrollView {
        override func setFrameSize(_ size: NSSize) {
            let resized = size.height != frame.height
            super.setFrameSize(size)
            guard resized, let view = documentView as? NSTextView else { return }
            view.scrollRangeToVisible(view.selectedRange())
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        var focusRequest: Int
        var focusKey: String
        init(_ parent: ChatInput) { self.parent = parent; focusRequest = parent.focusRequest; focusKey = parent.focusKey }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = TextView()
        view.setAccessibilityIdentifier(CommandBar.inputIdentifier)
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
        // Dropped images go to the Command box's own drop target, not into the text.
        view.unregisterDraggedTypes()
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TextView else { return }
        view.returnSends = returnSends
        view.onSend = onSend
        view.onDigit = onDigit
        if view.string != text, !view.hasMarkedText() { view.string = text }
        view.isEditable = context.environment.isEnabled
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            view.window?.makeFirstResponder(view)
        }
        if context.coordinator.focusKey != focusKey {
            context.coordinator.focusKey = focusKey
            DispatchQueue.main.async { view.takeFreeFocus() }
        }
    }

    /// As tall as the text at the offered width, from one line up to `maxHeight`; past that the text scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let width = proposal.width ?? scroll.frame.width
        if width > 0, container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = max(layout.usedRect(for: container).height, Self.lineHeight)
        return CGSize(width: width, height: min(ceil(used), maxHeight))
    }
}
