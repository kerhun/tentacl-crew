import Foundation
import Observation

/// One line of a project's notes. A line the file format does not know (`raw`) is kept exactly as written and shown as plain text.
struct NoteLine: Identifiable, Equatable {
    /// Kept across reloads of the file for a line whose text did not change (`NotesModel.reload`).
    var id = UUID()
    var text: String
    var done = false
    /// The day it was checked (YYYY-MM-DD), kept in the file as `<!-- done … -->`.
    var doneOn: String?
    /// The card made from it ("Make a task…"), kept as `<!-- task … -->`.
    var task: String?
    var raw = false
}

/// The lines under one `## YYYY-MM-DD` heading; `date` is nil for lines above the first heading.
struct NoteDay: Equatable {
    var date: String?
    var lines: [NoteLine]
}

/// `notes.md` in a project's data folder: `## YYYY-MM-DD` headings, newest first, each with `- [ ] text` / `- [x] text` lines.
/// A note's further lines follow its item indented by two spaces. Plain Markdown, so the user and the PM can read and edit it by hand.
enum NotesFile {
    static let name = "notes.md"

    static func parse(_ text: String) -> [NoteDay] {
        var days: [NoteDay] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // An indented line under a note is the note's next line.
            if rawLine.first == " " || rawLine.first == "\t", let d = days.indices.last, let last = days[d].lines.indices.last, !days[d].lines[last].raw {
                let kept = rawLine.hasPrefix(indent) ? String(rawLine.dropFirst(indent.count)) : line
                days[d].lines[last].text += "\n" + trimmedEnd(kept)
                continue
            }
            if let date = heading(line) {
                if !days.contains(where: { $0.date == date }) { days.append(NoteDay(date: date, lines: [])) }
                // Later lines go to that day, wherever it was first seen.
                if let i = days.firstIndex(where: { $0.date == date }) { days.append(days.remove(at: i)) }
                continue
            }
            if days.isEmpty { days.append(NoteDay(date: nil, lines: [])) }
            days[days.count - 1].lines.append(item(line) ?? NoteLine(text: line, raw: true))
        }
        return days
    }

    static func write(_ days: [NoteDay]) -> String {
        let kept = days.filter { !$0.lines.isEmpty }
        let ordered = kept.filter { $0.date == nil } + kept.filter { $0.date != nil }.sorted { $0.date! > $1.date! }
        return ordered.map { day in
            let head = day.date.map { "## \($0)\n" } ?? ""
            return head + day.lines.map { line($0) + "\n" }.joined()
        }.joined(separator: "\n")
    }

    /// The file's name for a day (the calendar's own day, so "today" follows the user's clock).
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A note's text as it is kept: no blank lines (they would end the item in the file), no spaces at either end of it or at a line's end.
    static func clean(_ text: String) -> String {
        text.components(separatedBy: .newlines).map(trimmedEnd).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let indent = "  "

    private static func trimmedEnd(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }

    private static func line(_ note: NoteLine) -> String {
        if note.raw { return note.text }
        let parts = note.text.components(separatedBy: "\n")
        var out = "- [\(note.done ? "x" : " ")] \(parts[0])"
        if let task = note.task { out += " <!-- task \(task) -->" }
        if note.done, let doneOn = note.doneOn { out += " <!-- done \(doneOn) -->" }
        return out + parts.dropFirst().map { "\n" + indent + $0 }.joined()
    }

    private static func heading(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let date = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return isDay(date) ? date : nil
    }

    private static func isDay(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func item(_ line: String) -> NoteLine? {
        let open = "- [ ] ", done = ["- [x] ", "- [X] "]
        let isDone: Bool
        if line.hasPrefix(open) { isDone = false } else if done.contains(where: line.hasPrefix) { isDone = true } else { return nil }
        var text = String(line.dropFirst(open.count))
        var note = NoteLine(text: "", done: isDone)
        // Trailing comments, in any order: `<!-- done YYYY-MM-DD -->`, `<!-- task ID -->`.
        while text.hasSuffix("-->"), let start = text.range(of: "<!--", options: .backwards) {
            let words = text[start.upperBound..<text.index(text.endIndex, offsetBy: -3)].split(separator: " ").map(String.init)
            guard words.count == 2 else { break }
            if words[0] == "done", isDay(words[1]), note.doneOn == nil { note.doneOn = words[1] }
            else if words[0] == "task", note.task == nil { note.task = words[1] }
            else { break }
            text = text[..<start.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        note.text = text.trimmingCharacters(in: .whitespaces)
        return note.text.isEmpty ? nil : note
    }
}

/// The lines of one day as the pad shows them.
struct NoteGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var lines: [NoteLine]
}

/// One project's notes: reads `notes.md`, changes it line by line and writes it back atomically. Reloads when the file changes on disk.
@Observable @MainActor
final class NotesModel {
    let fileURL: URL
    private(set) var days: [NoteDay] = []
    /// Why the last write failed; nil once a write works.
    private(set) var saveError: String?
    /// "Show done": done lines checked before today come back.
    var showDone = false
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    /// The file's modification date at the last read or write (nil: no file).
    @ObservationIgnored private var seen: Date?

    init(fileURL: URL, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.fileURL = fileURL; self.now = now; self.calendar = calendar
        reload()
    }

    var today: String { NotesFile.day(now(), calendar: calendar) }
    private var yesterday: String { NotesFile.day(calendar.date(byAdding: .day, value: -1, to: now()) ?? now(), calendar: calendar) }

    var openCount: Int { days.reduce(0) { $0 + $1.lines.filter { !$0.done && !$0.raw }.count } }
    /// Done lines folded away (checked before today, or with no date).
    var foldedCount: Int { days.reduce(0) { $0 + $1.lines.filter(folded).count } }

    private func folded(_ line: NoteLine) -> Bool { line.done && (line.doneOn ?? "") < today }

    /// The days that have something to show, newest first.
    var groups: [NoteGroup] {
        let ordered = days.filter { $0.date != nil }.sorted { $0.date! > $1.date! } + days.filter { $0.date == nil }
        return ordered.compactMap { day in
            let lines = showDone ? day.lines : day.lines.filter { !folded($0) }
            guard !lines.isEmpty else { return nil }
            return NoteGroup(id: day.date ?? "undated", title: title(day.date), lines: lines)
        }
    }

    private func title(_ date: String?) -> String {
        guard let date else { return "Undated" }
        if date == today { return "Today" }
        if date == yesterday { return "Yesterday" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX"); parser.calendar = calendar; parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let d = parser.date(from: date) else { return date }
        parser.dateFormat = "EEE d MMM"
        return parser.string(from: d)
    }

    // MARK: changes

    /// A new note (one or more lines), first under today.
    func add(_ text: String) {
        let text = NotesFile.clean(text)
        guard !text.isEmpty else { return }
        let date = today
        if let i = days.firstIndex(where: { $0.date == date }) { days[i].lines.insert(NoteLine(text: text), at: 0) }
        else { days.append(NoteDay(date: date, lines: [NoteLine(text: text)])) }
        save()
    }

    func toggle(_ id: UUID) {
        let date = today
        change(id) { line in
            guard !line.raw else { return }
            line.done.toggle()
            line.doneOn = line.done ? date : nil
        }
    }

    func edit(_ id: UUID, to text: String) {
        let text = NotesFile.clean(text)
        guard !text.isEmpty else { return }
        change(id) { $0.text = text }
    }

    func delete(_ id: UUID) {
        for d in days.indices { days[d].lines.removeAll { $0.id == id } }
        days.removeAll { $0.lines.isEmpty }
        save()
    }

    /// Marks the first line with this text that has no card yet as made into `card`.
    func linkTask(text: String, to card: String) {
        guard let id = days.lazy.flatMap(\.lines).first(where: { $0.text == text && $0.task == nil && !$0.raw })?.id else { return }
        change(id) { $0.task = card }
    }

    private func change(_ id: UUID, _ update: (inout NoteLine) -> Void) {
        for d in days.indices { if let i = days[d].lines.firstIndex(where: { $0.id == id }) { update(&days[d].lines[i]); save(); return } }
    }

    // MARK: disk

    /// Reads the file again. A line whose text is still there keeps its id (the first unused one with that text, in order), so a click
    /// on the pad drawn before the reload still finds its line.
    func reload() {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var old: [String: [UUID]] = [:]
        for line in days.flatMap(\.lines) { old["\(line.raw) \(line.text)", default: []].append(line.id) }
        var read = NotesFile.parse(text)
        for d in read.indices {
            for i in read[d].lines.indices {
                let key = "\(read[d].lines[i].raw) \(read[d].lines[i].text)"
                if let id = old[key]?.first { read[d].lines[i].id = id; old[key]?.removeFirst() }
            }
        }
        days = read
        seen = modified()
    }

    /// Reads the file again when it changed since the last read or write; true when it did.
    @discardableResult
    func reloadIfChanged() -> Bool {
        guard modified() != seen else { return false }
        reload()
        return true
    }

    private func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NotesFile.write(days).write(to: fileURL, atomically: true, encoding: .utf8)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
        seen = modified()
    }
}

/// Every project's notes, one model per data folder, made on first use.
@MainActor
final class NotesBook {
    private var models: [String: NotesModel] = [:]
    private let now: () -> Date
    private let calendar: Calendar

    init(now: @escaping () -> Date = Date.init, calendar: Calendar = .current) { self.now = now; self.calendar = calendar }

    func notes(dataDir: URL) -> NotesModel {
        if let model = models[dataDir.path] { return model }
        let model = NotesModel(fileURL: dataDir.appendingPathComponent(NotesFile.name), now: now, calendar: calendar)
        models[dataDir.path] = model
        return model
    }
}

/// Where the floating pad sits and how big it is; remembered between launches.
struct NotesPadPlace: Equatable {
    /// How far the pad was dragged from its first spot (just above the rail's notes icon).
    var offset = CGSize.zero
    var big = false

    static let normal = CGSize(width: 340, height: 456)
    static let bigger = CGSize(width: 560, height: 708)
    /// The first spot: right of the rail (64) with a gap, and off the bottom edge.
    static let home = (left: CGFloat(80), bottom: CGFloat(16))

    var size: CGSize { big ? Self.bigger : Self.normal }

    /// The pad's top-left corner inside a container of `bounds`, always fully inside it (as far as it fits).
    func origin(in bounds: CGSize) -> CGPoint {
        let x = Self.home.left + offset.width
        let y = bounds.height - Self.home.bottom - size.height + offset.height
        return CGPoint(x: min(max(0, x), max(0, bounds.width - size.width)), y: min(max(0, y), max(0, bounds.height - size.height)))
    }

    /// Drags the pad, stopping at the container's edges.
    mutating func move(by translation: CGSize, in bounds: CGSize) {
        let start = origin(in: bounds)
        offset.width += translation.width; offset.height += translation.height
        let end = origin(in: bounds)
        // Keep only the part of the drag that took effect, so dragging back from an edge moves at once.
        offset = CGSize(width: offset.width - translation.width + (end.x - start.x), height: offset.height - translation.height + (end.y - start.y))
    }

    private static let keys = (x: "notes.pad.x", y: "notes.pad.y", big: "notes.pad.big")

    static func load(_ defaults: UserDefaults) -> NotesPadPlace {
        NotesPadPlace(offset: CGSize(width: defaults.double(forKey: keys.x), height: defaults.double(forKey: keys.y)), big: defaults.bool(forKey: keys.big))
    }

    func save(_ defaults: UserDefaults) {
        defaults.set(Double(offset.width), forKey: Self.keys.x)
        defaults.set(Double(offset.height), forKey: Self.keys.y)
        defaults.set(big, forKey: Self.keys.big)
    }
}
