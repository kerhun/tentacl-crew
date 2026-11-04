import Foundation

struct SkillEntry: Equatable, Comparable, Identifiable {
    enum Kind: Int { case userSkill = 0, plugin = 1 }
    let name: String
    let kind: Kind
    var id: String { "\(kind.rawValue):\(name)" }
    static func < (a: SkillEntry, b: SkillEntry) -> Bool { (a.name, a.kind.rawValue) < (b.name, b.kind.rawValue) }
}

/// What a role can choose from: your own skills (`~/.claude/skills/*`) and the plugins Claude knows about (`enabledPlugins`).
/// A plugin is on or off as a whole for an agent; single skills inside a plugin cannot be switched off.
struct SkillCatalog {
    var claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    func installed() -> [SkillEntry] {
        var entries: [SkillEntry] = []
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: claudeHome.appendingPathComponent("skills").path)) ?? []) where !name.hasPrefix(".") {
            entries.append(SkillEntry(name: name, kind: .userSkill))
        }
        if let data = try? Data(contentsOf: claudeHome.appendingPathComponent("settings.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let plugins = object["enabledPlugins"] as? [String: Any] {
            for key in plugins.keys {
                let name = String(key.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                if !name.isEmpty { entries.append(SkillEntry(name: name, kind: .plugin)) }
            }
        }
        return Array(Set(entries.map(\.id))).compactMap { id in entries.first { $0.id == id } }.sorted()
    }
}
