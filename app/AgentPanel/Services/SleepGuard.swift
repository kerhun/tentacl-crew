import Foundation
import AppKit
import IOKit.pwr_mgt
import Observation

/// The assertions the guard holds. In `pmset -g assertions` they are PreventUserIdleSystemSleep, PreventSystemSleep (what
/// `caffeinate -s` holds; macOS honours it on power only) and PreventUserIdleDisplaySleep.
enum AssertionKind: Hashable, CaseIterable {
    case idleSystem, system, idleDisplay

    var type: CFString {
        switch self {
        case .idleSystem: kIOPMAssertPreventUserIdleSystemSleep as CFString
        case .system: "PreventSystemSleep" as CFString
        case .idleDisplay: kIOPMAssertPreventUserIdleDisplaySleep as CFString
        }
    }
}

/// The part of IOKit's power assertions the guard uses; tests replace it.
protocol PowerAssertions {
    func create(kind: AssertionKind, reason: String) -> UInt32?
    func release(_ id: UInt32)
}

struct IOKitPowerAssertions: PowerAssertions {
    func create(kind: AssertionKind, reason: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kind.type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }
    func release(_ id: UInt32) { IOPMAssertionRelease(IOPMAssertionID(id)) }
}

/// When the Mac is kept awake (Settings → Keep awake).
enum KeepAwakeMode: String, CaseIterable {
    case off, agents, always

    var title: String {
        switch self {
        case .off: "Off"
        case .agents: "While agents work"
        case .always: "Always while Tentacl Crew is open"
        }
    }
}

/// The coffee button: keeps the Mac from idle sleep (and, on power, from lid-close sleep) as the mode says, and warns on battery.
@MainActor @Observable
final class SleepGuard {
    /// `lowBattery`: on, but paused because the battery is below the user's threshold.
    enum State: Equatable { case off, waiting, holding, lowBattery }

    static let key = "sleepGuard.on"
    static let modeKey = "sleepGuard.mode"
    static let keepDisplayKey = "sleepGuard.keepDisplay"
    static let lidOnPowerKey = "sleepGuard.lidOnPower"
    static let warnOnBatteryKey = "sleepGuard.warnOnBattery"
    static let stopBelowEnabledKey = "sleepGuard.stopBelowEnabled"
    static let stopBelowPercentKey = "sleepGuard.stopBelowPercent"
    static let reason = "Tentacl Crew: agents are working"
    static let alwaysReason = "Tentacl Crew: keeping the Mac awake while it is open"
    static let batteryWarning = "On battery: closing the lid will pause the agents"
    static let help = "Keeps the Mac awake while agents work. On power it also stays awake with the lid closed; on battery, closing the lid puts the Mac to sleep. Off: the Mac sleeps as usual."

    var mode: KeepAwakeMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.modeKey); defaults.set(mode != .off, forKey: Self.key)
            if mode != .off { lastActiveMode = mode }
            sync()
        }
    }
    var keepDisplay: Bool { didSet { save(keepDisplay, oldValue, Self.keepDisplayKey) } }
    var lidOnPower: Bool { didSet { save(lidOnPower, oldValue, Self.lidOnPowerKey) } }
    var warnOnBattery: Bool { didSet { save(warnOnBattery, oldValue, Self.warnOnBatteryKey) } }
    var stopBelowEnabled: Bool { didSet { save(stopBelowEnabled, oldValue, Self.stopBelowEnabledKey) } }
    var stopBelowPercent: Int {
        didSet { guard stopBelowPercent != oldValue else { return }; defaults.set(stopBelowPercent, forKey: Self.stopBelowPercentKey); sync() }
    }

    /// The quick on/off of the coffee button: on restores the last mode that was not Off.
    var isOn: Bool {
        get { mode != .off }
        set { mode = newValue ? lastActiveMode : .off }
    }

    private(set) var state: State = .off
    /// The power source as of the last look.
    private(set) var source = PowerSnapshot(hasBattery: false, onBattery: false, percent: nil)
    /// After a wake: what the sleep interrupted. Cleared by `dismissInterruption()` and by the next sleep.
    private(set) var interruption: String?
    /// Where "The Mac is going to sleep on battery" goes (a macOS notification, set by the panel).
    @ObservationIgnored var onNotice: (_ title: String, _ body: String) -> Void = { _, _ in }

    @ObservationIgnored private var running = false
    @ObservationIgnored private var agents = 0
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var held: [AssertionKind: UInt32] = [:]
    @ObservationIgnored private var lastActiveMode: KeepAwakeMode
    @ObservationIgnored private var sleepStart: (at: Date, onBattery: Bool, agents: Int)?
    @ObservationIgnored private let power: PowerAssertions
    @ObservationIgnored private let environment: PowerEnvironment
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    init(power: PowerAssertions = IOKitPowerAssertions(), environment: PowerEnvironment? = nil,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.power = power
        let environment = environment ?? SystemPowerEnvironment()
        self.environment = environment
        self.defaults = defaults
        self.now = now
        // The old on/off switch ("sleepGuard.on") becomes a mode; with nothing saved the mode is "While agents work".
        let saved = defaults.string(forKey: Self.modeKey).flatMap(KeepAwakeMode.init(rawValue:))
        let initial = saved ?? ((defaults.object(forKey: Self.key) as? Bool) == false ? .off : .agents)
        mode = initial
        lastActiveMode = initial == .off ? .agents : initial
        keepDisplay = defaults.object(forKey: Self.keepDisplayKey) as? Bool ?? false
        lidOnPower = defaults.object(forKey: Self.lidOnPowerKey) as? Bool ?? true
        warnOnBattery = defaults.object(forKey: Self.warnOnBatteryKey) as? Bool ?? true
        stopBelowEnabled = defaults.object(forKey: Self.stopBelowEnabledKey) as? Bool ?? false
        stopBelowPercent = defaults.object(forKey: Self.stopBelowPercentKey) as? Int ?? 20
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareToQuit() }
        }
        environment.start(onChange: { [weak self] in self?.sync() }, willSleep: { [weak self] in self?.willSleep() }, didWake: { [weak self] in self?.didWake() })
        sync()
    }

    /// Call whenever the set of running tasks may have changed; `agents` is how many agents are working (for the sleep notice).
    func update(running: Bool, agents: Int? = nil) {
        self.running = running
        self.agents = running ? max(agents ?? 1, 1) : 0
        sync()
    }

    func prepareToQuit() { quitting = true; sync() }
    func dismissInterruption() { interruption = nil }

    /// Whether this Mac has a lid that "stay awake with the lid closed" applies to (a laptop: it has a battery).
    var supportsLidClosed: Bool { source.hasBattery }

    /// The Settings line under "Stay awake with the lid closed on power".
    var lidSupportNote: String {
        supportsLidClosed
            ? "This Mac is a laptop, so it applies. Tentacl Crew asks macOS not to sleep when the lid closes (the assertion caffeinate -s holds); macOS honours that on power only."
            : "Not needed: this Mac has no lid."
    }

    /// Set while agents work on battery with the warning on: closing the lid would pause them.
    var warning: String? {
        mode != .off && !quitting && running && source.hasBattery && source.onBattery && warnOnBattery ? Self.batteryWarning : nil
    }

    var tooltip: String {
        var lines: [String] = []
        if let warning { lines.append(warning) }
        switch state {
        case .off: lines.append("Off. The Mac sleeps as usual.")
        case .waiting: lines.append("Keep awake: \(mode.title). No agent is working.")
        case .holding: lines.append("Keep awake: \(mode.title). Keeping the Mac awake now.")
        case .lowBattery: lines.append("Keep awake: \(mode.title). Paused: the battery is below \(stopBelowPercent)%.")
        }
        if let interruption { lines.append(interruption) }
        return lines.joined(separator: "\n")
    }

    private var batteryLow: Bool {
        guard stopBelowEnabled, source.onBattery, let percent = source.percent else { return false }
        return percent < stopBelowPercent
    }

    private func save(_ value: Bool, _ old: Bool, _ key: String) {
        guard value != old else { return }
        defaults.set(value, forKey: key); sync()
    }

    private func willSleep() {
        source = environment.snapshot
        guard running, agents > 0 else { sleepStart = nil; return }
        sleepStart = (now(), source.onBattery, agents)
        interruption = nil
        if source.onBattery, warnOnBattery {
            onNotice("The Mac is going to sleep on battery", "\(Self.agentsText(agents, "is", "are")) working and will pause until it wakes.")
        }
    }

    private func didWake() {
        defer { sync() }
        guard let start = sleepStart else { return }
        sleepStart = nil
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        interruption = "Mac slept \(f.string(from: start.at))–\(f.string(from: now())) \(start.onBattery ? "on battery" : "on power"); \(Self.agentsText(start.agents, "was", "were")) working"
    }

    private static func agentsText(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 agent \(one)" : "\(n) agents \(many)" }

    private func sync() {
        source = environment.snapshot
        let active = mode != .off && !quitting && (mode == .always || running)
        var wanted: [AssertionKind: String] = [:]
        if active, !batteryLow {
            let base = mode == .always && !running ? Self.alwaysReason : Self.reason
            wanted[.idleSystem] = base
            if lidOnPower, source.hasBattery, !source.onBattery { wanted[.system] = base + " (lid closed on power)" }
            if keepDisplay { wanted[.idleDisplay] = base + " (display)" }
        }
        for (kind, id) in held where wanted[kind] == nil { power.release(id); held[kind] = nil }
        for kind in AssertionKind.allCases { if let reason = wanted[kind], held[kind] == nil { held[kind] = power.create(kind: kind, reason: reason) } }
        if mode == .off { state = .off }
        else if active, batteryLow { state = .lowBattery }
        else { state = held[.idleSystem] != nil ? .holding : .waiting }
    }
}
