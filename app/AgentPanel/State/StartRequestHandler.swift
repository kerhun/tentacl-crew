import Foundation

/// What became of a start request, for the decision feed.
struct StartRequestOutcome: Equatable {
    enum Result: Equatable {
        /// The accepted cards were started without a sheet.
        case started
        /// The accepted cards wait in the Round sheet for the user's click.
        case sheet
        /// Nothing could start (or the request itself was refused).
        case refused
    }

    let requestID: String
    let words: String
    let requested: [String]
    let result: Result
    let started: [String]
    let refused: [RoundModel.Dropped]
    let failure: String?
    /// The message sent to the PM's pane.
    let message: String
    /// Done under the PM's standing authority, with no message of the user's behind it.
    var authority = false
}

/// The messages the user sent to a project's PM pane from the Command box, kept for a while so a PM request of that project can quote
/// them (start and approve requests share it). Messages of one project never back a request of another.
@MainActor
final class CommandMemory {
    /// How long a Command box message can back a request.
    static let window: TimeInterval = 600

    struct Said: Equatable { let project: String; let pane: String; let text: String; let time: Date }
    var now: () -> Date = Date.init
    private var said: [Said] = []

    func note(_ text: String, to pane: String, project: String) {
        said.append(Said(project: project, pane: pane, text: Self.normal(text), time: now()))
        if said.count > 20 { said.removeFirst(said.count - 20) }
    }

    /// The recent, unused message of this project that backs the quoted words; the message is used up. It must name every card id, and the
    /// quoted words must be the whole message or at least `minWords` words of it.
    func take(project: String, ids: [String], words: String) -> Said? {
        backing(project: project, ids: ids, words: words).map { said.remove(at: $0) }
    }

    /// Whether `take` would find a message, without using it up.
    func hasBacking(project: String, ids: [String], words: String) -> Bool {
        backing(project: project, ids: ids, words: words) != nil
    }

    private func backing(project: String, ids: [String], words: String) -> Int? {
        let wanted = Self.normal(words)
        guard !wanted.isEmpty, !ids.isEmpty else { return nil }
        let cutoff = now().addingTimeInterval(-Self.window)
        let long = wanted.split(separator: " ").count >= Self.minWords
        return said.lastIndex(where: {
            $0.project == project && $0.time >= cutoff && ($0.text == wanted || (long && $0.text.contains(wanted))) && Self.names(ids, in: $0.text)
        })
    }

    /// Gives a message back (with its original time) when its request had to wait.
    func restore(_ message: Said) { said.append(message) }

    // MARK: session key (N91)

    /// The secret only the PM of a project received. Memory only, never written anywhere; one per PM pane, so a PM that moves to another
    /// pane (or a restarted panel) has a new key and the old one stops working.
    private struct SessionKey { var pane: String; var key: String; var givenAt: Date? }
    private var keys: [String: SessionKey] = [:]
    /// How long the panel waits before it sends the key again to a PM that wrote a request without a valid one.
    static let resendAfter: TimeInterval = 600

    /// The key of this PM pane (made on first use; a different pane replaces the old key).
    func key(project: String, pane: String) -> String {
        if let known = keys[project], known.pane == pane { return known.key }
        let fresh = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()   // 256 bits
        keys[project] = SessionKey(pane: pane, key: fresh, givenAt: nil)
        return fresh
    }

    /// A key made for a PM that is about to start (N280): it goes into that process's environment as `TENTACL_PM_KEY`. A restart makes a
    /// new one, so the old one stops working. `bindKey` ties it to the pane the PM got.
    private var pending: [String: String] = [:]

    func newKeyForSpawn(project: String) -> String {
        let fresh = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()   // 256 bits
        pending[project] = fresh
        return fresh
    }

    /// The PM started with the pending key: that pane has the key already, so the panel never types it into the chat.
    func bindKey(project: String, pane: String) {
        guard let fresh = pending.removeValue(forKey: project) else { return }
        keys[project] = SessionKey(pane: pane, key: fresh, givenAt: now())
    }

    /// The spawn failed: the pending key is dropped.
    func dropPendingKey(project: String) { pending[project] = nil }

    /// Whether this is the current key of the project's PM pane.
    func accepts(_ key: String?, project: String, pane: String?) -> Bool {
        guard let key, !key.isEmpty, let pane, let known = keys[project], known.pane == pane else { return false }
        return known.key == key
    }

    /// The key to send to the PM pane now, or nil when this session already got it. Marks it as sent.
    func keyToGive(project: String, pane: String) -> String? {
        let key = key(project: project, pane: pane)
        guard keys[project]?.givenAt == nil else { return nil }
        keys[project]?.givenAt = now()
        return key
    }

    /// A request came without a valid key: let the key go out again (the first message may have found the PM busy), at most once per `resendAfter`.
    func keyMayBeLost(project: String) {
        if let given = keys[project]?.givenAt, now().timeIntervalSince(given) >= Self.resendAfter { keys[project]?.givenAt = nil }
    }

    static let minWords = 3

    private static func names(_ ids: [String], in text: String) -> Bool {
        let tokens = Set(text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }).map(String.init))
        return ids.allSatisfy { tokens.contains($0.lowercased()) }
    }

    private static func normal(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// What the panel tells the PM about the key of its session.
func keyMessage(_ key: String) -> String {
    "Panel: new authority key: \(key) (pass as --key)"
}

/// Whether a request is carried out without a sheet: under the standing authority (the project's own key) or backed by the user's own
/// Command box message with the autopilot on. A project that is not open has no sheet, so a request that needs one waits for the project to be opened.
@MainActor
private func runsWithoutSheet(_ request: StartRequest?, project: String, memory: CommandMemory, authority: PMAuthority, mode: AutopilotMode, pane: String?) -> Bool {
    guard let request else { return true }
    if authority.enabled, keyState(of: request.key, memory: memory, project: project, pane: pane) == .valid { return true }
    return mode == .on && memory.hasBacking(project: project, ids: request.cards, words: request.userWords)
}

/// How a request's key stands against the PM session's key.
enum KeyState { case valid, missing, wrong }

@MainActor
private func keyState(of key: String?, memory: CommandMemory, project: String, pane: String?) -> KeyState {
    if memory.accepts(key, project: project, pane: pane) { return .valid }
    return (key ?? "").isEmpty ? .missing : .wrong
}

/// The standing-authority text of an unusable key, for the PM's answer; nil when the key was fine or the authority is off anyway.
func keyNote(_ state: KeyState, authorityOn: Bool) -> String? {
    guard authorityOn else { return nil }
    switch state {
    case .valid: return nil
    case .missing: return "Your request carried no key, so it was judged without the standing authority; pass `--key <key>` with the key from the Panel message (it is sent again shortly if you lost it)."
    case .wrong: return "Your request carried a wrong key (not the one of this session), so it was judged without the standing authority. The panel was restarted: from now on use `--key <key>` with the newest \"Panel: new authority key\" message; do not send it again."
    }
}

/// Sends each PM its session key, once, when the standing authority is on for its project (open or not). The send is the usual checked one
/// that waits for an idle PM; a PM that missed it asks again by writing a request without a key.
@MainActor
private func giveKeys(memory: CommandMemory, projects: [String], authority: (String) -> PMAuthority, pmPane: (String) -> String?, tell: (String, String) async -> Void) async {
    for project in projects {
        guard authority(project).enabled, let pane = pmPane(project), let key = memory.keyToGive(project: project, pane: pane) else { continue }
        await tell(pane, keyMessage(key))
    }
}

/// Reads the PM's start requests and carries them out through the Round model, so every check of the normal start flow stays.
/// A request is started without a sheet only when the autopilot is on and the user's own Command box message asked for it.
@MainActor
final class StartRequestHandler {
    /// How long a Command box message can back a request.
    static let chatWindow: TimeInterval = CommandMemory.window

    @ObservationIgnored private let projects: () -> [String]
    @ObservationIgnored private let selected: () -> String?
    @ObservationIgnored private let store: (String) -> StartRequestStore?
    @ObservationIgnored private let mode: (String) -> AutopilotMode
    /// The round model a request for a project is carried out with (nil: the panel is closing).
    @ObservationIgnored private let round: (String) -> RoundModel?
    @ObservationIgnored private let pmPane: (String) -> String?
    @ObservationIgnored private let tell: (String, String) async -> Void
    @ObservationIgnored private let record: (String, StartRequestOutcome) -> Void
    @ObservationIgnored private let log: ActionLog
    @ObservationIgnored private let authority: (String) -> PMAuthority
    @ObservationIgnored private let card: (String, String) -> TaskCard?
    @ObservationIgnored let memory: CommandMemory
    @ObservationIgnored var now: () -> Date { get { memory.now } set { memory.now = newValue } }
    private var busy = false

    init(projects: @escaping () -> [String], selected: @escaping () -> String?, store: @escaping (String) -> StartRequestStore?,
         mode: @escaping (String) -> AutopilotMode, round: @escaping (String) -> RoundModel?, pmPane: @escaping (String) -> String?,
         tell: @escaping (String, String) async -> Void, record: @escaping (String, StartRequestOutcome) -> Void, log: ActionLog,
         memory: CommandMemory? = nil, authority: @escaping (String) -> PMAuthority = { _ in PMAuthority() }, card: @escaping (String, String) -> TaskCard? = { _, _ in nil }) {
        self.authority = authority; self.card = card
        self.memory = memory ?? CommandMemory()
        self.projects = projects; self.selected = selected; self.store = store; self.mode = mode; self.round = round; self.pmPane = pmPane
        self.tell = tell; self.record = record; self.log = log
    }

    /// The user sent this to the PM pane of `project` from the Command box (call it only for messages the panel really sent there).
    func noteCommand(_ text: String, to pane: String, project: String) { memory.note(text, to: pane, project: project) }

    /// Handles every waiting request of every project, open or not, oldest first, with that project's own key, rules and cards. A request
    /// waits (stays on disk) while the Round sheet is in use, and, for a project that is not open, while it would need the user's click on
    /// that sheet.
    func process() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await giveKeys(memory: memory, projects: projects(), authority: authority, pmPane: pmPane, tell: tell)
        for project in projects() {
            guard let store = store(project) else { continue }
            for pending in store.pending() {
                if selected() != project, !runsWithoutSheet(pending.request, project: project, memory: memory, authority: authority(project), mode: mode(project), pane: pmPane(project)) { continue }
                guard let (outcome, pane) = await handle(pending, project: project) else { break }
                store.remove(pending)
                log.append("start-request \(outcome.requestID) \(outcome.result)\(outcome.authority ? " [\(PMAuthority.tag)]" : "") cards=\(outcome.requested.joined(separator: ",")) started=\(outcome.started.joined(separator: ",")) refused=\(outcome.refused.map(\.id).joined(separator: ","))"
                           + (outcome.failure.map { " failure=\($0)" } ?? ""), project: project)
                record(project, outcome)
                if let pane = pane ?? pmPane(project) { await tell(pane, outcome.message) }
            }
        }
    }

    private static func refusal(_ pending: PendingStartRequest) -> (StartRequestOutcome, pane: String?) {
        let why = pending.problem ?? "the request cannot be used"
        let message = "Panel: your start request \(pending.id) was refused: \(why)."
        return (StartRequestOutcome(requestID: pending.id, words: pending.request?.userWords ?? "", requested: pending.request?.cards ?? [], result: .refused,
                                    started: [], refused: [], failure: why, message: message), nil)
    }

    private func handle(_ pending: PendingStartRequest, project: String) async -> (StartRequestOutcome, pane: String?)? {
        guard let request = pending.request else { return Self.refusal(pending) }
        let backing = memory.take(project: project, ids: request.cards, words: request.userWords)
        let mode = mode(project)
        let authority = authority(project)
        // The standing authority is for the PM only: a request without the key of the PM session is judged as if the authority were off.
        let state = keyState(of: request.key, memory: memory, project: project, pane: pmPane(project))
        let standing = state == .valid ? authority : PMAuthority()
        let note = keyNote(state, authorityOn: authority.enabled)
        var warning: String?
        if state == .wrong {
            warning = "warning: start-request \(request.id) carried a wrong key (not the key of the PM session), so the standing authority was not used"
            log.append(warning!, project: project)
            memory.keyMayBeLost(project: project)
        } else if state == .missing, note != nil { memory.keyMayBeLost(project: project) }
        // The user's own message behind the request, with the autopilot on, is the old path; otherwise the standing authority (when on) decides.
        let byAuthority = standing.enabled && !(backing != nil && mode == .on)
        var ids = request.cards
        var held: [RoundModel.Dropped] = []
        if byAuthority {
            if let why = standing.blocker { return (Self.stopped(request, why: why, authority: true), nil) }
            let left = standing.startsPerDay - standing.startedToday
            if left <= 0 { return (Self.stopped(request, why: "the PM has already started \(standing.startedToday) cards today (the limit is \(standing.startsPerDay) a day)", authority: true), nil) }
            var seen: [String] = []
            for id in ids where !seen.contains(id) { seen.append(id) }
            ids = []
            for id in seen {
                if card(project, id)?.kind == "setup" { held.append(.init(id: id, reason: PMAuthority.setupCard)) }
                else if ids.count >= left { held.append(.init(id: id, reason: "the PM may start \(standing.startsPerDay) cards a day and \(standing.startedToday) already started")) }
                else { ids.append(id) }
            }
            if ids.isEmpty { return (Self.stopped(request, why: nil, authority: true, refused: held), nil) }
        }
        let pane = backing?.pane
        let startNow = byAuthority || (pane != nil && mode == .on)
        guard let round = round(project), var result = await round.fulfil(ids: ids, words: request.userWords, startNow: startNow, project: project) else {
            if let backing { memory.restore(backing) }   // keep the user's message (and its time) for the retry
            return nil
        }
        result.refused = held + result.refused
        let kind: StartRequestOutcome.Result = result.sheet ? .sheet : (result.started.isEmpty ? .refused : .started)
        var lines: [String] = []
        switch kind {
        case .started: lines.append("Panel: started \(result.started.joined(separator: ", "))\(byAuthority ? " under your standing authority" : "").")
        case .sheet:
            let cards = "the Round sheet is open for the user"
            lines.append(result.firstRound
                ? "Panel: this is the project's first round, which always waits for the user's click (even under your standing authority), so nothing was started; \(cards), who starts the cards with one click."
                : pane == nil
                ? "Panel: I did not see the user ask for this in the Command box (no recent message of theirs contains the words you quoted), so nothing was started; \(cards), who starts the cards with one click."
                : "Panel: the PM autopilot is \(mode == .off ? "off" : "in shadow mode"), so nothing was started; \(cards), who starts the cards with one click.")
        case .refused: lines.append("Panel: nothing was started.")
        }
        if let failure = result.failure { lines.append(failure) }
        if !result.refused.isEmpty { lines.append("Refused: " + result.refused.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ") + ".") }
        if let note { lines.append(note) }
        let failure = [warning, result.failure].compactMap { $0 }.joined(separator: " ")
        let outcome = StartRequestOutcome(requestID: request.id, words: request.userWords, requested: request.cards, result: kind, started: result.started,
                                          refused: result.refused, failure: failure.isEmpty ? nil : failure, message: lines.joined(separator: " "), authority: byAuthority)
        return (outcome, pane)
    }

    /// A request the standing authority cannot carry out: nothing starts and no sheet opens (the limits are for the PM, not for the user's click).
    private static func stopped(_ request: StartRequest, why: String?, authority: Bool, refused: [RoundModel.Dropped] = []) -> StartRequestOutcome {
        let failure = why.map { "Under your standing authority nothing was started: \($0)." }
        let tail = refused.isEmpty ? "" : " Refused: " + refused.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ") + "."
        return StartRequestOutcome(requestID: request.id, words: request.userWords, requested: request.cards, result: .refused, started: [], refused: refused, failure: failure,
                                   message: "Panel: nothing was started." + (failure.map { " " + $0 } ?? "") + tail + " The user can start the cards from the Round sheet.", authority: authority)
    }
}

/// What became of an approve request, for the decision feed.
struct ApproveRequestOutcome: Equatable {
    enum Result: Equatable {
        /// The accepted cards were prepared and approved without a sheet.
        case approved
        /// The Approve sheet opened for the first accepted card.
        case sheet
        /// Nothing was approved (or the request itself was refused).
        case refused
    }

    let requestID: String
    let words: String
    let requested: [String]
    let result: Result
    let approved: [String]
    let refused: [RoundModel.Dropped]
    let failure: String?
    let message: String
    var authority = false
}

/// Reads the PM's approve requests and carries them out through the panel's own Prepare review and Approve, so every check of the normal
/// flow stays. Without the autopilot on and the user's own Command box message behind it, the Approve sheet opens instead. A card whose
/// packet is not complete is never approved.
@MainActor
final class ApproveRequestHandler {
    @ObservationIgnored private let projects: () -> [String]
    @ObservationIgnored private let selected: () -> String?
    @ObservationIgnored private let store: (String) -> StartRequestStore?
    @ObservationIgnored private let mode: (String) -> AutopilotMode
    @ObservationIgnored private let memory: CommandMemory
    @ObservationIgnored private let card: (String, String) -> TaskCard?
    @ObservationIgnored private let phase: (String, TaskCard) -> TaskPhase?
    @ObservationIgnored private let ready: (String) -> Bool
    @ObservationIgnored private let prepare: (String, TaskCard) async -> String?
    @ObservationIgnored private let plan: (String, TaskCard) async -> Result<ApprovalPlan, ReviewError>
    @ObservationIgnored private let approve: (String, ApprovalPlan) async -> String?
    @ObservationIgnored private let openSheet: (TaskCard) -> Void
    @ObservationIgnored private let pmPane: (String) -> String?
    @ObservationIgnored private let tell: (String, String) async -> Void
    @ObservationIgnored private let record: (String, ApproveRequestOutcome) -> Void
    @ObservationIgnored private let log: ActionLog
    @ObservationIgnored private let authority: (String) -> PMAuthority
    private var busy = false

    init(projects: @escaping () -> [String], selected: @escaping () -> String?, store: @escaping (String) -> StartRequestStore?,
         mode: @escaping (String) -> AutopilotMode, memory: CommandMemory, card: @escaping (String, String) -> TaskCard?, phase: @escaping (String, TaskCard) -> TaskPhase?,
         ready: @escaping (String) -> Bool, prepare: @escaping (String, TaskCard) async -> String?, plan: @escaping (String, TaskCard) async -> Result<ApprovalPlan, ReviewError>,
         approve: @escaping (String, ApprovalPlan) async -> String?, openSheet: @escaping (TaskCard) -> Void, pmPane: @escaping (String) -> String?,
         tell: @escaping (String, String) async -> Void, record: @escaping (String, ApproveRequestOutcome) -> Void, log: ActionLog,
         authority: @escaping (String) -> PMAuthority = { _ in PMAuthority() }) {
        self.authority = authority
        self.projects = projects; self.selected = selected; self.store = store; self.mode = mode; self.memory = memory; self.card = card; self.phase = phase
        self.ready = ready; self.prepare = prepare; self.plan = plan; self.approve = approve; self.openSheet = openSheet; self.pmPane = pmPane
        self.tell = tell; self.record = record; self.log = log
    }

    /// Handles every waiting request of every project, open or not, oldest first, with that project's own key, rules and cards. A request
    /// waits (stays on disk) while the panel is busy or, for the open project, an Approve sheet is open.
    func process() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await giveKeys(memory: memory, projects: projects(), authority: authority, pmPane: pmPane, tell: tell)
        for project in projects() {
            guard let store = store(project) else { continue }
            for pending in store.pending() {
                guard ready(project) else { break }
                // A project that is not open has no Approve sheet to show: what needs the user's click waits until the project is opened.
                if selected() != project, !runsWithoutSheet(pending.request, project: project, memory: memory, authority: authority(project), mode: mode(project), pane: pmPane(project)) { continue }
                let (outcome, pane) = await handle(pending, project: project)
                store.remove(pending)
                log.append("approve-request \(outcome.requestID) \(outcome.result)\(outcome.authority ? " [\(PMAuthority.tag)]" : "") cards=\(outcome.requested.joined(separator: ",")) approved=\(outcome.approved.joined(separator: ",")) refused=\(outcome.refused.map(\.id).joined(separator: ","))"
                           + (outcome.failure.map { " failure=\($0)" } ?? ""), project: project)
                record(project, outcome)
                if let pane = pane ?? pmPane(project) { await tell(pane, outcome.message) }
            }
        }
    }

    private static func refusal(_ pending: PendingStartRequest) -> ApproveRequestOutcome {
        let why = pending.problem ?? "the request cannot be used"
        return ApproveRequestOutcome(requestID: pending.id, words: pending.request?.userWords ?? "", requested: pending.request?.cards ?? [], result: .refused, approved: [],
                                     refused: [], failure: why, message: "Panel: your approve request \(pending.id) was refused: \(why).")
    }

    private static func name(_ status: TaskStatus) -> String {
        switch status {
        case .todo: "todo"; case .awaitingStartApproval: "awaiting-start-approval"; case .doing: "doing"; case .review: "review"; case .needsFix: "needs-fix"
        case .done: "done"; case .blocked: "blocked"; case .cancelled: "cancelled"; case .unknown(let raw): raw
        }
    }

    /// Why an approve request cannot take this card, or nil. A card in review is ready; a doing or needs-fix card only once its agent finished.
    private func blocker(_ found: TaskCard, project: String) -> String? {
        switch found.status {
        case .review: return nil
        case .doing, .needsFix:
            let current = phase(project, found)
            if current == .finished { return nil }
            return "it is \(Self.name(found.status)) and its agent is not finished (\(current?.label.lowercased() ?? "state unknown")); only tasks in review, or whose agent finished, can be approved"
        default:
            return "it is \(Self.name(found.status)); only tasks in review, or doing or needing a fix with a finished agent, can be approved"
        }
    }

    private func handle(_ pending: PendingStartRequest, project: String) async -> (ApproveRequestOutcome, pane: String?) {
        guard let request = pending.request else { return (Self.refusal(pending), nil) }
        let pane = memory.take(project: project, ids: request.cards, words: request.userWords)?.pane
        let mode = mode(project)
        let authority = authority(project)
        let state = keyState(of: request.key, memory: memory, project: project, pane: pmPane(project))
        let standing = state == .valid ? authority : PMAuthority()
        let note = keyNote(state, authorityOn: authority.enabled)
        var warning: String?
        if state == .wrong {
            warning = "warning: approve-request \(request.id) carried a wrong key (not the key of the PM session), so the standing authority was not used"
            log.append(warning!, project: project)
            memory.keyMayBeLost(project: project)
        } else if state == .missing, note != nil { memory.keyMayBeLost(project: project) }
        let byAuthority = standing.enabled && !(pane != nil && mode == .on)
        if byAuthority, let why = standing.blocker {
            let failure = "Under your standing authority nothing was approved: \(why)."
            return (ApproveRequestOutcome(requestID: request.id, words: request.userWords, requested: request.cards, result: .refused, approved: [], refused: [], failure: failure,
                                          message: "Panel: nothing was approved. \(failure) The user can approve from the Approve sheet.", authority: true), pane)
        }
        let approveNow = byAuthority || (pane != nil && mode == .on)

        var refused: [RoundModel.Dropped] = []
        var accepted: [String] = []
        for id in request.cards where !accepted.contains(id) {
            guard let found = card(project, id) else { refused.append(.init(id: id, reason: "no such card")); continue }
            if let why = blocker(found, project: project) { refused.append(.init(id: id, reason: why)); continue }
            if byAuthority, found.kind == "setup" { refused.append(.init(id: id, reason: PMAuthority.setupCard)); continue }
            if byAuthority, found.status == .needsFix { refused.append(.init(id: id, reason: "its Fix notes are still open (the card needs a fix); the PM does not approve it on its own")); continue }
            accepted.append(id)
        }

        var approved: [String] = []
        var failure: String?
        var result: ApproveRequestOutcome.Result = .refused
        var lines: [String] = []
        if accepted.isEmpty {
            lines.append("Panel: nothing was approved.")
        } else if !approveNow {
            result = .sheet
            if let first = accepted.first.flatMap({ card(project, $0) }) { openSheet(first) }
            let sheet = "the Approve sheet is open for \(accepted[0]) for the user, who approves with one click"
            lines.append(pane == nil
                ? "Panel: I did not see the user ask for this in the Command box (no recent message of theirs to the PM names the cards and contains the words you quoted), so nothing was approved; \(sheet)."
                : "Panel: the PM autopilot is \(mode == .off ? "off" : "in shadow mode"), so nothing was approved; \(sheet).")
            if accepted.count > 1 { lines.append("Not opened: \(accepted.dropFirst().joined(separator: ", ")).") }
        } else {
            let changed = "the project was taken off the panel while the request ran, so nothing more was done"
            for (i, id) in accepted.enumerated() {
                func stop(_ reason: String) {
                    refused.append(.init(id: id, reason: reason))
                    let rest = accepted.dropFirst(i + 1)
                    failure = "\(id) failed: \(reason)" + (rest.isEmpty ? "" : " Not approved: \(rest.joined(separator: ", ")).")
                }
                guard projects().contains(project) else { stop(changed); break }
                guard let current = card(project, id) else { refused.append(.init(id: id, reason: "no such card")); continue }
                if let why = await prepare(project, current) { refused.append(.init(id: id, reason: "the review packet could not be prepared: \(why)")); continue }
                guard projects().contains(project) else { stop(changed); break }
                guard let prepared = card(project, id) else { refused.append(.init(id: id, reason: "no such card")); continue }
                let planned = await plan(project, prepared)
                guard projects().contains(project) else { stop(changed); break }
                switch planned {
                case .failure(let error): refused.append(.init(id: id, reason: "the packet is not ready to approve: \(error.message)"))
                case .success(let ready):
                    if let why = await approve(project, ready) {
                        refused.append(.init(id: id, reason: why))
                        let rest = accepted.dropFirst(i + 1)
                        failure = "\(id) failed to approve: \(why)" + (rest.isEmpty ? "" : " Not approved: \(rest.joined(separator: ", ")).")
                    } else { approved.append(id) }
                }
                if failure != nil { break }
            }
            result = approved.isEmpty ? .refused : .approved
            lines.append(approved.isEmpty ? "Panel: nothing was approved." : "Panel: approved \(approved.joined(separator: ", ")) (merged and closed)\(byAuthority ? " under your standing authority" : "").")
        }
        if let failure { lines.append(failure) }
        if !refused.isEmpty {
            lines.append("Refused: " + refused.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ") + ".")
            if approveNow { lines.append("Send a fix request to the agent of a card whose packet is not complete.") }
        }
        if let note { lines.append(note) }
        let shown = [warning, failure].compactMap { $0 }.joined(separator: " ")
        return (ApproveRequestOutcome(requestID: request.id, words: request.userWords, requested: request.cards, result: result, approved: approved, refused: refused,
                                      failure: shown.isEmpty ? nil : shown, message: lines.joined(separator: " "), authority: byAuthority), pane)
    }
}
