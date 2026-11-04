import SwiftUI
import AppKit
import WebKit

/// The three page widths of the preview (design C): the pane's width, a tablet and an iPhone (which also gets Safari's iPhone user agent).
enum PreviewWidth: String, CaseIterable {
    case desktop = "Desktop", tablet = "1024", phone = "390"

    var points: CGFloat? {
        switch self {
        case .desktop: return nil
        case .tablet: return 1024
        case .phone: return 390
        }
    }

    var userAgent: String? {
        self == .phone ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1" : nil
    }

    /// The frame and page zoom for `available` points: a width wider than the pane is laid out at its own width and scaled down.
    func frame(available: CGFloat) -> (width: CGFloat, zoom: CGFloat) {
        guard let points, available > 0 else { return (available, 1) }
        return points > available ? (available, available / points) : (points, 1)
    }
}

/// One console line the page sent (`console.error`, `console.warn`, an uncaught error or a failed load).
struct PreviewConsoleLine: Equatable {
    enum Level: String { case error, warn }
    let level: Level
    let text: String
}

/// An element picked in the page: its selector and its box in page (CSS) pixels.
struct PickedElement: Equatable {
    let selector: String
    let rect: CGRect
    var size: String { "\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))" }
}

/// Where the comment box goes (N225): right next to the element (beside it when there is room, else on its other side), below it on
/// the 390 width or when neither side fits; always inside the page frame.
enum PickBoxPlacement {
    static let gap: CGFloat = 8

    static func origin(element e: CGRect, frame: CGSize, box: CGSize, below: Bool) -> CGPoint {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, gap), max(gap, frame.width - box.width - gap)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, gap), max(gap, frame.height - box.height - gap)) }
        if !below {
            if e.maxX + gap + box.width <= frame.width - gap { return CGPoint(x: e.maxX + gap, y: clampY(e.minY)) }
            if e.minX - gap - box.width >= gap { return CGPoint(x: e.minX - gap - box.width, y: clampY(e.minY)) }
        }
        let under = e.maxY + gap
        let y = under + box.height <= frame.height - gap ? under : e.minY - gap - box.height
        return CGPoint(x: clampX(e.minX), y: clampY(y))
    }
}

/// The preview's screenshots: `tasks/assets/<ID>-preview-<n>.png`, numbered from 1.
enum PreviewShots {
    static func existing(in assets: URL, id: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)) ?? []
        return files.filter { number(of: $0, id: id) != nil }.sorted { number(of: $0, id: id)! < number(of: $1, id: id)! }
    }

    static func next(in assets: URL, id: String) -> URL {
        let n = (existing(in: assets, id: id).compactMap { number(of: $0, id: id) }.max() ?? 0) + 1
        return assets.appendingPathComponent("\(id)-preview-\(n).png")
    }

    static func number(of url: URL, id: String) -> Int? {
        let name = url.lastPathComponent, prefix = "\(id)-preview-"
        guard name.hasPrefix(prefix), name.hasSuffix(".png") else { return nil }
        return Int(name.dropFirst(prefix.count).dropLast(4))
    }
}

struct PreviewShotError: Error { let message: String }

/// The web view, its history and console, and the element picker. Local pages only (`PreviewRoute`).
@MainActor @Observable
final class PreviewModel: NSObject {
    private(set) var current: URL?
    var address = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var console: [PreviewConsoleLine] = []
    var width: PreviewWidth = .desktop { didSet { if width != oldValue { applyWidth() } } }
    private(set) var picking = false
    var picked: PickedElement?
    var note = ""
    /// A short line after an action ("Added to fix notes", an error); cleared on the next one.
    var status: String?
    /// Which web view the page is in (N240): claude.ai pages get their own signed-in store and none of the panel's scripts.
    private(set) var session: PreviewSession = .local
    /// Bumped when the web view is replaced (a page of the other session), so the pane builds the new one.
    private(set) var generation = 0
    /// The page's `<title>`, for the chat Preview's tab (N248).
    private(set) var title: String?
    /// Called with each page the user navigates to (the chat's Preview remembers the last one).
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    @ObservationIgnored let openOutside: (URL) -> Void
    @ObservationIgnored private var popups: [PopupWindow] = []
    @ObservationIgnored private var web: WKWebView?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    init(url: URL?, picking: Bool = false, openOutside: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.openOutside = openOutside
        super.init()
        current = url
        session = url.map(PreviewSession.of) ?? .local
        self.picking = picking
        address = url.map(Self.display) ?? ""
    }

    /// `localhost:5173/settings` for the address field (the scheme is dropped for http).
    static func display(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasPrefix("http://") ? String(s.dropFirst(7)) : s
    }

    var errorCount: Int { console.filter { $0.level == .error }.count }
    var warningCount: Int { console.filter { $0.level == .warn }.count }

    func webView() -> WKWebView {
        if let web { return web }
        let config = Self.configuration(for: session, handler: MessageProxy(self))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isInspectable = true
        view.customUserAgent = width.userAgent
        observers = [
            view.observe(\.canGoBack) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoForward = v.canGoForward } },
            view.observe(\.title) { [weak self] v, _ in MainActor.assumeIsolated { self?.title = v.title } },
            view.observe(\.url) { [weak self] v, _ in MainActor.assumeIsolated { if let u = v.url { self?.current = u; self?.address = Self.display(u); self?.onNavigate?(u) } } },
        ]
        web = view
        if let current { load(current, in: view) }
        return view
    }

    /// The web view's configuration. A claude.ai page gets a persistent store of its own and no scripts: nothing in the page is read,
    /// and nothing leaves it unless the user acts.
    static func configuration(for session: PreviewSession, handler: WKScriptMessageHandler? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        switch session {
        case .claude:
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: PreviewLink.claudeStoreID)
        case .local:
            guard let handler else { break }
            let controller = config.userContentController
            controller.add(handler, name: "tentaclConsole")
            controller.add(handler, name: "tentaclPick")
            controller.addUserScript(WKUserScript(source: PreviewScripts.console, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            controller.addUserScript(WKUserScript(source: PreviewScripts.pick, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        return config
    }

    /// Shows `url` in the web view of its session; a page of the other session gets a new web view.
    func show(_ url: URL) {
        let next = PreviewSession.of(url)
        current = url; address = Self.display(url)
        if next != session {
            session = next
            web = nil; observers = []; popups.forEach { $0.close() }; popups = []
            picking = false; picked = nil; console = []; canGoBack = false; canGoForward = false
            generation += 1
        } else if let web { load(url, in: web) }
    }

    var isClaude: Bool { session == .claude }

    func openInBrowser() { if let current { openOutside(current) } }

    /// Opens what the user typed: a local page or an artifact here, anything else in the default browser.
    func go(_ text: String) {
        guard let url = PreviewRoute.typed(text) else { return }
        switch PreviewRoute.of(url) {
        case .load: show(url)
        case .openOutside: openOutside(url); status = "Opened \(url.host ?? url.absoluteString) in the browser (only local pages and claude.ai artifacts open here)."
        case .ignore: break
        }
    }

    private func load(_ url: URL, in view: WKWebView) {
        if url.isFileURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { view.load(URLRequest(url: url)) }
    }

    func back() { web?.goBack() }
    func forward() { web?.goForward() }
    func reload() { web?.reload() }

    func setZoom(_ zoom: CGFloat) { if let web, abs(web.pageZoom - zoom) > 0.001 { web.pageZoom = zoom } }

    private func applyWidth() {
        guard let web else { return }
        if web.customUserAgent != (width.userAgent ?? "") { web.customUserAgent = width.userAgent; web.reload() }
        picked = nil
    }

    func togglePick() {
        picking.toggle()
        if !picking { picked = nil }
        web?.evaluateJavaScript(picking ? "window.__tentaclPick && window.__tentaclPick.start()" : "window.__tentaclPick && window.__tentaclPick.stop()")
    }

    func clearPick() {
        picked = nil; note = ""
        if picking { web?.evaluateJavaScript("window.__tentaclPick && window.__tentaclPick.start()") }
    }

    /// The fix-note line for the picked element, or nil when nothing is picked or the note is empty.
    var noteLine: String? {
        guard let picked, let current, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PreviewNote.line(url: current, selector: picked.selector, note: note)
    }

    /// Saves the visible page as a PNG; the completion gets the file or an error line.
    func screenshot(to file: URL, done: @escaping (Result<URL, PreviewShotError>) -> Void) {
        guard let web else { done(.failure(PreviewShotError(message: "No page is open."))); return }
        web.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                done(.failure(PreviewShotError(message: error?.localizedDescription ?? "Could not take the screenshot."))); return
            }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: file, options: .withoutOverwriting)
                done(.success(file))
            } catch { done(.failure(PreviewShotError(message: error.localizedDescription))) }
        }
    }

    /// Keeps the last 200 console lines.
    func record(_ line: PreviewConsoleLine) {
        console.append(line)
        if console.count > 200 { console.removeFirst(console.count - 200) }
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "tentaclConsole":
            guard let text = body["msg"] as? String else { return }
            record(PreviewConsoleLine(level: (body["level"] as? String) == "warn" ? .warn : .error, text: text))
        case "tentaclPick":
            guard picking, let x = body["x"] as? Double, let y = body["y"] as? Double, let w = body["w"] as? Double, let h = body["h"] as? Double else { return }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if (body["kind"] as? String) == "move" {
                if let p = picked { picked = PickedElement(selector: p.selector, rect: rect) }
            } else if let selector = body["selector"] as? String {
                picked = PickedElement(selector: selector, rect: rect); note = ""; status = nil
            }
        default: break
        }
    }
}

extension PreviewModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        switch PreviewRoute.of(url, mainFrame: mainFrame, session: session) {
        case .load where mainFrame && PreviewSession.of(url) != session && url.scheme != "about":
            show(url); decisionHandler(.cancel)
        case .load:
            if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) } else { decisionHandler(.allow) }
        case .openOutside: openOutside(url); decisionHandler(.cancel)
        case .ignore: decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        console = []; picked = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if picking { webView.evaluateJavaScript("window.__tentaclPick && window.__tentaclPick.start()") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        record(PreviewConsoleLine(level: .error, text: error.localizedDescription))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            // Sign-in opens a small window of claude.ai or Google and talks back to the page that opened it: it keeps its opener.
            if session == .claude, PreviewLink.isClaudeHost(url.host) || url.host?.lowercased() == "accounts.google.com" {
                let popup = PopupWindow(configuration: configuration) { [weak self] closed in self?.popups.removeAll { $0 === closed } }
                popups.append(popup)
                return popup.web
            }
            switch PreviewRoute.of(url, session: session) {
            case .load where PreviewSession.of(url) != session: show(url)
            case .load: webView.load(action.request)
            case .openOutside: openOutside(url)
            case .ignore: break
            }
        }
        return nil
    }
}

/// The script message handler holds its handler strongly; this keeps the web view from holding the model.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var model: PreviewModel?
    init(_ model: PreviewModel) { self.model = model }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { model?.received(message) }
    }
}

enum PreviewScripts {
    /// console.error / console.warn, uncaught errors, rejected promises and failed resource loads, sent to `tentaclConsole`.
    static let console = """
    (function(){
      if (window.__tentaclConsole) return; window.__tentaclConsole = true;
      function post(level, msg){ try { webkit.messageHandlers.tentaclConsole.postMessage({level: level, msg: String(msg).slice(0, 500)}); } catch (e) {} }
      function text(x){ try { return typeof x === 'string' ? x : (x instanceof Error ? (x.stack || x.message) : JSON.stringify(x)); } catch (e) { return String(x); } }
      ['error', 'warn'].forEach(function(level){
        var original = console[level];
        console[level] = function(){ post(level, Array.prototype.map.call(arguments, text).join(' ')); return original.apply(console, arguments); };
      });
      addEventListener('error', function(e){
        var t = e.target;
        if (t && t !== window && (t.src || t.href)) { post('error', 'Failed to load ' + (t.src || t.href)); return; }
        post('error', (e.message || 'Error') + (e.filename ? ' · ' + e.filename.split('/').pop() + ':' + e.lineno : ''));
      }, true);
      addEventListener('unhandledrejection', function(e){ var r = e.reason; post('error', 'Unhandled rejection: ' + (r && r.message ? r.message : r)); });
    })();
    """

    /// The element picker: an outline follows the pointer, a click selects (the page does not get it) and posts the selector and
    /// box to `tentaclPick`; scrolling posts the box again.
    static let pick = """
    (function(){
      if (window.__tentaclPick) return;
      var on = false, chosen = null, box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #A78BFA;border-radius:3px;background:rgba(167,139,250,0.12);display:none';
      function place(el){ var r = el.getBoundingClientRect(); box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px'; box.style.display = 'block'; return r; }
      function part(el){
        var s = el.tagName.toLowerCase();
        if (el.id && /^[A-Za-z][\\w-]*$/.test(el.id)) return s + '#' + el.id;
        var cls = Array.prototype.filter.call(el.classList, function(c){ return /^[A-Za-z_-][\\w-]*$/.test(c); }).slice(0, 2);
        return s + (cls.length ? '.' + cls.join('.') : '');
      }
      function unique(sel){ try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; } }
      function selector(el){
        var path = [], node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement && path.length < 5) {
          path.unshift(part(node));
          var sel = path.join(' > ');
          if (unique(sel)) return sel;
          node = node.parentElement;
        }
        var last = part(el), parent = el.parentElement;
        if (parent) { var same = Array.prototype.filter.call(parent.children, function(c){ return c.tagName === el.tagName; }); if (same.length > 1) last += ':nth-of-type(' + (same.indexOf(el) + 1) + ')'; }
        path[path.length - 1] = last;
        return path.join(' > ');
      }
      function post(kind, el, r){ try { webkit.messageHandlers.tentaclPick.postMessage({kind: kind, selector: kind === 'pick' ? selector(el) : '', x: r.left, y: r.top, w: r.width, h: r.height}); } catch (e) {} }
      function move(e){ if (on && !chosen && e.target !== box) place(e.target); }
      function click(e){ if (!on) return; e.preventDefault(); e.stopPropagation(); chosen = e.target; post('pick', chosen, place(chosen)); }
      function swallow(e){ if (on) { e.preventDefault(); e.stopPropagation(); } }
      function follow(){ if (on && chosen) post('move', chosen, place(chosen)); }
      document.addEventListener('mousemove', move, true);
      document.addEventListener('click', click, true);
      document.addEventListener('mousedown', swallow, true);
      document.addEventListener('mouseup', swallow, true);
      addEventListener('scroll', follow, true);
      addEventListener('resize', follow);
      window.__tentaclPick = {
        start: function(){ on = true; chosen = null; box.style.display = 'none'; if (!box.parentNode) document.documentElement.appendChild(box); },
        stop: function(){ on = false; chosen = null; box.style.display = 'none'; }
      };
    })();
    """
}

/// The sign-in window a claude.ai page opens (Google's account chooser); it closes itself when the page closes it.
@MainActor private final class PopupWindow: NSObject, WKUIDelegate {
    let web: WKWebView
    private let window: NSWindow
    private let onClose: (PopupWindow) -> Void

    init(configuration: WKWebViewConfiguration, onClose: @escaping (PopupWindow) -> Void) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 660), configuration: configuration)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.onClose = onClose
        super.init()
        web.uiDelegate = self
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.title = "Sign in"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
    func webViewDidClose(_ webView: WKWebView) { window.close(); onClose(self) }
}

private struct WebFrame: NSViewRepresentable {
    let model: PreviewModel
    func makeNSView(context: Context) -> WKWebView { model.webView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The preview pane (design C, N225): back, forward, reload, the address with where it came from, the width, Pick element, Screenshot
/// to card and close; the page; the console row. Reusable: `PreviewPane(url:source:cardID:)` is all the Terminals screen needs.
struct PreviewPane: View {
    /// The command that started the page (`npm run dev`), when the terminal shows one.
    let source: String?
    let cardID: String
    /// The card's `tasks/assets` folder for Screenshot to card; nil hides the button.
    var assetsFolder: URL? = nil
    /// Appends a line to the card's `## Fix notes`; returns an error line, nil on success. Nil hides the button.
    var addFixNote: ((String) -> String?)? = nil
    /// Sends a picked element's note straight to the agent as a prompt (the secondary action; Fix notes is the default). Nil: the note
    /// is copied for the message box instead.
    var sendToAgent: ((String) async -> String?)? = nil
    var onShot: (URL) -> Void = { _ in }
    var onClose: (() -> Void)? = nil
    /// Replaces "from <card> terminal" in the address bar (the chat's Preview).
    var fromText: String? = nil
    /// Set for the chat's Preview card (N248): a tab-like header with the page title, where it came from, expand or restore and close.
    var onExpand: (() -> Void)? = nil
    var expanded = false
    /// The chat's Preview over the chat card (N254): a Chat button in the tab header brings the chat back.
    var onChat: (() -> Void)? = nil
    @State private var model: PreviewModel
    @Environment(\.snapshotMode) private var snapshot

    init(url: URL?, source: String?, cardID: String, assetsFolder: URL? = nil, addFixNote: ((String) -> String?)? = nil, sendToAgent: ((String) async -> String?)? = nil,
         onShot: @escaping (URL) -> Void = { _ in }, onClose: (() -> Void)? = nil, fromText: String? = nil, onNavigate: ((URL) -> Void)? = nil,
         openOutside: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.source = source; self.cardID = cardID; self.assetsFolder = assetsFolder; self.addFixNote = addFixNote; self.sendToAgent = sendToAgent
        self.onShot = onShot; self.onClose = onClose; self.fromText = fromText
        let model = PreviewModel(url: url, openOutside: openOutside)
        model.onNavigate = onNavigate
        _model = State(initialValue: model)
    }

    /// With a model set up beforehand (snapshots).
    init(model: PreviewModel, source: String?, cardID: String, assetsFolder: URL? = nil, addFixNote: ((String) -> String?)? = nil,
         sendToAgent: ((String) async -> String?)? = nil, onClose: (() -> Void)? = nil, fromText: String? = nil, onExpand: (() -> Void)? = nil, expanded: Bool = false,
         onChat: (() -> Void)? = nil) {
        self.source = source; self.cardID = cardID; self.assetsFolder = assetsFolder; self.addFixNote = addFixNote; self.sendToAgent = sendToAgent; self.onClose = onClose
        self.fromText = fromText; self.onExpand = onExpand; self.expanded = expanded; self.onChat = onChat
        _model = State(initialValue: model)
    }

    var body: some View {
        if model.current == nil { empty } else { pane }
    }

    // MARK: empty state

    private var empty: some View {
        VStack(alignment: .leading, spacing: Tok.Space.m) {
            Text("No local page found in \(cardID)\u{2019}s terminal").font(Tok.Font.heading).foregroundStyle(Tok.ink)
            Text("When the agent starts a dev server, its localhost address opens here. You can also type one.")
                .font(Tok.Font.body).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tok.Space.s) {
                addressField(trailing: nil).frame(maxWidth: 420)
                Button("Open") { model.go(model.address) }.buttonStyle(ChromeButtonStyle()).disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let status = model.status { Text(status).font(Tok.Font.small).foregroundStyle(Tok.wait) }
            Text("Only localhost, file and claude.ai artifact pages open here. Other links open in your browser.").font(Tok.Font.small).foregroundStyle(Tok.ink3)
        }
        .padding(Tok.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }

    // MARK: pane

    private var pane: some View {
        VStack(spacing: 0) {
            if onExpand != nil { tabHeader; Rectangle().fill(Tok.line).frame(height: 1) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tok.Space.s) { navButtons; addressField(trailing: addressTrailing).frame(minWidth: 220); tools }
                VStack(alignment: .leading, spacing: Tok.Space.s) {
                    HStack(spacing: Tok.Space.s) { navButtons; addressField(trailing: addressTrailing) }
                    HStack(spacing: Tok.Space.s) { tools }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Rectangle().fill(Tok.line).frame(height: 1)
            if model.isClaude { signInHint; Rectangle().fill(Tok.line).frame(height: 1) }
            page
            // A claude.ai page has no console row: its scripts are not injected and nothing is read from it.
            if !model.isClaude {
                Rectangle().fill(Tok.line).frame(height: 1)
                consoleRow
            }
        }
        .background(Tok.pane)
        .clipShape(RoundedRectangle(cornerRadius: Tok.radius))
        .overlay(RoundedRectangle(cornerRadius: Tok.radius).stroke(Tok.line))
    }

    private var fromLine: String { fromText ?? "from \(cardID) terminal" + (source.map { " · \($0)" } ?? "") }
    /// The tab header says where the page came from; the address field does otherwise.
    private var addressTrailing: String? { onExpand == nil ? fromLine : nil }

    /// The tab's name: the page title, else its host (with the port), else the file name.
    static func tabTitle(title: String?, url: URL?) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        guard let url else { return "Preview" }
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host else { return "Preview" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var tabHeader: some View {
        HStack(spacing: Tok.Space.s) {
            Image(systemName: model.isClaude ? "sparkles" : "globe").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.ink2)
            Text(Self.tabTitle(title: model.title, url: model.current)).font(Tok.Font.bodyStrong).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.tail)
            Text(fromLine).font(Tok.Font.small).foregroundStyle(Tok.ink3).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            if let onChat {
                Button(action: onChat) { Label("Chat", systemImage: "bubble.left.and.bubble.right").labelStyle(.titleAndIcon) }
                    .buttonStyle(ChromeButtonStyle()).fixedSize().help(expanded ? "Back to the chat" : "Back to the chat (Esc)")
            }
            if let onExpand {
                iconButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           expanded ? "Restore preview (Esc)" : "Expand preview", enabled: true, action: onExpand)
            }
            if let onClose { iconButton("xmark", "Close preview", enabled: true, action: onClose) }
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 36)
    }

    static let signInHintText = "Signed out? Sign in with your email (same Gmail address): claude.ai sends a code. Google sign-in may not finish inside the app."

    private var signInHint: some View {
        HStack(spacing: Tok.Space.s) {
            Text(Self.signInHintText).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open in browser") { model.openInBrowser() }.buttonStyle(ChromeButtonStyle()).fixedSize().help("Opens this page in your default browser")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var navButtons: some View {
        HStack(spacing: 2) {
            iconButton("chevron.left", "Back", enabled: model.canGoBack) { model.back() }
            iconButton("chevron.right", "Forward", enabled: model.canGoForward) { model.forward() }
            iconButton("arrow.clockwise", "Reload", enabled: true) { model.reload() }
        }
    }

    private func iconButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? Tok.ink2 : Tok.ink3.opacity(0.5)).disabled(!enabled).help(label).accessibilityLabel(label)
    }

    private func addressField(trailing: String?) -> some View {
        HStack(spacing: Tok.Space.s) {
            Circle().fill(model.current.map { PreviewRoute.of($0) == .load } ?? false ? Tok.go : Tok.ink3).frame(width: 7, height: 7)
            if snapshot {
                // ImageRenderer cannot draw a text field.
                Text(model.address.isEmpty ? "localhost:5173" : model.address).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(model.address.isEmpty ? Tok.ink3 : Tok.ink).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.address, prompt: Text("localhost:5173").foregroundStyle(Tok.ink3))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.ink)
                    .onSubmit { model.go(model.address) }.accessibilityLabel("Address")
            }
            if let trailing { Text(trailing).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Tok.chrome, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .tutorialAnchor(.previewAddress)
    }

    @ViewBuilder private var tools: some View {
        HStack(spacing: 2) {
            ForEach(PreviewWidth.allCases, id: \.self) { w in
                let on = model.width == w
                Button { model.width = w } label: {
                    Text(w.rawValue).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? Tok.ink : Tok.ink2)
                        .padding(.horizontal, 9).frame(height: 26).background(on ? Tok.line : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2).background(Tok.chrome, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
        .fixedSize()
        if !model.isClaude {
            Button { model.togglePick() } label: {
                Label("Pick element", systemImage: "cursorarrow").font(.system(size: 12))
            }
            .buttonStyle(ChromeButtonStyle(on: model.picking)).fixedSize().help("Hover to outline an element, click to leave a note on it")
            .tutorialAnchor(.previewPick)
        }
        if let assetsFolder {
            Button("Screenshot to card") { takeShot(assetsFolder) }.buttonStyle(ChromeButtonStyle()).fixedSize().disabled(snapshot)
                .tutorialAnchor(.previewScreenshot)
        }
        if let onClose, onExpand == nil { iconButton("xmark", "Close preview", enabled: true, action: onClose) }
    }

    private func takeShot(_ folder: URL) {
        model.screenshot(to: PreviewShots.next(in: folder, id: cardID)) { result in
            switch result {
            case .success(let url): model.status = "Saved \(url.lastPathComponent) to Screenshots"; onShot(url)
            case .failure(let error): model.status = error.message
            }
        }
    }

    private var page: some View {
        GeometryReader { geo in
            let available = geo.size.width - 36
            let f = model.width.frame(available: available)
            VStack(spacing: 0) {
                pageContent(zoom: f.zoom)
                    .frame(width: f.width)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
            .onChange(of: f.zoom, initial: true) { _, z in model.setZoom(z) }
        }
        .background(Tok.chrome)
    }

    @ViewBuilder private func pageContent(zoom: CGFloat) -> some View {
        if snapshot {
            // ImageRenderer cannot draw a WKWebView; snapshots show where the page goes.
            Color.white.overlay(alignment: .bottom) {
                Text("The page renders here (a web view is not drawn in snapshots)").font(Tok.Font.small).foregroundStyle(Color(hex: 0x6B7280)).padding(Tok.Space.m)
            }
            .overlay(alignment: .topLeading) { pickOverlay(zoom: zoom) }
        } else {
            WebFrame(model: model).id(model.generation).overlay(alignment: .topLeading) { pickOverlay(zoom: zoom) }
        }
    }

    private func pickOverlay(zoom: CGFloat) -> some View {
        GeometryReader { geo in
            if let picked = model.picked {
                let r = CGRect(x: picked.rect.minX * zoom, y: picked.rect.minY * zoom, width: picked.rect.width * zoom, height: picked.rect.height * zoom)
                let size = CGSize(width: min(300, geo.size.width - 2 * PickBoxPlacement.gap), height: 150)
                let o = PickBoxPlacement.origin(element: r, frame: geo.size, box: size, below: model.width == .phone)
                PickBox(model: model, picked: picked, cardID: cardID, addFixNote: addFixNote, sendToAgent: sendToAgent).frame(width: size.width).offset(x: o.x, y: o.y)
            }
        }
    }

    private var consoleRow: some View {
        HStack(spacing: Tok.Space.s) {
            Text("CONSOLE").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(Tok.ink2)
            if model.console.isEmpty {
                Text("No errors").font(Tok.Font.small).foregroundStyle(Tok.ink3)
            } else {
                Text(consoleCount).font(Tok.Font.small).foregroundStyle(model.errorCount > 0 ? Tok.stop : Tok.wait)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background((model.errorCount > 0 ? Tok.stop : Tok.wait).opacity(0.14), in: Capsule())
                Text(model.console.last?.text ?? "").font(Tok.Font.mono).foregroundStyle(model.console.last?.level == .warn ? Tok.wait : Tok.stop)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let status = model.status { Text(status).font(Tok.Font.small).foregroundStyle(Tok.ink2).lineLimit(1) }
            if addFixNote != nil, model.errorCount > 0 {
                Button("Add errors to fix notes", action: addErrors)
                    .buttonStyle(.plain).font(Tok.Font.small).foregroundStyle(Tok.wait).padding(.horizontal, Tok.Space.s).frame(height: 22)
                    .help("Appends the console errors to \(cardID)\u{2019}s Fix notes")
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .help(model.console.suffix(10).map(\.text).joined(separator: "\n"))
    }

    private func addErrors() {
        guard let addFixNote, let current = model.current, let lines = PreviewNote.consoleLines(url: current, console: model.console) else { return }
        let count = lines.components(separatedBy: "\n").count
        model.status = addFixNote(lines) ?? "Added \(count) error\(count == 1 ? "" : "s") to fix notes"
    }

    private var consoleCount: String {
        [model.errorCount > 0 ? "\(model.errorCount) error\(model.errorCount == 1 ? "" : "s")" : nil,
         model.warningCount > 0 ? "\(model.warningCount) warning\(model.warningCount == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The comment box beside a picked element: its selector and size, a note, "Add to fix notes" (the default: Return) and, second,
/// "Send to <card> now" or "Put in message".
private struct PickBox: View {
    @Bindable var model: PreviewModel
    let picked: PickedElement
    let cardID: String
    let addFixNote: ((String) -> String?)?
    let sendToAgent: ((String) async -> String?)?
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.s) {
            HStack(spacing: 6) {
                Text("\(picked.selector) · \(picked.size)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tok.you).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { model.clearPick() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Tok.ink3).help("Pick another element").accessibilityLabel("Close")
            }
            Text("Note for the agent").font(.system(size: 12)).foregroundStyle(Tok.ink2)
            noteField
                .padding(.horizontal, 8).frame(height: 30)
                .background(Tok.chrome, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.line))
            HStack(spacing: 6) {
                if addFixNote != nil {
                    Button("Add to fix notes", action: add).buttonStyle(ChromeButtonStyle(ink: Tok.wait)).disabled(model.noteLine == nil)
                }
                Button(sendToAgent == nil ? "Put in message" : "Send to \(cardID) now") {
                    guard let line = model.noteLine else { return }
                    if let sendToAgent {
                        Task {
                            if let error = await sendToAgent(line) { model.status = error } else { model.status = "Sent to \(cardID)"; model.clearPick() }
                        }
                    } else {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line, forType: .string)
                        model.status = "Copied the note; paste it in the agent\u{2019}s message box"
                    }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tok.ink2).padding(.horizontal, 6).disabled(model.noteLine == nil)
            }
        }
        .padding(Tok.Space.m)
        .background(Tok.pane, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tok.you))
        .shadow(color: .black.opacity(Tok.shadowOpacity(0.35)), radius: 15, y: 12)
    }

    @ViewBuilder private var noteField: some View {
        if snapshot {
            Text(model.note).font(.system(size: 12)).foregroundStyle(Tok.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: $model.note, prompt: Text("What should change?").foregroundStyle(Tok.ink3))
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Tok.ink)
                .onSubmit(add)
        }
    }

    private func add() {
        guard let line = model.noteLine, let addFixNote else { return }
        if let error = addFixNote(line) { model.status = error } else { model.status = "Added to fix notes"; model.clearPick() }
    }
}

/// The pane's bordered buttons (design C): raised fill, line border; `on` is the purple Pick element state.
private struct ChromeButtonStyle: ButtonStyle {
    var on = false
    var ink: Color = Tok.ink
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(on ? Tok.you : ink).opacity(enabled ? 1 : 0.45)
            .padding(.horizontal, 10).frame(height: 30)
            .background(on ? Tok.youFill : Tok.raise, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Tok.you : Tok.line))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
