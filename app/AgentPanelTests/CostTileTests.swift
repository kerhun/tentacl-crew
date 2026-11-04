import XCTest
import SwiftUI
@testable import AgentPanel

final class CostTileTests: XCTestCase {
    private var calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 15))!
    private func day(_ back: Int, hour: Int = 0) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!)!
    }

    func testWeekIsSevenDaysOldestFirstTodayLastMissingDaysZero() {
        let days = [DayCost(day: day(6), dollars: 1), DayCost(day: day(3, hour: 10), dollars: 2.5), DayCost(day: day(0), dollars: 4)]
        XCTAssertEqual(CostTile.week(days, calendar: calendar, now: now), [1, 0, 0, 2.5, 0, 0, 4])
    }

    func testWeekDropsOlderDaysAndAddsSameDay() {
        let days = [DayCost(day: day(7), dollars: 9), DayCost(day: day(13), dollars: 9), DayCost(day: day(1), dollars: 1), DayCost(day: day(1, hour: 5), dollars: 2)]
        XCTAssertEqual(CostTile.week(days, calendar: calendar, now: now), [0, 0, 0, 0, 0, 3, 0])
    }

    func testTodaysAmountIsTheLastPoint() {
        let days = [DayCost(day: day(0), dollars: 1)]
        XCTAssertEqual(CostTile.week(days, today: 1.75, calendar: calendar, now: now).last, 1.75)
        XCTAssertEqual(CostTile.week([], today: nil, calendar: calendar, now: now), Array(repeating: 0, count: 7))
    }

    // N361: the big amount is this project's today cost and equals the line's last point; the plan-wide total is only a labelled line.
    func testNoLimitBigAmountIsProjectCostNotPlanWide() {
        let days = [DayCost(day: day(1), dollars: 2), DayCost(day: day(0), dollars: 0.5)]
        let today = CostTile.projectToday(read: 1.25, autopilot: nil)   // no daily limit: the autopilot never reads
        let week = CostTile.week(days, today: today, calendar: calendar, now: now)
        XCTAssertEqual(today, 1.25)
        XCTAssertEqual(week.last, today)
        XCTAssertEqual(CostTile.subtitle(today: today, limit: nil, reached: false), "today")
        XCTAssertEqual(CostTile.allProjectsText(today: today, allProjects: 42.4), "all projects ≈ $42.40 today")
    }

    func testWithLimitBigAmountIsProjectCostAndLimitTextUnchanged() {
        let today = CostTile.projectToday(read: 3, autopilot: 2.9)
        let week = CostTile.week([], today: today, calendar: calendar, now: now)
        XCTAssertEqual(today, 3)
        XCTAssertEqual(week.last, today)
        XCTAssertEqual(CostTile.subtitle(today: today, limit: 5, reached: false), "today · limit $5.00")
        XCTAssertEqual(CostTile.subtitle(today: today, limit: 2, reached: true), "Daily limit reached: questions come to you")
        // Before the week's read lands, the autopilot's read of the same project number is used.
        XCTAssertEqual(CostTile.projectToday(read: nil, autopilot: 2.9), 2.9)
    }

    func testUnknownProjectCostIsNotReadYetEvenWithPlanWideTotal() {
        let today = CostTile.projectToday(read: nil, autopilot: nil)
        XCTAssertNil(today)
        XCTAssertEqual(CostTile.subtitle(today: today, limit: nil, reached: false), "Not read yet today")
        XCTAssertEqual(CostTile.allProjectsText(today: today, allProjects: 7), "all projects ≈ $7.00 today")
    }

    // F1: without a limit the autopilot never reads, so the plan-wide total moving must still trigger a new read; plus a minute tick.
    func testRefreshKeyMovesWithThePlanWideTotalWithoutALimit() {
        let before = CostTile.refreshKey(project: "p", cards: 3, autopilot: nil, allProjects: 10)
        XCTAssertNotEqual(before, CostTile.refreshKey(project: "p", cards: 3, autopilot: nil, allProjects: 10.5))
        XCTAssertNotEqual(before, CostTile.refreshKey(project: "p", cards: 3, autopilot: 1, allProjects: 10))
        XCTAssertNotEqual(before, CostTile.refreshKey(project: "q", cards: 3, autopilot: nil, allProjects: 10))
        XCTAssertNotEqual(before, CostTile.refreshKey(project: "p", cards: 4, autopilot: nil, allProjects: 10))
        XCTAssertEqual(before, CostTile.refreshKey(project: "p", cards: 3, autopilot: nil, allProjects: 10))
        XCTAssertLessThanOrEqual(CostTile.refreshSeconds, 60)
    }

    // F2: after a project switch the previous project's read is not shown; the autopilot's value (or "–") is, until the new read lands.
    func testAnotherProjectsReadIsDroppedOnSwitch() {
        let read = CostTile.Read(project: "a", days: [DayCost(day: day(0), dollars: 9)], today: 9)
        XCTAssertEqual(CostTile.Read.of(read, project: "a"), read)
        XCTAssertNil(CostTile.Read.of(read, project: "b"))
        XCTAssertNil(CostTile.projectToday(read: CostTile.Read.of(read, project: "b")?.today, autopilot: nil))
        XCTAssertEqual(CostTile.projectToday(read: CostTile.Read.of(read, project: "b")?.today, autopilot: 0.4), 0.4)
    }

    func testAllProjectsLineHiddenWhenUnknownZeroOrSame() {
        XCTAssertNil(CostTile.allProjectsText(today: 1, allProjects: nil))
        XCTAssertNil(CostTile.allProjectsText(today: 0, allProjects: 0))
        XCTAssertNil(CostTile.allProjectsText(today: 1.004, allProjects: 1.0))
    }

    /// Live-window shot → N361-cost.png: no limit, project $1.25 today (the line's last point), plan-wide $42.40 as the second line;
    /// beside it the same tile with a limit, light and dark.
    @MainActor func testTheLiveCostShot() async throws {
        let days = [DayCost(day: day(5), dollars: 0.8), DayCost(day: day(3), dollars: 2.1), DayCost(day: day(1), dollars: 1.6)]
        let week = CostTile.week(days, today: 1.25, calendar: calendar, now: now)
        let tiles = VStack(spacing: 16) {
            CostTile(today: 1.25, limit: nil, limitReached: false, week: week, allProjects: 42.4)
            CostTile(today: 1.25, limit: 5, limitReached: false, week: week, allProjects: 42.4)
            CostTile(today: nil, limit: nil, limitReached: false, week: nil, allProjects: 42.4)
        }
        .padding(20).frame(width: 480)
        let shots = try [true, false].map { dark -> NSImage in
            let theme = AppTheme.current
            AppTheme.current = dark ? .dark : .light
            defer { AppTheme.current = theme }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView: tiles.background(Tok.bg).environment(\.colorScheme, dark ? .dark : .light))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
            return image
        }
        let size = shots[0].size, both = NSImage(size: NSSize(width: size.width * 2, height: size.height))
        both.lockFocus(); shots[0].draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        shots[1].draw(at: NSPoint(x: size.width, y: 0), from: .zero, operation: .copy, fraction: 1); both.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(both.tiffRepresentation))?.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 10_000)
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N361-cost.png")) }
    }

    func testWeekText() {
        XCTAssertEqual(CostTile.weekText([1, 0, 0, 2.5, 0, 0, 4]), "Last 7 days: $7.50 total")
    }

    func testSparkPointsSpanTheWidthAndPeakAtTop() {
        let pts = CostSparkline.points([0, 2, 1], in: CGSize(width: 106, height: 26), inset: 3)
        XCTAssertEqual(pts.map(\.x), [3, 53, 103])
        XCTAssertEqual(pts.map(\.y), [23, 3, 13])
        XCTAssertEqual(CostSparkline.points([0, 0], in: CGSize(width: 10, height: 10), inset: 0).map(\.y), [10, 10])
    }
}
