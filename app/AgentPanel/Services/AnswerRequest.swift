import Foundation

/// The PM's answer to a relayed question (`scripts/answer-question.sh` writes it to `<data folder>/.tentacl/answer-requests/`).
struct AnswerRequest: Codable, Equatable {
    let id: String
    let requestedBy: String
    /// `<card id>-q<n>`, as the QUESTION line named it.
    let question: String
    /// An option number, or the PM's own words for a question that takes typed text.
    let answer: String
    var key: String? = nil

    static func validQuestionID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}-q[0-9]{1,6}$"#, options: .regularExpression) != nil }
}

struct PendingAnswerRequest: Equatable {
    let url: URL
    let request: AnswerRequest?
    let problem: String?
    var id: String { request?.id ?? url.deletingPathExtension().lastPathComponent }
}

/// `<dataDir>/.tentacl/answer-requests/`: the PM writes a request there, the panel reads it once and deletes it.
struct AnswerRequestStore {
    static let maxBytes = 16_000
    let dir: URL
    init(dataDir: URL) { dir = dataDir.appendingPathComponent(".tentacl/answer-requests") }

    func pending() -> [PendingAnswerRequest] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        return names.map { read(dir.appendingPathComponent($0)) }
    }

    private func read(_ url: URL) -> PendingAnswerRequest {
        func bad(_ why: String) -> PendingAnswerRequest { PendingAnswerRequest(url: url, request: nil, problem: why) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { return bad("the request is not a plain file") }
        guard (attributes[.size] as? Int ?? 0) <= Self.maxBytes else { return bad("the request file is too large") }
        guard let data = try? Data(contentsOf: url), let request = try? JSONDecoder().decode(AnswerRequest.self, from: data) else { return bad("the request file cannot be read (expected id, requestedBy, question, answer)") }
        guard request.requestedBy == "pm" else { return bad("only the PM may answer a question (requestedBy is \"\(request.requestedBy)\")") }
        guard AnswerRequest.validQuestionID(request.question) else { return bad("\"\(request.question)\" is not a question id like N12-q1") }
        guard !request.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return bad("the request has no answer") }
        return PendingAnswerRequest(url: url, request: request, problem: nil)
    }

    func remove(_ pending: PendingAnswerRequest) { try? FileManager.default.removeItem(at: pending.url) }
}
