import Foundation

/// Who answers the questions agents ask (Settings → PM & Autopilot → Agent questions, N279).
enum AgentQuestionMode: String, CaseIterable, Equatable {
    case pmAll, pmCritical, user

    var title: String {
        switch self {
        case .pmAll: "PM answers all"
        case .pmCritical: "PM answers, critical ones come to me"
        case .user: "All come to me"
        }
    }
}

enum QuestionSettings {
    static let modeKey = "agentQuestions.mode"
    static let languageKey = "agentQuestions.language"

    /// Default: the PM answers, critical ones come to the user.
    static func mode(_ defaults: UserDefaults) -> AgentQuestionMode { defaults.string(forKey: modeKey).flatMap(AgentQuestionMode.init(rawValue:)) ?? .pmCritical }

    /// The user's language by name ("Turkish"), as agents are told at spawn; the system language until the user sets one.
    static func language(_ defaults: UserDefaults) -> String {
        let own = defaults.string(forKey: languageKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? systemLanguage : own
    }

    static var systemLanguage: String {
        let code = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}
