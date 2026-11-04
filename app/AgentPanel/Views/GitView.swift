import SwiftUI

/// The Git screen (N179): the selected project's branch, remote and sync state, what is not pushed, recent merges on the main branch, the
/// agent worktrees and the task branches no agent holds. Push… and Create GitHub repository… open N178's sheet, which runs nothing before
/// its own button. The branch name is a menu that switches or creates a branch, and the .gitignore card opens its editor (N180).
struct GitView: View {
    @Bindable var model: PanelModel
    @Bindable var git: GitScreenModel
    @State private var branches: BranchMenuModel
    @State private var menuOpen: Bool
    /// The project folder's .gitignore; `ignoreProject` is the project it was read for (nil: given by a screenshot test).
    @State private var ignore: GitignoreInfo?
    @State private var ignoreProject: String?
    @State private var editingIgnore: GitignoreFlow?
    /// Bumped after a switch or a saved .gitignore, so everything is read again.
    @State private var changes = 0
    /// "Install stable-N" waits here for the user's yes; `installing` and `installNote` show what became of it.
    @State private var confirmInstall: String?
    @State private var installing = false
    @State private var installNote: String?
    /// The "Not pushed" commit whose full message shows under its row, and the messages read so far (N269).
    @State private var expandedCommit: String?
    @State private var messages: [String: String] = [:]
    @Environment(\.snapshotMode) private var snapshot

    init(model: PanelModel, git: GitScreenModel, branches: BranchMenuModel? = nil, ignore: GitignoreInfo? = nil, menuOpen: Bool = false,
         expandedCommit: String? = nil, messages: [String: String] = [:]) {
        _model = Bindable(model); _git = Bindable(git)
        _expandedCommit = State(initialValue: expandedCommit); _messages = State(initialValue: messages)
        _branches = State(initialValue: branches ?? BranchMenuModel(runner: Self.live ? BranchSwitchRunner(runner: ProcessToolRunner(timeout: 60)) : nil))
        _ignore = State(initialValue: ignore)
        _menuOpen = State(initialValue: menuOpen)
    }

    /// No test reads or changes a real repository from the screen.
    private static var live: Bool { !PanelModel.runsUnderXCTest }

    private var project: ProjectConfig? { model.selectedProject }
    private var cards: [TaskCard] { model.selectedTaskCards }
    /// Read again when the project changes, a card is merged (done), when the push sheet closes and after a switch or a .gitignore save.
    private var refreshKey: String {
        "\(project?.id ?? "")|\(cards.filter { $0.status == .done }.count)|\(model.gitSetup.pushSheet == nil)|\(changes)"
    }

    /// Approve is merging one of this project's cards right now.
    private func mergeRunning() -> Bool { cards.contains { $0.status == .review && ReviewFlow.isApproving($0) } }

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: Tok.Space.l + 4) {
                if let project {
                    header(project)
                    if let d = git.details, git.projectID == project.id {
                        summary(d)
                        HStack(alignment: .top, spacing: Tok.Space.l + 4) {
                            VStack(alignment: .leading, spacing: Tok.Space.l + 4) {
                                mergeQueueSection(d, project: project)
                                unpushedSection(d)
                                mergesSection(d, project: project)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: Tok.Space.l + 4) {
                                worktreesSection(d)
                                idleBranchesSection(d)
                                ignoreSection(project)
                                if !d.otherWorktrees.isEmpty { otherSection(d) }
                            }
                            .frame(width: 380, alignment: .topLeading)
                        }
                    } else {
                        Text(git.loading ? "Reading the repository…" : "Not read yet.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                    }
                } else {
                    Text("Git").font(Tok.Font.title).foregroundStyle(Tok.ink)
                    Text("Pick a project to see its git state.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                }
            }
            .pageMargin()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Tok.bg)
        .task(id: refreshKey) {
            guard !snapshot, let project else { return }
            await git.refresh(project)
            if Self.live {
                let info = await GitignoreTool(runner: ProcessToolRunner(timeout: 30)).read(repoPath: project.repoPath)
                if self.project?.id == project.id { ignore = info; ignoreProject = project.id }
            }
        }
        .confirmationDialog("Install \(confirmInstall ?? "stable")?", isPresented: Binding(get: { confirmInstall != nil }, set: { if !$0 { confirmInstall = nil } }), titleVisibility: .visible) {
            Button("Install \(confirmInstall ?? "")") { if let tag = confirmInstall, let project { Task { await install(tag, project: project) } }; confirmInstall = nil }
            Button("Cancel", role: .cancel) { confirmInstall = nil }
        } message: {
            Text("Builds \(confirmInstall ?? "this tag") in the stable copy and installs the app. The running Tentacl Crew is not restarted. Runs: \(project.map { MergeQueue.installText(repoPath: $0.repoPath, tag: confirmInstall ?? "") } ?? "")")
        }
        .sheet(item: $editingIgnore) { flow in
            GitignoreSheet(flow: flow) { _ in editingIgnore = nil; changes += 1 }
        }
    }

    // MARK: Header

    private func header(_ project: ProjectConfig) -> some View {
        let d = git.projectID == project.id ? git.details : nil
        return HStack(alignment: .top, spacing: Tok.Space.l) {
            VStack(alignment: .leading, spacing: Tok.Space.s) {
                Text("Git · \(project.name)").font(Tok.Font.title).foregroundStyle(Tok.ink)
                FlowLayout(spacing: Tok.Space.s, lineSpacing: Tok.Space.s) {
                    BranchMenu(menu: branches, branch: d?.branch, main: project.baseBranch, repoPath: project.repoPath,
                               mergeRunning: mergeRunning, onSwitched: { changes += 1 }, open: $menuOpen)
                        .disabled(d == nil)
                    if let d {
                        if let remote = d.remoteURL {
                            Text(remote).font(Tok.Font.mono).foregroundStyle(Tok.ink2).textSelection(.enabled).frame(height: 26)
                            Text(d.syncText).font(Tok.Font.small).foregroundStyle(d.behind ?? 0 > 0 ? Tok.wait : Tok.ink2).frame(height: 26)
                            Text(d.fetchText()).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(height: 26)
                        } else {
                            Text(d.noRemoteText).font(Tok.Font.small).foregroundStyle(Tok.wait)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(Tok.wait.opacity(0.1), in: Capsule()).overlay(Capsule().stroke(Tok.wait.opacity(0.35)))
                        }
                    }
                    Text(abbreviated(project.repoPath)).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(height: 26)
                }
                if let d, let note = BranchSwitcher.awayNote(current: d.branch, main: project.baseBranch) {
                    Text("This folder is on \(d.branch ?? "a detached HEAD"). " + note).font(Tok.Font.small).foregroundStyle(Tok.wait)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s)
                        .background(Tok.wait.opacity(0.1), in: RoundedRectangle(cornerRadius: Tok.radius))
                        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.wait.opacity(0.35)))
                }
                if let error = git.fetchError {
                    Text(error).font(Tok.Font.small).foregroundStyle(Tok.stop).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tok.Space.m)
            HStack(spacing: Tok.Space.s + 2) {
                if git.fetching || git.loading { ProgressView().controlSize(.small) }
                Button("Fetch") { Task { await git.fetch(project) } }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(d?.remoteURL == nil || git.fetching)
                    .help(d?.remoteURL == nil ? "No remote to fetch from." : "git fetch origin: updates the remote branches; the work tree is not touched.")
                if d?.remoteURL == nil {
                    Button("Create GitHub repository…") { Task { await model.gitSetup.openPush(project) } }
                        .buttonStyle(ConfirmButtonStyle()).disabled(d == nil)
                        .help("Opens a sheet that shows what will happen; nothing is created before its button.")
                } else {
                    Button("Push…") { Task { await model.gitSetup.openPush(project) } }
                        .buttonStyle(ConfirmButtonStyle())
                        .help("Opens a sheet that lists the commits; nothing is pushed before its button.")
                }
            }
        }
        .zIndex(1)
    }

    // MARK: Summary

    private func summary(_ d: GitDetails) -> some View {
        let dirtyTrees = d.worktrees.filter { ($0.dirty ?? 0) > 0 }.count
        let last = d.merges.first
        return HStack(spacing: Tok.Space.m) {
            tile("Remote", d.remoteURL == nil ? "None yet" : d.syncText, d.remoteURL == nil ? "every commit is only on this Mac" : d.fetchText())
            tile("Last merge", last.map { [$0.tag, $0.card].compactMap { $0 }.joined(separator: " · ") }.flatMap { $0.isEmpty ? nil : $0 } ?? (last?.hash ?? "None"),
                 last.map { "\($0.hash) · \(GitDetails.ago($0.date))" } ?? "")
            tile("Agent worktrees", d.worktrees.isEmpty ? "None" : "\(d.worktrees.count) open",
                 d.worktrees.isEmpty ? "no agent is working" : (dirtyTrees == 0 ? "all clean" : "\(dirtyTrees) with uncommitted changes"))
            tile("Working copy", d.uncommitted == 0 ? "Clean" : "\(d.uncommitted) uncommitted", d.uncommitted == 0 ? "nothing uncommitted on \(d.branch ?? "HEAD")" : "in the project folder")
        }
    }

    private func tile(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Tok.Font.small).foregroundStyle(Tok.ink3)
            Text(value).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1)
            Text(detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1)
        }
        .padding(.horizontal, Tok.Space.l).padding(.vertical, Tok.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
        .accessibilityElement(children: .combine)
    }

    // MARK: Sections

    private func mergeQueueSection(_ d: GitDetails, project: ProjectConfig) -> some View {
        let items = Array(model.mergeQueue.items(for: project.id).reversed())
        let last = MergeQueue.lastStable(in: d.merges.flatMap(\.tags))
        return section("Merge queue", note: "one merge at a time; Approve and the PM's requests wait here") {
            HStack(spacing: Tok.Space.m) {
                Text(last.map { "Last stable: \($0)" } ?? "No stable-N tag yet").font(Tok.Font.small).foregroundStyle(Tok.ink2)
                if installing { ProgressView().controlSize(.small) }
                if let installNote { Text(installNote).font(Tok.Font.small).foregroundStyle(installNote.hasPrefix("Installed") ? Tok.go : Tok.stop).lineLimit(2) }
                Spacer()
                if let last {
                    Button("Install \(last)…") { confirmInstall = last }
                        .buttonStyle(PanelButtonStyle())
                        .disabled(installing || model.settings.scriptsDir == nil)
                        .help("Asks first, then builds \(last) in the stable copy and installs the app.")
                }
            }
            .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.s + 2)
            .overlay(alignment: .bottom) { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
            if items.isEmpty { emptyRow("Nothing queued. A merge shows here while it waits, runs, and after it finished or failed.") }
            ForEach(items) { queueRow($0) }
        }
    }

    private func queueRow(_ item: MergeQueue.Item) -> some View {
        let (word, colour, detail): (String, Color, String?) = switch item.state {
        case .waiting: ("waiting", Tok.wait, item.waitNote)
        case .running: ("running", Tok.work, nil)
        case .done(let detail): ("done", Tok.go, detail)
        case .failed(let reason): ("failed", Tok.stop, reason)
        }
        return HStack(alignment: .firstTextBaseline, spacing: Tok.Space.m) {
            Text(item.card).font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work).frame(width: 44, alignment: .leading)
            Text(item.branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink).lineLimit(1)
            Spacer(minLength: Tok.Space.s)
            if let detail { Text(detail).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled) }
            Text(word).font(Tok.Font.small.weight(.semibold)).foregroundStyle(colour).frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.s + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private func install(_ tag: String, project: ProjectConfig) async {
        guard Self.live, let scripts = model.settings.scriptsDir else { return }
        installing = true; installNote = nil
        let command = MergeQueue.installCommand(scriptsDir: scripts, repoPath: project.repoPath, tag: tag)
        let result = await ProcessToolRunner(timeout: 1800).run(command.tool, command.arguments)
        installing = false
        let out = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
        installNote = result.status == 0 ? "Installed \(tag)." : "Install failed: \(out.isEmpty ? "exit \(result.status)" : out)"
    }

    private func unpushedSection(_ d: GitDetails) -> some View {
        let note = d.remoteURL == nil ? "every commit is local until you create the repository"
                 : d.unpushedCount == 0 ? "everything on \(d.branch ?? "this branch") is pushed" : "on this Mac only, newest first"
        return section("Not pushed", note: note) {
            ForEach(d.unpushed) { c in
                CommitRow(short: c.hash, subject: c.subject, date: c.date, message: messages[c.hash], card: c.card, expanded: expandedCommit == c.hash,
                          onToggle: { toggleMessage(c.hash) })
                    .padding(.horizontal, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
            }
            if d.unpushedCount > d.unpushed.count {
                Text("and \(d.unpushedCount - d.unpushed.count) more").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.m)
            }
        }
    }

    /// Opens or closes a commit's full message; reads it once with `git log -1 --format=%B` (never under XCTest).
    private func toggleMessage(_ hash: String) {
        guard expandedCommit != hash else { expandedCommit = nil; return }
        expandedCommit = hash
        guard Self.live, messages[hash] == nil, let repo = project?.repoPath else { return }
        Task {
            let result = await ProcessToolRunner(timeout: 15).run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", repo, "log", "-1", "--format=%b", hash])
            if result.status == 0 { messages[hash] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private func mergesSection(_ d: GitDetails, project: ProjectConfig) -> some View {
        section("Recent merges on \(project.baseBranch)", note: "with the stable-N tag each one got") {
            if d.merges.isEmpty { emptyRow("No commits on \(project.baseBranch) yet.") }
            ForEach(d.merges) { commitRow($0, showTag: true) }
        }
    }

    private func worktreesSection(_ d: GitDetails) -> some View {
        section("Agent worktrees", note: nil) {
            if d.worktrees.isEmpty { emptyRow("None. Each started task gets one under .agent-worktrees/.") }
            ForEach(d.worktrees) { worktreeRow($0) }
        }
    }

    private func idleBranchesSection(_ d: GitDetails) -> some View {
        let busy = Set(cards.filter { $0.status.holdsAgent }.compactMap(\.branch))
        let idle = GitDetails.idleTaskBranches(d.taskBranches, busy: busy)
        return section("Task branches without an agent", note: nil) {
            if idle.isEmpty { emptyRow("None. Branches of merged cards are deleted when the card is closed.") }
            ForEach(idle, id: \.self) { branch in
                HStack(spacing: Tok.Space.s) {
                    Text(branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink)
                    Spacer()
                    if let card = cards.first(where: { $0.branch == branch }) {
                        Text("\(card.id) · \(card.status.raw)").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    }
                }
                .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.s + 2)
            }
            if !idle.isEmpty {
                Text("Kept until cleaned up; nothing is deleted from here.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                    .padding(.horizontal, Tok.Space.l + 2).padding(.bottom, Tok.Space.m)
            }
        }
    }

    private func ignoreSection(_ project: ProjectConfig) -> some View {
        let info = ignoreProject == nil || ignoreProject == project.id ? ignore : nil
        return VStack(alignment: .leading, spacing: Tok.Space.s + 2) {
            HStack(spacing: Tok.Space.s + 2) {
                Text(".gitignore").font(Tok.Font.heading).foregroundStyle(Tok.ink)
                Spacer()
                Button("Edit…") { editIgnore(project) }.buttonStyle(PanelButtonStyle())
                    .help("Opens the .gitignore editor; nothing is saved before its button.")
            }
            if let info {
                let lines = info.text.map(Gitignore.patterns) ?? []
                if lines.isEmpty {
                    Text(info.text == nil ? "No .gitignore yet." : "The file has no lines.").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                } else {
                    Text(lines.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tok.ink2).lineSpacing(3)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tok.Space.m).padding(.vertical, Tok.Space.s + 2)
                        .background(Tok.bg, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
                }
                Text(Gitignore.agentWorktreesNote(info.agentWorktrees)).font(Tok.Font.small)
                    .foregroundStyle(info.agentWorktrees == .nowhere ? Tok.wait : Tok.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reading…").font(Tok.Font.body).foregroundStyle(Tok.ink3)
            }
        }
        .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius + 2).stroke(Tok.line))
    }

    private func editIgnore(_ project: ProjectConfig) {
        editingIgnore = GitignoreFlow(repoPath: project.repoPath, projectName: project.name,
                                      tool: Self.live ? GitignoreTool(runner: ProcessToolRunner(timeout: 30)) : nil)
    }

    private func otherSection(_ d: GitDetails) -> some View {
        section("Other worktrees", note: nil) {
            ForEach(d.otherWorktrees) { tree in
                HStack(spacing: Tok.Space.s) {
                    Text(tree.folder).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink)
                    Spacer()
                    Text(tree.branch ?? "detached").font(Tok.Font.small).foregroundStyle(Tok.ink3)
                }
                .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.s + 2)
                .help(tree.path)
            }
        }
    }

    // MARK: Rows

    private func commitRow(_ c: GitCommit, showTag: Bool) -> some View {
        HStack(spacing: Tok.Space.m) {
            Text(c.hash).font(Tok.Font.mono).foregroundStyle(Tok.ink3).frame(width: 60, alignment: .leading)
            Text(c.card ?? "").font(Tok.Font.small.weight(.semibold)).foregroundStyle(Tok.work).frame(width: 44, alignment: .leading)
            Text(c.subject).font(Tok.Font.body).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showTag, let tag = c.tag {
                Text(tag).font(.system(size: 10, design: .monospaced)).foregroundStyle(Tok.ink)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Tok.work.opacity(0.12), in: Capsule()).overlay(Capsule().stroke(Tok.work.opacity(0.4)))
            }
            Text(GitDetails.ago(c.date)).font(Tok.Font.small).foregroundStyle(Tok.ink3).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.s + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
        .help(c.subject)
        .accessibilityElement(children: .combine)
    }

    private func worktreeRow(_ tree: GitWorktree) -> some View {
        let card = cards.first { $0.branch != nil && $0.branch == tree.branch }
        let running = card?.status.holdsAgent == true
        return HStack(spacing: Tok.Space.s + 2) {
            Circle().fill(running ? Tok.work : Tok.ink3).frame(width: 8, height: 8)
                .help(running ? "An agent is on this card." : "No running agent.")
            VStack(alignment: .leading, spacing: 2) {
                Text(tree.branch ?? tree.folder).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink)
                Text(card.map { [$0.agent, $0.title.hasPrefix($0.id) ? $0.title : "\($0.id) · \($0.title)"].compactMap { $0 }.joined(separator: " · ") } ?? "no card names this branch")
                    .font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let ahead = tree.ahead { Text("\(ahead) ahead").font(Tok.Font.small).foregroundStyle(Tok.ink2) }
            if let dirty = tree.dirty {
                Text(dirty == 0 ? "clean" : "\(dirty) uncommitted").font(Tok.Font.small).foregroundStyle(dirty == 0 ? Tok.go : Tok.wait)
            }
        }
        .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.s + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.line.opacity(0.6)).frame(height: 1) }
        .help(tree.path)
        .accessibilityElement(children: .combine)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(Tok.Font.body).foregroundStyle(Tok.ink3).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.m)
    }

    private func section<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Tok.Space.s + 2) {
                Text(title).font(Tok.Font.heading).foregroundStyle(Tok.ink)
                if let note { Text(note).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1) }
            }
            .padding(.horizontal, Tok.Space.l + 2).padding(.vertical, Tok.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Tok.line).frame(height: 1) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius + 2))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius + 2).stroke(Tok.line))
        .clipShape(RoundedRectangle(cornerRadius: Tok.radius + 2))
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
