import SwiftUI
import XCTest
@testable import AgentPanel

/// N328: Start PM / Resume PM off say why, in a line under the PM bar and as the buttons' help.
@MainActor final class PMStartBlockTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var keep: [TempDir] = []

    func testTheLineForUsageHoldSetupReasonAndNone() {
        XCTAssertEqual(PMStartBlock.make(setupReason: nil, gateReason: "Week usage 98% — resets Sat 10:00", safePointReason: nil, busy: false),
                       PMStartBlock(text: "Starting is paused: week usage 98% — resets Sat 10:00.", offersStartAnyway: true))
        XCTAssertEqual(PMStartBlock.make(setupReason: "The location of project.json is unknown.", gateReason: "Week usage 98% — resets Sat 10:00", safePointReason: nil, busy: false),
                       PMStartBlock(text: "The location of project.json is unknown."), "the setup reason comes first, without Start anyway")
        XCTAssertEqual(PMStartBlock.make(setupReason: nil, gateReason: nil, safePointReason: "Safe point reached: 95% of the 5-hour limit used, resets at 14:20.", busy: false),
                       PMStartBlock(text: "Safe point reached: 95% of the 5-hour limit used, resets at 14:20."), "Start anyway does not lift the safe point")
        XCTAssertNil(PMStartBlock.make(setupReason: nil, gateReason: nil, safePointReason: nil, busy: false))
        XCTAssertNil(PMStartBlock.make(setupReason: nil, gateReason: "Week usage 98% — resets Sat 10:00", safePointReason: nil, busy: true), "busy adds nothing new")
    }

    func testTheModelsWeekHoldGivesTheLineAndStartAnywayClearsIt() async throws {
        let m = try await model(week: 98)
        m.safePoint = SafePoint(percent: nil)
        let block = try XCTUnwrap(block(m))
        XCTAssertTrue(block.text.hasPrefix("Starting is paused: week usage 98% — resets "))
        XCTAssertTrue(block.offersStartAnyway)
        XCTAssertFalse(m.canStart)
        XCTAssertTrue(m.startAnyway())
        XCTAssertNil(self.block(m))
        XCTAssertTrue(m.canStart)
    }

    /// The Dashboard's PM bar with the usage-hold line (set AGENT_PANEL_SNAPSHOT_DIR to save it).
    func testSnapshotOfTheDashboardWithTheUsageHold() async throws {
        let m = try await model(week: 98)
        m.safePoint = SafePoint(percent: nil)
        XCTAssertEqual(m.pmStatus, .missing)
        for (name, scheme) in [("", ColorScheme.light), ("-dark", ColorScheme.dark)] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: DashboardView(model: m).environment(\.colorScheme, scheme), size: CGSize(width: 1440, height: 900)))
            XCTAssertGreaterThan(data.count, 20_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N328-dashboard-usage-hold\(name).png")) }
        }
    }

    private func block(_ m: PanelModel) -> PMStartBlock? {
        PMStartBlock.make(setupReason: m.startSetupReason, gateReason: m.usageGateReason, safePointReason: m.safePointReason, busy: m.isBusy)
    }

    private func model(week: Double) async throws -> PanelModel {
        let dir = try TempDir()
        for n in ScriptName.allCases { try dir.write("scripts/\(n.rawValue)", "#!/bin/bash\n") }
        let source = try dir.write("p/project.json", "{\"id\":\"demo\",\"name\":\"Demo\",\"repoPath\":\"/repo\",\"dataDir\":\"\(dir.url.appendingPathComponent("data").path)\",\"maxParallel\":2,\"buildCommand\":\"b\",\"simulator\":{\"baseDevice\":\"x\"},\"sharedFiles\":[],\"openWith\":\"Xcode\"}")
        let settings = try dir.write("settings.json", "{\"projects\":[\"\(source.path)\"],\"scriptsDir\":\"\(dir.url.appendingPathComponent("scripts").path)\"}")
        let iso = TestIsolation(dir, owner: self)
        let m = PanelModel(settingsURL: settings, makeTerminal: { FakeTerminal(agentsResult: .success([])) }, opener: RecordingOpener(), log: iso.log, defaults: iso.defaults, roleStore: iso.roleStore)
        let usage = PlanUsage(fiveHour: PlanUsage.Window(percent: 10, resetsAt: now.addingTimeInterval(3600)), week: PlanUsage.Window(percent: week, resetsAt: now.addingTimeInterval(3 * 86_400)), todayCost: 0)
        m.now = { [now] in now }
        m.usageSource = { usage }
        await m.reload()
        await m.refreshAgents()
        for _ in 0..<200 where m.planUsage != usage { try await Task.sleep(for: .milliseconds(5)) }
        keep.append(dir)
        return m
    }
}
