import Foundation

/// One tour's saved progress.
struct TutorialProgress: Equatable {
    enum State: String { case notStarted, inProgress, finished, skipped }
    var state = State.notStarted
    /// The step to resume at (0-based).
    var step = 0
    var version = 1
}

/// Everything `tutorial.v1` holds: app-wide, not per project.
struct TutorialSave: Equatable {
    var tours: [TutorialTourID: TutorialProgress] = [:]
    var offerOnNewScreen = true
    var seenScreens: [String] = []

    func progress(_ id: TutorialTourID) -> TutorialProgress { tours[id] ?? TutorialProgress(version: id.tour.version) }
}

/// Reads and writes the tours' progress in UserDefaults under `tutorial.v1` (spec "İlerleme kaydı"):
/// `{ "<tourID>": { "state": …, "step": 3, "version": 1 }, "offerOnNewScreen": true, "seenScreens": ["plan", …] }`.
struct TutorialStore {
    static let key = "tutorial.v1"
    let defaults: UserDefaults

    func load() -> TutorialSave {
        guard let data = defaults.data(forKey: Self.key),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return TutorialSave() }
        var save = TutorialSave()
        save.offerOnNewScreen = json["offerOnNewScreen"] as? Bool ?? true
        save.seenScreens = json["seenScreens"] as? [String] ?? []
        for id in TutorialTourID.allCases {
            guard let entry = json[id.rawValue] as? [String: Any] else { continue }
            let version = entry["version"] as? Int ?? 0
            // The tour's steps changed since: only this tour starts over.
            guard version == id.tour.version else { continue }
            let state = (entry["state"] as? String).flatMap(TutorialProgress.State.init(rawValue:)) ?? .notStarted
            let step = min(max(entry["step"] as? Int ?? 0, 0), id.tour.steps.count - 1)
            save.tours[id] = TutorialProgress(state: state, step: step, version: version)
        }
        return save
    }

    func save(_ save: TutorialSave) {
        var json: [String: Any] = ["offerOnNewScreen": save.offerOnNewScreen, "seenScreens": save.seenScreens]
        for (id, p) in save.tours { json[id.rawValue] = ["state": p.state.rawValue, "step": p.step, "version": p.version] }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) { defaults.set(data, forKey: Self.key) }
    }

    /// Clears every tour's progress and the seen screens; "Offer a tour on a new screen" is a setting and stays.
    func reset() {
        let offer = load().offerOnNewScreen
        save(TutorialSave(offerOnNewScreen: offer))
    }
}
