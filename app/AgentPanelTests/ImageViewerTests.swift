import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

final class ImageViewerTests: XCTestCase {
    // A 2000x1000 image in a 1000x800 viewport: Fit is 0.5 (the width decides).
    private func zoom() -> ZoomState { ZoomState(imageSize: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 1000, height: 800)) }

    // MARK: zoom state

    func testOpensFitted() {
        let z = zoom()
        XCTAssertTrue(z.isFit)
        XCTAssertEqual(z.scale, 0.5)
        XCTAssertEqual(z.offset, .zero)
        XCTAssertEqual(z.percent, 50)
    }

    func testFitNeverEnlargesASmallImage() {
        let z = ZoomState(imageSize: CGSize(width: 200, height: 100), viewport: CGSize(width: 1000, height: 800))
        XCTAssertEqual(z.fitScale, 1)
        XCTAssertEqual(z.scale, 1)
    }

    func testFitFollowsTheViewportWhileFitted() {
        var z = zoom()
        z.viewport = CGSize(width: 500, height: 800)
        XCTAssertEqual(z.scale, 0.25)
        z.set(scale: 2)
        z.viewport = CGSize(width: 1000, height: 800)
        XCTAssertEqual(z.scale, 2, "a chosen zoom stays when the window changes")
    }

    func testZoomInAndOutStepThroughTheLevels() {
        var z = zoom()
        z.zoomIn()
        XCTAssertEqual(z.scale, 0.75)
        z.zoomIn()
        XCTAssertEqual(z.scale, 1)
        XCTAssertFalse(z.isFit)
        z.zoomOut()
        z.zoomOut()
        XCTAssertTrue(z.isFit, "zooming out to the fitted size snaps back to Fit")
        z.zoomOut()
        XCTAssertEqual(z.scale, 0.25)
        for _ in 0..<20 { z.zoomIn() }
        XCTAssertEqual(z.scale, ZoomState.maxScale)
        for _ in 0..<20 { z.zoomOut() }
        XCTAssertEqual(z.scale, ZoomState.minScale)
    }

    func testMenuLevels() {
        var z = zoom()
        z.set(scale: 2)
        XCTAssertEqual(z.percent, 200)
        z.fit()
        XCTAssertTrue(z.isFit)
        XCTAssertEqual(z.offset, .zero)
    }

    func testDoubleClickZoomsTo100AtThePointAndBackToFit() {
        var z = zoom()
        // 100 pt right of the centre shows image pixel 2000/2 + 100/0.5 = 1200; at 100% that pixel stays under the pointer.
        z.doubleClick(at: CGPoint(x: 600, y: 400))
        XCTAssertEqual(z.scale, 1)
        XCTAssertEqual(z.offset.width, -100, accuracy: 0.001)
        XCTAssertEqual(z.offset.height, 0, accuracy: 0.001)
        XCTAssertEqual(z.imagePoint(at: CGPoint(x: 600, y: 400)).x, 1200, accuracy: 0.001)
        z.doubleClick(at: CGPoint(x: 10, y: 10))
        XCTAssertTrue(z.isFit)
        XCTAssertEqual(z.offset, .zero)
    }

    func testPanStaysInsideTheImage() {
        var z = zoom()
        z.pan(by: CGSize(width: 300, height: 300))
        XCTAssertEqual(z.offset, .zero, "a fitted image does not move")
        z.set(scale: 1)   // 2000x1000 in 1000x800: 500 to each side, 100 up and down
        z.pan(by: CGSize(width: 300, height: 30))
        XCTAssertEqual(z.offset, CGSize(width: 300, height: 30))
        z.pan(by: CGSize(width: 900, height: -900))
        XCTAssertEqual(z.offset, CGSize(width: 500, height: -100))
    }

    func testPinchKeepsThePointUnderTheFingers() {
        var z = zoom()
        let anchor = CGPoint(x: 800, y: 300)
        let before = z.imagePoint(at: anchor)
        z.set(scale: 1.5, anchor: anchor)
        let after = z.imagePoint(at: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
        z.set(scale: 99)
        XCTAssertEqual(z.scale, ZoomState.maxScale)
    }

    // MARK: set navigation

    private func items(_ n: Int) -> [ViewerItem] {
        (1...n).map { ViewerItem(name: "shot\($0).png", source: .file(URL(fileURLWithPath: "/tmp/shot\($0).png"))) }
    }

    func testNavigatesThroughTheSetWithoutWrapping() {
        var set = ViewerSet(items: items(5), index: 1)
        XCTAssertEqual(set.position, "2 of 5")
        XCTAssertEqual(set.current.name, "shot2.png")
        set.previous()
        XCTAssertFalse(set.hasPrevious)
        set.previous()
        XCTAssertEqual(set.index, 0)
        for _ in 0..<10 { set.next() }
        XCTAssertEqual(set.position, "5 of 5")
        XCTAssertFalse(set.hasNext)
    }

    func testASingleImageShowsNoPosition() {
        let set = ViewerSet(items: items(1), index: 0)
        XCTAssertNil(set.position)
        XCTAssertFalse(set.hasNext)
        XCTAssertFalse(set.hasPrevious)
    }

    func testStartIndexIsClamped() {
        XCTAssertEqual(ViewerSet(items: items(3), index: 9).index, 2)
        XCTAssertEqual(ViewerSet(items: items(3), index: -1).index, 0)
    }

    func testScreenshotSetSkipsMissingFilesAndStartsOnTheClickedOne() throws {
        let shots = [ShotItem(url: URL(fileURLWithPath: "/a/1.png"), exists: true), ShotItem(url: URL(fileURLWithPath: "/a/2.png"), exists: false),
                     ShotItem(url: URL(fileURLWithPath: "/a/3.png"), exists: true)]
        let set = try XCTUnwrap(ViewerSet(shots: shots, opening: shots[2]))
        XCTAssertEqual(set.items.map(\.name), ["1.png", "3.png"])
        XCTAssertEqual(set.position, "2 of 2")
        XCTAssertNil(ViewerSet(shots: shots, opening: shots[1]), "a missing file does not open")
    }

    func testChatImagesBecomeASet() {
        let set = ViewerSet(images: [.file("/att/one.png"), .inline(Data([1, 2])), .file("/att/three.jpg")], index: 1)
        XCTAssertEqual(set.items.map(\.name), ["one.png", "Image 2", "three.jpg"])
        XCTAssertEqual(set.current.fileURL, nil, "an inline image has no file to show in Finder")
        XCTAssertEqual(set.items[0].fileURL?.path, "/att/one.png")
    }

    // MARK: sheet safety (N54)

    func testReturnTriggersNothing() {
        XCTAssertNil(ImageViewer.defaultButton)
    }

    // MARK: fitting the window (N109)

    func testSheetFitsInsideTheWindowWithAMargin() {
        XCTAssertEqual(ImageViewer.sheetSize(window: CGSize(width: 700, height: 600)), CGSize(width: 652, height: 552))
        XCTAssertEqual(ImageViewer.sheetSize(window: CGSize(width: 1440, height: 860)), CGSize(width: 1392, height: 812))
        let tiny = ImageViewer.sheetSize(window: CGSize(width: 300, height: 200))
        XCTAssertLessThanOrEqual(tiny.width, 300)
        XCTAssertLessThanOrEqual(tiny.height, 200)
    }

    func testWithoutAWindowTheSheetIsNotSizedToTheScreen() {
        let size = ImageViewer.sheetSize(window: nil)
        XCTAssertLessThanOrEqual(size.width, 1100 - 2 * Tok.Space.xl, "the panel window is at least 1100 pt wide")
        XCTAssertLessThanOrEqual(size.height, 600 - 2 * Tok.Space.xl)
    }

    func testToolbarLayoutsGoFromFullToMinimal() {
        XCTAssertEqual(ImageViewer.ToolbarLayout.allCases, [.full, .compact, .minimal])
        XCTAssertTrue(ImageViewer.ToolbarLayout.full.fileActionsInline)
        XCTAssertFalse(ImageViewer.ToolbarLayout.compact.fileActionsInline, "Open in Preview and Show in Finder move into the … menu")
        XCTAssertFalse(ImageViewer.ToolbarLayout.minimal.zoomButtonsInline, "zoom in and out move into the zoom menu")
    }

    @MainActor private func toolbarWidth(_ layout: ImageViewer.ToolbarLayout) -> CGFloat {
        let set = ViewerSet(items: items(5).map { ViewerItem(name: "a-rather-long-screenshot-name-\($0.name)", source: $0.source) }, index: 1)
        return NSHostingView(rootView: ImageViewer(set: set, onClose: {}).toolbar(layout)).fittingSize.width
    }

    @MainActor func testToolbarFitsAtANarrowAndAWideWindow() {
        let narrow = ImageViewer.sheetSize(window: CGSize(width: 700, height: 600)).width
        XCTAssertLessThanOrEqual(toolbarWidth(.compact), narrow, "at 700 pt every control but the file actions stays visible")
        XCTAssertGreaterThan(toolbarWidth(.full), narrow, "the full toolbar does not fit at 700 pt, so it is not chosen there")
        XCTAssertLessThan(toolbarWidth(.minimal), toolbarWidth(.compact), "a still narrower sheet keeps a toolbar that fits")
        XCTAssertLessThanOrEqual(toolbarWidth(.full), ImageViewer.sheetSize(window: CGSize(width: 1100, height: 600)).width)
    }

    // MARK: snapshot

    @MainActor func testSnapshotsAtANarrowAndAWideWindow() throws {
        let dir = try TempDir()
        let urls = try (1...5).map { i -> URL in
            let url = dir.url.appendingPathComponent("review-screenshot-\(i).png")
            try Self.screenshotPNG().write(to: url)
            return url
        }
        let set = ViewerSet(items: urls.map { ViewerItem(name: $0.lastPathComponent, source: .file($0)) }, index: 1)
        for (name, window) in [("image-viewer-700.png", CGSize(width: 700, height: 600)), ("image-viewer-wide.png", CGSize(width: 1440, height: 860))] {
            let data = try XCTUnwrap(SnapshotRenderer.render(view: ImageViewer(set: set, onClose: {}), size: ImageViewer.sheetSize(window: window)))
            XCTAssertGreaterThan(data.count, 8_000)
            if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] {
                try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
            }
        }
    }

    private static func screenshotPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1206, pixelsHigh: 2622, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.35, green: 0.63, blue: 0.94, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1206, height: 2622).fill()
        NSColor.white.setFill(); NSRect(x: 100, y: 1200, width: 1006, height: 300).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
