import Foundation

/// The rules `validate-config.sh` applies to a role file, plus the checks only the form needs (live feedback while typing).
enum RoleValidator {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    static let permissionModes = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    static let kinds = ["interactive", "headless"]
    static let tools = ["claude", "codex"]
    /// Any non-empty model is accepted. The efforts are the ones the Codex catalog lists for the model; this list is the fallback while the catalog is unknown.
    static let codexEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let codexPermissionModes = ["manual", "acceptEdits", "plan", "bypassPermissions"]

    /// The agent name is `<role>-<task>`, so a role name has no "-" and a role can always be read back from an agent name.
    static func validName(_ s: String) -> Bool {
        guard (1...20).contains(s.count), let first = s.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// `knownStyles` (the output style catalog) lets an unknown style show as a warning; without it the style is only checked for being non-empty.
    static func problems(for role: RoleConfig, knownStyles: [String]? = nil, codexEfforts catalogEfforts: [String]? = nil) -> [RoleProblem] {
        var out: [RoleProblem] = []
        func error(_ field: String, _ message: String) { out.append(RoleProblem(field: field, message: message, severity: .error)) }
        func warning(_ field: String, _ message: String) { out.append(RoleProblem(field: field, message: message, severity: .warning)) }

        if !validName(role.name) { error("name", "Use lowercase letters, digits or _, start with a letter, at most 20 characters.") }
        if !kinds.contains(role.kind) { error("kind", "Kind must be interactive or headless.") }
        let codex = role.tool == "codex"
        if !tools.contains(role.tool) { error("tool", "Tool must be claude or codex.") }
        if role.model.trimmingCharacters(in: .whitespaces).isEmpty { error("model", codex ? "Model is missing (a Codex model name)." : "Model is missing (opus, sonnet, haiku, fable or a full model name).") }
        let allowedEfforts = codex ? (catalogEfforts.flatMap { $0.isEmpty ? nil : $0 } ?? codexEfforts) : efforts
        if !allowedEfforts.contains(role.effort) { error("effort", "Effort must be \(allowedEfforts.dropLast().joined(separator: ", ")) or \(allowedEfforts.last!).") }
        let allowedModes = codex ? codexPermissionModes : permissionModes
        if !allowedModes.contains(role.permissionMode) { error("permissionMode", "Permission mode must be one of: \(allowedModes.joined(separator: ", ")).") }
        if role.outputStyle.trimmingCharacters(in: .whitespaces).isEmpty || role.outputStyle.contains("\n") { error("outputStyle", "Output style must be one line naming a style (Concise, Explanatory, or one of your own).") }
        else if codex {
            if !["default", "concise"].contains(role.outputStyle.lowercased()) { warning("outputStyle", "Output style is ignored for a Codex role.") }
        }
        else if let known = knownStyles, !known.contains(OutputStyleCatalog.canonical(role.outputStyle)) {
            warning("outputStyle", "Output style \"\(role.outputStyle)\" is not a built-in style or a style file on this machine; Claude Code falls back to Default if it is missing.")
        }
        if let t = role.thinking, !["on", "off"].contains(t) { error("thinking", "Thinking must be on or off (leave it out for Claude Code's default).") }
        if let l = role.language, l.contains("\n") { error("language", "Reply language must be one line, like turkish.") }
        if !codex && role.thinking == "off" && ["xhigh", "max"].contains(role.effort) { warning("thinking", "With thinking off, some models refuse effort \(role.effort); pick high or lower.") }
        if codex && (role.thinking != nil || role.language != nil) { warning("thinking", "Thinking and reply language are ignored for a Codex role.") }
        if role.allowedTools.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.contains("\n") }) { error("allowedTools", "Allowed tools cannot contain empty entries or line breaks.") }
        if role.skills.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.contains("\n") }) { error("skills", "Skills cannot contain empty entries or line breaks.") }
        if codex {
            if !role.skills.isEmpty { warning("skills", "Skills are ignored for a Codex role.") }
            if !role.allowedTools.isEmpty { warning("allowedTools", "Allowed tools are ignored for a Codex role.") }
            if role.advanced != nil { warning("advanced", "Advanced settings are ignored for a Codex role.") }
        }
        let file = role.instructionFile
        if file.isEmpty || file.contains("/") || file == "." || file == ".." { error("instructionFile", "The instruction file must be a plain file name next to the role file.") }
        if let name = role.displayName, !name.isEmpty {
            if name.count > 40 { error("displayName", "The display name can have at most 40 characters.") }
            if name.contains("\n") || name.contains("\r") { error("displayName", "The display name must be one line.") }
        }
        if let advanced = role.advanced {
            if containsKey("env", in: .object(advanced)) {
                error("advanced", "\"env\" is not supported: do not put secrets in role files, define them in your terminal.")
            }
            if advanced["model"] != nil { warning("advanced.model", "The Model field wins over \"model\" here.") }
            if case .object(let p)? = advanced["permissions"], p["defaultMode"] != nil { warning("advanced.permissions.defaultMode", "The Permission mode field wins over \"permissions.defaultMode\" here.") }
            if advanced["enabledPlugins"] != nil { warning("advanced.enabledPlugins", "The skills list decides the plugins; \"enabledPlugins\" here is overridden.") }
            if advanced["skillOverrides"] != nil { warning("advanced.skillOverrides", "The skills list decides the skill switches; \"skillOverrides\" here is overridden.") }
            if case .object(let p)? = advanced["permissions"] {
                for rule in ["allow", "deny", "ask"] {
                    if case .array(let items)? = p[rule], !items.isEmpty {
                        warning("advanced.permissions.\(rule)", "\"permissions.\(rule)\" adds rules on top of the Allowed tools field; check that it does not give this role more than intended.")
                    }
                }
            }
            if advanced["hooks"] != nil { warning("advanced.hooks", "\"hooks\" run commands on your machine when the agent works; make sure you trust them.") }
            for key in ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "statusLine"] where advanced[key] != nil {
                warning("advanced.\(key)", "\"\(key)\" runs a command on your machine; make sure you trust it.")
            }
        }
        return out
    }

    private static func containsKey(_ key: String, in value: JSONValue) -> Bool {
        switch value {
        case .object(let o): return o[key] != nil || o.values.contains { containsKey(key, in: $0) }
        case .array(let a): return a.contains { containsKey(key, in: $0) }
        default: return false
        }
    }
}
