import Foundation

/// The user's usage gate: no new agent starts while the 5-hour or the week plan usage is above a threshold (N259). Unlike the
/// safe point it covers the week window too, and "Start anyway" lifts it until the window that held it resets.
struct UsageGate: Equatable {
    static let range = 50...100
    static let defaultFiveHour = 90
    static let defaultWeek = 95
    static let fiveHourKey = "usageGateFiveHour"
    static let weekKey = "usageGateWeek"
    /// The Unix time until which "Start anyway" lifts the gate.
    static let overrideKey = "usageGateOverrideUntil"
    /// The stored value for "off".
    static let offValue = 0

    /// Nil: off.
    var fiveHour: Int?
    var week: Int?

    init(fiveHour: Int? = Self.defaultFiveHour, week: Int? = Self.defaultWeek) {
        self.fiveHour = fiveHour.map(Self.clamp)
        self.week = week.map(Self.clamp)
    }

    /// Stored values: unset is the default, `offValue` is off, anything else is clamped into the range.
    init(fiveHourStored: Int?, weekStored: Int?) {
        self.init(fiveHour: Self.decode(fiveHourStored, default: Self.defaultFiveHour), week: Self.decode(weekStored, default: Self.defaultWeek))
    }

    private static func clamp(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) }
    private static func decode(_ stored: Int?, default value: Int) -> Int? {
        switch stored { case nil: value; case Self.offValue?: nil; case let v?: v }
    }
    static func encode(_ v: Int?) -> Int { v ?? offValue }

    /// "5 h usage 93% — resets at 14:20" for the first window above its threshold (the 5-hour one first); nil while none is, when
    /// the usage is unknown, and for a window that has already reset.
    func reason(_ usage: PlanUsage?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let usage else { return nil }
        for (label, limit, window) in [("5 h", fiveHour, usage.fiveHour), ("Week", week, usage.week)] {
            guard let limit, let window, window.resetsAt > now, window.percent > Double(limit) else { continue }
            return "\(label) usage \(Int(window.percent.rounded()))% — resets \(Self.clock(window.resetsAt, now: now, calendar: calendar))"
        }
        return nil
    }

    /// The moment "Start anyway" lasts until: the latest reset of the windows that hold now; nil when none does.
    func overrideUntil(_ usage: PlanUsage?, now: Date = Date()) -> Date? {
        guard let usage else { return nil }
        let held = [(fiveHour, usage.fiveHour), (week, usage.week)].compactMap { limit, window -> Date? in
            guard let limit, let window, window.resetsAt > now, window.percent > Double(limit) else { return nil }
            return window.resetsAt
        }
        return held.max()
    }

    private static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        f.dateFormat = sameDay ? "HH:mm" : "EEE HH:mm"
        return (sameDay ? "at " : "") + f.string(from: date)
    }
}

extension PanelModel {
    /// The thresholds (Settings → Keep awake), kept in the app's defaults, not per project.
    var usageGate: UsageGate {
        get {
            access(keyPath: \.usageGate)
            return UsageGate(fiveHourStored: defaults.object(forKey: UsageGate.fiveHourKey) as? Int, weekStored: defaults.object(forKey: UsageGate.weekKey) as? Int)
        }
        set {
            withMutation(keyPath: \.usageGate) {
                defaults.set(UsageGate.encode(newValue.fiveHour), forKey: UsageGate.fiveHourKey)
                defaults.set(UsageGate.encode(newValue.week), forKey: UsageGate.weekKey)
            }
        }
    }

    /// "Start anyway" is on: the gate stays open until the window that held it resets.
    var usageGateOverridden: Bool {
        access(keyPath: \.usageGate)
        let until = defaults.double(forKey: UsageGate.overrideKey)
        return until > now().timeIntervalSince1970
    }

    /// Lifts the gate until the windows that hold it now reset; false when nothing holds it.
    @discardableResult
    func startAnyway() -> Bool {
        let usage = [planUsage, codexPlanUsage]
        let until = usage.compactMap { usageGate.overrideUntil($0, now: now()) }.max()
        withMutation(keyPath: \.usageGate) { defaults.set(until?.timeIntervalSince1970 ?? 0, forKey: UsageGate.overrideKey) }
        return until != nil
    }

    func stopStartAnyway() {
        withMutation(keyPath: \.usageGate) { defaults.removeObject(forKey: UsageGate.overrideKey) }
    }

    private func usageGateReason(_ usage: PlanUsage?) -> String? {
        usageGateOverridden ? nil : usageGate.reason(usage, now: now())
    }

    /// Why no card starts now (a plan window is above its threshold). Without a card it is Claude's reason, and only while no Codex
    /// role could still start (same rule as the safe point).
    var usageGateReason: String? {
        guard let reason = usageGateReason(planUsage) else { return nil }
        return anyRoleUsesCodex && usageGateReason(codexPlanUsage) == nil ? nil : reason
    }

    /// The same for a role: only the windows of the tool the role runs on hold it. A tool without usage data holds nothing.
    func usageGateReason(forRole role: String?) -> String? {
        guard let role else { return usageGateReason }
        return usageGateReason(tool(ofRole: role) == .codex ? codexPlanUsage : planUsage)
    }

    /// Why a card of this role cannot start because of the plan usage: the usage gate, then the safe point.
    func usageHold(forRole role: String?) -> String? { usageGateReason(forRole: role) ?? safePointReason(forRole: role) }
    var usageHold: String? { usageGateReason ?? safePointReason }
}
