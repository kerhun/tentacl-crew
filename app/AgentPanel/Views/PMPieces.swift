import SwiftUI

/// Agents whose task waits on someone: on you, on the PM, or because it is blocked.
func agentsWaitingCount(phases: [TaskPhase?]) -> Int {
    phases.filter { $0 == .waitingForYou || $0 == .pmHandling || $0 == .blocked }.count
}

/// The Dashboard's card while a round waits for "Start round".
struct RoundWaitingCard: View {
    let ids: [String]
    /// Reopens the Round sheet (Cancel there only hides it).
    var onOpen: () -> Void = {}

    static func title(_ ids: [String]) -> String { "Round waiting: " + ids.joined(separator: ", ") }

    var body: some View {
        Button(action: onOpen) { content }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Round sheet")
    }

    private var content: some View {
        HStack(spacing: Tok.Space.s) {
            // A round to start is green in Waiting for you (N182).
            Circle().fill(WaitingTint.start.color).frame(width: 8, height: 8).overlay { Circle().stroke(WaitingTint.start.color.opacity(0.25), lineWidth: 3) }
            Text(Self.title(ids)).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(2)
            Spacer(minLength: 0)
            WaitingChip(text: "Open the Round sheet", tint: .start, dot: false)
        }
        .padding(Tok.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Why Start PM / Resume PM are off (N328): the line under the PM bar and the buttons' help. "Start anyway" only for the usage gate.
struct PMStartBlock: Equatable {
    let text: String
    var offersStartAnyway = false
    /// Not signed in to this tool: the line offers "Sign in to …" (N329).
    var signInTool: AgentTool? = nil

    static let busyHelp = "Another action is running; wait until it finishes."

    /// The setup reason first, then the usage gate, then the safe point (the order of `startDisabledReason`). Nil while busy: the
    /// command bar already says what runs.
    static func make(setupReason: String?, signInReason: String? = nil, gateReason: String?, safePointReason: String?, busy: Bool) -> PMStartBlock? {
        if busy { return nil }
        if let setupReason { return PMStartBlock(text: setupReason) }
        if let signInReason { return PMStartBlock(text: signInReason, signInTool: .claude) }
        if let gateReason { return PMStartBlock(text: "Starting is paused: \(gateReason.prefix(1).lowercased() + gateReason.dropFirst()).", offersStartAnyway: true) }
        if let safePointReason { return PMStartBlock(text: safePointReason) }
        return nil
    }
}

/// The short line with the reason under the PM bar, with "Start anyway" for the usage gate.
struct PMStartBlockedLine: View {
    let block: PMStartBlock
    var onStartAnyway: () -> Void = {}
    var signingIn = false
    var onSignIn: (AgentTool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: Tok.Space.s) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Tok.ask)
            Text(block.text).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let tool = block.signInTool {
                Button("Sign in to \(SignInGate.name(tool))") { onSignIn(tool) }.disabled(signingIn)
                    .help("Opens `\(SignInGate.command(tool).joined(separator: " "))` in Tentacl Crew's terminal; Start works again once it succeeds")
            }
            if block.offersStartAnyway {
                Button("Start anyway", action: onStartAnyway).help("Lifts the usage gate until the window that holds it resets (same as Settings)")
            }
        }
        .padding(.horizontal, Tok.Space.m).padding(.bottom, Tok.Space.s)
        .accessibilityElement(children: .contain)
    }
}

/// The warning for a PM that runs outside its project's folder, with the action that starts a new one in the right folder.
struct PMOutsideWarning: View {
    let folder: String
    let repo: String
    var canStart = true
    /// The help of the off button: why it is off (N328).
    var offHelp: String? = nil
    var onStart: () -> Void = {}

    static func text(folder: String, repo: String) -> String {
        "This PM runs in \(folder), not in \(repo). Its history and memory go to the other project."
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tok.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tok.ask)
            Text(Self.text(folder: folder, repo: repo)).font(Tok.Font.small).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Start a PM here", action: onStart).disabled(!canStart).help(canStart ? "Starts a new PM in the project folder and uses it instead" : offHelp ?? "")
        }
        .padding(Tok.Space.s)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, Tok.Space.m)
        .accessibilityElement(children: .contain)
    }
}

// MARK: N346: the menus drawn by the Dashboard (the widget menu, the chat's ⋯)

/// One line of a menu drawn by the panel (so a snapshot shows it open): an action, a checkmark item, a section label or a divider.
struct PopMenuItem: Identifiable {
    enum Kind: Equatable { case action, check(Bool), section, divider }
    let id: String
    var title = ""
    var icon: String? = nil
    var kind: Kind = .action
    var destructive = false
    var enabled = true
    var help: String? = nil
    /// N345: a small picture drawn in place of the icon (a layout's grid), and a VoiceOver label other than the title.
    var thumbnail: AnyView? = nil
    var voiceLabel: String? = nil
    /// N356: an optional small second line under the title (a layout's widgets).
    var subtitle: String? = nil
    var action: () -> Void = {}

    static func divider(_ id: String) -> PopMenuItem { PopMenuItem(id: id, kind: .divider) }
    static func section(_ title: String) -> PopMenuItem { PopMenuItem(id: "section." + title, title: title, kind: .section) }
}

/// Where each panel-drawn menu's button is ("widgets", "chat"), so the open menu is drawn under it above the tiles.
struct PopMenuAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}

/// The open menu: the tile ⋯ menu's look (N343). A pick runs its action and closes the menu.
struct PopMenuView: View {
    let label: String
    let items: [PopMenuItem]
    let onClose: () -> Void

    static let width: CGFloat = 220
    /// N356: a menu with subtitled rows (the widget menu's layouts) is wider, so the second line is not cut.
    static let wideWidth: CGFloat = 290
    static func width(for items: [PopMenuItem]) -> CGFloat { items.contains { $0.subtitle != nil } ? wideWidth : width }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(items) { item in row(item) }
        }
        .padding(5)
        .frame(width: Self.width(for: items))
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tok.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 15, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func row(_ item: PopMenuItem) -> some View {
        switch item.kind {
        case .divider:
            Rectangle().fill(Tok.line).frame(height: 1).padding(.horizontal, 2).padding(.vertical, 4).accessibilityHidden(true)
        case .section:
            Text(item.title.uppercased()).font(.system(size: 10.5)).kerning(0.4).foregroundStyle(Tok.ink3)
                .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 2).accessibilityAddTraits(.isHeader)
        case .action, .check:
            let checked = item.kind == .check(true)
            let tint = item.destructive ? Tok.stop : Tok.ink
            Button { item.action(); onClose() } label: {
                HStack(spacing: 9) {
                    if let thumbnail = item.thumbnail {
                        thumbnail
                    } else {
                        Image(systemName: item.icon ?? "circle").font(.system(size: 12)).foregroundStyle(item.destructive ? Tok.stop : Tok.ink2)
                            .frame(width: 16).opacity(item.icon == nil ? 0 : 1)
                    }
                    if let subtitle = item.subtitle {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12.5)).foregroundStyle(tint).lineLimit(1)
                            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Tok.ink3).lineLimit(1)
                        }
                    } else {
                        Text(item.title).font(.system(size: 12.5)).foregroundStyle(tint).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.work) }
                }
                .padding(.horizontal, 9).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopMenuRowStyle())
            .disabled(!item.enabled)
            .opacity(item.enabled ? 1 : 0.4)
            .help(item.help ?? "")
            .accessibilityLabel(item.voiceLabel ?? item.title)
            .accessibilityAddTraits(checked ? .isSelected : [])
        }
    }
}

/// A menu row: highlighted while hovered or pressed.
private struct PopMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .background(enabled && (hovered || configuration.isPressed) ? Tok.line : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}

// MARK: N346: the PM chat's one header row

/// The Dashboard chat's header (N346): the PM's avatar with its state dot, name and "working · project", unread and waiting dots,
/// the authority chip, then Only chat, search, Preview and ⋯ while a PM runs.
struct PMChatHeader: View {
    let status: PMStatus
    var name = "PM"
    var role: String? = nil
    var projectName = ""
    var unread = false
    var waiting = false
    var waitingHelp = "The PM is waiting for you"
    var authority = "Authority off"
    var authorityOn = false
    var onAuthority: () -> Void = {}
    var conversationOnly = false
    var onConversationOnly: () -> Void = {}
    var onSearch: () -> Void = {}
    /// The Preview icon (N265): nil hides it (no page to show), true shows it selected (the Preview is open).
    var previewShown: Bool? = nil
    var onPreview: () -> Void = {}
    var menuOpen = false
    var onMenu: () -> Void = {}

    /// The same help the Dashboard strip's chip had.
    static let authorityHelp = "Change PM authority in the Autopilot rules"
    static let menuAnchor = "chat"

    /// Whether the Preview icon is there, and selected, for a project with or without a page (N265).
    static func previewIcon(hasPage: Bool, showing: Bool) -> Bool? { hasPage ? showing : nil }

    /// "working · project", "idle · project", "not running · project".
    static func stateLine(_ status: PMStatus, project: String) -> String {
        let state = switch status { case .running: "working"; case .idle: "idle"; case .missing: "not running" }
        return project.isEmpty ? state : "\(state) · \(project)"
    }

    static func color(_ status: PMStatus) -> Color {
        switch status { case .running: Tok.work; case .idle: Tok.go; case .missing: Tok.ink3 }
    }

    /// The Dashboard's "PM authority · 2 of 6 today" / "PM authority · off", shortened for the chip.
    static func authorityText(_ full: String) -> String {
        if full == dashboardAuthorityText(enabled: false, startedToday: 0, perDay: 0) { return "Authority off" }
        return full.replacingOccurrences(of: "PM authority", with: "Authority")
    }

    /// The ⋯ menu. New and Compact need a conversation the panel may restart and no action running; Stop asks first.
    static func menuItems(canRestart: Bool, busy: Bool, returnSends: Bool, compact: Bool = true, onNew: @escaping () -> Void = {}, onCompact: @escaping () -> Void = {},
                          onReturnSends: @escaping (Bool) -> Void = { _ in }, onRules: @escaping () -> Void = {}, onStop: @escaping () -> Void = {}) -> [PopMenuItem] {
        let restartOff: String? = busy ? PMStartBlock.busyHelp : (canRestart ? nil : "An agent on a task card is restarted with its card.")
        return [
            PopMenuItem(id: "new", title: "New conversation…", icon: "plus.bubble", enabled: restartOff == nil,
                        help: restartOff ?? "Start the PM on a fresh conversation (with a hand-off note)", action: onNew),
        ] + (compact ? [PopMenuItem(id: "compact", title: "Compact conversation…", icon: "text.line.last.and.arrowtriangle.forward", enabled: restartOff == nil,
                        help: restartOff ?? "Keep one summarised conversation (/compact)", action: onCompact)] : []) + [
            .divider("d1"),
            PopMenuItem(id: "return", title: "Return sends", icon: "return", kind: .check(returnSends),
                        help: "On: Return sends and Shift-Return starts a new line. Off: Return starts a new line. ⌘Return always sends.",
                        action: { onReturnSends(!returnSends) }),
            PopMenuItem(id: "rules", title: "PM authority rules…", icon: "star", help: "Open the Autopilot rules", action: onRules),
            .divider("d2"),
            PopMenuItem(id: "stop", title: "Stop PM…", icon: "stop", destructive: true, help: "Closes the PM session (asks first)", action: onStop),
        ]
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                PMAvatar(status: status)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Tok.ink)
                        if let role { Text(role).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                    }
                    Text(Self.stateLine(status, project: projectName)).font(.system(size: 11.5)).foregroundStyle(Tok.ink3)
                }
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .tutorialAnchor(.pmState)
            .layoutPriority(1)
            if unread { Circle().fill(Tok.work).frame(width: 7, height: 7).help("New reply").accessibilityLabel("New reply") }
            if waiting { Circle().fill(Tok.ask).frame(width: 7, height: 7).help(waitingHelp).accessibilityLabel("Waiting for you") }
            Spacer(minLength: 8)
            Button(action: onAuthority) {
                HStack(spacing: 6) {
                    Circle().fill(authorityOn ? Tok.go : Tok.ink3).frame(width: 7, height: 7)
                    Text(authority).font(.system(size: 11.5)).foregroundStyle(authorityOn ? Tok.ink : Tok.ink2).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 10).frame(height: 24)
                .background(Tok.raise, in: Capsule()).overlay(Capsule().strokeBorder(Tok.line, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).help(Self.authorityHelp)
            .accessibilityLabel("PM authority").accessibilityValue(authority)
            if status != .missing {
                Button(action: onConversationOnly) {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                        Text("Only chat").fixedSize()
                    }
                    .font(.system(size: 11.5)).foregroundStyle(conversationOnly ? Tok.work : Tok.ink3)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(conversationOnly ? Tok.work.opacity(0.14) : .clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(conversationOnly ? Tok.work.opacity(0.35) : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Hide the panel's notes, tool lines and summaries")
                .accessibilityLabel("Only chat").accessibilityValue(conversationOnly ? "on" : "off")
                iconButton("magnifyingglass", help: "Search the conversation (⌘F)", label: "Search the conversation", action: onSearch)
                    .keyboardShortcut("f", modifiers: .command)
            }
            if let previewShown {
                iconButton("macwindow", help: previewShown ? "Back to the chat" : "Show preview (the page from the chat)", label: "Preview", selected: previewShown, action: onPreview)
                    .tutorialAnchor(.previewButton)
            }
            if status != .missing {
                iconButton("ellipsis", help: "More", label: "More", selected: menuOpen, action: onMenu)
                    .accessibilityValue(menuOpen ? "open" : "")
                    .anchorPreference(key: PopMenuAnchors.self, value: .bounds) { [Self.menuAnchor: $0] }
                    .tutorialAnchor(.chatNewConversation)
            }
        }
        // N347: the chat's column: the same side inset and cap as the thread and composer below.
        .frame(maxWidth: ChatThread.readingWidth)
        .padding(.horizontal, CommandBar.inset).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func iconButton(_ symbol: String, help: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Tok.ink : Tok.ink2)
                .frame(width: 28, height: 28).background(selected ? Tok.raise : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The "PM" circle with the state dot (green idle, blue working, grey none).
struct PMAvatar: View {
    let status: PMStatus
    var size: CGFloat = 30

    var body: some View {
        Text("PM").font(.system(size: size * 0.37, weight: .semibold)).foregroundStyle(Tok.ink)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Tok.line, Tok.raise], startPoint: .top, endPoint: .bottom), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(PMChatHeader.color(status)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Tok.pane, lineWidth: 2)).offset(x: 1, y: 1)
            }
            .accessibilityHidden(true)
    }
}

/// The thread area without a PM (N346): Start PM, Resume PM and "Choose a running agent…" by today's rules.
struct PMNoPMState: View {
    var projectName = ""
    var candidates: [AgentStatus] = []
    var label: (AgentStatus) -> String = { $0.title }
    var canStart = true
    /// The help of Start PM / Resume PM while they are off: why (N328).
    var offHelp: String? = nil
    /// Resume PM: nil hides it; false shows it off, with the reason as help.
    var resumeHelp: String? = nil
    var canResume = false
    var onResume: () -> Void = {}
    var onChoose: (AgentStatus) -> Void = { _ in }
    var onStart: () -> Void = {}

    static let text = "Start one in the project folder, or resume the last PM session with its conversation."

    /// What the empty state offers: Start always, Resume when there is a resume help, Choose when an agent could be the PM.
    enum Action: Equatable { case start, resume, choose }
    static func actions(resumeShown: Bool, candidates: Int) -> [Action] {
        [.start] + (resumeShown ? [.resume] : []) + (candidates > 0 ? [.choose] : [])
    }

    /// N347: the full state when it fits; in a short tile a compact one (no avatar, smaller title, less space); if even that is too
    /// tall it scrolls. The sentence always wraps, never cut; the buttons go under each other when one row is too wide.
    var body: some View {
        ViewThatFits(in: .vertical) {
            content(compact: false).padding(20)
            content(compact: true).padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView { content(compact: true).padding(.horizontal, 16).padding(.vertical, 10) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            if !compact { PMAvatar(status: .missing, size: 40) }
            Text(projectName.isEmpty ? "No PM" : "No PM for \(projectName)").font(.system(size: compact ? 13.5 : 15, weight: .semibold)).foregroundStyle(Tok.ink)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(Self.text).font(.system(size: compact ? 12 : 12.5)).foregroundStyle(Tok.ink3).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(spacing: 6) { buttons }
            }
            .padding(.top, compact ? 2 : 4)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var buttons: some View {
                ForEach(Self.actions(resumeShown: resumeHelp != nil, candidates: candidates.count), id: \.self) { action in
                    switch action {
                    case .start:
                        Button("Start PM", action: onStart).buttonStyle(ConfirmButtonStyle()).disabled(!canStart)
                            .help(canStart ? "Starts the project's pm role in the project folder" : offHelp ?? "")
                    case .resume:
                        Button("Resume PM", action: onResume).buttonStyle(PanelButtonStyle()).disabled(!canStart || !canResume)
                            .help(canStart ? resumeHelp ?? "" : offHelp ?? resumeHelp ?? "")
                    case .choose:
                        Menu {
                            ForEach(candidates, id: \.paneID) { agent in Button(label(agent)) { onChoose(agent) } }
                        } label: { Text("Choose a running agent…") }
                        .menuStyle(.button).buttonStyle(PanelButtonStyle()).menuIndicator(.hidden).fixedSize()
                        .help("Uses a running agent as this project's PM")
                    }
                }
    }
}

/// "Stop this agent?" for an agent's Stop button; used by the Dashboard.
struct AgentStopDialog: ViewModifier {
    let model: PanelModel

    func body(content: Content) -> some View {
        content.confirmationDialog("Stop \(model.pendingStop.map { $0.name ?? $0.title } ?? "this agent")?", isPresented: Binding(get: { model.pendingStop != nil }, set: { if !$0 { model.cancelStop() } }), titleVisibility: .visible) {
            Button("Stop", role: .destructive) { if let agent = model.pendingStop { Task { await model.stop(agent) } } }
            Button("Cancel", role: .cancel) { model.cancelStop() }
        } message: {
            Text("This closes its terminal session and ends the session. Work in the project folder stays.")
        }
    }
}

/// "Use <agent> as the PM of <project>?" when that agent is another project's PM; confirming takes it from there.
struct PMChoiceDialog: ViewModifier {
    let model: PanelModel

    func body(content: Content) -> some View {
        content.confirmationDialog("Use \(model.pendingPMChoice.map { $0.agent.name ?? $0.agent.title } ?? "this agent") as the PM here?", isPresented: Binding(get: { model.pendingPMChoice != nil }, set: { if !$0 { model.cancelPMChoice() } }), titleVisibility: .visible) {
            Button("Use as PM") { model.confirmPMChoice() }
            Button("Cancel", role: .cancel) { model.cancelPMChoice() }
        } message: {
            Text("It is the PM of \(model.pendingPMChoice?.fromName ?? "another project") now; that project is left without a PM.")
        }
    }
}

/// A quiet reminder in the PM's chat when its conversation is large (N171). Never restarts by itself.
struct PMContextReminder: View {
    let percent: Int
    var disabled = false
    var onRestart: () -> Void = {}

    static let text = "The PM's conversation is large: restart with hand-off"

    var body: some View {
        HStack(spacing: Tok.Space.s) {
            Image(systemName: "text.badge.minus").foregroundStyle(Tok.ink3)
            Text(Self.text).font(Tok.Font.small).foregroundStyle(Tok.ink2)
            Text("\(percent)% of its context").font(Tok.Font.small).foregroundStyle(Tok.ink3).monospacedDigit()
            Spacer(minLength: 0)
            Button("Restart with hand-off", action: onRestart).buttonStyle(PanelButtonStyle()).disabled(disabled)
                .help("The PM writes a short note, the conversation is cleared and the new one reads the note")
        }
        .padding(.horizontal, Tok.Space.s + 2).padding(.vertical, Tok.Space.xs + 2)
        .background(Tok.raise, in: RoundedRectangle(cornerRadius: Tok.radius))
        .accessibilityElement(children: .combine)
    }
}
