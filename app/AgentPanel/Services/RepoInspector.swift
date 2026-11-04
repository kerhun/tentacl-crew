import Foundation

/// What "Add project" learns about an existing folder before it is registered. Read-only: nothing in the repository is written.
struct RepoFacts: Equatable {
    var isGitRepo = false
    /// The folder is the root of its repository, not a subfolder of one.
    var isTopLevel = false
    var hasCommits = false
    /// The checked-out branch; nil when there is none (detached HEAD, no commits, not a repository).
    var branch: String?
    /// The first `*.xcodeproj` at the top level, if any.
    var xcodeProject: String?
    /// Whether git already ignores `.agent-worktrees/` (through .gitignore or .git/info/exclude).
    var worktreesIgnored = false
}

/// The read-only picture of a folder that "Add project" and the PM's first summary start from. Guesses are shown as detected.
struct ProjectProbe: Equatable {
    enum Ecosystem: String, Equatable { case swiftPackage, xcode, node, python, rust, go, ruby, gradle, make }
    struct AgentDoc: Equatable {
        let name: String
        let isFolder: Bool
        /// The first ~40 lines; empty for a folder.
        let excerpt: String
    }
    var facts: RepoFacts
    /// `origin`'s URL; nil without a remote.
    var remote: String?
    /// Origin HEAD, then local main/master, then the current branch; no duplicates.
    var mainCandidates: [String] = []
    /// Changed or untracked paths in the working tree.
    var dirtyFiles = 0
    /// Commits ahead of the upstream; nil when the branch has no upstream.
    var unpushedCommits: Int?
    var commitCount = 0
    var ecosystems: [Ecosystem] = []
    var buildCommand: String?
    var testCommand: String?
    var xcodeSchemes: [String] = []
    /// Every `*.xcodeproj` at the top level (the schemes above are read from the first); more than one is asked about in the form.
    var xcodeProjects: [String] = []
    var agentDocs: [AgentDoc] = []
    var ciWorkflows: [String] = []
    var fileCount = 0
    var lastCommitDate: Date?
}

struct RepoInspector: Sendable {
    let runner: CommandRunner
    var git = URL(fileURLWithPath: "/usr/bin/git")
    var xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    var xcodebuild = URL(fileURLWithPath: "/usr/bin/xcodebuild")

    func inspect(_ path: String) async -> RepoFacts {
        var facts = RepoFacts()
        func run(_ args: [String]) async -> String? {
            guard let data = try? await runner.run(git, ["-C", path] + args) else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let inside = await run(["rev-parse", "--is-inside-work-tree"])
        guard inside == "true" else { return facts }
        facts.isGitRepo = true
        if let top = await run(["rev-parse", "--show-toplevel"]) {
            facts.isTopLevel = URL(fileURLWithPath: top).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let head = await run(["rev-parse", "--verify", "-q", "HEAD"])
        facts.hasCommits = head?.isEmpty == false   // the runner does not report exit codes: git prints the commit only when there is one
        if let branch = await run(["symbolic-ref", "--short", "-q", "HEAD"]), !branch.isEmpty { facts.branch = branch }
        let ignored = await run(["check-ignore", ".agent-worktrees/x"])
        facts.worktreesIgnored = ignored?.isEmpty == false   // check-ignore prints the path only when it is ignored
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        facts.xcodeProject = items.filter { $0.hasSuffix(".xcodeproj") }.sorted().first
        return facts
    }

    /// Everything `inspect` learns plus what the PM and the Add project form need: remote, main-branch candidates, dirty tree,
    /// unpushed commits, ecosystems, suggested commands, Xcode schemes, agent docs, CI names, size. Read only; a command that
    /// fails or times out leaves its field empty.
    func probe(_ path: String) async -> ProjectProbe {
        var probe = ProjectProbe(facts: await inspect(path))
        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
        func read(_ name: String) -> String? { try? String(contentsOfFile: path + "/" + name, encoding: .utf8) }
        func git(_ args: [String]) async -> String? {
            guard let data = try? await runner.run(self.git, ["-C", path] + args) else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if probe.facts.isGitRepo {
            if let url = await git(["remote", "get-url", "origin"]), !url.isEmpty { probe.remote = url }
            var candidates: [String] = []
            if let head = await git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]), head.hasPrefix("refs/remotes/origin/") {
                candidates.append(String(head.dropFirst("refs/remotes/origin/".count)))
            }
            for name in ["main", "master"] {
                // for-each-ref prints the ref only when it exists
                if let found = await git(["for-each-ref", "refs/heads/" + name]), !found.isEmpty, !candidates.contains(name) { candidates.append(name) }
            }
            if let current = probe.facts.branch, !candidates.contains(current) { candidates.append(current) }
            probe.mainCandidates = candidates
            if probe.facts.hasCommits {
                let status = await git(["status", "--porcelain"]) ?? ""
                probe.dirtyFiles = status.split(separator: "\n").count
                if let count = await git(["rev-list", "--count", "@{upstream}..HEAD"]), let n = Int(count) { probe.unpushedCommits = n }
                if let count = await git(["rev-list", "--count", "HEAD"]), let n = Int(count) { probe.commitCount = n }
                if let stamp = await git(["log", "-1", "--format=%ct"]), let t = TimeInterval(stamp) { probe.lastCommitDate = Date(timeIntervalSince1970: t) }
            } else {
                probe.dirtyFiles = (await git(["status", "--porcelain"]) ?? "").split(separator: "\n").count
            }
            if let files = await git(["ls-files"]) { probe.fileCount = files.isEmpty ? 0 : files.split(separator: "\n").count }
        } else {
            probe.fileCount = Self.countFiles(path)
        }
        probe.ecosystems = Self.ecosystems(items)
        probe.xcodeProjects = items.filter { $0.hasSuffix(".xcodeproj") }
        if let project = probe.facts.xcodeProject {
            let args = ["-list", "-json", "-project", path + "/" + project]
            if let data = try? await runner.run(xcodebuild, args),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let body = (object["project"] ?? object["workspace"]) as? [String: Any],
               let schemes = body["schemes"] as? [String] { probe.xcodeSchemes = schemes }
        }
        let commands = Self.commands(items: items, probe: probe, read: read)
        probe.buildCommand = commands.build; probe.testCommand = commands.test
        for name in ["CLAUDE.md", "AGENTS.md", ".claude", ".codex"] where items.contains(name) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path + "/" + name, isDirectory: &isDir)
            let excerpt = isDir.boolValue ? "" : (read(name) ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(40).joined(separator: "\n")
            probe.agentDocs.append(ProjectProbe.AgentDoc(name: name, isFolder: isDir.boolValue, excerpt: excerpt))
        }
        let workflows = (try? fm.contentsOfDirectory(atPath: path + "/.github/workflows")) ?? []
        probe.ciWorkflows = workflows.filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.sorted().map { name in
            let text = (try? String(contentsOfFile: path + "/.github/workflows/" + name, encoding: .utf8)) ?? ""
            let title = text.split(separator: "\n").first { $0.hasPrefix("name:") }.map { $0.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            return title.flatMap { $0.isEmpty ? nil : $0 } ?? name
        }
        return probe
    }

    static func ecosystems(_ items: [String]) -> [ProjectProbe.Ecosystem] {
        func has(_ names: String...) -> Bool { names.contains { items.contains($0) } }
        func hasSuffix(_ suffixes: String...) -> Bool { items.contains { name in suffixes.contains { name.hasSuffix($0) } } }
        var found: [ProjectProbe.Ecosystem] = []
        if has("Package.swift") { found.append(.swiftPackage) }
        if hasSuffix(".xcodeproj", ".xcworkspace") { found.append(.xcode) }
        if has("package.json") { found.append(.node) }
        if has("pyproject.toml", "requirements.txt") { found.append(.python) }
        if has("Cargo.toml") { found.append(.rust) }
        if has("go.mod") { found.append(.go) }
        if has("Gemfile") { found.append(.ruby) }
        if hasSuffix("build.gradle", "build.gradle.kts") { found.append(.gradle) }
        if has("Makefile") { found.append(.make) }
        return found
    }

    /// The commands to suggest, from the first ecosystem that has one. They are suggestions: the user reviews them.
    private static func commands(items: [String], probe: ProjectProbe, read: (String) -> String?) -> (build: String?, test: String?) {
        for ecosystem in probe.ecosystems {
            switch ecosystem {
            case .xcode:
                guard let project = probe.facts.xcodeProject else { continue }
                let base = (project as NSString).deletingPathExtension
                let scheme = probe.xcodeSchemes.contains(base) ? base : (probe.xcodeSchemes.first ?? base)
                let head = "xcodebuild -project '\(project)' -scheme '\(scheme)' -destination 'id=$UDID' -derivedDataPath build/dd"
                return (head + " build", head + " test")
            case .swiftPackage: return ("swift build", "swift test")
            case .node:
                guard let data = read("package.json")?.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let scripts = object["scripts"] as? [String: String] ?? [:]
                let manager = items.contains("pnpm-lock.yaml") ? "pnpm" : items.contains("yarn.lock") ? "yarn" : (items.contains("bun.lockb") || items.contains("bun.lock")) ? "bun" : "npm"
                let build = scripts["build"] != nil ? "\(manager) run build" : nil
                let test = scripts["test"].flatMap { $0.contains("no test specified") ? nil : "\(manager) test" }
                if build != nil || test != nil { return (build, test) }
            case .rust: return ("cargo build", "cargo test")
            case .go: return ("go build ./...", "go test ./...")
            case .python: return (nil, items.contains("pyproject.toml") || items.contains("requirements.txt") ? "python3 -m pytest" : nil)
            case .ruby: return (nil, "bundle exec rake test")
            case .gradle: return (items.contains("gradlew") ? "./gradlew build" : "gradle build", items.contains("gradlew") ? "./gradlew test" : "gradle test")
            case .make:
                let text = read("Makefile") ?? ""
                func target(_ name: String) -> Bool { text.split(separator: "\n").contains { $0.hasPrefix(name + ":") } }
                let build = target("build") ? "make build" : nil, test = target("test") ? "make test" : nil
                if build != nil || test != nil { return (build, test) }
            }
        }
        return (nil, nil)
    }

    /// Files in a folder that is not a repository, without `.git`-like and dependency folders; capped so a huge folder stays quick.
    private static func countFiles(_ path: String, cap: Int = 20000) -> Int {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let url as URL in walker {
            if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
            if count >= cap { break }
        }
        return count
    }

    /// The names of the installed, available iPhone simulators, "iPhone 17 Pro" first when it is there. Empty when Xcode's tools are missing.
    func simulators() async -> [String] {
        guard let data = try? await runner.run(xcrun, ["simctl", "list", "devices", "available", "-j"]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = object["devices"] as? [String: [[String: Any]]] else { return [] }
        var names: [String] = []
        for key in runtimes.keys.sorted(by: >) {
            for device in runtimes[key] ?? [] {
                guard let name = device["name"] as? String, name.hasPrefix("iPhone"), (device["isAvailable"] as? Bool) != false, !names.contains(name) else { continue }
                names.append(name)
            }
        }
        if let favourite = names.firstIndex(of: "iPhone 17 Pro") { names.insert(names.remove(at: favourite), at: 0) }
        return names
    }

    static func preferredSimulator(in names: [String]) -> String? { names.contains("iPhone 17 Pro") ? "iPhone 17 Pro" : names.first }
}
