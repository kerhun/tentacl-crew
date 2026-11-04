import Foundation

/// Reads a worktree's git state from git's exit codes and output (`ProcessRunner` reports neither), for "Clean up…".
struct GitInspector {
    var git = URL(fileURLWithPath: "/usr/bin/git")

    private func run(_ args: [String]) async -> (status: Int32, out: String)? {
        await Task.detached { [git] () -> (status: Int32, out: String)? in
            let process = Process(), pipe = Pipe()
            process.executableURL = git; process.arguments = args
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// A branch is merged when it has no commit that `base` lacks. Anything git cannot answer counts as not merged and dirty (kept).
    func state(repo: String, worktree: String, base: String) async -> WorktreeState {
        guard let head = await run(["-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"]), head.status == 0, head.out != "HEAD", !head.out.isEmpty,
              let status = await run(["-C", worktree, "status", "--porcelain"]), status.status == 0 else { return WorktreeState(branch: nil, dirty: true, merged: false) }
        let ahead = await run(["-C", repo, "rev-list", "--count", "\(base)..\(head.out)"])
        return WorktreeState(branch: head.out, dirty: !status.out.isEmpty, merged: ahead?.status == 0 && ahead?.out == "0")
    }
}
