import Foundation

/// Any JSON value (the "advanced" settings of a role are passed to Claude as they are).
enum JSONValue: Codable, Equatable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// A role file (`<name>.json`): the same format `validate-config.sh` and `spawn-agent.sh` read.
struct RoleConfig: Equatable {
    var name: String
    var kind: String
    /// Which agent program runs the role: "claude" or "codex". A role file without it is a Claude role.
    var tool: String = "claude"
    var model: String
    var effort: String
    var permissionMode: String
    var outputStyle: String
    var allowedTools: [String]
    var skills: [String]
    var instructionFile: String
    /// Claude only: "on" or "off" sets Claude Code's `alwaysThinkingEnabled`; nil leaves Claude Code's default.
    var thinking: String? = nil
    /// Claude only: Claude Code's `language` setting (the reply language, like "turkish"); nil or empty changes nothing.
    var language: String? = nil
    /// Shown on screen only; never reaches a script, a path or a command.
    var displayName: String?
    /// Extra Claude settings merged into the agent's settings file (the generated settings win on a clash).
    var advanced: [String: JSONValue]?
    /// Keys of the role file this version does not know (for example `maxBudgetUsd`); they are written back unchanged on save.
    var extra: [String: JSONValue] = [:]
}

extension RoleConfig: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private static let known: Set<String> = ["name", "kind", "tool", "model", "effort", "permissionMode", "outputStyle", "allowedTools", "skills", "instructionFile", "thinking", "language", "displayName", "advanced"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        name = try c.decode(String.self, forKey: Key("name"))
        kind = try c.decode(String.self, forKey: Key("kind"))
        tool = try c.decodeIfPresent(String.self, forKey: Key("tool")) ?? "claude"
        model = try c.decode(String.self, forKey: Key("model"))
        effort = try c.decode(String.self, forKey: Key("effort"))
        permissionMode = try c.decode(String.self, forKey: Key("permissionMode"))
        outputStyle = try c.decode(String.self, forKey: Key("outputStyle"))
        allowedTools = try c.decode([String].self, forKey: Key("allowedTools"))
        skills = try c.decode([String].self, forKey: Key("skills"))
        instructionFile = try c.decode(String.self, forKey: Key("instructionFile"))
        thinking = try c.decodeIfPresent(String.self, forKey: Key("thinking"))
        language = try c.decodeIfPresent(String.self, forKey: Key("language"))
        displayName = try c.decodeIfPresent(String.self, forKey: Key("displayName"))
        advanced = try c.decodeIfPresent([String: JSONValue].self, forKey: Key("advanced"))
        var other: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.known.contains(key.stringValue) { other[key.stringValue] = try c.decode(JSONValue.self, forKey: key) }
        extra = other
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(name, forKey: Key("name")); try c.encode(kind, forKey: Key("kind"))
        if tool != "claude" { try c.encode(tool, forKey: Key("tool")) }
        try c.encode(model, forKey: Key("model"))
        try c.encode(effort, forKey: Key("effort")); try c.encode(permissionMode, forKey: Key("permissionMode")); try c.encode(outputStyle, forKey: Key("outputStyle"))
        try c.encode(allowedTools, forKey: Key("allowedTools")); try c.encode(skills, forKey: Key("skills")); try c.encode(instructionFile, forKey: Key("instructionFile"))
        try c.encodeIfPresent(thinking, forKey: Key("thinking")); try c.encodeIfPresent(language, forKey: Key("language"))
        try c.encodeIfPresent(displayName, forKey: Key("displayName")); try c.encodeIfPresent(advanced, forKey: Key("advanced"))
        for (key, value) in extra where !Self.known.contains(key) { try c.encode(value, forKey: Key(key)) }
    }
}

enum RoleSource: Equatable {
    case base
    case project
    /// Named in the project's `project.json` under "roles": shown, never edited by the panel.
    case mapped
}

struct ResolvedRole: Equatable, Identifiable {
    let config: RoleConfig
    let fileURL: URL
    let source: RoleSource
    var isEditable: Bool { source != .mapped }
    var id: String { fileURL.path }
}

struct RoleProblem: Equatable {
    enum Severity { case error, warning }
    let field: String
    let message: String
    let severity: Severity
}
