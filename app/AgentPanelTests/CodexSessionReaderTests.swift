import XCTest
@testable import AgentPanel

final class CodexSessionReaderTests: XCTestCase {
    private func temp() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func json(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func meta(_ id: String, _ cwd: String) -> String {
        json(["type": "session_meta", "timestamp": "2026-10-19T10:00:00.000Z", "payload": ["id": id, "cwd": cwd]])
    }
    private func message(_ role: String, _ text: String, _ t: String = "2026-10-19T10:00:01.000Z") -> String {
        json(["type": "response_item", "timestamp": t, "payload": ["type": "message", "role": role,
              "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]]]])
    }
    private func call(_ name: String, _ id: String) -> String {
        json(["type": "response_item", "timestamp": "2026-10-19T10:00:02.000Z", "payload": ["type": "function_call", "name": name, "call_id": id]])
    }
    private func tokens(total: [String: Int], primary: (Double, Double, Double)? = nil, secondary: (Double, Double, Double)? = nil) -> String {
        var limits: [String: Any] = [:]
        if let p = primary { limits["primary"] = ["used_percent": p.0, "window_minutes": p.1, "resets_at": p.2] }
        if let s = secondary { limits["secondary"] = ["used_percent": s.0, "window_minutes": s.1, "resets_at": s.2] }
        return json(["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": total], "rate_limits": limits]])
    }

    /// A session file under `root/2026/10/19`.
    @discardableResult
    private func session(_ root: URL, id: String, cwd: String, lines: [String], day: String = "19") throws -> URL {
        let dir = root.appendingPathComponent("2026/10/\(day)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-10-\(day)T10-00-00-\(id).jsonl")
        try ([meta(id, cwd)] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFindsASessionByIdAndByWorktree() throws {
        let root = try temp().resolvingSymlinksInPath()
        let a = try session(root, id: "aaaa-1111", cwd: "/w/a", lines: [])
        let b = try session(root, id: "bbbb-2222", cwd: "/w/b", lines: [], day: "18")
        XCTAssertEqual(CodexSessionReader.find(root: root, sessionID: "bbbb-2222", cwd: nil)?.resolvingSymlinksInPath(), b.resolvingSymlinksInPath())
        XCTAssertEqual(CodexSessionReader.find(root: root, sessionID: nil, cwd: "/w/a")?.resolvingSymlinksInPath(), a.resolvingSymlinksInPath())
        XCTAssertEqual(CodexSessionReader.find(root: root, sessionID: "nope", cwd: "/w/b")?.resolvingSymlinksInPath(), b.resolvingSymlinksInPath())
        XCTAssertNil(CodexSessionReader.find(root: root, sessionID: "nope", cwd: "/w/none"))
        XCTAssertNil(CodexSessionReader.find(root: try temp().appendingPathComponent("missing"), sessionID: "x", cwd: "/w/a"))
    }

    func testTurnsResponseItemsIntoChatLines() throws {
        let root = try temp()
        let url = try session(root, id: "s1", cwd: "/w/a", lines: [
            message("developer", "sandbox rules"),
            message("user", "<environment_context>cwd</environment_context>"),
            message("user", "Please fix the bug"),
            call("shell", "c1"), call("shell", "c2"), call("apply_patch", "c3"),
            message("assistant", "Done, the bug is fixed."),
            message("user", "Your task card: /x/N1.md"),
            json(["type": "event_msg", "payload": ["type": "user_message", "message": "Please fix the bug"]]),
        ])
        var r = CodexSessionReader(url: url)
        XCTAssertTrue(r.poll())
        XCTAssertEqual(r.entries.map(\.kind), [.user, .tools, .agent, .panel])
        XCTAssertEqual(r.entries[0].text, "Please fix the bug")
        XCTAssertEqual(r.entries[1].text, "ran 2 commands, edited 1 time")
        XCTAssertEqual(r.entries[2].text, "Done, the bug is fixed.")
        XCTAssertNotNil(r.entries[0].time)
        XCTAssertFalse(r.poll())
    }

    func testUserMessageAttachmentLinesBecomeChipsAndThumbnails() throws {
        let root = try temp()
        let text = "check these\n[Image: /att/demo/a.png]\n[File: /Users/me/dump.bin]\n[Folder: /Users/me/design]"
        let url = try session(root, id: "a1", cwd: "/w", lines: [message("user", text)])
        var r = CodexSessionReader(url: url, attachmentsRoot: URL(fileURLWithPath: "/att"))
        XCTAssertTrue(r.poll())
        XCTAssertEqual(r.entries[0].text, "check these")
        XCTAssertEqual(r.entries[0].images, [.file("/att/demo/a.png")])
        XCTAssertEqual(r.entries[0].files, [ChatFile(path: "/Users/me/dump.bin", folder: false, copied: false),
                                            ChatFile(path: "/Users/me/design", folder: true, copied: false)])
    }

    func testPollReadsOnlyWhatWasAddedAndWaitsForTheEndOfALine() throws {
        let root = try temp()
        let url = try session(root, id: "s2", cwd: "/w/a", lines: [message("user", "one")])
        var r = CodexSessionReader(url: url)
        XCTAssertTrue(r.poll())
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        let next = message("assistant", "two")
        h.write(Data(next.prefix(20).utf8))
        XCTAssertFalse(r.poll())
        h.write(Data((String(next.dropFirst(20)) + "\n").utf8))
        try h.close()
        XCTAssertTrue(r.poll())
        XCTAssertEqual(r.entries.map(\.text), ["one", "two"])
    }

    func testReadsTheLastCumulativeTokensAndTheWindows() throws {
        let root = try temp()
        let t = 1_800_000_000.0
        let url = try session(root, id: "s3", cwd: "/w/a", lines: [
            json(["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]]),
            tokens(total: ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10, "total_tokens": 110], primary: (5, 300, t), secondary: (2, 10080, t + 99)),
            tokens(total: ["input_tokens": 1000, "cached_input_tokens": 600, "cache_write_input_tokens": 7, "output_tokens": 50, "reasoning_output_tokens": 20, "total_tokens": 1050],
                   primary: (12.5, 300, t + 60), secondary: (3, 10080, t + 120)),
        ])
        let u = try XCTUnwrap(CodexSessionReader.usage(url))
        XCTAssertEqual(u.tokens, TokenUsage(input: 400, output: 50, cacheWrite: 7, cacheRead: 600))
        XCTAssertEqual(u.model, "gpt-5.6-sol")
        XCTAssertEqual(u.fiveHour, PlanUsage.Window(percent: 12.5, resetsAt: Date(timeIntervalSince1970: t + 60)))
        XCTAssertEqual(u.week, PlanUsage.Window(percent: 3, resetsAt: Date(timeIntervalSince1970: t + 120)))
        XCTAssertNil(CodexSessionReader.usage(try session(root, id: "s4", cwd: "/w/a", lines: [message("user", "hi")])))
    }

    func testCodexCostIsTokensOnlyNotUnknown() throws {
        let root = try temp(), claude = try temp()
        try session(root, id: "s5", cwd: "/w/task", lines: [tokens(total: ["input_tokens": 500, "cached_input_tokens": 100, "output_tokens": 30])])
        try session(root, id: "s6", cwd: "/w/other", lines: [tokens(total: ["input_tokens": 9, "output_tokens": 9])])
        let c = try XCTUnwrap(CostReader.taskCost(projectsRoot: claude, codexRoot: root, tool: .codex, worktree: "/w/task", since: nil))
        XCTAssertEqual(c.usage, TokenUsage(input: 400, output: 30, cacheWrite: 0, cacheRead: 100))
        XCTAssertTrue(c.isTokensOnly)
        XCTAssertNil(c.dollars)
        XCTAssertEqual(AgentFacts.make(role: nil, cost: c, hasAgent: true).cost, "tokens only")
        // Claude's tool never reads Codex's files.
        XCTAssertNil(CostReader.taskCost(projectsRoot: claude, codexRoot: root, tool: .claude, worktree: "/w/task", since: nil))
    }

    func testStatsCountsCodexTasksAsTokensOnly() {
        var cost = SessionCost(); cost.tokensOnly = TokenUsage(input: 5)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var card = TaskCard(id: "N1", project: "p", status: .done, agent: nil, branch: nil, kind: nil, files: [], title: "Title", sections: [:], url: URL(fileURLWithPath: "/tmp/N1.md"))
        card.modified = now
        let s = Stats.compute(cards: [card], events: [], costs: ["N1": CardCost(agent: nil, pm: 0, session: cost)], now: now)
        XCTAssertEqual(s.tokensOnlyTasks, 1)
        XCTAssertEqual(s.unknownCostTasks, 0)
        XCTAssertTrue(s.rows.first?.tokensOnly == true)
    }

    func testUsageReaderPicksTheNewestCodexWindowThatHasNotReset() throws {
        let root = try temp()
        let now = Date(timeIntervalSince1970: 1_800_000_000), t = now.timeIntervalSince1970
        try session(root, id: "old", cwd: "/w/a", lines: [tokens(total: ["input_tokens": 1], primary: (90, 300, t - 10), secondary: (50, 10080, t - 5))], day: "17")
        try session(root, id: "new", cwd: "/w/a", lines: [tokens(total: ["input_tokens": 1], primary: (20, 300, t + 600), secondary: (30, 10080, t + 9000))])
        let u = try XCTUnwrap(UsageReader.readCodex(root: root, now: now))
        XCTAssertEqual(u.fiveHour?.percent, 20)
        XCTAssertEqual(u.week?.percent, 30)
        XCTAssertEqual(u.todayCost, 0)
        XCTAssertNil(UsageReader.readCodex(root: try temp(), now: now))
    }

    func testSessionTranscriptPicksTheReaderByTool() throws {
        let codex = try temp(), claude = try temp()
        try session(codex, id: "s7", cwd: "/w/a", lines: [message("user", "hello")])
        var t = try XCTUnwrap(SessionTranscript.make(tool: .codex, cwd: "/w/a", session: "s7", projectsRoot: claude, codexRoot: codex))
        XCTAssertTrue(t.poll())
        XCTAssertEqual(t.entries.map(\.text), ["hello"])
        XCTAssertNil(SessionTranscript.make(tool: .codex, cwd: "/w/zzz", session: "missing", projectsRoot: claude, codexRoot: codex))
        guard case .claude = try XCTUnwrap(SessionTranscript.make(tool: .claude, cwd: "/w/a", session: "s", projectsRoot: claude, codexRoot: codex)) else { return XCTFail("expected the Claude reader") }
    }

    func testKeyNoticeAndThePMsTickAreHidden() throws {
        let root = try temp()
        let url = try session(root, id: "pm-1", cwd: "/repo", lines: [
            message("user", "Panel: new authority key abc"), message("assistant", "✓"),
            message("user", "hello"), message("assistant", "✓")])
        var r = CodexSessionReader(url: url)
        XCTAssertTrue(r.poll())
        XCTAssertEqual(r.entries.map(\.text), ["hello", "✓"], "only the tick right after the notice is dropped")
    }
}
