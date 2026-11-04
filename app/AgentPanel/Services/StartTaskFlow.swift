import Foundation

/// Starts a task: checks it, runs the Phase 0 spawn script, hands the card to the agent and marks the card `doing`.
/// Every step after the agent exists is undone when a later step fails, so a failed start leaves no running agent behind.
final class StartTaskFlow: @unchecked Sendable {
    private let project: ProjectConfig
    private let scripts: ScriptRunning
    private let commander: TerminalCommanding
    /// Makes sure the terminal's server answers before the spawn script runs (starts tentacld when it is down).
    private let server: TerminalServerEnsuring
    private let writer: CardWriting
    private let log: ActionLog
    private let roleStore: RoleStore
    private let teamStore: TeamChartStore
    private let runningCards: @Sendable () -> [TaskCard]
    /// What the card's Dependencies section allows; the default allows everything.
    private let dependencyState: @Sendable (TaskCard) -> DependencyState
    /// nil means "do not check" (tests, or no Claude config to read).
    private let trust: ClaudeTrust?
    /// Shared by every flow instance: a card that is being started anywhere cannot be started again.
    private static let lock = NSLock()
    private static var inFlight: Set<String> = []

    init(project: ProjectConfig, scripts: ScriptRunning, commander: TerminalCommanding, writer: CardWriting,
         log: ActionLog, roleStore: RoleStore, teamStore: TeamChartStore, runningCards: @escaping @Sendable () -> [TaskCard], trust: ClaudeTrust? = nil,
         dependencyState: @escaping @Sendable (TaskCard) -> DependencyState = { _ in .clear },
         server: TerminalServerEnsuring = NoTerminalServerCheck()) {
        self.server = server
        self.project = project
        self.scripts = scripts
        self.commander = commander
        self.writer = writer
        self.log = log
        self.roleStore = roleStore
        self.teamStore = teamStore
        self.runningCards = runningCards
        self.trust = trust
        self.dependencyState = dependencyState
    }

    // MARK: plan

    func plan(for card: TaskCard) throws -> StartPlan {
        guard card.status == .todo || card.status == .awaitingStartApproval else {
            throw StartError.notStartable("the card's status is \"\(card.status.label)\"")
        }
        switch dependencyState(card) {
        case .waiting(let ids): throw StartError.notStartable("it is waiting for \(ids.joined(separator: ", "))")
        case .problem(let text): throw StartError.invalid("the Dependencies section has a problem: \(text)")
        case .clear, .ready: break
        }
        guard TaskInput.validTaskID(card.id) else { throw StartError.invalid("the task id \"\(card.id)\" is not a plain name") }
        let branch = (card.branch?.isEmpty == false) ? card.branch! : "task/\(card.id.lowercased())"
        guard TaskInput.validBranch(branch) else { throw StartError.invalid("the branch name \"\(branch)\" is not allowed") }
        guard let source = project.sourcePath else { throw StartError.invalid("the location of project.json is unknown") }
        let roleName = card.roles.first ?? "dev"
        let found = roleStore.resolve(roleName, in: project)
        guard let role = found.role else {
            let where_ = found.searched.isEmpty ? "role names are lowercase letters, digits or _" : "looked in: " + found.searched.joined(separator: "; ")
            if let template = RoleTemplates.all.first(where: { $0.id == roleName && $0.id != "empty" }) {
                throw StartError.missingRole(name: roleName, template: template.id, detail: where_)
            }
            throw StartError.invalid("no role called \"\(roleName)\" is defined (\(where_))")
        }
        guard role.config.kind == "interactive" else {
            throw StartError.invalid("the role \"\(role.config.name)\" is headless; the panel starts only interactive roles (change its Kind in the Team screen)")
        }
        let roleProblems = RoleValidator.problems(for: role.config).filter { $0.severity == .error }
        if !roleProblems.isEmpty {
            throw StartError.invalid("the role \"\(role.config.name)\" is not valid: " + roleProblems.map { "\($0.field): \($0.message)" }.joined(separator: " "))
        }
        if runningCards().filter({ $0.status.holdsAgent }).count >= project.maxParallel { throw StartError.capacity(project.maxParallel) }
        let authority = try authorityFor(card, role: roleName)

        let agentName = TaskInput.agentName(role: role.config.name, task: card.id, projectID: project.id)
        let folder = Self.worktreeFolder(for: branch)
        let worktree = project.worktreesURL.appendingPathComponent(folder).path
        if FileManager.default.fileExists(atPath: worktree) { throw StartError.invalid("the worktree folder \(worktree) already exists (it may belong to another agent)") }
        if runningCards().contains(where: { $0.id != card.id && $0.branch.map(Self.worktreeFolder) == folder }) {
            throw StartError.invalid("another running task uses the same worktree folder (\(folder)); pick a different branch name")
        }
        let preview = (["spawn-agent.sh", source, role.fileURL.path, card.id, branch]).map(Self.quoted).joined(separator: " ")
        return StartPlan(card: card, agentName: agentName, branch: branch, rolePath: role.fileURL.path, worktreePath: worktree, commandPreview: preview,
                         roleName: role.config.name, roleDisplayName: role.config.displayName.flatMap { $0.isEmpty ? nil : $0 }, authority: authority,
                         needsTrust: trust.map { !$0.isTrusted(project.repoPath) } ?? false)
    }

    /// spawn-agent.sh puts a branch's worktree in a folder named after it with "/" replaced by "-", so `a/b` and `a-b` collide.
    static func worktreeFolder(for branch: String) -> String { branch.replacingOccurrences(of: "/", with: "-") }

    static func quoted(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-:@")
        return s.isEmpty || s.unicodeScalars.contains(where: { !safe.contains($0) }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }

    /// The team chart's answer to "may the card's giver give this task to this role?". A project without a chart is not checked;
    /// a broken chart or an odd `from` value stops the start before anything runs.
    private func authorityFor(_ card: TaskCard, role: String) throws -> StartAuthority {
        switch teamStore.load(for: project) {
        case .none: return .notApplicable
        case .invalid(let problems):
            throw StartError.invalid("the team chart (team.json) is invalid, so no task can be checked: " + problems.map(\.message).joined(separator: " "))
        case .valid(let chart):
            let from = card.from
            if let from, from != "user", !RoleValidator.validName(from) {
                throw StartError.invalid("the card's \"from\" is not a plain role name or \"user\"")
            }
            let giver = from ?? "user"
            if chart.canAssign(from: from, to: role) { return .allowed(from: giver, to: role) }
            if chart.member(giver) == nil { return .denied("\"\(giver)\" is not in the team chart, so it cannot give tasks.") }
            if chart.member(role) == nil { return .denied("\"\(role)\" is not in the team chart; only you can give it tasks.") }
            let boss = chart.manager(of: role).map { "it reports to \"\($0)\"" } ?? "it reports to you"
            return .denied("\"\(giver)\" is not above \"\(role)\" in the team chart (\(boss)).")
        }
    }

    // MARK: start

    /// `status` gets the line the panel shows while a step waits ("Starting the terminal…", then "Starting <agent>…").
    func start(_ plan: StartPlan, givingItMyself: Bool = false, status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> StartedAgent {
        let card = plan.card
        let key = card.url.path
        Self.lock.lock()
        let isNew = Self.inFlight.insert(key).inserted
        Self.lock.unlock()
        guard isNew else { throw StartError.alreadyStarting }
        defer { Self.lock.lock(); Self.inFlight.remove(key); Self.lock.unlock() }

        do {
            let started = try await run(plan, givingItMyself: givingItMyself, status: status)
            log.append("start \(card.id) agent=\(started.agent) branch=\(plan.branch) pane=\(started.paneID)", project: project.id)
            return started
        } catch let error as StartError {
            log.append("start \(card.id) FAILED: \(error.message)", project: project.id)
            throw error
        }
    }

    private func run(_ plan: StartPlan, givingItMyself: Bool, status: @escaping @Sendable (String) -> Void) async throws -> StartedAgent {
        let card = plan.card
        guard let source = project.sourcePath else { throw StartError.invalid("the location of project.json is unknown") }

        // The card may have changed since the plan was made (someone else moved it on): do not start for a stale card.
        guard let text = try? String(contentsOf: card.url, encoding: .utf8),
              let current = try? CardParser.parse(text.replacingOccurrences(of: "\r\n", with: "\n"), url: card.url),
              current.status == card.status,
              card.fingerprint.isEmpty || current.fingerprint == card.fingerprint else {
            throw StartError.notStartable("the card changed since it was shown; reload and try again")
        }

        // The team chart said no: only the user, giving the task themselves, can start it (and then the card says so).
        var givenByUser = false
        if case .denied(let reason) = plan.authority {
            guard givingItMyself else { throw StartError.notAuthorized(reason) }
            givenByUser = true
        }

        // The role file may have been deleted since the plan was made: refuse before anything runs.
        guard FileManager.default.fileExists(atPath: plan.rolePath) else {
            throw StartError.invalid("the role file \(plan.rolePath) no longer exists; plan the start again")
        }

        for other in runningCards() where other.status.holdsAgent && other.id != card.id {
            let check: ScriptResult
            do { check = try await scripts.run(.checkConflicts, arguments: [card.url.path, other.url.path, source]) }
            catch { throw StartError.conflict("the conflict check could not run (\(Self.describe(error)))") }
            if check.status != 0 {
                let detail = (check.stdout + check.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                throw StartError.conflict(detail.isEmpty ? "(with \(other.id))" : detail)
            }
        }

        // An agent in a folder Claude Code does not trust stops at its trust question: mark the folder trusted first (the sheet said so).
        if plan.needsTrust {
            let trusted: ScriptResult
            do { trusted = try await scripts.run(.trustFolder, arguments: [project.repoPath]) }
            catch { throw StartError.spawnFailed("the folder could not be marked as trusted for Claude Code (\(Self.describe(error)))") }
            guard trusted.status == 0 else {
                let text = trusted.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw StartError.spawnFailed("the folder could not be marked as trusted for Claude Code: \(text.isEmpty ? "exit status \(trusted.status)" : text)")
            }
        }

        // Other starts may have taken the free slots since the plan was made (a round, a request, a hand start): check again right before spawning.
        if runningCards().filter({ $0.status.holdsAgent && $0.id != card.id }).count >= project.maxParallel { throw StartError.capacity(project.maxParallel) }

        do { try await server.ensureRunning(onStarting: { status("Starting the terminal…") }) }
        catch { throw StartError.spawnFailed(Self.describe(error)) }
        status("Starting \(plan.agentName)…")

        let spawn: ScriptResult
        do { spawn = try await scripts.run(.spawn, arguments: [source, plan.rolePath, card.id, plan.branch]) }
        catch ScriptError.launchFailed(let message) {
            throw StartError.spawnFailed("the script could not be launched: \(message)")   // nothing started: nothing to clean up
        } catch ScriptError.notConfigured(let name) {
            throw StartError.spawnFailed("the script \(name) is not configured")
        } catch {
            // Cut off half way (for example a timeout): the script may have created an agent, so clean up what this run may have made.
            throw await abort(.spawnFailed(Self.describe(error)), agent: plan.agentName, worktree: plan.worktreePath, branch: plan.branch)
        }
        guard spawn.status == 0 else {
            let message = TerminalMessage.plain(spawn.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            throw StartError.spawnFailed(message.isEmpty ? "the script exited with status \(spawn.status)" : message)   // spawn-agent.sh rolls back its own failure
        }
        guard let started = Self.parseStarted(spawn.stdout) else {
            throw await abort(.spawnFailed("the script answered with output the panel cannot read"), agent: plan.agentName, worktree: plan.worktreePath, branch: plan.branch)
        }

        let message = "Your task card: \(card.url.path) (read it fully, then do the task). Follow your role instructions (concise). When finished, fill the card's Report section and tell me briefly."
        do { try await commander.prompt(target: started.paneID, text: message) }
        catch { throw await abort(.promptFailed(Self.describe(error)), agent: started.agent, worktree: started.worktreePath, branch: plan.branch) }

        var changes: [CardField: String] = [.status: "doing", .agent: started.agent, .branch: plan.branch]
        if givenByUser { changes[.from] = "user" }
        do { try writer.update(card, set: changes, expectingStatus: card.status) }
        catch { throw await abort(.cardWriteFailed(Self.describe(error)), agent: started.agent, worktree: started.worktreePath, branch: plan.branch) }
        return started
    }

    // MARK: resume

    /// Starts the card's agent again in its existing worktree and branch, continuing `session` (`spawn-agent.sh --resume`). Nothing is
    /// created or undone on failure: the worktree and branch were there before. Sets the card's `agent` and logs `resume <ID>`.
    func resume(_ card: TaskCard, session: String, nudge: Bool = true, status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> StartedAgent {
        guard card.status == .doing || card.status == .needsFix else { throw StartError.notStartable("the card's status is \"\(card.status.label)\"") }
        guard let source = project.sourcePath else { throw StartError.invalid("the location of project.json is unknown") }
        guard let branch = card.branch, TaskInput.validBranch(branch) else { throw StartError.invalid("the card has no valid branch") }
        let roleName = card.roles.first ?? "dev"
        guard let role = roleStore.resolve(roleName, in: project).role else { throw StartError.invalid("no role called \"\(roleName)\" is defined") }
        guard role.config.kind == "interactive" else { throw StartError.invalid("the role \"\(role.config.name)\" is headless; the panel starts only interactive roles") }
        let key = card.url.path
        Self.lock.lock()
        let isNew = Self.inFlight.insert(key).inserted
        Self.lock.unlock()
        guard isNew else { throw StartError.alreadyStarting }
        defer { Self.lock.lock(); Self.inFlight.remove(key); Self.lock.unlock() }

        do { try await server.ensureRunning(onStarting: { status("Starting the terminal…") }) }
        catch { throw StartError.spawnFailed(Self.describe(error)) }
        status("Resuming \(TaskInput.agentName(role: role.config.name, task: card.id, projectID: project.id))…")
        let spawn: ScriptResult
        do { spawn = try await scripts.run(.spawn, arguments: ["--resume", session, source, role.fileURL.path, card.id, branch]) }
        catch { throw StartError.spawnFailed(Self.describe(error)) }
        guard spawn.status == 0 else {
            let message = TerminalMessage.plain(spawn.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            throw StartError.spawnFailed(message.isEmpty ? "the script exited with status \(spawn.status)" : message)
        }
        guard let started = Self.parseStarted(spawn.stdout) else { throw StartError.spawnFailed("the script answered with output the panel cannot read") }
        // The conversation is back; the card is the same. Failing here leaves the agent running: say so rather than close its context again.
        do { try writer.update(card, set: [.agent: started.agent], expectingStatus: card.status) }
        catch { throw StartError.cardWriteFailed(Self.describe(error)) }
        log.append("resume \(card.id)", project: project.id)
        if nudge {
            do { try await commander.prompt(target: started.paneID, text: ResumeSession.nudge(cardPath: card.url.path)) }
            catch { throw StartError.promptFailed(Self.describe(error)) }
        }
        return started
    }

    /// Undo a start (close the agent; remove its worktree, simulator and fresh branch) and return the error to show:
    /// the original one when the cleanup worked, `cleanupFailed` with the manual steps when it did not.
    private func abort(_ error: StartError, agent: String, worktree: String, branch: String) async -> StartError {
        let detail: String?
        do {
            let result = try await scripts.run(.stop, arguments: [agent, worktree, "--remove-worktree", "--delete-branch", "--expect-branch", branch] + (project.simulator == nil ? ["--no-sim"] : []))
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = result.status == 0 ? nil : (message.isEmpty ? "stop-agent.sh exited with status \(result.status)" : message)
        } catch {
            detail = Self.describe(error)
        }
        guard let detail else { return error }
        let manual = "agent \(agent), worktree \(worktree), branch \(branch), simulator agent-\(agent)"
        log.append("CLEANUP FAILED for \(agent): \(detail). Remove manually: \(manual)", project: project.id)
        return .cleanupFailed(cause: error.plainMessage, detail: detail, manual: manual)
    }

    private static func parseStarted(_ stdout: String) -> StartedAgent? {
        guard let line = stdout.split(separator: "\n").map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let agent = object["agent"] as? String, let pane = object["pane_id"] as? String,
              let worktree = object["worktree_path"] as? String else { return nil }
        return StartedAgent(agent: agent, paneID: pane, worktreePath: worktree, udid: object["udid"] as? String ?? "")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as ScriptError:
            switch e {
            case .notConfigured(let n): return "the script \(n) is not configured"
            case .timedOut(let s): return "the script did not finish within \(s) seconds"
            case .waitTimedOut(let s): return "the packet waited \(s) seconds for the build slot and never started (the run limit did not start)"
            case .launchFailed(let m): return "the script could not be launched: \(m)"
            }
        case let e as BackendError:
            switch e {
            case .notInstalled: return "the terminal is not installed"
            case .notRunning(let m): return "the terminal is not running: \(m)"
            case .failed(let m): return m
            case .badOutput: return "the terminal answered with output the panel cannot read"
            }
        case let e as CardWriteError:
            switch e {
            case .conflict(let expected, let found): return "the card changed (expected \(expected), found \(found))"
            case .isSymlink: return "the card is a symbolic link"
            case .unreadable(let m), .writeFailed(let m): return m
            }
        default: return error.localizedDescription
        }
    }
}
