import SwiftUI

/// The window: top bar, rail, and the open screen (the Dashboard, or the task list and detail area, or another screen).
struct ShellView: View {
    @Bindable var model: PanelModel
    @State private var pendingPlan: StartPlan?
    /// plan.json as the task list read it; the detail names the card's round from it.
    @State private var tasksPlan: PlanFile?
    @State private var pendingApproval: ApprovalPlan?
    @State private var roundRows: [ApproveRound.Row]?
    @State private var roundResult: ApproveRound.Result?
    @State private var roundRunning = false
    @State private var fixCard: TaskCard?
    @State private var fixNotes = ""
    @State private var closeCard: TaskCard?
    /// The open screen: given at init (snapshots), else the one saved when the app last ran (N260; a new install opens on the
    /// Dashboard). Every change is saved in the model's defaults, which outlive a quit even when macOS does not restore windows.
    @State private var shown: ShellScreen
    private var screen: ShellScreen {
        get { shown }
        nonmutating set { shown = newValue; LayoutRestore.saveScreen(model.defaults, newValue); onScreen(newValue); tutorial.screenChanged(to: newValue) }
    }
    /// Told each screen the window switches to (tests).
    private let onScreen: (ShellScreen) -> Void
    @State private var leavingTeamFor: ShellScreen?
    /// A card asked for a role that has a template: the name to offer adding.
    @State private var missingRole: String?
    @State private var pendingProject: String?
    @State private var addProject: AddProjectFlow?
    @State private var editProject: EditProjectFlow?
    @State private var newTask: NewTaskFlow?
    @State private var settingsFlow: SettingsFlow?
    /// The theme the window was drawn with: Dark and Midnight share one macOS look, so a change redraws the window (spec §4, N312).
    @State private var theme = AppTheme.current
    @State private var cleanup: CleanupFlow?
    @State private var statsModel: StatsModel?
    @State private var gitScreen: GitScreenModel?
    @State private var notesMode = NotesPadMode.closed
    @State private var notesBook = NotesBook()
    /// The note a New task sheet was opened from ("Make a task…"): the line gets the new card's id.
    @State private var noteForTask: (dataDir: URL, text: String)?
    /// The note the ⌘K field opened the pad at; marked in the pad until it closes.
    @State private var noteFocus: UUID?
    /// The card whose detail opens on its Changes tab (the Terminals screen's Changes button).
    @State private var changesTabCardID: String?
    /// The question card's Later / closed / opened state (N371, N376).
    @State private var blockedBannerModel = BlockedBannerModel()
    @Environment(\.snapshotMode) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tours (N311): given by the app (the Help menu shares it), else one of the window's own (snapshots, tests).
    @State private var tutorial: TutorialModel

    /// The window's minimum size (set on the window in AgentPanelApp).
    static let minimumWindow = CGSize(width: 1100, height: 600)

    init(model: PanelModel, screen: ShellScreen? = nil, tutorial: TutorialModel? = nil, blockedCard: BlockedBannerModel? = nil,
         onScreen: @escaping (ShellScreen) -> Void = { _ in }) {
        self.model = model
        self.onScreen = onScreen
        let shown = screen ?? LayoutRestore.screen(model.defaults)
        _shown = State(initialValue: shown)
        _tutorial = State(initialValue: tutorial ?? TutorialModel(store: TutorialStore(defaults: model.defaults), screen: shown))
        if let blockedCard { _blockedBannerModel = State(initialValue: blockedCard) }
    }

    /// Split out of `body`: one more closure there is too much for the type checker.
    private var dashboard: some View {
        DashboardView(model: model, onOpen: { model.selectedCardID = $0; go(to: .tasks) }, onApprove: { approveTapped($0) },
                      onStart: { startTapped($0) }, onApproveRound: { openApproveRound(stay: true) }, onOpenPlan: { go(to: .plan) },
                      onOpenTimeline: { go(to: .timeline) }, onOpenTerminals: { go(to: .terminals) },
                      onRequestFix: { model.clearActionState(); fixNotes = ""; fixCard = $0 }, onOpenStats: { go(to: .stats) })
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, screen: screen, inbox: model.topBarInbox(), autopilotLook: model.autopilot.isAvailable ? AutopilotIcon.look(model.autopilot) : nil,
                   usage: model.planUsage, onPick: { pickProject($0) }, onAddProject: { addProject = model.makeAddProjectFlow() }, onEditProject: { openEditProject() },
                   onOpenStats: { if model.usageHold(forRole: nil) != nil { go(to: .settings); settingsFlow?.show(.usage as SettingsCategory) } else { go(to: .stats) } }, onOpenCodexStats: { go(to: .stats); statsModel?.focusCodex = true }, onApprove: { approveFromInbox() }, onOpenQuestion: { openQuestion($0) }, onOpenReady: { openReady($0) },
                   search: { commandRows($0) }, onCommand: { runCommand($0) }, waitingOnYou: blockedQuestions.count, withPM: model.inbox.withPM.count, onAnswer: { toggleBlockedCard() })
            Divider().overlay(Tok.line).modifier(SetupSheetModifier(model: model, onAddProject: { addProject = model.makeAddProjectFlow() }))
            HStack(spacing: 0) {
                Rail(screen: screen, unreadReply: unreadReply, terminalAsks: terminalAsks, notes: railNotes, onSelect: { go(to: $0) }).tutorialAnchor(.rail)
                Divider().overlay(Tok.line)
                if screen == .dashboard {
                    dashboard
                } else if screen == .terminals {
                    TerminalsView(model: model, onOpenCard: { model.selectedCardID = $0; go(to: .tasks) },
                                  onOpenChanges: { changesTabCardID = $0; model.selectedCardID = $0; go(to: .tasks) })
                        // The panes are read once at init: another project is another view, with its own saved panes.
                        .id(model.selectedProjectID)
                } else if screen == .timeline {
                    TimelineScreen(model: model, onOpen: { model.selectedCardID = $0; go(to: .tasks) })
                } else if screen == .team {
                    TeamView(model: model.team, activity: model.roleActivity, running: model.roleRunning, cards: model.selectedTaskCards, agents: rosterAgents)
                } else if screen == .plan {
                    PlanView(model: model, onOpen: { model.selectedCardID = $0; go(to: .tasks) }, onOpenChat: { go(to: .dashboard) })
                } else if screen == .git, let gitScreen {
                    GitView(model: model, git: gitScreen)
                } else if screen == .stats, let statsModel {
                    StatsView(stats: statsModel, onOpen: { model.selectedCardID = $0; go(to: .tasks) })
                } else if screen == .settings, let settingsFlow {
                    settingsScreen(settingsFlow)
                } else {
                    TaskListView(model: model, onPlanRound: { model.round.begin() }, onNewTask: { newTask = model.makeNewTaskFlow() },
                                 onAddProject: { addProject = model.makeAddProjectFlow() }, onOpenSetup: { model.setup.open() }, plan: $tasksPlan).frame(width: 440)
                    Divider().overlay(Tok.line)
                    detail
                }
            }
            .overlay { NotesOverlay(model: model, book: notesBook, mode: $notesMode, highlight: $noteFocus, onMakeTask: { makeTask(fromNote: $0) }) }
        }
        .overlayPreferenceValue(WaitingPillAnchorKey.self) { pill in blockedCard(pill: pill) }
        .modifier(TutorialShell(tutorial: tutorial, model: model, screen: screen, go: { go(to: $0) }))
        .background(Tok.bg)
        .modifier(ThemeScheme(theme: theme))
        .id(theme)
        // Not under XCTest: AppKit keeps the frame in the app's own defaults, which belong to the user.
        .background { if !snapshot && !PanelModel.runsUnderXCTest { WindowFrameAutosave(name: LayoutRestore.frameName) } }
        .sheet(item: $addProject) { flow in
            AddProjectSheet(flow: flow, onAdded: { project in
                let notice = flow.notice, startsPM = flow.startsPM, probe = flow.probe, publish = flow.publishRequest
                addProject = nil
                // The notice outlives the sheet: it goes to the window's message line.
                Task {
                    await model.projectAdded(project.id)
                    if let publish { await model.gitSetup.openPush(project, visibility: publish.visibility, owner: publish.owner) }
                    if startsPM { if let probe { await model.startPMWithOnboarding(probe: probe) } else { await model.startPM() } }
                    if let notice { model.setActionState(.failed(notice)) }
                }
            }, onCancel: { addProject = nil })
            .tutorialHost(tutorial, name: "addProject")
        }
        .modifier(GitSetupSheets(git: model.gitSetup))
        .sheet(item: $newTask) { flow in
            NewTaskSheet(flow: flow, onCreated: { id in newTask = nil; linkNote(to: id); Task { await model.reloadCards(); model.selectedCardID = id } },
                         onCancel: { newTask = nil; noteForTask = nil })
        }
        .sheet(item: $editProject) { flow in
            EditProjectSheet(flow: flow, onSaved: { _ in editProject = nil; Task { await model.projectsChanged() } },
                             onRemoved: { editProject = nil; Task { await model.projectsChanged() } }, onCancel: { editProject = nil })
        }
        .sheet(isPresented: Binding(get: { settingsFlow?.phase == .confirming }, set: { if !$0 { settingsFlow?.cancel() } })) {
            if let settingsFlow {
                UpdateStableSheet(flow: settingsFlow, onConfirm: { Task { await settingsFlow.confirm() } }, onCancel: { settingsFlow.cancel() })
            }
        }
        .sheet(item: $cleanup) { flow in CleanupSheet(flow: flow, onClose: { cleanup = nil }) }
        .sheet(isPresented: Binding(get: { model.round.showsSheet }, set: { if !$0 { model.round.cancel() } })) {
            RoundSheet(model: model.round, onClose: { model.round.cancel() })
        }
        .sheet(isPresented: Binding(get: { model.autopilot.rulesOpen }, set: { model.autopilot.rulesOpen = $0 })) {
            AutopilotRulesSheet(policy: model.autopilot.policy, permissionRules: model.autopilot.permissionRules, onRemoveRule: { model.autopilot.removeRule($0) }, costToday: model.autopilot.lastCostToday, startedToday: model.autopilot.authorityStartsToday(),
                                onResetCount: { model.autopilot.resetAuthorityCount() }, onSave: { model.autopilot.update($0); model.autopilot.rulesOpen = false }, onCancel: { model.autopilot.rulesOpen = false })
        }
        .confirmationDialog("Switch the PM autopilot to On?", isPresented: Binding(get: { model.autopilot.confirmingOn }, set: { if !$0 { model.autopilot.cancelOn() } }), titleVisibility: .visible) {
            Button("Switch to On", role: .destructive) { model.autopilot.confirmOn() }
            Button("Cancel", role: .cancel) { model.autopilot.cancelOn() }
        } message: {
            Text(AutopilotModel.onWarning)
        }
        // The Dashboard hosts its own question window; elsewhere the banner's Answer opens this one (N371).
        .sheet(isPresented: Binding(get: { screen != .dashboard && model.inbox.focus != nil }, set: { if !$0 { model.inbox.closeFocus() } })) { blockedQuestionSheet }
        .onAppear { SheetCloser.shared.closeAll = { closeAllSheets() }; prepare(screen) }
        .task(id: screen == .dashboard) { await followPMReplies() }
        .sheet(item: $pendingPlan) { plan in
            if let project = model.selectedProject {
                StartTaskSheet(plan: plan, project: project, state: model.actionState,
                               onConfirm: { Task { await model.confirmStart(plan); if case .done = model.actionState { pendingPlan = nil } } },
                               onGiveMyself: { Task { await model.confirmStart(plan, givingItMyself: true); if case .done = model.actionState { pendingPlan = nil } } },
                               onCancel: { model.clearActionState(); pendingPlan = nil })
            }
        }
        .confirmationDialog("Add the \"\(missingRole ?? "")\" role?", isPresented: Binding(get: { missingRole != nil }, set: { if !$0 { missingRole = nil } }), titleVisibility: .visible) {
            if let name = missingRole { Button("Add the \"\(name)\" role from its template") { addMissingRole(name) } }
            Button("Cancel", role: .cancel) { missingRole = nil }
        } message: {
            Text("It opens the Team screen with the template's form filled in for the shared library. You save it there.")
        }
        .sheet(item: $pendingApproval) { plan in
            ApproveSheet(plan: plan, state: model.actionState,
                         onConfirm: {
                             Task {
                                 await model.confirmApprove(plan)
                                 // Once the merge happened the card has left review: the sheet is done even if a later step failed
                                 // (its message stays in the command bar).
                                 if model.card(id: plan.card.id)?.status != .review { pendingApproval = nil }
                             }
                         },
                         onCancel: { model.clearActionState(); pendingApproval = nil })
        }
        .onChange(of: settingsFlow?.appearance) { _, next in if let next { theme = next } }
        .onChange(of: model.settings.scriptsDir) { _, _ in if let settingsFlow { settingsFlow.apply(model.settings); Task { await settingsFlow.load() } } }
        .onChange(of: pendingApproval) { _, plan in model.approvalSheetOpen = plan != nil || roundRows != nil }
        .onChange(of: roundRows == nil) { _, _ in model.approvalSheetOpen = pendingApproval != nil || roundRows != nil }
        .sheet(isPresented: Binding(get: { roundRows != nil }, set: { if !$0 && !roundRunning { roundRows = nil; roundResult = nil } })) {
            ApproveRoundSheet(rows: Binding(get: { roundRows ?? [] }, set: { roundRows = $0 }), result: roundResult, running: roundRunning,
                              onConfirm: {
                                  guard let rows = roundRows else { return }
                                  roundRunning = true
                                  Task {
                                      roundResult = await model.approveRound(rows)
                                      roundRunning = false
                                      // Merged cards have left review: only the cards that are still there stay listed.
                                      roundRows = roundRows?.filter { model.card(id: $0.id)?.status == .review }
                                  }
                              },
                              onClose: { roundRows = nil; roundResult = nil })
        }
        .onChange(of: model.terminalFocus) { _, request in
            if request != nil { go(to: .terminals) }
        }
        .onChange(of: model.approveSheetRequest) { _, id in
            guard let id else { return }
            model.approveSheetRequest = nil
            screen = .tasks
            if let card = model.card(id: id) { approveTapped(card) }
        }
        .alert(alertTitle, isPresented: Binding(get: { alertKind != nil }, set: { if !$0 { leavingTeamFor = nil; pendingProject = nil; closeCard = nil } })) {
            switch alertKind {
            case .leavingTeam?:
                Button("Discard changes", role: .destructive) { model.team.revertAll(); if let target = leavingTeamFor { prepare(target); screen = target }; leavingTeamFor = nil }
                Button("Keep editing", role: .cancel) { leavingTeamFor = nil }
            case .switchingProject?:
                Button("Discard changes", role: .destructive) { model.team.revertAll(); let id = pendingProject; pendingProject = nil; if let id { Task { await model.selectProject(id) } } }
                Button("Keep editing", role: .cancel) { pendingProject = nil }
            case .closeTask?:
                Button("Close task") { if let card = closeCard { Task { await model.closeTask(card) } }; closeCard = nil }
                Button("Cancel", role: .cancel) { closeCard = nil }
            case nil:
                EmptyView()
            }
        } message: {
            switch alertKind {
            case .leavingTeam?: Text("The role or chart on the Team screen has changes that are not saved.")
            case .switchingProject?: Text("The role or chart on the Team screen has changes that belong to the current project and are not saved.")
            case .closeTask?: Text("The agent or its worktree is gone. The task is marked cancelled; nothing is merged.")
            case nil: EmptyView()
            }
        }
        .sheet(item: $fixCard) { card in
            FixRequestSheet(card: card, notes: $fixNotes, state: model.actionState,
                            onSend: { Task { if await model.sendFixRequest(card, notes: fixNotes) { fixCard = nil; fixNotes = "" } } },
                            onCancel: { model.clearActionState(); fixCard = nil })
        }
    }
}

extension ShellView {
    /// The one question the window is asking right now (SwiftUI shows only one `.alert` per view).
    fileprivate var alertKind: ShellAlertKind? { shellAlertKind(leavingTeam: leavingTeamFor != nil, switchingProject: pendingProject != nil, closeTask: closeCard != nil) }
    fileprivate var alertTitle: String { alertKind == .closeTask ? "Close \(closeCard?.id ?? "")?" : "Discard your changes?" }

    fileprivate func settingsScreen(_ flow: SettingsFlow) -> some View {
        SettingsView(flow: flow, projects: model.projects, sleepGuard: model.sleepGuard, safePoint: model.safePoint, safePointReason: model.safePointReason,
                     onSafePoint: { model.safePoint = $0 },
                     usageGate: model.usageGate, usageGateReason: model.usageGateReason, onUsageGate: { model.usageGate = $0 },
                     onStartAnyway: model.usageGateReason == nil ? nil : { model.startAnyway() }, onUpdate: { flow.requestUpdate() },
                     onRelaunch: { relaunch(flow) },
                     onCleanup: model.settings.scriptsDir == nil ? nil : { cleanup = model.makeCleanupFlow(); if let cleanup { Task { await cleanup.scan() } } },
                     onSetup: { model.setup.open() },
                     onChooseScripts: { chooseScripts() }, notificationsOn: model.notificationsEnabled,
                     onNotifications: { on in Task { await model.setNotifications(on) } },
                     notificationPrefs: model.notificationPrefs,
                     onNotificationEvent: { model.setNotificationEvent($0, $1) }, onNotificationSound: { model.setNotificationSound($0) },
                     onEventSound: { model.setNotificationSound($1, for: $0) }, onDockBadge: { model.setDockBadge($0) }, onDockBounce: { model.setDockBounce($0) },
                     onAddProject: model.settings.scriptsDir == nil ? nil : { addProject = model.makeAddProjectFlow() },
                     onEditProject: { id in Task { await model.selectProject(id); openEditProject() } },
                     onOpenTeam: { go(to: .team) },
                     planUsage: model.planUsage, workingAgents: workingAgents, setup: model.setup,
                     leftoverScan: { guard let flow = model.makeCleanupFlow() else { return nil }; await flow.scan(); return flow.items.count })
    }

    /// Agents working now, as Keep awake counts them (the user's own shells left out).
    fileprivate var workingAgents: Int {
        guard case .available(let list) = model.agents else { return 0 }
        return TerminalShells.withoutUserShells(list).filter { $0.state == .working }.count
    }

    /// Settings → Choose…: validates and saves `scriptsDir`, then rebuilds the Settings screen so it shows the new folder.
    fileprivate func chooseScripts() {
        Task {
            await model.setup.chooseScripts()
            settingsFlow = model.makeSettingsFlow()
        }
    }

    /// The PM's reply arriving while the Dashboard is not shown: the Dashboard's chat is not on screen to read it, so it is read here.
    fileprivate var unreadReply: Bool { model.selectedProjectID.map { model.chats.unread(project: $0) } ?? false }

    /// The rail's Terminals dot: an agent of the selected project asks the user something.
    fileprivate var terminalAsks: Bool { !model.autopilot.forUser(model.inbox.questions).isEmpty }

    fileprivate func followPMReplies() async {
        if snapshot { return }
        while !Task.isCancelled, screen != .dashboard {
            if let id = model.selectedProjectID, let pm = model.pmAgent(forProject: id), let session = model.chats.existingSession(project: id, pane: pm.paneID) {
                await session.chat.refresh(agent: pm, viewing: false)
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    /// The rail's notes icon: the selected project's open lines; it opens and closes the pad without changing the screen.
    fileprivate var railNotes: RailNotes? {
        guard let project = model.selectedProject else { return nil }
        return RailNotes(open: notesBook.notes(dataDir: project.dataURL).openCount, active: notesMode != .closed, onTap: { notesMode = notesMode.railTapped() })
    }

    /// "Make a task…" on a note: the New task sheet with the line as its title; the line shows the card's id once it is made.
    fileprivate func makeTask(fromNote text: String) {
        guard let project = model.selectedProject, let flow = model.makeNewTaskFlow() else { return }
        flow.title = text
        noteForTask = (project.dataURL, text)
        newTask = flow
    }

    fileprivate func linkNote(to card: String) {
        if let note = noteForTask { notesBook.notes(dataDir: note.dataDir).linkTask(text: note.text, to: card) }
        noteForTask = nil
    }

    /// The agents at work in the selected project, for the Team screen's Roster.
    private var rosterAgents: [RosterAgent] {
        guard let project = model.selectedProject, case .available(let list) = model.agents else { return [] }
        return TeamRoster.agents(list, cards: model.selectedTaskCards, worktrees: project.worktreesURL, pm: model.pmAgent(forProject: project.id))
    }

    /// The ⌘K field's results: the selected project's cards and notes, the screens and the projects, as the window holds them.
    fileprivate func commandRows(_ query: String) -> [CommandSearch.Row] {
        let project = model.selectedProject
        let notes = project.map { notesBook.notes(dataDir: $0.dataURL).days.flatMap(\.lines).map { CommandSearch.Note(id: $0.id, text: $0.text, done: $0.done) } } ?? []
        let hasPM = model.selectedProjectID.flatMap { model.pmAgent(forProject: $0) } != nil
        return CommandSearch.rows(query: query, cards: model.selectedTaskCards, projects: model.projects.map { CommandSearch.Project(id: $0.id, name: $0.name) },
                                  selectedProject: model.selectedProjectID, notes: notes, tours: commandTours, pmMissing: hasPM ? nil : CommandSearch.pmMissingReason(project: project?.name))
    }

    /// ⌘K's tour rows (N311): this screen's tour and the one in progress.
    private var commandTours: CommandSearch.Tours {
        let resume = tutorial.resumable.map { id in (id: id, step: tutorial.progress(id).step + 1, of: id.tour.steps.count) }
        return CommandSearch.Tours(here: tutorial.tourHere, screen: screen.railTitle, resume: resume)
    }

    fileprivate func runCommand(_ target: CommandSearch.Target) {
        switch target {
        case .card(let id): model.selectedCardID = id; go(to: .tasks)
        case .screen(let target): go(to: target)
        case .project(let id): if id != model.selectedProjectID { pickProject(id) }
        case .note(let id):
            // A done line may be folded away: the pad shows the done lines so the found one is there.
            if let project = model.selectedProject {
                let notes = notesBook.notes(dataDir: project.dataURL)
                if notes.days.flatMap(\.lines).first(where: { $0.id == id })?.done == true { notes.showDone = true }
            }
            noteFocus = id
            notesMode = .open
        case .askPM(let text):
            guard let id = model.selectedProjectID, let pm = model.pmAgent(forProject: id) else { return }
            CommandBar.holdForPM(text, agent: pm, project: id, model: model)
            go(to: .dashboard)
        case .tour(let id): tutorial.open(id)
        case .allTours: tutorial.popoverOpen = true
        }
    }

    fileprivate func openEditProject() {
        if let flow = model.makeEditProjectFlow() { editProject = flow }
        else if let why = EditProjectFlow.unavailableReason(project: model.selectedProject, scriptsDir: model.settings.scriptsDir) { model.setActionState(.failed(why)) }
    }

    fileprivate func pickProject(_ id: String) {
        if projectSwitchNeedsConfirmation(screen: screen, teamIsDirty: model.team.hasUnsavedChanges) { pendingProject = id }
        else { Task { await model.selectProject(id) } }
    }

    /// "Relaunch now": closes every open sheet (one could block quitting), starts the relaunch script and quits.
    fileprivate func relaunch(_ flow: SettingsFlow) {
        flow.relaunch(closeSheets: { closeAllSheets() }, quit: { NSApplication.shared.terminate(nil) })
    }

    /// ⌘Q and Relaunch: nothing stays open that could hold the app back.
    fileprivate func closeAllSheets() {
        for sheet in PanelSheet.allCases { close(sheet) }
    }

    fileprivate func close(_ sheet: PanelSheet) {
        switch sheet {
        case .startPlan: pendingPlan = nil
        case .approve: pendingApproval = nil
        case .approveRound: if !roundRunning { roundRows = nil; roundResult = nil }
        case .fixRequest: fixCard = nil
        case .closeTask: closeCard = nil
        case .leavingTeam: leavingTeamFor = nil
        case .switchingProject: pendingProject = nil
        case .missingRole: missingRole = nil
        case .addProject: addProject = nil
        case .editProject: editProject = nil
        case .newTask: newTask = nil
        case .updateStable: settingsFlow?.cancel()
        case .cleanup: cleanup = nil
        case .round: model.round.forceClose()
        case .autopilotRules: model.autopilot.rulesOpen = false
        case .autopilotOn: model.autopilot.cancelOn()
        case .roleTemplate: model.team.templateLocation = nil
        case .setup: model.setup.close()
        case .gitInit: if model.gitSetup.initSheet?.phase != .running { model.gitSetup.initSheet = nil }
        case .gitPush: model.gitSetup.pushSheet = nil
        case .questionFocus: model.inbox.closeFocus()
        }
    }

    fileprivate func go(to target: ShellScreen) {
        switch screenChange(from: screen, to: target, teamIsDirty: model.team.hasUnsavedChanges) {
        case .go:
            prepare(target)
            screen = target
        case .askFirst: leavingTeamFor = target
        }
    }

    /// Settings, Stats and Git build their model on first use (also when the window reopens on one of them).
    fileprivate func prepare(_ target: ShellScreen) {
        if target == .settings, settingsFlow == nil { settingsFlow = model.makeSettingsFlow() }
        if target == .git, gitScreen == nil { gitScreen = GitScreenModel(reader: PanelModel.runsUnderXCTest ? nil : GitDetailsReader(runner: ProcessToolRunner(timeout: 60))) }
        if target == .stats { if statsModel == nil { statsModel = StatsModel(model: model) } }
    }

    fileprivate func startTapped(_ card: TaskCard) {
        switch model.startPlan(for: card) {
        case .success(let plan): model.clearActionState(); pendingPlan = plan
        case .failure(let error):
            model.setActionState(.failed(error.message))
            if case .missingRole(let name, _, _) = error { missingRole = name }
        }
    }

    fileprivate func addMissingRole(_ name: String) {
        missingRole = nil
        if model.team.addRoleFromTemplate(named: name) == .needsConfirmation {
            model.setActionState(.failed("The Team screen has unsaved changes. Save or discard them, then add the \"\(name)\" role."))
        }
        go(to: .team)
    }

    // MARK: the question card (N371, floating since N376)

    /// The open project's agent questions for the user, oldest first.
    fileprivate var blockedQuestions: [PendingQuestion] {
        BlockedBanner.oldestFirst(model.autopilot.forUser(model.inbox.questions), askedAt: model.inbox.askedAt, now: Date())
    }

    /// The card as it stands now (nil: hidden).
    fileprivate func blockedCardContent() -> BlockedBanner.Content? {
        let tile = screen == .dashboard && DashboardLayoutStore().load().widgets.contains(.waiting)
        return blockedBannerModel.content(questions: blockedQuestions, askedAt: model.inbox.askedAt, onDashboard: screen == .dashboard, waitingTileShown: tile,
                                          role: { model.questionRole($0) }, suggestion: { model.autopilot.suggestion(for: $0) }, held: model.inbox.heldRows)
    }

    /// The floating question card (N376) under the waiting pill, over the content: nothing moves when it comes or goes. Re-read every
    /// 30 s: the minutes waited, Later running out and the Dashboard's tiles (kept by the Dashboard) follow.
    fileprivate func blockedCard(pill: Anchor<CGRect>?) -> some View {
        GeometryReader { g in
            SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { _ in
                let content = blockedCardContent()
                let pillRect = pill.map { g[$0] }
                let width = BlockedBanner.cardWidth
                // Right edge under the pill's right edge, kept inside the window; the notch points at the pill's middle.
                let right = min(pillRect?.maxX ?? g.size.width - Tok.Space.l, g.size.width - Tok.Space.l)
                let left = max(right - width, Tok.Space.l)
                ZStack(alignment: .topLeading) {
                    if let content {
                        BlockedBannerView(content: content, notchX: pillRect.map { min(max($0.midX - left, 20), width - 20) },
                                          onAnswer: { answerOldest() }, onLater: { blockedBannerModel.later(open: blockedQuestions.map(\.id)) },
                                          onLetPMDecide: blockedQuestions.first.flatMap { q in letPMDecideAction(q) },
                                          role: { model.questionRole($0) }, onAnswerMyself: { model.inbox.answerMyself($0) })
                        .offset(x: left, y: TopBarLayout.height + BlockedBanner.cardGap)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                        .id(content.questionID)
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2), value: content?.questionID)
                .animation(.easeOut(duration: 0.2), value: content?.held.map(\.id))
                .modifier(BlockedCardEscape(active: content != nil && !snapshot) { blockedBannerModel.close(open: blockedQuestions.map(\.id)) })
            }
        }
    }

    /// The pill: opens or closes the card.
    fileprivate func toggleBlockedCard() {
        blockedBannerModel.togglePill(shown: blockedCardContent() != nil, open: blockedQuestions.map(\.id))
    }

    /// Answer: the question window on the oldest question; its ‹ › go through the others.
    fileprivate func answerOldest() {
        let questions = blockedQuestions
        guard let first = questions.first else { return }
        model.inbox.openFocus(first, in: questions)
    }

    /// "Let the PM decide": the question goes to the PM's chat, as the Dashboard's focus card sends it. Nil when no PM can take it.
    fileprivate func letPMDecideAction(_ q: PendingQuestion) -> (() -> Void)? {
        guard !q.isPM, let project = model.selectedProjectID, let pane = model.pmPane(forProject: project),
              QuestionRelay.relayable(q, routing: model.inbox.routing) else { return nil }
        return { Task { await model.tellPM(pane: pane, passOnToPMText(q)) } }
    }

    /// The question window off the Dashboard, with the same pieces as the Dashboard's.
    fileprivate var blockedQuestionSheet: some View {
        let inbox = model.inbox
        let pm = model.selectedProjectID.flatMap { model.pmPane(forProject: $0) }
        let window = NSApp.mainWindow?.contentLayoutRect.height ?? QuestionFocusSheet.height
        return QuestionFocusSheet(inbox: inbox, questions: blockedQuestions,
                                  suggestion: { model.autopilot.suggestion(for: $0) }, escalation: { model.autopilot.escalation(for: $0) },
                                  cardTitle: { model.card(id: $0)?.title },
                                  waited: { q in inbox.askedAt[q.id].map { Stats.durationText(max(Date().timeIntervalSince($0), 0)) } },
                                  onPassOn: pm.map { pane in { q in Task { await model.tellPM(pane: pane, passOnToPMText(q)) } } },
                                  onAlwaysAllow: model.autopilot.isAvailable ? { q in Task { _ = await model.autopilot.alwaysAllow(q) } } : nil,
                                  maxHeight: window - 40)
    }

    /// The Inbox's Approve: one card opens its Approve sheet, several the Approve round sheet.
    fileprivate func approveFromInbox() {
        let ready = model.approveRoundCards
        if ready.count == 1, let card = ready.first { approveTapped(card) } else { openApproveRound() }
    }

    /// A question in the Inbox: its project, its card, and the Dashboard where questions are answered.
    fileprivate func openQuestion(_ q: TopBarInbox.Question) {
        if q.projectID != model.selectedProjectID, projectSwitchNeedsConfirmation(screen: screen, teamIsDirty: model.team.hasUnsavedChanges) {
            pendingProject = q.projectID
            return
        }
        Task {
            if q.projectID != model.selectedProjectID { await model.selectProject(q.projectID) }
            if let card = q.cardID { model.selectedCardID = card }
        }
        go(to: .dashboard)
    }

    /// A card waiting for approval in another project: that project, the card, and the Tasks screen where it is approved.
    fileprivate func openReady(_ r: TopBarInbox.Ready) {
        guard let project = r.projectID else { return }
        if project != model.selectedProjectID, projectSwitchNeedsConfirmation(screen: screen, teamIsDirty: model.team.hasUnsavedChanges) {
            pendingProject = project
            return
        }
        Task {
            if project != model.selectedProjectID { await model.selectProject(project) }
            model.selectedCardID = r.cardID
        }
        go(to: .tasks)
    }

    /// `stay`: opened from the Dashboard, which lists the cards itself; the top bar's button shows them on the Tasks screen.
    fileprivate func openApproveRound(stay: Bool = false) {
        Task {
            if !stay { screen = .tasks }
            let rows = await model.approveRoundRows()
            if rows.count > 1 { model.clearActionState(); roundResult = nil; roundRows = rows }
        }
    }

    fileprivate func approveTapped(_ card: TaskCard) {
        Task {
            switch await model.approvalPlan(for: card) {
            case .success(let plan): model.clearActionState(); pendingApproval = plan
            case .failure(let error):
                model.setActionState(.failed(error.message))
                // The main branch moved on: one click from the fix request that asks the agent to rebase.
                if error == .notFastForward, let base = model.selectedProject?.baseBranch { fixNotes = rebaseRequestText(base: base); fixCard = card }
            }
        }
    }

    /// Whether the agent's worktree folder is still there (the "Close task" button is offered when it is not).
    fileprivate func worktreeExists(_ card: TaskCard, _ project: ProjectConfig) -> Bool {
        guard let branch = card.branch, TaskInput.validBranch(branch) else { return false }
        return FileManager.default.fileExists(atPath: project.worktreesURL.appendingPathComponent(StartTaskFlow.worktreeFolder(for: branch)).path)
    }

    /// The tab the card was left on when the app last ran (N260), while the card can still show it.
    fileprivate func restoredTab(_ card: TaskCard, _ project: ProjectConfig) -> TaskDetailView.Tab? {
        return model.savedTab(for: card, shots: ShotItem.items(for: card, dataDir: project.dataURL).count)
    }

    @ViewBuilder fileprivate var detail: some View {
        if let card = model.selectedCard, let project = model.selectedProject {
            TaskDetailView(card: card,
                           shots: ShotItem.items(for: card, dataDir: project.dataURL),
                           opener: model.workspaceOpener,
                           phase: model.phase(of: card),
                           agentTag: AgentTagInfo.make(card, displayNames: model.roleDisplayNames, phase: model.phase(of: card)),
                           busyMessage: { if case .running(let m) = model.actionState { return m } else { return nil } }(),
                           startState: startButtonState(card: card, canStart: model.startDisabledReason(for: card) == nil, reason: model.startDisabledReason(for: card), busy: model.isBusy,
                                                   dependencies: model.dependencyGraph.state(of: card.id)),
                           reviewState: reviewButtonStates(card: card, canAct: model.reviewDisabledReason == nil, reason: model.reviewDisabledReason,
                                           worktreeExists: worktreeExists(card, project), busy: model.isBusy,
                                           agentWorking: model.phase(of: card) == .working),
                           onStart: { startTapped(card) },
                           resumeState: model.resumeState(for: card),
                           onResume: { Task { await model.resumeAgent(card) } },
                           onPrepare: { Task { await model.prepareReview(card) } },
                           onApprove: { approveTapped(card) },
                           onRequestFix: { model.clearActionState(); fixNotes = ""; fixCard = card },
                           onClose: { closeCard = card },
                           onEdit: { newTask = model.makeEditFlow(card) },
                           logEvents: { model.actionLogEvents() },
                           agentPane: model.agentPane(of: card),
                           onOpenTerminal: { model.openTerminalTab($0) },
                           decisions: { model.autopilot.allDecisions() },
                           roundName: tasksPlan?.rounds.first { $0.cards.contains(card.id) }?.name,
                           agentFacts: model.configuredAgentFacts(card),
                           loadAgentFacts: { await model.agentFacts(for: card) },
                           startTab: changesTabCardID == card.id ? .changes : restoredTab(card, project) ?? openingTab(card: card),
                           diffComments: model.diffComments,
                           onSendDiffComments: { await model.sendFixRequest(card, notes: $0) },
                           onTab: { model.saveOpenTab($0, card: card.id) })
                .id(card.id)
        } else {
            Tok.bg.overlay { Text("Select a task").font(Tok.Font.body).foregroundStyle(Tok.ink3) }
        }
    }
}

/// The top bar's widths: the middle column is kept for the command field; a narrow window drops the screen from the path.
/// SwiftUI's colour scheme for a chosen theme, so assets with a dark variant (the wordmark) pick the same side as `NSApp.appearance`,
/// also where there is no window (snapshots). System keeps the window's own scheme.
struct ThemeScheme: ViewModifier {
    let theme: AppTheme
    @Environment(\.colorScheme) private var windowScheme

    static func scheme(_ theme: AppTheme, window: ColorScheme) -> ColorScheme {
        switch theme {
        case .system: window
        case .light: .light
        case .dark, .midnight: .dark
        }
    }

    func body(content: Content) -> some View { content.environment(\.colorScheme, Self.scheme(theme, window: windowScheme)) }
}

struct TopBarLayout: Equatable {
    static let height: CGFloat = 52
    static let narrowBelow: CGFloat = 1200
    /// The main window's minimum width (`AgentPanelApp`).
    static let narrowestWindow: CGFloat = 1100
    /// The ⌘K field gives way first, down to this width (N388); only then does the right group step down.
    static let fieldMin: CGFloat = 160
    static let spacing: CGFloat = Tok.Space.l
    static let padding: CGFloat = Tok.Space.l
    let width: CGFloat

    var narrow: Bool { width < Self.narrowBelow }
    var middle: CGFloat { narrow ? 240 : 520 }
    func screenTitle(_ screen: ShellScreen) -> String? { narrow ? nil : screen.railTitle }
    static func otherProjectsBadge(_ count: Int) -> String? { count > 0 ? "\(count)" : nil }

    /// What the right group may take: the bar less the path, the field at its smallest and the gaps.
    func rightRoom(left: CGFloat) -> CGFloat { max(0, width - 2 * Self.padding - left - Self.fieldMin - 2 * Self.spacing) }

    /// The first step of the right group that fits its room, else the last (as `ViewThatFits` picks).
    static func step(_ widths: [CGFloat], room: CGFloat) -> Int { widths.firstIndex { $0 <= room } ?? max(widths.count - 1, 0) }

    struct Frames: Equatable { let left: CGRect; let field: CGRect; let right: CGRect }

    /// The path at the left edge, the right group at the right edge, and the ⌘K field centred in the bar as far as the space between
    /// them allows, never wider than `middle` and never over either side (N388).
    func frames(left: CGFloat, right: CGFloat) -> Frames {
        let h = Self.height, lo = Self.padding, hi = width - Self.padding
        let rightX = max(lo, hi - right)
        let leftW = min(left, max(0, rightX - Self.spacing - lo))
        let gapLo = lo + leftW + Self.spacing, gapHi = rightX - Self.spacing
        let fieldW = max(0, min(middle, gapHi - gapLo))
        let fieldX = min(max((width - fieldW) / 2, gapLo), gapHi - fieldW)
        return Frames(left: CGRect(x: lo, y: 0, width: leftW, height: h), field: CGRect(x: fieldX, y: 0, width: fieldW, height: h),
                      right: CGRect(x: rightX, y: 0, width: hi - rightX, height: h))
    }
}

/// The bar's three parts placed by `TopBarLayout.frames`: the path, the ⌘K field and the right group (a `ViewThatFits` of `TopBarStep`s).
struct TopBarRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? TopBarLayout.narrowestWindow, height: proposal.height ?? TopBarLayout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let layout = TopBarLayout(width: bounds.width)
        let left = subviews[0].sizeThatFits(.unspecified).width
        let right = subviews[2].sizeThatFits(ProposedViewSize(width: layout.rightRoom(left: left), height: bounds.height)).width
        let f = layout.frames(left: left, right: right)
        for (view, rect) in zip(subviews, [f.left, f.field, f.right]) {
            view.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: rect.width, height: bounds.height))
        }
    }
}

/// How far the right group has stepped down for room (N388), most room first: the pill goes compact, the plan names go, the
/// "with PM" part keeps only its number, the percents go. The Inbox, the waiting count and the rings always show.
enum TopBarStep: Int, CaseIterable {
    case full, compactPill, noRingNames, compactHeld, noPercents

    var compactPill: Bool { self.rawValue >= Self.compactPill.rawValue }
    var ringNames: Bool { self.rawValue < Self.noRingNames.rawValue }
    var compactHeld: Bool { self.rawValue >= Self.compactHeld.rawValue }
    var ringPercents: Bool { self.rawValue < Self.noPercents.rawValue }
}

/// `tentacl / project ▾ / screen` on the left, the ⌘K field in the middle (N134), the usage ring, autopilot, coffee and the Inbox on the right
/// (design B, N133).
struct TopBar: View {
    @Bindable var model: PanelModel
    let screen: ShellScreen
    let inbox: TopBarInbox.Content
    let autopilotLook: AutopilotIcon.Look?
    let usage: PlanUsage?
    @State var inboxOpen = false
    /// What is typed in the ⌘K field.
    @State var query = ""
    var onPick: (String) -> Void = { _ in }
    var onAddProject: () -> Void = {}
    var onEditProject: () -> Void = {}
    var onOpenStats: () -> Void = {}
    var onOpenCodexStats: () -> Void = {}
    var onApprove: () -> Void = {}
    var onOpenQuestion: (TopBarInbox.Question) -> Void = { _ in }
    var onOpenReady: (TopBarInbox.Ready) -> Void = { _ in }
    /// The ⌘K field's results for what is typed (see `CommandSearch`), and what a picked row does.
    var search: (String) -> [CommandSearch.Row] = { _ in [] }
    var onCommand: (CommandSearch.Target) -> Void = { _ in }
    /// The open project's agents stopped on a question for the user (N371): the pill next to Inbox, and what its click does (N376: the card opens or closes).
    var waitingOnYou = 0
    /// Its questions the PM is answering (N380): a muted "1 with PM" on the pill, not counted as waiting on the user.
    var withPM = 0
    var onAnswer: () -> Void = {}
    @Environment(\.snapshotMode) private var snapshot
    @Environment(TutorialModel.self) private var tutorial: TutorialModel?

    var body: some View {
        GeometryReader { g in
            let layout = TopBarLayout(width: g.size.width)
            TopBarRow {
                path(layout)
                CommandField(query: $query, search: search, onRun: onCommand)
                right
            }
        }
        .frame(height: TopBarLayout.height)
        .background(Tok.rail)
        .overlay(alignment: .topTrailing) {
            // ImageRenderer cannot draw a popover: a snapshot shows the open Inbox where the popover would be.
            if snapshot && inboxOpen { panel.clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
                .offset(x: -Tok.Space.l, y: TopBarLayout.height + Tok.Space.s) }
        }
        .zIndex(1)
    }

    func path(_ layout: TopBarLayout) -> some View {
        HStack(spacing: Tok.Space.m) {
            Image("Wordmark").resizable().scaledToFit().frame(height: 28).accessibilityLabel("Tentacl Crew")
            Rectangle().fill(Tok.line).frame(width: 1, height: 20).accessibilityHidden(true)
            if !model.projects.isEmpty {
                ProjectPicker(model: model, badge: TopBarLayout.otherProjectsBadge(model.waitingInOtherProjects), onPick: onPick, onAddProject: onAddProject, onEditProject: onEditProject)
                    .tutorialAnchor(.projectPicker)
            } else {
                Button("Add project", action: onAddProject).buttonStyle(PanelButtonStyle()).disabled(model.settings.scriptsDir == nil).help(model.settings.scriptsDir == nil ? "Set scriptsDir in the settings file first." : "Create a project or add one from disk")
                    .tutorialAnchor(.addProject)
            }
            if let title = layout.screenTitle(screen) {
                slash
                Text(title).font(Tok.Font.body).foregroundStyle(Tok.ink2).lineLimit(1)
            }
        }
    }

    private var slash: some View { Text("/").font(.system(size: 18)).foregroundStyle(Tok.ink3.opacity(0.6)).accessibilityHidden(true) }

    /// The right group at the first step that fits its room (N371, N388).
    private var right: some View {
        ViewThatFits(in: .horizontal) { ForEach(TopBarStep.allCases, id: \.self) { rightRow($0, tutorial: tutorial) } }
    }

    func rightRow(_ step: TopBarStep, tutorial: TutorialModel?) -> some View {
        HStack(spacing: Tok.Space.m) {
            TopBarExtras(guardModel: model.sleepGuard, usage: usage, codexUsage: model.shownCodexUsage, autopilot: model.autopilot, autopilotLook: autopilotLook,
                         ringNames: step.ringNames, ringPercents: step.ringPercents, onOpenStats: onOpenStats, onOpenCodexStats: onOpenCodexStats)
            if let tutorial { TutorialButton(model: tutorial, screen: screen, hasProjects: !model.projects.isEmpty) }
            WaitingOnYouPill(count: waitingOnYou, withPM: withPM, compact: step.compactPill, compactHeld: step.compactHeld, action: onAnswer)
            InboxButton(count: inbox.count) { inboxOpen.toggle() }
                .tutorialAnchor(.inbox)
                .popover(isPresented: Binding(get: { inboxOpen && !snapshot }, set: { inboxOpen = $0 }), arrowEdge: .bottom) {
                    panel.onExitCommand { inboxOpen = false }
                }
        }
        .fixedSize()
    }

    private var panel: some View {
        InboxPanel(content: inbox, busy: model.isBusy,
                   onOpen: { q in inboxOpen = false; onOpenQuestion(q) },
                   onOpenReady: { r in inboxOpen = false; onOpenReady(r) },
                   onApprove: { inboxOpen = false; onApprove() },
                   onAnswerMyself: { item in model.watches[item.projectID]?.inbox.answerMyself(item.questionID) })
    }
}

/// Sizes of the things the user clicks in the rail and the detail tabs (kept as constants so a test can hold them above the minimum).
enum ClickTargets {
    static let railWidth: CGFloat = 64
    static let railItem = CGSize(width: 64, height: 48)
    static let tabHeight: CGFloat = 32
}

extension ShellScreen {
    /// The rail's items from top to bottom; ⌘1…⌘9 pick them in this order. Terminals and the Timeline follow Tasks: they follow the work,
    /// while Team, Plan, Git, Stats and Settings below them set it up or look back on it.
    static let railOrder: [ShellScreen] = [.dashboard, .tasks, .terminals, .timeline, .team, .plan, .git, .stats, .settings]

    var railTitle: String {
        switch self {
        case .dashboard: "Dashboard"
        case .tasks: "Tasks"
        case .terminals: "Terminals"
        case .timeline: "Timeline"
        case .team: "Team"
        case .plan: "Plan"
        case .git: "Git"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }

    var railSymbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .tasks: "checklist"
        case .terminals: "terminal"
        case .timeline: "calendar.day.timeline.left"
        case .team: "person.2"
        case .plan: "book.closed"
        case .git: "arrow.triangle.branch"
        case .stats: "chart.bar"
        case .settings: "gearshape"
        }
    }

    /// The rail's dot: the Dashboard's chat has a PM reply the user has not seen, or (Terminals, orange) a terminal asks something.
    func railDot(current: ShellScreen, unreadReply: Bool, terminalAsks: Bool = false) -> Bool {
        (self == .dashboard && current != .dashboard && unreadReply) || (self == .terminals && terminalAsks)
    }

    /// On the Terminals screen ⌘1…⌘9 pick a terminal tab, so the rail's own digits are off there.
    static func railShortcutsActive(on current: ShellScreen) -> Bool { current != .terminals }

    var shortcutDigit: Int { (Self.railOrder.firstIndex(of: self) ?? 0) + 1 }
    var railHelp: String { "\(railTitle) (⌘\(shortcutDigit))" }

    init?(shortcutDigit: Int) {
        guard shortcutDigit >= 1, shortcutDigit <= Self.railOrder.count else { return nil }
        self = Self.railOrder[shortcutDigit - 1]
    }
}

struct Rail: View {
    let screen: ShellScreen
    var unreadReply = false
    var terminalAsks = false
    /// The notes icon at the bottom, apart from the screens (nil without a project).
    var notes: RailNotes?
    let onSelect: (ShellScreen) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ShellScreen.railOrder, id: \.self) { item($0) }
            Spacer()
            if let notes { RailNotesButton(notes: notes) }
        }
        .padding(.vertical, 8)
        .frame(width: ClickTargets.railWidth)
        .background(Tok.rail)
    }

    private func item(_ target: ShellScreen) -> some View {
        RailItem(screen: target, selected: screen == target, dot: target.railDot(current: screen, unreadReply: unreadReply, terminalAsks: terminalAsks),
                 shortcut: ShellScreen.railShortcutsActive(on: screen), onSelect: { onSelect(target) })
    }
}

private struct RailItem: View {
    let screen: ShellScreen
    let selected: Bool
    var dot = false
    var shortcut = true
    let onSelect: () -> Void
    @State private var hovering = false

    private var dotHelp: String { screen == .terminals ? "A terminal asks you something" : "New reply from the PM" }

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: screen.railSymbol).font(.system(size: 17)).foregroundStyle(selected || hovering ? Tok.ink : Tok.ink3)
                .frame(maxWidth: .infinity, minHeight: ClickTargets.railItem.height, maxHeight: ClickTargets.railItem.height)
                .background(selected ? Tok.raise : (hovering ? Tok.raise.opacity(0.5) : .clear), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topTrailing) {
                    if dot { Circle().fill(screen == .terminals ? Tok.ask : Tok.work).frame(width: 7, height: 7).padding(Tok.Space.s).accessibilityLabel(dotHelp) }
                }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, (ClickTargets.railWidth - ClickTargets.railItem.width) / 2 + 4)
        .onHover { hovering = $0 }
        .keyboardShortcut(shortcut ? KeyboardShortcut(KeyEquivalent(Character("\(screen.shortcutDigit)")), modifiers: .command) : nil)
        .help(dot ? "\(screen.railHelp) · \(screen == .terminals ? "a terminal asks you something" : "new reply from the PM")" : screen.railHelp)
        .accessibilityLabel(screen.railTitle)
    }
}

/// The project switcher.
private struct ProjectPicker: View {
    @Bindable var model: PanelModel
    /// What waits in the other projects; nil hides the badge.
    var badge: String?
    let onPick: (String) -> Void
    let onAddProject: () -> Void
    let onEditProject: () -> Void
    @State private var reordering = false

    var body: some View {
        MenuBox {
            ForEach(model.projects) { project in
                let waiting = model.waitingCount(forProject: project.id)
                Button(waiting > 0 ? "\(project.name) · \(waiting) waiting" : project.name) { onPick(project.id) }
            }
            Divider()
            Button("Add project…", action: onAddProject).disabled(model.settings.scriptsDir == nil)
            Button("Edit project…", action: onEditProject)
            Button("Reorder projects…") { reordering = true }.disabled(model.projects.count < 2)
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedProject?.name ?? "").font(Tok.Font.body.weight(.semibold)).foregroundStyle(Tok.ink).lineLimit(1)
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(Tok.ask)
                        .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                        .background(Tok.line, in: Capsule())
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Tok.ink3)
            }
            .padding(.horizontal, Tok.Space.s).frame(height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .fixedSize()
        .help(badge.map { "\($0) waiting in other projects" } ?? "Switch project")
        .accessibilityLabel("Project")
        .accessibilityValue([model.selectedProject?.name, badge.map { "\($0) waiting in other projects" }].compactMap { $0 }.joined(separator: ", "))
        .popover(isPresented: $reordering, arrowEdge: .bottom) { ProjectOrderList(model: model) }
    }
}

/// Presents the first-run guide (kept out of ShellView's long modifier chain, which the compiler cannot type-check in time).
private struct SetupSheetModifier: ViewModifier {
    let model: PanelModel
    let onAddProject: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { model.setup.isOpen }, set: { if $0 { model.setup.isOpen = true } else { model.setup.close() } })) {
            SetupView(model: model.setup, onClose: { model.setup.close() },
                      onAddProject: { if model.setup.close() { onAddProject() } },
                      onSignIn: { tool in Task { await model.signIn(tool) } })
        }
    }
}

/// The tours in the window (N311): the overlay, the first-visit nudge under the top bar, the reset question, and the model's view of
/// the window (its screen, whether there is a project, how to change screens). Kept out of ShellView's long body.
private struct TutorialShell: ViewModifier {
    let tutorial: TutorialModel
    let model: PanelModel
    let screen: ShellScreen
    let go: (ShellScreen) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if tutorial.nudge == screen, tutorial.active == nil {
                    TutorialNudge(model: tutorial, screen: screen).padding(.top, TopBarLayout.height + 1)
                }
            }
            .tutorialHost(tutorial, name: TutorialOverlay.windowHost)
            .environment(tutorial)
            .onAppear {
                tutorial.navigate = go
                tutorial.hasProjects = !model.projects.isEmpty
                tutorial.screenChanged(to: screen)
            }
            .onChange(of: model.projects.isEmpty) { _, empty in tutorial.hasProjects = !empty }
            // The welcome waits for Setup to close (spec T0).
            .onChange(of: model.setup.isOpen) { _, open in
                if !open { tutorial.offerFirstLaunch(noProjects: model.projects.isEmpty, sheetOpen: false) }
            }
            .confirmationDialog("Reset all tours?", isPresented: Binding(get: { tutorial.confirmingReset }, set: { tutorial.confirmingReset = $0 })) {
                Button("Reset tours", role: .destructive) { tutorial.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every tour starts again from step 1 and the first-visit hints come back. Other settings stay.")
            }
    }
}
