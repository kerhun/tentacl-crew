import SwiftUI
import AppKit

/// The first-run guide: one line per thing Tentacl needs, with the way to fix it. "Install missing (n)" installs the missing tools with
/// their official installers after one confirmation that shows every command; until the terminal answers and the required tools are there, it cannot be closed.
struct SetupView: View {
    @Bindable var model: SetupModel
    let onClose: () -> Void
    let onAddProject: () -> Void
    var onSignIn: (AgentTool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            Text("Setup").font(Tok.Font.title).foregroundStyle(Tok.ink)
            Text("What Tentacl Crew needs on this Mac. Missing tools are installed with their official installers after you confirm; every command is shown first.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            // The list scrolls when the sheet would not fit the window, so Install, Re-check and Close stay reachable.
            ViewThatFits(in: .vertical) {
                itemList
                Scroller { itemList }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
            .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
            if model.offersCodexRules {
                HStack(spacing: Tok.Space.m) {
                    Button("Copy my Claude rules to Codex…") { model.openRules() }.buttonStyle(PanelButtonStyle())
                    Text("Codex does not read ~/.claude/CLAUDE.md. You see what is added to ~/.codex/AGENTS.md before anything is written.")
                        .font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            installSection
            if let message = model.message {
                Text(message).font(Tok.Font.small).foregroundStyle(Tok.askText).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: Tok.Space.s + 2) {
                Button(model.isChecking ? "Checking…" : "Re-check") { Task { await model.check() } }
                    .buttonStyle(PanelButtonStyle()).disabled(model.isChecking)
                Spacer()
                Button("Close", action: onClose).buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.cancelAction)
                    .disabled(model.blocksDashboard)
                    .help(model.blocksDashboard ? "Tentacl Crew opens once the terminal answers and the required tools are installed." : "")
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 640)
        .frame(maxHeight: Self.maxHeight)
        .background(Tok.bg)
        .interactiveDismissDisabled(model.blocksDashboard)
        .sheet(item: $model.rulesFlow) { flow in CodexRulesSheet(flow: flow) { model.rulesFlow = nil } }
    }

    /// The one-click install: the button, then the exact commands with one confirmation, then the live output.
    @ViewBuilder private var installSection: some View {
        let plan = model.installPlan
        if model.isConfirmingInstall {
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                Text("This will run:").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                ForEach(plan.steps, id: \.command) { command($0.command) }
                HStack(spacing: Tok.Space.s + 2) {
                    Button("Install") { Task { await model.confirmInstall() } }.buttonStyle(ConfirmButtonStyle())
                    Button("Cancel") { model.cancelInstall() }.buttonStyle(PanelButtonStyle())
                }
            }
            .padding(Tok.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
            .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        } else if !plan.isEmpty, !model.isInstalling {
            HStack(spacing: Tok.Space.m) {
                Button("Install missing (\(plan.count))") { model.requestInstall() }.buttonStyle(ConfirmButtonStyle()).disabled(model.isChecking)
                let names = plan.tools.joined(separator: ", ")
                Text("Installs \(names)." + " You see the commands before anything runs.")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        if !model.installLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isInstalling ? "Installing…" : "Install output")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.installLog).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 160)
                    .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.installLog) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }

    private func command(_ text: String) -> some View {
        Text(text).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 4).background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
    }

    /// The sheet stays inside the main window (a 13" laptop window is about 800 pt tall).
    static var maxHeight: CGFloat {
        let window = NSApp?.mainWindow?.contentLayoutRect.height ?? NSScreen.main?.visibleFrame.height ?? 760
        return max(420, window - 40)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.items) { item in
                row(item)
                if item.id != model.items.last?.id { Divider().overlay(Tok.line) }
            }
            if model.items.isEmpty { Text("Checking…").font(Tok.Font.body).foregroundStyle(Tok.ink3).padding(Tok.Space.m + 2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mark(_ state: SetupState) -> (String, Color) {
        switch state {
        case .ok: return ("\u{2713}", Tok.ink)
        case .missing: return ("\u{2717}", Tok.ask)
        case .unsure: return ("!", Tok.wait)
        }
    }

    private func row(_ item: SetupItem) -> some View {
        let (symbol, color) = mark(item.state)
        return HStack(alignment: .top, spacing: Tok.Space.m) {
            Text(symbol).font(Tok.Font.bodyStrong).foregroundStyle(color).frame(width: 16)
                .accessibilityLabel(item.state == .ok ? "OK" : item.state == .missing ? "Missing" : "Unsure")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink)
                Text(item.detail).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                if let fix = item.fix, item.state != .ok { fixView(fix) }
            }
            Spacer(minLength: 0)
        }
        .padding(Tok.Space.m + 2)
    }

    @ViewBuilder private func fixView(_ fix: SetupFix) -> some View {
        switch fix {
        case .copy(let command):
            HStack(spacing: Tok.Space.s) {
                Text(command).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                }.buttonStyle(PanelButtonStyle())
            }
        case .signIn(let tool):
            HStack(spacing: Tok.Space.s) {
                Text(SignInGate.command(tool).joined(separator: " ")).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
                Button("Sign in to \(SignInGate.name(tool))") { onSignIn(tool) }.buttonStyle(PanelButtonStyle())
                    .help("Opens this command in Tentacl Crew's terminal and checks again when it ends")
            }
        case .chooseScripts:
            Button("Choose scripts folder…") { Task { await model.chooseScripts() } }.buttonStyle(PanelButtonStyle())
        case .addProject:
            Button("Add project…", action: onAddProject).buttonStyle(PanelButtonStyle())
        case .addRoles(let names):
            Button("Add \(names.joined(separator: " and ")) from templates") { Task { await model.addRoles(names) } }.buttonStyle(PanelButtonStyle())
                .help("Writes the role files into the shared library (~/.config/tentacl/roles).")
        }
    }
}

/// "Copy my Claude rules to Codex…" (N367): shows exactly what goes into `~/.codex/AGENTS.md`; nothing is written before Add.
struct CodexRulesSheet: View {
    let flow: CodexRulesFlow
    let onClose: () -> Void

    private var previewText: some View {
        Text(flow.preview).font(Tok.Font.mono).foregroundStyle(Tok.ink).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(Tok.Space.m).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            Text("Copy my Claude rules to Codex").font(Tok.Font.title).foregroundStyle(Tok.ink)
            Text(flow.replaces
                 ? "\(flow.agentsPath) already has a copy from Tentacl Crew. Add replaces that block with this text; the rest of the file stays as it is."
                 : "A Codex PM does not read ~/.claude/CLAUDE.md. Add appends this text to \(flow.agentsPath); the rest of the file stays as it is.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .vertical) {
                previewText
                Scroller { previewText }
            }
            .frame(maxWidth: .infinity, maxHeight: 260, alignment: .topLeading)
            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.line))
            .accessibilityIdentifier("codexRulesPreview")
            switch flow.phase {
            case .added: Text("Added to \(flow.agentsPath).").font(Tok.Font.small).foregroundStyle(Tok.ink2)
            case .failed(let why): Text(why).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
            case .confirming: EmptyView()
            }
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                if flow.phase == .added {
                    Button("Done", action: onClose).buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: onClose).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Add") { flow.add() }.buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 600)
        .background(Tok.bg)
    }
}
