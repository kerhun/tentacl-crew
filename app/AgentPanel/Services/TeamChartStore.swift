import Foundation

enum TeamChartLoad: Equatable {
    /// The project has no `team.json`: nothing is checked and nothing is added to instructions.
    case none
    case valid(TeamChart)
    case invalid([RoleProblem])
}

enum TeamChartWriteError: Error, Equatable {
    case noProjectFile
    case isSymlink
    case problems([RoleProblem])
    case writeFailed(String)
}

/// Reads and writes a project's `team.json` (next to its `project.json`) and nothing else.
struct TeamChartStore {
    func url(for project: ProjectConfig) -> URL? {
        project.sourcePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("team.json") }
    }

    func load(for project: ProjectConfig) -> TeamChartLoad {
        guard let url = url(for: project), FileManager.default.fileExists(atPath: url.path) || isSymlink(url) else { return .none }
        func problem(_ message: String) -> TeamChartLoad { .invalid([RoleProblem(field: "team.json", message: message, severity: .error)]) }
        if isSymlink(url) { return problem("team.json is a symbolic link; the panel does not use it.") }
        guard let data = try? Data(contentsOf: url) else { return problem("team.json could not be read.") }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return problem("team.json is not valid JSON.") }
        guard let chart = try? JSONDecoder().decode(TeamChart.self, from: data) else { return problem("team.json needs a \"members\" list of {\"role\", \"reportsTo\"} entries.") }
        let found = chart.problems
        return found.isEmpty ? .valid(chart) : .invalid(found)
    }

    func save(_ chart: TeamChart, for project: ProjectConfig) throws {
        guard let url = url(for: project) else { throw TeamChartWriteError.noProjectFile }
        if isSymlink(url) || isSymlink(url.deletingLastPathComponent()) { throw TeamChartWriteError.isSymlink }
        let found = chart.problems
        guard found.isEmpty else { throw TeamChartWriteError.problems(found) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".team.json.panel-\(UUID().uuidString)")
        do {
            try encoder.encode(chart).write(to: temp)
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) } else { try fm.moveItem(at: temp, to: url) }
        } catch {
            try? fm.removeItem(at: temp)
            throw TeamChartWriteError.writeFailed(error.localizedDescription)
        }
    }

    private func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
}
