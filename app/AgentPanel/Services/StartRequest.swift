import Foundation

/// A request from the PM to start tasks the user asked for in the Command box (`scripts/request-start.sh` writes it).
struct StartRequest: Codable, Equatable {
    let id: String
    let requestedBy: String
    /// The user's own words that asked for the start; the panel looks for them among the messages it sent for the user. May be empty (the PM's standing authority).
    let userWords: String
    let cards: [String]
    /// The secret of the PM's session (`--key`); the standing authority is used only when it matches. Never kept past reading the request.
    var key: String? = nil
}

/// One file in the requests folder: the request, or why it cannot be read.
struct PendingStartRequest: Equatable {
    let url: URL
    let request: StartRequest?
    let problem: String?
    var id: String { request?.id ?? url.deletingPathExtension().lastPathComponent }
}

/// `<dataDir>/.tentacl/start-requests/`: the PM writes a request there, the panel reads it once and deletes it.
struct StartRequestStore {
    static let maxBytes = 16_000
    static let maxCards = 8
    let dir: URL

    init(dir: URL) { self.dir = dir }
    init(dataDir: URL) { dir = dataDir.appendingPathComponent(".tentacl/start-requests") }
    /// The PM's approve requests have the same shape and their own folder.
    init(approveDataDir: URL) { dir = approveDataDir.appendingPathComponent(".tentacl/approve-requests") }

    /// The `*.json` files, oldest name first. Anything else (the script's temporary file) is not a request yet.
    func pending() -> [PendingStartRequest] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        return names.map { read(dir.appendingPathComponent($0)) }
    }

    private func read(_ url: URL) -> PendingStartRequest {
        func bad(_ why: String) -> PendingStartRequest { PendingStartRequest(url: url, request: nil, problem: why) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { return bad("the request is not a plain file") }
        guard (attributes[.size] as? Int ?? 0) <= Self.maxBytes else { return bad("the request file is too large") }
        guard let data = try? Data(contentsOf: url), let request = try? JSONDecoder().decode(StartRequest.self, from: data) else { return bad("the request file cannot be read (expected id, requestedBy, userWords, cards)") }
        guard request.requestedBy == "pm" else { return bad("only the PM may ask for a start (requestedBy is \"\(request.requestedBy)\")") }
        guard !request.cards.isEmpty else { return bad("the request names no card") }
        guard request.cards.count <= Self.maxCards, request.cards.allSatisfy(TaskInput.validTaskID) else { return bad("the request names more than \(Self.maxCards) cards or a card id that is not a plain name") }
        return PendingStartRequest(url: url, request: request, problem: nil)
    }

    func remove(_ pending: PendingStartRequest) { try? FileManager.default.removeItem(at: pending.url) }
}
