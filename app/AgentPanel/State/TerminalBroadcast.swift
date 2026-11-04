import Foundation

/// Broadcast on the Terminals screen (N271): what the user types into the focused live terminal also goes to the other picked panes.
/// Not saved. Shell panes are picked when it starts; an agent pane only after an explicit yes, asked once.
struct TerminalBroadcast: Equatable {
    private(set) var isOn = false
    private(set) var picked: Set<String> = []
    /// The panes seen since it started, so a pane that joins is picked once and an unticked one stays unticked.
    private var known: Set<String> = []
    /// "Also type into agent panes?" was answered yes.
    private(set) var agentsAllowed = false
    private let isShell: (String) -> Bool

    init(isShell: @escaping (String) -> Bool = TerminalShells.isUserShell) { self.isShell = isShell }

    static func == (a: Self, b: Self) -> Bool {
        a.isOn == b.isOn && a.picked == b.picked && a.agentsAllowed == b.agentsAllowed && a.known == b.known
    }

    enum Toggle: Equatable {
        case picked, unpicked
        /// An agent pane that is not allowed yet: the screen asks, then calls `allowAgents(andPick:)`.
        case needsAgentConsent
    }

    /// All shell panes of the screen ticked; agent panes never.
    mutating func start(panes: [String]) {
        isOn = true
        agentsAllowed = false
        known = Set(panes)
        picked = Set(panes.filter(isShell))
    }

    mutating func stop() { isOn = false; picked = []; known = []; agentsAllowed = false }

    /// The panes on the screen changed: gone panes drop out, new shell panes are ticked (an agent pane too once agents are allowed).
    mutating func reconcile(panes: [String]) {
        guard isOn else { return }
        let now = Set(panes)
        for new in now.subtracting(known) where isShell(new) || agentsAllowed { picked.insert(new) }
        known = now
        picked.formIntersection(now)
    }

    mutating func toggle(_ pane: String) -> Toggle {
        guard isOn else { return .unpicked }
        if picked.contains(pane) { picked.remove(pane); return .unpicked }
        if !isShell(pane) && !agentsAllowed { return .needsAgentConsent }
        picked.insert(pane)
        return .picked
    }

    /// The yes of "Also type into agent panes?": asked once, so agent panes toggle freely from here.
    mutating func allowAgents(andPick pane: String) { guard isOn else { return }; agentsAllowed = true; picked.insert(pane) }

    func isPicked(_ pane: String) -> Bool { isOn && picked.contains(pane) }

    /// "Typing into 3 panes" counts the picked panes that are on the screen.
    var count: Int { picked.count }

    /// The panes that get a copy of what is typed into `source`: the other picked panes. Typing into a pane that is not picked is not
    /// broadcast (its mark is off).
    func targets(from source: String, panes: [String]) -> [String] {
        guard isOn, picked.contains(source) else { return [] }
        return panes.filter { $0 != source && picked.contains($0) }
    }

    static func banner(count: Int) -> String {
        count < 2 ? "Broadcast is on · tick a second pane to type into more than one" : "Typing into \(count) panes"
    }
}

/// Esc twice in a row (within `window`) stops broadcast.
struct TerminalEscapeTracker {
    static let window: TimeInterval = 0.6
    private var last: Date?

    /// True when this Esc is the second of a pair.
    mutating func press(at now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) <= Self.window { self.last = nil; return true }
        last = now
        return false
    }

    mutating func reset() { last = nil }
}

/// The bytes a terminal would send for a key, for the panes that do not have the keyboard.
enum TerminalBroadcastKeys {
    enum Output: Equatable {
        case bytes([UInt8])
        /// ⌘V: the pasteboard text goes to the others.
        case paste
        case none
    }

    static let escape: UInt8 = 0x1B

    /// `characters` / `plain` are the event's `characters` and `charactersIgnoringModifiers`.
    static func output(keyCode: UInt16, characters: String?, plain: String?, command: Bool, control: Bool, option: Bool, shift: Bool) -> Output {
        if command { return plain?.lowercased() == "v" && !control && !option ? .paste : .none }
        switch keyCode {
        case 36, 76: return .bytes([0x0D])
        case 48: return .bytes(shift ? [escape, 0x5B, 0x5A] : [0x09])
        case 51: return .bytes([0x7F])
        case 53: return .bytes([escape])
        case 117: return .bytes(csi("3~"))
        case 123: return .bytes(csi("D"))
        case 124: return .bytes(csi("C"))
        case 125: return .bytes(csi("B"))
        case 126: return .bytes(csi("A"))
        case 115: return .bytes(csi("H"))
        case 119: return .bytes(csi("F"))
        case 116: return .bytes(csi("5~"))
        case 121: return .bytes(csi("6~"))
        default: break
        }
        if control, let scalar = plain?.unicodeScalars.first, plain?.unicodeScalars.count == 1 {
            switch scalar.value {
            case 0x61...0x7A: return .bytes([UInt8(scalar.value & 0x1F)])
            case 0x40...0x5F: return .bytes([UInt8(scalar.value & 0x1F)])
            case 0x20: return .bytes([0])
            default: return .none
            }
        }
        // Option sends Esc before the key (meta), as the terminal does.
        let text = option ? plain : characters
        guard let text, !text.isEmpty, text.unicodeScalars.allSatisfy({ !(0xF700...0xF8FF).contains($0.value) && $0.value >= 0x20 && $0.value != 0x7F }) else { return .none }
        return .bytes((option ? [escape] : []) + Array(text.utf8))
    }

    static func pasteBytes(_ text: String) -> [UInt8] {
        Array(text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r").utf8)
    }

    private static func csi(_ tail: String) -> [UInt8] { [escape, 0x5B] + Array(tail.utf8) }
}

/// What the router writes to: `TentacldClient`'s session write.
protocol TerminalWriting: AnyObject {
    func write(id: String, data: Data) async throws
}

extension TentacldClient: TerminalWriting {}

/// Copies input to the other panes' sessions with the existing `write`, in order per session (a slow write does not let a later one pass).
@MainActor
final class TerminalBroadcastRouter {
    private let writer: TerminalWriting
    private var tails: [String: Task<Void, Never>] = [:]

    init(writer: TerminalWriting) { self.writer = writer }

    func send(_ bytes: [UInt8], to targets: [String]) {
        guard !bytes.isEmpty else { return }
        let data = Data(bytes)
        for id in targets {
            let previous = tails[id]
            tails[id] = Task { [writer] in
                await previous?.value
                try? await writer.write(id: id, data: data)
            }
        }
    }

    /// Waits until everything sent so far is written (tests).
    func settle() async { for task in tails.values { await task.value } }
}
