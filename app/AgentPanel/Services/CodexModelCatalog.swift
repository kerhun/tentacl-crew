import Foundation

/// One Codex model a role can name, with the reasoning efforts it supports.
struct CodexModel: Equatable, Identifiable {
    let id: String
    let label: String
    let efforts: [String]
    let defaultEffort: String
}

/// The result of asking Codex for its models. Never partly filled: either models, or no models and the reason.
struct CodexCatalog: Equatable {
    var models: [CodexModel] = []
    var reason: String?

    /// The same shape as `ModelCatalog.claude`, so one picker can show either.
    var choices: [ModelChoice] { models.map { ModelChoice(id: $0.id, label: $0.label, group: CodexModelCatalog.group) } }
    func efforts(for model: String) -> [String] { models.first { $0.id == model }?.efforts ?? [] }
}

/// The models Codex lists (`codex debug models`, those with `visibility == "list"`), read off the main thread and kept after the
/// first good answer. A missing `codex` or output that cannot be read gives an empty catalog with a reason, never an error.
final class CodexModelCatalog: @unchecked Sendable {
    static let group = "Codex"

    private let executable: URL?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var kept: CodexCatalog?

    init(executable: URL? = CodexModelCatalog.findExecutable(), timeout: TimeInterval = 20) {
        self.executable = executable
        self.timeout = timeout
    }

    var cached: CodexCatalog? { lock.lock(); defer { lock.unlock() }; return kept }

    func load(refresh: Bool = false) async -> CodexCatalog {
        if !refresh, let kept = cached { return kept }
        guard let executable else { return CodexCatalog(reason: "codex is not installed (or not on PATH)") }
        let timeout = timeout
        let run = await Task.detached { Self.run(executable, timeout: timeout) }.value
        let catalog: CodexCatalog
        switch run {
        case .success(let data): catalog = Self.parse(data)
        case .failure(let reason): catalog = CodexCatalog(reason: reason)
        }
        if !catalog.models.isEmpty { lock.lock(); kept = catalog; lock.unlock() }
        return catalog
    }

    /// Pure: the listed models of a `codex debug models` output.
    static func parse(_ data: Data) -> CodexCatalog {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["models"] as? [[String: Any]] else {
            return CodexCatalog(reason: "codex debug models gave output the panel cannot read")
        }
        let models: [CodexModel] = raw.compactMap { item in
            guard item["visibility"] as? String == "list", let id = item["slug"] as? String, !id.isEmpty else { return nil }
            let efforts = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            let preferred = item["default_reasoning_level"] as? String ?? ""
            let label = (item["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return CodexModel(id: id, label: label, efforts: efforts, defaultEffort: efforts.contains(preferred) ? preferred : (efforts.first ?? preferred))
        }
        return models.isEmpty ? CodexCatalog(reason: "codex lists no models") : CodexCatalog(models: models)
    }

    private enum Run { case success(Data), failure(String) }

    private static func run(_ executable: URL, timeout: TimeInterval) -> Run {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable; process.arguments = ["debug", "models"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { return .failure("codex could not be started: \(error.localizedDescription)") }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // stderr is read on another thread so a full pipe cannot block the child.
        nonisolated(unsafe) var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); errDone.wait(); timer.cancel()
        guard process.terminationStatus == 0 else {
            let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure("codex debug models failed (exit \(process.terminationStatus))" + (text.isEmpty ? "" : ": " + String(text.prefix(300))))
        }
        return .success(data)
    }

    /// Looks for `codex` on PATH and in the usual install folders (an app started from Finder has a short PATH).
    static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathDirs + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return candidates.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
