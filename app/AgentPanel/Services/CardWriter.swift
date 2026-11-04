import Foundation

enum CardField: String {
    case status, agent, branch, from
}

/// The two body sections the panel may write besides the front matter lines.
enum CardSection: String {
    case fixNotes = "Fix notes"
    case decision = "Decision"
}

/// One section write: "Fix notes" gets the text appended below what is there, "Decision" has its text replaced.
struct SectionEdit: Equatable {
    let section: CardSection
    let text: String
    init(_ section: CardSection, _ text: String) { self.section = section; self.text = text }
}

/// A change to a card that is not running. A nil field is left as it is; for `kind` and `branch` an empty string removes the line.
struct CardEdit: Equatable {
    var title: String?
    /// Section name to its new text.
    var sections: [String: String] = [:]
    var files: [String]?
    var roles: [String]?
    var kind: String?
    var branch: String?
    var priority: CardPriority?
    var status: TaskStatus?
}

enum CardWriteError: Error, Equatable {
    /// The card's status on disk is not the one the panel last read.
    case conflict(expected: String, found: String)
    case isSymlink
    case unreadable(String)
    case writeFailed(String)
}

/// What the start flow needs from a card writer (a protocol so tests can make a write fail).
protocol CardWriting: Sendable {
    /// Changes front matter lines and at most one body section in a single atomic write.
    func update(_ card: TaskCard, set values: [CardField: String], section: SectionEdit?, expectingStatus: TaskStatus) throws
}

extension CardWriting {
    func update(_ card: TaskCard, set values: [CardField: String], expectingStatus: TaskStatus) throws {
        try update(card, set: values, section: nil, expectingStatus: expectingStatus)
    }
}

/// The panel's only way to change a task card, and it changes only `status`, `agent` and `branch` lines of the front matter
/// and, when asked, the `Fix notes` or `Decision` section. Every other line stays byte for byte as it was. The write is atomic and refused when the card changed since
/// the panel read it or is a symbolic link.
struct CardWriter: CardWriting {
    func update(_ card: TaskCard, set values: [CardField: String], section: SectionEdit?, expectingStatus: TaskStatus) throws {
        for (field, value) in values where value.contains("\n") || value.contains("\r") {
            throw CardWriteError.writeFailed("the value for \(field.rawValue) contains a line break")
        }
        let url = card.url
        let text = try load(card, expectingStatus: expectingStatus, bodyChecked: section != nil)

        var lines = text.components(separatedBy: "\n")
        let cr = text.contains("\r\n") ? "\r" : ""
        guard let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == "---" }) else {
            throw CardWriteError.unreadable("no front matter in \(url.path)")
        }
        var insertAt = close
        for field in [CardField.status, .agent, .branch, .from] {
            guard let value = values[field] else { continue }
            let newLine = "\(field.rawValue): \(value)\(cr)"
            if let index = lines[1..<close].firstIndex(where: { $0.hasPrefix("\(field.rawValue):") }) {
                lines[index] = newLine
            } else {
                lines.insert(newLine, at: insertAt)
                insertAt += 1
            }
        }
        if let section { apply(section, to: &lines, frontMatterEnd: close, cr: cr) }
        try replace(url, with: Data(lines.joined(separator: "\n").utf8))
    }

    /// Rewrites the title, the named sections and the front matter lines in `change` of a card that is not running, and nothing else:
    /// other keys and sections stay as they were. Refused when the card changed since it was read.
    func edit(_ card: TaskCard, _ change: CardEdit) throws {
        let one: [String?] = [change.title, change.kind, change.branch] + (change.roles ?? []).map { Optional($0) } + (change.files ?? []).map { Optional($0) }
        if one.contains(where: { $0?.contains(where: \.isNewline) == true }) { throw CardWriteError.writeFailed("a value contains a line break") }
        for (name, text) in change.sections where text.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") || $0 == "#" || $0 == "##" }) {
            throw CardWriteError.writeFailed("\(name) has a line that starts with # or ##")
        }
        let url = card.url
        let text = try load(card, expectingStatus: card.status, bodyChecked: true, allowRunning: false)
        var lines = text.components(separatedBy: "\n")
        let cr = text.contains("\r\n") ? "\r" : ""
        guard let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == "---" }) else {
            throw CardWriteError.unreadable("no front matter in \(url.path)")
        }
        var front = Array(lines[1..<close])
        var body = Array(lines[close...])

        func isKey(_ line: String, _ key: String) -> Bool { line.hasPrefix("\(key):") }
        /// Removes the key's line and the list items under it.
        func remove(_ key: String) {
            guard let at = front.firstIndex(where: { isKey($0, key) }) else { return }
            var end = at + 1
            while end < front.count, front[end].hasPrefix(" ") || front[end].hasPrefix("\t") || front[end].hasPrefix("- ") { end += 1 }
            front.removeSubrange(at..<end)
        }
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { remove(key); return }
            let line = "\(key): \(value)\(cr)"
            if let at = front.firstIndex(where: { isKey($0, key) }) { front[at] = line } else { front.append(line) }
        }
        put("kind", change.kind)
        put("branch", change.branch)
        if let roles = change.roles { put("roles", "[\(roles.joined(separator: ", "))]") }
        if let priority = change.priority { put("priority", priority.rawValue) }
        if let status = change.status { put("status", status.raw) }
        if let files = change.files {
            remove("files")
            if !files.isEmpty { front += ["files:\(cr)"] + files.map { "  - \($0)\(cr)" } }
        }
        lines = ["---" + cr] + front + body
        if let title = change.title {
            let heading = "# \(title)" + cr
            if let at = lines.indices.first(where: { $0 > front.count + 1 && lines[$0].hasPrefix("# ") }) { lines[at] = heading }
            else { lines.insert(heading, at: front.count + 2) }
        }
        body = []
        let newClose = front.count + 1
        for name in ["Goal", "Scope", "Acceptance criteria", "Dependencies"] {
            if let text = change.sections[name] { set(section: name, to: text, in: &lines, frontMatterEnd: newClose, cr: cr) }
        }
        try replace(url, with: Data(lines.joined(separator: "\n").utf8))
    }

    /// Replaces the text under `## <name>`; a missing section is added before `## Report`, or at the end.
    private func set(section name: String, to text: String, in lines: inout [String], frontMatterEnd close: Int, cr: String) {
        let heading = "## \(name)"
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { $0 + cr }
        func isHeading(_ i: Int, _ text: String) -> Bool { lines[i].trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == text }
        guard let h = lines.indices.first(where: { $0 > close && isHeading($0, heading) }) else {
            let at = lines.indices.first(where: { $0 > close && isHeading($0, "## Report") }) ?? (lines.last == "" ? lines.count - 1 : lines.count)
            lines.insert(contentsOf: [heading + cr, cr] + body + [cr], at: at)
            return
        }
        let end = lines.indices.dropFirst(h + 1).first(where: { lines[$0].hasPrefix("## ") }) ?? lines.count
        lines.replaceSubrange((h + 1)..<end, with: [cr] + body + [end < lines.count ? cr : ""])
    }

    /// Reads the card and refuses a symbolic link, an unreadable file, a status other than the one the panel read and a front matter (or body, when `bodyChecked`) that changed since.
    private func load(_ card: TaskCard, expectingStatus: TaskStatus, bodyChecked: Bool, allowRunning: Bool = true) throws -> String {
        let url = card.url
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CardWriteError.isSymlink }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw CardWriteError.unreadable(url.path)
        }
        let current: TaskCard
        // The parser reads LF text; a CRLF card is parsed with its line endings normalised, but written back as CRLF.
        do { current = try CardParser.parse(text.replacingOccurrences(of: "\r\n", with: "\n"), url: url) } catch { throw CardWriteError.unreadable("not a task card: \(url.path)") }
        guard current.status == expectingStatus else {
            throw CardWriteError.conflict(expected: expectingStatus.label, found: current.status.label)
        }

        if !card.fingerprint.isEmpty, current.fingerprint != card.fingerprint {
            throw CardWriteError.conflict(expected: "front matter as read", found: "front matter changed")
        }

        // A section write also refuses when the body changed since the panel read it (an agent may be writing its report).
        if bodyChecked, !card.bodyFingerprint.isEmpty, current.bodyFingerprint != card.bodyFingerprint {
            throw CardWriteError.conflict(expected: "body as read", found: "body changed")
        }

        if !allowRunning, current.status.holdsAgent { throw CardWriteError.conflict(expected: "a card that is not running", found: current.status.label) }
        return text
    }

    /// Appends to or replaces `## <name>` (created at the end of the card when missing); nothing outside that section moves.
    private func apply(_ edit: SectionEdit, to lines: inout [String], frontMatterEnd close: Int, cr: String) {
        let heading = "## \(edit.section.rawValue)"
        let body = edit.text.components(separatedBy: "\n").map { $0 + cr }
        let blank = cr
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard let h = lines.indices.first(where: { $0 > close && lines[$0].trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == heading }) else {
            if lines.last == "" { lines.removeLast() }
            lines.append(contentsOf: [blank, heading + cr, blank] + body + [""])
            return
        }
        let end = lines.indices.dropFirst(h + 1).first(where: { lines[$0].hasPrefix("## ") }) ?? lines.count
        switch edit.section {
        case .fixNotes:
            var at = end
            while at > h + 1, isBlank(lines[at - 1]) { at -= 1 }
            lines.insert(contentsOf: [blank] + body, at: at)
        case .decision:
            lines.replaceSubrange((h + 1)..<end, with: [blank] + body + [end < lines.count ? blank : ""])
        }
    }

    /// Writes next to the card and swaps the files, so a reader never sees a half-written card.
    private func replace(_ url: URL, with data: Data) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).panel-\(UUID().uuidString)")
        do {
            let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o644
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw CardWriteError.writeFailed(error.localizedDescription)
        }
    }
}

/// Creates a new card file. It never replaces one: the write fails when the file exists, even if it appeared a moment ago.
struct CardCreator {
    func create(text: String, id: String, in tasksDir: URL) throws {
        guard TaskInput.validTaskID(id) else { throw CardWriteError.writeFailed("\"\(id)\" is not a valid task id") }
        let url = tasksDir.appendingPathComponent("\(id).md")
        let fm = FileManager.default
        let temp = tasksDir.appendingPathComponent(".\(id).md.panel-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: temp)
            // A hard link fails when the name is taken, so the card appears whole or not at all.
            try fm.linkItem(at: temp, to: url)
        } catch {
            throw CardWriteError.writeFailed((error as? CocoaError)?.code == .fileWriteFileExists ? "\(id).md already exists" : error.localizedDescription)
        }
    }
}
