import Foundation

/// One line of a project's decision log: who decided what for which agent, and why.
struct DecisionRecord: Codable, Equatable, Identifiable {
    enum By: String, Codable { case pm, you }
    enum Result: String, Codable {
        /// The answer was sent to the agent.
        case answered
        /// Shadow mode: the PM's answer was shown, not sent.
        case suggested
        /// The question went to the user.
        case escalated
    }

    var id: String
    let time: Date
    let cardID: String
    let agent: String
    let kind: String
    /// The question, shortened.
    let question: String
    let by: By
    let result: Result
    /// The option label or typed text that was (or would have been) sent.
    let answer: String
    let why: String
    var costUSD: Double? = nil

    /// The line the PM reads about this decision in later calls.
    var promptLine: String {
        let who = by == .pm ? "PM" : "User"
        switch result {
        case .answered: return "\(who) answered \"\(question)\" with \"\(answer)\"" + (why.isEmpty ? "" : " (\(why))")
        case .suggested: return "PM suggested \"\(answer)\" for \"\(question)\""
        case .escalated: return "\"\(question)\" was escalated to the user" + (why.isEmpty ? "" : " (\(why))")
        }
    }
}

/// An append-only JSON-lines file per project. Writing never blocks the decision it records; unreadable lines are skipped.
final class DecisionLog: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()
    /// Every record as last decoded, with the file's size and modification time then: the file is read and decoded again only when it changed
    /// (the Dashboard and the PM's authority ask for the recent records on every draw).
    private var cache: (size: Int, modified: Date, records: [DecisionRecord])?

    init(fileURL: URL) { self.fileURL = fileURL }

    func append(_ record: DecisionRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        cache = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) { try Data().write(to: fileURL) }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // The log is a record, not a gate; ignore failures.
        }
    }

    /// The newest records last; `cardID` keeps one card's records only.
    func recent(limit: Int, cardID: String? = nil) -> [DecisionRecord] {
        let all = records()
        return Array(all.filter { cardID == nil || $0.cardID == cardID }.suffix(limit))
    }

    private func records() -> [DecisionRecord] {
        lock.lock(); defer { lock.unlock() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0, modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        if let cache, cache.size == size, cache.modified == modified { return cache.records }
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = text.split(separator: "\n").compactMap { try? decoder.decode(DecisionRecord.self, from: Data($0.utf8)) }
        cache = (size, modified, all)
        return all
    }
}
