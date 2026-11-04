import SwiftUI

/// The branch name on the Git screen as a menu (N180): find a local branch and switch to it, or create a new one from the current branch.
/// Branches checked out in an agent worktree are listed but cannot be picked. Nothing is deleted and nothing is stashed.
struct BranchMenu: View {
    @Bindable var menu: BranchMenuModel
    let branch: String?
    let main: String
    let repoPath: String
    let mergeRunning: () -> Bool
    let onSwitched: () -> Void
    @Binding var open: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(branch ?? "detached HEAD").font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tok.ink2)
            }
            .padding(.leading, 12).padding(.trailing, 10).frame(height: 26)
            .background(Tok.raise, in: Capsule()).overlay(Capsule().stroke(open ? Tok.work : Tok.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("The branch checked out in the project folder. Click to switch or create a branch. Merges go to \(main).")
        .accessibilityLabel("Branch \(branch ?? "detached HEAD"), switch or create")
        .popover(isPresented: Binding(get: { open && !snapshot }, set: { open = $0 }), arrowEdge: .bottom) {
            panel.onExitCommand { open = false }
        }
        .overlay(alignment: .topLeading) {
            // ImageRenderer cannot draw a popover: snapshots draw the panel under the button.
            if open && snapshot { panel.background(Tok.pane, in: RoundedRectangle(cornerRadius: 12)).offset(y: 34) }
        }
        .task(id: open) { if open && !snapshot { menu.reset(); await menu.load(repoPath: repoPath) } }
    }

    private var rows: [BranchRow] {
        guard let state = menu.state else { return [] }
        let all = BranchSwitcher.rows(state, main: main)
        let found = BranchSwitcher.matching(all, query: menu.query)
        // A new name matches nothing: the branches stay listed under the Create row.
        return found.isEmpty && BranchSwitcher.createOffer(menu.query, state: state) != nil ? all : found
    }

    private var offer: String? { menu.state.flatMap { BranchSwitcher.createOffer(menu.query, state: $0) } }

    /// Typed but not offered: why (an existing name is simply found in the list).
    private var nameProblem: String? {
        let q = menu.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, menu.state?.local.contains(q) == false else { return nil }
        return BranchSwitcher.nameProblem(q)
    }

    private var blocked: String? { menu.state.flatMap { BranchSwitcher.leaveProblem($0, mergeRunning: mergeRunning()) } }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldText(text: $menu.query, placeholder: "Find or create a branch", mono: true)
                .onSubmit(submit)
                .padding(.bottom, 6)
            if let offer {
                Button { create(offer) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.work)
                        (Text("Create ") + Text(offer).font(.system(size: 12, design: .monospaced)) + Text(" from \(branch ?? "HEAD") and switch"))
                            .font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(Tok.work.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(menu.working || blocked != nil)
            } else if let nameProblem {
                Text(nameProblem).font(Tok.Font.small).foregroundStyle(Tok.wait).padding(.horizontal, 10).padding(.vertical, 4)
            }
            if let message = menu.error ?? blocked {
                Text(message).font(Tok.Font.small).foregroundStyle(Tok.wait).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tok.wait.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Local branches").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.ink3).padding(.horizontal, 10).padding(.top, 6)
            if menu.state == nil {
                Text("Reading branches…").font(Tok.Font.small).foregroundStyle(Tok.ink3).padding(.horizontal, 10).padding(.vertical, 6)
            } else if rows.isEmpty {
                Text("No branch matches.").font(Tok.Font.small).foregroundStyle(Tok.ink3).padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(rows) { row($0) }
            Text(BranchSwitcher.menuNote(main: main)).font(Tok.Font.small).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                .overlay(alignment: .top) { Rectangle().fill(Tok.line).frame(height: 1) }
                .padding(.top, 4)
        }
        .padding(10)
        .frame(width: 380, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(snapshot ? Tok.line : .clear))
    }

    private func row(_ row: BranchRow) -> some View {
        let enabled = row.selectable && blocked == nil && !menu.working
        return Button { switchTo(row.name) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Tok.go).opacity(row.current ? 1 : 0)
                    .frame(width: 14)
                Text(row.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(row.selectable || row.current ? Tok.ink : Tok.ink3)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Tok.Space.s)
                if let note = row.note { Text(note).font(Tok.Font.small).foregroundStyle(Tok.ink3) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(row.current ? .isSelected : [])
    }

    private func submit() {
        if let offer { create(offer); return }
        let picks = rows.filter(\.selectable)
        if picks.count == 1 { switchTo(picks[0].name) }
    }

    private func switchTo(_ name: String) {
        Task { if await menu.switchTo(name, repoPath: repoPath, mergeRunning: mergeRunning(), onDone: onSwitched) { open = false } }
    }

    private func create(_ name: String) {
        Task { if await menu.create(name, repoPath: repoPath, mergeRunning: mergeRunning(), onDone: onSwitched) { open = false } }
    }
}
