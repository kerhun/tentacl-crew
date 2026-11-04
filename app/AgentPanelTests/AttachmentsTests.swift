import XCTest
import AppKit
@testable import AgentPanel

final class AttachmentsTests: XCTestCase {
    private var dir: TempDir!
    private var store: Attachments!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = try TempDir()
        store = Attachments(root: dir.url.appendingPathComponent("attachments"))
    }

    private func png(_ side: Int = 8) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testPastedImageIsStoredAsPngInTheProjectFolder() throws {
        let image = try store.pending(pasted: png())
        let stored = try store.store([image], project: "demo", now: now)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].deletingLastPathComponent().path, dir.url.appendingPathComponent("attachments/demo").path)
        XCTAssertTrue(stored[0].lastPathComponent.hasSuffix(".png"))
        XCTAssertNotNil(NSImage(contentsOf: stored[0]))
    }

    func testPickedFileKeepsItsTypeAndNamesDiffer() throws {
        let jpg = try file("shot.JPG", png())
        let a = try store.pending(file: jpg), b = try store.pending(file: jpg)
        let stored = try store.store([a, b], project: "demo", now: now)
        XCTAssertTrue(stored.allSatisfy { $0.pathExtension == "jpg" })
        XCTAssertEqual(Set(stored.map(\.path)).count, 2)
    }

    func testMessageGetsOneImageLinePerImage() {
        let urls = [URL(fileURLWithPath: "/a/one.png"), URL(fileURLWithPath: "/a/two.png")]
        let root = URL(fileURLWithPath: "/a")
        XCTAssertEqual(Attachments.compose("look at this", paths: urls, root: root), "look at this\n[Image: /a/one.png]\n[Image: /a/two.png]")
        XCTAssertEqual(Attachments.compose("", paths: Array(urls.dropLast()), root: root), "[Image: /a/one.png]")
        XCTAssertEqual(Attachments.compose("plain", paths: []), "plain")
    }

    func testAnImageIsStillAnImageWithAThumbnail() throws {
        let image = try store.pending(file: file("shot.png", png()))
        XCTAssertEqual(image.kind, .image)
        XCTAssertNotNil(image.thumbnail)
        let stored = try store.store([image], project: "demo", now: now)
        XCTAssertEqual(Attachments.compose("", paths: stored, root: store.root), "[Image: \(stored[0].path)]")
    }

    func testAPdfAndAMarkdownFileAreCopiedUnderTheirOwnNames() throws {
        let pdf = try store.pending(file: file("notes.pdf", Data("%PDF-1.4".utf8)))
        let md = try store.pending(file: file("plan.md", Data("# Plan".utf8)))
        XCTAssertEqual([pdf.kind, md.kind], [.file, .file])
        XCTAssertNil(pdf.thumbnail)
        XCTAssertEqual(md.size, 6)
        let stored = try store.store([pdf, md], project: "demo", now: now)
        XCTAssertEqual(stored.map(\.lastPathComponent), ["notes.pdf", "plan.md"])
        XCTAssertTrue(stored.allSatisfy { $0.path.hasPrefix(store.root.appendingPathComponent("demo").path + "/") })
        XCTAssertEqual(try String(contentsOf: stored[1], encoding: .utf8), "# Plan")
        XCTAssertEqual(Attachments.compose("read these", paths: stored, root: store.root),
                       "read these\n[File: \(stored[0].path)]\n[File: \(stored[1].path)]")
        let shown = Attachments.split(stored, root: store.root)
        XCTAssertEqual(shown.files.map(\.copied), [true, true])
        XCTAssertTrue(shown.images.isEmpty)
    }

    func testAFolderIsLinkedNotCopied() throws {
        let folder = dir.url.appendingPathComponent("design")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = try store.pending(file: folder)
        XCTAssertEqual(item.kind, .linked)
        XCTAssertTrue(item.isFolder)
        let stored = try store.store([item], project: "demo", now: now)
        XCTAssertEqual(stored, [folder])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), "nothing copied")
        XCTAssertEqual(Attachments.compose("", paths: stored, root: store.root), "[Folder: \(folder.path)]")
        XCTAssertEqual(Attachments.split(stored, root: store.root).files, [ChatFile(path: folder.path, folder: true, copied: false)])
    }

    func testAFileOver10MBIsLinkedNotCopied() throws {
        let big = try file("dump.bin", Data(count: 20 * 1024 * 1024))
        let item = try store.pending(file: big)
        XCTAssertEqual(item.kind, .linked)
        XCTAssertEqual(item.size, 20 * 1024 * 1024)
        let stored = try store.store([item], project: "demo", now: now)
        XCTAssertEqual(stored, [big])
        XCTAssertEqual(Attachments.compose("look", paths: stored, root: store.root), "look\n[File: \(big.path)]")
        XCTAssertEqual(Attachments.split(stored, root: store.root).files.map(\.copied), [false])
    }

    func testABigImageIsLinkedAsAFile() throws {
        let item = try store.pending(file: file("huge.png", Data(count: Attachments.maxBytes + 1)))
        XCTAssertEqual(item.kind, .linked)
        XCTAssertEqual(Attachments.compose("", paths: try store.store([item], project: "demo", now: now), root: store.root),
                       "[File: \(dir.url.appendingPathComponent("huge.png").path)]")
    }

    func testAMissingFileOrUnreadableImageIsRefused() throws {
        XCTAssertThrowsError(try store.pending(file: dir.url.appendingPathComponent("gone.pdf"))) { XCTAssertEqual($0.localizedDescription, "gone.pdf could not be found.") }
        XCTAssertThrowsError(try store.pending(file: file("bad.png", Data("x".utf8)))) { XCTAssertEqual($0.localizedDescription, "bad.png could not be read as an image.") }
    }

    func testChipDetail() {
        XCTAssertEqual(Attachments.chipDetail(size: nil, folder: true, linked: true), "Folder · linked, not copied")
        XCTAssertEqual(Attachments.chipDetail(size: 20 * 1024 * 1024, folder: false, linked: true), Attachments.sizeText(20 * 1024 * 1024) + " · linked, not copied")
        XCTAssertEqual(Attachments.chipDetail(size: 2048, folder: false, linked: false), Attachments.sizeText(2048))
        XCTAssertEqual(Attachments.chipDetail(size: nil, folder: false, linked: false), "")
    }

    @MainActor func testPastedFileURLsAreAttachedLikeADrop() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("agent-panel-attach-paste-test"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let pdf = try file("paste.pdf", Data("%PDF".utf8))
        board.writeObjects([pdf as NSURL])
        XCTAssertTrue(Attachments.hasAttachment(board))
        XCTAssertEqual(try store.pending(from: board).map(\.kind), [.file])
        board.clearContents()
        board.setString("just text", forType: .string)
        XCTAssertFalse(Attachments.hasAttachment(board))
    }

    func testOldCopiedFilesAreRemovedOnPrune() throws {
        let doc = try store.store([store.pending(file: file("old.md", Data("x".utf8)))], project: "demo", now: now)[0]
        let box = doc.deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: box.path)
        store.prune(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.path))
    }

    func testFolderIsNeverCreatedWhenNothingIsStored() throws {
        _ = try? store.pending(file: file("a.txt", Data()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testOldAttachmentsAreRemovedOnPrune() throws {
        let fresh = try store.store([store.pending(pasted: png())], project: "demo", now: now)[0]
        let old = try store.store([store.pending(pasted: png())], project: "demo", now: now)[0]
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        let aged = now.addingTimeInterval(-31 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: aged], ofItemAtPath: old.path)
        store.prune(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testDefaultRootIsUnderApplicationSupportTentacl() {
        XCTAssertTrue(Attachments.defaultRoot.path.hasSuffix("Library/Application Support/Tentacl/attachments"))
    }

    func testCanSendWithOnlyImages() {
        XCTAssertTrue(canSend(text: "", target: "p1", busy: false, hasImages: true))
        XCTAssertFalse(canSend(text: "", target: "p1", busy: false))
    }
}
