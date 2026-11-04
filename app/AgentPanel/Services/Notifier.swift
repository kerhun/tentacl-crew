import Foundation
import AppKit
import UserNotifications

struct AppNotification: Equatable {
    let id: String
    let title: String
    let body: String
    let cardID: String
    /// The project the event belongs to (nil in single-project use).
    var projectID: String? = nil
    var sound: NotificationSound = .crew
    /// Bounces the Dock icon once when shown (an agent asks while the app is not active).
    var bounce = false
    /// Set for an agent question: the notification carries answer buttons (see `QuestionNotice`).
    var questionID: String? = nil
    var actions: [QuestionNoticeAction] = []
}

struct QuestionNoticeAction: Equatable {
    let id: String
    let title: String
    var textInput = false
}

/// The buttons of a question notification and what pressing one means. Pure; the answer itself goes through `AgentInboxModel`,
/// the same path as the in-app buttons (which checks the agent session before sending).
enum QuestionNotice {
    enum Answer: Equatable { case option(QuestionOption), text(String), typed(String), passToPM }

    /// Menu: up to 3 options; free question: Reply; permission: Allow once / Deny (never "don't ask again"); plan and sign-in: Open only.
    /// A call of several questions or a terminal-only menu has no buttons either.
    static func actions(for q: AgentQuestion, letPM: Bool = false) -> [QuestionNoticeAction] {
        var list: [QuestionNoticeAction] = []
        if !q.terminalOnly, q.call == nil {
            switch q.kind {
            case .choice:
                list = q.options.filter { !$0.isSpecial && $0.role != .allowAlways }.prefix(3).map { QuestionNoticeAction(id: "opt:\($0.number)", title: "\($0.number) · \(ReadableQuestion.stripRecommended($0.label))") }
            case .freeText: list = [QuestionNoticeAction(id: "reply", title: "Reply", textInput: true)]
            case .permission:
                if PermissionRules.answer(for: q) != nil { list.append(QuestionNoticeAction(id: "allow", title: "Allow once")) }
                if q.options.contains(where: { $0.role == .deny }) { list.append(QuestionNoticeAction(id: "deny", title: "Deny")) }
            case .plan, .signIn: break
            }
        }
        if letPM { list.append(QuestionNoticeAction(id: "pm", title: "Let the PM decide")) }
        return list + [QuestionNoticeAction(id: "open", title: "Open")]
    }

    /// One category per set of buttons.
    static func categoryID(_ actions: [QuestionNoticeAction]) -> String { "question:" + actions.map { $0.id + "=" + $0.title }.joined(separator: "|") }

    /// What a pressed button (and the reply text) asks for; nil when the question has no such button.
    static func answer(action: String, text: String, for q: AgentQuestion) -> Answer? {
        switch action {
        case "pm": return .passToPM
        case "allow": return PermissionRules.answer(for: q).map(Answer.option)
        case "deny": return q.options.first { $0.role == .deny }.map(Answer.option)
        case "reply":
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return nil }
            return q.kind == .freeText ? .text(words) : q.typeNumber != nil ? .typed(words) : nil
        default:
            guard action.hasPrefix("opt:"), let n = Int(action.dropFirst(4)) else { return nil }
            return q.options.first { $0.number == n && !$0.isSpecial && $0.role != .allowAlways }.map(Answer.option)
        }
    }
}

/// The sound of one event: none, the default notification sound, or a macOS system sound by name (/System/Library/Sounds).
enum NotificationSound: Equatable, Hashable {
    case silent, standard, crew, named(String)

    var stored: String {
        switch self {
        case .silent: "none"
        case .standard: "default"
        case .crew: "crew"
        case .named(let name): name
        }
    }

    init(stored: String) {
        switch stored {
        case "none": self = .silent
        case "default": self = .standard
        case "crew", "": self = .crew
        default: self = .named(stored)
        }
    }

    var label: String {
        switch self {
        case .silent: "None"
        case .standard: "Default"
        case .crew: "Tentacl Crew"
        case .named(let name): name
        }
    }

    /// The bundled "bloop" (made by scripts/make-notification-sound.swift).
    static let crewFile = "TentaclCrew.caf"
    static var crewURL: URL? { Bundle.main.url(forResource: "TentaclCrew", withExtension: "caf") }

    /// The names of the system sounds, sorted.
    static func systemSounds(in dir: String = "/System/Library/Sounds") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// The sound macOS plays with the notification: only Default. macOS did not find the bundled file for this app and played its default, so Crew and system sounds are played by the app (`playsLocally`).
    var systemSound: UNNotificationSound? { self == .standard ? .default : nil }
    var playsLocally: Bool { if case .crew = self { true } else if case .named = self { true } else { false } }

    /// Plays a named sound for the ▶ preview (and for notifications whose sound macOS cannot play by itself).
    @MainActor func play() {
        switch self {
        case .silent: break
        case .standard: NSSound.beep()
        case .crew: Self.crewURL.flatMap { NSSound(contentsOf: $0, byReference: true) }?.play()
        case .named(let name): NSSound(named: NSSound.Name(name))?.play()
        }
    }
}

/// The kinds of events the user can switch on and off in Settings → Notifications.
enum NotificationEvent: String, CaseIterable {
    case agentAsks, reviewReady, roundReady, fixEscalated, costLimit, pmReply, agentStuck, updateAvailable

    var title: String {
        switch self {
        case .agentAsks: "An agent needs an answer, a permission or a plan approval"
        case .reviewReady: "A task is ready to review"
        case .roundReady: "A round is ready to start"
        case .fixEscalated: "A fix card was escalated to me"
        case .costLimit: "The PM paused: the daily cost limit was reached"
        case .pmReply: "The PM replied in the chat"
        case .agentStuck: "An agent seems stuck: it stopped before finishing its task"
        case .updateAvailable: "A new Tentacl Crew version is available"
        }
    }
}

/// Which events notify and which sound each plays. All on by default; saved in the app's defaults.
/// `sound` is the global mute switch (the old "Play a sound" setting): off silences every event whatever its picker says.
struct NotificationPrefs: Equatable {
    var events = Set(NotificationEvent.allCases)
    var sound = true
    var sounds: [NotificationEvent: NotificationSound] = [:]
    /// The number of waiting things on the Dock icon.
    var dockBadge = true
    /// One Dock bounce when an agent asks while the app is not active.
    var dockBounce = true

    private static let soundKey = "notifySound"
    private static let badgeKey = "notifyDockBadge"
    private static let bounceKey = "notifyDockBounce"
    private static func soundKey(_ event: NotificationEvent) -> String { "notifySound." + event.rawValue }

    /// What an event plays: Default until the user picks, nothing while muted.
    func sound(for event: NotificationEvent) -> NotificationSound { sound ? sounds[event] ?? .crew : .silent }
    private static func key(_ event: NotificationEvent) -> String { "notifyEvent." + event.rawValue }

    static func load(_ defaults: UserDefaults) -> NotificationPrefs {
        var prefs = NotificationPrefs()
        prefs.events = Set(NotificationEvent.allCases.filter { defaults.object(forKey: key($0)) as? Bool ?? true })
        prefs.sound = defaults.object(forKey: soundKey) as? Bool ?? true
        // An old install has only the on/off switch: no per-event key means Default.
        for event in NotificationEvent.allCases {
            if let stored = defaults.string(forKey: soundKey(event)) { prefs.sounds[event] = NotificationSound(stored: stored) }
        }
        prefs.dockBadge = defaults.object(forKey: badgeKey) as? Bool ?? true
        prefs.dockBounce = defaults.object(forKey: bounceKey) as? Bool ?? true
        return prefs
    }

    func save(_ defaults: UserDefaults) {
        for event in NotificationEvent.allCases { defaults.set(events.contains(event), forKey: Self.key(event)) }
        defaults.set(sound, forKey: Self.soundKey)
        for event in NotificationEvent.allCases { defaults.set((sounds[event] ?? .crew).stored, forKey: Self.soundKey(event)) }
        defaults.set(dockBadge, forKey: Self.badgeKey)
        defaults.set(dockBounce, forKey: Self.bounceKey)
    }
}

/// The events beyond questions and review cards, handed to the planner as plain data.
struct NotificationExtras: Equatable {
    struct Fix: Equatable { let cardID: String; let reason: String }
    struct Reply: Equatable { let id: String; let text: String }
    /// An agent that stopped before finishing; `since` (any stable text) tells one stop from the next.
    struct Stuck: Equatable { let cardID: String; let since: String }
    /// The cards of a round the PM proposed that waits for the user; empty when there is none.
    var roundCardIDs: [String] = []
    var escalatedFixes: [Fix] = []
    /// The day (any stable text) the daily cost limit paused the PM; nil while it has not.
    var costLimitDay: String? = nil
    /// The PM's latest chat reply.
    var pmReply: Reply? = nil
    var stuckAgents: [Stuck] = []
}

/// Decides what to notify about. Pure: it only remembers which events it already saw.
/// The first look and every look while notifications are off or the window is focused only record what is there, so an event is
/// never notified late (after the user turned the setting on, or after they left the window) and never twice.
/// Events of a switched-off kind are recorded too, so turning the kind on does not replay them.
struct NotificationPlanner {
    private var seen: Set<String> = []
    private var primed = false
    private var firstSeen: [String: Date] = [:]
    /// PM questions already notified (at once, or after waiting `askDelay` in a focused window).
    private var notifiedAsks: Set<String> = []
    /// A PM question open this long while the user is in the window but not on the Dashboard is notified anyway.
    static let askDelay: TimeInterval = 30

    mutating func plan(questions: [PendingQuestion], reviewCards: [TaskCard], extras: NotificationExtras = NotificationExtras(), prefs: NotificationPrefs = NotificationPrefs(),
                       enabled: Bool, focused: Bool, onDashboard: Bool = true, now: Date = Date(), project: (id: String, name: String)? = nil) -> [AppNotification] {
        let prefix = project.map { $0.name + " · " } ?? ""
        let pid = project?.id
        var events: [(key: String, kind: NotificationEvent, note: AppNotification)] = []
        func add(_ key: String, _ kind: NotificationEvent, title: String, body: String, card: String, question: PendingQuestion? = nil) {
            events.append((key, kind, AppNotification(id: key, title: NotificationText.plain(prefix + title), body: NotificationText.plain(body), cardID: card, projectID: pid, sound: prefs.sound(for: kind),
                                                                                    bounce: kind == .agentAsks && prefs.dockBounce, questionID: question?.id, actions: question.map { QuestionNotice.actions(for: $0.question) } ?? [])))
        }
        for q in questions {
            let what: String
            switch q.question.kind {
            case .permission: what = "needs a permission"
            case .plan: what = "needs a plan approval"
            case .choice, .freeText: what = "needs an answer"
            case .signIn: what = "needs sign-in"
            }
            add(q.id, .agentAsks, title: "\(q.agentLabel) \(what)", body: q.question.text, card: q.cardID, question: q)
        }
        for c in reviewCards { add("review|" + c.id, .reviewReady, title: "\(c.id) is ready to review", body: c.title, card: c.id) }
        if !extras.roundCardIDs.isEmpty {
            let ids = extras.roundCardIDs.joined(separator: ", ")
            add("round|" + extras.roundCardIDs.joined(separator: ","), .roundReady, title: "A round is ready to start", body: ids, card: extras.roundCardIDs[0])
        }
        for fix in extras.escalatedFixes { add("fix|" + fix.cardID, .fixEscalated, title: "\(fix.cardID) fix was escalated to you", body: fix.reason, card: fix.cardID) }
        if let day = extras.costLimitDay { add("limit|" + day, .costLimit, title: "The PM paused: daily cost limit reached", body: "The PM has stopped deciding until tomorrow or a higher limit.", card: "") }
        if let reply = extras.pmReply, !NotificationText.isOnlyCheckMark(reply.text) { add("pm-reply|" + reply.id, .pmReply, title: "The PM replied", body: reply.text, card: "") }
        for stuck in extras.stuckAgents {
            add("stuck|\(stuck.cardID)|\(stuck.since)", .agentStuck, title: "\(stuck.cardID) seems stuck", body: "Its agent stopped before finishing the task. Open the card to nudge it.", card: stuck.cardID)
        }
        let fresh = events.filter { !seen.contains($0.key) && prefs.events.contains($0.kind) }
        seen = Set(events.map(\.key))
        defer { primed = true }
        let pmAsks = questions.filter(\.isPM).map(\.id)
        firstSeen = firstSeen.filter { pmAsks.contains($0.key) }
        notifiedAsks.formIntersection(pmAsks)
        for id in pmAsks where firstSeen[id] == nil { firstSeen[id] = now }
        guard primed && enabled else { return [] }
        if !focused {
            notifiedAsks.formUnion(fresh.map(\.key).filter(pmAsks.contains))
            return fresh.map(\.note)
        }
        guard !onDashboard && prefs.events.contains(.agentAsks) else { return [] }
        let late = events.filter { e in
            e.kind == .agentAsks && pmAsks.contains(e.key) && !notifiedAsks.contains(e.key) && now.timeIntervalSince(firstSeen[e.key] ?? now) >= Self.askDelay
        }
        notifiedAsks.formUnion(late.map(\.key))
        return late.map(\.note)
    }
}

protocol NotificationSending: Sendable {
    func requestAuthorization() async -> Bool
    func send(_ notification: AppNotification) async
    /// Removes delivered and pending notifications (a question was answered).
    func remove(ids: [String]) async
}

extension NotificationSending {
    func remove(ids: [String]) async {}
}

enum Notifier {
    /// Asks macOS for permission when the user turns the setting on; true when notifications may be shown.
    static func enable(_ sender: NotificationSending) async -> Bool { await sender.requestAuthorization() }
}

/// Shows notifications through UserNotifications; a click brings the window forward and reports the card.
final class SystemNotificationSender: NSObject, NotificationSending, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onClick: @MainActor (_ projectID: String?, _ cardID: String) -> Void = { _, _ in }
    /// A button of a question notification: the project, the question id, the button id and the typed reply.
    var onAction: @MainActor (_ projectID: String?, _ questionID: String, _ action: String, _ text: String) -> Void = { _, _, _, _ in }
    // shortcut: categories are kept for the whole run (one per set of buttons), not pruned; upgrade if a run sees thousands of distinct menus.
    private var categories: [String: UNNotificationCategory] = [:]
    // shortcut: no .timeSensitive level: it needs the Time Sensitive capability in the provisioning profile; notifications stay .active.
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async -> Bool {
        center.delegate = self
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func send(_ notification: AppNotification) async {
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = notification.sound.systemSound
        if notification.sound.playsLocally { let sound = notification.sound; await MainActor.run { sound.play() } }
        content.userInfo = ["cardID": notification.cardID, "projectID": notification.projectID ?? "", "questionID": notification.questionID ?? ""]
        if !notification.actions.isEmpty {
            let id = QuestionNotice.categoryID(notification.actions)
            if categories[id] == nil {
                categories[id] = UNNotificationCategory(identifier: id, actions: notification.actions.map(Self.unAction), intentIdentifiers: [])
                center.setNotificationCategories(Set(categories.values))
            }
            content.categoryIdentifier = id
        }
        try? await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    func remove(ids: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static func unAction(_ a: QuestionNoticeAction) -> UNNotificationAction {
        if a.textInput { return UNTextInputNotificationAction(identifier: a.id, title: a.title, options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer") }
        return UNNotificationAction(identifier: a.id, title: a.title, options: a.id == "open" ? [.foreground] : a.id == "deny" ? [.destructive] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let card = (info["cardID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let project = (info["projectID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let action = response.actionIdentifier
        if let question = (info["questionID"] as? String).flatMap({ $0.isEmpty ? nil : $0 }), action != UNNotificationDefaultActionIdentifier, action != "open" {
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            await MainActor.run { onAction(project, question, action, text) }
            return
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let card { onClick(project, card) }
        }
    }
}
