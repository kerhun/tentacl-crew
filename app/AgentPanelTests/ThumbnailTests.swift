import XCTest
import AppKit
@testable import AgentPanel

final class ThumbnailTests: XCTestCase {
    private func writePNG(_ dir: TempDir, name: String, width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = dir.url.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    /// A 1206x2622 screenshot must not stay a 12 MB bitmap for a 190 pt thumbnail.
    func testLargeImageIsDownsampled() throws {
        let dir = try TempDir()
        let url = try writePNG(dir, name: "big.png", width: 1206, height: 2622)
        let image = try XCTUnwrap(Thumbnail.load(url, maxPixel: 600))
        // `size` is in pixels here (the loader sets it from the decoded image); NSImage reps report Retina-scaled counts.
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 600)
        XCTAssertGreaterThan(max(image.size.width, image.size.height), 300)
    }

    func testSmallImageKeepsItsSize() throws {
        let dir = try TempDir()
        let url = try writePNG(dir, name: "small.png", width: 100, height: 200)
        let image = try XCTUnwrap(Thumbnail.load(url, maxPixel: 600))
        XCTAssertEqual(image.size.height, 200)
        XCTAssertEqual(image.size.width, 100)
    }

    func testPixelSizeIsReadWithoutDecoding() throws {
        let dir = try TempDir()
        let url = try writePNG(dir, name: "big.png", width: 1206, height: 2622)
        XCTAssertEqual(Thumbnail.pixelSize(url), CGSize(width: 1206, height: 2622))
        XCTAssertEqual(Thumbnail.pixelSize(Data(try Data(contentsOf: url))), CGSize(width: 1206, height: 2622))
        XCTAssertNil(Thumbnail.pixelSize(Data("not an image".utf8)))
    }

    func testImageBytesAreDownsampledToo() throws {
        let dir = try TempDir()
        let data = try Data(contentsOf: try writePNG(dir, name: "big.png", width: 1206, height: 2622))
        let image = try XCTUnwrap(Thumbnail.load(data, maxPixel: 600))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 600)
        XCTAssertNil(Thumbnail.load(Data("not an image".utf8), maxPixel: 600))
    }

    func testCorruptFileGivesNil() throws {
        let dir = try TempDir()
        let url = try dir.write("broken.png", "this is not a png")
        XCTAssertNil(Thumbnail.load(url, maxPixel: 600))
    }
}
