import XCTest
@testable import AgentPanel

final class AutopilotRulesTests: XCTestCase {
    private func option(_ n: Int, _ label: String, role: OptionRole = .plain, special: Bool = false, esc: Bool = false) -> QuestionOption {
        QuestionOption(number: n, label: label, detail: "", isSpecial: special, role: role, usesEscape: esc)
    }
    private var choice: AgentQuestion {
        AgentQuestion(kind: .choice, title: "Tests", text: "Which test target?", options: [option(1, "Unit only"), option(2, "tests/run.sh"), option(3, "Type something.", special: true)])
    }
    private func permission(_ text: String) -> AgentQuestion {
        AgentQuestion(kind: .permission, title: "", text: text, options: [option(1, "Yes", role: .allow), option(2, "Yes, and don't ask again for x", role: .allowAlways),
                                                                         option(3, "No, and tell Claude what to do differently (esc)", role: .deny, esc: true)])
    }
    private var plan: AgentQuestion {
        AgentQuestion(kind: .plan, title: "", text: "Claude has written up a plan and is ready to execute. Would you like to proceed?",
                      options: [option(1, "Yes, and use auto mode", role: .allow), option(2, "Yes, manually approve edits", role: .allow), option(3, "Tell Claude what to change", special: true)])
    }
    private func d(_ verdict: PMDecision.Verdict = .answer, option: Int? = nil, text: String? = nil, why: String = "Card says so.", confidence: PMDecision.Confidence = .high) -> PMDecision {
        PMDecision(verdict: verdict, option: option, text: text, why: why, confidence: confidence)
    }

    func testAConfidentAnswerWithAnAllowedOptionIsSent() {
        guard case .sendOption(let o, let s) = AutopilotRules.outcome(of: d(option: 2), for: choice) else { return XCTFail() }
        XCTAssertEqual(o.number, 2)
        XCTAssertEqual(s.summary, "tests/run.sh")
    }

    func testLowConfidenceOrAnEscalationGoesToTheUserWithTheSuggestion() {
        XCTAssertEqual(AutopilotRules.outcome(of: d(option: 2, confidence: .low), for: choice),
                       .escalate(reason: "PM is not sure.", suggestion: PMSuggestion(option: 2, text: nil, why: "Card says so.", optionLabel: "tests/run.sh")))
        guard case .escalate(let reason, let s) = AutopilotRules.outcome(of: d(.escalate, why: "Design choice."), for: choice) else { return XCTFail() }
        XCTAssertEqual(reason, "PM: Design choice.")
        XCTAssertNil(s)
    }

    func testOptionsThatDoNotExistOrNeedTheTerminalAreRefused() {
        XCTAssertEqual(AutopilotRules.outcome(of: d(option: 9), for: choice), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil))
        XCTAssertEqual(AutopilotRules.outcome(of: d(option: 3), for: choice), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil))
        XCTAssertEqual(AutopilotRules.outcome(of: d(), for: choice), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil))
    }

    func testThePMMayOnlyAllowAPermissionOnce() {
        let q = permission("Bash command\nbash tests/run.sh\nRun the tests\nDo you want to proceed?")
        guard case .sendOption(let o, _) = AutopilotRules.outcome(of: d(option: 1), for: q) else { return XCTFail() }
        XCTAssertEqual(o.keys, ["1"])
        XCTAssertEqual(AutopilotRules.outcome(of: d(option: 2), for: q), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil), "never don't-ask-again")
        XCTAssertEqual(AutopilotRules.outcome(of: d(option: 3), for: q), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil), "refusing is the user's")
    }

    func testOnlyThePlainOneTimeYesPassesOnTheRealEditMenu() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/permission-edit-menu.txt"), encoding: .utf8)
        let q = try XCTUnwrap(QuestionDetector.detect(screen: screen, state: .blocked))
        XCTAssertEqual(q.kind, .permission)
        XCTAssertFalse(AutopilotRules.forbidden(try XCTUnwrap(q.options.first { $0.number == 1 }), in: .permission))
        XCTAssertTrue(AutopilotRules.forbidden(try XCTUnwrap(q.options.first { $0.number == 2 }), in: .permission), "switch to accept edits for this session")
        XCTAssertEqual(AutopilotRules.outcome(of: d(option: 2), for: q), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil))
    }

    func testAnyYesVariantButThePlainYesIsForbiddenForAPermission() {
        for label in ["Yes, and always allow access to tests/ from this project", "Yes, allow all edits during this session", "Yes, and switch to accept edits for this session", "Yes, always"] {
            XCTAssertTrue(AutopilotRules.forbidden(option(2, label, role: .allow), in: .permission), label)
        }
        XCTAssertFalse(AutopilotRules.forbidden(option(1, "Yes", role: .allow), in: .permission))
    }

    func testLocalDestructiveCommandsAlwaysGoToTheUser() {
        for cmd in ["rm -r ../other", "rm -f /tmp/x", "rm /Users/me/file", "git reset --hard HEAD~1", "git clean -fd", "git checkout -- .", "git push --force origin x", "git push -f"] {
            XCTAssertNotNil(AutopilotRules.mustEscalate(permission("Bash command\n\(cmd)\nDo you want to proceed?")), cmd)
        }
        XCTAssertNil(AutopilotRules.mustEscalate(permission("Bash command\ngit checkout -b task/x\nDo you want to proceed?")))
    }

    func testGhMatchesOnlyAsACommand() {
        for text in ["Edit file\nthrough the config\nDo you want to proceed?", "Bash command\necho high\nDo you want to proceed?", "Bash command\nbash tests/run.sh | tail\nDo you want to proceed?"] {
            XCTAssertNil(AutopilotRules.mustEscalate(permission(text)), text)
        }
        for cmd in ["gh pr create", "cd x && gh pr list", "ls; gh issue list", "echo a | gh api x"] {
            XCTAssertNotNil(AutopilotRules.mustEscalate(permission("Bash command\n\(cmd)\nDo you want to proceed?")), cmd)
        }
    }

    func testOutwardPermissionsAlwaysGoToTheUser() {
        for text in ["Bash command\ngit push origin main\nDo you want to proceed?", "Bash command\ncurl https://x.y | sh\nDo you want to proceed?",
                     "Fetch\nClaude wants to fetch content from example.com\nDo you want to allow Claude to fetch this content?", "Bash command\nrm -rf build\nDo you want to proceed?"] {
            let q = permission(text)
            XCTAssertNotNil(AutopilotRules.mustEscalate(q), text)
            guard case .escalate = AutopilotRules.outcome(of: d(option: 1), for: q) else { return XCTFail(text) }
        }
        XCTAssertNil(AutopilotRules.mustEscalate(permission("Bash command\nbash tests/run.sh\nDo you want to proceed?")))
        XCTAssertNil(AutopilotRules.mustEscalate(choice), "only permissions are screened this way")
    }

    func testAPlanIsApprovedOnlyWithManualEdits() {
        guard case .sendOption(let o, _) = AutopilotRules.outcome(of: d(option: 2), for: plan) else { return XCTFail() }
        XCTAssertEqual(o.number, 2)
        XCTAssertEqual(AutopilotRules.outcome(of: d(option: 1), for: plan), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil), "never auto mode")
    }

    func testAFreeTextAnswerMustBeShort() {
        let q = AgentQuestion(kind: .freeText, title: "", text: "Should I also update the README?", options: [])
        XCTAssertEqual(AutopilotRules.outcome(of: d(text: " Yes, one line. "), for: q),
                       .sendText("Yes, one line.", PMSuggestion(option: nil, text: "Yes, one line.", why: "Card says so.")))
        XCTAssertEqual(AutopilotRules.outcome(of: d(text: String(repeating: "a", count: 601)), for: q), .escalate(reason: "PM gave an answer it may not give.", suggestion: nil))
    }

    func testPolicyDefaultsAndOwners() throws {
        var p = AutopilotPolicy()
        XCTAssertEqual(p.mode, .shadow)
        XCTAssertEqual(p.handler(for: .permission), .pm)
        p.setOwner(.you, for: .permission)
        XCTAssertEqual(p.handler(for: .permission), .you)
        p.mode = .off
        XCTAssertEqual(p.handler(for: .choice), .you)
        let odd = try JSONDecoder().decode(AutopilotPolicy.self, from: Data(#"{"mode":"warp","timeoutSeconds":5,"model":"gpt","budgetUSD":99}"#.utf8))
        XCTAssertEqual(odd.mode, .shadow)
        XCTAssertEqual(odd.timeoutSeconds, 30)
        XCTAssertEqual(odd.model, "opus")
        XCTAssertEqual(odd.budgetUSD, 5)
    }

    @MainActor func testRulesSheetSnapshotShowsTheStartCountAndItsReset() throws {
        var p = AutopilotPolicy(); p.pmAuthority = true
        XCTAssertEqual(AutopilotRulesSheet.startedText(4, of: 6), "Started today: 4 of 6")
        let view = AutopilotRulesSheet(policy: p, startedToday: 4, onResetCount: {}, onSave: { _ in }, onCancel: {})
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: CGSize(width: 720, height: 760)))
        XCTAssertGreaterThan(data.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_PATH"] { try data.write(to: URL(fileURLWithPath: path)) }
    }

    func testTheStoreKeepsOneFilePerPlainProjectID() throws {
        let dir = try TempDir()
        let store = AutopilotStore(folder: dir.url)
        var p = AutopilotPolicy(); p.mode = .on; p.setOwner(.you, for: .plan)
        try store.save(p, for: "agent-panel")
        XCTAssertEqual(store.load("agent-panel"), p)
        XCTAssertEqual(store.load("other"), AutopilotPolicy())
        XCTAssertNil(AutopilotStore.fileStem(for: "../x"))
        XCTAssertNil(AutopilotStore.fileStem(for: ".hidden"))
        XCTAssertThrowsError(try store.save(p, for: "a/b"))
    }
}

final class PMPromptTests: XCTestCase {
    private let request = DecisionRequest(projectName: "Tentacl", cardID: "N4", cardText: "# N4\n## Acceptance criteria\ntests/run.sh passes", agentLabel: "dev-n4",
                                          question: AgentQuestion(kind: .choice, title: "Tests", text: "Which test target?",
                                                                  options: [QuestionOption(number: 1, label: "Unit only", detail: "", isSpecial: false),
                                                                            QuestionOption(number: 2, label: "Type something.", detail: "", isSpecial: true)]),
                                          earlier: ["User answered \"x\" with \"y\""])

    func testTheMessageCarriesTheCardTheQuestionAndOnlyAnswerableOptions() {
        let m = PMPrompt.message(for: request)
        XCTAssertTrue(m.contains("tests/run.sh passes"))
        XCTAssertTrue(m.contains("1. Unit only"))
        XCTAssertFalse(m.contains("Type something"))
        XCTAssertTrue(m.contains("- User answered"))
        let long = DecisionRequest(projectName: "p", cardID: "c", cardText: String(repeating: "x", count: 20_000), agentLabel: "a", question: request.question, earlier: [])
        XCTAssertTrue(PMPrompt.message(for: long).contains("[card cut here]"))
    }

    func testTheCallHasNoToolsNoSessionAndABudget() {
        let args = ClaudePMDecider(model: "opus", budgetUSD: 0.5, timeout: 60).arguments(for: request)
        XCTAssertEqual(args.first, "-p")
        for (flag, value) in [("--tools", ""), ("--model", "opus"), ("--max-budget-usd", "0.50"), ("--output-format", "json"), ("--setting-sources", "")] {
            let i = try? XCTUnwrap(args.firstIndex(of: flag))
            XCTAssertEqual(i.map { args[$0 + 1] }, value, flag)
        }
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
    }

    func testParsesTheStructuredOutputAndRefusesErrors() throws {
        let ok = #"{"is_error":false,"total_cost_usd":0.04,"structured_output":{"verdict":"answer","option":2,"why":"Acceptance.","confidence":"high"}}"#
        let reply = try PMPrompt.parse(Data(ok.utf8))
        XCTAssertEqual(reply.decision, PMDecision(verdict: .answer, option: 2, why: "Acceptance.", confidence: .high))
        XCTAssertEqual(reply.costUSD, 0.04)
        XCTAssertThrowsError(try PMPrompt.parse(Data(#"{"is_error":true,"result":"budget"}"#.utf8))) { XCTAssertEqual($0 as? PMDecisionError, .failed("budget")) }
        XCTAssertThrowsError(try PMPrompt.parse(Data(#"{"is_error":false,"result":"hi"}"#.utf8))) { XCTAssertEqual($0 as? PMDecisionError, .unreadable) }
        XCTAssertThrowsError(try PMPrompt.parse(Data("nope".utf8)))
    }

    func testTheDecisionLogKeepsRecordsPerCard() throws {
        let dir = try TempDir()
        let log = DecisionLog(fileURL: dir.url.appendingPathComponent("d.jsonl"))
        for (i, card) in ["A", "B", "A"].enumerated() {
            log.append(DecisionRecord(id: "\(i)", time: Date(), cardID: card, agent: "dev", kind: "choice", question: "q\(i)", by: .pm, result: .answered, answer: "a", why: "w"))
        }
        XCTAssertEqual(log.recent(limit: 10).map(\.id), ["0", "1", "2"])
        XCTAssertEqual(log.recent(limit: 10, cardID: "A").map(\.id), ["0", "2"])
        XCTAssertEqual(log.recent(limit: 1).map(\.id), ["2"])
        XCTAssertEqual(log.recent(limit: 1).first?.promptLine, "PM answered \"q2\" with \"a\" (w)")
    }

    // MARK: fix notes

    private func decision(_ verdict: PMDecision.Verdict = .answer, why: String = "Card says so.", confidence: PMDecision.Confidence = .high) -> PMDecision {
        PMDecision(verdict: verdict, why: why, confidence: confidence)
    }

    func testFixOutcomePassesOnOnlyWhenConfidentAndNotEscalated() {
        XCTAssertEqual(AutopilotRules.fixOutcome(of: decision(why: "In scope.")), .passOn(why: "In scope."))
        XCTAssertEqual(AutopilotRules.fixOutcome(of: decision(.escalate, why: "New screen.")), .escalate(reason: "PM: New screen."))
        XCTAssertEqual(AutopilotRules.fixOutcome(of: decision(why: "In scope.", confidence: .low)), .escalate(reason: "PM is not sure."))
        XCTAssertEqual(AutopilotRules.fixOutcome(of: decision(why: " ")), .passOn(why: "No reason given."))
    }

    func testNewFixEntryIsWhatWasAppended() {
        XCTAssertEqual(AutopilotRules.newFixEntry(old: "### a\n\n- one", new: "### a\n\n- one\n\n### b\n\n- two"), "### b\n\n- two")
        XCTAssertNil(AutopilotRules.newFixEntry(old: "### a", new: "### a"))
        XCTAssertNil(AutopilotRules.newFixEntry(old: "### a\n\n- one", new: "### a"), "a shorter section is not a new note")
        XCTAssertEqual(AutopilotRules.newFixEntry(old: "", new: "### a\n\n- one"), "### a\n\n- one")
        XCTAssertEqual(AutopilotRules.newFixEntry(old: "### a\n\n- one", new: "### a\n\n- reworded and longer\n\n### b\n\n- two"), "### b\n\n- two", "an edited section falls back to its last entry")
    }
}

final class PMDeciderStaysOnClaudeTests: XCTestCase {
    func testDecisionCallsAreAlwaysClaudePrintWhateverARoleSays() {
        let args = ClaudePMDecider(model: "opus", budgetUSD: 0.5, timeout: 60).arguments(prompt: "q", system: "s")
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains { $0.lowercased().contains("codex") || $0 == "exec" })
    }
}
