import Foundation

struct TeamMember: Codable, Equatable {
    var role: String
    /// The role this one reports to; nil means it reports to the user (the top of the chart).
    var reportsTo: String?

    private enum CodingKeys: String, CodingKey { case role, reportsTo }

    init(role: String, reportsTo: String?) { self.role = role; self.reportsTo = reportsTo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        reportsTo = try c.decodeIfPresent(String.self, forKey: .reportsTo)
    }

    /// The top of the chart is written as an explicit `null`, as the file format says.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if let reportsTo { try c.encode(reportsTo, forKey: .reportsTo) } else { try c.encodeNil(forKey: .reportsTo) }
    }
}

/// The team of a project: who reports to whom. The user is above everyone. A role may give tasks only to the roles below it.
struct TeamChart: Equatable {
    var version = 1
    var members: [TeamMember]
    /// Keys of the file this version does not know; written back unchanged.
    var extra: [String: JSONValue] = [:]

    func member(_ role: String) -> TeamMember? { members.first { $0.role == role } }
    func manager(of role: String) -> String? { member(role)?.reportsTo }

    /// The chain of managers above `role`, nearest first (a cycle in a broken file is cut, never followed forever).
    func ancestors(of role: String) -> [String] {
        var out: [String] = [], seen: Set<String> = [role]
        var current = manager(of: role)
        while let next = current, !seen.contains(next) {
            out.append(next); seen.insert(next)
            current = manager(of: next)
        }
        return out
    }

    func descendants(of role: String) -> [String] { members.map(\.role).filter { $0 != role && ancestors(of: $0).contains(role) } }

    /// May `from` give a task to `to`? The user (nil or "user") may give any; otherwise `from` must be a strict ancestor of `to`.
    /// A role that is not in the chart reports to the user, so only the user may give it a task; a giver that is not in the chart
    /// cannot be verified.
    func canAssign(from: String?, to: String) -> Bool {
        guard let from, from != "user" else { return true }
        guard member(from) != nil, member(to) != nil, from != to else { return false }
        return ancestors(of: to).contains(from)
    }

    /// Everything wrong with the chart (all errors); a role that has no role file is not checked here (it is only a warning in the screen).
    var problems: [RoleProblem] {
        var out: [RoleProblem] = []
        func error(_ message: String) { out.append(RoleProblem(field: "members", message: message, severity: .error)) }
        var seen: Set<String> = []
        for m in members {
            if !RoleValidator.validName(m.role) { error("A role name in the chart is not a plain role name (lowercase letters, digits or _)."); continue }
            if !seen.insert(m.role).inserted { error("The role \"\(m.role)\" is in the chart more than once.") }
        }
        for m in members where RoleValidator.validName(m.role) {
            guard let boss = m.reportsTo else { continue }
            if boss == m.role { error("The role \"\(m.role)\" reports to itself.") }
            else if !RoleValidator.validName(boss) { error("\"\(m.role)\" reports to a name that is not a plain role name.") }
            else if member(boss) == nil { error("\"\(m.role)\" reports to \"\(boss)\", which is not in the chart.") }
        }
        var reported: Set<String> = []
        for m in members where RoleValidator.validName(m.role) && m.reportsTo != m.role {
            var seenChain: Set<String> = [m.role]
            var current = manager(of: m.role)
            while let next = current {
                if next == m.role { if reported.insert(m.role).inserted { error("The chart has a cycle through \"\(m.role)\".") }; break }
                if !seenChain.insert(next).inserted { break }
                current = manager(of: next)
            }
        }
        return out
    }

    /// pm → reviewer → dev and ui_dev, using only the roles that can be resolved; a missing one is skipped and its reports move up.
    static func defaultChart(resolvable roles: Set<String>) -> TeamChart {
        var members: [TeamMember] = []
        var top: String?
        for name in ["pm", "reviewer", "dev", "ui_dev"] where roles.contains(name) {
            let boss: String?
            switch name {
            case "pm": boss = nil
            case "reviewer": boss = roles.contains("pm") ? "pm" : nil
            default: boss = roles.contains("reviewer") ? "reviewer" : (roles.contains("pm") ? "pm" : nil)
            }
            members.append(TeamMember(role: name, reportsTo: boss))
            if boss == nil && top == nil { top = name }
        }
        return TeamChart(members: members)
    }

    /// The chart without `role`; roles that reported to it report to its manager (or to the user).
    func removing(role: String) -> TeamChart {
        guard member(role) != nil else { return self }
        let boss = manager(of: role)
        var copy = self
        copy.members = members.filter { $0.role != role }.map { m in
            var m = m
            if m.reportsTo == role { m.reportsTo = boss }
            return m
        }
        return copy
    }
}

extension TeamChart: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        version = try c.decodeIfPresent(Int.self, forKey: Key("version")) ?? 1
        members = try c.decode([TeamMember].self, forKey: Key("members"))
        var other: [String: JSONValue] = [:]
        for key in c.allKeys where key.stringValue != "version" && key.stringValue != "members" { other[key.stringValue] = try c.decode(JSONValue.self, forKey: key) }
        extra = other
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(version, forKey: Key("version"))
        try c.encode(members, forKey: Key("members"))
        for (key, value) in extra where key != "version" && key != "members" { try c.encode(value, forKey: Key(key)) }
    }
}
