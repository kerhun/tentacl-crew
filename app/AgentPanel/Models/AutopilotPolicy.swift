import Foundation

/// How the PM agent takes part in the answers agents wait for.
enum AutopilotMode: String, Codable, CaseIterable, Equatable {
    /// Every question goes to the user, as before.
    case off
    /// The PM suggests an answer for its questions; nothing is sent until the user picks it.
    case shadow
    /// The PM answers its questions itself; only escalations reach the user.
    case on

    var title: String {
        switch self {
        case .off: "Off"
        case .shadow: "Shadow"
        case .on: "On"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Every question comes to you."
        case .shadow: "PM suggests an answer; you still send it."
        case .on: "PM answers; only escalations come to you."
        }
    }
}

/// The kinds of moments an agent waits on, as the policy table names them.
enum DecisionCategory: String, Codable, CaseIterable, Equatable {
    case choice, freeText, permission, plan, fix, review

    init(_ kind: AgentQuestion.Kind) {
        switch kind {
        case .choice: self = .choice
        case .freeText: self = .freeText
        case .permission: self = .permission
        case .plan: self = .plan
        case .signIn: self = .choice
        }
    }

    var title: String {
        switch self {
        case .choice: "Agent question (options)"
        case .freeText: "Agent question (free text)"
        case .permission: "Permission prompt"
        case .plan: "Plan approval"
        case .fix: "Fix notes from a reviewer"
        case .review: "Prepare review when an agent finishes"
        }
    }

    var rule: String {
        switch self {
        case .choice: "PM picks an option when the card settles it; product, design or scope choices come to you."
        case .freeText: "Same rule; PM's answer is one paragraph of at most 600 characters."
        case .permission: "PM may allow once for work inside the task. Never \"don't ask again\"; network, push, installs and deletes always come to you."
        case .plan: "PM approves with manual edit approval when the plan stays within the card's scope. Never auto mode."
        case .fix: "PM passes a reviewer's new Fix notes on to the developer when they ask for changes inside the card's Scope. Everything else, and every third round on a card, comes to you."
        case .review: "When an agent finishes its turn and its Report is filled, the panel prepares the review packet. A failed packet goes back to the agent as a fix request (at most 2 rounds per card); in Shadow it comes to you."
        }
    }
}

enum DecisionOwner: String, Codable, Equatable { case you, pm }

/// One project's autopilot settings. Kept in the app's own folder, never in the project, so no agent can change its own rules.
struct AutopilotPolicy: Codable, Equatable {
    var mode: AutopilotMode = .shadow
    var owners: [String: DecisionOwner] = [:]
    /// After this many seconds without a PM decision the question goes to the user.
    var timeoutSeconds: Int = 180
    var model: String = "opus"
    /// The model of the Codex decider (used only when Claude is not signed in); empty = the first one Codex lists.
    var codexModel: String = ""
    var budgetUSD: Double = 0.5
    /// Today's estimated cost (agents and PM decisions) at which the PM stops deciding; nil means no limit.
    var dailyLimitUSD: Double?
    /// Whether the panel writes a line into the PM pane when a card changes phase.
    var tellPM = true
    /// Standing PM authority: the PM may start planned cards and approve cards that passed review without a fresh user message.
    var pmAuthority = false
    /// The most cards the PM may start in one day under that authority.
    var pmStartsPerDay = 6
    /// Whether the PM may run the build and test commands (read-only, output trimmed) while it writes the first project summary.
    var runBuildAndTest = true
    /// Whether the PM starts a fresh conversation with hand-off at each new round, when a round is finished, and at the safe point (N171).
    var freshConversation = true

    static let models = ["opus", "sonnet", "haiku"]
    static let defaultOwners: [DecisionCategory: DecisionOwner] = [.choice: .pm, .freeText: .pm, .permission: .pm, .plan: .pm, .fix: .pm, .review: .pm]

    func owner(of category: DecisionCategory) -> DecisionOwner {
        owners[category.rawValue] ?? Self.defaultOwners[category] ?? .you
    }

    mutating func setOwner(_ owner: DecisionOwner, for category: DecisionCategory) { owners[category.rawValue] = owner }

    /// Who answers a question now: the PM only while the autopilot is not off and the table gives the category to the PM.
    func handler(for kind: AgentQuestion.Kind) -> DecisionOwner {
        mode == .off ? .you : owner(of: DecisionCategory(kind))
    }

    /// Who handles a reviewer's new Fix notes: the PM only while the autopilot is not off and the table gives them to the PM.
    var fixHandler: DecisionOwner { mode == .off ? .you : owner(of: .fix) }

    /// Who prepares the review of a finished agent's work: the panel for the PM only while the autopilot is not off.
    var reviewHandler: DecisionOwner { mode == .off ? .you : owner(of: .review) }

    init() {}

    private enum Key: String, CodingKey { case mode, owners, timeoutSeconds, model, codexModel, budgetUSD, dailyLimitUSD, tellPM, pmAuthority, pmStartsPerDay, runBuildAndTest, freshConversation }

    /// Missing or unknown values fall back to the defaults, so an older or hand-edited file still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        mode = (try? c.decodeIfPresent(AutopilotMode.self, forKey: .mode)) ?? .shadow
        owners = (try? c.decodeIfPresent([String: DecisionOwner].self, forKey: .owners)) ?? [:]
        timeoutSeconds = min(max((try? c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)) ?? 180, 30), 1800)
        let m = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? "opus"
        model = Self.models.contains(m) ? m : "opus"
        codexModel = ((try? c.decodeIfPresent(String.self, forKey: .codexModel)) ?? "").trimmingCharacters(in: .whitespaces)
        budgetUSD = min(max((try? c.decodeIfPresent(Double.self, forKey: .budgetUSD)) ?? 0.5, 0.05), 5)
        dailyLimitUSD = ((try? c.decodeIfPresent(Double.self, forKey: .dailyLimitUSD)) ?? nil).flatMap { $0 > 0 ? min($0, 10_000) : nil }
        tellPM = (try? c.decodeIfPresent(Bool.self, forKey: .tellPM)) ?? true
        pmAuthority = (try? c.decodeIfPresent(Bool.self, forKey: .pmAuthority)) ?? false
        pmStartsPerDay = min(max((try? c.decodeIfPresent(Int.self, forKey: .pmStartsPerDay)) ?? 6, 1), 50)
        runBuildAndTest = (try? c.decodeIfPresent(Bool.self, forKey: .runBuildAndTest)) ?? true
        freshConversation = (try? c.decodeIfPresent(Bool.self, forKey: .freshConversation)) ?? true
    }
}

/// What the panel needs to know to judge a start or approve request the user did not back with a message of their own.
struct PMAuthority: Equatable {
    var enabled = false
    var startsPerDay = 6
    /// Cards started under the authority today.
    var startedToday = 0
    /// The daily cost limit is reached.
    var costLimitReached = false

    /// The tag in the decision feed and the action log.
    static let tag = "PM authority"
    static let setupCard = "setup cards are never started or approved by the PM on its own"

    /// Why nothing at all may be done under the authority now, or nil.
    var blocker: String? {
        costLimitReached ? "the daily cost limit is reached, so the PM's standing authority is paused" : nil
    }
}

/// Reads and writes one policy file per project in `~/Library/Application Support/Tentacl/autopilot/`.
struct AutopilotStore: Sendable {
    let folder: URL

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tentacl/autopilot")
    }

    /// A project id becomes a file name only when it is a plain name; anything else is not stored.
    static func fileStem(for projectID: String) -> String? {
        let ok = !projectID.isEmpty && projectID.count <= 80 && projectID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } && !projectID.hasPrefix(".")
        return ok ? projectID : nil
    }

    func policyURL(_ projectID: String) -> URL? { Self.fileStem(for: projectID).map { folder.appendingPathComponent("\($0).json") } }
    func decisionsURL(_ projectID: String) -> URL? { Self.fileStem(for: projectID).map { folder.appendingPathComponent("\($0).decisions.jsonl") } }

    /// What a project without a policy file of its own starts with (Settings → Autopilot defaults). Kept next to the folder, not in it, so no project id can collide with it.
    var defaultsURL: URL { folder.deletingLastPathComponent().appendingPathComponent("autopilot-defaults.json") }

    func loadDefaults() -> AutopilotPolicy {
        guard let data = try? Data(contentsOf: defaultsURL), let policy = try? JSONDecoder().decode(AutopilotPolicy.self, from: data) else { return AutopilotPolicy() }
        return policy
    }

    /// Only the mode (never On: that needs its confirmation in each project), model, budget and daily limit are defaults.
    func saveDefaults(_ policy: AutopilotPolicy) throws {
        var d = AutopilotPolicy()
        d.mode = policy.mode == .on ? .shadow : policy.mode
        d.model = policy.model; d.budgetUSD = policy.budgetUSD; d.dailyLimitUSD = policy.dailyLimitUSD
        try FileManager.default.createDirectory(at: defaultsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(d).write(to: defaultsURL, options: .atomic)
    }

    func load(_ projectID: String) -> AutopilotPolicy {
        guard let url = policyURL(projectID), let data = try? Data(contentsOf: url), let policy = try? JSONDecoder().decode(AutopilotPolicy.self, from: data) else { return loadDefaults() }
        return policy
    }

    func save(_ policy: AutopilotPolicy, for projectID: String) throws {
        guard let url = policyURL(projectID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: url, options: .atomic)
    }
}
