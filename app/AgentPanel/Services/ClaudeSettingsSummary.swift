import Foundation

/// A short, safe description of the Claude settings that also apply to an agent: which file, how many permission rules, which hooks
/// and MCP servers. Only counts and names are read. Values (environment variables, hook commands, MCP headers) are never shown.
enum ClaudeSettingsSummary {
    static func lines(claudeHome: URL, repo: URL?, roleSkills: [String] = []) -> [String] {
        var files: [(label: String, url: URL, isProject: Bool)] = [("~/.claude/settings.json", claudeHome.appendingPathComponent("settings.json"), false)]
        if let repo {
            files.append((".claude/settings.json in the project", repo.appendingPathComponent(".claude/settings.json"), true))
            files.append((".claude/settings.local.json in the project", repo.appendingPathComponent(".claude/settings.local.json"), true))
        }
        var out: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file.url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var parts: [String] = []
            if let p = object["permissions"] as? [String: Any] {
                if let allow = p["allow"] as? [Any], !allow.isEmpty { parts.append(plural(allow.count, "allow rule")) }
                if let deny = p["deny"] as? [Any], !deny.isEmpty { parts.append(plural(deny.count, "deny rule")) }
            }
            if let hooks = object["hooks"] as? [String: Any], !hooks.isEmpty { parts.append("hooks: " + hooks.keys.sorted().joined(separator: ", ")) }
            if let mcp = object["mcpServers"] as? [String: Any], !mcp.isEmpty { parts.append("MCP servers: " + mcp.keys.sorted().joined(separator: ", ")) }
            if let env = object["env"] as? [String: Any], !env.isEmpty { parts.append("sets " + plural(env.count, "environment variable")) }
            if !parts.isEmpty { out.append("\(file.label): " + parts.joined(separator: "; ")) }

            if file.isProject, let plugins = object["enabledPlugins"] as? [String: Any] {
                for (key, value) in plugins.sorted(by: { $0.key < $1.key }) where (value as? Bool) == true {
                    let name = String(key.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                    if !roleSkills.contains(name) { out.append("The project turns on the plugin \(name); it stays on for this agent because the skills list does not switch it off.") }
                }
            }
        }
        return out
    }

    private static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
