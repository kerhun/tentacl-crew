import Foundation

/// The form's state for one role: every field as the user edits it (text where the file holds lists or JSON).
struct RoleDraft: Equatable, Hashable {
    var name = ""
    var displayName = ""
    var kind = "interactive"
    /// "claude" or "codex" (the role file's `tool`).
    var tool = "claude"
    var model = "sonnet"
    var effort = "medium"
    var permissionMode = "acceptEdits"
    var outputStyle = "concise"
    /// "default", "on" or "off" (the role file leaves `thinking` out for "default").
    var thinking = "default"
    /// The reply language; empty leaves it out of the role file.
    var language = ""
    var allowedTools: [String] = ["Read", "Edit", "Write", "Bash"]
    var skills: [String] = []
    var instructions = ""
    var advancedText = ""
    /// Keys of the role file the form does not show; kept so a save never drops them.
    var extra: [String: JSONValue] = [:]

    init() {}

    init(role: ResolvedRole, instructions: String) {
        let c = role.config
        name = c.name; displayName = c.displayName ?? ""; kind = c.kind; tool = c.tool; model = c.model; effort = c.effort; permissionMode = c.permissionMode; outputStyle = c.outputStyle
        thinking = c.thinking ?? "default"; language = c.language ?? ""
        allowedTools = c.allowedTools
        skills = c.skills
        extra = c.extra
        self.instructions = instructions
        if let advanced = c.advanced, !advanced.isEmpty {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            advancedText = (try? encoder.encode(advanced)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// Ticks or unticks a tool of the catalog; rules typed under "Other rules" are never touched.
    mutating func toggleTool(_ name: String) {
        if let i = allowedTools.firstIndex(of: name) { allowedTools.remove(at: i) } else { allowedTools.append(name) }
    }

    /// The allowed tools that are not in the tick-box list (patterns like `Bash(git status:*)`, MCP tools), as one editable line.
    var customToolsText: String {
        get { allowedTools.filter { !ToolCatalog.names.contains($0) }.joined(separator: ", ") }
        set {
            let custom = newValue.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            allowedTools = allowedTools.filter { ToolCatalog.names.contains($0) } + custom
        }
    }

    /// The role file this draft would become, plus the problems found while reading the Advanced text.
    func config() -> (role: RoleConfig, problems: [RoleProblem]) {
        var problems: [RoleProblem] = []
        var advanced: [String: JSONValue]?
        let trimmed = advancedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) {
                if case .object(let o) = value { advanced = o }
                else { problems.append(RoleProblem(field: "advanced", message: "Advanced must be a JSON object, like {\"permissions\": {...}}.", severity: .error)) }
            } else {
                problems.append(RoleProblem(field: "advanced", message: "Advanced is not valid JSON.", severity: .error))
            }
        }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        // Codex has no such settings (its thinking is the effort), so a Codex role file never carries them.
        let claude = tool != "codex", lang = language.trimmingCharacters(in: .whitespaces)
        let role = RoleConfig(name: self.name, kind: kind, tool: tool, model: model, effort: effort, permissionMode: permissionMode, outputStyle: outputStyle,
                              allowedTools: allowedTools, skills: skills, instructionFile: "\(self.name).md", thinking: claude && thinking != "default" ? thinking : nil,
                              language: claude && !lang.isEmpty ? lang : nil, displayName: name.isEmpty ? nil : name, advanced: advanced, extra: extra)
        return (role, problems)
    }

    /// How many of the form's fields differ from `saved` (a list such as the skills counts once), for the "N unsaved changes" badge.
    func changeCount(from saved: RoleDraft) -> Int {
        let fields: [(RoleDraft) -> AnyHashable] = [{ $0.name }, { $0.displayName }, { $0.kind }, { $0.tool }, { $0.model }, { $0.effort }, { $0.permissionMode },
                                                    { $0.outputStyle }, { $0.thinking }, { $0.language }, { $0.allowedTools }, { $0.skills }, { $0.instructions }, { $0.advancedText }]
        return fields.filter { $0(self) != $0(saved) }.count + (extra == saved.extra ? 0 : 1)
    }
}
