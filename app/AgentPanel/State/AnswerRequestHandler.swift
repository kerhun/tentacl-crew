import Foundation

/// Hands relayed questions to the PM's pane and carries out the PM's answers (`scripts/answer-question.sh`, N279). An answer counts only
/// with the key of the PM session, only for a question the panel relayed and that is still open, and goes into the agent the way the card's
/// buttons do. A critical question is never relayed, so the PM cannot answer one.
@MainActor
final class AnswerRequestHandler {
    @ObservationIgnored private let projects: () -> [String]
    @ObservationIgnored private let store: (String) -> AnswerRequestStore?
    @ObservationIgnored private let inbox: (String) -> AgentInboxModel?
    @ObservationIgnored private let pmPane: (String) -> String?
    @ObservationIgnored private let tell: (String, String) async -> Void
    @ObservationIgnored private let memory: CommandMemory
    @ObservationIgnored private let log: ActionLog
    private var busy = false

    init(projects: @escaping () -> [String], store: @escaping (String) -> AnswerRequestStore?, inbox: @escaping (String) -> AgentInboxModel?,
         pmPane: @escaping (String) -> String?, tell: @escaping (String, String) async -> Void, memory: CommandMemory, log: ActionLog) {
        self.projects = projects; self.store = store; self.inbox = inbox; self.pmPane = pmPane; self.tell = tell; self.memory = memory; self.log = log
    }

    /// Writes the QUESTION lines the relays queued into the PM's pane, after the session key when the PM has not got it yet.
    func deliver() async {
        for project in projects() {
            guard let relay = inbox(project)?.relay else { continue }
            let lines = relay.takeOutgoing()
            for pane in Set(lines.map(\.pane)) {
                if let key = memory.keyToGive(project: project, pane: pane) { await tell(pane, keyMessage(key)) }
                for line in lines where line.pane == pane {
                    log.append("relayed to the PM: \(String(line.text.prefix(120)))", project: project)
                    await tell(pane, line.text)
                }
            }
        }
    }

    func process() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        for project in projects() {
            guard let store = store(project), let inbox = inbox(project) else { continue }
            for pending in store.pending() {
                let message = await handle(pending, project: project, inbox: inbox)
                store.remove(pending)
                if let pane = pmPane(project) { await tell(pane, message) }
            }
        }
    }

    private func handle(_ pending: PendingAnswerRequest, project: String, inbox: AgentInboxModel) async -> String {
        func refused(_ why: String) -> String {
            log.append("answer-request \(pending.id) refused: \(why)", project: project)
            return "Panel: your answer \(pending.id) was refused: \(why)."
        }
        guard let request = pending.request else { return refused(pending.problem ?? "the request cannot be used") }
        guard memory.accepts(request.key, project: project, pane: pmPane(project)) else {
            memory.keyMayBeLost(project: project)
            return refused((request.key ?? "").isEmpty ? "it carried no key; pass `--key <key>` with the key from the Panel message" : "it carried a wrong key (not the one of this session); the panel was restarted: use `--key <key>` with the newest \"Panel: new authority key\" message")
        }
        switch await inbox.answerForPM(question: request.question, answer: request.answer) {
        case .success(let words):
            log.append("answer-request \(request.id) answered \(request.question)", project: project)
            return "Panel: answered \(request.question) with \"\(words)\"."
        case .failure(let error): return refused(error.message)
        }
    }
}
