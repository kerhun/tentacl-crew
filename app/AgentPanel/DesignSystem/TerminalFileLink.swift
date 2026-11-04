import AppKit

/// `path:line` links in terminal text (N268): finds the file name under a click, checks it exists and opens it in the editor chosen in the Aa panel.
enum TerminalFileLink {
    struct Match: Equatable {
        /// Absolute path of an existing file.
        let path: String
        let line: Int?
        let column: Int?
    }

    /// How a match is opened (separate from doing it, so tests check it without starting anything).
    enum Launch: Equatable {
        /// The file in its default app.
        case open(URL)
        /// An editor's URL scheme (`vscode://file/…:line:col`).
        case url(URL)
        /// A command line tool (`xed -l`, `zed path:line`).
        case run(String, [String])
    }

    private static let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`()[]{}<>,;|"))

    /// The word around column `col` of `line`, cut at spaces, quotes and brackets.
    static func word(in line: String, at col: Int) -> String? {
        let chars = Array(line)
        guard chars.indices.contains(col), !isDelimiter(chars[col]) else { return nil }
        var start = col, end = col
        while start > 0, !isDelimiter(chars[start - 1]) { start -= 1 }
        while end < chars.count - 1, !isDelimiter(chars[end + 1]) { end += 1 }
        return String(chars[start...end])
    }

    private static func isDelimiter(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { delimiters.contains($0) } }

    /// `app/Foo.swift:42`, `/abs/path.swift:42:7`, `path.swift` → the existing file (relative paths are looked up in `folder`).
    static func match(word: String, folder: String?, isFile: (String) -> Bool = { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && !dir.boolValue }) -> Match? {
        var text = word
        while let last = text.last, ".,:;!?".contains(last) { text.removeLast() }
        guard !text.isEmpty, !text.contains("://") else { return nil }
        var parts = text.components(separatedBy: ":")
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let n = Int(parts.last ?? ""), n > 0 { numbers.insert(n, at: 0); parts.removeLast() }
        let name = parts.joined(separator: ":")
        guard !name.isEmpty else { return nil }
        var path = (name as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            guard let folder, !folder.isEmpty else { return nil }
            path = (folder as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        guard isFile(path) else { return nil }
        return Match(path: path, line: numbers.first, column: numbers.count > 1 ? numbers[1] : nil)
    }

    static func launch(_ m: Match, editor: TerminalAppearance.Editor, zedCLI: String? = zedCLIPath()) -> Launch {
        let file = URL(fileURLWithPath: m.path)
        let suffix = [m.line, m.line == nil ? nil : m.column].compactMap { $0 }.map { ":\($0)" }.joined()
        switch editor {
        case .defaultApp:
            return .open(file)
        case .vscode, .cursor:
            let scheme = editor == .vscode ? "vscode" : "cursor"
            let encoded = m.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.path
            return URL(string: "\(scheme)://file\(encoded)\(suffix)").map(Launch.url) ?? .open(file)
        case .xcode:
            return .run("/usr/bin/xed", (m.line.map { ["-l", String($0)] } ?? []) + [m.path])
        case .zed:
            guard let zedCLI else { return .open(file) }
            return .run(zedCLI, [m.path + suffix])
        }
    }

    /// Zed's command line tool, where its app or Homebrew put it.
    static func zedCLIPath() -> String? {
        ["/Applications/Zed.app/Contents/MacOS/cli", "/opt/homebrew/bin/zed", "/usr/local/bin/zed"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Opens the match. An editor that is not installed (no app for its URL, no tool) opens the file in the default app instead.
    @MainActor static func open(_ m: Match, editor: TerminalAppearance.Editor) {
        switch launch(m, editor: editor) {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .url(let url):
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.open(URL(fileURLWithPath: m.path)) }
        case .run(let exe, let args):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            do { try p.run() } catch { NSWorkspace.shared.open(URL(fileURLWithPath: m.path)) }
        }
    }
}
