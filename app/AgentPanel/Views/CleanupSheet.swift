import SwiftUI

extension CleanupFlow: Identifiable { var id: ObjectIdentifier { ObjectIdentifier(self) } }

/// Lists what "Clean up…" found, per project, and what will happen to each. Nothing runs until "Clean up".
struct CleanupSheet: View {
    @Bindable var flow: CleanupFlow
    let onClose: () -> Void

    private var projectIDs: [String] { flow.items.reduce(into: [String]()) { if !$0.contains($1.projectID) { $0.append($1.projectID) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.l) {
            Text("Clean up").font(Tok.Font.title).foregroundStyle(Tok.ink)
            Text("Agents and worktrees whose card is not running. Work that is uncommitted or not merged is listed but kept.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            if let error = flow.scanError { Text(error).font(Tok.Font.small).foregroundStyle(Tok.askInk) }
            if flow.phase == .scanning { Text("Looking…").font(Tok.Font.body).foregroundStyle(Tok.ink2) }
            else if flow.items.isEmpty { Text("Nothing to clean up.").font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink) }
            ScrollView {
                VStack(alignment: .leading, spacing: Tok.Space.m) {
                    ForEach(projectIDs, id: \.self) { id in
                        let items = flow.items.filter { $0.projectID == id }
                        VStack(alignment: .leading, spacing: Tok.Space.s) {
                            Text(items.first?.projectName ?? id).font(Tok.Font.small).foregroundStyle(Tok.ink3)
                            ForEach(items) { row($0) }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            ForEach(flow.warnings, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.ink3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            ForEach(flow.failures, id: \.self) { Text($0).font(Tok.Font.small).foregroundStyle(Tok.askInk).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Tok.Space.s + 2) {
                Spacer()
                Button("Close", action: onClose).buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction).disabled(flow.phase == .running)
                Button("Clean up \(flow.selectedCount)") { Task { await flow.runCleanup() } }
                    .buttonStyle(ConfirmButtonStyle()).keyboardShortcut(.defaultAction).disabled(flow.selectedCount == 0 || flow.phase != .ready)
            }
        }
        .padding(Tok.Space.xl + 2)
        .frame(width: 600)
        .background(Tok.bg)
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(alignment: .top, spacing: Tok.Space.m) {
            Toggle("", isOn: Binding(get: { flow.selectedIDs.contains(item.id) }, set: { _ in flow.toggle(item) }))
                .labelsHidden().disabled(!item.isOffered)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.agent ?? item.id).font(Tok.Font.mono).foregroundStyle(Tok.ink)
                if let agent = item.agent, item.worktreePath != nil { Text("agent \(agent)").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                if let blocked = item.blocked { Text(blocked).font(Tok.Font.small).foregroundStyle(Tok.askInk) }
                else { Text(item.steps.joined(separator: " · ")).font(Tok.Font.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(Tok.Space.m)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }
}
