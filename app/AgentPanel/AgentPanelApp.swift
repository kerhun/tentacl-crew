import SwiftUI
import AppKit

@main
struct AgentPanelApp: App {
    private static let arguments = ProcessInfo.processInfo.arguments
    private static let demo = arguments.contains("--demo")
    private static var snapshotPath: String? {
        guard let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = PanelModel.uiTestFolder.map { PanelModel.isolatedForUITest(folder: $0) } ?? (PanelModel.runsUnderXCTest ? PanelModel.isolatedForTests() : AgentPanelApp.demo
        ? DemoSupport.makeUnloadedModel()
        : PanelModel(settingsURL: ProjectStore.defaultSettingsURL, makeTerminal: { AgentPanelApp.terminal }, opener: WorkspaceURLOpener(),
                     makeCommander: { AgentPanelApp.terminal }, seedsRoles: true, makeReader: { AgentPanelApp.terminal }, makeKeySender: { AgentPanelApp.terminal },
                     claudeTrust: .standard, autopilotStore: AutopilotStore(folder: AutopilotStore.defaultFolder),
                     terminalServer: TentacldLauncher()))
    /// The tours (N311), shared by the window and the Help menu. They offer themselves only in the real app.
    @State private var tutorial = TutorialModel(store: TutorialStore(defaults: .standard),
                                                autoOffer: !AgentPanelApp.demo && !PanelModel.runsUnderXCTest && PanelModel.uiTestFolder == nil)
    /// The terminal every agent runs in: Tentacl's own, through tentacld.
    private static let terminal = TentaclBackend()

    /// `--appearance light` (demo and snapshots) picks the theme without a settings file.
    private static var appearanceArgument: AppTheme? {
        guard let i = arguments.firstIndex(of: "--appearance"), i + 1 < arguments.count else { return nil }
        return AppTheme(rawValue: arguments[i + 1])
    }

    init() {
        // The saved theme before the first frame (N312); tests keep Dark.
        if let theme = Self.appearanceArgument {
            AppTheme.apply(theme)
        } else if !Self.demo, PanelModel.uiTestFolder == nil, !PanelModel.runsUnderXCTest {
            AppTheme.apply(AppSettingsStore.load(settingsURL: ProjectStore.defaultSettingsURL).appearance)
        }
        // `Tentacl --demo --snapshot out.png` writes the demo window as a PNG and quits; it needs no visible window.
        if let path = Self.snapshotPath {
            Task { @MainActor in
                let demoModel = await DemoSupport.makeModel()
                if let data = SnapshotRenderer.render(model: demoModel, size: CGSize(width: 1440, height: 860)) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// The floating question panel (N373); not under tests or snapshots.
    @MainActor private static var questionPanel: QuestionPanelController?

    /// `--demo --question-panel-sample` feeds the panel one sample question (screenshots; the setting still decides).
    @MainActor private func startQuestionPanel() {
        guard Self.questionPanel == nil, !PanelModel.runsUnderXCTest, Self.snapshotPath == nil else { return }
        let model = model
        let sample = Self.demo && Self.arguments.contains("--question-panel-sample")
        let controller = QuestionPanelController { sample ? Self.sampleItems(model) : QuestionPanelController.items(of: model) }
        controller.start(model: model)
        Self.questionPanel = controller
    }

    @MainActor private static func sampleItems(_ model: PanelModel) -> [QuestionPanelItem] {
        let options = ["Keep Claude required (Recommended)", "Make Claude optional"].enumerated().map { QuestionOption(number: $0.offset + 1, label: $0.element, detail: "", isSpecial: false) }
        let asks = [("ui_dev", "N367", "Should Claude become optional for a Codex-only user, or stay required for the decider?", 360.0),
                    ("dev", "N368", "Restart the PM with the hand-off now?", 60.0)]
        return asks.map { label, card, text, ago in
            let q = PendingQuestion(paneID: "sample-" + card, sessionID: nil, agentLabel: label, cardID: card,
                                    question: AgentQuestion(kind: .choice, title: "", text: text, options: options))
            return QuestionPanelItem(question: q, projectID: model.selectedProjectID ?? "", projectName: "agent-panel", inbox: model.inbox,
                                     askedAt: Date().addingTimeInterval(-ago), pmPane: "sample-pm")
        }
    }

    var body: some Scene {
        Window("Tentacl Crew", id: "main") {
            ShellView(model: model, tutorial: tutorial)
                .frame(minWidth: 1100, minHeight: 600)
                .task {
                    guard Self.snapshotPath == nil else { return }
                    model.startPolling()   // first: even if the terminal hangs, the task list keeps refreshing
                    startQuestionPanel()
                    await model.reload()
                    if !Self.demo, !PanelModel.runsUnderXCTest, await model.setup.checkOnLaunch() { model.setup.open() }
                    tutorial.offerFirstLaunch(noProjects: model.projects.isEmpty, sheetOpen: model.setup.isOpen)
                    if Self.demo, model.selectedCardID == nil { model.selectedCardID = "A1" }
                }
        }
        .defaultSize(width: 1440, height: 860)
        .commands { TutorialCommands(tutorial: tutorial) }
    }
}

/// Help › Tour This Screen ⌘?, All Tours…, Resume <tour> Tour (only while one is in progress), Reset Tours… (N311, artboard C2).
struct TutorialCommands: Commands {
    let tutorial: TutorialModel

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Tour This Screen") { if let id = tutorial.tourHere { tutorial.open(id) } }
                .keyboardShortcut("?", modifiers: .command)
                .disabled(tutorial.tourHere == nil)
            Button("All Tours…") { tutorial.popoverOpen = true }
            if let resume = tutorial.resumable { Button("Resume \(resume.title) Tour") { tutorial.open(resume) } }
            Divider()
            Button("Reset Tours…") { tutorial.confirmingReset = true }
        }
    }
}
