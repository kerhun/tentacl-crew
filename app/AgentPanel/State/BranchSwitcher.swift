import Foundation
import Observation

/// What the branch menu needs to know about the project folder (N180).
struct BranchState: Equatable {
    /// nil when detached.
    var current: String?
    /// Local branches, as git sorts them.
    var local: [String]
    /// Branches checked out in another worktree: true when that worktree is an agent's (`.agent-worktrees/`).
    var heldElsewhere: [String: Bool]
    /// Uncommitted files in the project folder (untracked ones too).
    var uncommitted: Int
    /// A merge, rebase or cherry-pick stopped half way in the project folder.
    var mergeInProgress: Bool
}

/// One branch in the menu.
struct BranchRow: Equatable, Identifiable {
    let name: String
    let current: Bool
    let note: String?
    let selectable: Bool
    var id: String { name }
}

/// The branch menu's decisions, pure (N180). Switching never deletes a branch and never stashes: a folder with uncommitted changes
/// is refused with the reason instead.
enum BranchSwitcher {
    static let maxNameLength = 100

    /// Why `name` cannot be a branch name (git's check-ref-format rules, plus a length cap); nil when it can.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Type a branch name." }
        if name.count > maxNameLength { return "A branch name is at most \(maxNameLength) characters." }
        if name.contains(where: { $0 == " " }) { return "A branch name cannot hold spaces." }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "A branch name cannot hold tabs or control characters." }
        if let bad = name.first(where: { "~^:?*[\\".contains($0) }) { return "A branch name cannot hold \"\(bad)\"." }
        if name.contains("..") { return "A branch name cannot hold \"..\"." }
        if name.contains("@{") || name == "@" { return "A branch name cannot be \"@\" or hold \"@{\"." }
        if name == "HEAD" { return "HEAD is not a branch name." }
        if name.hasPrefix("-") { return "A branch name cannot start with \"-\"." }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.contains("//") { return "A branch name cannot start or end with \"/\" or hold \"//\"." }
        if name.hasSuffix(".") { return "A branch name cannot end with \".\"." }
        for part in name.split(separator: "/") {
            if part.hasPrefix(".") { return "No part of a branch name can start with \".\"." }
            if part.hasSuffix(".lock") { return "No part of a branch name can end with \".lock\"." }
        }
        return nil
    }

    /// The name to offer as "Create <name> … and switch": typed, valid and not a local branch yet.
    static func createOffer(_ query: String, state: BranchState) -> String? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, nameProblem(name) == nil, !state.local.contains(name) else { return nil }
        return name
    }

    /// The main branch first, then the rest in git's order; branches checked out elsewhere are listed but cannot be picked.
    static func rows(_ state: BranchState, main: String) -> [BranchRow] {
        let ordered = state.local.filter { $0 == main } + state.local.filter { $0 != main }
        return ordered.map { name in
            let current = name == state.current
            if let agent = state.heldElsewhere[name], !current {
                return BranchRow(name: name, current: false, note: agent ? "in an agent worktree" : "in another worktree", selectable: false)
            }
            return BranchRow(name: name, current: current, note: name == main ? "merges go here" : nil, selectable: !current)
        }
    }

    static func matching(_ rows: [BranchRow], query: String) -> [BranchRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? rows : rows.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Why the folder cannot leave its branch now; nil when it can. `mergeRunning`: the panel is merging a card right now.
    static func leaveProblem(_ state: BranchState, mergeRunning: Bool) -> String? {
        if mergeRunning { return "A merge is running. Switch when it is done." }
        if state.mergeInProgress { return "A merge, rebase or cherry-pick is in progress in the project folder. Finish or abort it first." }
        if state.uncommitted > 0 {
            let one = state.uncommitted == 1
            return "The project folder has \(state.uncommitted) uncommitted file\(one ? "" : "s"). Commit \(one ? "it" : "them") first; a switch never stashes."
        }
        return nil
    }

    static func switchProblem(to branch: String, state: BranchState, mergeRunning: Bool) -> String? {
        if branch == state.current { return "The folder is already on \(branch)." }
        guard state.local.contains(branch) else { return "There is no local branch \(branch)." }
        if let agent = state.heldElsewhere[branch] { return "\(branch) is checked out in \(agent ? "an agent worktree" : "another worktree")." }
        return leaveProblem(state, mergeRunning: mergeRunning)
    }

    static func createProblem(_ name: String, state: BranchState, mergeRunning: Bool) -> String? {
        if let problem = nameProblem(name) { return problem }
        if state.local.contains(name) { return "\(name) exists already." }
        return leaveProblem(state, mergeRunning: mergeRunning)
    }

    /// Shown on the Git screen while the folder is not on the main branch.
    static func awayNote(current: String?, main: String) -> String? {
        current == main ? nil
            : "Agents keep working in their own worktrees. While this folder is on another branch, merges wait until you switch back to \(main)."
    }

    /// The menu's footer.
    static func menuNote(main: String) -> String {
        "Agents keep working in their own worktrees. While this folder is on another branch, merges wait until you switch back to \(main). Uncommitted changes block a switch."
    }
}

/// Reads `BranchState` with read-only git and runs `git switch` / `git switch -c` after checking the rules again on fresh state.
struct BranchSwitchRunner: Sendable {
    var runner: GitToolRunning
    var git = URL(fileURLWithPath: "/usr/bin/git")

    private func git(_ repo: String, _ args: [String]) async -> ScriptResult { await runner.run(git, ["-C", repo] + args) }

    func read(repoPath: String) async -> BranchState {
        let head = await git(repoPath, ["symbolic-ref", "--short", "-q", "HEAD"])
        let current = head.status == 0 ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let local = Self.lines(await git(repoPath, ["for-each-ref", "--format=%(refname:short)", "refs/heads/"]))
        let repo = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        var held: [String: Bool] = [:]
        for tree in GitDetails.parseWorktrees(await git(repoPath, ["worktree", "list", "--porcelain"]).stdout) {
            guard let branch = tree.branch, URL(fileURLWithPath: tree.path).standardizedFileURL.path != repo else { continue }
            held[branch] = tree.path.hasPrefix(repo + "/.agent-worktrees/")
        }
        let uncommitted = Self.lines(await git(repoPath, GitDetailsReader.statusArguments)).count
        var stopped = false
        for ref in ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"] where !stopped {
            stopped = await git(repoPath, ["rev-parse", "--verify", "-q", ref]).status == 0
        }
        return BranchState(current: current.isEmpty ? nil : current, local: local, heldElsewhere: held, uncommitted: uncommitted, mergeInProgress: stopped)
    }

    /// git's error text or the refusal; nil when the folder is now on `branch`.
    func switchTo(_ branch: String, repoPath: String, mergeRunning: Bool) async -> String? {
        let state = await read(repoPath: repoPath)
        if let problem = BranchSwitcher.switchProblem(to: branch, state: state, mergeRunning: mergeRunning) { return problem }
        // A local branch name (listed by git) cannot start with "-", so it is never read as an option.
        let result = await git(repoPath, ["switch", branch])
        return result.status == 0 ? nil : GitPublisher.errorText(result, "git switch")
    }

    func create(_ name: String, repoPath: String, mergeRunning: Bool) async -> String? {
        if let problem = BranchSwitcher.nameProblem(name) { return problem }
        let state = await read(repoPath: repoPath)
        if let problem = BranchSwitcher.createProblem(name, state: state, mergeRunning: mergeRunning) { return problem }
        let result = await git(repoPath, ["switch", "-c", name])
        return result.status == 0 ? nil : GitPublisher.errorText(result, "git switch -c")
    }

    private static func lines(_ result: ScriptResult) -> [String] {
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The branch menu's state: read when it opens, and the last refusal or git error.
@Observable @MainActor
final class BranchMenuModel {
    private(set) var state: BranchState?
    var query = ""
    private(set) var working = false
    private(set) var error: String?
    /// Nil under XCTest unless a test sets one.
    @ObservationIgnored var runner: BranchSwitchRunner?

    init(runner: BranchSwitchRunner?, state: BranchState? = nil) {
        self.runner = runner; self.state = state
    }

    func load(repoPath: String) async {
        guard let runner else { return }
        state = await runner.read(repoPath: repoPath)
    }

    func reset() { query = ""; error = nil }

    @discardableResult
    func switchTo(_ branch: String, repoPath: String, mergeRunning: Bool, onDone: () -> Void) async -> Bool {
        if let state, let problem = BranchSwitcher.switchProblem(to: branch, state: state, mergeRunning: mergeRunning) { error = problem; return false }
        return await run(repoPath: repoPath, onDone: onDone) { await $0.switchTo(branch, repoPath: repoPath, mergeRunning: mergeRunning) }
    }

    @discardableResult
    func create(_ name: String, repoPath: String, mergeRunning: Bool, onDone: () -> Void) async -> Bool {
        if let state, let problem = BranchSwitcher.createProblem(name, state: state, mergeRunning: mergeRunning) { error = problem; return false }
        return await run(repoPath: repoPath, onDone: onDone) { await $0.create(name, repoPath: repoPath, mergeRunning: mergeRunning) }
    }

    private func run(repoPath: String, onDone: () -> Void, _ action: (BranchSwitchRunner) async -> String?) async -> Bool {
        guard let runner, !working else { return false }
        working = true; error = nil
        let failure = await action(runner)
        state = await runner.read(repoPath: repoPath)
        working = false
        if let failure { error = failure; return false }
        query = ""
        onDone()
        return true
    }
}
