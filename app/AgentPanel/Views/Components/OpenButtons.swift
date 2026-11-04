import SwiftUI

/// Open-folder buttons. The opener refuses anything outside the project's registered folders.
struct OpenButtons: View {
    let opener: WorkspaceOpener?
    let card: TaskCard?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: Tok.Space.s) {
            if let opener {
                button("Open folder") { try opener.openFolder(opener.project.repoURL) }
                if opener.project.xcodeProject != nil { button("Open in Xcode") { try opener.openInXcode() } }
                if let card, card.branch != nil {
                    button("Open worktree") { try opener.openFolder(Self.worktreeURL(opener.project, card)) }
                }
            }
        }
        .alert("Cannot open", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    static func worktreeURL(_ project: ProjectConfig, _ card: TaskCard) -> URL {
        project.worktreesURL.appendingPathComponent((card.branch ?? "").replacingOccurrences(of: "/", with: "-"))
    }

    private func button(_ title: String, _ action: @escaping () throws -> Void) -> some View {
        Button(title) {
            do { try action() } catch { errorMessage = Self.describe(error) }
        }
        .buttonStyle(PanelButtonStyle())
    }

    static func describe(_ error: Error) -> String {
        switch error as? OpenError {
        case .notAllowed(let path): return "\(path) is outside the project's registered folders."
        case .missing(let what): return "Not found: \(what)"
        case nil: return error.localizedDescription
        }
    }
}

struct PanelButtonStyle: ButtonStyle {
    var primary = false
    /// The label's colour instead of `ink` (the first button of a Waiting for you item, N182).
    var tint: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tok.Font.bodyStrong)
            .lineLimit(1).fixedSize()
            .foregroundStyle(primary ? Tok.askInk : (tint ?? Tok.ink))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(primary ? Tok.ask : Tok.raise, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Tok.line))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// The task detail header's buttons (design B, N142): 34 high, radius 8. Approve is green; Prepare review keeps its orange, Start its blue.
struct HeaderButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        case approve, decision, confirm, secondary

        var fill: Color {
            switch self {
            case .approve: return Tok.go
            case .decision: return Tok.ask
            case .confirm: return Tok.work
            case .secondary: return Tok.raise
            }
        }

        var ink: Color {
            switch self {
            case .approve: return Tok.goInk
            case .decision: return Tok.askInk
            case .confirm: return Tok.bg
            case .secondary: return Tok.ink
            }
        }
    }

    var kind = Kind.secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .approve ? .bold : kind == .secondary ? .regular : .medium))
            .lineLimit(1).fixedSize()
            .foregroundStyle(kind.ink)
            .padding(.horizontal, kind == .approve ? 16 : 14).frame(height: 34)
            .background(kind.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay { if kind == .secondary { RoundedRectangle(cornerRadius: 8).stroke(Tok.line) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// A square icon button of the task list's header (+, Plan a round): 30 × 30, radius 8 (design B, N142).
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14)).foregroundStyle(Tok.ink)
            .frame(width: 30, height: 30)
            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// The confirm button of a sheet: a calm blue (orange is reserved for "waiting for your decision").
struct ConfirmButtonStyle: ButtonStyle {
    /// The fill; a Waiting for you item's first button takes its kind's colour (N182).
    var fill: Color = Tok.work
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tok.Font.bodyStrong)
            .lineLimit(1).fixedSize()
            .foregroundStyle(Tok.bg)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(fill, in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
