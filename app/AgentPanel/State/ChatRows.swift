import Foundation

/// A panel note in a `.system` row; `acked` when the PM answered it with a bare ✓.
struct PanelEvent: Equatable, Identifiable {
    let entry: ChatEntry
    var acked = false
    var id: String { entry.id }
}

/// One row of the chat thread: the entries grouped for display (day and gap dividers, stacked panel notes with their ✓ folded in).
enum ChatRow: Equatable, Identifiable {
    case day(Date)
    case gap(TimeInterval)
    case system([PanelEvent])
    case user(ChatEntry)
    case turn(ChatEntry)
    case tools(ChatEntry)
    case summary(ChatEntry)

    /// Stable while a turn grows or a system row gets another event; dividers are keyed by their value.
    var id: String {
        switch self {
        case .day(let d): "day-\(d.timeIntervalSinceReferenceDate)"
        case .gap(let t): "gap-\(t)"
        case .system(let events): "system-\(events[0].id)"
        case .user(let e), .turn(let e), .tools(let e), .summary(let e): "\(e.id)"
        }
    }
}

enum ChatRows {
    static let gapAfter: TimeInterval = 3600

    /// `previous` are the entries of the earlier conversation (shown above the new one); they get rows too, so a day divider is not repeated.
    static func build(entries: [ChatEntry], previous: [ChatEntry] = [], now: Date = Date(), calendar: Calendar = .current) -> [ChatRow] {
        var rows: [ChatRow] = []
        var lastTime: Date?
        var panelRun = false      // the last row is a `.system` row still taking events
        var afterPanel = false    // the last kept entry was a panel note (a ✓ or tool stretch may follow)
        for entry in previous + entries {
            if afterPanel, entry.kind == .tools, entry.pending == nil { continue }
            if afterPanel, entry.kind == .agent, isAck(entry.text), case .system(var events)? = rows.last {
                events[events.count - 1].acked = true
                rows[rows.count - 1] = .system(events)
                continue
            }
            if let time = entry.time {
                if let last = lastTime {
                    if !calendar.isDate(last, inSameDayAs: time) { rows.append(.day(calendar.startOfDay(for: time))); panelRun = false }
                    else if time.timeIntervalSince(last) > gapAfter { rows.append(.gap(time.timeIntervalSince(last))); panelRun = false }
                } else { rows.append(.day(calendar.startOfDay(for: time))) }
                lastTime = time
            }
            afterPanel = false
            switch entry.kind {
            case .panel:
                let event = PanelEvent(entry: entry)
                // A note that needs action keeps its own row (Retry/Remove) and takes no neighbours.
                let stuck = entry.pending.map(ChatThread.needsAction) == true
                if panelRun, !stuck, case .system(var events)? = rows.last {
                    events.append(event); rows[rows.count - 1] = .system(events)
                } else { rows.append(.system([event])) }
                panelRun = !stuck
                afterPanel = !stuck
            case .user: rows.append(.user(entry)); panelRun = false
            case .agent: rows.append(.turn(entry)); panelRun = false
            case .tools: rows.append(.tools(entry)); panelRun = false
            case .summary: rows.append(.summary(entry)); panelRun = false
            }
        }
        return rows
    }

    private static func isAck(_ text: String) -> Bool { ["✓", "✓."].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
