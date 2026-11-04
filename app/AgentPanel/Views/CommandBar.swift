import SwiftUI
import AppKit

/// The chat's header state (N346): searching, Only chat and the New conversation sheet. The Dashboard draws the header outside the
/// command bar and shares this with it; on the Command screen the bar keeps its own.
@MainActor @Observable final class ChatControls {
    var searching = false
    var conversationOnly = false
    var restartOpen = false
    /// The choice the New conversation sheet opens with ("Compact conversation…" opens it on Compact).
    var restartMode: RestartMode = .handoff

    func openRestart(_ mode: RestartMode = .handoff) { restartMode = mode; restartOpen = true }
}

/// Send a message to one of the running agents (usually the PM). The panel checks that the agent is still there before sending.
struct CommandBar: View {
    @Bindable var model: PanelModel
    @State private var chosen: ChosenTarget?
    @State private var lostLabel: String?
    @State private var attachError: String?
    @State private var pasteMonitor: Any?
    /// On: Return sends and Shift-Return starts a new line. Off: Return starts a new line. ⌘Return always sends.
    @AppStorage(CommandBar.returnSendsKey) private var returnSends = false
    @State private var focusRequest = 0
    /// Searching, Conversation only (N291, remembered per project) and the restart sheet: the Dashboard's header shares them (N346).
    @State private var ownControls = ChatControls()
    var controls: ChatControls? = nil
    private var c: ChatControls { controls ?? ownControls }
    /// The thread area without a PM (N346, the Dashboard): shown instead of the thread; the input stays, disabled.
    var noPM: AnyView? = nil
    @State private var query = ""
    @State private var searchFilter = ChatSearch.Filter.all
    @State private var searchIndex = 0
    /// The open question the card shows, and the last digit key for it (N293).
    @State private var questionIndex = 0
    @State private var digit: ChatDigit?
    /// The whole box's height, measured; on the Dashboard it sets how tall the input may grow.
    @State private var boxHeight: Double = 0
    private let attachments = Attachments()
    @State private var active = NSApp?.isActive ?? true
    /// The thread's height; the user drags the bar's top edge or presses the expand button. Kept between launches by the window.
    @Binding var chatHeight: Double
    /// The tallest the thread may get (the column's height minus room for the agents and the input).
    var maxChatHeight: Double = 600
    /// On the Dashboard the conversation takes all the height its card leaves; the height buttons and the drag handle are not shown.
    var fillsHeight = false
    /// False while the Command box is not on screen: a reply that arrives then counts as unread.
    var viewing = true
    /// The Dashboard's conversation: only the project's PM can be addressed.
    var pmOnly = false
    /// Opens a link of the conversation in the Preview beside it (N240); nil leaves every link to the browser.
    var onOpenPreview: ((URL) -> Void)? = nil
    /// How long a done line stays (tests shorten it).
    var doneLineTime: Duration = PanelModel.doneLineTime
    /// Told the size of the composer's key hint (tests check it is never squeezed, N303).
    var onActionsSize: ((CGSize) -> Void)? = nil
    @Environment(\.snapshotMode) private var snapshot

    static let defaultChatHeight: Double = 230
    static let minChatHeight: Double = 120
    static let inputIdentifier = "command-input"
    static let returnSendsKey = "chatReturnSends"

    enum ReturnKey: Equatable { case send, newline, pass }

    /// What Return does in the input. Off leaves every Return to the field (today's behaviour); ⌘Return is the Send button's.
    static func returnKey(returnSends: Bool, modifiers: NSEvent.ModifierFlags) -> ReturnKey {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard returnSends else { return .pass }
        if mods.isEmpty { return .send }
        return mods == .shift ? .newline : .pass
    }

    static func sendHelp(returnSends: Bool) -> String {
        "Send to the selected agent (\(returnSends ? "↵; ⇧↵ for a new line" : "⌘↵"))"
    }

    /// Undo and Edit put the held text back before whatever was typed since.
    static func restoredText(_ held: String, current: String) -> String {
        held.isEmpty ? current : (current.isEmpty ? held : held + "\n" + current)
    }

    static func conversationOnlyKey(project: String) -> String { "chatConversationOnly.\(project)" }

    /// Quote and Edit again put text into the input after what is typed already, a blank line between.
    static func inserted(_ text: String, into current: String) -> String {
        current.isEmpty ? text : current + "\n\n" + text
    }

    /// The input grows with its text up to 40% of the conversation's height, never less than five lines; then it scrolls.
    static func inputMaxHeight(chat: Double, line: Double) -> Double { Swift.max(chat * 0.4, line * 5) }

    static func title(pmOnly: Bool) -> String { pmOnly ? "Chat" : "Command" }

    /// The header's left side (N293): the PM as its turns are labelled, the role alone when its name has none in it (or it has no
    /// name), "PM not running" when there is no PM (`agent` nil).
    static func headerLabel(agent: String?, displayNames: [String: String]) -> (name: String, role: String?) {
        guard let agent else { return ("PM not running", nil) }
        guard AgentRowName.role(ofAgent: agent) != nil else { return ("pm", nil) }
        return ChatRowText.turnLabel(agent: agent, displayNames: displayNames)
    }

    /// The status line while a panel action runs: Send waits for it, the input stays open.
    static func waitingText(_ action: String) -> String { "Waiting: " + action }
    static func placeholder(pmOnly: Bool, noPM: Bool = false) -> String { noPM ? "Start a PM to send messages" : (pmOnly ? "Message the PM…" : "Message to the agent…") }

    /// The hint beside the paperclip (N346).
    static func sendHint(returnSends: Bool) -> String { returnSends ? "↵ send · ⇧↵ new line" : "⌘↵ send" }

    /// An image paste is ours only when the Command box's own field editor has focus; every other paste goes on.
    static func takesImagePaste(responder: NSResponder?, hasImage: Bool) -> Bool { hasImage && inputEditor(responder) != nil }

    /// The Command box's input text view (or a field editor editing a field with its identifier) when it has focus, else nil.
    static func inputEditor(_ responder: NSResponder?) -> NSTextView? {
        guard let editor = responder as? NSTextView else { return nil }
        if editor.accessibilityIdentifier() == inputIdentifier { return editor }
        guard let field = editor.delegate as? NSTextField, field.accessibilityIdentifier() == inputIdentifier else { return nil }
        return editor
    }

    @MainActor init(model: PanelModel, chatHeight: Binding<Double> = .constant(CommandBar.defaultChatHeight), maxChatHeight: Double = 600, fillsHeight: Bool = false, viewing: Bool = true, pmOnly: Bool = false, onOpenPreview: ((URL) -> Void)? = nil,
                    doneLineTime: Duration = PanelModel.doneLineTime, onActionsSize: ((CGSize) -> Void)? = nil, controls: ChatControls? = nil, noPM: AnyView? = nil) {
        self.onOpenPreview = onOpenPreview
        self.controls = controls
        self.noPM = noPM
        self.doneLineTime = doneLineTime
        self.onActionsSize = onActionsSize
        self.model = model
        self.pmOnly = pmOnly
        _chatHeight = chatHeight
        self.maxChatHeight = maxChatHeight
        self.fillsHeight = fillsHeight
        self.viewing = viewing
    }

    /// The thread and draft of the chosen agent in the selected project; kept by the panel model, so they survive this view being rebuilt.
    private var session: ChatSession { model.chats.session(project: model.selectedProjectID ?? "", pane: chosen?.paneID ?? "") }
    private var chat: ChatModel { session.chat }
    private var text: Binding<String> { Binding(get: { session.text }, set: { session.text = $0 }) }
    private var images: [PendingImage] {
        get { session.images }
        nonmutating set { session.images = newValue }
    }

    /// A click on a link in the thread: the Preview beside the chat, or the browser (⌘-click, or a link the Preview does not show).
    private func open(link url: URL) -> OpenURLAction.Result {
        guard let onOpenPreview else { return .systemAction }
        let root = model.selectedProject?.repoURL
        switch ChatLinkAction.of(url, commandHeld: NSEvent.modifierFlags.contains(.command), projectRoot: root) {
        case .preview(let page): onOpenPreview(page)
        case .browser(let page): NSWorkspace.shared.open(page)
        }
        return .handled
    }

    /// The chat's side inset from the tile edge (N347); the Dashboard's PM bar uses the same one.
    static let inset: CGFloat = Tok.Space.l

    private var shownHeight: Double { Self.clampedHeight(chatHeight, max: maxChatHeight) }
    private var expanded: Bool { shownHeight >= Self.clampedHeight(maxChatHeight, max: maxChatHeight) - 1 }

    /// The thread height to draw: never below the minimum, never above what the column leaves free.
    static func clampedHeight(_ h: Double, max: Double) -> Double { Swift.min(Swift.max(h, minChatHeight), Swift.max(max, minChatHeight)) }

    private var agents: [AgentStatus] {
        guard case .available(let list) = model.visibleAgents else { return [] }
        guard pmOnly else { return list }
        let pmPane = model.selectedProjectID.flatMap { model.pmPane(forProject: $0) }
        return list.filter { $0.paneID == pmPane }
    }
    private var busy: Bool { if case .running = model.actionState { return true } else { return false } }

    var body: some View {
        let matches = searchMatches
        let shownIndex = min(searchIndex, max(matches.count - 1, 0))
        return VStack(alignment: .leading, spacing: Tok.Space.s) {
            if c.searching {
                ChatSearchBar(query: $query, filter: $searchFilter, index: shownIndex, count: matches.count, onStep: stepSearch, onDone: closeSearch)
            } else if controls == nil {
                headerRow
            }
            if pmOnly, let id = model.selectedProjectID, model.pendingOnboarding[id] != nil {
                Button("Send the onboarding prompt") { Task { await model.sendOnboarding() } }
                    .buttonStyle(PanelButtonStyle()).disabled(busy || model.pmPane(forProject: id) == nil)
                    .help("Asks the PM to inspect the project, write the summary and the first cards. Nothing starts until you approve the round.")
            }
            if let agent = chosenAgent, isPM(agent), model.pmContextLarge, let fraction = model.pmContextFraction {
                PMContextReminder(percent: Int((fraction * 100).rounded()), disabled: busy, onRestart: { restart(.handoff) })
            }
            if let noPM {
                noPM.frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil)
                    .frame(height: fillsHeight ? nil : shownHeight)
            } else {
            ChatThread(place: session.place, opened: session.opened, entries: chat.entries, previous: session.previous, agentLabel: turnLabel.name, agentRole: turnLabel.role, working: chat.working,
                       onStop: chosenAgent.map { isPM($0) } == true ? { Task { await model.interruptPM() } } : nil,
                       held: chat.held, onEdit: { takeBack(editing: true) }, onUndo: { takeBack(editing: false) },
                       onRetry: { retry($0) }, onRemove: { chat.remove($0.id) }, onQuote: { model.chatQuotes.put(ChatQuote(speaker: turnLabel.name, text: $0), for: quoteKey); focusRequest += 1 }, onEditAgain: { insert(model.chatQuotes.restore($0, for: quoteKey)) },
                       conversationOnly: c.conversationOnly, canLoadEarlier: chat.canLoadEarlier, earlierFrom: chat.earlierFrom,
                       onLoadEarlier: { Task { await chat.loadEarlier() } })
                .environment(\.chatHighlight, c.searching && !query.isEmpty ? ChatHighlight(query: query.trimmingCharacters(in: .whitespacesAndNewlines), current: matches.isEmpty ? nil : matches[shownIndex]) : nil)
                .environment(\.openURL, OpenURLAction { open(link: $0) })
                .frame(height: fillsHeight ? nil : shownHeight)
                .frame(maxHeight: fillsHeight ? .infinity : nil)
            }
            ChatQuestionCard(inbox: model.inbox, questions: openQuestions, paneID: chosen?.paneID, selection: $questionIndex, digit: digit)
                .tutorialAnchor(.chatQuestion, if: !openQuestions.isEmpty)
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                if chat.editing { Text("Editing").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work) }
                if let quote { ChatQuoteBox(quote: quote) { model.chatQuotes.remove(for: quoteKey) } }
                if !images.isEmpty { thumbnails }
                input
                composerActions
            }
                .font(Tok.Font.body).foregroundStyle(Tok.ink)
                .padding(.leading, Tok.Space.m).padding(.trailing, Tok.Space.s + 2).padding(.top, Tok.Space.s + 2).padding(.bottom, Tok.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.bg, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
                .disabled(noPM != nil)
                .tutorialAnchor(.chatMessage)
            // Only when there is something to say (N346).
            if hasStatus { statusLine.padding(.horizontal, Tok.Space.xs) }
        }
        // N347: one column for the header, thread and composer, so their edges line up; capped and centred on a very wide tile.
        .frame(maxWidth: ChatThread.readingWidth, alignment: .leading)
        .padding(.horizontal, Self.inset).padding(.vertical, Tok.Space.m + 2)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { boxHeight = $0 }
        .background(Tok.pane)
        .sheet(isPresented: Bindable(c).restartOpen) {
            NewConversationSheet(agentLabel: chosen?.label ?? "Agent", mode: c.restartMode, modes: chosenAgent.map { model.restartModes(for: $0) } ?? RestartMode.allCases, onStart: { restart($0) }, onCancel: { c.restartOpen = false })
        }
        .overlay(alignment: .top) {
            if !fillsHeight { ResizeHandle(axis: .vertical, help: "Drag to make the conversation taller or shorter; double-click to reset") { delta in
                chatHeight = Self.clampedHeight(shownHeight - delta, max: maxChatHeight)
            } onReset: { chatHeight = Self.defaultChatHeight } }
        }
        .dropDestination(for: URL.self) { urls, _ in add { try urls.map { try attachments.pending(file: $0) } }; return !urls.isEmpty }
        .task { if !snapshot { await Task.detached { Attachments().prune() }.value } }
        .onAppear { installPasteMonitor() }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil
            // Leaving the screen or closing the chat sends a held message now; it is never dropped.
            chat.release()
        }
        .onChange(of: chosen?.paneID) { old, _ in model.chats.existingSession(project: model.selectedProjectID ?? "", pane: old ?? "")?.chat.release() }
        .onChange(of: model.selectedProjectID) { old, _ in model.chats.existingSession(project: old ?? "", pane: chosen?.paneID ?? "")?.chat.release() }
        .task(id: agents) { retarget() }
        .task(id: model.actionState) {
            guard !snapshot, case .done(let m) = model.actionState else { return }
            try? await Task.sleep(for: doneLineTime)
            if !Task.isCancelled { model.clearDoneLine(m) }
        }
        .task(id: model.selectedProjectID) {
            c.conversationOnly = UserDefaults.standard.bool(forKey: Self.conversationOnlyKey(project: model.selectedProjectID ?? ""))
        }
        .onChange(of: c.conversationOnly) { UserDefaults.standard.set($1, forKey: Self.conversationOnlyKey(project: model.selectedProjectID ?? "")) }
        .onChange(of: query) { searchIndex = 0 }
        .onChange(of: searchFilter) { searchIndex = 0 }
        .task(id: chosen) { await followThread() }
        .onChange(of: viewing) { _, now in if now && active { chat.markSeen() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true; chat.markSeen() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
    }

    /// The chosen agent's open menus (N289): its plain questions are already its replies in the thread.
    private var openQuestions: [PendingQuestion] {
        guard let pane = chosen?.paneID else { return [] }
        return model.questionsForYou.filter { $0.paneID == pane && $0.question.kind != .freeText }
    }

    private var chosenAgent: AgentStatus? { ChosenAgent.resolve(chosen, in: agents) }

    /// The agent's turns are labelled with its role's display name and the role beside it (N292).
    private var turnLabel: (name: String, role: String?) {
        let agent = chosen.flatMap { c in agents.first { $0.paneID == c.paneID } }
        guard let name = agent?.name ?? chosen?.label else { return ("Agent", nil) }
        return ChatRowText.turnLabel(agent: name, displayNames: model.roleDisplayNames)
    }

    private var headerLabel: (name: String, role: String?) { Self.headerLabel(agent: chosenAgent.map { $0.name ?? "" }, displayNames: model.roleDisplayNames) }

    /// A digit typed into the empty input picks that option of the shown question; any other digit is typed (N293).
    private func pick(digit n: Int) -> Bool {
        guard !openQuestions.isEmpty else { return false }
        let p = openQuestions[min(questionIndex, openQuestions.count - 1)]
        guard ChatQuestionContent.digitOption(p, n) != nil else { return false }
        digit = ChatDigit(number: n, seq: (digit?.seq ?? 0) + 1)
        return true
    }

    private var quoteKey: String { (model.selectedProjectID ?? "") + "|" + (chosen?.paneID ?? "") }
    private var quote: ChatQuote? { model.chatQuotes[quoteKey] }

    private func restart(_ mode: RestartMode) {
        c.restartOpen = false
        guard let agent = chosenAgent else { return }
        Task {
            let result = await model.restartConversation(mode, agent: agent)
            if result == .ok, let new = model.restartedSession { chosen = ChosenTarget(paneID: agent.paneID, sessionID: new, label: label(agent)) }
        }
    }

    private func isPM(_ agent: AgentStatus) -> Bool { model.selectedProjectID.flatMap { model.pmPane(forProject: $0) } == agent.paneID }
    private func label(_ agent: AgentStatus) -> String { model.agentLabel(agent) }

    /// After every agent poll: keep the chosen agent, tell the user when it is gone (never quietly switch to another one),
    /// and pick a default only when nothing was chosen yet.
    private func retarget() {
        switch CommandCenter.resolveTarget(chosen: chosen, agents: agents, remembered: model.rememberedTarget, preferred: model.selectedProjectID.flatMap { model.pmPane(forProject: $0) }) {
        case .keep:
            // Chosen before its first session was known: take the session now, or the header never resolves the agent.
            if let c = chosen, let next = ChosenAgent.followed(c, in: agents, follows: { _ in false }) { chosen = next }
        case .gone(let name):
            // A restart (the panel's, or /clear typed in the terminal) gives the pane a new session: follow it instead of calling the agent gone.
            if let c = chosen {
                let restarting = model.restartingPane == c.paneID
                if let next = ChosenAgent.followed(c, in: agents, follows: { restarting || model.canRestartConversation($0) }) {
                    if !restarting, let id = model.selectedProjectID, let old = c.sessionID, model.pmSession(forProject: id) == old { model.setPMSession(next.sessionID, forProject: id) }
                    chosen = next
                    return
                }
                if restarting { return }
            }
            chosen = nil; lostLabel = name
        case .choose(let pane):
            // No picker any more (N293): a PM that runs again is taken back without a choice.
            if pmOnly { lostLabel = nil }
            guard lostLabel == nil, let agent = agents.first(where: { $0.paneID == pane }) else { return }
            chosen = ChosenTarget(paneID: agent.paneID, sessionID: agent.sessionID, label: label(agent))
        }
    }

    /// Reads the chosen agent's session file about once a second and a half while the box is on screen.
    private func followThread() async {
        if snapshot { return }
        while !Task.isCancelled {
            let agent = chosen.flatMap { c in agents.first { $0.paneID == c.paneID } }
            await chat.refresh(agent: agent, tool: agent.map { model.tool(of: $0) } ?? .claude, viewing: active && viewing)
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private var sendable: Bool { canSend(text: ChatQuote.message(quote: quote, typed: session.text), target: chosen?.paneID, busy: busy, hasImages: !images.isEmpty) }

    /// Holds the message for `ChatSendDelay.hold` (Edit / Undo) and clears the input; it goes to the agent when the time runs out.
    private func send() {
        guard let chosen, sendable else { return }
        let session = session
        var stored: [URL] = []
        if !images.isEmpty {
            do {
                stored = try attachments.store(images, project: model.selectedProjectID ?? "project")
            } catch {
                attachError = "The attachments could not be saved: \(error.localizedDescription)"
                return
            }
        }
        attachError = nil
        model.clearDoneLine()
        session.chat.hold(text: model.chatQuotes.send(session.text, for: quoteKey), images: session.images, stored: stored) { [model] held in
            Self.deliver(held, to: chosen, session: session, model: model, quoteKey: quoteKey)
        }
        session.clearDraft()
    }

    /// Sends a held message as before the hold existed. A failed send puts the draft back when the input is still empty.
    private static func deliver(_ held: HeldMessage, to target: ChosenTarget, session: ChatSession, model: PanelModel, quoteKey: String) {
        let message = held.stored.isEmpty ? held.text : Attachments.compose(held.text, paths: held.stored)
        // Shown at once with the queued mark; it loses the mark when the agent's transcript shows it.
        let shown = Attachments.split(held.stored)
        let pendingID = session.chat.addPending(held.text, kind: .user, images: shown.images, files: shown.files)
        Task {
            let why: String
            switch await model.sendCommand(message, to: target.paneID, session: target.sessionID) {
            case .ok: return
            case .busy: why = ActionResult.busyReason
            case .failed(let reason): why = reason
            }
            session.chat.markFailed(pendingID, reason: why)
            refill(held, session: session, model: model, quoteKey: quoteKey)
        }
    }

    /// After a failed send, into an input that is still empty (no text, images or quote): the typed text into the field and a
    /// quote back into the box (N322 F1), as Edit and Undo do.
    static func refill(_ held: HeldMessage, session: ChatSession, model: PanelModel, quoteKey: String) {
        guard session.text.isEmpty && session.images.isEmpty && model.chatQuotes[quoteKey] == nil else { return }
        session.text = model.chatQuotes.restore(held.text, for: quoteKey)
        session.images = held.images
    }

    /// The ⌘K field's "Ask the PM" (N134): held in the PM's chat and delivered as the Dashboard's Send does, with the same Edit / Undo time.
    static func holdForPM(_ text: String, agent: AgentStatus, project: String, model: PanelModel) {
        let session = model.chats.session(project: project, pane: agent.paneID)
        let target = ChosenTarget(paneID: agent.paneID, sessionID: agent.sessionID, label: model.agentLabel(agent))
        session.chat.hold(text: text, images: [], stored: []) { held in deliver(held, to: target, session: session, model: model, quoteKey: project + "|" + agent.paneID) }
    }

    /// Retry on a failed or not-seen message of the user: sent again through the same checked send; the panel's own lines have no Retry.
    private func retry(_ entry: ChatEntry) {
        guard entry.kind == .user, let target = chosen, chat.retry(entry.id) != nil else { return }
        let stored = entry.images.compactMap { image -> URL? in if case .file(let path) = image { URL(fileURLWithPath: path) } else { nil } }
            + entry.files.map { URL(fileURLWithPath: $0.path) }
        Self.deliver(HeldMessage(text: entry.text, images: [], stored: stored, deadline: Date()), to: target, session: session, model: model, quoteKey: quoteKey)
    }

    /// Undo and Edit: the held message goes back into the input, before anything typed since.
    private func takeBack(editing: Bool) {
        guard let held = chat.takeBack(editing: editing) else { return }
        session.text = Self.restoredText(model.chatQuotes.restore(held.text, for: quoteKey), current: session.text)
        images = held.images + images
        focusRequest += 1
    }

    private func insert(_ text: String) {
        session.text = Self.inserted(text, into: session.text)
        focusRequest += 1
    }

    private var searchMatches: [ChatSearch.Match] {
        guard c.searching else { return [] }
        let rows = ChatRows.build(entries: chat.entries, previous: session.previous)
        return ChatSearch.matches(c.conversationOnly ? ChatSearch.conversationOnly(rows) : rows, query: query, filter: searchFilter)
    }

    private func stepSearch(_ by: Int) {
        let n = searchMatches.count
        if n > 0 { searchIndex = ((min(searchIndex, n - 1) + by) % n + n) % n }
    }

    private func closeSearch() { c.searching = false; query = ""; searchIndex = 0 }

    /// Adds what `make` returns; a refused file shows its reason under the input and nothing else is added.
    private func add(_ make: () throws -> [PendingImage]) {
        do { images += try make(); attachError = nil } catch { attachError = error.localizedDescription }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose files, folders or images to send (folders and files over 10 MB are linked, not copied)"
        guard panel.runModal() == .OK else { return }
        add { try panel.urls.map { try attachments.pending(file: $0) } }
    }

    /// ⌘V with an image, or files or folders copied in Finder, adds them; text pastes as usual. (Return and the focus are the input's own: see `ChatInput`.)
    private func installPasteMonitor() {
        guard pasteMonitor == nil, !snapshot else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v",
                  Self.takesImagePaste(responder: NSApp.keyWindow?.firstResponder, hasImage: Attachments.hasAttachment(.general)) else { return event }
            add { try attachments.pending(from: .general) }
            return nil
        }
    }

    /// A snapshot cannot draw a ScrollView, so it shows the row without one.
    @ViewBuilder private var thumbnails: some View {
        if snapshot { thumbnailRow } else { ScrollView(.horizontal, showsIndicators: false) { thumbnailRow } }
    }

    private var thumbnailRow: some View {
            HStack(spacing: Tok.Space.s) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        if let thumb = image.thumbnail {
                            Image(nsImage: thumb).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line))
                        } else {
                            FileChip(name: image.name, folder: image.isFolder,
                                     detail: Attachments.chipDetail(size: image.size, folder: image.isFolder, linked: image.kind == .linked))
                                .frame(height: 52)
                        }
                        Button { images.removeAll { $0.id == image.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(Tok.ink, Tok.raise)
                        }
                        .buttonStyle(.plain).offset(x: 5, y: -5)
                        .help(image.kind == .image ? "Remove this image" : "Remove \(image.name)").accessibilityLabel(image.kind == .image ? "Remove image" : "Remove \(image.name)")
                    }
                    .padding(.top, 5).padding(.trailing, 5)
                }
            }
    }

    /// How tall the input may grow: 40% of the thread's height, or of the whole box on the Dashboard.
    private var inputMaxHeight: Double { Self.inputMaxHeight(chat: fillsHeight ? boxHeight : shownHeight, line: ChatInput.lineHeight) }

    /// A snapshot cannot draw an AppKit text view, so it shows the text (or placeholder) as plain text.
    @ViewBuilder private var input: some View {
        if snapshot {
            Text(session.text.isEmpty ? Self.placeholder(pmOnly: pmOnly, noPM: noPM != nil) : session.text).foregroundStyle(session.text.isEmpty ? Tok.ink3 : Tok.ink).lineLimit(5)
        } else {
            ChatInput(text: text, returnSends: returnSends, maxHeight: inputMaxHeight, focusRequest: focusRequest, focusKey: chosen?.paneID ?? "", onSend: { send() }, onDigit: { pick(digit: $0) })
                .overlay(alignment: .topLeading) {
                    if session.text.isEmpty { Text(Self.placeholder(pmOnly: pmOnly, noPM: noPM != nil)).foregroundStyle(Tok.ink3).allowsHitTesting(false) }
                }
        }
    }

    /// The Command screen's header row (N346): the agent, its dots, Only chat, search, expand and ⋯ (New conversation, Compact, Return sends).
    private var headerRow: some View {
        HStack(spacing: Tok.Space.s) {
            let header = headerLabel
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(header.name).font(Tok.Font.heading).foregroundStyle(chosenAgent == nil ? Tok.ink3 : Tok.ink)
                if let role = header.role { Text(role).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            }
            .lineLimit(1).layoutPriority(1)
            .accessibilityElement(children: .combine)
            if chat.unread, !fillsHeight { Circle().fill(Tok.work).frame(width: 7, height: 7).help("New reply").accessibilityLabel("New reply") }
            if !openQuestions.isEmpty {
                Circle().fill(Tok.ask).frame(width: 7, height: 7).help("\(chosen?.label ?? "The agent") is waiting for you").accessibilityLabel("Waiting for you")
            }
            Spacer(minLength: 0)
            Button { c.conversationOnly.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                    Text("Only chat").fixedSize()
                }
                .font(Tok.Font.small).foregroundStyle(c.conversationOnly ? Tok.work : Tok.ink2)
                .padding(.horizontal, 8).frame(height: 22)
                .background(c.conversationOnly ? Tok.work.opacity(0.14) : Tok.raise, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Hide the panel's notes, tool lines and summaries")
            .accessibilityLabel("Only chat").accessibilityValue(c.conversationOnly ? "on" : "off")
            Button { c.searching = true } label: {
                Image(systemName: "magnifyingglass").font(Tok.Font.small).foregroundStyle(Tok.ink2).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
            .help("Search the conversation (⌘F)").accessibilityLabel("Search the conversation")
            if !fillsHeight {
                Button { chatHeight = expanded ? Self.defaultChatHeight : maxChatHeight } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(Tok.Font.small).foregroundStyle(Tok.ink2).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Make the conversation smaller" : "Make the conversation as tall as the column")
                .accessibilityLabel(expanded ? "Shrink conversation" : "Expand conversation")
            }
            moreMenu
        }
    }

    /// ⋯ on the Command screen: the restart sheet's two ways in (only for an agent the panel may restart) and Return sends.
    private var moreMenu: some View {
        let restartable = chosenAgent.map { model.canRestartConversation($0) } == true
        return Menu {
            if restartable {
                Button("New conversation…") { c.openRestart(.handoff) }.disabled(busy)
                if chosenAgent.map({ model.restartModes(for: $0).contains(.compact) }) == true { Button("Compact conversation…") { c.openRestart(.compact) }.disabled(busy) }
                Divider()
            }
            Toggle("Return sends", isOn: $returnSends)
        } label: {
            Image(systemName: "ellipsis").font(Tok.Font.small).foregroundStyle(Tok.ink2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More").accessibilityLabel("More")
    }

    /// Inside the input box (N346): the paperclip, the key hint and the round-cornered send arrow.
    private var composerActions: some View {
        HStack(spacing: Tok.Space.s) {
            Button { pickImages() } label: {
                Image(systemName: "paperclip").font(Tok.Font.body).foregroundStyle(Tok.ink2).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Attach files, folders or images (or paste or drop them here)")
            .accessibilityLabel("Attach files, folders or images")
            Text(Self.sendHint(returnSends: returnSends)).font(.system(size: 11)).foregroundStyle(Tok.ink3).lineLimit(1).fixedSize()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { onActionsSize?($0) }
            Spacer(minLength: Tok.Space.s)
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(sendable ? Tok.bg : Tok.ink3)
                    .frame(width: 30, height: 30)
                    .background(sendable ? Tok.work : Tok.raise, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!sendable)
            .help(Self.sendHelp(returnSends: returnSends))
            .accessibilityLabel("Send")
            .tutorialAnchor(.chatSend)
        }
    }

    /// Whether the line under the box has anything to say.
    private var hasStatus: Bool {
        if attachError != nil || lostLabel != nil { return true }
        if case .idle = model.actionState { return false }
        return true
    }

    @ViewBuilder private var statusLine: some View {
        if let attachError {
            Text(attachError).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        } else if let lostLabel {
            Text("\(lostLabel) is no longer running.").font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
        } else {
            actionLine
        }
    }

    @ViewBuilder private var actionLine: some View {
        switch model.actionState {
        case .idle: EmptyView()
        case .running(let m): Text(Self.waitingText(m)).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(2).truncationMode(.tail).help(Self.waitingText(m))
        case .failed(let m):
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                Text(m).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
                if model.canAskToCommit {
                    Button("Ask the agent to commit") { Task { await model.askAgentToCommit() } }
                        .buttonStyle(PanelButtonStyle())
                        .help("Send the agent a prompt to commit its work on the branch and fill in the Report")
                }
            }
        case .done(let m): Text(m).font(Tok.Font.small).foregroundStyle(Tok.go).lineLimit(2).truncationMode(.tail).help(m)
        }
    }
}
