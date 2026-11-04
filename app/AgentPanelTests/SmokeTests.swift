import XCTest
import AppKit

final class SmokeTests: XCTestCase {
    // The test host is the Debug build: "Tentacl Dev" with its own id, so it is not a second "Tentacl" in Spotlight. Release keeps "Tentacl".
    func testBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.kerhun.Tentacl.dev")
    }

    func testDebugBuildIsCalledTentaclDev() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Tentacl Crew Dev")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Tentacl Crew Dev")
        XCTAssertTrue(Bundle.main.bundleURL.lastPathComponent == "Tentacl Dev.app", Bundle.main.bundleURL.lastPathComponent)
    }

    func testReleaseKeepsTheStableNameAndId() throws {
        let project = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.kerhun.Tentacl\n"))
        XCTAssertTrue(project.contains("PRODUCT_NAME: Tentacl\n"))
        XCTAssertFalse(project.contains("Release:\n          PRODUCT_NAME"))
    }

    func testAppIconIsBundled() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        let icon = NSImage(named: "AppIcon")
        XCTAssertNotNil(icon, "the AppIcon asset must be in the app bundle")
        // The catalog carries the full macOS size range up to 1024 px (512 pt @2x).
        let widest = icon?.representations.map(\.pixelsWide).max() ?? 0
        XCTAssertGreaterThanOrEqual(widest, 512, "widest icon representation: \(widest) px")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Assets.car").path))
    }

    func testWordmarkIsBundledAndUsedInTheTopBar() throws {
        let wordmark = try XCTUnwrap(NSImage(named: "Wordmark"), "the Wordmark asset must be in the app bundle")
        XCTAssertGreaterThanOrEqual(wordmark.representations.map(\.pixelsWide).max() ?? 0, 700)
        // The window is always dark, so the bundled wordmark has light letters in every appearance (a dark-letter variant vanishes on it).
        guard let cg = wordmark.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return XCTFail("cannot read the wordmark pixels") }
        var sum = 0.0, n = 0.0
        for i in stride(from: 0, to: CFDataGetLength(data) - 3, by: 4) where bytes[i + 3] > 200 { sum += Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2]); n += 3 }
        XCTAssertGreaterThan(n, 0)
        XCTAssertGreaterThan(sum / n, 200, "mean letter brightness")
    }

    func testTheTopBarShowsTheWordmarkNotPlainText() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPanel/Views/ShellView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Image(\"Wordmark\")"))
        XCTAssertFalse(source.contains("Text(\"Tentacl\")"))
    }
}
