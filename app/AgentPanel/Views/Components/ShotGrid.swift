import SwiftUI
import AppKit
import ImageIO

/// Loads an image no larger than `maxPixel` on its longest side, so a 12 MB screenshot is never decoded at full size
/// for a thumbnail. Returns nil for a file that is missing or not a readable image.
enum Thumbnail {
    static func load(_ url: URL, maxPixel: Int) -> NSImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { load($0, maxPixel: maxPixel) }
    }

    /// The same for image bytes (an image pasted into the chat).
    static func load(_ data: Data, maxPixel: Int) -> NSImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { load($0, maxPixel: maxPixel) }
    }

    /// The image's size in pixels, read from its header without decoding it.
    static func pixelSize(_ url: URL) -> CGSize? { CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(pixelSize) }
    static func pixelSize(_ data: Data) -> CGSize? { CGImageSourceCreateWithData(data as CFData, nil).flatMap(pixelSize) }

    private static func pixelSize(_ source: CGImageSource) -> CGSize? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : nil
    }

    private static func load(_ source: CGImageSource, maxPixel: Int) -> NSImage? {
        guard let size = pixelSize(source) else { return nil }
        let width = Int(size.width), height = Int(size.height)
        let cgImage: CGImage?
        if max(width, height) <= maxPixel {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

struct ShotItem: Identifiable, Equatable {
    let url: URL
    let exists: Bool
    var name: String { url.lastPathComponent }
    var id: String { url.path }

    static func items(for urls: [URL]) -> [ShotItem] {
        urls.map { ShotItem(url: $0, exists: FileManager.default.fileExists(atPath: $0.path)) }
    }

    /// The screenshots the card's latest review packet lists (paths relative to the data folder). A listed file that is
    /// missing, or whose path leaves the data folder, becomes a placeholder. When the packet lists none, the card's
    /// shots folder is shown instead.
    static func items(for card: TaskCard, dataDir: URL) -> [ShotItem] {
        let listed = packetSections(from: card.sections["Review packet"] ?? "").screenshots
        guard !listed.isEmpty else { return items(for: CardRepository(dataDir: dataDir).screenshots(for: card)) }
        let root = dataDir.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return listed.map { relative in
            let url = dataDir.appendingPathComponent(relative)
            let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let inside = !relative.hasPrefix("/") && parts.count > root.count && Array(parts.prefix(root.count)) == root
            return ShotItem(url: url, exists: inside && FileManager.default.fileExists(atPath: url.path))
        }
    }
}

/// Screenshots of a task. Images load lazily; a missing file shows a placeholder instead of an error. A click opens the image
/// viewer on the set of screenshots.
struct ShotGrid: View {
    let items: [ShotItem]
    @Environment(\.snapshotMode) private var snapshot
    @State private var viewing: ViewerSet?

    var body: some View {
        if items.isEmpty {
            Text("No screenshots yet").font(Tok.Font.body).foregroundStyle(Tok.ink3)
        } else {
            Scroller(axes: .horizontal) {
                row.padding(.vertical, Tok.Space.xs)
            }
            .frame(height: 440)
            .imageViewer($viewing)
        }
    }
}

extension ShotGrid {
    /// Thumbnails are created lazily while scrolling; a snapshot has no scrolling, so it builds them all.
    @ViewBuilder fileprivate var row: some View {
        if snapshot {
            HStack(alignment: .top, spacing: Tok.Space.l) { ForEach(items) { thumb($0) } }
        } else {
            LazyHStack(alignment: .top, spacing: Tok.Space.l) { ForEach(items) { thumb($0) } }
        }
    }

    fileprivate func thumb(_ item: ShotItem) -> some View {
        Thumb(item: item) { viewing = ViewerSet(shots: items, opening: item) }
    }
}

private struct Thumb: View {
    let item: ShotItem
    let onOpen: () -> Void
    static let maxPixel = 824   // twice the 412 pt height of the thumbnail, for Retina
    @State private var image: NSImage?
    @Environment(\.snapshotMode) private var immediate

    private var shown: NSImage? {
        image ?? (immediate && item.exists ? Thumbnail.load(item.url, maxPixel: Thumb.maxPixel) : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.xs + 2) {
            Group {
                if let shown {
                    Image(nsImage: shown).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Tok.raise)
                        .overlay { Text(item.exists ? "Loading…" : "File missing").font(Tok.Font.small).foregroundStyle(Tok.ink3) }
                }
            }
            .frame(width: 190, height: 412)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tok.line))
            .contentShape(Rectangle())
            .onTapGesture { if item.exists { onOpen() } }
            .help(item.exists ? "Open the screenshot" : "")
            Text(item.name).font(Tok.Font.small).foregroundStyle(Tok.ink2)
        }
        .task(id: item.id) {
            guard item.exists else { image = nil; return }
            let url = item.url
            image = await Task.detached { Thumbnail.load(url, maxPixel: Thumb.maxPixel) }.value
        }
        .accessibilityLabel("Screenshot \(item.name)")
    }
}
