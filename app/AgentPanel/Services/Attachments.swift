import Foundation
import AppKit

/// An image, file or folder the user added to the Command box and has not sent yet.
struct PendingImage: Identifiable {
    enum Source { case pasted(Data), file(URL) }
    /// `image` and `file` are copied when sent; `linked` (a folder, or a file over 10 MB) is sent by its own path.
    enum Kind: Equatable { case image, file, linked }
    let id = UUID()
    let source: Source
    let thumbnail: NSImage?
    var kind: Kind = .image
    var size: Int? = nil
    var isFolder = false

    var name: String { if case .file(let url) = source { url.lastPathComponent } else { "Pasted image" } }
}

/// Attachments sent from the Command box. The panel keeps its own copy of images and files up to 10 MB in `<root>/<project id>/`
/// and names the path in the message (`[Image: path]`, `[File: path]`), which the agent reads; folders and bigger files are named
/// by their own path (`[Folder: path]`, `[File: path]`). Nothing is written into a project or a worktree.
struct Attachments {
    struct Refusal: LocalizedError {
        let errorDescription: String?
    }

    static let maxBytes = 10 * 1024 * 1024
    static let maxAgeDays = 30
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif"]

    /// Keep in step with `ATTACHMENTS` in scripts/spawn-agent.sh.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tentacl/attachments")
    }

    let root: URL
    init(root: URL = Attachments.defaultRoot) { self.root = root }

    /// A pasted image (any format AppKit reads), to be stored as PNG.
    func pending(pasted data: Data) throws -> PendingImage {
        guard let image = NSImage(data: data), let png = Self.pngData(image) else { throw Refusal(errorDescription: "The pasted image could not be read.") }
        guard png.count <= Self.maxBytes else { throw Refusal(errorDescription: "The pasted image is larger than 10 MB.") }
        return PendingImage(source: .pasted(png), thumbnail: image)
    }

    /// A picked, dropped or pasted file or folder: an image (≤ 10 MB) gets a thumbnail, any other file ≤ 10 MB is copied when sent,
    /// a folder or a bigger file is linked. Refused only when it is gone or is an image that cannot be read.
    func pending(file url: URL) throws -> PendingImage {
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw Refusal(errorDescription: "\(name) could not be found.") }
        if isDir.boolValue { return PendingImage(source: .file(url), thumbnail: nil, kind: .linked, isFolder: true) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else { return PendingImage(source: .file(url), thumbnail: nil, kind: .linked, size: size) }
        guard Self.extensions.contains(url.pathExtension.lowercased()) else { return PendingImage(source: .file(url), thumbnail: nil, kind: .file, size: size) }
        guard let image = NSImage(contentsOf: url) else { throw Refusal(errorDescription: "\(name) could not be read as an image.") }
        return PendingImage(source: .file(url), thumbnail: image, size: size)
    }

    /// Copies images to `<root>/<project>/<date>-<random>.<ext>` and files to `<root>/<project>/<date>-<random>/<name>`; a linked
    /// item keeps its own path. Returns the paths in order.
    func store(_ images: [PendingImage], project: String, now: Date = Date()) throws -> [URL] {
        let folder = root.appendingPathComponent(Self.safe(project), isDirectory: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = f.string(from: now)
        return try images.map { image in
            if image.kind == .linked, case .file(let url) = image.source { return url }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if image.kind == .file, case .file(let url) = image.source {
                let box = folder.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6).lowercased())", isDirectory: true)
                try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
                let target = box.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: target)
                return target
            }
            let ext: String
            if case .file(let url) = image.source { ext = url.pathExtension.lowercased() == "jpeg" ? "jpg" : url.pathExtension.lowercased() } else { ext = "png" }
            let target = folder.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6).lowercased()).\(ext)")
            switch image.source {
            case .pasted(let data): try data.write(to: target)
            case .file(let url): try FileManager.default.copyItem(at: url, to: target)
            }
            return target
        }
    }

    /// The message text followed by one line per path: `[Image: path]` for an image in the panel's folder, `[Folder: path]` for a
    /// folder, `[File: path]` for anything else.
    static func compose(_ text: String, paths: [URL], root: URL = Attachments.defaultRoot) -> String {
        let lines = paths.map { url -> String in
            switch kind(of: url, root: root) {
            case .image: "[Image: \(url.path)]"
            case .folder: "[Folder: \(url.path)]"
            case .file: "[File: \(url.path)]"
            }
        }
        return ([text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty } + lines).joined(separator: "\n")
    }

    enum LineKind { case image, file, folder }

    /// How a sent path is named in the message and shown in the thread.
    static func kind(of url: URL, root: URL = Attachments.defaultRoot) -> LineKind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .folder }
        return isInside(url.path, root: root) && extensions.contains(url.pathExtension.lowercased()) ? .image : .file
    }

    static func isInside(_ path: String, root: URL) -> Bool {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) && !path.contains("/../")
    }

    /// The thread's view of sent paths: thumbnails for the images, chips for the files and folders.
    static func split(_ paths: [URL], root: URL = Attachments.defaultRoot) -> (images: [ChatImage], files: [ChatFile]) {
        var images: [ChatImage] = [], files: [ChatFile] = []
        for url in paths {
            switch kind(of: url, root: root) {
            case .image: images.append(.file(url.path))
            case .folder: files.append(ChatFile(path: url.path, folder: true, copied: false))
            case .file: files.append(ChatFile(path: url.path, folder: false, copied: isInside(url.path, root: root)))
            }
        }
        return (images, files)
    }

    /// "1.2 MB", or "12 KB".
    static func sizeText(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    /// The chip's second line: the size, and for a folder or a big file that it was linked, not copied.
    static func chipDetail(size: Int?, folder: Bool, linked: Bool) -> String {
        let first = folder ? "Folder" : size.map(sizeText)
        return ([first, linked ? "linked, not copied" : nil] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    /// Deletes copied files (and their folders) older than 30 days and project folders left empty; linked items are never here.
    func prune(now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(Self.maxAgeDays) * 86_400)
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in projects {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff { try? fm.removeItem(at: file) }
            }
            if ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["x"]).isEmpty { try? fm.removeItem(at: folder) }
        }
    }

    /// Files and folders on a pasteboard (copied in Finder), else the image itself.
    @MainActor func pending(from pasteboard: NSPasteboard) throws -> [PendingImage] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return try urls.map { try pending(file: $0) } }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return [try pending(pasted: data)] }
        return []
    }

    /// True when ⌘V should attach: file URLs (any type, folders too) or image data.
    static func hasAttachment(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func safe(_ id: String) -> String {
        let s = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return s.isEmpty ? "project" : s
    }
}
