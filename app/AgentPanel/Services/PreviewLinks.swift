import Foundation

/// What a link is to the Preview (N240).
enum PreviewLinkKind: Equatable { case artifact, local, designFile, other }

/// Which web view a page belongs in: local pages and files share the default one; claude.ai has its own, signed-in and persistent,
/// and gets none of the panel's scripts.
enum PreviewSession: Equatable {
    case local, claude

    static func of(_ url: URL) -> PreviewSession { PreviewLink.isClaudeHost(url.host) ? .claude : .local }
}

enum PreviewLink {
    /// The claude.ai web view's own persistent data store (not shared with local pages). The panel never reads what is in it.
    static let claudeStoreID = UUID(uuidString: "7A1C2E40-5D3B-4C8E-9F61-0B2D7E4A9C13")!

    static func isClaudeHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }

    /// `https://claude.ai/artifact/…` and `https://claude.ai/code/artifact/…`.
    static func isArtifact(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == "claude.ai" || host == "www.claude.ai" else { return false }
        let path = url.path.lowercased()
        return (path.hasPrefix("/artifact/") && path.count > 10) || (path.hasPrefix("/code/artifact/") && path.count > 15)
    }

    /// The link as a URL the Preview can use: a relative `design/x.html` is a file of the project.
    static func resolved(_ url: URL, projectRoot: URL?) -> URL {
        guard url.scheme == nil, let projectRoot, url.path.hasPrefix("design/") else { return url }
        return projectRoot.appendingPathComponent(url.path)
    }

    /// A `.html` file inside `<project>/design/`.
    static func isDesignFile(_ url: URL, projectRoot: URL?) -> Bool {
        guard url.isFileURL, let projectRoot, url.pathExtension.lowercased() == "html" else { return false }
        let design = projectRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("design").path + "/"
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(design)
    }

    static func kind(of url: URL, projectRoot: URL?) -> PreviewLinkKind {
        let url = resolved(url, projectRoot: projectRoot)
        if isArtifact(url) { return .artifact }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), PreviewRoute.isLocalHost(url.host) { return .local }
        if isDesignFile(url, projectRoot: projectRoot) { return .designFile }
        return .other
    }

    /// Every artifact link in a line of text, in order.
    static func artifactURLs(in line: String) -> [URL] {
        let pattern = try! NSRegularExpression(pattern: #"https://(?:www\.)?claude\.ai/(?:code/)?artifact/[A-Za-z0-9._~%/-]+"#, options: .caseInsensitive)
        return pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
            Range(m.range, in: line).flatMap { URL(string: String(line[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\")]}"))) }
        }.filter(isArtifact)
    }

    /// The page a terminal's text points to: its newest local address or artifact link, whichever is lower on the screen.
    static func page(in text: String) -> LocalPage? {
        let lines = LocalPageFinder.stripANSI(text).components(separatedBy: .newlines)
        let artifact = lines.lastIndex { !artifactURLs(in: $0).isEmpty }
        let local = lines.lastIndex { !LocalPageFinder.urls(in: $0).isEmpty }
        if let artifact, local == nil || artifact > local!, let url = artifactURLs(in: lines[artifact]).last { return LocalPage(url: url, command: nil) }
        return LocalPageFinder.find(in: text)
    }
}

/// What a click on a link in the chat does (N240): opens in the Preview next to the chat, or in the browser (⌘-click, or a link the
/// Preview does not show).
enum ChatLinkAction: Equatable {
    case preview(URL), browser(URL)

    static func of(_ url: URL, commandHeld: Bool, projectRoot: URL?) -> ChatLinkAction {
        let url = PreviewLink.resolved(url, projectRoot: projectRoot)
        if commandHeld { return .browser(url) }
        return PreviewLink.kind(of: url, projectRoot: projectRoot) == .other ? .browser(url) : .preview(url)
    }
}
