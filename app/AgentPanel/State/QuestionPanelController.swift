import AppKit
import SwiftUI

/// When the floating question panel shows, which question it shows and when it comes to the front again (N373). Pure: the caller hands in
/// the open questions, the setting, whether Tentacl is the active app and the clock. Nothing here answers a question.
struct QuestionPanelRules {
    struct Decision: Equatable {
        /// The oldest open question; nil hides the panel.
        var shown: PendingQuestion?
        /// How many more questions wait behind it ("+N more").
        var more = 0
        /// A question reached the 5-min reminder: the panel comes to the front again.
        var raise = false
        var visible: Bool { shown != nil }
    }

    /// The setting (Settings → Notifications), off by default.
    static let settingKey = "questionPanelOnTop"
    /// The same mark as the first reminder (`QuestionReminders`).
    static let raiseAfter: TimeInterval = 300

    private(set) var firstSeen: [String: Date] = [:]
    /// The questions open when the user pressed ×; nil while not closed. A question not in it opens the panel again.
    private var closedWith: Set<String>?
    private var raised: Set<String> = []

    /// × : hidden until a question that is not open now comes.
    mutating func close(open questions: [PendingQuestion]) { closedWith = Set(questions.map(\.id)) }

    /// `askedAt`: when the inbox first saw each question (the panel's own first sight otherwise).
    mutating func step(questions: [PendingQuestion], askedAt: [String: Date] = [:], enabled: Bool, appActive: Bool, now: Date) -> Decision {
        let open = Set(questions.map(\.id))
        firstSeen = firstSeen.filter { open.contains($0.key) }
        for q in questions where firstSeen[q.id] == nil { firstSeen[q.id] = askedAt[q.id] ?? now }
        raised.formIntersection(open)
        if let closed = closedWith { closedWith = open.isSubset(of: closed) ? closed.intersection(open) : nil }
        // Every question that passed the 5-min mark is marked even while hidden, so showing later does not count as a reminder.
        var reached = false
        for q in questions where !raised.contains(q.id) && now.timeIntervalSince(firstSeen[q.id] ?? now) >= Self.raiseAfter {
            raised.insert(q.id); reached = true
        }
        let ordered = questions.enumerated().sorted { a, b in
            let (da, db) = (firstSeen[a.element.id] ?? now, firstSeen[b.element.id] ?? now)
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
        guard enabled, !appActive, closedWith == nil, let oldest = ordered.first else { return Decision() }
        return Decision(shown: oldest, more: ordered.count - 1, raise: reached)
    }
}

/// One open question with what answering it needs: its project's inbox (the same path as in-app), the PM's suggestion, the PM pane.
struct QuestionPanelItem {
    let question: PendingQuestion
    let projectID: String
    let projectName: String
    let inbox: AgentInboxModel
    var askedAt: Date?
    var suggestion: PMSuggestion?
    var escalation: String?
    var pmPane: String?
}

/// What the panel's view shows; the controller updates it.
@MainActor @Observable
final class QuestionPanelContent {
    var item: QuestionPanelItem?
    var more = 0
    var total: Int { item == nil ? 0 : more + 1 }
    var now = Date()
    var onClose: () -> Void = {}
    var onPassOn: (QuestionPanelItem) -> Void = { _ in }
    var onOpenApp: (QuestionPanelItem) -> Void = { _ in }
}

/// The floating, non-activating question panel on every Space, top-right of the screen (N373). Shown only while the setting is on,
/// a question waits for the user and Tentacl is not the active app.
@MainActor
final class QuestionPanelController {
    private let source: @MainActor () -> [QuestionPanelItem]
    private let defaults: UserDefaults
    private var rules = QuestionPanelRules()
    private let content = QuestionPanelContent()
    private var panel: NSPanel?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastOpen: [PendingQuestion] = []

    init(defaults: UserDefaults = .standard, source: @escaping @MainActor () -> [QuestionPanelItem]) {
        self.defaults = defaults; self.source = source
    }

    /// The questions of every project that wait for the user (the PM's undecided ones stay out), each with its project's inbox.
    static func items(of model: PanelModel) -> [QuestionPanelItem] {
        model.projects.flatMap { project -> [QuestionPanelItem] in
            guard let watch = model.watches[project.id] else { return [] }
            let pm = model.pmPane(forProject: project.id)
            return watch.autopilot.forUser(watch.inbox.questions).map {
                QuestionPanelItem(question: $0, projectID: project.id, projectName: project.name, inbox: watch.inbox, askedAt: watch.inbox.askedAt[$0.id],
                                  suggestion: watch.autopilot.suggestion(for: $0), escalation: watch.autopilot.escalation(for: $0), pmPane: pm)
            }
        }
    }

    func start(model: PanelModel) {
        content.onClose = { [weak self] in self?.closeByUser() }
        content.onPassOn = { item in
            guard let pane = item.pmPane else { return }
            Task { await model.tellPM(pane: pane, passOnToPMText(item.question)) }
        }
        content.onOpenApp = { item in
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.open(projectID: item.projectID, cardID: item.question.cardID) }
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } })
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func closeByUser() {
        rules.close(open: lastOpen)
        tick()
    }

    func tick() {
        let items = source()
        lastOpen = items.map(\.question)
        let asked = Dictionary(items.compactMap { item in item.askedAt.map { (item.question.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let decision = rules.step(questions: lastOpen, askedAt: asked, enabled: defaults.bool(forKey: QuestionPanelRules.settingKey),
                                  appActive: NSApp.isActive, now: Date())
        guard let shown = decision.shown, var item = items.first(where: { $0.question.id == shown.id }) else {
            content.item = nil
            panel?.orderOut(nil)
            return
        }
        item.askedAt = rules.firstSeen[shown.id] ?? item.askedAt
        let isNew = content.item?.question.id != shown.id
        let old = content.item
        if isNew || old?.suggestion != item.suggestion || old?.escalation != item.escalation || old?.pmPane != item.pmPane { content.item = item }
        if content.more != decision.more { content.more = decision.more }
        if Int(Date().timeIntervalSince(content.now)) >= 30 || isNew { content.now = Date() }
        let panel = panel ?? makePanel()
        if !panel.isVisible { anchor = Self.defaultAnchor(); keepAnchor() }
        if !panel.isVisible || decision.raise || isNew { panel.orderFrontRegardless() }
    }

    /// The panel's top-right corner: top-right of the screen until the user drags it.
    private var anchor = NSPoint.zero
    private var placing = false

    private static func defaultAnchor() -> NSPoint {
        guard let screen = NSScreen.main?.visibleFrame else { return NSPoint(x: 800, y: 600) }
        return NSPoint(x: screen.maxX - 16, y: screen.maxY - 12)
    }

    private func keepAnchor() {
        guard let panel else { return }
        placing = true
        panel.setFrameTopLeftPoint(NSPoint(x: anchor.x - panel.frame.width, y: anchor.y))
        placing = false
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingQuestionPanel(contentRect: NSRect(x: 0, y: 0, width: QuestionPanel.width, height: 200),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.title = "Questions"
        panel.setAccessibilityLabel("Tentacl question panel")
        // The window takes the SwiftUI content's size; a resize keeps the top-right corner, a drag moves it.
        let host = NSHostingController(rootView: QuestionPanel(content: content))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAnchor() }
        })
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.placing, let p = self.panel { self.anchor = NSPoint(x: p.frame.maxX, y: p.frame.maxY) } }
        })
        self.panel = panel
        return panel
    }
}

/// A borderless panel that can take typing (the reply box) without making Tentacl the active app.
private final class FloatingQuestionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
