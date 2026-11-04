import Foundation
import CryptoKit

/// A published GitHub release, as far as the update needs it.
struct ReleaseInfo: Equatable {
    let tag: String
    let notes: String
    let isBeta: Bool
    /// The first lines of the release notes as plain text, for Settings and the notification.
    var summary: String { NotificationText.plain(Self.withoutLeadingHeading(notes)).split(whereSeparator: \.isNewline).prefix(4).joined(separator: "\n") }

    /// The notes without their leading Markdown heading lines ("## What's new"): Settings already says "What's new in …" (N340).
    static func withoutLeadingHeading(_ notes: String) -> String {
        var lines = notes.components(separatedBy: "\n")[...]
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty
                || first.range(of: #"^\s{0,3}#{1,6}(\s|$)"#, options: .regularExpression) != nil { lines = lines.dropFirst() }
        return lines.joined(separator: "\n")
    }
}

/// Asks GitHub for the newest public release (no token, no personal data). Every failure is quiet: the answer is nil.
enum UpdateChecker {
    typealias Get = @Sendable (URL) async throws -> Data
    static let repo = "kerhun/tentacl-crew"
    static let live: Get = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// The running app's tag from its version and label: 1.0 + "Beta 1" → v1.0-beta.1; nil for a development build.
    static func ownTag(short: String?, label: String?) -> String? {
        guard let short, short.first?.isNumber == true else { return nil }
        let l = (label ?? "").trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: ".")
        return "v" + short + (l.isEmpty ? "" : "-" + l)
    }

    /// The newest release: `releases/latest`, or with betas the first published entry of `releases`.
    static func latest(includeBetas: Bool, get: Get) async -> ReleaseInfo? {
        let base = "https://api.github.com/repos/\(repo)/releases"
        guard let url = URL(string: includeBetas ? base : base + "/latest"), let data = try? await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entry = includeBetas ? (json as? [[String: Any]])?.first { $0["draft"] as? Bool != true } : json as? [String: Any]
        guard let entry, let tag = entry["tag_name"] as? String, tag.hasPrefix("v") else { return nil }
        return ReleaseInfo(tag: tag, notes: entry["body"] as? String ?? "", isBeta: entry["prerelease"] as? Bool ?? false)
    }
}

/// Settings → Version and updates: the check (at launch + 30 s, then every 24 h, and "Check now") and the install of a newer release.
/// Nothing installs without the click. The install is `install.sh` from that release, started detached while the app quits.
@Observable @MainActor
final class UpdateModel {
    enum Phase: Equatable { case idle, checking, installing, failed(String) }
    static let autoKey = "updateAutoCheck", betasKey = "updateIncludeBetas", notifiedKey = "updateNotifiedTag"
    static let lastCheckKey = "updateLastCheck", lastCheckFailedKey = "updateLastCheckFailed"
    static let interval: TimeInterval = 24 * 3600

    private(set) var available: ReleaseInfo?
    private(set) var phase: Phase = .idle
    /// "Up to date" / "Could not check" after a manual check.
    private(set) var result: String?
    var confirming = false
    private(set) var autoCheck: Bool
    private(set) var includeBetas: Bool
    /// The last check that got an answer from GitHub, and whether the check after it failed (kept in defaults, N340).
    private(set) var lastCheck: Date?
    private(set) var lastCheckFailed: Bool
    let ownTag: String?
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let get: UpdateChecker.Get
    @ObservationIgnored private let appFolder: URL
    /// Starts a program detached (argv[0] is the program).
    @ObservationIgnored private let start: ([String]) throws -> Void
    @ObservationIgnored private let workFolder: URL
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(ownTag: String?, defaults: UserDefaults, get: @escaping UpdateChecker.Get = UpdateChecker.live,
         appFolder: URL = Bundle.main.bundleURL.deletingLastPathComponent(), workFolder: URL = FileManager.default.temporaryDirectory,
         start: @escaping ([String]) throws -> Void = UpdateModel.startDetached, now: @escaping () -> Date = Date.init) {
        self.ownTag = ownTag; self.defaults = defaults; self.get = get; self.appFolder = appFolder; self.start = start; self.workFolder = workFolder; self.now = now
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        lastCheckFailed = defaults.bool(forKey: Self.lastCheckFailedKey)
        autoCheck = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        includeBetas = defaults.object(forKey: Self.betasKey) as? Bool ?? (ownTag?.contains("-") == true)
    }

    static func live(defaults: UserDefaults) -> UpdateModel {
        let info = Bundle.main.infoDictionary
        return UpdateModel(ownTag: UpdateChecker.ownTag(short: info?["CFBundleShortVersionString"] as? String, label: info?["TentaclReleaseLabel"] as? String), defaults: defaults)
    }

    static func startDetached(_ argv: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst())
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
    }

    func setAutoCheck(_ on: Bool) { autoCheck = on; defaults.set(on, forKey: Self.autoKey) }
    func setIncludeBetas(_ on: Bool) { includeBetas = on; defaults.set(on, forKey: Self.betasKey) }

    /// Checks once. Returns the release only when it is newer than the running app and was not announced yet (`onNew` is the notification).
    func check(manual: Bool = false, onNew: (ReleaseInfo) -> Void = { _ in }) async {
        guard phase == .idle || phase.isFailed, let ownTag else { if manual { result = "This is a development build." }; return }
        phase = .checking
        let release = await UpdateChecker.latest(includeBetas: includeBetas, get: get)
        phase = .idle
        lastCheckFailed = release == nil
        defaults.set(lastCheckFailed, forKey: Self.lastCheckFailedKey)
        guard let release else { if manual { result = "Could not check. Try again later." }; return }
        lastCheck = now(); defaults.set(lastCheck, forKey: Self.lastCheckKey)
        if SettingsFlow.isNewer(release.tag, ownTag) {
            available = release; result = nil
            if defaults.string(forKey: Self.notifiedKey) != release.tag { defaults.set(release.tag, forKey: Self.notifiedKey); onNew(release) }
        } else { available = nil; if manual { result = "Tentacl Crew is up to date." } }
    }

    /// The General card's "checked 10 min ago" / "not checked yet" / "could not check".
    var checkedText: String { Self.checkedText(lastCheck: lastCheck, failed: lastCheckFailed, now: now()) }

    static func checkedText(lastCheck: Date?, failed: Bool, now: Date) -> String {
        if failed { return "could not check" }
        guard let lastCheck else { return "not checked yet" }
        let seconds = now.timeIntervalSince(lastCheck)
        return seconds < 60 ? "checked just now" : "checked \(Stats.durationText(seconds)) ago"
    }

    /// At launch (after 30 s) and every 24 h while "Check for updates automatically" is on.
    func startSchedule(first: TimeInterval = 30, onNew: @escaping @MainActor (ReleaseInfo) -> Void) {
        loop?.cancel()
        loop = Task { [weak self] in
            var wait = first
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait)); wait = Self.interval
                guard let self, !Task.isCancelled else { return }
                if self.autoCheck { await self.check(onNew: onNew) }
            }
        }
    }

    /// Downloads that release's install.sh and SHA256SUMS, checks the script against the sums, starts it detached and quits.
    /// Nothing is started when the sum does not match.
    func install(quit: () -> Void) async {
        guard let release = available, phase == .idle || phase.isFailed else { return }
        phase = .installing
        do {
            let base = "https://github.com/\(UpdateChecker.repo)/releases/download/\(release.tag)/"
            let script = try await get(URL(string: base + "install.sh")!), sums = try await get(URL(string: base + "SHA256SUMS")!)
            let hash = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
            let listed = String(decoding: sums, as: UTF8.self).split(whereSeparator: \.isNewline)
                .first { $0.split(separator: " ").last == "install.sh" }?.split(separator: " ").first
            guard listed.map(String.init) == hash else { throw UpdateError.sumMismatch }
            let folder = workFolder.appendingPathComponent("tentacl-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("install.sh")
            try script.write(to: file)
            try start(Self.command(script: file, tag: release.tag, dir: appFolder))
            phase = .idle
            quit()
        } catch UpdateError.sumMismatch { phase = .failed("install.sh does not match the release's SHA256SUMS; nothing was installed.") }
        catch { phase = .failed("Could not start the update: \(error.localizedDescription)") }
    }

    enum UpdateError: Error { case sumMismatch }

    static func command(script: URL, tag: String, dir: URL) -> [String] {
        ["/usr/bin/nohup", "/bin/bash", script.path, "--version", tag, "--dir", dir.path, "--yes", "--open"]
    }
}

private extension UpdateModel.Phase { var isFailed: Bool { if case .failed = self { true } else { false } } }
