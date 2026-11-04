import SwiftUI

/// The Settings screen (the gear in the rail): a sidebar of categories with a search field, and the chosen category on the right.
/// Settings v2 (N339): a page is a short header, an optional status card, then groups of rows (`SettingsRows.swift`) in a 640 pt column.
/// Rarely used rows sit behind the category's "Advanced".
struct SettingsView: View {
    @Bindable var flow: SettingsFlow
    var projects: [ProjectConfig] = []
    /// The top bar's coffee button; the Keep awake switches drive the same object.
    var sleepGuard: SleepGuard?
    /// The safe point of the 5-hour plan usage, with the reason it is reached now (nil while it is not).
    var safePoint = SafePoint(percent: SafePoint.defaultPercent)
    var safePointReason: String?
    var onSafePoint: (SafePoint) -> Void = { _ in }
    /// The usage gate (N259): thresholds of the 5-hour and week usage, why it holds now, and "Start anyway" (nil while nothing holds).
    var usageGate = UsageGate()
    var usageGateReason: String?
    var onUsageGate: (UsageGate) -> Void = { _ in }
    var onStartAnyway: (() -> Void)?
    var onUpdate: () -> Void = {}
    var onRelaunch: () -> Void = {}
    var onCleanup: (() -> Void)?
    var onSetup: () -> Void = {}
    var onChooseScripts: () -> Void = {}
    var notificationsOn = false
    var onNotifications: (Bool) -> Void = { _ in }
    var notificationPrefs = NotificationPrefs()
    var onNotificationEvent: (NotificationEvent, Bool) -> Void = { _, _ in }
    var onNotificationSound: (Bool) -> Void = { _ in }
    var onEventSound: (NotificationEvent, NotificationSound) -> Void = { _, _ in }
    var onDockBadge: (Bool) -> Void = { _ in }
    var onDockBounce: (Bool) -> Void = { _ in }
    /// The floating question panel (N373), off by default; `QuestionPanelController` reads it on every tick.
    @AppStorage(QuestionPanelRules.settingKey) private var questionPanelOnTop = false
    var onAddProject: (() -> Void)?
    /// Opens the project's own settings sheet, where "Remove from list…" asks before it does anything.
    var onEditProject: (String) -> Void = { _ in }
    var onOpenTeam: () -> Void = {}
    /// The settings the shown page has a row for (tests: every `SettingsItem` is visible on its page).
    var onRowsShown: ((Set<SettingsItem>) -> Void)?
    /// The plan usage the top bar shows (Usage › Plan usage now), the agents working now (Keep awake card), the Setup check (Advanced card)
    /// and the Clean up… scan, counted when Agents & Team opens (N340).
    var planUsage: PlanUsage?
    var workingAgents = 0
    var setup: SetupModel?
    var leftoverScan: (() async -> Int?)?
    @State private var copied = false
    @State private var confirmingRestart = false
    /// The tours (N311), from the window; absent in snapshots of the screen alone.
    @Environment(TutorialModel.self) private var tutorial: TutorialModel?

    static let columnWidth: CGFloat = 640
    private static let groupSpacing: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Tok.line)
            Scroller {
                VStack(alignment: .leading, spacing: Self.groupSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flow.category.title).font(Tok.Font.title).foregroundStyle(Tok.ink)
                        Text(flow.category.explanation).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                    content(of: flow.category)
                }
                .frame(maxWidth: Self.columnWidth, alignment: .topLeading)
                .pageMargin()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onPreferenceChange(SettingsRowItemsKey.self) { items in onRowsShown?(items) }
            }
            .id(flow.category)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.bg)
        .task { await flow.load() }
        .task(id: flow.category) { if flow.category == .agents, let leftoverScan { await flow.countLeftovers(leftoverScan) } }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").font(Tok.Font.title).foregroundStyle(Tok.ink).padding(.bottom, Tok.Space.s)
            TextField("Search settings", text: $flow.query).textFieldStyle(.roundedBorder)
                .onSubmit { if let first = flow.results.first { flow.show(first) } }
                .accessibilityLabel("Search settings")
                .tutorialAnchor(.settingsSearch)
                .padding(.bottom, Tok.Space.s)
            if flow.query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(alignment: .leading, spacing: 2) { ForEach(SettingsCategory.allCases, id: \.self) { category in categoryRow(category) } }
                    .tutorialAnchor(.settingsCategories)
            } else if flow.results.isEmpty {
                Text("No setting matches \u{201C}\(flow.query)\u{201D}").font(Tok.Font.small).foregroundStyle(Tok.ink3).padding(.horizontal, 4)
            } else {
                ForEach(flow.results, id: \.self) { item in resultRow(item) }
            }
            Spacer(minLength: 0)
        }
        .padding([.trailing, .bottom], Tok.Space.m).pageMargin([.leading, .top])
        .frame(width: 236, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.pane)
    }

    private func categoryRow(_ category: SettingsCategory) -> some View {
        let selected = flow.category == category
        return Button { flow.show(category) } label: {
            HStack(spacing: Tok.Space.s) {
                Image(systemName: category.symbol).font(Tok.Font.small).frame(width: 16)
                Text(category.title).font(Tok.Font.body)
                Spacer(minLength: 0)
                if category == .general, flow.update.available != nil {
                    Text("1").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.work)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Tok.work.opacity(0.18), in: Capsule())
                        .accessibilityLabel("Update available")
                }
            }
            .foregroundStyle(selected ? Tok.ink : Tok.ink2)
            .padding(.horizontal, Tok.Space.s).padding(.vertical, 6)
            .background(selected ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func resultRow(_ item: SettingsItem) -> some View {
        Button { flow.show(item) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Tok.Font.body).foregroundStyle(Tok.ink)
                Text(item.isAdvanced ? "\(item.category.title) › Advanced" : item.category.title).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tok.Space.s).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.category.title)")
    }

    // MARK: categories

    @ViewBuilder private func content(of category: SettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: Self.groupSpacing) {
            switch category {
            case .general: general
            case .notifications: notifications
            case .keepAwake: keepAwake
            case .usage: usage
            case .autopilot: autopilot
            case .agents: agents
            case .terminals: terminals
            case .projects: projectsList
            case .github: githubSection
            case .advanced: advanced
            }
        }
    }

    static func caffeinateStatus(_ state: SleepGuard.State) -> String {
        switch state {
        case .off: "Off"
        case .waiting: "On, no task is running"
        case .holding: "On, keeping the Mac awake now"
        case .lowBattery: "On, paused: the battery is low"
        }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        versionCard
        SettingsGroup(title: "Appearance") {
            SettingsRow(title: SettingsItem.appearance.title, item: .appearance) {
                Picker("Appearance", selection: Binding(get: { flow.appearance }, set: { flow.setAppearance($0) })) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let error = flow.appearanceError { SettingsLine { note(error, warning: true) } }
        }
        startupAndUpdates
        if let tutorial { tours(tutorial) }
        if flow.hasSourceBuild {
            developerBuild
            advancedPart {
                SettingsCard { SettingsRow(title: SettingsItem.signing.title, hint: flow.signingHint, item: .signing) }
            }
        }
    }

    /// The running version, and the newer release with its notes and "Install update…" when there is one (N337).
    private var versionCard: some View {
        @Bindable var update = flow.update
        let version = SettingsFlow.splitVersion(flow.appVersion)
        return SettingsStatusCard(icon: "shippingbox", title: "Tentacl Crew \(version.name)", subtitle: updateLine(update, build: version.build)) {
            if let release = update.available {
                SettingsPill(text: "\(SettingsFlow.tagName(release.tag).replacingOccurrences(of: "Tentacl Crew ", with: "")) is available", tone: .work)
                Button("Install update…") { update.confirming = true }.buttonStyle(.settingsPrimary).disabled(update.phase == .installing)
            }
        } below: {
            if let release = update.available, !release.summary.isEmpty {
                SettingsLine {
                    Text("What's new in \(SettingsFlow.tagName(release.tag))").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink2)
                    Text(release.summary).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 56)
            }
            if case .failed(let m) = update.phase { SettingsLine { note(m, warning: true) } }
        }
        .settingsItem(.version)
        .confirmationDialog("Install \(update.available.map { SettingsFlow.tagName($0.tag) } ?? "the update")?", isPresented: $update.confirming) {
            Button("Install and restart") { Task { await update.install(quit: { NSApp.terminate(nil) }) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Tentacl Crew will quit, update and reopen; agents keep running in tentacld.") }
    }

    /// "Build 268 · checked 10 min ago" (N340); after a failed check "could not check".
    private func updateLine(_ update: UpdateModel, build: String?) -> String? {
        let state: String = switch update.phase {
        case .checking: "checking for updates…"
        case .installing: "downloading the update…"
        case .idle, .failed: update.ownTag == nil ? "development build" : update.checkedText
        }
        return [build.map { "Build \($0)" }, state].compactMap { $0 }.joined(separator: " · ")
    }

    private var startupAndUpdates: some View {
        let update = flow.update
        return SettingsGroup(title: "Startup and updates") {
            SettingsRow(title: SettingsItem.openAtLogin.title, item: .openAtLogin) {
                SettingsSwitch("Open at login", isOn: Binding(get: { flow.openAtLogin }, set: { flow.setOpenAtLogin($0) }))
            }
            if let error = flow.loginError { SettingsLine { note(error, warning: true) } }
            SettingsRow(title: SettingsItem.githubUpdate.title, hint: "At launch and once a day. Nothing installs without you.", item: .githubUpdate) {
                Button(update.phase == .checking ? "Checking…" : "Check now") { Task { await update.check(manual: true) } }
                    .buttonStyle(.settingsLink).disabled(update.phase != .idle)
                SettingsSwitch("Check for updates automatically", isOn: Binding(get: { update.autoCheck }, set: { update.setAutoCheck($0) }))
            }
            SettingsRow(title: "Include betas") {
                SettingsSwitch("Include betas", isOn: Binding(get: { update.includeBetas }, set: { update.setIncludeBetas($0) }))
            }
        }
    }

    /// General › Tours (N311): the first-visit offer and Reset tours (which asks first); the progress on the group's right.
    private func tours(_ tutorial: TutorialModel) -> some View {
        SettingsGroup(title: "Tours") {
            Text(tutorial.summary)
        } content: {
            SettingsRow(title: "Offer a tour on a new screen", hint: "The ? button in the top bar or ⌘? opens a tour any time.", item: .tours) {
                Button("Reset tours…") { tutorial.confirmingReset = true }.buttonStyle(.settings)
                SettingsSwitch("Offer a tour on a new screen", isOn: Binding(get: { tutorial.save.offerOnNewScreen }, set: { tutorial.setOfferOnNewScreen($0) }))
            }
        }
        .tutorialAnchor(.settingsTours)
    }

    /// Only on a Mac with the source repository: the installed stable copy and "Update stable…".
    private var developerBuild: some View {
        SettingsGroup(title: "Developer build") {
            Text("only with the source repository")
        } content: {
            SettingsRow(title: SettingsItem.stableVersion.title, hint: flow.stableVersion ?? "not installed yet", item: .stableVersion, monoHint: true) {
                MenuBox {
                    ForEach(flow.tags, id: \.self) { tag in Button(tag) { flow.ref = tag } }
                } label: {
                    HStack(spacing: 6) {
                        Text(flow.ref ?? "no tag").font(Tok.Font.mono).foregroundStyle(Tok.ink)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Tok.ink2)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line))
                }
                .accessibilityLabel("Tag")
                Button("Update stable…", action: onUpdate).buttonStyle(.settings).disabled(!flow.canUpdate || flow.phase == .working)
                    .help(flow.refusal ?? "Build the chosen tag and install it as the stable Tentacl Crew")
                    .settingsItem(.updateStable)
            }
            if let refusal = flow.refusal, flow.phase != .working { SettingsLine { note(refusal) } }
            stableStatus
        }
    }

    @ViewBuilder private var stableStatus: some View {
        switch flow.phase {
        case .working: SettingsLine { note("Building and installing… this takes a few minutes.") }
        case .done:
            SettingsLine {
                HStack(spacing: Tok.Space.m) {
                    Text(flow.message ?? "").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if flow.canRelaunch { Button("Relaunch now", action: onRelaunch).buttonStyle(.settingsPrimary) }
                }
            }
        case .failed(let m): SettingsLine { Text(m).font(Tok.Font.small).foregroundStyle(Tok.askText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        case .idle, .confirming: EmptyView()
        }
    }

    // MARK: Notifications

    @ViewBuilder private var notifications: some View {
        SettingsCard {
            SettingsRow(title: SettingsItem.notifications.title, hint: "macOS asks for permission the first time.", item: .notifications) {
                SettingsSwitch("Notifications", isOn: Binding(get: { notificationsOn }, set: onNotifications))
            }
        }
        SettingsGroup(title: "Events", footer: "macOS System Settings → Notifications can still mute Tentacl Crew.") {
            HStack(spacing: 6) {
                Text("Play sounds")
                SettingsSwitch("Play sounds", isOn: Binding(get: { notificationPrefs.sound }, set: onNotificationSound))
            }
            .disabled(!notificationsOn).opacity(notificationsOn ? 1 : 0.45)
            .settingsItem(.sound)
        } content: {
            HStack {
                Text("Event").frame(maxWidth: .infinity, alignment: .leading)
                Text("Sound").frame(width: 150 + 20 + Tok.Space.s * 2 + 32, alignment: .leading)
            }
            .font(Tok.Font.small).foregroundStyle(Tok.ink3)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .overlay(alignment: .top) { SettingsHairline() }
            ForEach(NotificationEvent.allCases, id: \.self) { event in eventRow(event) }
        }
        .settingsItem(.events)
        SettingsGroup(title: "Dock icon") {
            SettingsRow(title: "Show count on the Dock icon", item: .dock) {
                SettingsSwitch("Show count on the Dock icon", isOn: Binding(get: { notificationPrefs.dockBadge }, set: onDockBadge))
            }
            SettingsRow(title: "Bounce once when an agent asks") {
                SettingsSwitch("Bounce the Dock icon once when an agent asks", isOn: Binding(get: { notificationPrefs.dockBounce }, set: onDockBounce))
            }
        }
        SettingsGroup(title: "Question panel") {
            SettingsRow(title: "Keep a question panel on top until I answer",
                        hint: "While Tentacl is in the background, a small panel shows the oldest open question over other apps. × hides it until the next new question.",
                        item: .questionPanel) {
                SettingsSwitch("Keep a question panel on top until I answer", isOn: $questionPanelOnTop)
            }
        }
    }

    /// One line of the Events table: the event, its sound and ▶, and its switch. Master off dims the line.
    private func eventRow(_ event: NotificationEvent) -> some View {
        let sound = notificationPrefs.sounds[event] ?? .crew
        return SettingsRow(title: event.title, dimmed: !notificationsOn) {
            HStack(spacing: Tok.Space.s) {
                Picker("Sound for \(event.title)", selection: Binding(get: { sound }, set: { onEventSound(event, $0) })) {
                    Text("Tentacl Crew").tag(NotificationSound.crew)
                    Text("None").tag(NotificationSound.silent)
                    Text("Default").tag(NotificationSound.standard)
                    Divider()
                    ForEach(NotificationSound.systemSounds(), id: \.self) { Text($0).tag(NotificationSound.named($0)) }
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
                Button { sound.play() } label: { Image(systemName: "play.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Tok.ink3).frame(width: 20)
                    .help("Preview this sound").accessibilityLabel("Preview sound for \(event.title)")
            }
            .disabled(!notificationPrefs.sound).opacity(notificationPrefs.sound ? 1 : 0.45)
            SettingsSwitch(event.title, isOn: Binding(get: { notificationPrefs.events.contains(event) }, set: { onNotificationEvent(event, $0) }))
        }
    }

    // MARK: Keep awake

    @ViewBuilder private var keepAwake: some View {
        if let g = sleepGuard {
            awakeCard(g)
            SettingsGroup(title: "When") {
                SettingsRow(title: SettingsItem.keepAwakeMode.title, item: .keepAwakeMode) {
                    Picker("Keep awake mode", selection: Binding(get: { g.mode }, set: { g.mode = $0 })) {
                        ForEach(KeepAwakeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }
                SettingsRow(title: SettingsItem.display.title, hint: "Off: the screen may turn off while the Mac works.", item: .display) {
                    SettingsSwitch("Keep the display awake too", isOn: Binding(get: { g.keepDisplay }, set: { g.keepDisplay = $0 }))
                }
            }
            SettingsGroup(title: "On battery", footer: "On battery the Mac sleeps when the lid closes, and the agents pause.") {
                SettingsRow(title: "Warn when agents work on battery", info: "The coffee button shows a warning, and a notification comes before the Mac sleeps.", item: .battery) {
                    SettingsSwitch("Warn when agents work on battery", isOn: Binding(get: { g.warnOnBattery }, set: { g.warnOnBattery = $0 }))
                }
                SettingsRow(title: "Stop keeping awake below") {
                    SettingsIntStepper(text: "\(g.stopBelowPercent)% battery", value: Binding(get: { g.stopBelowPercent }, set: { g.stopBelowPercent = $0 }),
                                       range: 5...95, step: 5, on: g.stopBelowEnabled)
                    SettingsSwitch("Stop keeping awake below", isOn: Binding(get: { g.stopBelowEnabled }, set: { g.stopBelowEnabled = $0 }))
                }
            }
            advancedPart {
                SettingsCard {
                    SettingsRow(title: "Stay awake with the lid closed on power", hint: g.lidSupportNote, item: .lid) {
                        SettingsSwitch("Stay awake with the lid closed on power", isOn: Binding(get: { g.lidOnPower }, set: { g.lidOnPower = $0 })).disabled(!g.supportsLidClosed)
                    }
                }
            }
        } else {
            note("Keep awake is not available.")
        }
    }

    /// What Keep awake does now (`SleepGuard.state`), and the last sleep it could not stop.
    private func awakeCard(_ g: SleepGuard) -> some View {
        let (title, pill, tone): (String, String, SettingsPill.Tone) = switch g.state {
        case .off: ("The Mac sleeps as usual", "Off", .off)
        case .waiting: ("No agent is working", "On", .work)
        case .holding: ("Keeping the Mac awake", "On now", .go)
        case .lowBattery: ("Paused: the battery is low", "Paused", .wait)
        }
        return SettingsStatusCard(icon: "cup.and.saucer", title: title, subtitle: SettingsFlow.awakeLine(agents: workingAgents, power: g.source)) {
            SettingsPill(text: pill, tone: tone).accessibilityLabel(Self.caffeinateStatus(g.state))
        } below: {
            if let line = g.interruption {
                SettingsLine {
                    HStack(spacing: Tok.Space.s) {
                        Text(line).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Dismiss") { g.dismissInterruption() }.buttonStyle(.settings)
                    }
                }
            }
        }
    }

    // MARK: Usage

    @AppStorage(AgentSleep.minutesKey) private var sleepMinutes = 0

    @ViewBuilder private var usage: some View {
        SettingsGroup(title: "Plan usage now", trailing: { Text("white line = your limit").font(Tok.Font.small).foregroundStyle(Tok.ink3) }) {
            usageRow("5 hours", planUsage?.fiveHour, limit: usageGate.fiveHour)
            usageRow("Week", planUsage?.week, limit: usageGate.week)
        }
        SettingsGroup(title: "Limits", footer: "Running agents are never stopped. Unknown usage never blocks.") {
            gateRow("No new agents above (5 hours)", label: "Do not start new agents when the 5 h usage is above", value: usageGate.fiveHour, fallback: UsageGate.defaultFiveHour) {
                onUsageGate(UsageGate(fiveHour: $0, week: usageGate.week))
            }
            .settingsItem(.usageLimit)
            gateRow("No new agents above (week)", label: "Do not start new agents when the week usage is above", value: usageGate.week, fallback: UsageGate.defaultWeek) {
                onUsageGate(UsageGate(fiveHour: usageGate.fiveHour, week: $0))
            }
            if let usageGateReason {
                SettingsLine {
                    note(usageGateReason, warning: true)
                    if let onStartAnyway { Button("Start anyway until it resets", action: onStartAnyway).buttonStyle(.settings) }
                }
            }
            SettingsRow(title: "PM stops starting cards at (5 hours)",
                        info: "The safe point. Start, Plan a round and Autopilot wait; running agents are not stopped. The PM is told the safe point.", item: .safePoint) {
                SettingsIntStepper(text: "\(safePoint.percent ?? SafePoint.defaultPercent)%", value: Binding(get: { safePoint.percent ?? SafePoint.defaultPercent }, set: { onSafePoint(SafePoint(percent: $0)) }),
                                   range: SafePoint.range, step: 5, on: safePoint.percent != nil)
                SettingsSwitch("Safe point", isOn: Binding(get: { safePoint.percent != nil }, set: { onSafePoint(SafePoint(percent: $0 ? SafePoint.defaultPercent : nil)) }))
            }
            if let safePointReason { SettingsLine { note(safePointReason, warning: true) } }
        }
    }

    /// One window of the plan usage: the bar (tone by `SettingsFlow.usageTone`), a white mark at the limit (none when it is off), "42% / 90%".
    private func usageRow(_ title: String, _ window: PlanUsage.Window?, limit: Int?) -> some View {
        let width: CGFloat = 220
        let tone: Color = switch window.map({ SettingsFlow.usageTone(percent: $0.percent, limit: limit) }) {
        case .stop?: Tok.stop
        case .wait?: Tok.wait
        default: Tok.go
        }
        return SettingsRow(title: title, hint: window.map { SettingsFlow.resetHint($0.resetsAt) }) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Tok.bg).overlay(RoundedRectangle(cornerRadius: 4).stroke(Tok.line))
                if let window { RoundedRectangle(cornerRadius: 4).fill(tone).frame(width: width * window.fraction) }
                if let limit, window != nil {
                    RoundedRectangle(cornerRadius: 1).fill(Tok.ink).frame(width: 2, height: 16).offset(x: width * CGFloat(limit) / 100 - 1)
                }
            }
            .frame(width: width, height: 8)
            .accessibilityHidden(true)
            Text(SettingsFlow.usageValue(percent: window?.percent, limit: window == nil ? nil : limit))
                .font(Tok.Font.mono).foregroundStyle(Tok.ink2).monospacedDigit()
                .frame(width: 92, alignment: .trailing)
                .accessibilityLabel("\(title) usage \(SettingsFlow.usageValue(percent: window?.percent, limit: window == nil ? nil : limit))")
        }
    }

    private func gateRow(_ title: String, label: String, value: Int?, fallback: Int, set: @escaping (Int?) -> Void) -> some View {
        SettingsRow(title: title) {
            SettingsIntStepper(text: "\(value ?? fallback)%", value: Binding(get: { value ?? fallback }, set: { set($0) }), range: UsageGate.range, step: 5, on: value != nil)
            SettingsSwitch(label, isOn: Binding(get: { value != nil }, set: { set($0 ? fallback : nil) }))
        }
    }

    // MARK: PM & Autopilot

    @ViewBuilder private var autopilot: some View {
        let d = flow.autopilotDefaults
        SettingsGroup(title: "Agent questions") {
            SettingsRow(title: "Who answers",
                        info: "Critical questions (outward or destructive steps, anything outside the card's files, or marked critical by the agent) always come to you; the PM cannot lower that. A question the PM does not answer in 10 minutes comes to you. What the PM answered is listed under Waiting for you.",
                        item: .agentQuestions) {
                Picker("Agent questions", selection: Binding(get: { flow.questionMode }, set: { flow.setQuestionMode($0) })) {
                    ForEach(AgentQuestionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }
            SettingsRow(title: SettingsItem.userLanguage.title, hint: "Questions that reach you are written in it. Empty: the system language.", item: .userLanguage) {
                FieldText(text: Binding(get: { flow.userLanguage }, set: { flow.setUserLanguage($0) }), placeholder: QuestionSettings.systemLanguage).frame(width: 160)
            }
        }
        SettingsGroup(title: "New project defaults", footer: "Projects with their own autopilot settings keep them. On is switched per project.") {
            SettingsRow(title: SettingsItem.autopilotMode.title, hint: d.mode.explanation, item: .autopilotMode) {
                Picker("Mode", selection: Binding(get: { d.mode }, set: { var n = d; n.mode = $0; flow.saveAutopilotDefaults(n) })) {
                    Text("Off").tag(AutopilotMode.off); Text("Shadow").tag(AutopilotMode.shadow)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            SettingsRow(title: SettingsItem.autopilotModel.title, item: .autopilotModel) {
                Picker("Model", selection: Binding(get: { d.model }, set: { var n = d; n.model = $0; flow.saveAutopilotDefaults(n) })) {
                    ForEach(AutopilotPolicy.models, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsRow(title: SettingsItem.perDecision.title, item: .perDecision) {
                SettingsStepper(text: String(format: "$%.2f", d.budgetUSD), value: Binding(get: { d.budgetUSD }, set: { var n = d; n.budgetUSD = $0; flow.saveAutopilotDefaults(n) }),
                                range: 0.05...5, step: 0.25)
            }
            SettingsRow(title: SettingsItem.perDay.title, item: .perDay) {
                SettingsStepper(text: String(format: "$%.0f a day", d.dailyLimitUSD ?? 10),
                                value: Binding(get: { d.dailyLimitUSD ?? 10 }, set: { var n = d; n.dailyLimitUSD = $0; flow.saveAutopilotDefaults(n) }),
                                range: 1...1000, step: 5, on: d.dailyLimitUSD != nil)
                SettingsSwitch("Daily limit", isOn: Binding(get: { d.dailyLimitUSD != nil }, set: { var n = d; n.dailyLimitUSD = $0 ? 10 : nil; flow.saveAutopilotDefaults(n) }))
            }
            if let error = flow.defaultsError { SettingsLine { note(error, warning: true) } }
        }
        if let folder = flow.autopilotFolder {
            advancedPart { SettingsCard { pathRow(SettingsItem.decisionLogs.title, folder, item: .decisionLogs) } }
        }
    }

    // MARK: Agents & Team

    @ViewBuilder private var agents: some View {
        SettingsCard {
            SettingsRow(title: SettingsItem.team.title, hint: "Roles are edited on the Team screen.", item: .team) {
                Button("Open Team", action: onOpenTeam).buttonStyle(.settings)
            }
            SettingsRow(title: "Put idle agents to sleep after",
                        info: "Only agents that wrote their Report and wait with nothing running. Never one with an open question, a running command, or a card in review. A sleeping agent does not count against the parallel limit; a message or Fix notes wake it first, and it continues the same conversation.",
                        item: .sleep) {
                let minutes = sleepMinutes > 0 ? sleepMinutes : AgentSleep.defaultMinutes
                SettingsIntStepper(text: "\(minutes) min", value: Binding(get: { minutes }, set: { sleepMinutes = $0 }), range: AgentSleep.minutesRange, step: 5, on: sleepMinutes > 0)
                SettingsSwitch("Put idle agents to sleep", isOn: Binding(get: { sleepMinutes > 0 }, set: { sleepMinutes = $0 ? AgentSleep.defaultMinutes : 0 }))
            }
            SettingsRow(title: SettingsItem.cleanUp.title, hint: onCleanup == nil ? "Needs the scripts folder (Advanced)." : SettingsFlow.cleanupHint(flow.leftovers), item: .cleanUp) {
                if let onCleanup { Button("Clean up…", action: onCleanup).buttonStyle(.settings).help("List agents and worktrees that outlived their card") }
            }
        }
        if let dir = flow.rolesDir {
            advancedPart { SettingsCard { pathRow(SettingsItem.sharedRoles.title, dir, item: .sharedRoles) } }
        }
    }

    // MARK: Terminals

    private var terminals: some View {
        SettingsCard {
            SettingsRow(title: "Bring back a shell's text after a restart",
                        hint: flow.restoreHistory ? "Shown dimmed above a new shell in the same folder." : "Off: new shells save nothing, and saved text is not shown.",
                        item: .restoreHistory) {
                Button("Delete saved") { Task { await flow.deleteSavedHistory() } }.buttonStyle(.settings)
                    .help("Deletes the saved text of every shell. Turning the switch off does not delete it.")
                    .accessibilityLabel("Delete saved history")
                SettingsSwitch("Restore terminal history", isOn: Binding(get: { flow.restoreHistory }, set: { flow.setRestoreHistory($0) }))
            }
            SettingsRow(title: SettingsItem.terminalHelper.title, hint: helperHint, item: .terminalHelper) {
                switch flow.helper {
                case .unknown: SettingsPill(text: "Checking…")
                case .notRunning: SettingsPill(text: "Not running")
                case .current: SettingsPill(text: "Running, current", tone: .go)
                case .old:
                    SettingsPill(text: "Older version", tone: .wait)
                    Button("Restart helper…") { confirmingRestart = true }.buttonStyle(.settings).disabled(!flow.canRestartHelper)
                        .help(flow.canRestartHelper ? "Closes the open shells and starts the new helper" : "An agent is running in the helper; restart when it is done")
                }
            }
            if case .old = flow.helper, flow.agentSessions > 0 {
                SettingsLine { note("\(flow.agentSessions) agent \(flow.agentSessions == 1 ? "session runs" : "sessions run") in it. Restart when they are done.") }
            }
            if let error = flow.terminalError { SettingsLine { note(error, warning: true) } }
        }
        .confirmationDialog(flow.restartQuestion, isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Restart helper", role: .destructive) { Task { await flow.restartHelper() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var helperHint: String {
        switch flow.helper {
        case .notRunning: "tentacld · starts with the first terminal"
        case .old(let started):
            "From an older version" + (started.map { " (started \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute())))" } ?? "")
                + ". New terminal features, such as history, need a restart."
        case .unknown, .current: "tentacld · keeps shells and agents alive while the app restarts"
        }
    }

    // MARK: Projects

    @ViewBuilder private var projectsList: some View {
        SettingsCard {
            if projects.isEmpty { SettingsRow(title: "No project yet", item: .projects) }
            ForEach(Array(projects.enumerated()), id: \.offset) { _, project in
                SettingsRow(title: project.name, hint: Self.shortPath(project.repoPath), item: .projects, monoHint: true, strong: true) {
                    Button("Edit…") { onEditProject(project.id) }.buttonStyle(.settings)
                        .help("Edit the project, or remove it from the list (its files stay)")
                }
                .help(project.repoPath)
            }
        }
        if let onAddProject { Button("Add project…", action: onAddProject).buttonStyle(.settings).settingsItem(.addProject) }
    }

    /// The home folder as ~.
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: GitHub

    private var githubSection: some View {
        let github = flow.github
        return githubCard(github)
            .settingsItem(.githubAccount)
            .task { await github.check() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await github.appBecameActive() } }
    }

    @ViewBuilder private func githubCard(_ github: GitHubAccountModel) -> some View {
        let icon = "person.crop.circle"
        switch github.state {
        case nil:
            SettingsStatusCard(icon: icon, title: "Checking…", subtitle: "Asking the GitHub CLI (gh) who is signed in.") { EmptyView() } below: { githubFooter(github) }
        case .signedIn(let login)?:
            SettingsStatusCard(icon: icon, title: login.account,
                               subtitle: "\(login.host) · \(login.gitProtocol ?? "unknown protocol") · via GitHub CLI"
                                   + (login.others.isEmpty ? "" : "\nAlso signed in: \(login.others.joined(separator: ", "))")) {
                SettingsPill(text: "Signed in", tone: .go)
                checkAgain(github)
            } below: { githubFooter(github) }
        case .signedOut?:
            SettingsStatusCard(icon: icon, title: "Not signed in", subtitle: "Sign in once to create repositories and push. A Terminal window opens; you finish in the browser.") {
                SettingsPill(text: "Signed out", tone: .wait)
            } below: {
                SettingsLine {
                    commandBox(GitHubAccount.signInCommand)
                    HStack(spacing: Tok.Space.s) {
                        Button("Sign in to GitHub") { Task { await github.signIn() } }.buttonStyle(.settingsPrimary)
                        checkAgain(github)
                    }
                    if github.isWaitingForSignIn { note("Terminal is open. When you are done in the browser, come back here; this checks again by itself.") }
                }
                githubFooter(github)
            }
        case .ghMissing?:
            SettingsStatusCard(icon: icon, title: "GitHub CLI missing", subtitle: "Tentacl Crew talks to GitHub through the GitHub CLI (gh). Install it, then sign in.") {
                SettingsPill(text: "Not installed", tone: .wait)
            } below: {
                SettingsLine {
                    commandBox(github.installCommand)
                    if github.isConfirmingInstall {
                        note("This runs the command above with Homebrew, then checks again.")
                        HStack(spacing: Tok.Space.s) {
                            Button("Install") { Task { await github.confirmInstall() } }.buttonStyle(.settingsPrimary)
                            Button("Cancel") { github.cancelInstall() }.buttonStyle(.settings)
                        }
                    } else {
                        HStack(spacing: Tok.Space.s) {
                            if github.canInstall { Button("Install GitHub CLI") { github.requestInstall() }.buttonStyle(.settingsPrimary).disabled(github.isInstalling) }
                            Button("Copy command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(github.installCommand, forType: .string) }.buttonStyle(.settings)
                            checkAgain(github)
                        }
                    }
                }
                githubFooter(github)
            }
        case .unsure(let why)?:
            SettingsStatusCard(icon: icon, title: "No clear answer from gh", subtitle: "gh gave an answer the panel cannot use: \(why)") {
                SettingsPill(text: "Unknown", tone: .warn)
                checkAgain(github)
            } below: { githubFooter(github) }
        }
    }

    /// The install log and the last error, inside the account card.
    @ViewBuilder private func githubFooter(_ github: GitHubAccountModel) -> some View {
        if !github.installLog.isEmpty {
            SettingsLine { Text(github.installLog).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        if let message = github.message { SettingsLine { note(message, warning: true) } }
    }

    private func checkAgain(_ github: GitHubAccountModel) -> some View {
        Button(github.isChecking ? "Checking…" : "Check again") { Task { await github.check() } }.buttonStyle(.settings).disabled(github.isChecking)
    }

    private func commandBox(_ command: String) -> some View {
        Text(command).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled)
            .padding(Tok.Space.s + 2).frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line))
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        SettingsStatusCard(icon: "checklist", title: SettingsItem.setupCheck.title, subtitle: setupLine) {
            if let setup {
                if setup.isChecking { SettingsPill(text: "Checking…") }
                else if let summary = SettingsFlow.setupSummary(setup.items) { SettingsPill(text: summary.text, tone: summary.ok ? .go : .wait) }
                if SettingsFlow.setupSummary(setup.items)?.ok == false { Button("Open Setup…", action: onSetup).buttonStyle(.settings) }
                Button("Run again") { Task { await setup.check() } }.buttonStyle(.settings).disabled(setup.isChecking)
                    .help("Check that the terminal (tentacld), claude, jq, the scripts folder, a project and the shared roles are in place")
            } else {
                Button("Setup check…", action: onSetup).buttonStyle(.settings)
                    .help("Check that the terminal (tentacld), claude, jq, the scripts folder, a project and the shared roles are in place")
            }
        } below: {
            ForEach(flow.problems, id: \.self) { problem in SettingsLine { note(problem, warning: true) } }
        }
        .settingsItem(.setupCheck)
        SettingsGroup(title: "Files") {
            SettingsRow(title: SettingsItem.scriptsFolder.title, hint: flow.scriptsDir.map { Self.shortPath($0.path) } ?? "not set", item: .scriptsFolder, monoHint: true) {
                Button("Choose…", action: onChooseScripts).buttonStyle(.settings)
            }
            pathRow(SettingsItem.settingsFile.title, flow.settingsURL, item: .settingsFile)
            if let log = flow.actionLogURL {
                SettingsRow(title: SettingsItem.actionLog.title, hint: Self.shortPath(log.path), item: .actionLog, monoHint: true) {
                    Button("Open") { NSWorkspace.shared.open(log) }.buttonStyle(.settings).disabled(!FileManager.default.fileExists(atPath: log.path))
                }
            }
        }
        SettingsGroup(title: "Tools") {
            ForEach(SettingsFlow.toolNames, id: \.self) { name in
                let t = flow.tool(name)
                SettingsRow(title: name, hint: t.map { Self.shortPath($0.path) } ?? "not found", item: .tools, monoHint: true) {
                    if let t { Text(t.version).font(Tok.Font.mono).foregroundStyle(Tok.ink2).lineLimit(1) }
                    else { Text("not found").font(Tok.Font.small).foregroundStyle(Tok.askText) }
                }
            }
        }
        Button(copied ? "Copied" : SettingsItem.diagnostics.title) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(flow.diagnostics, forType: .string); copied = true
        }
        .buttonStyle(.settings).help("Versions and paths for a bug report. No logins or keys.")
        .settingsItem(.diagnostics)
    }

    /// "Ran 10 min ago · tentacld, claude, …"; before the first check only the list.
    private var setupLine: String {
        let what = "tentacld, claude, jq, the scripts folder, a project and the shared roles"
        guard let at = setup?.checkedAt else { return what }
        let seconds = Date().timeIntervalSince(at)
        return (seconds < 60 ? "Ran just now" : "Ran \(Stats.durationText(seconds)) ago") + " · " + what
    }

    // MARK: pieces

    /// The category's rarely used rows, closed until asked for (a search result in it opens it).
    private func advancedPart<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { flow.advancedOpen.toggle() } label: {
                HStack(spacing: Tok.Space.xs) {
                    Image(systemName: flow.advancedOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("Advanced").font(Tok.Font.small)
                }
                .foregroundStyle(Tok.ink3).padding(.horizontal, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(flow.advancedOpen ? "Hide advanced settings" : "Show advanced settings")
            if flow.advancedOpen { content() }
        }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(Tok.Font.small).foregroundStyle(warning ? Tok.askText : Tok.ink3).fixedSize(horizontal: false, vertical: true)
    }

    /// A folder or file row: its shortened path below the title, and Show in Finder.
    private func pathRow(_ title: String, _ url: URL, item: SettingsItem) -> some View {
        SettingsRow(title: title, hint: Self.shortPath(url.path), item: item, monoHint: true) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.settings)
                .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
        .help(url.path)
    }
}


/// The last step before the update: the tag and the exact command. Nothing runs until "Update stable".
struct UpdateStableSheet: View {
    @Bindable var flow: SettingsFlow
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            Text("Update stable to \(flow.ref ?? "")").font(Tok.Font.title).foregroundStyle(Tok.ink)
            Text("This checks out the tag in the stable folder, builds it and installs Tentacl.app, and points scriptsDir at the stable scripts. The running Tentacl Crew keeps running until you relaunch it.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                Text(flow.command ?? "").font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Tok.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Update stable", action: onConfirm).buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction).disabled(!flow.canUpdate)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 560)
        .background(Tok.bg)
    }
}
