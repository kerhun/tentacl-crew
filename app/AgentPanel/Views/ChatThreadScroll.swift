import SwiftUI
import AppKit

/// Where the user left a thread: at the bottom (following the newest message) or a place higher up.
/// Kept by the chat session, so a screen switch comes back to the same place.
@MainActor @Observable
final class ChatPlace {
    /// At the bottom: new messages, the held bubble and a growing input keep the newest message in view.
    private(set) var following = true
    /// Scrolled up more than a screen-height: the Jump to latest button shows.
    private(set) var far = false
    /// Messages in the thread when the user left the bottom; the button's badge counts the ones after them.
    private(set) var countAtLeave: Int?
    /// The view's top, in points below the thread's top, while not following.
    @ObservationIgnored var top: Double = 0
    /// Bumped by the button; the scroll view animates to the bottom.
    private(set) var jumpRequest = 0

    /// Closer than this to the bottom counts as at the bottom.
    static let bottomSlack: Double = 4

    /// The user's messages and the agent's turns are what the badge counts: never panel notes (or the ✓ folded into them),
    /// tool lines, summaries or dividers.
    static func messages(_ entries: [ChatEntry]) -> Int {
        ChatRows.build(entries: entries).reduce(0) { n, row in
            switch row {
            case .user, .turn: n + 1
            default: n
            }
        }
    }

    func newCount(in entries: [ChatEntry]) -> Int { countAtLeave.map { max(0, Self.messages(entries) - $0) } ?? 0 }

    func jump() {
        follow()
        jumpRequest += 1
    }

    /// Back to the newest message (a jump, or a fresh conversation).
    func follow() {
        following = true; far = false; countAtLeave = nil; top = 0
    }

    /// The user scrolled: `fromBottom` is how far the view's bottom is above the thread's end.
    func scrolled(top: Double, fromBottom: Double, visible: Double, messages: Int) {
        if fromBottom <= Self.bottomSlack { follow(); return }
        self.top = top
        if following { following = false; countAtLeave = messages }
        let isFar = fromBottom > visible
        if far != isFar { far = isFar }
    }
}

/// Sits inside the thread's scroll view and drives the AppKit scroll view under SwiftUI's ScrollView: it keeps the bottom
/// in view while following, keeps the view's top where the user left it otherwise (also when content or the view's size
/// changes), restores that place when the thread is shown again, and animates Jump to latest.
struct ThreadScrollProbe: NSViewRepresentable {
    let place: ChatPlace
    let messages: Int
    let jumpRequest: Int

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.place = place
        view.messages = messages
        // Never scroll inside SwiftUI's update: the scroll posts notifications that would change state mid-update.
        if view.jumpRequest != jumpRequest { view.jumpRequest = jumpRequest; DispatchQueue.main.async { [weak view] in view?.animateToBottom() } }
    }

    final class ProbeView: NSView {
        var place: ChatPlace?
        var messages = 0
        var jumpRequest = 0
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var workspaceObservers: [NSObjectProtocol] = []
        private var screenAsleep = false
        private var pendingTarget: NSPoint?
        /// The sizes the last settle saw; a bounds change with other sizes is layout, not the user.
        private var sizes = (content: 0.0, visible: 0.0)
        private var adjusting = false
        private var animating = false

        /// Leaving the window drops the observers and the scroll view before anything else can call back.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { detach() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil, let scroll = enclosingScrollView, let doc = scroll.documentView else { return }
            self.scroll = scroll
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            doc.postsFrameChangedNotifications = true
            scroll.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.boundsChanged() } },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.settle() } },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.settle() } },
            ]
            // Sleep, hide or minimise ends a running jump at its target: its animation would never complete.
            let end: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.endJumpNow() } }
            if let window {
                observers += [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification]
                    .map { center.addObserver(forName: $0, object: window, queue: .main, using: end) }
            }
            let ws = NSWorkspace.shared.notificationCenter
            workspaceObservers = [
                ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] n in MainActor.assumeIsolated { self?.screenAsleep = true; end(n) } },
                ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.screenAsleep = false } },
            ]
            settle()
            // SwiftUI may finish laying out the rows after the view is in the window.
            DispatchQueue.main.async { [weak self] in self?.settle() }
        }

        private func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            workspaceObservers = []
            scroll = nil
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        }

        private var metrics: (top: Double, content: Double, visible: Double)? {
            guard let scroll, let doc = scroll.documentView else { return nil }
            let clip = scroll.contentView.bounds
            let content = doc.frame.height
            return (doc.isFlipped ? clip.minY : content - clip.maxY, content, clip.height)
        }

        private func boundsChanged() {
            guard !adjusting, !animating, let m = metrics, let place else { return }
            if (m.content, m.visible) != sizes { settle(); return }
            // AppKit posts this synchronously, also while SwiftUI lays the thread out; changing observed state then can
            // crash the view graph, so the place is updated on the next turn of the main queue.
            let messages = messages
            DispatchQueue.main.async { [weak place] in
                place?.scrolled(top: m.top, fromBottom: m.content - m.visible - m.top, visible: m.visible, messages: messages)
            }
        }

        /// Puts the view where the place says: the bottom while following, else the same top.
        private func settle() {
            guard !animating, let m = metrics, let place else { return }
            sizes = (m.content, m.visible)
            let maxTop = max(0, m.content - m.visible)
            scroll(toTop: place.following ? maxTop : min(place.top, maxTop))
        }

        private func origin(top: Double) -> NSPoint {
            guard let scroll, let doc = scroll.documentView else { return .zero }
            let y = doc.isFlipped ? top : doc.frame.height - scroll.contentView.bounds.height - top
            return NSPoint(x: scroll.contentView.bounds.minX, y: y)
        }

        private func scroll(toTop top: Double) {
            guard let scroll, abs((metrics?.top ?? top) - top) > 0.5 else { return }
            adjusting = true
            scroll.contentView.scroll(to: origin(top: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            adjusting = false
        }

        func animateToBottom() {
            guard let scroll, let window, let m = metrics else { return }
            let target = origin(top: max(0, m.content - m.visible))
            // The animation runs on the display's clock: with the display asleep or the window hidden it never advances
            // and its completion never comes, so the jump would not finish. Then the jump is direct.
            guard Self.shouldAnimate(windowVisible: window.isVisible, occluded: !window.occlusionState.contains(.visible),
                                     miniaturised: window.isMiniaturized, screenAsleep: screenAsleep) else { finishJump(to: target); return }
            animating = true
            pendingTarget = target
            let token = UUID()
            jumpToken = token
            NSAnimationContext.runAnimationGroup { [weak scroll] context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                guard let scroll else { return }
                scroll.contentView.animator().setBoundsOrigin(target)
                scroll.reflectScrolledClipView(scroll.contentView)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finishJump(to: target, token: token) }
            }
            // The display can go to sleep mid-animation: the jump then ends here, not on a completion that never comes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finishJump(to: target, token: token) }
        }

        private var jumpToken: UUID?

        /// Animate only when the window can draw; otherwise the scroll is direct.
        nonisolated static func shouldAnimate(windowVisible: Bool, occluded: Bool, miniaturised: Bool, screenAsleep: Bool) -> Bool {
            windowVisible && !occluded && !miniaturised && !screenAsleep
        }

        private func endJumpNow() {
            if animating, let target = pendingTarget { finishJump(to: target, token: jumpToken) }
        }

        /// Ends a jump once: the first of the animation's completion and the fallback wins.
        private func finishJump(to target: NSPoint, token: UUID? = nil) {
            if let token { guard jumpToken == token else { return }; jumpToken = nil }
            if let scroll {
                adjusting = true
                scroll.contentView.scroll(to: target)
                scroll.reflectScrolledClipView(scroll.contentView)
                adjusting = false
            }
            animating = false
            pendingTarget = nil
            settle()
        }
    }
}
