import Foundation

struct ModelChoice: Equatable, Identifiable {
    let id: String
    let label: String
    let group: String
}

/// The models a role can name. Claude has no command that lists its models, so this is a fixed list: the aliases (which follow the
/// newest release) and the pinned versions. Any other model name can still be typed into the field.
enum ModelCatalog {
    static let latestGroup = "Latest (follows new releases)"
    static let pinnedGroup = "Pinned versions"

    static let claude: [ModelChoice] = [
        ModelChoice(id: "opus", label: "Opus (latest)", group: latestGroup),
        ModelChoice(id: "sonnet", label: "Sonnet (latest)", group: latestGroup),
        ModelChoice(id: "haiku", label: "Haiku (latest)", group: latestGroup),
        ModelChoice(id: "fable", label: "Fable (latest)", group: latestGroup),
        ModelChoice(id: "claude-opus-5-5", label: "Opus 5.5", group: pinnedGroup),
        ModelChoice(id: "claude-sonnet-5-5", label: "Sonnet 5.5", group: pinnedGroup),
        ModelChoice(id: "claude-haiku-5-5", label: "Haiku 5.5", group: pinnedGroup),
        ModelChoice(id: "claude-fable-5-1", label: "Fable 5.1", group: pinnedGroup),
    ]

    /// The readable name of a model id; a model that is not in the list (typed by hand) keeps its id.
    static func label(for id: String) -> String { claude.first { $0.id == id }?.label ?? id }
}

struct ToolInfo: Equatable, Identifiable {
    let name: String
    let summary: String
    var id: String { name }
}

/// The tools an agent can be allowed to use without asking. Anything else (a rule like `Bash(git status:*)`, an MCP tool)
/// goes into the "Other rules" field of the form.
enum ToolCatalog {
    static let claude: [ToolInfo] = [
        ToolInfo(name: "Read", summary: "Read files"),
        ToolInfo(name: "Edit", summary: "Change existing files"),
        ToolInfo(name: "Write", summary: "Create or overwrite files"),
        ToolInfo(name: "NotebookEdit", summary: "Edit Jupyter notebooks"),
        ToolInfo(name: "Bash", summary: "Run shell commands"),
        ToolInfo(name: "Glob", summary: "Find files by name pattern"),
        ToolInfo(name: "Grep", summary: "Search inside files"),
        ToolInfo(name: "WebFetch", summary: "Fetch a web page"),
        ToolInfo(name: "WebSearch", summary: "Search the web"),
        ToolInfo(name: "Task", summary: "Start sub-agents"),
        ToolInfo(name: "TodoWrite", summary: "Keep a to-do list"),
    ]
    static var names: Set<String> { Set(claude.map(\.name)) }
}
