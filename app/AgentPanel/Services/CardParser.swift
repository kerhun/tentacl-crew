import Foundation
import CryptoKit

enum CardParseError: Error, Equatable {
    case noFrontMatter
    case missingID
}

/// Parses a task card. No YAML library: the front matter is `key: value` lines plus an optional `files:` list.
enum CardParser {
    static func parse(_ text: String, url: URL) throws -> TaskCard {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else {
            throw CardParseError.noFrontMatter
        }
        let (fields, lists) = frontMatter(Array(lines[1..<close]))
        let files = lists["files"] ?? [], roles = lists["roles"] ?? []
        guard let id = fields["id"], !id.isEmpty else { throw CardParseError.missingID }

        let body = Array(lines[(close + 1)...])
        let title = body.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? id
        return TaskCard(
            id: id,
            project: fields["project"] ?? "",
            status: TaskStatus(raw: fields["status"] ?? ""),
            agent: nonEmpty(fields["agent"]),
            branch: nonEmpty(fields["branch"]),
            kind: nonEmpty(fields["kind"]),
            files: files,
            title: title,
            sections: sections(body),
            url: url,
            fingerprint: digest(lines[1..<close]),
            bodyFingerprint: digest(body[...]),
            roles: roles,
            from: nonEmpty(fields["from"]),
            priority: CardPriority(rawValue: unquote(fields["priority"] ?? "").lowercased()) ?? .normal)
    }

    private static func digest(_ lines: ArraySlice<String>) -> String {
        SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
        return v
    }

    /// Returns the scalar fields and the list fields (`files`, `roles`), each as block `- item` lines or inline `[a, b]`.
    private static func frontMatter(_ lines: [String]) -> ([String: String], [String: [String]]) {
        let listKeys: Set<String> = ["files", "roles"]
        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var inList: String?
        for line in lines {
            if let key = inList, let item = listItem(line) { lists[key, default: []].append(unquote(item)); continue }
            inList = nil
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if listKeys.contains(key) {
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    lists[key] = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
                } else if !value.isEmpty {
                    lists[key] = [unquote(value)]   // `roles: reviewer` is a list of one, not an empty list
                } else {
                    inList = key
                    lists[key] = lists[key] ?? []
                }
            } else {
                // a key written twice is ambiguous: `from` then becomes a value no start accepts, instead of silently using one line
                fields[key] = (key == "from" && fields[key] != nil) ? "(repeated)" : value
            }
        }
        return (fields, lists)
    }

    private static func listItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        return String(trimmed.dropFirst(2))
    }

    private static func sections(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var name: String?
        var buffer: [String] = []
        func flush() {
            if let name { result[name] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                buffer = []
            } else if name != nil {
                buffer.append(line)
            }
        }
        flush()
        return result
    }
}
