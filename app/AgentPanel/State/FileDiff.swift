import Foundation

/// One file of a task's change list, from `git diff --name-status -M -z` (N204).
struct DiffFileEntry: Equatable, Identifiable, Hashable {
    enum Status: Equatable, Hashable { case added, modified, deleted, renamed(Int), copied(Int), typeChanged, other }
    let status: Status
    let path: String
    /// The old path of a rename or copy.
    var oldPath: String? = nil
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    var letter: String {
        switch status {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .other: return "?"
        }
    }

    /// NUL-separated records: "M\0path\0", "R087\0old\0new\0".
    static func parseNameStatus(_ text: String) -> [DiffFileEntry] {
        var fields = text.components(separatedBy: "\0")[...]
        var out: [DiffFileEntry] = []
        while let code = fields.popFirst(), !code.isEmpty {
            let kind = code.first!, score = Int(code.dropFirst()) ?? 100
            if kind == "R" || kind == "C" {
                guard let old = fields.popFirst(), let new = fields.popFirst() else { break }
                out.append(DiffFileEntry(status: kind == "R" ? .renamed(score) : .copied(score), path: new, oldPath: old))
                continue
            }
            guard let path = fields.popFirst() else { break }
            let status: Status
            switch kind {
            case "A": status = .added
            case "M": status = .modified
            case "D": status = .deleted
            case "T": status = .typeChanged
            default: status = .other
            }
            out.append(DiffFileEntry(status: status, path: path))
        }
        return out
    }
}

/// One file's unified diff, parsed from plain `git diff` output (N204).
struct FileDiff: Equatable {
    enum Kind: Equatable { case modified, added, deleted, renamed(similarity: Int), copied(similarity: Int) }

    struct Line: Equatable {
        enum Kind: Equatable { case context, added, removed }
        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String
        /// "\ No newline at end of file" followed this line.
        var noNewline = false
    }

    struct Hunk: Equatable {
        let header: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        var lines: [Line] = []
    }

    var oldPath: String?
    var newPath: String?
    var kind: Kind = .modified
    var binary = false
    var oldMode: String?
    var newMode: String?
    var hunks: [Hunk] = []

    var path: String { newPath ?? oldPath ?? "" }
    var addedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var removedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    /// What the file's header says beside the counts; nil for a plain change.
    var note: String? {
        var parts: [String] = []
        switch kind {
        case .added: parts.append("New file")
        case .deleted: parts.append("Deleted file")
        case .renamed(let s): parts.append("Renamed from \(oldPath ?? "?")" + (s < 100 ? " (\(s)% similar)" : ""))
        case .copied(let s): parts.append("Copied from \(oldPath ?? "?")" + (s < 100 ? " (\(s)% similar)" : ""))
        case .modified: break
        }
        if binary { parts.append("Binary file, no text diff") }
        if let oldMode, let newMode, oldMode != newMode { parts.append("Mode \(oldMode) → \(newMode)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// All files of a `git diff` output.
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var oldLine = 0, newLine = 0

        func closeHunk() { if let h = hunk { current?.hunks.append(h) }; hunk = nil }
        func closeFile() { closeHunk(); if let f = current { files.append(f) }; current = nil }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line.hasPrefix("diff --git ") {
                closeFile()
                var f = FileDiff()
                if let paths = gitLinePaths(String(line.dropFirst("diff --git ".count))) { f.oldPath = paths.old; f.newPath = paths.new }
                current = f
                continue
            }
            guard current != nil else { continue }
            if var h = hunk {
                // Inside a hunk until its counts are used up; a header line can then start the next one.
                let open = oldLine < h.oldStart + h.oldCount || newLine < h.newStart + h.newCount
                if line.hasPrefix("\\") {
                    if !h.lines.isEmpty { h.lines[h.lines.count - 1].noNewline = true }
                    hunk = h; continue
                }
                if open, case let first = line.first ?? " ", first == " " || first == "+" || first == "-" {
                    let body = String(line.dropFirst())
                    switch first {
                    case "+": h.lines.append(Line(kind: .added, old: nil, new: newLine, text: body)); newLine += 1
                    case "-": h.lines.append(Line(kind: .removed, old: oldLine, new: nil, text: body)); oldLine += 1
                    default: h.lines.append(Line(kind: .context, old: oldLine, new: newLine, text: body)); oldLine += 1; newLine += 1
                    }
                    hunk = h; continue
                }
            }
            if line.hasPrefix("@@"), let h = parseHunkHeader(line) {
                closeHunk()
                hunk = h; oldLine = h.oldStart; newLine = h.newStart
                continue
            }
            closeHunk()
            if line.hasPrefix("new file mode ") { current?.kind = .added; current?.newMode = String(line.dropFirst("new file mode ".count)) }
            else if line.hasPrefix("deleted file mode ") { current?.kind = .deleted; current?.oldMode = String(line.dropFirst("deleted file mode ".count)) }
            else if line.hasPrefix("old mode ") { current?.oldMode = String(line.dropFirst("old mode ".count)) }
            else if line.hasPrefix("new mode ") { current?.newMode = String(line.dropFirst("new mode ".count)) }
            else if line.hasPrefix("similarity index ") {
                let s = Int(line.dropFirst("similarity index ".count).dropLast()) ?? 100
                current?.kind = .renamed(similarity: s)
            }
            else if line.hasPrefix("rename from ") { current?.oldPath = unquote(String(line.dropFirst("rename from ".count))) }
            else if line.hasPrefix("rename to ") { current?.newPath = unquote(String(line.dropFirst("rename to ".count))) }
            else if line.hasPrefix("copy from ") {
                if case .renamed(let s) = current?.kind { current?.kind = .copied(similarity: s) }
                current?.oldPath = unquote(String(line.dropFirst("copy from ".count)))
            }
            else if line.hasPrefix("copy to ") { current?.newPath = unquote(String(line.dropFirst("copy to ".count))) }
            else if line.hasPrefix("Binary files ") || line == "GIT binary patch" { current?.binary = true }
            else if line.hasPrefix("--- ") { if let p = sidePath(String(line.dropFirst(4)), prefix: "a/") { current?.oldPath = p } }
            else if line.hasPrefix("+++ ") { if let p = sidePath(String(line.dropFirst(4)), prefix: "b/") { current?.newPath = p } }
        }
        closeFile()
        // A new or deleted file names the missing side /dev/null: keep both paths the same so `path` is the real one.
        return files.map { f in
            var f = f
            if f.kind == .added { f.oldPath = nil }
            if f.kind == .deleted { f.newPath = nil; if f.oldPath == nil { f.oldPath = f.path } }
            return f
        }
    }

    /// "@@ -12,7 +12,9 @@ func x()": a missing count is 1.
    static func parseHunkHeader(_ line: String) -> Hunk? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(nums[0]) else { return nil }
            return (start, nums.count > 1 ? Int(nums[1]) ?? 1 : 1)
        }
        guard let o = range(parts[1]), let n = range(parts[2]) else { return nil }
        // A count of 0 names the line before the (empty) range; the first real line is the one after.
        return Hunk(header: line, oldStart: o.1 == 0 ? o.0 + 1 : o.0, oldCount: o.1, newStart: n.1 == 0 ? n.0 + 1 : n.0, newCount: n.1)
    }

    /// "a/x b/x" (no quotes when the paths hold no special characters); splits where the two halves name the same file when possible.
    static func gitLinePaths(_ rest: String) -> (old: String, new: String)? {
        if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
            let old = unquote(String(rest[...end])), tail = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces)
            return (strip(old, "a/"), strip(unquote(tail), "b/"))
        }
        guard rest.hasPrefix("a/") else { return nil }
        let body = rest.dropFirst(2)
        // Same path on both sides: "a/<p> b/<p>".
        if body.count % 2 == 1 {
            let half = (body.count - 3) / 2
            if half >= 0 {
                let left = body.prefix(half), right = body.suffix(half)
                if body.dropFirst(half).hasPrefix(" b/") && left == right { return (String(left), String(right)) }
            }
        }
        guard let split = body.range(of: " b/", options: .backwards) else { return nil }
        return (String(body[..<split.lowerBound]), String(body[split.upperBound...]))
    }

    private static func sidePath(_ text: String, prefix: String) -> String? {
        let t = unquote(text.trimmingCharacters(in: CharacterSet(charactersIn: "\t")))
        if t == "/dev/null" { return nil }
        return strip(t, prefix)
    }

    private static func strip(_ text: String, _ prefix: String) -> String { text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text }

    /// git's C-style quoting ("\"a/sp\\303\\251\""): escapes and octal bytes back to text.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var bytes: [UInt8] = []
        var chars = Array(text.utf8.dropFirst().dropLast())[...]
        while let c = chars.popFirst() {
            guard c == UInt8(ascii: "\\"), let e = chars.popFirst() else { bytes.append(c); continue }
            switch e {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(e - 48)
                for _ in 0..<2 { if let d = chars.first, d >= 48, d <= 55 { value = value * 8 + Int(d - 48); chars.removeFirst() } }
                bytes.append(UInt8(value & 0xFF))
            default: bytes.append(e)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Rows

    /// One row of the unified view.
    enum Row: Equatable {
        case hunk(String)
        case line(Line)
        /// Unchanged lines git left out: `count` lines starting at old/new line numbers; `id` is stable for the expand state.
        case gap(id: Int, count: Int, old: Int, new: Int)
    }

    static let rowLimit = 3000

    /// The rows of the view: the hunks, with the unchanged stretches between them (and before and after) as gaps; an expanded gap shows
    /// its lines from `newText` (the file at the branch). Without `newText` no gap is offered (nothing to show).
    func rows(newText: String?, expanded: Set<Int> = []) -> [Row] {
        let fileLines: [String]? = newText.map { t in
            var l = t.components(separatedBy: "\n"); if l.last == "" { l.removeLast() }; return l
        }
        var rows: [Row] = []
        var nextNew = 1, nextOld = 1
        func gap(id: Int, upTo newEnd: Int) {
            guard let fileLines else { return }
            let count = min(newEnd, fileLines.count + 1) - nextNew
            guard count > 0 else { return }
            if expanded.contains(id) {
                for i in 0..<count {
                    rows.append(.line(Line(kind: .context, old: nextOld + i, new: nextNew + i, text: fileLines[nextNew + i - 1])))
                }
            } else {
                rows.append(.gap(id: id, count: count, old: nextOld, new: nextNew))
            }
        }
        for (i, h) in hunks.enumerated() {
            if kind == .modified || isRenameOrCopy { gap(id: i, upTo: h.newStart) }
            rows.append(.hunk(h.header))
            rows += h.lines.map(Row.line)
            nextNew = h.newStart + h.newCount; nextOld = h.oldStart + h.oldCount
        }
        if !hunks.isEmpty, kind == .modified || isRenameOrCopy { gap(id: hunks.count, upTo: Int.max - 1) }
        return rows
    }

    private var isRenameOrCopy: Bool {
        switch kind { case .renamed, .copied: return true; default: return false }
    }
}
