import SwiftUI

/// The saved last screen of a user's shell that came back after the session was gone (N273).
struct RestoredHistory: Equatable {
    let text: String
    let saved: Date
    let cwd: String

    /// "Restored from Oct 25, 18:21"
    var title: String { "Restored from " + saved.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
}

enum TerminalHistory {
    /// What tentacld saved for the shell `id`; nil when nothing is saved (or the daemon is an old one that does not know the verb).
    static func saved(client: TentacldClient, id: String) async -> RestoredHistory? {
        guard let r = try? await client.request(["verb": "history", "id": id]), r["found"] as? Bool == true, let text = r["text"] as? String else { return nil }
        return RestoredHistory(text: text, saved: Date(timeIntervalSince1970: r["saved"] as? Double ?? 0), cwd: r["cwd"] as? String ?? "")
    }

    /// A new shell in the folder of the saved one (the project folder when that is gone), with the saved text kept by the daemon.
    /// nil, and no shell, when nothing is saved: a shell the user closed leaves no file.
    static func restore(client: TentacldClient, id: String, fallbackCwd: String, argv: [String] = TerminalShells.argv()) async throws -> RestoredHistory? {
        guard let saved = await saved(client: client, id: id) else { return nil }
        var isDir: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: saved.cwd, isDirectory: &isDir) && isDir.boolValue ? saved.cwd : fallbackCwd
        _ = try await client.request(["verb": "spawn", "id": id, "argv": argv, "cwd": cwd, "restore": true])
        return saved
    }

    static func forget(client: TentacldClient, id: String) async {
        _ = try? await client.request(["verb": "forget", "id": id])
    }
}

/// The restored text per shell. A shell is brought back once per app launch (a shell that ends by itself while the app runs stays ended).
@MainActor @Observable
final class RestoredShells {
    static let shared = RestoredShells()
    private(set) var items: [String: RestoredHistory] = [:]
    @ObservationIgnored private var tried: Set<String> = []

    /// True once per id.
    func claim(_ id: String) -> Bool { tried.insert(id).inserted }
    func set(_ id: String, _ value: RestoredHistory) { items[id] = value }
    func drop(_ id: String) { items[id] = nil }
}

/// The dimmed text above a restored shell, under "Restored from <date> · Clear".
struct RestoredHistoryBlock: View {
    let restored: RestoredHistory
    let theme: TerminalTheme
    let font: Font
    let onClear: () -> Void
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(restored.title + " ·").foregroundStyle(theme.dim)
                Button("Clear", action: onClear).buttonStyle(.plain).foregroundStyle(Tok.you).accessibilityLabel("Clear restored text")
                Spacer()
            }
            .font(Tok.Font.small).padding(.horizontal, Tok.Space.m).padding(.vertical, 4)
            let lines = Text(restored.text.isEmpty ? " " : restored.text).font(font).foregroundStyle(theme.dim).opacity(0.7).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Tok.Space.m)
            // A snapshot cannot draw a ScrollView: the newest lines sit at the bottom, as in the pane.
            if snapshot { Color.clear.overlay(alignment: .bottomLeading) { lines }.clipped().frame(height: 150) }
            else { ScrollView { lines }.defaultScrollAnchor(.bottom).frame(maxHeight: 150) }
            Rectangle().fill(theme.lineColor).frame(height: 1)
        }
    }
}
