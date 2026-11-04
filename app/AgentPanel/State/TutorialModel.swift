import Foundation
import Observation

/// The running tour (N311): which tour and step, Next/Back/Skip, steps whose target is missing, and the cards and nudge around the tours.
/// The tour never presses a button: it moves the highlight, changes the screen when a step is elsewhere, and saves the progress.
@MainActor @Observable
final class TutorialModel {
    /// A centred card outside a tour: the first-launch welcome, or the Dashboard tour offered after first launch.
    enum Card: Equatable { case welcome, offerDashboard }

    @ObservationIgnored let store: TutorialStore
    /// Whether the welcome card and the first-visit nudge come up by themselves (off in tests, UI tests and the demo).
    @ObservationIgnored let autoOffer: Bool
    /// Opens a screen for a step on another screen (set by the window).
    @ObservationIgnored var navigate: (ShellScreen) -> Void = { _ in }

    private(set) var save: TutorialSave
    private(set) var active: TutorialTourID?
    private(set) var index = 0
    /// Steps passed over because their target was missing; the counter leaves them out.
    private(set) var skipped: Set<Int> = []
    private var forward = true
    var card: Card?
    /// The screen the first-visit nudge is shown on.
    var nudge: ShellScreen?
    /// The `?` popover (Help › All Tours… opens it).
    var popoverOpen = false
    /// "Reset all tours…" asks first.
    var confirmingReset = false
    private(set) var screen: ShellScreen
    /// Whether the window has a project (without one, "Tour this screen" is first launch).
    var hasProjects = true
    /// The anchors each host (the window, an open sheet) has on screen now.
    private var hosts: [String: Set<TutorialAnchorID>] = [:]

    init(store: TutorialStore, autoOffer: Bool = false, screen: ShellScreen = .dashboard) {
        self.store = store
        self.autoOffer = autoOffer
        self.screen = screen
        save = store.load()
    }

    var present: Set<TutorialAnchorID> { hosts.values.reduce(into: []) { $0.formUnion($1) } }
    var tour: TutorialTour? { active.map(\.tour) }
    var step: TutorialStep? { tour.map { $0.steps[index] } }
    func progress(_ id: TutorialTourID) -> TutorialProgress { save.progress(id) }

    /// The step's target is missing and a dashed example stands in its place.
    var showsExample: Bool {
        guard let step, let example = step.exampleAt else { return false }
        return !present.contains(step.anchor) && present.contains(example)
    }

    /// The step is all the tour can show (no page in the Preview): it says its `aloneText` and is step 1 of 1.
    var isAlone: Bool {
        guard let step, let without = step.aloneWithout else { return false }
        return !present.contains(without)
    }

    /// The anchor the ring goes around.
    var highlighted: TutorialAnchorID? {
        guard let step else { return nil }
        if showsExample { return step.exampleAt }
        if let other = step.orAt, !present.contains(step.anchor) { return other }
        return step.anchor
    }

    var text: String { (isAlone ? step?.aloneText : nil) ?? step?.text ?? "" }

    /// "step n of N": the steps passed over do not count.
    var position: (n: Int, of: Int) {
        guard let tour else { return (0, 0) }
        if isAlone { return (1, 1) }
        return ((0..<index).filter { !skipped.contains($0) }.count + 1, tour.steps.count - skipped.count)
    }

    var isLast: Bool { position.n == position.of }

    /// What VoiceOver says when a step opens.
    var announcement: String {
        guard let tour, let step else { return "" }
        return "\(tour.id.title) tour, step \(position.n) of \(position.of). \(step.title) \(text)"
    }

    // MARK: moving

    func start(_ id: TutorialTourID, at step: Int = 0) {
        card = nil
        nudge = nil
        popoverOpen = false
        active = id
        skipped = []
        forward = true
        go(min(max(step, 0), id.tour.steps.count - 1))
        // Before the window has reported its anchors nothing is known to be missing.
        if !hosts.isEmpty { validate() }
    }

    /// A finished, skipped or new tour starts at step 1; one in progress goes on at its saved step.
    func open(_ id: TutorialTourID) {
        let p = progress(id)
        start(id, at: p.state == .inProgress ? p.step : 0)
    }

    func next() {
        if isLast || isAlone { done() } else { move(1) }
    }

    func back() { move(-1) }

    /// Skip tour or Esc: saved as skipped, nothing is asked.
    func skip() {
        guard let active else { return }
        record(active, .skipped, step: index)
        self.active = nil
    }

    func done() {
        guard let active else { return }
        record(active, .finished, step: 0)
        self.active = nil
        if active == .firstLaunch, progress(.dashboard).state == .notStarted { card = .offerDashboard }
    }

    /// The user went elsewhere: the step is kept and offered as Resume.
    func pause() {
        guard let active else { return }
        record(active, .inProgress, step: index)
        self.active = nil
    }

    private func move(_ step: Int) {
        guard let tour else { return }
        forward = step > 0
        var i = index + step
        while tour.steps.indices.contains(i) {
            if canShow(i) { go(i); return }
            skipped.insert(i)
            i += step
        }
        if forward { done() }
    }

    private func go(_ i: Int) {
        guard let active, let tour else { return }
        index = i
        record(active, .inProgress, step: i)
        if let target = tour.steps[i].screen, target != screen { navigate(target) }
    }

    /// The step can show: its target (or its example's place) is there, or it is on another screen the tour goes to first.
    private func canShow(_ i: Int) -> Bool {
        guard let step = tour?.steps[i] else { return false }
        if let target = step.screen, target != screen { return true }
        return present.contains(step.anchor) || step.exampleAt.map(present.contains) == true || step.orAt.map(present.contains) == true
    }

    /// The current step's target went missing (or never came): it is passed over in the direction the user moved.
    private func validate() {
        guard active != nil, !canShow(index) else { return }
        skipped.insert(index)
        let before = index
        move(forward ? 1 : -1)
        // Nothing before it: go on forward instead.
        if active != nil, index == before, !forward { move(1) }
    }

    // MARK: what the window tells the model

    func anchorsChanged(host: String, _ anchors: Set<TutorialAnchorID>) {
        guard hosts[host] != anchors else { return }
        hosts[host] = anchors.isEmpty ? nil : anchors
        // With no anchors anywhere (the window went away) nothing is known to be missing.
        guard let step, !present.isEmpty else { return }
        if let advance = step.advancesWhen, anchors.contains(advance) { move(1); return }
        validate()
    }

    func screenChanged(to newScreen: ShellScreen) {
        screen = newScreen
        if let target = step?.screen, target != newScreen { pause() }
        if active == nil { offerNudge(on: newScreen) }
    }

    // MARK: offers

    /// The welcome card: no project yet, first launch never finished or skipped, and no sheet (Setup) open.
    func offerFirstLaunch(noProjects: Bool, sheetOpen: Bool) {
        guard autoOffer, noProjects, !sheetOpen, active == nil, card == nil, progress(.firstLaunch).state == .notStarted else { return }
        card = .welcome
    }

    /// Not now on the welcome card: first launch is skipped; the `?` button offers it again.
    func declineWelcome() {
        record(.firstLaunch, .skipped, step: 0)
        card = nil
    }

    /// The first visit to a screen with a tour, after first launch: a small nudge, once per screen.
    func offerNudge(on screen: ShellScreen) {
        guard autoOffer, save.offerOnNewScreen, card == nil, [.finished, .skipped].contains(progress(.firstLaunch).state),
              let id = TutorialTours.forScreen(screen, hasProjects: true), id != .firstLaunch,
              !save.seenScreens.contains(screen.rawValue), progress(id).state == .notStarted else { return }
        save.seenScreens.append(screen.rawValue)
        store.save(save)
        nudge = screen
    }

    /// ✕, Esc or a click outside the nudge (N319): it goes, and its screen stays seen so it does not come back there.
    func dismissNudge() {
        guard let shown = nudge else { return }
        nudge = nil
        guard !save.seenScreens.contains(shown.rawValue) else { return }
        save.seenScreens.append(shown.rawValue)
        store.save(save)
    }

    func setOfferOnNewScreen(_ on: Bool) {
        save.offerOnNewScreen = on
        store.save(save)
    }

    /// Clears every tour's progress (after the user confirmed).
    func reset() {
        active = nil
        card = nil
        nudge = nil
        store.reset()
        save = store.load()
    }

    // MARK: labels

    /// The tour of the screen the window shows (Help › Tour This Screen, ⌘K).
    var tourHere: TutorialTourID? { TutorialTours.forScreen(screen, hasProjects: hasProjects) }

    /// The first tour in progress (Help › Resume …, ⌘K).
    var resumable: TutorialTourID? { TutorialTourID.allCases.first { progress($0).state == .inProgress && $0 != active } }

    /// The `?` popover's state column: "✓ finished", "skipped · start", "resume · step 4 of 7", "not started".
    func stateLabel(_ id: TutorialTourID) -> String {
        let p = progress(id)
        switch p.state {
        case .finished: return "✓ finished"
        case .skipped: return "skipped · start"
        case .inProgress: return "resume · step \(p.step + 1) of \(id.tour.steps.count)"
        case .notStarted: return "not started"
        }
    }

    /// Settings › General › Tours: "2 of 7 finished · Tasks in progress".
    var summary: String {
        let finished = TutorialTourID.allCases.filter { progress($0).state == .finished }.count
        let doing = TutorialTourID.allCases.filter { progress($0).state == .inProgress }.map(\.title)
        return "\(finished) of \(TutorialTourID.allCases.count) finished" + (doing.isEmpty ? "" : " · \(doing.joined(separator: ", ")) in progress")
    }

    private func record(_ id: TutorialTourID, _ state: TutorialProgress.State, step: Int) {
        save.tours[id] = TutorialProgress(state: state, step: step, version: id.tour.version)
        store.save(save)
    }
}
