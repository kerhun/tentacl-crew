import AppKit
import Foundation
import Observation

struct PendingQuestion: Identifiable, Equatable {
    let paneID: String
    let sessionID: String?
    let agentLabel: String
    let cardID: String
    let question: AgentQuestion
    /// The project of the card (for the action log); nil when unknown.
    var project: String? = nil
    /// A question of the project's PM session: it belongs to no card and always waits for the user.
    var isPM = false
    var id: String { paneID + "|" + question.signature }
    /// What the action log calls the asker: the card, or "PM".
    var owner: String { isPM ? "PM" : cardID }
}

/// An answer the user sent from the panel: the question, what went to the agent (an option's label, the typed words, "feedback: …"), when.
struct SentAnswer: Equatable {
    let question: PendingQuestion
    let sent: String
    let at: Date
}

/// A question the PM has (N380), or one of those just answered: the user's lists show it as a muted row, so an agent never waits unseen.
struct HeldQuestion: Identifiable, Equatable {
    let question: PendingQuestion
    /// Since when the PM has it; nil once answered.
    let since: Date?
    /// What went to the agent, for the ~1.5 s the answered row stays.
    var answer: String? = nil
    var byPM = false
    var token = 0
    var id: String { question.id }
    var isAnswered: Bool { answer != nil }

    /// "PM is answering · comes to you in 7 min", "PM answered: Option A", "Answered: Option A".
    func status(now: Date) -> String {
        if let answer { return (byPM ? "PM answered: " : "Answered: ") + answer }
        return "PM is answering · comes to you in \(QuestionRelay.minutesLeft(since: since ?? now, now: now)) min"
    }

    /// The pill's muted part: "1 with PM".
    static func pillText(_ count: Int) -> String? { count > 0 ? "\(count) with PM" : nil }
}

struct QuestionAnswerError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The question window (N183): which open question it shows, in the order of Waiting for you, and a short note when the question
/// it showed went away (answered in the terminal, or the agent moved on) while it was open.
struct QuestionFocus: Equatable {
    private(set) var currentID: String
    /// Where the current question stood: when it leaves the list, the one that takes its place opens (the next unanswered one).
    private(set) var index: Int
    private(set) var note: String?
    /// Who asked the current question, for the note when it goes away.
    private var asker: String
    /// Questions answered from the panel: they leave the list without a note.
    private var answeredHere: Set<String> = []

    init?(opening question: PendingQuestion, in questions: [PendingQuestion]) {
        guard let i = questions.firstIndex(where: { $0.id == question.id }) else { return nil }
        currentID = question.id; index = i; asker = question.agentLabel
    }

    func current(in questions: [PendingQuestion]) -> PendingQuestion? { questions.first { $0.id == currentID } }

    /// "2 of 3"; nil when the current question is not in the list.
    func position(in questions: [PendingQuestion]) -> String? {
        questions.firstIndex { $0.id == currentID }.map { "\($0 + 1) of \(questions.count)" }
    }

    /// ‹ and ›: wraps around at both ends.
    mutating func move(by step: Int, in questions: [PendingQuestion]) {
        guard !questions.isEmpty else { return }
        let from = questions.firstIndex { $0.id == currentID } ?? index
        show(questions, at: ((from + step) % questions.count + questions.count) % questions.count)
        note = nil
    }

    mutating func markAnswered(_ id: String) { answeredHere.insert(id) }

    /// Follows the list: false when no question is left (the window closes).
    mutating func sync(_ questions: [PendingQuestion]) -> Bool {
        if let i = questions.firstIndex(where: { $0.id == currentID }) { index = i; return true }
        guard !questions.isEmpty else { return false }
        note = answeredHere.contains(currentID) ? nil : "\(asker)'s question was answered in its terminal or is no longer asked."
        show(questions, at: min(index, questions.count - 1))
        return true
    }

    private mutating func show(_ questions: [PendingQuestion], at i: Int) {
        index = i; currentID = questions[i].id; asker = questions[i].agentLabel
    }
}

/// The agents that wait for an answer from the user: it reads the screen of agents that belong to a running task and are blocked or
/// finished their turn, and sends the answer back (a key for a menu option, a prompt for a typed answer).
@Observable @MainActor
final class AgentInboxModel {
    private(set) var questions: [PendingQuestion] = []
    /// Questions the PM has (N279): not in `questions` until they come back to the user.
    private(set) var withPM: [PendingQuestion] = []
    let relay = QuestionRelay()
    /// Questions of the relay just answered (by the PM, or by the user after "Answer myself"): shown as answered for `answeredShownFor`.
    private(set) var justAnswered: [HeldQuestion] = []
    @ObservationIgnored var answeredShownFor: Duration = .milliseconds(1500)
    @ObservationIgnored private var answeredToken = 0
    /// Called after the PM's answer reached the agent (the card's timeline and the decision log record it).
    @ObservationIgnored var onAnsweredByPM: ((PendingQuestion, String) -> Void)?
    /// Who gets a question; the panel sets it before every read.
    @ObservationIgnored var routing = QuestionRouting()
    /// True while the PM's answer is being sent: the autopilot does not count it as the user's.
    @ObservationIgnored private var answeringForPM = false
    /// Dismissed questions that are still on screen: the card keeps a quiet "agent waiting" marker, so a stuck agent is not forgotten.
    private(set) var quiet: [PendingQuestion] = []
    private(set) var error: String?
    private(set) var sending = false

    /// How much of the terminal is read: a plan or a diff above a menu can be taller than a screenful.
    nonisolated static let screenLines = 200

    @ObservationIgnored private let reader: TerminalReading
    @ObservationIgnored private let keys: TerminalKeySending
    @ObservationIgnored private let commander: TerminalCommanding
    @ObservationIgnored private let adapter: TerminalListing
    @ObservationIgnored private let log: ActionLog
    /// What was read for a pane the last time its state was seen: reading again is only needed when the state changed.
    @ObservationIgnored private var seen: [String: (state: AgentState, seq: Int?, session: String?, question: AgentQuestion?)] = [:]
    /// Bumped when an answer is sent to a pane, so a read that started earlier cannot bring the answered question back.
    @ObservationIgnored private var epoch: [String: Int] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var readFailureShown = false
    @ObservationIgnored private var dismissed: Set<String> = []
    /// Questions already written to the action log as "asked", so a repeated read does not log them again.
    @ObservationIgnored private var logged: Set<String> = []
    /// When each question on screen was first seen (the top bar's Inbox shows its age).
    @ObservationIgnored private(set) var askedAt: [String: Date] = [:]
    /// Called after an answer reached the agent, with what was sent (an option's label, the typed text, "skipped").
    @ObservationIgnored var onAnswered: ((PendingQuestion, String) -> Void)?
    /// The user's last answer from the panel: the chat's question card shows it as one line for a few seconds (N289).
    private(set) var lastAnswer: SentAnswer?
    /// Where Claude Code's session files are: a call of several questions is read from the agent's session (N188).
    @ObservationIgnored var claudeProjectsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    /// What the user has picked so far in each call's window; nothing goes to the agent before Send.
    private(set) var callDrafts: [String: CallDraft] = [:]

    init(reader: TerminalReading, keys: TerminalKeySending, commander: TerminalCommanding, adapter: TerminalListing, log: ActionLog) {
        self.reader = reader; self.keys = keys; self.commander = commander; self.adapter = adapter; self.log = log
    }

    /// What the user's lists show for the questions the PM has (N380): the held ones, then the ones just answered.
    var heldRows: [HeldQuestion] {
        let held = withPM.map { HeldQuestion(question: $0, since: relay.heldSince($0.id) ?? Date()) }
        return held + justAnswered.filter { a in !held.contains { $0.id == a.id } }
    }

    /// The panes whose agent waits on the PM's answer: their status line says "Question with PM".
    var panesWithPM: Set<String> { Set(withPM.map(\.paneID)) }

    /// "Answer myself": the PM no longer has the question; it is the user's at once, with its options. A later answer of the PM is refused.
    func answerMyself(_ id: String) {
        guard let entry = relay.entries[id], relay.isHeld(id) else { return }
        relay.release(entry)
        settleRelay()
        log.append("answer-myself \(entry.qid) (\(entry.question.cardID))", project: entry.question.project)
    }

    /// A QUESTION line that could not be written into the PM's pane: the question is the user's again at once.
    func questionUndelivered(_ qid: String) {
        guard let entry = relay.undelivered(qid) else { return }
        settleRelay()
        log.append("relay \(qid) not delivered to the PM; back to the user", project: entry.question.project)
    }

    /// Moves the questions the relay no longer holds from `withPM` to `questions`, in the order they were read.
    private func settleRelay() {
        let back = withPM.filter { !relay.isHeld($0.id) }
        guard !back.isEmpty else { return }
        withPM.removeAll { !relay.isHeld($0.id) }
        questions += back.filter { b in !questions.contains { $0.id == b.id } }
    }

    /// Shows the question as answered for a moment, then lets it go.
    private func showAnswered(_ q: PendingQuestion, answer: String, byPM: Bool) {
        answeredToken += 1
        let token = answeredToken
        justAnswered.removeAll { $0.id == q.id }
        justAnswered.append(HeldQuestion(question: q, since: nil, answer: answer, byPM: byPM, token: token))
        let wait = answeredShownFor
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.justAnswered.removeAll { $0.token == token }
        }
    }

    func waitingCount(forCard id: String) -> Int { questions.filter { !$0.isPM && $0.cardID == id }.count }
    func quietWaitingCount(forCard id: String) -> Int { quiet.filter { !$0.isPM && $0.cardID == id }.count }

    /// Looks at the agents of running tasks. A screen is read only for agents that are blocked or finished a turn and whose state
    /// changed since it was last read; a read that fails is shown as a note and leaves the known questions as they are.
    /// The project's PM (`pm`) is read too, but only for real menus, and its questions belong to no card.
    func refresh(agents: [AgentStatus], cards: [TaskCard], projectWorktrees: URL, pm: AgentStatus? = nil, pmProject: String? = nil, label: (AgentStatus) -> String) async {
        var found: [PendingQuestion] = []
        var failure: String?
        var livePanes: Set<String> = []
        var failedPanes: Set<String> = []
        generation += 1
        let mine = generation
        let startEpoch = epoch
        for agent in agents where [.blocked, .idle, .done].contains(agent.state) && !TerminalShells.isUserShell(agent.paneID) {
            let isPM = pm.map { $0.paneID == agent.paneID && $0.sessionID == agent.sessionID } ?? false
            // Only the agent the panel started for the task: a Claude session the user opened inside the worktree is never read or answered.
            // The PM is read only while it is blocked at a menu: its idle reply is not a question.
            let card = cards.first(where: { $0.status.holdsAgent && $0.agent != nil && $0.agent == agent.name && Self.runs(agent, in: $0, worktrees: projectWorktrees) })
            if isPM { guard agent.state == .blocked else { continue } } else if card == nil { continue }
            livePanes.insert(agent.paneID)
            let question: AgentQuestion?
            // A blocked agent is read every time: its menu may be drawn after its state changed, or replaced by the next menu without a change of state.
            if agent.state != .blocked, let known = seen[agent.paneID], known.state == agent.state, known.seq == agent.changeSeq, known.session == agent.sessionID, agent.changeSeq != nil {
                question = known.question
            } else {
                do {
                    let screen = try await reader.screen(of: agent.paneID, lines: Self.screenLines)
                    var held = false
                    question = await callQuestion(QuestionDetector.detect(screen: screen, state: agent.state), of: agent, held: &held)
                    // A call held back because the user is in the pane is looked at again on the next refresh, whatever the state counter says.
                    if !held, startEpoch[agent.paneID, default: 0] == epoch[agent.paneID, default: 0] { seen[agent.paneID] = (agent.state, agent.changeSeq, agent.sessionID, question) }
                } catch {
                    failedPanes.insert(agent.paneID)
                    failure = "Could not read \(label(agent)): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                    if let old = questions.first(where: { $0.paneID == agent.paneID }) { found.append(old) }
                    continue
                }
            }
            if startEpoch[agent.paneID, default: 0] != epoch[agent.paneID, default: 0] { continue }
            if let question, !isPM || question.kind != .freeText {
                let pending = PendingQuestion(paneID: agent.paneID, sessionID: agent.sessionID, agentLabel: isPM ? "PM" : label(agent), cardID: isPM ? "" : card?.id ?? "",
                                              question: question, project: isPM ? pmProject : card?.project, isPM: isPM)
                found.append(pending)
                if askedAt[pending.id] == nil { askedAt[pending.id] = Date() }
                if logged.insert(pending.id).inserted { log.append("asked \(pending.owner) (\(Self.kindName(question.kind)))", project: pending.project) }
            }
        }
        guard mine == generation else { return }  // a newer refresh started meanwhile and owns the result
        seen = seen.filter { livePanes.contains($0.key) }
        readCalls = readCalls.filter { livePanes.contains($0.key) }
        // A dismissed question stays hidden only while it is still on screen; once it is gone and comes back, it is shown again.
        // A pane whose screen could not be read keeps its dismissals.
        // A question that went away and comes back is a new one; a pane that could not be read keeps its entries.
        logged = logged.filter { key in found.contains { $0.id == key } || failedPanes.contains { key.hasPrefix($0 + "|") } }
        dismissed = dismissed.filter { key in found.contains { $0.id == key } || failedPanes.contains { key.hasPrefix($0 + "|") } }
        askedAt = askedAt.filter { entry in found.contains { $0.id == entry.key } || failedPanes.contains { entry.key.hasPrefix($0 + "|") } }
        callDrafts = callDrafts.filter { entry in found.contains { $0.id == entry.key } }
        let visible = found.filter { !dismissed.contains($0.id) }
        relay.update(open: visible, routing: routing)
        questions = visible.filter { !relay.isHeld($0.id) }
        withPM = visible.filter { relay.isHeld($0.id) }
        quiet = found.filter { dismissed.contains($0.id) }
        if let failure { error = failure; readFailureShown = true } else if readFailureShown { error = nil; readFailureShown = false }
    }

    /// The pane the user is typing to in Tentacl's Terminals screen (N224): it counts as the user being in that pane.
    @ObservationIgnored var typingPane: String?

    private func isUserInPane(_ agent: AgentStatus) -> Bool { agent.paneID == typingPane }

    /// A call of several questions that nothing has answered yet is one item for all of them. Claude Code writes the call to the session
    /// file only after it was answered, so the questions are read from the screen by stepping through the tabs (nothing is answered);
    /// a session file that does hold the pending call is used first. Without either, the tabs stay single questions, as before.
    /// While the user is in the agent's pane (typing to it on the Terminals screen) the tabs are not stepped: the screen is shown as it is (`held`) and the call is
    /// read on a later refresh, once the user has left the pane.
    private func callQuestion(_ screen: AgentQuestion?, of agent: AgentStatus, held: inout Bool) async -> AgentQuestion? {
        guard let screen, screen.tabs.count >= 2, !screen.terminalOnly, agent.state == .blocked else { return screen }
        if let session = agent.sessionID,
           let call = AskCallReader.pending(at: TranscriptReader.path(projectsRoot: claudeProjectsRoot, cwd: agent.cwd, session: session)),
           !call.items.contains(where: \.multiSelect), call.isFresh(screen) { return .call(call, from: screen) }
        guard !screen.isReview, screen.tabAnswered.allSatisfy({ !$0 }) else { return screen }
        if let known = readCalls[agent.paneID], known.isUntouched(screen) { return .call(known, from: screen) }
        if isUserInPane(agent) { held = true; return screen }
        guard let call = await readCallFromTabs(screen, pane: agent.paneID) else { return screen }
        readCalls[agent.paneID] = call
        return .call(call, from: screen)
    }

    /// Calls already read from the screen, per pane, so the tabs are stepped through once.
    @ObservationIgnored private var readCalls: [String: AskCall] = [:]

    /// The screen once it has stopped changing (and, with `from`, differs from that one); nil when it never settles.
    private func settledScreen(_ pane: String, from: String? = nil) async -> String? {
        var last: String?
        for attempt in 0..<max(callWait.tries, 1) {
            if attempt > 0 { try? await Task.sleep(for: callWait.step) }
            guard let now = try? await reader.screen(of: pane, lines: Self.screenLines) else { return nil }
            if now == last, now != from { return now }
            last = now
        }
        return nil
    }

    /// Reads every question of the call by moving to the first tab (←) and then through the tabs (→), looking at each; no answer key is
    /// pressed. Ends on the first tab again. Nil (after going back) when any step does not show what a call looks like.
    private func readCallFromTabs(_ first: AgentQuestion, pane: String) async -> AskCall? {
        let n = first.tabs.count
        guard n <= 8 else { return nil }
        var tabs: [AgentQuestion] = []
        var previous: String?
        var ok = true
        do {
            try await keys.sendKeys(target: pane, keys: Array(repeating: "left", count: n))
            for i in 0..<n {
                guard let raw = await settledScreen(pane, from: previous), let tab = QuestionDetector.detect(screen: raw, state: .blocked),
                      tab.tabs == first.tabs, !tab.isReview, tab.tabAnswered.allSatisfy({ !$0 }) else { ok = false; break }
                tabs.append(tab); previous = raw
                try await keys.sendKeys(target: pane, keys: ["right"])
                if i == n - 1 {
                    // After the last question comes the Review step: the tab bar had no more questions than we read.
                    guard let raw = await settledScreen(pane, from: previous), QuestionDetector.detect(screen: raw, state: .blocked)?.isReview == true else { ok = false; break }
                }
            }
            try await keys.sendKeys(target: pane, keys: Array(repeating: "left", count: n))
        } catch { return nil }
        return ok ? AskCall.read(headers: first.tabs, tabs: tabs) : nil
    }

    // MARK: the window's picks for a call

    func callDraft(for question: PendingQuestion) -> CallDraft? {
        question.question.call.map { callDrafts[question.id] ?? CallDraft(count: $0.items.count) }
    }
    func chooseInCall(_ question: PendingQuestion, _ answer: AskCall.Answer) {
        guard var draft = callDraft(for: question) else { return }
        draft.choose(answer); callDrafts[question.id] = draft
    }
    func moveInCall(_ question: PendingQuestion, by delta: Int) {
        guard var draft = callDraft(for: question) else { return }
        draft.move(by: delta); callDrafts[question.id] = draft
    }
    func clearCallDraft(_ question: PendingQuestion) { callDrafts[question.id] = nil }

    /// The question window (N183); nil while it is closed.
    private(set) var focus: QuestionFocus?

    /// Opens the window on `question`; `questions` are the open ones in the order Waiting for you lists them.
    func openFocus(_ question: PendingQuestion, in questions: [PendingQuestion]) { focus = QuestionFocus(opening: question, in: questions) }
    func closeFocus() { focus = nil }
    func moveFocus(by step: Int, in questions: [PendingQuestion]) { focus?.move(by: step, in: questions) }

    /// Called whenever the open questions change: a question that left the list is dropped from the window (with a note unless it
    /// was answered here) and the next one opens; with none left the window closes.
    func syncFocus(_ questions: [PendingQuestion]) {
        guard var f = focus else { return }
        focus = f.sync(questions) ? f : nil
    }

    func dismiss(_ question: PendingQuestion) {
        dismissed.insert(question.id)
        questions.removeAll { $0.id == question.id }
        quiet.append(question)
    }

    /// Presses the option's key in the agent (only options the panel can answer with one key).
    @discardableResult
    func answer(_ question: PendingQuestion, option: QuestionOption) async -> Bool {
        guard !question.question.terminalOnly else { error = "Answer in \(question.isPM ? "the PM" : "the agent")'s terminal."; return false }
        guard !option.isSpecial else { error = "That option has to be answered in the agent's terminal."; return false }
        return await send(question, sent: option.label) { try await self.keys.sendKeys(target: question.paneID, keys: option.keys) }
    }

    /// How long the agent gets to show the next tab after a key (the screen is read again before every step).
    @ObservationIgnored var callWait: (step: Duration, tries: Int) = (.milliseconds(150), 20)

    /// Sends all answers of a call (one per question, in order) and then Submit: the digit of each answer (for the user's own words:
    /// the "Type something." number, the text, Enter), checking the agent's screen before every step, and `1` on the Review step.
    /// It stops, and says where, as soon as the screen is not the one expected; what already went in stays in the agent.
    @discardableResult
    func answerCall(_ question: PendingQuestion, answers: [AskCall.Answer]) async -> Bool {
        guard let call = question.question.call, answers.count == call.items.count else { error = "That is not a call of several questions."; return false }
        for (i, answer) in answers.enumerated() {
            switch answer {
            case .option(let n): guard call.items[i].options.indices.contains(n - 1) else { error = "\(call.items[i].header) has no option \(n)."; return false }
            case .text(let t): guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !t.contains(where: \.isNewline) else { error = "\(call.items[i].header): type your answer on one line."; return false }
            }
        }
        let pane = question.paneID
        let sent = answers.indices.map { call.words(answers[$0], at: $0) }.joined(separator: " · ")
        let ok = await send(question, sent: sent, matches: { call.isUntouched($0) }) {
            // The agent may be on any tab: back to the first one (← does not wrap), where the answers start.
            try await self.keys.sendKeys(target: pane, keys: Array(repeating: "left", count: call.items.count))
            for (i, answer) in answers.enumerated() {
                let live = try await self.expect(question, "question \(i + 1) of \(answers.count) (\(call.items[i].header))") { call.isStep($0, i) }
                switch answer {
                case .option(let n): try await self.keys.sendKeys(target: pane, keys: [String(n)])
                case .text(let t):
                    guard let own = live.options.first(where: { $0.label.hasPrefix("Type something") }), own.number <= 9 else {
                        throw BackendError.failed("\(call.items[i].header) offers no way to type an answer, nothing more was sent")
                    }
                    try await self.keys.sendKeys(target: pane, keys: [String(own.number)])
                    _ = try await self.expect(question, "the text field of question \(i + 1) (\(call.items[i].header))") { call.isStepLoosely($0, i) }
                    try await self.keys.sendText(target: pane, text: t.trimmingCharacters(in: .whitespacesAndNewlines))
                    try await self.keys.sendKeys(target: pane, keys: ["enter"])
                }
            }
            _ = try await self.expect(question, "the Review step") { call.isReview($0) }
            try await self.keys.sendKeys(target: pane, keys: ["1"])
        }
        if ok { callDrafts[question.id] = nil }
        return ok
    }

    /// Waits until the agent's screen is the expected one (the next tab takes a moment to draw); throws where it stopped when it never is.
    private func expect(_ question: PendingQuestion, _ what: String, _ ok: (AgentQuestion) -> Bool) async throws -> AgentQuestion {
        let pane = question.paneID
        var seenNow = "no menu"
        for attempt in 0..<max(callWait.tries, 1) {
            if attempt > 0 { try await Task.sleep(for: callWait.step) }
            guard let now = try await adapter.agents().first(where: { $0.paneID == pane && $0.sessionID == question.sessionID }) else { throw BackendError.failed("the agent is gone") }
            guard now.state == .blocked else { seenNow = "the agent is not waiting at a menu"; continue }
            let screen = try await reader.screen(of: pane, lines: Self.screenLines)
            guard let current = QuestionDetector.detect(screen: screen, state: now.state) else { seenNow = "no menu"; continue }
            if ok(current) { return current }
            seenNow = "\"\(current.title)\""
        }
        throw BackendError.failed("stopped before \(what): the screen shows \(seenNow). Everything before that was sent; the rest stays with \(question.agentLabel)")
    }

    /// Shows an agent's tab on the Terminals screen (set by the panel).
    @ObservationIgnored var openTerminal: ((String) -> Void)?

    /// Shows the agent's terminal (the "Open PM" button of a question the panel cannot answer).
    func openPane(of question: PendingQuestion) async {
        if let openTerminal { openTerminal(question.paneID); return }
        do { try await keys.focus(target: question.paneID) } catch { self.error = "Could not open \(question.agentLabel): \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
    }

    /// Runs the tool's login in Tentacl's terminal (the panel sets it). Afterwards every pane is read again, so a sign-in item goes once the screen no longer shows the login.
    @ObservationIgnored var signIn: ((AgentTool) async -> Void)?
    func signIn(for question: PendingQuestion) async {
        guard let tool = question.question.signInTool else { return }
        await signIn?(tool)
        seen.removeAll()
    }

    /// Tells the agent to move on without an answer: Escape closes a menu, a plain question gets a short instruction.
    @discardableResult
    func skip(_ question: PendingQuestion) async -> Bool {
        switch question.question.kind {
        case .choice: return await send(question, sent: "skipped") { try await self.keys.sendKeys(target: question.paneID, keys: ["esc"]) }
        case .permission, .plan, .signIn: error = "That has to be allowed or denied, not skipped."; return false
        case .freeText: return await send(question, sent: "skipped") { try await self.commander.prompt(target: question.paneID, text: "Skip this question and carry on with your best judgment. Say in your report which assumption you made.") }
        }
    }

    /// Sends a typed answer as a prompt.
    @discardableResult
    func answer(_ question: PendingQuestion, text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return await send(question, sent: text) { try await self.commander.prompt(target: question.paneID, text: text) }
    }

    /// Types the user's own words into a menu's "Type something." and presses Enter; the screen is read again before every step.
    @discardableResult
    func answerTyped(_ question: PendingQuestion, text: String) async -> Bool {
        let words = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !words.isEmpty else { return false }
        guard let number = question.question.typeNumber else { error = "This question has no way to type an answer from the panel."; return false }
        let pane = question.paneID
        return await send(question, sent: words) {
            try await self.keys.sendKeys(target: pane, keys: [String(number)])
            try await self.stillAsking(question, exact: false)
            try await self.keys.sendText(target: pane, text: words)
            try await self.stillAsking(question, exact: false)
            try await self.keys.sendKeys(target: pane, keys: ["enter"])
        }
    }

    /// How long to wait for the agent to finish its turn after Escape, before the feedback is sent as a prompt.
    @ObservationIgnored var escapeWait: (step: Duration, tries: Int) = (.milliseconds(250), 40)

    /// Sends typed feedback for a plan ("Tell Claude what to change") or a denied permission, by the path the screen offers:
    /// menu keys + text typed into option 3 + Enter, or Escape and then a prompt. The screen is read again before every step.
    @discardableResult
    func feedback(_ question: PendingQuestion, text: String) async -> Bool {
        // A line break typed into the pane could press Enter in the middle: the feedback goes in as one line.
        let reason = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !reason.isEmpty else { return false }
        guard let path = question.question.feedbackPath else { error = "This question has no way to send feedback from the panel."; return false }
        let pane = question.paneID
        return await send(question, sent: "feedback: " + reason) {
            switch path {
            case .inline(let select, let tab):
                if !select.isEmpty { try await self.keys.sendKeys(target: pane, keys: select) }
                if tab { try await self.stillAsking(question); try await self.keys.sendKeys(target: pane, keys: ["tab"]) }
                try await self.stillAsking(question, exact: !tab)
                try await self.keys.sendText(target: pane, text: reason)
                try await self.stillAsking(question, exact: false)
                try await self.keys.sendKeys(target: pane, keys: ["enter"])
            case .escapeThenPrompt:
                try await self.keys.sendKeys(target: pane, keys: ["esc"])
                var waited = 0
                while true {
                    let now = try await self.adapter.agents().first { $0.paneID == pane && $0.sessionID == question.sessionID }
                    guard let now else { throw BackendError.failed("the agent is gone") }
                    if now.state == .done || now.state == .idle { break }
                    waited += 1
                    guard waited < self.escapeWait.tries else { throw BackendError.failed("the agent did not stop after Escape") }
                    try await Task.sleep(for: self.escapeWait.step)
                }
                try await self.commander.prompt(target: pane, text: reason)
            }
        }
    }

    /// Between steps of one answer: the same agent still waits at the same menu (`exact`: the same question; after typing, the
    /// option's label holds the typed text, so only the kind and the number of options must match).
    private func stillAsking(_ question: PendingQuestion, exact: Bool = true) async throws {
        let pane = question.paneID
        guard let now = try await adapter.agents().first(where: { $0.paneID == pane && $0.sessionID == question.sessionID }), now.state == .blocked else {
            throw BackendError.failed("\(question.agentLabel) is no longer waiting at that menu")
        }
        let screen = try await reader.screen(of: pane, lines: Self.screenLines)
        guard let current = QuestionDetector.detect(screen: screen, state: now.state) else { throw BackendError.failed("the menu is gone") }
        let same = exact ? current.signature == question.question.signature
            : current.kind == question.question.kind && current.options.count == question.question.options.count
        guard same else { throw BackendError.failed("\(question.agentLabel) is no longer asking that question") }
    }

    /// `matches`: what the agent's screen must still show right before sending; the question's own signature when nil.
    private func send(_ question: PendingQuestion, sent: String, matches: ((AgentQuestion) -> Bool)? = nil, _ action: () async throws -> Void) async -> Bool {
        guard !sending else { return false }
        guard !TerminalShells.isUserShell(question.paneID) else { error = "That is your own shell: the panel does not answer it."; return false }
        sending = true
        defer { sending = false }
        // The pane may have been closed or reused since the question was read: the answer only goes to the same agent session.
        do {
            let current = try await adapter.agents()
            guard let now = current.first(where: { $0.paneID == question.paneID && question.sessionID != nil && $0.sessionID == question.sessionID }) else {
                error = "\(question.agentLabel) is no longer the same agent, so nothing was sent."
                questions.removeAll { $0.id == question.id }
                return false
            }
            // The screen is read again right before sending: the question must still be the one the user saw.
            let screen = try await reader.screen(of: question.paneID, lines: Self.screenLines)
            let live = QuestionDetector.detect(screen: screen, state: now.state)
            guard matches.map({ m in live.map(m) ?? false }) ?? (live?.signature == question.question.signature) else {
                error = "\(question.agentLabel) is no longer asking that question, so nothing was sent."
                questions.removeAll { $0.id == question.id }
                seen[question.paneID] = nil
                return false
            }
            try await action()
        } catch {
            self.error = "The answer could not be sent: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            seen[question.paneID] = nil  // some keys may have gone in: read the screen again
            return false
        }
        log.append("answered \(question.owner) (\(question.paneID))", project: question.project)
        error = nil
        focus?.markAnswered(question.id)
        questions.removeAll { $0.id == question.id }
        withPM.removeAll { $0.id == question.id }
        seen[question.paneID] = nil
        epoch[question.paneID, default: 0] += 1
        if !answeringForPM {
            onAnswered?(question, sent); lastAnswer = SentAnswer(question: question, sent: sent, at: Date())
            if relay.wasRelayed(question.id) { showAnswered(question, answer: sent, byPM: false) }
        }
        return true
    }

    // MARK: the PM's answers (N279)

    /// Types the PM's answer for a relayed question into its agent, the way the card's buttons would, and notes it as answered by the PM.
    /// An option number picks that option; other words are typed where the question takes them. Returns the words sent, or why nothing was.
    func answerForPM(question qid: String, answer: String) async -> Result<String, QuestionAnswerError> {
        guard let entry = relay.held(qid), let pending = withPM.first(where: { $0.id == entry.pendingID }) else {
            return .failure(.init(relay.knows(qid) ? "\(qid) is not open for you any more (it went to the user, was answered, or the agent moved on)" : "there is no question \(qid)"))
        }
        let words = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = pending.question
        var sent: Bool, label = words
        answeringForPM = true; defer { answeringForPM = false }
        if let n = Int(words) {
            guard let option = q.options.first(where: { $0.number == n && !$0.isSpecial }) else {
                return .failure(.init("\(qid) has no option \(n); its options are " + q.options.filter { !$0.isSpecial }.map { String($0.number) }.joined(separator: ", ")))
            }
            label = ReadableQuestion.stripRecommended(option.label)
            sent = await self.answer(pending, option: option)
        } else if q.kind == .freeText {
            sent = await self.answer(pending, text: words)
        } else if q.typeNumber != nil {
            sent = await answerTyped(pending, text: words)
        } else {
            return .failure(.init("\(qid) takes an option number, not words"))
        }
        guard sent else {
            relay.release(entry)
            settleRelay()
            return .failure(.init(error ?? "the answer could not be sent; the question went to the user"))
        }
        relay.markAnswered(entry, answer: label)
        showAnswered(pending, answer: label, byPM: true)
        onAnsweredByPM?(pending, label)
        log.append("answered-by-pm \(qid) (\(pending.cardID)): \(String(label.prefix(80)))", project: pending.project)
        return .success(label)
    }

    private static func kindName(_ kind: AgentQuestion.Kind) -> String {
        switch kind {
        case .choice: "choice"
        case .freeText: "text"
        case .permission: "permission"
        case .plan: "plan"
        case .signIn: "sign-in"
        }
    }

    nonisolated static func runs(_ agent: AgentStatus, in card: TaskCard, worktrees: URL) -> Bool {
        guard let worktree = worktreePath(of: card, worktrees: worktrees) else { return false }
        return runs(agent, inWorktreePath: worktree)
    }

    /// The card's worktree folder (standardized), nil without a valid branch. A caller that checks many agents against many cards
    /// computes these once: standardizing a path per pair is what made the PM lookup slow on a big project.
    nonisolated static func worktreePath(of card: TaskCard, worktrees: URL) -> String? {
        guard let branch = card.branch else { return nil }
        let key = worktrees.path + "\n" + branch
        worktreePaths.lock.lock(); defer { worktreePaths.lock.unlock() }
        if let known = worktreePaths.byKey[key] { return known.isEmpty ? nil : known }
        let path = TaskInput.validBranch(branch) ? worktrees.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).standardizedFileURL.path : ""
        if worktreePaths.byKey.count > 4000 { worktreePaths.byKey = [:] }
        worktreePaths.byKey[key] = path
        return path.isEmpty ? nil : path
    }

    /// Worktree paths already worked out (a list of 100+ cards asks for each one per agent on every draw); an empty path means "no valid branch".
    private final class WorktreePathCache: @unchecked Sendable {
        let lock = NSLock()
        var byKey: [String: String] = [:]
        var cwds: [String: String] = [:]
    }
    private nonisolated static let worktreePaths = WorktreePathCache()

    /// An agent's cwd standardized: `standardizedFileURL` asks the file system (`lstat`), and every draw checks every agent against every card.
    nonisolated static func standardizedPath(_ path: String) -> String {
        worktreePaths.lock.lock(); defer { worktreePaths.lock.unlock() }
        if let known = worktreePaths.cwds[path] { return known }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        if worktreePaths.cwds.count > 4000 { worktreePaths.cwds = [:] }
        worktreePaths.cwds[path] = standard
        return standard
    }

    nonisolated static func runs(_ agent: AgentStatus, inWorktreePath worktree: String) -> Bool {
        guard !agent.cwd.isEmpty else { return false }
        let cwd = standardizedPath(agent.cwd)
        return cwd == worktree || cwd.hasPrefix(worktree + "/")
    }
}
