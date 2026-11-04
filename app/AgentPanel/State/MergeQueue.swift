import Foundation
import Observation

/// The merge queue (N209): every merge the panel does goes through here, one at a time across the whole app (also across projects: a merge
/// moves a branch of one repository and starts a build of the packet on the same machine). Approve (sheet, round, the PM's request and the
/// autopilot all end in `PanelModel.confirmApprove`) waits its turn; a merge that `scripts/merge-queue.sh` does (the PM's command) holds the
/// script's lock folder, and the queue waits for it too, so two merges never run together.
@Observable @MainActor
final class MergeQueue {
    enum State: Equatable {
        case waiting
        case running
        /// Merged (or approved); `detail` is the commit and the tag when known.
        case done(detail: String?)
        case failed(reason: String)
    }

    struct Item: Identifiable, Equatable {
        let id: Int
        let project: String
        let card: String
        let branch: String
        var state: State
        let queuedAt: Date
        var finishedAt: Date?
        /// Why a waiting item has not started ("another merge is running").
        var waitNote: String?
    }

    /// Finished items kept for the Git screen.
    static let keepFinished = 10

    private(set) var items: [Item] = []
    private var nextID = 1
    private var turn: [(id: Int, resume: CheckedContinuation<Void, Never>)] = []
    private var active = false
    /// True while a merge outside the app holds the script's lock (`merge-queue.sh`).
    @ObservationIgnored var externalMerge: () -> Bool
    @ObservationIgnored var externalPoll: Duration = .seconds(2)
    @ObservationIgnored var now: () -> Date = Date.init

    /// Where the lock folder lives (`merge-queue.sh` uses the same one); nil: the queue takes no lock (tests).
    let lockRoot: URL?
    private var holdsLock = false

    init(externalMerge: @escaping () -> Bool = { false }, lockRoot: URL? = nil) { self.externalMerge = externalMerge; self.lockRoot = lockRoot }

    private var lockFolder: URL? { lockRoot?.appendingPathComponent(".merge-queue.lock") }

    /// Takes the script's lock folder (mkdir; the pid of the app inside). A lock whose process is gone is taken over. False: someone else holds it.
    private func acquireLock() -> Bool {
        guard let folder = lockFolder else { return true }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        for _ in 0..<3 {
            if (try? fm.createDirectory(at: folder, withIntermediateDirectories: false)) != nil {
                try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: folder.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
                holdsLock = true
                return true
            }
            if Self.scriptLockHeld(buildRoot: folder.deletingLastPathComponent()) { return false }
            let stale = folder.appendingPathExtension("stale.\(ProcessInfo.processInfo.processIdentifier)")
            if (try? fm.moveItem(at: folder, to: stale)) != nil { try? fm.removeItem(at: stale) }
        }
        return false
    }

    private func releaseLock() {
        guard holdsLock, let folder = lockFolder else { return }
        holdsLock = false
        try? FileManager.default.removeItem(at: folder)
    }

    var isRunning: Bool { active }
    func isRunning(project: String) -> Bool { items.contains { $0.project == project && $0.state == .running } }
    func items(for project: String) -> [Item] { items.filter { $0.project == project } }

    /// The lock folder `merge-queue.sh` holds, with the pid of its owner; held only while that process lives.
    nonisolated static func scriptLockHeld(buildRoot: URL = defaultBuildRoot) -> Bool {
        let pidFile = buildRoot.appendingPathComponent(".merge-queue.lock/pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return FileManager.default.fileExists(atPath: buildRoot.appendingPathComponent(".merge-queue.lock").path)
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated static var defaultBuildRoot: URL {
        if let root = ProcessInfo.processInfo.environment["AGENT_PANEL_BUILD_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/agent-panel/build")
    }

    /// Queues one merge and runs `work` when it is its turn. `work` returns nil on success (or a detail text through `done`), else the
    /// reason it failed. Returns what `work` returned; the item stays on the list as done or failed.
    @discardableResult
    func run(project: String, card: String, branch: String, work: () async -> MergeOutcome) async -> MergeOutcome {
        let id = nextID; nextID += 1
        items.append(Item(id: id, project: project, card: card, branch: branch, state: .waiting, queuedAt: now(), waitNote: nil))
        if active { setNote(id, "waiting for the merge before it") }
        await waitForTurn(id)
        update(id) { $0.state = .running; $0.waitNote = nil }
        let outcome = await work()
        releaseLock()
        update(id) {
            $0.finishedAt = now()
            switch outcome {
            case .merged(let detail): $0.state = .done(detail: detail)
            case .failed(let reason): $0.state = .failed(reason: reason)
            }
        }
        trim()
        // The next one in line inherits the turn (`active` stays true), so a new request cannot jump the queue.
        if turn.isEmpty { active = false } else { turn.removeFirst().resume.resume() }
        return outcome
    }

    private func waitForTurn(_ id: Int) async {
        if active { await withCheckedContinuation { turn.append((id, $0)) } } else { active = true }
        // A merge started outside the app holds the script's lock folder: wait until it is gone.
        // The app holds the same lock while it merges, so merge-queue.sh waits for the app too.
        while externalMerge() || !acquireLock() {
            setNote(id, "waiting for a merge started by merge-queue.sh")
            try? await Task.sleep(for: externalPoll)
        }
    }

    private func setNote(_ id: Int, _ text: String) { update(id) { $0.waitNote = text } }
    private func update(_ id: Int, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    private func trim() {
        let finished = items.filter { if case .waiting = $0.state { false } else if case .running = $0.state { false } else { true } }
        guard finished.count > Self.keepFinished else { return }
        let drop = Set(finished.prefix(finished.count - Self.keepFinished).map(\.id))
        items.removeAll { drop.contains($0.id) }
    }

    /// The highest `stable-N` among the tags; nil when there is none.
    static func lastStable(in tags: [String]) -> String? {
        let numbers = tags.compactMap { tag -> Int? in
            guard tag.hasPrefix(GitPublisher.tagPrefix) else { return nil }
            return Int(tag.dropFirst(GitPublisher.tagPrefix.count))
        }
        return numbers.max().map { "\(GitPublisher.tagPrefix)\($0)" }
    }

    /// The result line `merge-queue.sh` prints on success: "N1 merged abc1234 stable-3".
    static func parseResult(_ line: String) -> (card: String, sha: String, tag: String)? {
        let w = line.split(separator: " ").map(String.init)
        guard w.count == 4, w[1] == "merged", w[3].hasPrefix(GitPublisher.tagPrefix) else { return nil }
        return (w[0], w[2], w[3])
    }
}

extension MergeQueue {
    /// What "Install stable-N" runs (after the user confirmed): release-stable.sh from the scripts folder, for this project's repository.
    static func installCommand(scriptsDir: URL, repoPath: String, tag: String) -> (tool: URL, arguments: [String]) {
        (URL(fileURLWithPath: "/bin/bash"), [scriptsDir.appendingPathComponent("release-stable.sh").path, "--source", repoPath, tag])
    }

    /// The same command as the user reads it in the confirmation.
    static func installText(repoPath: String, tag: String) -> String { "release-stable.sh --source \(repoPath) \(tag)" }
}

enum MergeOutcome: Equatable {
    case merged(detail: String?)
    case failed(String)

    var failure: String? { if case .failed(let r) = self { r } else { nil } }
}
