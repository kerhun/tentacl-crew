import Foundation
import Observation

/// "New task": the form that writes a new `tasks/<ID>.md` with `status: todo` and `from: user`. Everything is checked before the write,
/// and an existing card is never replaced. Opened on a card that is not running it is "Edit card": the same fields, written back through
/// `CardWriter`, plus the status actions (back to todo, blocked, cancelled).
@Observable @MainActor
final class NewTaskFlow: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    enum Kind: String, CaseIterable { case normal, analysis }

    var prefix = "T"
    var title = ""
    var goal = ""
    var scope = ""
    var acceptance = ""
    /// One path per line.
    var files = ""
    var branch = ""
    var role: String
    var kind: Kind = .normal
    var priority: CardPriority = .normal
    /// Card ids separated by commas or spaces.
    var dependencies = ""
    private(set) var failure: String?

    let roles: [String]
    @ObservationIgnored private let projectID: String
    @ObservationIgnored private let tasksDir: URL
    @ObservationIgnored private let existingIDs: () -> Set<String>
    @ObservationIgnored private let creator = CardCreator()
    @ObservationIgnored private let writer = CardWriter()
    /// The card being edited and the form values as they were read from it; nil for a new task.
    @ObservationIgnored private let editing: TaskCard?
    @ObservationIgnored private var loaded: Snapshot?
    private struct Snapshot: Equatable {
        var title, goal, scope, acceptance, files, branch, role, dependencies: String
        var kind: Kind
        var priority: CardPriority
    }

    init(projectID: String, tasksDir: URL, roles: [String], existingIDs: @escaping () -> Set<String>) {
        self.projectID = projectID; self.tasksDir = tasksDir; self.existingIDs = existingIDs; self.editing = nil
        self.roles = roles.isEmpty ? ["dev"] : roles
        self.role = self.roles.contains("dev") ? "dev" : self.roles[0]
    }

    /// Opens the form on `card` ("Edit card"). A card that is running (doing, review, needs-fix) cannot be edited; the writer refuses it too.
    init(editing card: TaskCard, tasksDir: URL, roles: [String], existingIDs: @escaping () -> Set<String>) {
        self.projectID = card.project; self.tasksDir = tasksDir; self.existingIDs = existingIDs; self.editing = card
        self.roles = roles.isEmpty ? ["dev"] : roles
        self.role = card.roles.first ?? (self.roles.contains("dev") ? "dev" : self.roles[0])
        let heading = "\(card.id) · "
        title = card.title.hasPrefix(heading) ? String(card.title.dropFirst(heading.count)) : card.title
        goal = card.sections["Goal"] ?? ""; scope = card.sections["Scope"] ?? ""; acceptance = card.sections["Acceptance criteria"] ?? ""
        files = card.files.joined(separator: "\n"); branch = card.branch ?? ""
        kind = card.kind == "analysis" ? .analysis : .normal
        priority = card.priority
        dependencies = Self.dependencyIDs(in: card.sections["Dependencies"] ?? "").joined(separator: ", ")
        loaded = snapshot
    }

    private var snapshot: Snapshot {
        Snapshot(title: title.trimmingCharacters(in: .whitespacesAndNewlines), goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                 scope: scope.trimmingCharacters(in: .whitespacesAndNewlines), acceptance: acceptance.trimmingCharacters(in: .whitespacesAndNewlines),
                 files: fileList.joined(separator: "\n"), branch: branch.trimmingCharacters(in: .whitespaces), role: role,
                 dependencies: dependencyList.joined(separator: ", "), kind: kind, priority: priority)
    }

    /// The ids in a Dependencies section written as `- ID` lines (`None.` or free text gives none).
    static func dependencyIDs(in section: String) -> [String] {
        section.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { return nil }
            return t.dropFirst(2).split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
    }

    var isEditing: Bool { editing != nil }

    /// Statuses the card can be moved to from here; none for a running card.
    var statusActions: [TaskStatus] {
        guard let card = editing, !card.status.holdsAgent else { return [] }
        return [TaskStatus.todo, .blocked, .cancelled].filter { $0 != card.status }
    }

    // MARK: what the form shows

    /// One past the highest number used with this prefix (cards and files on disk both count).
    static func nextID(prefix: String, existing: Set<String>) -> String {
        let highest = existing.compactMap { id -> Int? in
            guard id.hasPrefix(prefix), let n = Int(id.dropFirst(prefix.count)), String(n) == id.dropFirst(prefix.count) else { return nil }
            return n
        }.max() ?? 0
        return "\(prefix)\(highest + 1)"
    }

    private var taken: Set<String> {
        var ids = existingIDs()
        if let editing { ids.insert(editing.id) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tasksDir.path)) ?? []
        for name in names where name.hasSuffix(".md") { ids.insert(String(name.dropLast(3))) }
        return ids
    }

    var nextID: String { editing?.id ?? Self.nextID(prefix: prefix, existing: taken) }

    var fileList: [String] { files.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var dependencyList: [String] { dependencies.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) }

    /// Reasons the card cannot be written yet; empty means it can.
    var problems: [String] {
        var found: [String] = []
        if editing != nil { if statusActions.isEmpty { found.append("A card that is running cannot be edited.") } }
        else if prefix.isEmpty || prefix.count > 8 || !prefix.allSatisfy({ $0.isASCII && $0.isLetter }) { found.append("The id prefix must be 1 to 8 letters (A to Z).") }
        else if !TaskInput.validTaskID(nextID) { found.append("\"\(nextID)\" is not a valid task id.") }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { found.append("Give the task a title.") }
        else if name.contains(where: \.isNewline) { found.append("The title must be one line.") }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append("Write the goal.") }
        for (label, text) in [("Goal", goal), ("Scope", scope), ("Acceptance criteria", acceptance)]
        where text.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") || $0 == "#" || $0 == "##" }) {
            found.append("\(label) cannot have a line that starts with # or ## (it would split the card).")
        }
        for file in fileList where !Self.isRepoRelative(file) { found.append("\"\(file)\" must be a path inside the repository (no leading / or ~, no ..).") }
        let b = branch.trimmingCharacters(in: .whitespaces)
        if !b.isEmpty, !TaskInput.validBranch(b) { found.append("\"\(b)\" is not a valid branch name.") }
        if !roles.contains(role) { found.append("The role \"\(role)\" is not one of this project's roles.") }
        let known = taken
        for dep in dependencyList where !TaskInput.validTaskID(dep) || !known.contains(dep) || dep == editing?.id { found.append("\"\(dep)\" is not an existing card.") }
        return found
    }

    var canSubmit: Bool { problems.isEmpty }

    private static func isRepoRelative(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.hasPrefix("~") && !path.contains("\\") && !path.split(separator: "/").contains("..")
            && !path.contains(where: { $0.isNewline || $0 == "\t" })
    }

    // MARK: writing

    /// The card text for `id`.
    func cardText(id: String) -> String {
        var lines = ["---", "id: \(id)", "project: \(projectID)", "status: todo"]
        if kind == .analysis { lines.append("kind: analysis") }
        if priority != .normal { lines.append("priority: \(priority.rawValue)") }
        let b = branch.trimmingCharacters(in: .whitespaces)
        if !b.isEmpty { lines.append("branch: \(b)") }
        lines += ["roles: [\(role)]", "from: user"]
        let paths = fileList
        if !paths.isEmpty { lines += ["files:"] + paths.map { "  - \($0)" } }
        lines += ["---", "# \(id) · \(title.trimmingCharacters(in: .whitespacesAndNewlines))", ""]
        func section(_ name: String, _ text: String) { lines += ["## \(name)", text.trimmingCharacters(in: .whitespacesAndNewlines), ""] }
        section("Goal", goal)
        section("Scope", scope)
        section("Acceptance criteria", acceptance)
        section("Dependencies", dependencyList.isEmpty ? "None." : dependencyList.map { "- \($0)" }.joined(separator: "\n"))
        lines += ["## Report", ""]
        return lines.joined(separator: "\n")
    }

    /// The fields that differ from what was read, for `CardWriter.edit`; sections and lists that did not change are not touched.
    private func changes(from old: Snapshot) -> CardEdit {
        let now = snapshot
        var edit = CardEdit()
        if now.title != old.title { edit.title = "\(nextID) · \(now.title)" }
        for (name, new, was) in [("Goal", now.goal, old.goal), ("Scope", now.scope, old.scope), ("Acceptance criteria", now.acceptance, old.acceptance)] where new != was {
            edit.sections[name] = new
        }
        if now.dependencies != old.dependencies { edit.sections["Dependencies"] = dependencyList.isEmpty ? "None." : dependencyList.map { "- \($0)" }.joined(separator: "\n") }
        if now.files != old.files { edit.files = fileList }
        if now.branch != old.branch { edit.branch = now.branch }
        if now.role != old.role { edit.roles = [now.role] }
        if now.kind != old.kind { edit.kind = now.kind == .analysis ? "analysis" : "" }
        if now.priority != old.priority { edit.priority = now.priority }
        return edit
    }

    /// Moves the card being edited to `status` (todo, blocked or cancelled); false when the card is running, changed since it was read, or the write failed.
    func setStatus(_ status: TaskStatus) -> Bool {
        failure = nil
        guard let card = editing, statusActions.contains(status) else { failure = "This card cannot be moved while it is running."; return false }
        do { try writer.update(card, set: [.status: status.raw], expectingStatus: card.status) }
        catch { failure = Self.describe(error); return false }
        return true
    }

    private static func describe(_ error: Error) -> String {
        if case CardWriteError.conflict = error { return "The card changed on disk since you opened it. Close this and open it again." }
        return "\(error)"
    }

    /// Writes the card and returns its id; nil when the form has problems or the write failed (see `failure`).
    func submit() -> String? {
        failure = nil
        guard problems.isEmpty else { failure = problems.first; return nil }
        if let card = editing, let old = loaded {
            do { try writer.edit(card, changes(from: old)) } catch { failure = Self.describe(error); return nil }
            return card.id
        }
        let id = nextID
        do { try creator.create(text: cardText(id: id), id: id, in: tasksDir) }
        catch { failure = "\(error)"; return nil }
        return id
    }
}
