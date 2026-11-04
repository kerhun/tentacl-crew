import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One image the viewer can show: a file (a screenshot, an attachment) or the bytes of an image in the chat.
struct ViewerItem: Identifiable, Equatable {
    enum Source: Equatable {
        case file(URL)
        case data(Data)
    }
    let name: String
    let source: Source

    var id: String {
        switch source {
        case .file(let url): return url.path
        case .data(let data): return "\(name)-\(data.count)-\(data.hashValue)"
        }
    }

    /// The file to show in Finder; nil for image bytes.
    var fileURL: URL? { if case .file(let url) = source { url } else { nil } }

    var pixelSize: CGSize? {
        switch source {
        case .file(let url): return Thumbnail.pixelSize(url)
        case .data(let data): return Thumbnail.pixelSize(data)
        }
    }

    func load(maxPixel: Int) -> NSImage? {
        switch source {
        case .file(let url): return Thumbnail.load(url, maxPixel: maxPixel)
        case .data(let data): return Thumbnail.load(data, maxPixel: maxPixel)
        }
    }
}

/// The images opened together (the screenshots of a packet, the images of one message) and the one on screen.
/// ← / → move through them without wrapping around.
struct ViewerSet: Equatable {
    let items: [ViewerItem]
    private(set) var index: Int

    init(items: [ViewerItem], index: Int) {
        self.items = items
        self.index = max(0, min(index, items.count - 1))
    }

    /// The packet's screenshots that exist, starting on the clicked one; nil when the clicked file is missing.
    init?(shots: [ShotItem], opening shot: ShotItem) {
        let present = shots.filter(\.exists)
        guard let index = present.firstIndex(of: shot) else { return nil }
        self.init(items: present.map { ViewerItem(name: $0.name, source: .file($0.url)) }, index: index)
    }

    init(images: [ChatImage], index: Int) {
        self.init(items: images.enumerated().map { i, image in
            switch image {
            case .file(let path): return ViewerItem(name: URL(fileURLWithPath: path).lastPathComponent, source: .file(URL(fileURLWithPath: path)))
            case .inline(let data): return ViewerItem(name: "Image \(i + 1)", source: .data(data))
            }
        }, index: index)
    }

    var current: ViewerItem { items[index] }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index < items.count - 1 }
    /// "2 of 5"; nil for a single image.
    var position: String? { items.count > 1 ? "\(index + 1) of \(items.count)" : nil }

    mutating func next() { if hasNext { index += 1 } }
    mutating func previous() { if hasPrevious { index -= 1 } }
}

/// Zoom and pan of one image in the viewer. `scale` is screen points per image pixel (1 = 100%); `offset` moves the image's
/// centre away from the viewport's centre and never lets an image larger than the viewport show empty space at its edges.
struct ZoomState: Equatable {
    static let levels: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]
    static var minScale: CGFloat { levels.first! }
    static var maxScale: CGFloat { levels.last! }

    let imageSize: CGSize
    var viewport: CGSize { didSet { offset = clamped(offset) } }
    /// nil while fitted: the scale then follows the viewport.
    private var chosen: CGFloat?
    private(set) var offset: CGSize = .zero

    init(imageSize: CGSize, viewport: CGSize) {
        self.imageSize = imageSize
        self.viewport = viewport
    }

    /// The whole image in the viewport; a small image is never enlarged.
    var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(1, viewport.width / imageSize.width, viewport.height / imageSize.height)
    }
    var scale: CGFloat { chosen ?? fitScale }
    var isFit: Bool { chosen == nil }
    var percent: Int { Int((scale * 100).rounded()) }
    var displaySize: CGSize { CGSize(width: imageSize.width * scale, height: imageSize.height * scale) }

    mutating func fit() {
        chosen = nil
        offset = .zero
    }

    /// Zooms to `scale`, keeping the image point under `anchor` (a viewport point; the centre when nil) where it is.
    mutating func set(scale: CGFloat, anchor: CGPoint? = nil) {
        let new = max(Self.minScale, min(Self.maxScale, scale))
        let a = anchor.map { CGSize(width: $0.x - viewport.width / 2, height: $0.y - viewport.height / 2) } ?? .zero
        let ratio = new / self.scale
        chosen = new
        offset = clamped(CGSize(width: a.width - (a.width - offset.width) * ratio, height: a.height - (a.height - offset.height) * ratio))
    }

    mutating func zoomIn() {
        set(scale: Self.levels.first { $0 > scale + 0.001 } ?? Self.maxScale)
    }

    /// Zooming out past the fitted size lands on Fit first.
    mutating func zoomOut() {
        let next = Self.levels.last { $0 < scale - 0.001 } ?? Self.minScale
        if scale > fitScale + 0.001 && next <= fitScale + 0.001 { fit() } else { set(scale: next) }
    }

    /// Fit ⇄ 100%, zooming in at the clicked point.
    mutating func doubleClick(at point: CGPoint) {
        if isFit { set(scale: 1, anchor: point) } else { fit() }
    }

    mutating func pan(by delta: CGSize) {
        offset = clamped(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    /// The image pixel under a viewport point.
    func imagePoint(at point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - viewport.width / 2 - offset.width) / scale + imageSize.width / 2,
                y: (point.y - viewport.height / 2 - offset.height) / scale + imageSize.height / 2)
    }

    private func clamped(_ o: CGSize) -> CGSize {
        let x = max(0, (displaySize.width - viewport.width) / 2), y = max(0, (displaySize.height - viewport.height) / 2)
        return CGSize(width: max(-x, min(x, o.width)), height: max(-y, min(y, o.height)))
    }
}

/// A sheet on the window, sized to fit inside it, showing one image of a set: fitted at first, zoomed with pinch, ⌘+ / ⌘−, the zoom menu or a double-click,
/// panned by dragging or scrolling, ← / → through the set. Esc closes; Return does nothing (N54). The fitted image is a
/// downsampled copy loaded off the main thread; the full-size one loads only when the zoom needs it.
struct ImageViewer: View {
    /// No button answers Return here.
    static let defaultButton: SheetButton? = nil
    /// The longest side, in pixels, of the copy shown while fitted.
    static let fitPixel = 2560

    @State var set: ViewerSet
    let onClose: () -> Void
    @State private var zoom: ZoomState?
    @State private var shown: Shown?
    @State private var pinchStart: CGFloat?
    @State private var lastDrag: CGSize = .zero
    @State private var scrollMonitor: Any?
    @State private var errorMessage: String?
    @Environment(\.snapshotMode) private var snapshot

    private struct Shown {
        let id: String
        let image: NSImage
        let pixelSize: CGSize
        let loadedPixel: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Tok.line).frame(height: 1)
            GeometryReader { geo in viewport(geo.size) }
        }
        .background(Tok.bg)
        .escapeCancels(onClose)
        .background { shortcuts }
        .task(id: set.current.id) { await loadFitted() }
        .task(id: needsFull) { if needsFull { await loadFull() } }
        .onAppear(perform: watchScrolling)
        .onDisappear { scrollMonitor.map(NSEvent.removeMonitor); scrollMonitor = nil }
        .alert("Cannot open", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: toolbar

    /// How much of the toolbar shows inline. The first one that fits the sheet's width is used; the others move what does
    /// not fit into a menu instead of running off the edge.
    enum ToolbarLayout: CaseIterable {
        /// Everything inline.
        case full
        /// Open in Preview and Show in Finder go into the "…" menu.
        case compact
        /// The zoom in and out buttons also go into the zoom menu.
        case minimal

        var fileActionsInline: Bool { self == .full }
        var zoomButtonsInline: Bool { self != .minimal }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(ToolbarLayout.allCases, id: \.self) { toolbar($0) }
        }
        .frame(maxWidth: .infinity)
        .background(Tok.pane)
    }

    /// The toolbar in one layout: title, size and "2 of 5", previous / next, zoom, the file actions, close.
    func toolbar(_ layout: ToolbarLayout) -> some View {
        HStack(spacing: Tok.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(set.current.name).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                HStack(spacing: Tok.Space.s) {
                    if let size = current?.pixelSize { Text(verbatim: "\(Int(size.width)) × \(Int(size.height)) px") }
                    if let position = set.position { Text(position) }
                }
                .font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1)
            }
            // A long name truncates instead of choosing a smaller layout.
            .frame(minWidth: 60, idealWidth: 150, maxWidth: .infinity, alignment: .leading)
            if set.items.count > 1 {
                HStack(spacing: Tok.Space.xs) {
                    iconButton("chevron.left", help: "Previous image (←)", action: previous).disabled(!set.hasPrevious)
                    iconButton("chevron.right", help: "Next image (→)", action: next).disabled(!set.hasNext)
                }
            }
            HStack(spacing: Tok.Space.xs) {
                if layout.zoomButtonsInline { iconButton("minus.magnifyingglass", help: "Zoom out (⌘−)") { zoom?.zoomOut() } }
                MenuBox {
                    Button("Fit") { zoom?.fit() }
                    Button("100%") { zoom?.set(scale: 1) }
                    Button("200%") { zoom?.set(scale: 2) }
                    if !layout.zoomButtonsInline {
                        Divider()
                        Button("Zoom In (⌘+)") { zoom?.zoomIn() }
                        Button("Zoom Out (⌘−)") { zoom?.zoomOut() }
                    }
                } label: {
                    Text(zoom.map { $0.isFit ? "Fit · \($0.percent)%" : "\($0.percent)%" } ?? "Fit")
                        .font(Tok.Font.small.monospacedDigit()).foregroundStyle(Tok.ink).lineLimit(1)
                        .frame(minWidth: 64).padding(.horizontal, Tok.Space.s).padding(.vertical, 6)
                        .background(Tok.raise, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.line))
                }
                .fixedSize()
                .help("Zoom")
                if layout.zoomButtonsInline { iconButton("plus.magnifyingglass", help: "Zoom in (⌘+)") { zoom?.zoomIn() } }
            }
            if layout.fileActionsInline {
                Button("Open in Preview", action: openInPreview).buttonStyle(PanelButtonStyle()).fixedSize()
                Button("Show in Finder", action: showInFinder).buttonStyle(PanelButtonStyle()).fixedSize().disabled(set.current.fileURL == nil)
                    .help(set.current.fileURL == nil ? "This image is not a file" : "Show the file in Finder")
            } else {
                MenuBox {
                    Button("Open in Preview", action: openInPreview)
                    Button("Show in Finder", action: showInFinder).disabled(set.current.fileURL == nil)
                } label: { iconLabel("ellipsis") }
                .fixedSize()
                .help("More: Open in Preview, Show in Finder")
                .accessibilityLabel("More")
            }
            iconButton("xmark", help: "Close (Esc)", action: onClose)
        }
        .padding(.horizontal, Tok.Space.l).padding(.vertical, Tok.Space.m)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(symbol) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }

    private func iconLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.ink2)
            .frame(width: 28, height: 28)
            .background(Tok.raise, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tok.line))
    }

    /// Key commands without a visible button: ⌘+ (also ⌘=), ⌘−, ← and →.
    private var shortcuts: some View {
        ZStack {
            Button("") { zoom?.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("") { zoom?.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("") { zoom?.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("", action: previous).keyboardShortcut(.leftArrow, modifiers: [])
            Button("", action: next).keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: viewport

    /// The image shown for the current item, if it has loaded (in a snapshot it is loaded right away).
    private var current: Shown? {
        if let shown, shown.id == set.current.id { return shown }
        guard snapshot, let size = set.current.pixelSize, let image = set.current.load(maxPixel: Self.fitPixel) else { return nil }
        return Shown(id: set.current.id, image: image, pixelSize: size, loadedPixel: Self.fitPixel)
    }

    @ViewBuilder private func viewport(_ size: CGSize) -> some View {
        if let current {
            let z = zoom.flatMap { $0.imageSize == current.pixelSize ? $0 : nil } ?? ZoomState(imageSize: current.pixelSize, viewport: size)
            Image(nsImage: current.image).resizable().interpolation(z.scale >= 2 ? .none : .high)
                .frame(width: z.displaySize.width, height: z.displaySize.height)
                .offset(z.offset)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .clipped()
                .gesture(drag)
                .simultaneousGesture(pinch)
                .onTapGesture(count: 2) { point in zoom?.doubleClick(at: point) }
                .onAppear { zoom = z; zoom?.viewport = size }
                .onChange(of: size) { _, new in zoom?.viewport = new }
                .accessibilityLabel("Image \(set.current.name)")
        } else {
            Text(set.current.pixelSize == nil ? "Cannot read this image" : "Loading…").font(Tok.Font.body).foregroundStyle(Tok.ink3)
                .frame(width: size.width, height: size.height)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                zoom?.pan(by: CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height))
                lastDrag = value.translation
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard zoom != nil else { return }
                let start = pinchStart ?? zoom!.scale
                pinchStart = start
                zoom?.set(scale: start * value.magnification, anchor: value.startLocation)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Scrolling pans a zoomed image; while fitted the scroll passes on.
    private func watchScrolling() {
        guard !snapshot, scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let z = zoom, !z.isFit, event.window === NSApp.keyWindow else { return event }
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            zoom?.pan(by: CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            return nil
        }
    }

    // MARK: loading

    /// True when the zoomed image would show more pixels than the fitted copy has.
    private var needsFull: Bool {
        guard let shown = current, let z = zoom else { return false }
        let longest = max(shown.pixelSize.width, shown.pixelSize.height)
        return CGFloat(shown.loadedPixel) < longest && z.scale * longest * 2 > CGFloat(shown.loadedPixel)
    }

    private func loadFitted() async {
        let item = set.current
        guard !snapshot, shown?.id != item.id else { return }
        let fitPixel = Self.fitPixel
        let loaded = await Task.detached { () -> Shown? in
            guard let size = item.pixelSize, let image = item.load(maxPixel: fitPixel) else { return nil }
            return Shown(id: item.id, image: image, pixelSize: size, loadedPixel: min(fitPixel, Int(max(size.width, size.height))))
        }.value
        guard item.id == set.current.id else { return }
        shown = loaded
        if let loaded { zoom = ZoomState(imageSize: loaded.pixelSize, viewport: zoom?.viewport ?? .zero) }
    }

    private func loadFull() async {
        guard let base = current else { return }
        let item = set.current, longest = Int(max(base.pixelSize.width, base.pixelSize.height))
        let image = await Task.detached { item.load(maxPixel: longest) }.value
        guard let image, item.id == set.current.id else { return }
        shown = Shown(id: item.id, image: image, pixelSize: base.pixelSize, loadedPixel: longest)
    }

    // MARK: actions

    private func previous() { set.previous() }
    private func next() { set.next() }

    private func openInPreview() {
        do {
            let url = try set.current.fileURL ?? Self.temporaryFile(for: set.current)
            guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                errorMessage = "Preview was not found."
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showInFinder() {
        guard let url = set.current.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Image bytes have no file; Preview gets a copy in the temporary folder.
    private static func temporaryFile(for item: ViewerItem) throws -> URL {
        guard case .data(let data) = item.source else { throw CocoaError(.fileNoSuchFile) }
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tentacl-\(item.name.replacingOccurrences(of: " ", with: "-"))")
            .appendingPathExtension(type?.preferredFilenameExtension ?? "png")
        try data.write(to: url)
        return url
    }
}

extension ImageViewer {
    /// The space kept between the viewer and the window's edges.
    static let windowMargin = Tok.Space.xl

    /// The viewer's size inside a window whose content is `window` big: the window less a margin, never larger than the window.
    /// Without a known window it assumes the panel's smallest one (1100 × 600) rather than the screen.
    static func sheetSize(window: CGSize?) -> CGSize {
        let window = window ?? CGSize(width: 1100, height: 600)
        func fit(_ side: CGFloat) -> CGFloat { max(0, max(side - 2 * windowMargin, min(side, 320) - 2 * Tok.Space.s)) }
        return CGSize(width: fit(window.width), height: fit(window.height))
    }
}

extension View {
    /// Shows `set` in the image viewer: a sheet on this view's window, sized to the window (not the screen) and following it.
    func imageViewer(_ set: Binding<ViewerSet?>) -> some View {
        modifier(ImageViewerPresenter(set: set))
    }
}

private struct ImageViewerPresenter: ViewModifier {
    @Binding var set: ViewerSet?
    @State private var window: CGSize?

    func body(content: Content) -> some View {
        content
            .background(WindowSizeReader(size: $window))
            .sheet(isPresented: Binding(get: { set != nil }, set: { if !$0 { set = nil } })) {
                if let value = set {
                    let size = ImageViewer.sheetSize(window: window)
                    ImageViewer(set: value, onClose: { set = nil })
                        .frame(width: size.width, height: size.height)
                }
            }
    }
}

/// Reports the content size of the window the view is in, and again whenever the window is resized.
private struct WindowSizeReader: NSViewRepresentable {
    @Binding var size: CGSize?

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { new in if size != new { size = new } }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: (CGSize) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            report(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let window = self?.window { self?.report(window) } }
            }
        }

        private func report(_ window: NSWindow) {
            let size = window.contentLayoutRect.size
            DispatchQueue.main.async { self.onChange(size) }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }
}
