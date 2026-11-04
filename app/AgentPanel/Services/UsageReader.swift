import Foundation

/// One rate-limit window of the Claude plan, as Claude Code reported it.
struct PlanUsage: Equatable {
    struct Window: Equatable {
        var percent: Double
        var resetsAt: Date
        /// The bar fill, 0...1.
        var fraction: Double { min(max(percent / 100, 0), 1) }
    }
    var fiveHour: Window?
    var week: Window?
    /// Dollars of the sessions seen today, as Claude Code counted them.
    var todayCost: Double
    /// When the session the windows come from last wrote (Codex only; nil for Claude).
    var seenAt: Date? = nil

    /// The session wrote within the last 5 hours.
    func seenRecently(now: Date = Date()) -> Bool {
        guard let seenAt else { return false }
        return now.timeIntervalSince(seenAt) < Self.fiveHourLength
    }

    static func resetText(_ date: Date, now: Date = Date()) -> String {
        "resets in \(Stats.durationText(max(date.timeIntervalSince(now), 0)))"
    }

    static let fiveHourLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 86400

    /// Where the window ends up at today's pace: the use so far divided by the share of the window that has passed (the window started
    /// `length` before its reset), capped at 100, with the moment it would reach 100. Nil without data or before any time has passed.
    static func forecast(_ window: Window?, length: TimeInterval, now: Date) -> LimitForecast? {
        guard let window else { return nil }
        let start = window.resetsAt.addingTimeInterval(-length)
        let elapsed = min(now.timeIntervalSince(start), length)
        guard elapsed > 0 else { return nil }
        let projected = window.percent / (elapsed / length)
        guard projected > 100, window.percent > 0 else { return LimitForecast(percentAtReset: projected, reachesLimitAt: nil) }
        return LimitForecast(percentAtReset: 100, reachesLimitAt: start.addingTimeInterval(elapsed * 100 / window.percent))
    }

    static func forecastText(_ f: LimitForecast, now: Date = Date(), calendar: Calendar = .current) -> String {
        if let at = f.reachesLimitAt { return "At this pace: reaches the limit around \(clock(at, now: now, calendar: calendar))" }
        return "At this pace: about \(Int(f.percentAtReset.rounded()))% at reset"
    }

    /// "Resets at 18:00 (in 1 h 40 min)"; another day: "Resets Thu 09:00 (in 2 d 17 h)".
    static func resetLine(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = clock(date, now: now, calendar: calendar)
        return "Resets \(calendar.isDate(date, inSameDayAs: now) ? "at " : "")\(when) (in \(Stats.durationText(max(date.timeIntervalSince(now), 0))))"
    }

    /// "18:00" today, "Thu 09:00" on another day.
    private static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}

/// A plan window at today's pace (`PlanUsage.forecast`).
struct LimitForecast: Equatable {
    /// Percent at the reset, at most 100.
    let percentAtReset: Double
    /// When it would reach 100 before the reset; nil when it would not.
    let reachesLimitAt: Date?
}

/// Reads the files `scripts/usage-statusline.sh` leaves for each session. Read-only; asks no server.
enum UsageReader {
    /// Keep in step with USAGE in scripts/usage-statusline.sh.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tentacl/usage")
    }

    /// The newest file that still has a window that has not reset; nil when there is none.
    static func read(root: URL = defaultRoot, now: Date = Date(), calendar: Calendar = .current) -> PlanUsage? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let startOfDay = calendar.startOfDay(for: now)
        var sessions: [(seen: Date, five: PlanUsage.Window?, week: PlanUsage.Window?)] = []
        var today = 0.0
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seenAt = obj["seen_at"] as? Double else { continue }
            let seen = Date(timeIntervalSince1970: seenAt)
            if seen >= startOfDay { today += (obj["cost"] as? [String: Any])?["total_cost_usd"] as? Double ?? 0 }
            let limits = obj["rate_limits"] as? [String: Any]
            func window(_ key: String) -> PlanUsage.Window? {
                guard let w = limits?[key] as? [String: Any], let p = w["used_percentage"] as? Double, let r = w["resets_at"] as? Double,
                      Date(timeIntervalSince1970: r) > now else { return nil }
                return PlanUsage.Window(percent: p, resetsAt: Date(timeIntervalSince1970: r))
            }
            sessions.append((seen, window("five_hour"), window("seven_day")))
        }
        guard let best = sessions.filter({ $0.five != nil || $0.week != nil }).max(by: { $0.seen < $1.seen }) else { return nil }
        return PlanUsage(fiveHour: best.five, week: best.week, todayCost: today)
    }

    /// The plan windows of the newest Codex session file that has a window that has not reset (`rate_limits` of its last `token_count`).
    /// Only the 20 newest files are looked at. Codex reports no dollars, so `todayCost` is 0; `seenAt` is the file's change time.
    static func readCodex(root: URL = CodexSessionReader.defaultRoot, now: Date = Date()) -> PlanUsage? {
        for file in CodexSessionReader.rollouts(root: root).prefix(20) {
            guard let usage = CodexSessionReader.usage(file.url) else { continue }
            let five = usage.fiveHour.flatMap { $0.resetsAt > now ? $0 : nil }, week = usage.week.flatMap { $0.resetsAt > now ? $0 : nil }
            if five != nil || week != nil { return PlanUsage(fiveHour: five, week: week, todayCost: 0, seenAt: file.modified) }
        }
        return nil
    }

    /// The plan usage of the agent's tool.
    static func read(tool: AgentTool, now: Date = Date(), calendar: Calendar = .current) -> PlanUsage? {
        tool == .codex ? readCodex(now: now) : read(now: now, calendar: calendar)
    }
}

/// The user's "Safe point": a share of the 5-hour plan window at which no new card starts, so running work can end before the limit.
struct SafePoint: Equatable {
    static let range = 80...95
    static let defaultPercent = 90
    static let key = "safePointPercent"
    /// The stored value for "off".
    static let offValue = 0

    /// Nil: off.
    var percent: Int?

    init(percent: Int?) { self.percent = percent.map { min(max($0, Self.range.lowerBound), Self.range.upperBound) } }

    /// A stored value: unset is the default, `offValue` is off, anything else is clamped into the range.
    init(stored: Int?) {
        switch stored {
        case nil: self.init(percent: Self.defaultPercent)
        case Self.offValue?: self.init(percent: nil)
        case let value?: self.init(percent: value)
        }
    }

    var stored: Int { percent ?? Self.offValue }

    /// The 5-hour window is at or above the safe point.
    func reached(_ usage: PlanUsage?) -> Bool {
        guard let percent, let five = usage?.fiveHour else { return false }
        return five.percent >= Double(percent)
    }

    /// "Safe point reached: 91% of the 5-hour limit used, resets at 18:00"; nil while it is not reached.
    func reason(_ usage: PlanUsage?, limit: String = "5-hour limit", now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard reached(usage), let five = usage?.fiveHour else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(five.resetsAt, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return "Safe point reached: \(Int(five.percent.rounded()))% of the \(limit) used, resets at \(f.string(from: five.resetsAt))."
    }

    /// What the PM is told when it plans: the safe point and where the 5-hour window stands (both tools' windows when Codex is in use).
    func promptLine(_ usage: PlanUsage?, codex: PlanUsage? = nil) -> String? {
        guard let percent else { return nil }
        var line = "Safe point: \(percent)% of the 5-hour plan limit. No card should be running when it is reached, so work that stops midway has to be resumed at a high cost."
        func share(_ u: PlanUsage?) -> String { u?.fiveHour.map { "\(Int($0.percent.rounded()))%" } ?? "unknown" }
        if codex != nil {
            line += " Used now: Claude \(share(usage)), Codex \(share(codex)). Each card waits on the limit of its own tool."
        } else { line += " Used now: \(share(usage))." }
        return line
    }
}
