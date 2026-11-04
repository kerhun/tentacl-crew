import Foundation

/// Phase 3: prepares the review packet, approves (merge, card done, agent closed) and sends fix requests.
/// The merge cannot be undone, so every safety check happens before it and nothing is rolled back after it:
/// a later failure is reported with what is done and what the user has to do by hand.
final class ReviewFlow: @unchecked Sendable {
    private let project: ProjectConfig
    private let scripts: ScriptRunning
    private let adapter: TerminalListing
    private let commander: TerminalCommanding
    private let writer: CardWriting
    private let log: ActionLog
    private let now: @Sendable () -> Date

    /// Shared by every flow instance: a card being prepared, approved or fixed anywhere cannot be touched again until that ends.
    private static let lock = NSLock()
    private static var inFlight: Set<String> = []

    /// A fix or rebase request sent to an agent that has not answered in its Report yet (N95), by card file. `rebase` is the autopilot's plain
    /// "rebase onto main" request, which Approve can do itself; every other request has to be answered by the agent first.
    private struct OpenRequest { let report: String; let rebase: Bool }
    private static var openRequests: [String: OpenRequest] = [:]
    /// Cards whose approval is being planned or carried out right now: the autopilot does not ask their agents to rebase.
    private static var approving: [String: Int] = [:]

    init(project: ProjectConfig, scripts: ScriptRunning, adapter: TerminalListing, commander: TerminalCommanding, writer: CardWriting,
         log: ActionLog, now: @escaping @Sendable () -> Date = { Date() }) {
        self.project = project
        self.scripts = scripts
        self.adapter = adapter
        self.commander = commander
        self.writer = writer
        self.log = log
        self.now = now
    }

    // MARK: prepare

    /// Builds the evidence (build, screenshot, diff) with `review-packet.sh`, which moves the card to `review` only when it is complete.
    func preparePacket(for card: TaskCard) async throws {
        let target = try validated(card)
        guard card.status == .doing || card.status == .needsFix || card.status == .review else {
            throw ReviewError.invalid("Only tasks that are doing, need a fix or are in review can be prepared for review.")
        }
        try await exclusive(card) {
            let current = try self.current(card)
            guard current.status == card.status else { throw ReviewError.invalid("The card changed since it was shown; reload and try again.") }
            // Also the packet prepared again after a rebase: it comes through here too.
            self.log.append("review packet started for \(card.id)", project: self.project.id)

            // Only a project with a simulator gives its agents one; the others are reviewed without a device.
            var udid = ""
            if self.project.simulator != nil {
                let sim = try await self.run(.sim, [target.agent, target.source])
                udid = sim.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { !$0.isEmpty }) ?? ""
                guard sim.status == 0, !udid.isEmpty else {
                    throw ReviewError.failed("The agent's simulator could not be found: \(Self.text(sim, fallback: "sim-for-agent.sh exited with status \(sim.status)"))")
                }
            }
            let result = try await self.run(.reviewPacket, [card.url.path, target.worktree, udid, target.source])
            guard result.status == 0 else {
                let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if out.contains("EVIDENCE MISSING") { throw ReviewError.packetMissing(out) }
                throw ReviewError.failed(Self.text(result, fallback: "review-packet.sh exited with status \(result.status)"))
            }
            self.log.append("review packet prepared for \(card.id)", project: self.project.id)
        }
    }

    /// A project without a simulator must not make stop-agent look for one: an agent of another project may have the same name.
    private var stopFlags: [String] { project.simulator == nil ? ["--no-sim"] : [] }

    /// True while Approve is planning or merging the card.
    static func isApproving(_ card: TaskCard) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return approving[card.url.path] != nil
    }

    private static func beginApproving(_ card: TaskCard) {
        lock.lock(); approving[card.url.path, default: 0] += 1; lock.unlock()
    }

    private static func endApproving(_ card: TaskCard) {
        lock.lock()
        let left = (approving[card.url.path] ?? 1) - 1
        approving[card.url.path] = left > 0 ? left : nil
        lock.unlock()
    }

    /// The autopilot's rebase request (`AutopilotModel.rebaseNotes`), as opposed to a conflict request or a reviewer's note.
    static func isRebaseRequest(_ notes: String) -> Bool {
        let prefix = "Your branch is "
        guard notes.hasPrefix(prefix), let first = notes.dropFirst(prefix.count).first else { return false }
        return first.isNumber
    }

    private static func reportText(_ card: TaskCard) -> String { (card.sections["Report"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func remember(_ card: TaskCard, _ request: OpenRequest?) {
        lock.lock(); openRequests[card.url.path] = request; lock.unlock()
    }

    /// The request to the card's agent that is still unanswered: the agent has not changed its Report since and still runs in the worktree.
    private func openRequest(for card: TaskCard, target: Target) async throws -> OpenRequest? {
        Self.lock.lock(); let request = Self.openRequests[card.url.path]; Self.lock.unlock()
        guard let request else { return nil }
        let report = (try? current(card, checkingFrontMatter: false)).map(Self.reportText) ?? request.report
        let agents: [AgentStatus]
        do { agents = try await adapter.agents() } catch { throw ReviewError.failed(StartTaskFlow.describe(error)) }
        if report != request.report || !agents.contains(where: { $0.name == target.agent && Self.runs(in: target.worktree, $0.cwd) }) {
            Self.remember(card, nil)
            return nil
        }
        return request
    }

    private func refuse(_ card: TaskCard, _ request: OpenRequest) -> ReviewError {
        let kind = request.rebase ? "rebase request" : "fix request"
        log.append("approve \(card.id) refused: the \(kind) is still open", project: project.id)
        return .invalid("The \(kind) to \(card.agent ?? "the agent") for \(card.id) is still open: the agent has not answered in its Report yet. Wait for it, then prepare the review again. Nothing was changed.")
    }

    /// Approve never goes on while the agent still owes an answer; throws the reason.
    private func ensureNoOpenRequest(_ card: TaskCard, target: Target) async throws {
        if let request = try await openRequest(for: card, target: target) { throw refuse(card, request) }
    }

    /// An open plain rebase request is withdrawn (Approve rebases itself) when the agent is idle and told so; a fix request, or a working agent, blocks.
    private func settleOpenRequest(_ card: TaskCard, target: Target, agentWorking: Bool) async throws {
        guard let request = try await openRequest(for: card, target: target) else { return }
        guard request.rebase, !agentWorking else { throw refuse(card, request) }
        let agents: [AgentStatus]
        do { agents = try await adapter.agents() } catch { throw ReviewError.failed(StartTaskFlow.describe(error)) }
        guard let agent = agents.first(where: { $0.name == target.agent && Self.runs(in: target.worktree, $0.cwd) }) else { return Self.remember(card, nil) }
        do { try await commander.prompt(target: agent.paneID, text: Self.withdrawMessage(project.baseBranch)) }
        catch { throw ReviewError.failed("The rebase request to the agent could not be withdrawn (\(StartTaskFlow.describe(error))). Nothing was changed.") }
        Self.remember(card, nil)
        log.append("rebase request for \(card.id) withdrawn: approve rebases it itself", project: project.id)
    }

    static func withdrawMessage(_ base: String) -> String {
        "Withdrawn: the rebase request is cancelled, do not rebase. The panel rebases your branch onto \(base) itself while approving it. Do not change your branch; wait."
    }

    /// How many commits main has that the card's branch lacks (what makes its fast-forward merge fail); 0 when none, nil when it cannot be told.
    func commitsBehindMain(_ card: TaskCard) async -> Int? {
        guard let target = try? validated(card),
              let inspect = try? await run(.merge, ["--inspect", target.source, target.branch, target.worktree]), inspect.status == 0,
              let info = Self.parseInspect(inspect.stdout) else { return nil }
        // A branch with no commits of its own fast-forwards whatever main did: it has nothing to rebase.
        return info.ahead > 0 ? info.behind : 0
    }

    // MARK: approve

    enum RebaseOutcome: Equatable { case notNeeded, rebased(head: String), conflict([String]) }

    /// Rebases a branch that is behind main onto it, in the agent's worktree, when it applies cleanly (`merge-task.sh --rebase`).
    /// Never when the agent is working or the tree is dirty: those are reported as they are today. A conflict changes nothing.
    func rebaseIfBehind(_ card: TaskCard, agentWorking: Bool) async throws -> RebaseOutcome {
        let target = try validated(card)
        guard card.kind != "analysis" else { return .notNeeded }
        let inspect = try await run(.merge, ["--inspect", target.source, target.branch, target.worktree])
        guard inspect.status == 0, let info = Self.parseInspect(inspect.stdout), info.ahead > 0, info.behind > 0 else { return .notNeeded }
        if agentWorking { throw ReviewError.notFastForward }
        if info.worktreeDirty { throw ReviewError.worktreeDirty }
        let result = try await run(.merge, ["--rebase", target.source, target.branch, target.worktree])
        switch result.status {
        case 0:
            guard let head = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])?["rebased"] as? String else { return .notNeeded }
            log.append("rebased \(target.branch) onto \(info.base) for \(card.id); head is \(head.prefix(7))", project: project.id)
            return .rebased(head: head)
        case 6: throw ReviewError.worktreeDirty
        case 9:
            log.append("rebase of \(target.branch) onto \(info.base) for \(card.id) conflicts; nothing changed", project: project.id)
            return .conflict(Self.lines(result.stdout))
        default: throw ReviewError.failed(Self.text(result, fallback: "merge-task.sh exited with status \(result.status)"))
        }
    }

    /// The autopilot's use of `rebaseIfBehind` (N207): what came of it, with the cases where nothing may be done folded into `.skipped`.
    func autoRebase(_ card: TaskCard, agentWorking: Bool) async -> AutoRebaseResult {
        if agentWorking { return .skipped }
        do {
            switch try await rebaseIfBehind(card, agentWorking: false) {
            case .notNeeded: return .skipped
            case .rebased(let head): return .rebased(head: head)
            case .conflict(let files): return .conflict(files)
            }
        } catch ReviewError.worktreeDirty { return .dirty }
        catch { return .skipped }
    }

    static func conflictNotes(files: [String], base: String) -> String {
        "Your branch is behind \(base) and rebasing it onto \(base) conflicts in: \(files.joined(separator: ", ")). Rebase it yourself, resolve the conflicts, rerun both test suites (scripts/app-test.sh and bash tests/run.sh), and update the Report. \(answerRule)"
    }

    /// Approve's plan for a card whose branch may be behind main: a clean rebase is done here, the review is prepared again on the new
    /// head (build and tests must pass on the rebased code), then the plan is made. A conflict sends one fix request naming the files.
    func approvalPlanRebasing(for card: TaskCard, agentWorking: Bool, onFixNotes: @MainActor (String) -> Void = { _ in }) async throws -> ApprovalPlan {
        Self.beginApproving(card)
        defer { Self.endApproving(card) }
        try await settleOpenRequest(card, target: try validated(card), agentWorking: agentWorking)
        switch try await rebaseIfBehind(card, agentWorking: agentWorking) {
        case .notNeeded: return try await approvalPlan(for: card)
        case .rebased:
            try await preparePacket(for: card)
            return try await approvalPlan(for: card)
        case .conflict(let files):
            let notes = Self.conflictNotes(files: files, base: project.baseBranch)
            await onFixNotes(Self.quoted(notes))
            try await requestFix(for: card, notes: notes)
            throw ReviewError.rebaseConflict(files)
        }
    }

    /// Checks everything that can be checked without changing anything; throws the reason Approve cannot go ahead.
    func approvalPlan(for card: TaskCard) async throws -> ApprovalPlan {
        let target = try validated(card)
        let current = try self.current(card)
        guard current.status == .review else { throw ReviewError.invalid("Only tasks in review can be approved.") }
        try await ensureNoOpenRequest(card, target: target)
        let isAnalysis = current.kind == "analysis"
        let raw = current.sections["Review packet"] ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ReviewError.packetMissing("There is no review packet yet. Prepare the review first.") }
        let packet = packetSections(from: raw)
        if !isAnalysis {
            if packet.build.hasPrefix("none"), self.project.buildCommand != nil {
                throw ReviewError.packetMissing("The packet says this project has no build, but it has a build command. Prepare the review again.")
            }
            if packet.screenshotsNotUsed, self.project.screenshotsEnabled, self.project.simulator != nil {
                throw ReviewError.packetMissing("The packet says screenshots are not used, but this project takes them. Prepare the review again.")
            }
            guard packet.buildAcceptable else { throw ReviewError.packetMissing("The build in the review packet did not pass.") }
            guard packet.screenshotsAcceptable else { throw ReviewError.packetMissing("The review packet has no screenshots.") }
        }
        guard let packetHead = packet.head else { throw ReviewError.stale }

        let inspect = try await run(.merge, ["--inspect", target.source, target.branch, target.worktree])
        guard inspect.status == 0 else { throw ReviewError.failed(Self.text(inspect, fallback: "merge-task.sh exited with status \(inspect.status)")) }
        guard let info = Self.parseInspect(inspect.stdout) else { throw ReviewError.failed("merge-task.sh answered with output the panel cannot read.") }
        guard info.head == packetHead else { throw ReviewError.stale }
        if info.worktreeDirty { throw ReviewError.worktreeDirty }
        if info.ahead > 0 {
            if info.repoBranch != info.base { throw ReviewError.invalid("Your repository is on \"\(info.repoBranch)\"; switch it to \"\(info.base)\" first. Nothing was changed.") }
            if info.behind > 0 { throw ReviewError.notFastForward }
            if !info.overlap.isEmpty { throw ReviewError.userFilesInTheWay(info.overlap) }
        }
        let preview = ["merge-task.sh", target.source, target.branch, target.worktree, "--expect-head", packetHead].map(StartTaskFlow.quoted).joined(separator: " ")
        return ApprovalPlan(card: current, agentName: target.agent, branch: target.branch, worktreePath: target.worktree, base: info.base, head: packetHead,
                            ahead: info.ahead, filesChanged: packet.filesChanged, screenshotCount: packet.screenshots.count, isAnalysis: isAnalysis,
                            commandPreview: preview)
    }

    /// Merges, marks the card done and closes the agent, in that order.
    func approve(_ plan: ApprovalPlan) async throws {
        Self.beginApproving(plan.card)
        defer { Self.endApproving(plan.card) }
        try await exclusive(plan.card) {
            let current = try self.current(plan.card)
            guard current.status == .review else { throw ReviewError.invalid("The card is no longer in review.") }
            try await self.ensureNoOpenRequest(current, target: try self.validated(current))
            let source = try self.sourcePath()

            var merged: String?
            if !plan.isAnalysis {
                let result = try await self.run(.merge, [source, plan.branch, plan.worktreePath, "--expect-head", plan.head])
                switch result.status {
                case 0: merged = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])?["merged"] as? String
                case 3: throw ReviewError.invalid(Self.text(result, fallback: "The repository is not on the main branch."))
                case 4: throw ReviewError.notFastForward
                case 5: throw ReviewError.userFilesInTheWay(Self.lines(result.stdout))
                case 6: throw ReviewError.worktreeDirty
                case 7: throw ReviewError.headMoved
                default: throw ReviewError.failed(Self.text(result, fallback: "merge-task.sh exited with status \(result.status)"))
                }
                self.log.append("merged \(plan.branch) into \(plan.base) at \(merged ?? "(nothing to merge)") for \(plan.card.id)", project: self.project.id)
            }

            let doneText = merged != nil ? "The branch is merged into \(plan.base)." : "The task is approved."
            let decision = merged.map { "Approved \(self.stamp()). Merged into \(plan.base) at \($0.prefix(7))." } ?? "Approved \(self.stamp()). Nothing to merge."
            let cleanup = (["stop-agent.sh", plan.agentName, plan.worktreePath, "--remove-worktree", "--delete-branch", "--expect-branch", plan.branch] + stopFlags).map(StartTaskFlow.quoted).joined(separator: " ")
            do {
                try self.writer.update(current, set: [.status: "done"], section: SectionEdit(.decision, decision), expectingStatus: .review)
            } catch {
                let failed = "But the card could not be updated (\(StartTaskFlow.describe(error)))."
                self.log.append("approve \(plan.card.id): \(doneText) CARD NOT UPDATED: \(StartTaskFlow.describe(error))", project: self.project.id)
                throw ReviewError.mergedButIncomplete(done: doneText, failed: failed, manual: "set \"status: done\" in \(plan.card.url.path), then run \(cleanup)")
            }
            self.log.append("approved \(plan.card.id)", project: self.project.id)

            let stop: ScriptResult
            do { stop = try await self.scripts.run(.stop, arguments: [plan.agentName, plan.worktreePath, "--remove-worktree", "--delete-branch", "--expect-branch", plan.branch] + self.stopFlags) }
            catch {
                self.log.append("CLEANUP FAILED for \(plan.agentName): \(StartTaskFlow.describe(error))", project: self.project.id)
                throw ReviewError.mergedButIncomplete(done: "\(doneText) The card is marked done.", failed: "But the agent could not be closed (\(StartTaskFlow.describe(error))).", manual: cleanup)
            }
            // 4: the terminal no longer knew the workspace; everything else was removed.
            if stop.status != 0 && stop.status != 4 {
                let detail = Self.text(stop, fallback: "stop-agent.sh exited with status \(stop.status)")
                self.log.append("CLEANUP FAILED for \(plan.agentName): \(detail)", project: self.project.id)
                throw ReviewError.mergedButIncomplete(done: "\(doneText) The card is marked done.", failed: "But the agent could not be closed (\(detail)).", manual: cleanup)
            }
        }
    }

    // MARK: request fix

    func requestFix(for card: TaskCard, notes: String, rebase: Bool = false) async throws {
        let target = try validated(card)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReviewError.invalid("Write what should change first.") }
        guard card.status == .doing || card.status == .needsFix || card.status == .review else {
            throw ReviewError.invalid("Only tasks that are doing, need a fix or are in review can get a fix request.")
        }
        try await exclusive(card) {
            let current = try self.current(card)
            let before = current.status
            guard before == .doing || before == .needsFix || before == .review else { throw ReviewError.invalid("The card is no longer doing, in need of a fix or in review.") }
            let beforeName = before == .doing ? "doing" : (before == .needsFix ? "needs-fix" : "review")

            let agents: [AgentStatus]
            do { agents = try await self.adapter.agents() } catch { throw ReviewError.failed(StartTaskFlow.describe(error)) }
            guard let agent = agents.first(where: { $0.name == target.agent && Self.runs(in: target.worktree, $0.cwd) }) else { throw ReviewError.agentGone }

            let entry = "### \(self.stamp())\n\n\(Self.quoted(trimmed))"
            do { try self.writer.update(current, set: [.status: "needs-fix"], section: SectionEdit(.fixNotes, entry), expectingStatus: before) }
            catch { throw ReviewError.failed("The card could not be updated: \(StartTaskFlow.describe(error)). Nothing was sent.") }

            do { try await self.commander.prompt(target: agent.paneID, text: Self.fixMessage(card.url.path, roles: card.roles)) }
            catch {
                let cause = StartTaskFlow.describe(error)
                if let written = try? self.current(card, checkingFrontMatter: false), (before == .needsFix || (try? self.writer.update(written, set: [.status: beforeName], expectingStatus: .needsFix)) != nil) {
                    self.log.append("fix request for \(card.id) NOT SENT: \(cause)", project: self.project.id)
                    throw ReviewError.failed("The agent did not get the fix request (\(cause)). The card is back to \(beforeName) and your note is kept in \"Fix notes\".")
                }
                self.log.append("fix request for \(card.id) NOT SENT and the card could not be restored: \(cause)", project: self.project.id)
                throw ReviewError.failed("The agent did not get the fix request (\(cause)) and the card still says needs-fix. Send the request yourself from the command bar.")
            }
            Self.remember(card, OpenRequest(report: Self.reportText(current), rebase: rebase || Self.isRebaseRequest(trimmed)))
            self.log.append("fix request sent to \(agent.paneID) for \(card.id)", project: self.project.id)
        }
    }

    /// Sends the newest entry already in "Fix notes" to the agent (the PM autopilot passes a reviewer's note on): the card moves to
    /// needs-fix and nothing is appended. Works for cards that are doing, need a fix or are in review.
    func passOnFixNotes(for card: TaskCard) async throws {
        let target = try validated(card)
        guard card.status.holdsAgent else {
            throw ReviewError.invalid("Only tasks that are doing, need a fix or are in review can get a fix request.")
        }
        try await exclusive(card) {
            let current = try self.current(card)
            guard current.status.holdsAgent else { throw ReviewError.invalid("The card changed since it was shown; reload and try again.") }
            guard let notes = current.sections["Fix notes"], !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReviewError.invalid("The card has no Fix notes to pass on.")
            }

            let agents: [AgentStatus]
            do { agents = try await self.adapter.agents() } catch { throw ReviewError.failed(StartTaskFlow.describe(error)) }
            guard let agent = agents.first(where: { $0.name == target.agent && Self.runs(in: target.worktree, $0.cwd) }) else { throw ReviewError.agentGone }

            let before = current.status
            let beforeName = before == .doing ? "doing" : "review"
            if before != .needsFix {
                do { try self.writer.update(current, set: [.status: "needs-fix"], expectingStatus: before) }
                catch { throw ReviewError.failed("The card could not be updated: \(StartTaskFlow.describe(error)). Nothing was sent.") }
            }
            do { try await self.commander.prompt(target: agent.paneID, text: Self.fixMessage(card.url.path, roles: card.roles)) }
            catch {
                let cause = StartTaskFlow.describe(error)
                if before != .needsFix {
                    if let written = try? self.current(card, checkingFrontMatter: false), (try? self.writer.update(written, set: [.status: beforeName], expectingStatus: .needsFix)) != nil {
                        self.log.append("fix request for \(card.id) NOT SENT: \(cause)", project: self.project.id)
                        throw ReviewError.failed("The agent did not get the fix request (\(cause)). The card is back to \(beforeName).")
                    }
                    self.log.append("fix request for \(card.id) NOT SENT and the card could not be restored: \(cause)", project: self.project.id)
                    throw ReviewError.failed("The agent did not get the fix request (\(cause)) and the card still says needs-fix. Send the request yourself from the command bar.")
                }
                self.log.append("fix request for \(card.id) NOT SENT: \(cause)", project: self.project.id)
                throw ReviewError.failed("The agent did not get the fix request (\(cause)).")
            }
            Self.remember(card, OpenRequest(report: Self.reportText(current), rebase: false))
            self.log.append("fix request (passed on) sent to \(agent.paneID) for \(card.id)", project: self.project.id)
        }
    }

    static let answerRule = "Answer in the Report under \"### Fix round N\" (one line per F-number, then the new Head), never in Fix notes."

    /// Only roles that build (dev, ui_dev) redo the build and screenshots; the others update their output file and the Report.
    static func fixMessage(_ cardPath: String, roles: [String] = []) -> String {
        let builds = roles.contains("dev") || roles.contains("ui_dev")
        let work = builds ? "fix it, commit, redo the build and screenshots, update the Report" : "fix it, update your output file and the Report"
        return "Fix request for your task card \(cardPath): read the newest entry in \"## Fix notes\", \(work), and tell me briefly when finished. \(answerRule)"
    }

    /// Every line of a note is quoted ("> "): a note with "## " lines must not start a section of its own in the card.
    static func quoted(_ note: String) -> String {
        note.components(separatedBy: "\n").map { "> " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }.joined(separator: "\n")
    }

    // MARK: close

    /// Marks a task cancelled (not done) without merging when there is no agent or worktree left to review (the agent is gone, the card never got
    /// an agent or a branch). Nothing is run and nothing is deleted: the card only records that it was closed this way.
    func closeTask(_ card: TaskCard) async throws {
        guard card.status.holdsAgent else { throw ReviewError.invalid("Only tasks that are doing, need a fix or are in review can be closed.") }
        guard TaskInput.validTaskID(card.id) else { throw ReviewError.invalid("The task id \"\(card.id)\" is not a plain name.") }
        if let target = try? validated(card), FileManager.default.fileExists(atPath: target.worktree) {
            throw ReviewError.invalid("This task still has its agent and worktree. Use Approve or Request fix.")
        }
        try await exclusive(card) {
            let current = try self.current(card)
            guard current.status.holdsAgent else { throw ReviewError.invalid("The card changed since it was shown; reload and try again.") }
            let decision = "Cancelled \(self.stamp()): closed without merge because the agent or its worktree no longer exists."
            do { try self.writer.update(current, set: [.status: "cancelled"], section: SectionEdit(.decision, decision), expectingStatus: current.status) }
            catch { throw ReviewError.failed("The card could not be updated: \(StartTaskFlow.describe(error)).") }
            self.log.append("closed \(card.id) without merge", project: self.project.id)
        }
    }

    // MARK: helpers

    private struct Target { let agent: String; let branch: String; let worktree: String; let source: String }

    /// The card is written by an agent: its id, agent and branch are checked before they reach a script, git or the terminal.
    private func validated(_ card: TaskCard) throws -> Target {
        guard TaskInput.validTaskID(card.id) else { throw ReviewError.invalid("The task id \"\(card.id)\" is not a plain name.") }
        guard let branch = card.branch, TaskInput.validBranch(branch) else {
            throw ReviewError.invalid("The card has no usable branch name, so there is no work to review. If the work is over, use Close task.")
        }
        guard let agent = card.agent, TaskInput.validAgentName(agent) else {
            throw ReviewError.invalid("The card has no usable agent name: the agent that worked on it is gone. If the work is over, use Close task.")
        }
        let source = try sourcePath()
        let worktree = project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).path
        return Target(agent: agent, branch: branch, worktree: worktree, source: source)
    }

    private func sourcePath() throws -> String {
        guard let source = project.sourcePath else { throw ReviewError.invalid("The location of project.json is unknown.") }
        return source
    }

    /// The card as it is on disk now; refuses when its front matter changed since the panel showed it.
    private func current(_ card: TaskCard, checkingFrontMatter: Bool = true) throws -> TaskCard {
        guard let text = try? String(contentsOf: card.url, encoding: .utf8),
              let now = try? CardParser.parse(text.replacingOccurrences(of: "\r\n", with: "\n"), url: card.url) else {
            throw ReviewError.invalid("The card could not be read.")
        }
        if checkingFrontMatter, !card.fingerprint.isEmpty, now.fingerprint != card.fingerprint {
            throw ReviewError.invalid("The card changed since it was shown; reload and try again.")
        }
        return now
    }

    private func run(_ script: ScriptName, _ arguments: [String]) async throws -> ScriptResult {
        do { return try await scripts.run(script, arguments: arguments) }
        catch { throw ReviewError.failed(StartTaskFlow.describe(error)) }
    }

    private func exclusive<T>(_ card: TaskCard, _ body: () async throws -> T) async throws -> T {
        let key = card.url.path
        guard Self.begin(key) else { throw ReviewError.alreadyRunning }
        defer { Self.end(key) }
        return try await body()
    }

    private static func begin(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return inFlight.insert(key).inserted }
    private static func end(_ key: String) { lock.lock(); inFlight.remove(key); lock.unlock() }

    private func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: now())
    }

    private static func text(_ r: ScriptResult, fallback: String) -> String {
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? fallback : out
    }

    private static func lines(_ s: String) -> [String] {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func runs(in worktree: String, _ cwd: String) -> Bool {
        let a = URL(fileURLWithPath: cwd).standardizedFileURL.path, b = URL(fileURLWithPath: worktree).standardizedFileURL.path
        return a == b || a.hasPrefix(b + "/")
    }

    private struct Inspected { let head, base, repoBranch: String; let ahead, behind: Int; let overlap: [String]; let worktreeDirty: Bool }

    private static func parseInspect(_ stdout: String) -> Inspected? {
        guard let line = stdout.split(separator: "\n").map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let head = o["head"] as? String, let base = o["base"] as? String, let ahead = o["ahead"] as? Int, let behind = o["behind"] as? Int,
              let overlap = o["dirtyOverlap"] as? [String], let dirty = o["worktreeDirty"] as? Bool else { return nil }
        return Inspected(head: head, base: base, repoBranch: o["repoBranch"] as? String ?? base, ahead: ahead, behind: behind, overlap: overlap, worktreeDirty: dirty)
    }
}
