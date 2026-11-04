import Foundation

/// Which conversation Resume continues, and whether Resume is offered at all.
enum ResumeSession {
    /// The session to resume for an agent that ran in `cwd`: the id the panel last saw for it (when its session file still exists),
    /// else the newest session file of that folder (Claude: `<projects>/<slug>/*.jsonl`; Codex: the newest file whose `cwd` matches).
    /// Nil when there is none.
    static func pick(known: String?, tool: AgentTool, cwd: String, claudeRoot: URL, codexRoot: URL) -> String? {
        let folders = [cwd, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        switch tool {
        case .claude:
            let dirs = folders.map { TranscriptReader.path(projectsRoot: claudeRoot, cwd: $0, session: "x").deletingLastPathComponent() }
            if let id = known, !id.isEmpty, dirs.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(id).jsonl").path) }) { return id }
            var files: [(id: String, modified: Date)] = []
            for dir in dirs {
                let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
                for url in urls where url.pathExtension == "jsonl" {
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    if values?.isRegularFile == true { files.append((url.deletingPathExtension().lastPathComponent, values?.contentModificationDate ?? .distantPast)) }
                }
            }
            return files.sorted { $0.modified == $1.modified ? $0.id > $1.id : $0.modified > $1.modified }.first?.id
        case .codex:
            if let id = known, !id.isEmpty, CodexSessionReader.find(root: codexRoot, sessionID: id, cwd: nil) != nil { return id }
            for folder in folders {
                if let url = CodexSessionReader.sessions(root: codexRoot, cwd: folder).first, let id = CodexSessionReader.meta(url)?.id { return id }
            }
            return nil
        }
    }

    /// Resume agent: offered (non-nil) only for a card that is doing or needs a fix, has no live agent, and whose worktree is still there.
    /// Enabled unless the panel cannot act or another action is running.
    static func buttonState(card: TaskCard, agentLive: Bool, worktreeExists: Bool, canAct: Bool = true, reason: String? = nil, busy: Bool = false) -> StartButtonState? {
        guard card.status == .doing || card.status == .needsFix, !agentLive, worktreeExists, card.branch != nil else { return nil }
        if !canAct { return StartButtonState(enabled: false, help: reason ?? "Starting agents is not set up for this project.") }
        if busy { return StartButtonState(enabled: false, help: "Another action is running; wait until it finishes.") }
        return StartButtonState(enabled: true, help: "Start the agent again in its worktree and continue its last conversation.")
    }

    static func noneFound(_ what: String) -> String { "No earlier conversation was found for \(what), so there is nothing to resume." }

    /// The line the resumed agent gets so it carries on at once.
    static func nudge(cardPath: String) -> String {
        "The panel resumed this conversation after your session ended. Carry on with your task card: \(cardPath). When finished, fill the card's Report section and tell me briefly."
    }
}
