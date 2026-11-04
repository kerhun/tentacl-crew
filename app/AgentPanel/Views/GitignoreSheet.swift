import SwiftUI

/// Edits the project's root `.gitignore` (N180), from the Git screen and from Edit project. Quick-add chips, a warning for tracked files the
/// new lines match (ignoring never untracks them), where `.agent-worktrees/` is ignored, and an optional commit of `.gitignore` alone.
struct GitignoreSheet: View {
    @Bindable var flow: GitignoreFlow
    /// true when the file was saved.
    let onDone: (Bool) -> Void
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m + 2) {
            VStack(alignment: .leading, spacing: 6) {
                Text(".gitignore").font(Tok.Font.title).foregroundStyle(Tok.ink)
                Text("Files git should not track in \(flow.projectName). Also opens from Edit project.")
                    .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Text("Add a common line:").font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(height: 24)
                ForEach(Gitignore.quickLines, id: \.self) { line in
                    Button { flow.add(line) } label: {
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(flow.has(line) ? Tok.ink3 : Tok.ink)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Tok.raise, in: Capsule()).overlay(Capsule().stroke(Tok.line))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(flow.has(line))
                    .help(flow.has(line) ? "Already in the file." : "Adds \(line) as a new line.")
                }
            }
            PlainEditor(text: $flow.text, height: 200, mono: true)
                .accessibilityLabel(".gitignore contents")
            let source = flow.effectiveSource
            Text(Gitignore.agentWorktreesNote(source)).font(Tok.Font.small).foregroundStyle(source == .nowhere ? Tok.wait : Tok.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = Gitignore.trackedWarning(flow.tracked) {
                Text(warning).font(Tok.Font.body).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s + 2).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tok.wait.opacity(0.1), in: RoundedRectangle(cornerRadius: Tok.radius))
                    .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.wait.opacity(0.35)))
            }
            HStack {
                Toggle(flow.commitLabel, isOn: $flow.commit).toggleStyle(.checkbox).foregroundStyle(Tok.ink2).disabled(flow.branch == nil)
                    .help(flow.branch == nil ? "The folder is not on a branch; the file is only saved." : "Commits .gitignore alone; nothing else you changed goes in.")
                Spacer()
            }
            if let error = flow.error {
                Text(error).font(Tok.Font.body).foregroundStyle(Tok.wait).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Tok.Space.s + 2) {
                if flow.saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { onDone(false) }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction).disabled(flow.saving)
                Button("Save .gitignore") { Task { if await flow.save() { onDone(true) } } }
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!flow.loaded || !flow.changed || flow.saving)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 600)
        .background(Tok.bg)
        .task { if !snapshot && !flow.loaded { await flow.load() } }
        .task(id: flow.added) {
            guard !snapshot, flow.loaded else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await flow.findTracked()
        }
    }
}
