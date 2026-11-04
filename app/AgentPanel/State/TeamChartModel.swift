import Foundation
import Observation

struct ChartRow: Equatable, Identifiable {
    let role: String
    let depth: Int
    /// The role it reports to; nil means the user.
    let reportsTo: String?
    let canGiveTasksTo: [String]
    /// The chart names this role but no role file with that name can be found.
    let isMissingRole: Bool
    var id: String { role }
}

/// What the project's cards say about the roles: which roles a card names (its `roles`, or `dev` when it names none, and the role of its
/// agent) and how many cards in doing each role's agents have.
struct ChartWork: Equatable {
    var namedRoles: Set<String> = []
    var running: [String: Int] = [:]

    init(cards: [TaskCard]) {
        for card in cards {
            namedRoles.formUnion(card.roles.isEmpty ? ["dev"] : card.roles)
            let agentRole = card.agent.flatMap(Self.role(ofAgent:))
            if let agentRole { namedRoles.insert(agentRole) }
            if card.status == .doing, let role = agentRole ?? card.roles.first { running[role, default: 0] += 1 }
        }
    }

    /// Agent names are `<role>-<task>` and role names have no "-".
    static func role(ofAgent agent: String) -> String? { agent.firstIndex(of: "-").map { String(agent[..<$0]) } }
}

/// One role in the chart's tree: its tile, its line of details and the roles that report to it.
struct ChartNode: Equatable, Identifiable {
    let role: String
    let title: String
    let model: String?
    let running: Int
    let isMissingRole: Bool
    var children: [ChartNode]
    var id: String { role }

    var initial: String { String(title.prefix(1)).uppercased() }
    var subtitle: String {
        [role, model ?? "no role file", running > 0 ? "\(running) running" : "idle"].joined(separator: " · ")
    }
}

/// A one-click change a warning offers (applied to the draft; Save chart writes it).
enum ChartFix: Equatable {
    /// The roles that report to `of` report to `to` instead (nil: to you).
    case moveReports(of: String, to: String?)
    case remove(String)
}

struct ChartWarning: Equatable {
    let role: String
    let title: String
    let message: String
    let fix: ChartFix?
    let fixLabel: String?
}

/// The Chart view's state: the project's team chart as a draft (rows, who may be whose manager), save and revert.
/// Reading never rewrites the file; nothing is written until Save.
@Observable @MainActor
final class TeamChartModel {
    static let runningAgentsNote = "Agents that are already running keep the chart they started with. New agents get the saved chart."

    private(set) var draft: TeamChart?
    private(set) var fileProblems: [RoleProblem] = []
    private(set) var saveError: String?
    var project: ProjectConfig?
    /// The selected role in the tree (its side panel shows); nil when none is.
    private(set) var selected: String?
    /// Why the last drop was refused; cleared by the next good drop or edit.
    private(set) var dropRefusal: String?
    /// What the cards say; nil until the panel has loaded them (then no "no work" warnings are shown).
    var work: ChartWork?

    @ObservationIgnored private var saved: TeamChart?
    @ObservationIgnored private let store: TeamChartStore
    @ObservationIgnored private let roleStore: RoleStore

    init(store: TeamChartStore = TeamChartStore(), roleStore: RoleStore) { self.store = store; self.roleStore = roleStore }

    /// Reads the chart of the current project from disk (an invalid file is reported, not replaced).
    func reload() {
        saveError = nil; dropRefusal = nil
        defer { if let s = selected, draft?.member(s) == nil { selected = nil } }
        guard let project else { draft = nil; saved = nil; fileProblems = []; return }
        switch store.load(for: project) {
        case .none: draft = nil; saved = nil; fileProblems = []
        case .valid(let chart): draft = chart; saved = chart; fileProblems = []
        case .invalid(let problems): draft = nil; saved = nil; fileProblems = problems
        }
    }

    var hasChart: Bool { draft != nil }
    var isDirty: Bool { draft != saved }
    var problems: [RoleProblem] { draft?.problems ?? [] }

    /// Every role name that can be found for this project (its own roles, mapped ones and the shared ones).
    var resolvable: Set<String> {
        var names = Set(roleStore.baseRoles().roles.map(\.config.name))
        if let project { names.formUnion(roleStore.projectRoles(project).roles.map(\.config.name)) }
        return names
    }

    var rows: [ChartRow] {
        guard let chart = draft else { return [] }
        let have = resolvable
        var out: [ChartRow] = []
        var placed: Set<String> = []
        func add(_ role: String, depth: Int) {
            guard placed.insert(role).inserted else { return }
            out.append(ChartRow(role: role, depth: depth, reportsTo: chart.manager(of: role), canGiveTasksTo: chart.descendants(of: role), isMissingRole: !have.contains(role)))
            for child in chart.members where child.reportsTo == role { add(child.role, depth: depth + 1) }
        }
        for m in chart.members where m.reportsTo == nil { add(m.role, depth: 0) }
        for m in chart.members { add(m.role, depth: 0) }   // anything a broken draft left unreachable still shows
        return out
    }

    /// The role files of this project by name (a project role wins over a shared one of the same name).
    private var roleConfigs: [String: RoleConfig] {
        var out: [String: RoleConfig] = [:]
        for r in roleStore.baseRoles().roles { out[r.config.name] = r.config }
        if let project { for r in roleStore.projectRoles(project).roles { out[r.config.name] = r.config } }
        return out
    }

    /// The chart as a tree from the top roles down (a role a broken draft left unreachable is a top node of its own).
    var tree: [ChartNode] {
        guard let chart = draft else { return [] }
        let configs = roleConfigs
        var placed: Set<String> = []
        func node(_ role: String) -> ChartNode? {
            guard placed.insert(role).inserted else { return nil }
            let config = configs[role]
            let title = config?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? role
            return ChartNode(role: role, title: title, model: config?.model, running: work?.running[role] ?? 0, isMissingRole: config == nil,
                             children: chart.members.filter { $0.reportsTo == role }.compactMap { node($0.role) })
        }
        var out = chart.members.filter { $0.reportsTo == nil }.compactMap { node($0.role) }
        out += chart.members.compactMap { node($0.role) }
        return out
    }

    /// The name a role shows with (its display name, else the role name).
    func title(of role: String) -> String {
        roleConfigs[role]?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? role
    }

    func select(_ role: String?) {
        guard let role else { selected = nil; return }
        if draft?.member(role) != nil { selected = role }
    }

    // MARK: drag and drop

    /// Why `role` cannot report to `target` (nil: it can; a nil target is you).
    func refusal(_ role: String, onto target: String?) -> String? {
        guard let chart = draft, chart.member(role) != nil else { return "\(role) is not in the chart." }
        guard let target else { return nil }
        if target == role { return "\(role) cannot report to itself." }
        if chart.member(target) == nil { return "\(target) is not in the chart." }
        if chart.descendants(of: role).contains(target) {
            return "\(role) cannot report to \(target): \(target) reports up through \(role), so that would make a loop."
        }
        return nil
    }

    func canDrop(_ role: String, onto target: String?) -> Bool { refusal(role, onto: target) == nil }

    /// Makes `role` report to `target` (nil: to you); a drop that is refused changes nothing and returns (and keeps) the reason.
    @discardableResult
    func drop(_ role: String, onto target: String?) -> String? {
        if let reason = refusal(role, onto: target) { dropRefusal = reason; return reason }
        dropRefusal = nil
        if draft?.manager(of: role) != target { setManager(of: role, to: target) }
        selected = role
        return nil
    }

    // MARK: warnings

    /// What may be wrong with `role` in the draft, each with a one-click fix where there is one.
    func warnings(for role: String) -> [ChartWarning] {
        guard let chart = draft, chart.member(role) != nil else { return [] }
        var out: [ChartWarning] = []
        if !resolvable.contains(role) {
            out.append(ChartWarning(role: role, title: "No role file",
                                    message: "No role file is named \(role), so no agent can be started for it. Add the role, or take it out of the chart.",
                                    fix: .remove(role), fixLabel: "Take \(role) out of the chart"))
        }
        if let work, !work.namedRoles.contains(role) {
            let reports = chart.members.filter { $0.reportsTo == role }.map(\.role)
            let boss = chart.manager(of: role)
            if reports.isEmpty {
                out.append(ChartWarning(role: role, title: "No work yet",
                                        message: "No card names \(role). Name it on cards, or take it out of the chart.",
                                        fix: .remove(role), fixLabel: "Take \(role) out of the chart"))
            } else {
                let names = Self.list(reports)
                out.append(ChartWarning(role: role, title: "No work yet",
                                        message: "No card names \(role), so \(names) reports go straight to \(boss ?? "you"). Name it on cards, or take it out of the chain.",
                                        fix: .moveReports(of: role, to: boss), fixLabel: "Move \(names) under \(boss ?? "you")"))
            }
        }
        return out
    }

    /// The warnings of every role in the chart, in chart order.
    var allWarnings: [ChartWarning] { (draft?.members ?? []).flatMap { warnings(for: $0.role) } }

    func apply(_ fix: ChartFix) {
        guard var chart = draft else { return }
        switch fix {
        case .moveReports(let role, let boss):
            for i in chart.members.indices where chart.members[i].reportsTo == role { chart.members[i].reportsTo = boss }
            draft = chart
        case .remove(let role):
            remove(role)
        }
        dropRefusal = nil
    }

    /// The side panel's "Its reports go to" line.
    func reportsGoTo(_ role: String) -> String { "\(draft?.manager(of: role) ?? "you"), in the Report of each card" }

    /// "dev", "dev and ui_dev", "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Resolvable roles that are not in the chart yet.
    var notInChart: [String] {
        let placed = Set(draft?.members.map(\.role) ?? [])
        return resolvable.subtracting(placed).sorted()
    }

    /// The roles that can be `role`'s manager: any other role in the chart that is not below it (the user is always possible).
    func availableManagers(for role: String) -> [String] {
        guard let chart = draft else { return [] }
        let below = Set(chart.descendants(of: role))
        return chart.members.map(\.role).filter { $0 != role && !below.contains($0) }
    }

    @discardableResult
    func setManager(of role: String, to boss: String?) -> Bool {
        guard var chart = draft, chart.member(role) != nil else { return false }
        if let boss, !availableManagers(for: role).contains(boss) { return false }
        guard let i = chart.members.firstIndex(where: { $0.role == role }) else { return false }
        chart.members[i].reportsTo = boss
        draft = chart
        return true
    }

    /// Places a resolvable role in the chart; it reports to the user until a manager is chosen.
    func add(_ role: String) {
        guard var chart = draft, resolvable.contains(role), chart.member(role) == nil else { return }
        chart.members.append(TeamMember(role: role, reportsTo: nil))
        draft = chart
    }

    func remove(_ role: String) {
        draft = draft?.removing(role: role)
        if selected == role { selected = nil }
    }

    /// The default chart (pm → reviewer → dev, ui_dev) from the roles that exist; only when the project has no chart yet.
    func createDefaultChart() {
        guard draft == nil else { return }
        draft = TeamChart.defaultChart(resolvable: resolvable)
    }

    func revert() {
        draft = saved; saveError = nil; dropRefusal = nil
        if let s = selected, draft?.member(s) == nil { selected = nil }
    }

    func save() async {
        guard let project, let chart = draft else { return }
        do {
            try store.save(chart, for: project)
            saved = chart; fileProblems = []; saveError = nil
        } catch {
            saveError = Self.message(for: error)
        }
    }

    /// Writes `chart` (used when deleting a role); on success the draft and the saved chart are that chart.
    func write(_ chart: TeamChart) -> String? {
        guard let project else { return "No project is selected." }
        do { try store.save(chart, for: project); draft = chart; saved = chart; return nil }
        catch { return Self.message(for: error) }
    }

    /// The chart as it is saved (not the draft).
    var savedChart: TeamChart? { saved }

    static func message(for error: Error) -> String {
        switch error as? TeamChartWriteError {
        case .noProjectFile?: return "The location of the project's project.json is unknown, so the chart cannot be saved."
        case .isSymlink?: return "team.json (or its folder) is a symbolic link; the panel does not write through it."
        case .problems(let p)?: return p.map(\.message).joined(separator: " ")
        case .writeFailed(let m)?: return "The chart could not be saved: \(m)"
        case nil: return error.localizedDescription
        }
    }
}
