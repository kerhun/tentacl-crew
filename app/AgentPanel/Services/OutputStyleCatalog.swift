import Foundation

/// What a role can choose as its output style: Claude Code's built-in styles, your own (`~/.claude/output-styles/*.md`) and the
/// project's (`<repo>/.claude/output-styles/*.md`). A style file's name is the `name:` of its front matter, else its file name.
struct OutputStyleCatalog {
    /// Claude Code reads the value case-sensitively, with these spellings.
    static let builtIns = ["Default", "Proactive", "Concise", "Explanatory", "Learning"]

    var claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    var repo: URL?

    func names() -> [String] {
        var out = Self.builtIns
        for dir in [claudeHome, repo?.appendingPathComponent(".claude")].compactMap({ $0 }) {
            for name in Self.styleNames(in: dir.appendingPathComponent("output-styles")) where !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// The built-in spelling for a built-in name in any casing (old role files say "concise"); anything else is returned as it is.
    static func canonical(_ name: String) -> String {
        builtIns.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    private static func styleNames(in dir: URL) -> [String] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted()
        return files.compactMap { file in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return frontMatterName(text) ?? String(file.dropLast(3))
        }
    }

    private static func frontMatterName(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { return nil }
            guard line.hasPrefix("name:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
