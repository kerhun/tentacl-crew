import Foundation

/// Validation for values that come from a task card. Cards are written by agents, so their `id` and `branch` are untrusted
/// input: they must be plain ASCII names before they are ever passed to a script, git or the terminal.
enum TaskInput {
    private static func isNameCharacter(_ c: Character, extra: String) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || extra.contains(c)
    }

    private static func startsWithAlphanumeric(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII else { return false }
        return first.isLetter || first.isNumber
    }

    static func validTaskID(_ s: String) -> Bool {
        (1...40).contains(s.count) && startsWithAlphanumeric(s) && s.allSatisfy { isNameCharacter($0, extra: "._-") }
    }

    /// An agent's name: `<role>-<task>-<project tag>`, so the same task id in two projects never names the same agent, simulator or state folder.
    /// The tag is the project id cut to 12 characters. Keep in step with `name=` in spawn-agent.sh.
    static func agentName(role: String, task: String, projectID: String) -> String {
        var tag = String(projectID.lowercased().prefix(12))
        while tag.hasSuffix("-") { tag.removeLast() }
        return "\(role)-\(task)\(tag.isEmpty ? "" : "-" + tag)".lowercased()
    }

    /// Up to 80 characters (role 20 + task 40 + project tag 12 and two dashes); old names without a tag are still valid.
    static func validAgentName(_ s: String) -> Bool {
        (1...80).contains(s.count) && startsWithAlphanumeric(s) && s.allSatisfy { isNameCharacter($0, extra: "._-") }
    }

    static func validBranch(_ s: String) -> Bool {
        guard (1...80).contains(s.count), startsWithAlphanumeric(s), s.allSatisfy({ isNameCharacter($0, extra: "._/-") }) else { return false }
        for part in s.split(separator: "/", omittingEmptySubsequences: false) {
            // empty part: leading/trailing/double slash; "." or ".." or hidden parts; git forbids a ".lock" suffix and a trailing dot
            if part.isEmpty || part.hasPrefix(".") || part.hasSuffix(".lock") || part.hasSuffix(".") { return false }
        }
        return !s.contains("..")
    }
}
