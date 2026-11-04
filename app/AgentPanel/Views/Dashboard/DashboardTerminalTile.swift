import SwiftUI

/// N359: the terminal the Terminal tile shows, saved per project: its pane and the name it had, so an ended one can be named.
struct DashboardTerminalChoice: Codable, Equatable {
    var pane: String
    var label: String
}

/// One entry of the tile's picker: the PM or a running agent of the open project (never the user's own shells).
struct DashboardTerminalOption: Identifiable, Equatable {
    let pane: String
    /// "PM", the card id, or "session".
    let label: String
    let title: String
    let isPM: Bool
    var id: String { pane }

    /// What the picker and the ended note say: "PM", "N359 · Terminal widget", "session · claude".
    var name: String { isPM || title.isEmpty ? label : "\(label) · \(title)" }
    var choice: DashboardTerminalChoice { DashboardTerminalChoice(pane: pane, label: name) }
}

/// What the tile shows: nothing to show, the chosen terminal ended, or a terminal.
enum DashboardTerminalShown: Equatable {
    case empty
    case ended(String)
    case showing(DashboardTerminalOption)
}

enum DashboardTerminalPick {
    /// The PM first, then the card agents and other agent sessions in the Terminals screen's order; the user's shells are left out.
    static func options(agents: [AgentStatus], pmPane: String?, card: (AgentStatus) -> TaskCard?) -> [DashboardTerminalOption] {
        TerminalTabs.make(agents: agents.filter { !TerminalShells.isUserShell($0.paneID) }, pmPane: pmPane, card: card, phase: { _ in nil }, questions: [])
            .map { DashboardTerminalOption(pane: $0.paneID, label: $0.label, title: $0.title, isPM: $0.kind == .pm) }
    }

    /// The saved terminal while it runs, "ended" once it is gone; with nothing saved the PM, else the first agent.
    static func shown(saved: DashboardTerminalChoice?, options: [DashboardTerminalOption]) -> DashboardTerminalShown {
        if let saved {
            if let o = options.first(where: { $0.pane == saved.pane }) { return .showing(o) }
            return .ended(saved.label)
        }
        return (options.first(where: \.isPM) ?? options.first).map { .showing($0) } ?? .empty
    }

    static let emptyText = "No agents are running. Start the PM or a task and its terminal can show here."
    static func endedText(_ label: String) -> String { "\(label) ended. Pick another terminal above." }
}

/// The Terminal tile (N359): a picker in its top row and the chosen terminal below it, the same live, typeable terminal as the
/// Terminals screen. Its session comes from `PanelModel.liveTerminals`: the Dashboard and the Terminals screen are never on screen
/// together, so the one view (with its screen) moves between them and resizes with the tile like a pane.
struct DashboardTerminalTile: View {
    @Bindable var model: PanelModel
    /// nil: the choice lives only in this view (snapshots).
    let store: DashboardLayoutStore?
    /// The tentacld the live terminal attaches to; nil shows the polled screen text.
    let client: TentacldClient?
    var onOpenTerminals: () -> Void = {}
    @State private var picked: DashboardTerminalChoice?
    @State private var pickedProject: String?

    private var projectID: String { model.selectedProjectID ?? "" }
    private var agents: [AgentStatus] { if case .available(let list) = model.visibleAgents { list } else { [] } }
    private var options: [DashboardTerminalOption] {
        DashboardTerminalPick.options(agents: agents, pmPane: model.selectedProjectID.flatMap { model.pmAgent(forProject: $0)?.paneID }, card: { model.card(of: $0) })
    }
    private var saved: DashboardTerminalChoice? { pickedProject == projectID ? picked : store?.terminalChoice(project: projectID) }

    var body: some View {
        let options = options
        let shown = DashboardTerminalPick.shown(saved: saved, options: options)
        DashboardTileShell(title: "Terminal", link: options.isEmpty ? nil : "Open in Terminals", linkHelp: "Open the Terminals screen", onLink: onOpenTerminals) {
            if !options.isEmpty { picker(options, shown: shown) }
            switch shown {
            case .empty: note(DashboardTerminalPick.emptyText)
            case .ended(let label): note(DashboardTerminalPick.endedText(label))
            case .showing(let o):
                DashboardTerminalScreen(model: model, pane: o.pane, name: o.name, client: client).id(o.pane)
            }
        }
        .onChange(of: model.agents) { _, _ in
            // As the Terminals screen does: a terminal gone from the project lets its session go.
            guard case .available(let list) = model.visibleAgents else { return }
            model.liveTerminals.keep(Set(list.map(\.paneID)))
        }
    }

    private func picker(_ options: [DashboardTerminalOption], shown: DashboardTerminalShown) -> some View {
        let current: String = { if case .showing(let o) = shown { o.name } else { "Choose a terminal" } }()
        return Menu {
            ForEach(options) { o in
                Button { choose(o.choice) } label: {
                    if case .showing(let s) = shown, s.pane == o.pane { Label(o.name, systemImage: "checkmark") } else { Text(o.name) }
                }
            }
        } label: {
            Text(current).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Tok.ink).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which terminal this tile shows")
        .accessibilityLabel("Terminal shown")
        .accessibilityValue(current)
    }

    private func choose(_ choice: DashboardTerminalChoice) {
        picked = choice; pickedProject = projectID
        store?.setTerminalChoice(choice, project: projectID)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The chosen terminal: the live one when tentacld has it, else its screen text read every few seconds (as a Terminals pane does).
private struct DashboardTerminalScreen: View {
    let model: PanelModel
    let pane: String
    let name: String
    let client: TentacldClient?
    @State private var poller: AgentScreenPoller
    @Environment(\.snapshotMode) private var snapshot

    init(model: PanelModel, pane: String, name: String, client: TentacldClient?) {
        self.model = model; self.pane = pane; self.name = name; self.client = client
        _poller = State(initialValue: AgentScreenPoller(reader: model.makeReader(), target: pane, lines: 200))
    }

    private var live: LiveTerminalSession? { client.map { model.liveTerminals.session(id: pane, client: $0) } }

    var body: some View {
        let look = model.terminalAppearance.appearance
        let t = look.palette
        let live = live
        VStack(alignment: .leading, spacing: 0) {
            if let live, live.isLive, !snapshot {
                LiveTerminalView(session: live).padding(look.paddingPoints).accessibilityLabel("Terminal \(name)")
            } else {
                let style = look.polledText
                if let failure = live?.failure ?? poller.error {
                    Text(failure).font(Tok.Font.small).foregroundStyle(Tok.wait).padding(.horizontal, Tok.Space.m).padding(.top, Tok.Space.s)
                }
                Color.clear.overlay(alignment: .bottomLeading) {
                    Text(poller.text.isEmpty ? " " : poller.text).font(Font(style.font as CTFont))
                        .foregroundStyle(Color(nsColor: TerminalAppearance.ns(style.foreground))).padding(style.padding)
                }
                .clipped()
            }
            if let code = live?.exitCode {
                Text(LiveTerminalSession.exitText(code)).font(Tok.Font.small).foregroundStyle(t.dim)
                    .padding(.horizontal, Tok.Space.m).frame(height: 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.bg, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.lineColor, lineWidth: 1))
        .onAppear { if !snapshot { live?.appear(); if live?.isLive != true { poller.appear() } } }
        .onDisappear { poller.disappear() }
        .onChange(of: live?.isLive) { _, now in if now == true { poller.disappear() } else if !snapshot { poller.appear() } }
    }
}
