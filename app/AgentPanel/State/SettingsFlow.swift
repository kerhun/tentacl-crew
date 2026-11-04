import Foundation
import Observation
import ServiceManagement
import AppKit

/// "Open at login", behind a small interface so tests never touch the system.
protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ on: Bool) throws
}

struct SystemLoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setEnabled(_ on: Bool) throws { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
}

/// A command-line tool the panel depends on, as found on this Mac.
struct InstalledTool: Equatable, Sendable {
    let name: String
    let path: String
    let version: String

    /// `<name> --version` for the first copy of `name` the setup check finds; nil when it is not installed.
    static func probe(_ name: String) async -> InstalledTool? {
        guard let url = SetupCheck.findTool(name) else { return nil }
        let out = (try? await ProcessRunner(timeout: 5).run(url, ["--version"])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let first = out.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return InstalledTool(name: name, path: url.path, version: first.isEmpty ? "version unknown" : first)
    }
}

/// The parts of the Settings screen that are not about the update, with live defaults; tests replace them.
struct SettingsExtras {
    var defaults: UserDefaults = .standard
    var loginItem: LoginItemControlling = SystemLoginItem()
    var appVersion = SettingsExtras.bundleVersion
    /// The GitHub release check; nil makes the live one.
    var update: UpdateModel?
    var autopilotStore: AutopilotStore?
    var actionLogURL: URL?
    var rolesDir: URL?
    var toolProbe: @Sendable (String) async -> InstalledTool? = { await InstalledTool.probe($0) }
    /// The GitHub sign-in status; nil makes the live one.
    var github: GitHubAccountModel?
    /// The terminal helper's client (Settings → Terminals), looked up when needed; nil while no helper is there, and always in tests unless one is given.
    var terminal: () -> TentacldClient? = { nil }
    /// When the helper inside the app was built; nil reads it from the app bundle.
    var bundledHelperDate: Date?

    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        return versionName(short: info?["CFBundleShortVersionString"] as? String ?? "dev", label: info?["TentaclReleaseLabel"] as? String, build: info?["CFBundleVersion"] as? String)
    }

    /// "1.0 Beta 1 (build 252)"; the label and the build are left out when the bundle has none.
    static func versionName(short: String, label: String?, build: String?) -> String {
        let name = [short, label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return build.map { "\(name) (build \($0))" } ?? name
    }
}

/// The categories in the Settings sidebar, in the order they are shown.
enum SettingsCategory: String, CaseIterable {
    case general, notifications, keepAwake, usage, autopilot, agents, terminals, projects, github, advanced

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .keepAwake: "Keep awake"
        case .usage: "Usage"
        case .autopilot: "PM & Autopilot"
        case .agents: "Agents & Team"
        case .terminals: "Terminals"
        case .projects: "Projects"
        case .github: "GitHub"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .keepAwake: "cup.and.saucer"
        case .usage: "gauge"
        case .autopilot: "steeringwheel"
        case .agents: "person.3"
        case .terminals: "terminal"
        case .projects: "folder"
        case .github: "arrow.triangle.branch"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    var explanation: String {
        switch self {
        case .general: "Look, startup and version."
        case .notifications: "What reaches you while the window is in the background."
        case .keepAwake: "Same as the coffee button in the top bar."
        case .usage: "When new work waits because the plan usage is high."
        case .autopilot: "Who answers agents, and what a new project's autopilot starts with."
        case .agents: "Roles, idle agents, and leftovers."
        case .terminals: "Shell history and the helper that keeps shells running."
        case .projects: "Removing one keeps its files."
        case .github: "Used to create repositories and push. The token stays with GitHub CLI."
        case .advanced: "Paths, tools and logs. Copy diagnostics for a bug report."
        }
    }

    var items: [SettingsItem] { SettingsItem.allCases.filter { $0.category == self } }
}

/// One setting on the Settings screen: its row label, its category, whether it sits behind that category's "Advanced",
/// and other words it is searched by.
enum SettingsItem: CaseIterable, Hashable {
    case appearance, tours, openAtLogin, version, githubUpdate, stableVersion, updateStable, signing
    case notifications, events, sound, dock, questionPanel
    case keepAwakeMode, display, battery, lid
    case safePoint, usageLimit
    case agentQuestions, userLanguage, autopilotMode, autopilotModel, perDecision, perDay, decisionLogs
    case team, sleep, cleanUp, sharedRoles
    case restoreHistory, terminalHelper
    case projects, addProject
    case githubAccount
    case setupCheck, scriptsFolder, settingsFile, actionLog, tools, diagnostics

    var title: String {
        switch self {
        case .appearance: "Theme"
        case .tours: "Tours"
        case .openAtLogin: "Open at login"
        case .version: "Version"
        case .githubUpdate: "Check for updates automatically"
        case .stableVersion: "Stable copy"
        case .updateStable: "Update stable"
        case .signing: "Signing"
        case .notifications: "Notifications"
        case .events: "Events"
        case .sound: "Play sounds"
        case .dock: "Dock icon"
        case .questionPanel: "Keep a question panel on top"
        case .keepAwakeMode: "Keep awake"
        case .display: "Keep the display awake too"
        case .battery: "On battery"
        case .lid: "Stay awake with the lid closed"
        case .safePoint: "Safe point"
        case .usageLimit: "Usage limit"
        case .agentQuestions: "Agent questions"
        case .userLanguage: "Your language"
        case .autopilotMode: "Autopilot"
        case .autopilotModel: "Model"
        case .perDecision: "Budget per decision"
        case .perDay: "Daily limit"
        case .decisionLogs: "Decision logs"
        case .team: "Team"
        case .sleep: "Put idle agents to sleep"
        case .cleanUp: "Leftover agents and worktrees"
        case .sharedRoles: "Shared roles"
        case .restoreHistory: "Restore terminal history"
        case .terminalHelper: "Terminal helper"
        case .projects: "Projects"
        case .addProject: "Add project"
        case .githubAccount: "GitHub account"
        case .setupCheck: "Setup check"
        case .scriptsFolder: "Scripts folder"
        case .settingsFile: "Settings file"
        case .actionLog: "Action log"
        case .tools: "Tools"
        case .diagnostics: "Copy diagnostics"
        }
    }

    var category: SettingsCategory {
        switch self {
        case .appearance, .tours, .openAtLogin, .version, .githubUpdate, .stableVersion, .updateStable, .signing: .general
        case .notifications, .events, .sound, .dock, .questionPanel: .notifications
        case .keepAwakeMode, .display, .battery, .lid: .keepAwake
        case .safePoint, .usageLimit: .usage
        case .agentQuestions, .userLanguage, .autopilotMode, .autopilotModel, .perDecision, .perDay, .decisionLogs: .autopilot
        case .team, .sleep, .cleanUp, .sharedRoles: .agents
        case .restoreHistory, .terminalHelper: .terminals
        case .projects, .addProject: .projects
        case .githubAccount: .github
        case .setupCheck, .scriptsFolder, .settingsFile, .actionLog, .tools, .diagnostics: .advanced
        }
    }

    /// Rarely used: shown when the category's "Advanced" is opened.
    var isAdvanced: Bool { [.signing, .lid, .decisionLogs, .sharedRoles].contains(self) }

    var keywords: [String] {
        switch self {
        case .appearance: ["appearance", "theme", "dark", "light", "midnight", "system", "colors", "colours", "look"]
        case .tours: ["tour", "tours", "tutorial", "guide", "help", "onboarding", "reset tours"]
        case .openAtLogin: ["start", "startup", "launch"]
        case .version: ["about", "build"]
        case .githubUpdate: ["updates", "check now", "update", "new version", "check", "automatically", "beta", "betas", "release"]
        case .stableVersion: ["stable version", "installed", "release", "developer build"]
        case .updateStable: ["tag", "upgrade", "install", "relaunch"]
        case .signing: ["code signing", "xcconfig", "folder access"]
        case .notifications: ["alerts", "notify"]
        case .events: NotificationEvent.allCases.map(\.title)
        case .sound: ["sound", "mute", "alert sound", "sound per event", "preview"]
        case .dock: ["badge", "count", "bounce", "dock"]
        case .questionPanel: ["floating", "panel", "on top", "always on top", "question", "until I answer"]
        case .keepAwakeMode: ["mode", "caffeinate", "coffee", "sleep", "awake"]
        case .display: ["display", "screen", "monitor"]
        case .battery: ["power", "low battery", "stop below", "warn"]
        case .lid: ["lid", "lid closed", "clamshell", "power adapter"]
        case .safePoint: ["usage", "limit", "5 hour", "5h", "plan", "percent", "no new cards", "week"]
        case .usageLimit: ["usage", "limit", "5h", "5 hour", "week", "weekly", "plan", "gate", "start anyway", "no new agents"]
        case .sleep: ["sleep", "idle", "idle agents", "wake", "resume", "auto-sleep", "park"]
        case .agentQuestions: ["questions", "PM answers", "critical", "ask", "waiting for you"]
        case .userLanguage: ["language", "translate", "turkish", "english", "questions"]
        case .autopilotMode: ["mode", "shadow", "off", "new project defaults"]
        case .autopilotModel: ["haiku", "sonnet", "opus"]
        case .perDecision: ["per decision", "budget", "cost", "dollars"]
        case .perDay: ["per day", "budget", "cost"]
        case .decisionLogs: ["autopilot logs", "history"]
        case .team: ["roles", "team screen"]
        case .cleanUp: ["clean up", "clean-up", "worktrees", "stale agents", "outlived"]
        case .sharedRoles: ["roles folder"]
        case .restoreHistory: ["shell", "saved text", "delete history", "scrollback"]
        case .terminalHelper: ["tentacld", "restart", "older version", "daemon"]
        case .projects: ["repository", "data folder", "edit", "remove"]
        case .addProject: ["new project", "create"]
        case .githubAccount: ["github", "gh", "sign in", "account", "push", "repository"]
        case .setupCheck: ["check", "jq", "requirements"]
        case .scriptsFolder: ["scriptsDir", "scripts"]
        case .settingsFile: ["projects.json", "config"]
        case .actionLog: ["log", "actions"]
        case .tools: ["claude", "paths"]
        case .diagnostics: ["bug report", "copy", "support"]
        }
    }

    /// The settings whose name, search words or category contain every word of `query` (case and accents ignored), in screen order.
    static func matching(_ query: String) -> [SettingsItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return allCases.filter { item in
            let text = ([item.title, item.category.title] + item.keywords).joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// The Settings screen: where the scripts are, which stable version of Tentacl is installed, and "Update stable…", which runs
/// `release-stable.sh <ref> --set-scripts-dir <settings>` after a confirmation. After a successful update it offers "Relaunch now": `relaunch-app.sh <app> <pid>` is started detached (it waits for this process to end, then opens the app) and the panel quits.
@Observable @MainActor
final class SettingsFlow {
    enum Phase: Equatable { case idle, confirming, working, done, failed(String) }
    static let scriptName = "release-stable.sh"

    private(set) var scriptsDir: URL?
    private(set) var problems: [String]
    let settingsURL: URL
    let stableDir: URL
    let signingConfigured: Bool
    private(set) var tags: [String] = []
    private(set) var stableVersion: String?
    private(set) var phase: Phase = .idle
    var ref: String?
    private(set) var openAtLogin = false
    /// Settings → General → Appearance (N312): saved as `appearance` in the settings file.
    private(set) var appearance: AppTheme = .dark
    private(set) var appearanceError: String?
    private(set) var loginError: String?
    private(set) var autopilotDefaults = AutopilotPolicy()
    private(set) var defaultsError: String?
    private(set) var tools: [InstalledTool] = []
    let appVersion: String
    let actionLogURL: URL?
    let rolesDir: URL?
    let github: GitHubAccountModel
    let update: UpdateModel
    /// Settings → Terminals (N275): the history switch, and the running helper compared with the one in the app.
    private(set) var restoreHistory = true
    private(set) var questionMode = AgentQuestionMode.pmCritical
    private(set) var userLanguage = QuestionSettings.systemLanguage
    private(set) var helper: HelperState = .unknown
    /// Agent sessions and the user's shells in the running helper (the restart is refused with an agent running, and names the shells).
    private(set) var agentSessions = 0
    private(set) var shellCount = 0
    private(set) var terminalError: String?
    enum HelperState: Equatable { case unknown, notRunning, current, old(started: Date?) }
    var autopilotFolder: URL? { extras.autopilotStore?.folder }
    /// The category shown on the right; the last one is remembered.
    private(set) var category: SettingsCategory = .general
    /// The current category's "Advanced" part is open.
    var advancedOpen = false
    /// The sidebar's search field; while it has text the sidebar lists the matching settings.
    var query = ""
    var results: [SettingsItem] { SettingsItem.matching(query) }
    /// How many agents and worktrees outlived their card (the Clean up… list), counted when Agents & Team opens; nil before (N340).
    private(set) var leftovers: Int?

    static let categoryKey = "settings.category"

    // MARK: status lines (N340)

    /// Counts the leftovers once (the page opening), not on every poll.
    func countLeftovers(_ scan: () async -> Int?) async { leftovers = await scan() }

    /// The Clean up row's hint.
    static func cleanupHint(_ count: Int?) -> String {
        switch count {
        case nil: "Agents and worktrees that outlived their card."
        case 0?: "nothing to clean up"
        case let n?: "\(n) outlived their card"
        }
    }

    enum UsageTone: Equatable { case go, wait, stop }

    /// The plan usage bar: green below the limit, `wait` within 10 points of it, `stop` at or above it. A switched-off limit counts as 100.
    static func usageTone(percent: Double, limit: Int?) -> UsageTone {
        let limit = Double(limit ?? 100)
        if percent >= limit { return .stop }
        return percent >= limit - 10 ? .wait : .go
    }

    /// "42% / 90%", "42%" without a limit, "unknown" without data.
    static func usageValue(percent: Double?, limit: Int?) -> String {
        guard let percent else { return "unknown" }
        let p = "\(Int(percent.rounded()))%"
        return limit.map { "\(p) / \($0)%" } ?? p
    }

    /// "resets 16:40" today, "resets Saturday 10:00" on another day.
    static func resetHint(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEEE HH:mm"
        return "resets \(f.string(from: date))"
    }

    /// The Keep awake card: "2 agents are working · on power adapter" / "· on battery 64%"; no power part on a Mac without a battery.
    static func awakeLine(agents: Int, power: PowerSnapshot) -> String {
        let who = switch agents { case 0: "No agent is working"; case 1: "1 agent is working"; default: "\(agents) agents are working" }
        guard power.hasBattery else { return who }
        return who + " · " + (power.onBattery ? "on battery" + (power.percent.map { " \($0)%" } ?? "") : "on power adapter")
    }

    /// The Setup check pill: "All 6 in place" (go), "2 missing" (wait), "1 unclear" (wait); nil before the first check.
    static func setupSummary(_ items: [SetupItem]) -> (text: String, ok: Bool)? {
        guard !items.isEmpty else { return nil }
        let missing = items.filter { $0.state == .missing }.count, unsure = items.filter { $0.state == .unsure }.count
        if missing > 0 { return ("\(missing) missing", false) }
        if unsure > 0 { return ("\(unsure) unclear", false) }
        return ("All \(items.count) in place", true)
    }

    /// "1.0 Beta 1 (build 268)" → ("1.0 Beta 1", "268").
    static func splitVersion(_ version: String) -> (name: String, build: String?) {
        guard let r = version.range(of: #" \(build ([^)]+)\)$"#, options: .regularExpression) else { return (version, nil) }
        return (String(version[..<r.lowerBound]), String(version[r].dropFirst(8).dropLast()))
    }

    static let toolNames = ["claude"]

    @ObservationIgnored private let extras: SettingsExtras
    @ObservationIgnored private var script: URL?
    @ObservationIgnored private let git: CommandRunner
    @ObservationIgnored private let release: @Sendable (URL, [String]) async throws -> ScriptResult
    @ObservationIgnored private let appURL: URL
    @ObservationIgnored private let processID: Int32
    @ObservationIgnored private let launch: (URL, [String]) throws -> Void
    @ObservationIgnored private let gitExecutable = URL(fileURLWithPath: "/usr/bin/git")

    static let relaunchScriptName = "relaunch-app.sh"

    init(settings: AppSettings, settingsURL: URL, stableDir: URL, signingConfigured: Bool, git: CommandRunner,
         release: @escaping @Sendable (URL, [String]) async throws -> ScriptResult,
         appURL: URL, processID: Int32, launch: @escaping (URL, [String]) throws -> Void, extras: SettingsExtras = SettingsExtras()) {
        self.extras = extras
        appVersion = extras.appVersion; actionLogURL = extras.actionLogURL; rolesDir = extras.rolesDir; github = extras.github ?? GitHubAccountModel()
        update = extras.update ?? UpdateModel.live(defaults: extras.defaults)
        category = extras.defaults.string(forKey: Self.categoryKey).flatMap(SettingsCategory.init(rawValue:)) ?? .general
        openAtLogin = extras.loginItem.isEnabled
        restoreHistory = TerminalSettings.restoreHistory(extras.defaults)
        questionMode = QuestionSettings.mode(extras.defaults); userLanguage = QuestionSettings.language(extras.defaults)
        autopilotDefaults = extras.autopilotStore?.loadDefaults() ?? AutopilotPolicy()
        scriptsDir = settings.scriptsDir; problems = settings.problems; appearance = AppTheme.current   // what is on screen (a flow rebuilt from older settings must not undo a choice)
        script = settings.fileURL(named: Self.scriptName)
        self.settingsURL = settingsURL; self.stableDir = stableDir; self.signingConfigured = signingConfigured
        self.git = git; self.release = release
        self.appURL = appURL; self.processID = processID; self.launch = launch
    }

    /// Settings arriving after the flow was built (the window reopened on Settings before `reload()` read them); `ref` is kept, `load()` re-reads the tags.
    func apply(_ settings: AppSettings) {
        scriptsDir = settings.scriptsDir; problems = settings.problems
        script = settings.fileURL(named: Self.scriptName)
    }

    /// Opens a category (the sidebar, or another screen sending the user to "Settings → Keep awake"), with its Advanced part closed.
    func show(_ category: SettingsCategory) {
        if category != self.category { advancedOpen = false }
        self.category = category
        extras.defaults.set(category.rawValue, forKey: Self.categoryKey)
    }

    /// Opens the category a search result is in, and its Advanced part when the setting is there; the search ends.
    func show(_ item: SettingsItem) {
        show(item.category)
        advancedOpen = item.isAdvanced
        query = ""
    }

    func tool(_ name: String) -> InstalledTool? { tools.first { $0.name == name } }

    func setOpenAtLogin(_ on: Bool) {
        do { try extras.loginItem.setEnabled(on); loginError = nil }
        catch { loginError = "Could not change Open at login: \(error.localizedDescription)" }
        openAtLogin = extras.loginItem.isEnabled
    }

    /// Shows the theme at once (`AppTheme.current` and the window look) and saves it; a file that cannot be written leaves a message.
    func setAppearance(_ theme: AppTheme) {
        appearance = theme
        AppTheme.apply(theme)
        NotificationCenter.default.post(name: TerminalAppearance.themeChanged, object: nil)
        do { try AppSettingsStore.update(settingsURL) { $0["appearance"] = theme.rawValue }; appearanceError = nil }
        catch { appearanceError = "The appearance is used now but was not saved: \(error.localizedDescription)" }
    }

    func setRestoreHistory(_ on: Bool) {
        extras.defaults.set(on, forKey: TerminalSettings.restoreHistoryKey)
        restoreHistory = on
    }

    func setQuestionMode(_ mode: AgentQuestionMode) {
        extras.defaults.set(mode.rawValue, forKey: QuestionSettings.modeKey)
        questionMode = mode
    }

    /// Empty goes back to the system language.
    func setUserLanguage(_ name: String) {
        let own = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if own.isEmpty { extras.defaults.removeObject(forKey: QuestionSettings.languageKey) } else { extras.defaults.set(own, forKey: QuestionSettings.languageKey) }
        userLanguage = QuestionSettings.language(extras.defaults)
    }

    func deleteSavedHistory() async {
        await extras.terminal()?.forgetAllHistory()
    }

    /// Asks the running helper who it is and what it holds.
    func refreshHelper() async {
        guard let client = extras.terminal(), let info = await client.helperInfo() else { helper = .notRunning; return }
        helper = info.isOld(bundled: extras.bundledHelperDate ?? HelperInfo.bundledDate()) ? .old(started: info.started) : .current
        let sessions = (try? await client.list()) ?? []
        shellCount = sessions.filter { $0.alive && TerminalShells.isUserShell($0.id) }.count
        agentSessions = sessions.filter { $0.alive && !TerminalShells.isUserShell($0.id) }.count
    }

    /// Only an old helper with no agent session in it.
    var canRestartHelper: Bool { if case .old = helper { agentSessions == 0 } else { false } }

    /// The question before the restart: how many shells close.
    var restartQuestion: String {
        let shells = shellCount == 0 ? "No shell is open." : "\(shellCount) open \(shellCount == 1 ? "shell" : "shells") will close; their text will not come back this time, from then on it will."
        return "Restart the terminal helper? " + shells
    }

    func restartHelper() async {
        guard canRestartHelper, let client = extras.terminal() else { return }
        await refreshHelper()   // an agent may have started since the page was drawn
        guard canRestartHelper else { return }
        do { try await client.restartHelper(); terminalError = nil } catch { terminalError = "Could not restart the helper: \(error.localizedDescription)" }
        await refreshHelper()
    }

    func saveAutopilotDefaults(_ policy: AutopilotPolicy) {
        guard let store = extras.autopilotStore else { return }
        do { try store.saveDefaults(policy); defaultsError = nil; autopilotDefaults = store.loadDefaults() }
        catch { defaultsError = "The defaults could not be saved: \(error.localizedDescription)" }
    }

    /// A text for a bug report: versions and paths only. No environment, no logins, no file contents.
    var diagnostics: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func short(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
        var lines = ["Tentacl Crew \(appVersion)", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "stable: \(stableVersion ?? "not installed")", "scripts folder: \(scriptsDir.map { short($0.path) } ?? "not set")",
                     "settings file: \(short(settingsURL.path))", "terminal: Tentacl Crew (tentacld)", "signing file: \(signingConfigured ? "yes" : "no (ad hoc)")"]
        for name in Self.toolNames {
            if let t = tool(name) { lines.append("\(name): \(short(t.path)) · \(t.version)") } else { lines.append("\(name): not found") }
        }
        return lines.joined(separator: "\n")
    }

    var signingHint: String {
        signingConfigured
            ? "app/Signing.local.xcconfig is there: the installed app keeps its identity, so macOS asks for folder access only once."
            : "No app/Signing.local.xcconfig: the installed app is signed ad hoc, so macOS asks for folder access again after every update (README, Code signing)."
    }

    var message: String? {
        guard phase == .done else { return nil }
        return canRelaunch ? "Relaunch now to use it, or quit and reopen Tentacl Crew yourself." : "Quit and reopen Tentacl Crew to use it."
    }

    /// The relaunch script: the one in the freshly installed stable checkout, else the one next to the other scripts.
    private var relaunchScript: URL? {
        let candidates = [stableDir.appendingPathComponent("scripts"), scriptsDir].compactMap { $0 }.map { $0.appendingPathComponent(Self.relaunchScriptName) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Offered only after a successful update, when the installed app and the script are there.
    var canRelaunch: Bool {
        phase == .done && relaunchScript != nil && FileManager.default.fileExists(atPath: appURL.path)
    }

    /// Starts the relaunch script detached, then closes open sheets (they would block quitting) and quits. If the script cannot start, the panel stays open.
    func relaunch(closeSheets: () -> Void, quit: () -> Void) {
        guard canRelaunch, let relaunchScript else { return }
        closeSheets()
        do { try launch(relaunchScript, [appURL.path, String(processID)]) } catch { phase = .failed("Could not start the relaunch: \(error.localizedDescription)"); return }
        quit()
    }

    /// Newest first: v* above stable-*; a release above its betas (v1.0 > v1.0-beta.9 > v1.0-beta.1); otherwise numeric.
    static func isNewer(_ a: String, _ b: String) -> Bool {
        let va = a.hasPrefix("v"), vb = b.hasPrefix("v")
        if va != vb { return va }
        let baseA = a.split(separator: "-", maxSplits: 1)[0], baseB = b.split(separator: "-", maxSplits: 1)[0]
        if va, baseA == baseB, (a == baseA) != (b == baseB) { return a == baseA }
        return a.compare(b, options: .numeric) == .orderedDescending
    }

    /// A tag as people read it: v1.0-beta.1 → "Tentacl 1.0 Beta 1", v1.0 → "Tentacl 1.0", stable-252 → "build 252".
    static func tagName(_ tag: String) -> String {
        if tag.hasPrefix("stable-") { return "build \(tag.dropFirst(7))" }
        guard tag.hasPrefix("v") else { return tag }
        let parts = tag.dropFirst().components(separatedBy: "-beta.")
        return "Tentacl Crew " + (parts.count == 2 ? "\(parts[0]) Beta \(parts[1])" : parts[0])
    }

    /// The exact command the update runs; nil when there is nothing to run.
    var command: String? {
        guard let script, let ref else { return nil }
        return "bash \(script.path) \(ref) --set-scripts-dir \(settingsURL.path)"
    }

    /// Why the update cannot start, or nil when it can.
    var refusal: String? {
        if scriptsDir == nil { return "scriptsDir is not set, so there is nothing to run." }
        if script == nil { return "\(Self.scriptName) is not in \(scriptsDir?.path ?? "scriptsDir")." }
        if tags.isEmpty { return "There is no release tag yet. Create one in the development repository (git tag v1.0-beta.1)." }
        guard let ref else { return "Choose a tag first." }
        if !tags.contains(ref) { return "\(ref) is not a release or stable-* tag of the development repository." }
        if phase == .working { return "An update is already running." }
        return nil
    }

    var canUpdate: Bool { refusal == nil }

    /// The development repository (with the release scripts) is on this Mac: "Update stable…" and the stable version make sense. Public users do not have it.
    var hasSourceBuild: Bool { script != nil }

    /// Reads the tags of the development repository (the checkout the scripts are in) and the commit of the stable checkout.
    func load() async {
        openAtLogin = extras.loginItem.isEnabled
        await refreshHelper()
        var found: [InstalledTool] = []
        for name in Self.toolNames { if let t = await extras.toolProbe(name) { found.append(t) } }
        tools = found
        if let scriptsDir {
            let repo = scriptsDir.deletingLastPathComponent().path
            let found = await lines(["-C", repo, "tag", "--list", "v[0-9]*", "stable-*"])
            tags = found.sorted(by: Self.isNewer)
        } else { tags = [] }
        if ref == nil || !tags.contains(ref ?? "") { ref = tags.first }
        let head = await lines(["-C", stableDir.path, "rev-parse", "--short", "HEAD"]).first
        if let head {
            let tag = await lines(["-C", stableDir.path, "tag", "--points-at", "HEAD", "--list", "v[0-9]*", "stable-*"]).sorted(by: Self.isNewer).first
            stableVersion = tag.map { "\(head) · \(Self.tagName($0))" } ?? head
        } else { stableVersion = nil }
    }

    func requestUpdate() { if canUpdate { phase = .confirming } }
    func cancel() { if phase == .confirming { phase = .idle } }

    /// Runs the update. Only after `requestUpdate()`; anything else does nothing.
    func confirm() async {
        guard phase == .confirming, canUpdate, let script, let ref else { return }
        phase = .working
        do {
            let result = try await release(script, [ref, "--set-scripts-dir", settingsURL.path])
            if result.status == 0 { phase = .done; await load() }
            else {
                let text = result.stderr.isEmpty ? result.stdout : result.stderr
                let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "the script failed"
                phase = .failed(last)
            }
        } catch { phase = .failed("\(error)") }
    }

    private func lines(_ arguments: [String]) async -> [String] {
        guard let data = try? await git.run(gitExecutable, arguments) else { return [] }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension AppTheme {
    /// Makes `theme` the app's look: the `Tok` colours read `current`, the windows and sheets take the macOS look (nil = follow the system).
    @MainActor static func apply(_ theme: AppTheme) {
        current = theme
        NSApplication.shared.appearance = theme.appearance
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .midnight: "Midnight"
        }
    }
}
