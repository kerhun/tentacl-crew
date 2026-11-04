import Foundation

/// Phase 3 actions: prepare a review packet, approve (merge) and ask for a fix. Same busy and message rules as starting a task.
extension PanelModel {
    var reviewDisabledReason: String? { reviewDisabledReason(for: selectedProjectID) }

    func reviewDisabledReason(for id: String?) -> String? {
        guard let project = config(of: id) else { return "No project selected." }
        if settings.scriptsDir == nil { return "Set \"scriptsDir\" in ~/.config/tentacl/projects.json to enable reviewing." }
        if project.sourcePath == nil { return "The location of project.json is unknown." }
        return nil
    }

    private func makeReviewFlow(project id: String? = nil) -> ReviewFlow? {
        guard reviewDisabledReason(for: id) == nil, let project = config(of: id) else { return nil }
        return ReviewFlow(project: project, scripts: makeScripts(settings), adapter: makeTerminal(), commander: makeCommander(), writer: cardWriter, log: actionLog)
    }

    @discardableResult
    func prepareReview(_ card: TaskCard, project id: String? = nil) async -> ActionResult {
        guard !isBusy else { return .busy }
        guard let flow = makeReviewFlow(project: id) else { let m = reviewDisabledReason(for: id) ?? "actions are not available"; setActionState(.failed(m)); return .failed(m) }
        setActionState(.running("Preparing the review for \(card.id): building and taking a screenshot…"))
        setCommitAsk(nil)
        var result = ActionResult.ok
        do {
            try await flow.preparePacket(for: card)
            setActionState(.done("The review for \(card.id) is ready."))
        } catch {
            let message = Self.reviewMessage(error)
            setActionState(.failed(message)); result = .failed(message)
            if message.contains(Self.uncommittedMarker) { await rememberCommitAsk(for: card) }
        }
        await reloadCards(of: id)
        return result
    }

    /// The autopilot prepares the review of a finished agent's work. Quiet: it does not use the action bar, and only a failure of the packet itself is reported.
    func autoPrepareReview(_ card: TaskCard, project id: String? = nil) async -> PacketOutcome {
        guard let flow = makeReviewFlow(project: id) else { return .skipped }
        let outcome: PacketOutcome
        do {
            try await flow.preparePacket(for: card)
            actionLog.append("autopilot: review of \(card.id) prepared", project: id ?? selectedProjectID)
            outcome = .ready
        } catch let error as ReviewError {
            switch error {
            case .packetMissing(let text), .failed(let text): outcome = .failed(text)
            default: outcome = .skipped
            }
        } catch {
            outcome = .skipped
        }
        await reloadCards(of: id)
        return outcome
    }

    /// How far behind main the card's branch is, for the autopilot; nil when it is up to date or the check cannot run.
    func commitsBehindMain(_ card: TaskCard, project id: String? = nil) async -> Int? {
        // The autopilot must not ask the agent to rebase a card Approve is about to merge (or rebase) itself.
        if ReviewFlow.isApproving(card) { return nil }
        return await makeReviewFlow(project: id)?.commitsBehindMain(card)
    }

    /// Runs only the failing tests on main (N214); the autopilot sends the agent only what main passes.
    func checkTestsOnMain(_ card: TaskCard, tests: [String], project id: String? = nil) async -> MainCheck {
        guard let project = config(of: id) else { return .unavailable(reason: "no project") }
        let folder = project.worktreesURL.appendingPathComponent("main-check-\(card.id)")
        let result = await MainTestCheck(repo: project.repoURL.path, base: project.baseBranch, folder: folder).run(tests)
        actionLog.append("autopilot: \(tests.count) failing test\(tests.count == 1 ? "" : "s") of \(card.id) run on \(project.baseBranch): \(result)", project: id ?? selectedProjectID)
        return result
    }

    /// The autopilot's own rebase (N207): never while the agent works in the worktree, Approve is on the card or another action (a merge) runs.
    func autoRebase(_ card: TaskCard, project id: String? = nil) async -> AutoRebaseResult {
        guard !isBusy, !ReviewFlow.isApproving(card), phase(of: card, in: id ?? selectedProjectID) != .working, let flow = makeReviewFlow(project: id) else { return .skipped }
        let result = await flow.autoRebase(card, agentWorking: false)
        if case .rebased = result { actionLog.append("autopilot: \(card.id) rebased onto main by the panel", project: id ?? selectedProjectID) }
        await reloadCards(of: id)
        return result
    }

    /// The autopilot sends a fix request it wrote itself. Returns nil when it reached the agent, else the reason it did not.
    func autoRequestFix(_ card: TaskCard, notes: String, project id: String? = nil) async -> String? {
        guard let flow = makeReviewFlow(project: id) else { return reviewDisabledReason(for: id) ?? "actions are not available" }
        var failure: String?
        do { try await flow.requestFix(for: card, notes: notes, rebase: ReviewFlow.isRebaseRequest(notes)); actionLog.append("autopilot: fix request for \(card.id) from the autopilot", project: id ?? selectedProjectID) }
        catch { failure = Self.reviewMessage(error) }
        await reloadCards(of: id)
        await refreshAgents()
        return failure
    }

    /// What the approval sheet will show, or the reason Approve cannot go ahead (shown to the user as it is).
    func approvalPlan(for card: TaskCard, project projectID: String? = nil) async -> Result<ApprovalPlan, ReviewError> {
        guard let flow = makeReviewFlow(project: projectID) else { return .failure(.invalid(reviewDisabledReason(for: projectID) ?? "actions are not available")) }
        let working = phase(of: card, in: projectID ?? selectedProjectID) == .working
        let id = card.id
        let autopilot = watch(of: projectID).autopilot
        // A fix or rebase request the autopilot is sending right now is as open as one already sent.
        if case .applying? = autopilot.fixes[id]?.state { return .failure(.invalid("A fix request for \(id) is being sent to its agent. Wait for the agent's answer in its Report. Nothing was changed.")) }
        let result: Result<ApprovalPlan, ReviewError>
        do { result = .success(try await flow.approvalPlanRebasing(for: card, agentWorking: working, onFixNotes: { [autopilot] in autopilot.expectOwnFixNote(cardID: id, quoted: $0) })) }
        catch let error as ReviewError { result = .failure(error) }
        catch { result = .failure(.failed(error.localizedDescription)) }
        // A rebase or a fix request changed the card (and maybe its status): show it.
        await reloadCards(of: projectID)
        await refreshAgents()
        return result
    }

    @discardableResult
    func confirmApprove(_ plan: ApprovalPlan, project id: String? = nil) async -> ActionResult {
        guard !isBusy else { return .busy }
        guard let flow = makeReviewFlow(project: id) else { let m = reviewDisabledReason(for: id) ?? "actions are not available"; setActionState(.failed(m)); return .failed(m) }
        setActionState(.running("Merging \(plan.branch) into \(plan.base)…"))
        var result = ActionResult.ok
        // One merge at a time across the app: this waits its turn behind any other merge (N209).
        let outcome = await mergeQueue.run(project: selectedProject?.id ?? "", card: plan.card.id, branch: plan.branch) {
            do { try await flow.approve(plan); return .merged(detail: plan.isAnalysis ? nil : String(plan.head.prefix(7))) }
            catch { return .failed(Self.reviewMessage(error)) }
        }
        if let message = outcome.failure {
            setActionState(.failed(message)); result = .failed(message)
        } else {
            setActionState(.done(plan.isAnalysis ? "\(plan.card.id) approved." : "\(plan.card.id) approved and merged into \(plan.base)."))
        }
        await reloadCards(of: id)
        await refreshAgents()
        return result
    }

    /// Prepare review for a PM request: nil when the packet is complete, else the reason (the message the user would have seen).
    func prepareForRequest(_ card: TaskCard, project id: String? = nil) async -> String? {
        clearActionState()
        return await prepareReview(card, project: id).failure
    }

    /// Approve for a PM request: nil when merged, done and closed, else the reason.
    func approveForRequest(_ plan: ApprovalPlan, project id: String? = nil) async -> String? {
        clearActionState()
        return await confirmApprove(plan, project: id).failure
    }

    /// Cards the "Approve round" sheet lists: all cards of the selected project that are in review with a packet.
    var approveRoundCards: [TaskCard] {
        ApproveRound.candidates(in: cards.compactMap { if case .card(let c) = $0 { return c } else { return nil } })
    }

    /// The sheet's rows, with how far behind main each card is.
    func approveRoundRows() async -> [ApproveRound.Row] {
        var rows: [ApproveRound.Row] = []
        for card in ApproveRound.order(approveRoundCards) { rows.append(ApproveRound.row(card, behind: await commitsBehindMain(card))) }
        return rows
    }

    /// One final approval for the ticked rows. Every merge is the single-card path (plan with rebase and head check, then approve).
    func approveRound(_ rows: [ApproveRound.Row]) async -> ApproveRound.Result {
        let result = await ApproveRound.run(rows: rows, plan: { await self.approvalPlan(for: $0) }, approve: { await self.approveForRequest($0) })
        actionLog.append("approve round: \(result.text)")
        if let failure = result.failure { setActionState(.failed("\(failure.id): \(failure.message)")) }
        else { setActionState(.done(result.text)) }
        return result
    }

    func closeTask(_ card: TaskCard) async {
        guard !isBusy else { return }
        guard let flow = makeReviewFlow() else { setActionState(.failed(reviewDisabledReason ?? "actions are not available")); return }
        setActionState(.running("Closing \(card.id)…"))
        do {
            try await flow.closeTask(card)
            setActionState(.done("\(card.id) cancelled; nothing was merged."))
        } catch {
            setActionState(.failed(Self.reviewMessage(error)))
        }
        await reloadCards()
    }

    /// Returns true when the request reached the agent, so the sheet can close; on false the message is in `actionState`.
    func sendFixRequest(_ card: TaskCard, notes: String) async -> Bool {
        guard !isBusy else { return false }
        guard await wakeBeforeSending(card) else { return false }
        guard let flow = makeReviewFlow() else { setActionState(.failed(reviewDisabledReason ?? "actions are not available")); return false }
        setActionState(.running("Sending the fix request…"))
        autopilot.expectOwnFixNote(cardID: card.id, quoted: ReviewFlow.quoted(notes.trimmingCharacters(in: .whitespacesAndNewlines)))
        var sent = false
        do {
            try await flow.requestFix(for: card, notes: notes)
            setActionState(.done("Fix request sent for \(card.id)."))
            sent = true
        } catch {
            setActionState(.failed(Self.reviewMessage(error)))
        }
        await reloadCards()
        await refreshAgents()
        return sent
    }

    /// The autopilot passes a reviewer's Fix notes entry on through the review flow. Returns nil when it reached the agent, else the reason it did not.
    func passOnFix(_ card: TaskCard, project id: String? = nil) async -> String? {
        if (id == nil || id == selectedProjectID), !(await wakeBeforeSending(card)) { return "the agent is asleep and could not be woken" }
        guard let flow = makeReviewFlow(project: id) else { return reviewDisabledReason(for: id) ?? "actions are not available" }
        var failure: String?
        do { try await flow.passOnFixNotes(for: card); actionLog.append("autopilot: fix notes of \(card.id) passed on", project: id ?? selectedProjectID) }
        catch { failure = Self.reviewMessage(error) }
        await reloadCards(of: id)
        await refreshAgents()
        return failure
    }

    static let uncommittedMarker = "uncommitted work in the agent's worktree"

    /// The "Ask the agent to commit" button is offered while the uncommitted-work message is still the one on screen.
    var canAskToCommit: Bool {
        if case .failed(let m) = actionState, m.contains(Self.uncommittedMarker), commitAsk != nil { return true }
        return false
    }

    /// Remembers the agent working in the card's worktree now, so the request goes to that session and no other.
    private func rememberCommitAsk(for card: TaskCard) async {
        guard let project = selectedProject, let branch = card.branch, TaskInput.validBranch(branch),
              let agents = try? await makeTerminal().agents() else { return }
        let worktree = project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).standardizedFileURL.path
        guard let agent = agents.first(where: { let cwd = URL(fileURLWithPath: $0.cwd).standardizedFileURL.path; return $0.name == card.agent && (cwd == worktree || cwd.hasPrefix(worktree + "/")) }) else { return }
        setCommitAsk(CommitAsk(cardID: card.id, cardPath: card.url.path, branch: branch, agentName: card.agent ?? agent.title, paneID: agent.paneID, sessionID: agent.sessionID))
    }

    /// Sends the one prompt through the command path (the pane and session are checked again right before sending).
    @discardableResult
    func askAgentToCommit() async -> ActionResult {
        guard canAskToCommit, let ask = commitAsk else { return isBusy ? .busy : .failed("There is nothing to ask the agent.") }
        let result = await sendCommand(ask.prompt, to: ask.paneID, session: ask.sessionID, remember: false)
        if result == .ok {
            setCommitAsk(nil)
            setActionState(.done("Asked \(ask.agentName) to commit its work on \(ask.branch) and fill the Report of \(ask.cardID)."))
        }
        return result
    }

    private static func reviewMessage(_ error: Error) -> String {
        (error as? ReviewError)?.message ?? error.localizedDescription
    }
}

/// The agent to ask after "uncommitted work" stopped Prepare review.
struct CommitAsk: Equatable {
    let cardID: String
    let cardPath: String
    let branch: String
    let agentName: String
    let paneID: String
    let sessionID: String?

    var prompt: String {
        "Your worktree has uncommitted work, so the review cannot be prepared. Commit it on your branch \(branch) (small, focused commits), then fill in the Report section of your task card \(cardPath), and tell me briefly when finished."
    }
}
