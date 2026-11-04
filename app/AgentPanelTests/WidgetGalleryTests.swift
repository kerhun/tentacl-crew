import XCTest
import SwiftUI
import AppKit
@testable import AgentPanel

/// N354: a gallery card's button. Only an Add with room is the blue confirm button; Added and Add with the grid full are the plain
/// disabled (neutral grey) button.
@MainActor
final class WidgetGalleryTests: XCTestCase {
    func testOnlyAddWithRoomIsTheConfirmButton() {
        XCTAssertEqual(WidgetGallery.button(added: false, room: true), .add)
        XCTAssertEqual(WidgetGallery.button(added: false, room: false), .noRoom, "grid full: plain disabled Add, not faded blue")
        XCTAssertEqual(WidgetGallery.button(added: true, room: true), .added)
        XCTAssertEqual(WidgetGallery.button(added: true, room: false), .added, "an added widget says Added even when the grid is full")
    }

    /// Full grid: chat 4×4, Waiting and Agents fill the rest, five widgets left to add.
    static var full: DashboardGridLayout {
        DashboardGridLayout([DashboardGridTests.t(.chat, 0, 0, 4, 4), DashboardGridTests.t(.waiting, 4, 0, 2, 2), DashboardGridTests.t(.agents, 4, 2, 2, 2)])
    }
    /// Room left: the same minus Agents.
    static var roomy: DashboardGridLayout {
        DashboardGridLayout([DashboardGridTests.t(.chat, 0, 0, 4, 4), DashboardGridTests.t(.waiting, 4, 0, 2, 2)])
    }

    func testTheLayoutsUsedForTheShots() {
        XCTAssertFalse(Self.full.hasRoom)
        XCTAssertTrue(Self.roomy.hasRoom)
    }

    /// Live-window shots (an on-screen NSHostingView, not ImageRenderer), dark and light, grid full and with room.
    func testTheLiveGalleryShots() async throws {
        for (layout, name) in [(Self.full, "full"), (Self.roomy, "room")] {
            for dark in [true, false] {
                let data = try await liveShot(WidgetGallery(layout: layout, onAdd: { _ in }, onClose: {}), dark: dark)
                XCTAssertGreaterThan(data.count, 10_000)
                if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("N354-gallery-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    private func liveShot(_ gallery: WidgetGallery, dark: Bool) async throws -> Data {
        let scheme: ColorScheme = dark ? .dark : .light
        let theme = AppTheme.current
        AppTheme.current = dark ? .dark : .light
        defer { AppTheme.current = theme }
        let root = gallery.padding(30).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WidgetGallery.width + 60, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
