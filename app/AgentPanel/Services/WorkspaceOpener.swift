import AppKit
import Foundation

enum OpenError: Error, Equatable {
    case notAllowed(String)
    case missing(String)
}

protocol URLOpening: Sendable {
    func open(_ url: URL)
}

struct WorkspaceURLOpener: URLOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// Opens folders and the Xcode project, but only inside the folders registered for the project:
/// the repository, its data folder and its agent worktrees. Paths are resolved (symlinks, `..`) before the check.
struct WorkspaceOpener {
    let project: ProjectConfig
    let opener: URLOpening

    init(project: ProjectConfig, opener: URLOpening = WorkspaceURLOpener()) {
        self.project = project
        self.opener = opener
    }

    func openFolder(_ url: URL) throws {
        let resolved = try allowed(url)
        guard FileManager.default.fileExists(atPath: resolved.path) else { throw OpenError.missing(resolved.path) }
        opener.open(resolved)
    }

    func openInXcode() throws {
        guard let name = project.xcodeProject, !name.isEmpty else { throw OpenError.missing("no xcodeProject configured") }
        let resolved = try allowed(project.repoURL.appendingPathComponent(name))
        guard FileManager.default.fileExists(atPath: resolved.path) else { throw OpenError.missing(resolved.path) }
        opener.open(resolved)
    }

    private var roots: [URL] { [project.repoURL, project.dataURL, project.worktreesURL] }

    /// Returns the resolved URL when it lies inside a registered root. Components are compared, not string prefixes,
    /// so `/work/repo-evil` is not inside `/work/repo`.
    private func allowed(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let parts = resolved.pathComponents
        let inside = roots.contains { root in
            let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return parts.count >= rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
        }
        guard inside else { throw OpenError.notAllowed(resolved.path) }
        return resolved
    }
}
