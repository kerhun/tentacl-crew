import XCTest
@testable import AgentPanel

/// Several questions in one AskUserQuestion call (N188): the call read from the session file, the window's picks, Send through the fake pane.
@MainActor
final class AskCallTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }

    // MARK: the session file

    static func jsonLine(_ questions: [(header: String, question: String, options: [String], multi: Bool)], id: String = "toolu_1") -> String {
        let qs = questions.map { q in
            let os = q.options.map { "{\"label\":\"\($0)\",\"description\":\"\($0) detail\"}" }.joined(separator: ",")
            return "{\"question\":\"\(q.question)\",\"header\":\"\(q.header)\",\"multiSelect\":\(q.multi),\"options\":[\(os)]}"
        }.joined(separator: ",")
        return "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[\(qs)]}}]}}"
    }
    static let result = { (id: String) in "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"Your questions have been answered\",\"tool_use_id\":\"\(id)\"}]}}" }
    static let three = jsonLine([("Colour", "Colour?", ["Red", "Green"], false), ("Size", "Size?", ["Small", "Large"], false), ("Shape", "Shape?", ["Round", "Square"], false)])
    static let two = jsonLine([("Colour", "Colour?", ["Red", "Green"], false), ("Size", "Size?", ["Small", "Large"], false)])

    func testThePendingCallHasEveryQuestionWithItsHeaderAndOptions() throws {
        let call = try XCTUnwrap(AskCallReader.parse("{\"type\":\"user\"}\n" + Self.three + "\n"))
        XCTAssertEqual(call.items.map(\.header), ["Colour", "Size", "Shape"])
        XCTAssertEqual(call.items.map(\.question), ["Colour?", "Size?", "Shape?"])
        XCTAssertEqual(call.items[1].options.map(\.label), ["Small", "Large"])
        XCTAssertEqual(call.items[1].options.map(\.description), ["Small detail", "Large detail"])
        XCTAssertEqual(call.title, "3 questions · Colour · Size · Shape")
    }

    func testAnAnsweredCallIsNotPendingAndTheLastOneWins() {
        XCTAssertNil(AskCallReader.parse(Self.three + "\n" + Self.result("toolu_1") + "\n"))
        let later = AskCallReader.parse(Self.three + "\n" + Self.result("toolu_1") + "\n" + Self.jsonLine([("A", "A?", ["x", "y"], false), ("B", "B?", ["x", "y"], false)], id: "toolu_2") + "\n")
        XCTAssertEqual(later?.items.map(\.header), ["A", "B"])
        XCTAssertNil(AskCallReader.parse("not json\n{\"type\":\"user\"}\n"))
    }

    func testTheFileIsReadFromItsEnd() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("s.jsonl")
        let filler = String(repeating: "{\"type\":\"user\",\"message\":{\"content\":\"" + String(repeating: "x", count: 500) + "\"}}\n", count: 50)
        try (filler + Self.two + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AskCallReader.pending(at: url, tail: 4_000)?.items.count, 2, "a short tail still holds the last call")
        XCTAssertNil(AskCallReader.pending(at: dir.url.appendingPathComponent("missing.jsonl")))
    }

    // MARK: the window's picks

    func testAnAnswerMovesToTheNextQuestionAndTheLastOneShowsTheSummary() {
        var d = CallDraft(count: 3)
        XCTAssertEqual(d.step, 0)
        d.choose(.option(2)); XCTAssertEqual(d.step, 1)
        d.choose(.text("Teal")); XCTAssertEqual(d.step, 2)
        XCTAssertNil(d.complete)
        d.choose(.option(1)); XCTAssertTrue(d.isSummary)
        XCTAssertEqual(d.complete, [.option(2), .text("Teal"), .option(1)])
    }

    func testBackAndForthKeepsAnswersAndForwardNeedsAnAnswer() {
        var d = CallDraft(count: 3)
        d.move(by: 1); XCTAssertEqual(d.step, 0, "no skipping an unanswered question")
        d.move(by: -1); XCTAssertEqual(d.step, 0)
        d.choose(.option(1)); d.choose(.option(2))
        d.move(by: -1); XCTAssertEqual(d.step, 1)
        d.move(by: -1); XCTAssertEqual(d.step, 0)
        d.choose(.option(2))  // changes the first answer and moves on
        XCTAssertEqual(d.step, 1)
        XCTAssertEqual(d.answers, [.option(2), .option(2), nil])
        d.move(by: 1); XCTAssertEqual(d.step, 2)
        d.move(by: 1); XCTAssertEqual(d.step, 2, "the summary only after the last question is answered")
        d.choose(.option(1)); d.move(by: -1); XCTAssertEqual(d.step, 2)
        d.move(by: 1); XCTAssertTrue(d.isSummary)
        d.move(by: 1); XCTAssertTrue(d.isSummary)
    }

    func testTheKeyHintsFollowTheStep() {
        var d = CallDraft(count: 2)
        XCTAssertEqual(QuestionFocusContent.callHint(d, options: 3), "1–3 answers · → next · Esc later")
        d.choose(.option(1))
        XCTAssertEqual(QuestionFocusContent.callHint(d, options: 2), "1–2 answers · ←/→ back and forth · Esc later")
        d.choose(.option(1))
        XCTAssertEqual(QuestionFocusContent.callHint(d, options: 2), "Enter sends all answers · ← back · Esc later")
    }

    // MARK: the inbox

    /// A pane whose screen follows what was sent: after the k-th key or text the screen is `screens[after[k-1]]`.
    private final class ScriptedPane: TerminalReading, TerminalKeySending, TerminalCommanding, @unchecked Sendable {
        private let lock = NSLock()
        let screens: [String]
        let after: [Int]
        private var index = 0
        private var e: [String] = []
        var events: [String] { lock.lock(); defer { lock.unlock() }; return e }
        init(_ screens: [String], after: [Int]) { self.screens = screens; self.after = after }
        func screen(of target: String, lines: Int) async throws -> String { lock.lock(); defer { lock.unlock() }; return screens[index] }
        private func record(_ s: String) { lock.lock(); e.append(s); if e.count <= after.count { index = after[e.count - 1] }; lock.unlock() }
        func sendKeys(target: String, keys: [String]) async throws { record("keys:" + keys.joined(separator: ",")) }
        func sendText(target: String, text: String) async throws { record("text:" + text) }
        func prompt(target: String, text: String) async throws { record("prompt:" + text) }
    }

    private var dir: TempDir!
    override func setUpWithError() throws { dir = try TempDir() }

    private let worktrees = URL(fileURLWithPath: "/repo/.agent-worktrees")
    private func pm(_ state: AgentState = .blocked) -> AgentStatus {
        var a = AgentStatus(paneID: "w9:pm", workspaceID: "w9", state: state, cwd: "/repo", title: "t", sessionID: "spm")
        a.changeSeq = 1
        return a
    }
    private func writeSession(_ lines: String...) throws {
        let url = TranscriptReader.path(projectsRoot: dir.url, cwd: "/repo", session: "spm")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private func inbox(_ pane: ScriptedPane) -> AgentInboxModel {
        let m = AgentInboxModel(reader: pane, keys: pane, commander: pane, adapter: FakeTerminal(agentsResult: .success([pm()])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        m.claudeProjectsRoot = dir.url
        m.callWait = (.milliseconds(1), 3)
        return m
    }
    /// `typing`: the user is typing to the PM's pane on the Terminals screen.
    private func refresh(_ m: AgentInboxModel, typing: Bool = false) async {
        m.typingPane = typing ? pm().paneID : nil
        await m.refresh(agents: [pm()], cards: [], projectWorktrees: worktrees, pm: pm(), pmProject: "d", label: { _ in "PM" })
    }
    private let threeSteps = ["choice-tabs3-1.txt", "choice-tabs3-2.txt", "choice-tabs3-3.txt", "choice-tabs3-4-submit.txt", "choice-tabs3-5-after.txt"]

    private func threeQuestionPane(after: [Int] = [0, 1, 2, 3, 4]) throws -> ScriptedPane { ScriptedPane(try threeSteps.map(fixture), after: after) }

    func testAThreeQuestionCallIsOneItemForAllQuestions() async throws {
        try writeSession(Self.three)
        let m = inbox(try threeQuestionPane())
        await refresh(m)
        XCTAssertEqual(m.questions.count, 1)
        let q = try XCTUnwrap(m.questions.first).question
        XCTAssertEqual(q.title, "3 questions · Colour · Size · Shape")
        XCTAssertEqual(q.call?.items.count, 3)
        XCTAssertEqual(q.text, "Colour?\nSize?\nShape?")
        XCTAssertFalse(q.terminalOnly)
        XCTAssertEqual(QuestionFocusContent(try XCTUnwrap(m.questions.first)).answers.count, 0, "no single-question buttons: the window steps through them")
    }

    func testWithoutAReadableCallEachTabStaysItsOwnQuestion() async throws {
        let m = inbox(try threeQuestionPane())
        await refresh(m)  // no session file
        XCTAssertNil(m.questions.first?.question.call)
        XCTAssertEqual(m.questions.first?.question.step, 1)
        // A call of other questions, a multiSelect call and a screen that is not on the first tab do not match either.
        try writeSession(AskCallTests.jsonLine([("A", "A?", ["x", "y"], false), ("B", "B?", ["x", "y"], false)]))
        let other = inbox(try threeQuestionPane())
        await refresh(other)
        XCTAssertNil(other.questions.first?.question.call)
        try writeSession(AskCallTests.jsonLine([("Colour", "Colour?", ["Red", "Green"], true), ("Size", "Size?", ["Small", "Large"], false), ("Shape", "Shape?", ["Round", "Square"], false)]))
        let multi = inbox(try threeQuestionPane())
        await refresh(multi)
        XCTAssertNil(multi.questions.first?.question.call)
        try writeSession(Self.three)
        let started = inbox(ScriptedPane([try fixture("choice-tabs3-2.txt")], after: []))
        await refresh(started)
        XCTAssertNil(started.questions.first?.question.call, "one tab already answered: the rest is asked tab by tab")
        XCTAssertEqual(started.questions.first?.question.step, 2)
        try writeSession(Self.three, Self.result("toolu_1"))
        let done = inbox(try threeQuestionPane())
        await refresh(done)
        XCTAssertNil(done.questions.first?.question.call, "an answered call is not pending")
    }

    func testSendPressesEachAnswerThenSubmitAndNothingBeforeSend() async throws {
        try writeSession(Self.three)
        let pane = try threeQuestionPane()
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(pane.events, [], "looking and picking send nothing")
        m.chooseInCall(q, .option(2)); m.chooseInCall(q, .option(1)); m.chooseInCall(q, .option(2))
        XCTAssertEqual(pane.events, [])
        XCTAssertTrue(try XCTUnwrap(m.callDraft(for: q)).isSummary)
        let sent = await m.answerCall(q, answers: try XCTUnwrap(m.callDraft(for: q)?.complete))
        XCTAssertTrue(sent)
        XCTAssertEqual(pane.events, ["keys:left,left,left", "keys:2", "keys:1", "keys:2", "keys:1"], "back to the first tab, then Green, Small, Square, then Submit answers")
        XCTAssertTrue(m.questions.isEmpty)
        XCTAssertNil(m.callDrafts[q.id], "the picks are gone after Send")
    }

    func testOwnWordsPressTypeSomethingTypeTheTextAndEnter() async throws {
        try writeSession(Self.two)
        let screens = try ["choice-tabs2-1.txt", "choice-tabs2-typing.txt", "choice-tabs2-2.txt", "choice-tabs2-3-submit.txt", "choice-tabs3-5-after.txt"].map(fixture)
        let pane = ScriptedPane(screens, after: [0, 1, 1, 2, 3, 4])
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(q.question.call?.items.count, 2)
        let sent = await m.answerCall(q, answers: [.text("Teal"), .option(2)])
        XCTAssertTrue(sent, m.error ?? "")
        XCTAssertEqual(pane.events, ["keys:left,left", "keys:3", "text:Teal", "keys:enter", "keys:2", "keys:1"])
    }

    func testAChangedScreenRefusesToSendAnything() async throws {
        try writeSession(Self.three)
        for changed in ["choice-tabs3-2.txt", "choice-tabs3-4-submit.txt", "choice-before.txt"] {
            let pane = ScriptedPane([try fixture("choice-tabs3-1.txt"), try fixture(changed)], after: [])
            let m = inbox(pane)
            await refresh(m)
            let q = try XCTUnwrap(m.questions.first)
            // The agent's screen changes (the user answered in the terminal) between the list and Send.
            let moved = ScriptedPane([try fixture(changed)], after: [])
            let m2 = AgentInboxModel(reader: moved, keys: moved, commander: moved, adapter: FakeTerminal(agentsResult: .success([pm()])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log2")))
            m2.callWait = (.milliseconds(1), 2)
            let ok = await m2.answerCall(q, answers: [.option(1), .option(1), .option(1)])
            XCTAssertFalse(ok, changed)
            XCTAssertEqual(moved.events, [], changed)
            XCTAssertTrue(m2.error?.contains("no longer asking that question, so nothing was sent") == true, "\(changed): \(m2.error ?? "")")
        }
    }

    func testItStopsAndSaysWhereWhenTheNextQuestionDoesNotShow() async throws {
        try writeSession(Self.three)
        let pane = try threeQuestionPane(after: [0, 0, 0, 0, 0])  // the screen never moves on
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answerCall(q, answers: [.option(2), .option(1), .option(2)])
        XCTAssertFalse(ok)
        XCTAssertEqual(pane.events, ["keys:left,left,left", "keys:2"], "only the first answer went in")
        let error = try XCTUnwrap(m.error)
        XCTAssertTrue(error.contains("stopped before question 2 of 3 (Size)"), error)
        XCTAssertTrue(error.contains("Everything before that was sent"), error)
    }

    func testItDoesNotSubmitWhenTheReviewStepNeverShows() async throws {
        try writeSession(Self.two)
        let screens = try ["choice-tabs2-1.txt", "choice-tabs2-2.txt", "choice-tabs2-2.txt"].map(fixture)
        let pane = ScriptedPane(screens, after: [0, 1, 2])
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        let ok = await m.answerCall(q, answers: [.option(1), .option(2)])
        XCTAssertFalse(ok)
        XCTAssertEqual(pane.events, ["keys:left,left", "keys:1", "keys:2"], "Submit is never pressed without the Review step on screen")
        XCTAssertTrue(m.error?.contains("stopped before the Review step") == true, m.error ?? "")
    }

    func testAnAnswerThatIsNotAnOptionOrTextIsRefusedUpFront() async throws {
        try writeSession(Self.two)
        let pane = ScriptedPane(try ["choice-tabs2-1.txt"].map(fixture), after: [])
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        let a = await m.answerCall(q, answers: [.option(3), .option(1)])
        let b = await m.answerCall(q, answers: [.text("one\ntwo"), .option(1)])
        let c = await m.answerCall(q, answers: [.option(1)])
        XCTAssertEqual([a, b, c], [false, false, false])
        XCTAssertEqual(pane.events, [])
    }

    func testASingleQuestionMenuIsUnchanged() async throws {
        let pane = ScriptedPane([try fixture("choice-before.txt")], after: [])
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertNil(q.question.call)
        XCTAssertEqual(q.question.tabs, [])
        let option = try XCTUnwrap(q.question.options.first { !$0.isSpecial })
        let ok = await m.answer(q, option: option)
        XCTAssertTrue(ok)
        XCTAssertEqual(pane.events, ["keys:" + option.keys.joined(separator: ",")])
        let none = await m.answerCall(q, answers: [.option(1)])
        XCTAssertFalse(none, "answerCall is only for a call")
    }

    func testTheItemKeepsItsIdWhileTheScreenIsUnchangedAndLosesItsPicksWhenItGoes() async throws {
        try writeSession(Self.three)
        let m = inbox(try threeQuestionPane())
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        m.chooseInCall(q, .option(1))
        await refresh(m)
        XCTAssertEqual(m.questions.first?.id, q.id)
        XCTAssertEqual(m.callDraft(for: q)?.step, 1, "the picks survive a refresh (and closing the window)")
        await m.refresh(agents: [], cards: [], projectWorktrees: worktrees, label: { _ in "" })
        XCTAssertTrue(m.callDrafts.isEmpty)
    }

    // MARK: a pending call is not in the session file (N192)

    /// The real run of N192: a scratch Claude Code agent asked three questions with Turkish headers. While its menu was on screen the
    /// session file held no AskUserQuestion line (Claude Code writes it only after the answer), so the file can never name a pending call.
    private let turkish = ["ask3-tab1.txt", "ask3-tab2.txt", "ask3-tab3.txt", "ask3-review-unanswered.txt", "ask3-typing.txt", "ask3-typed.txt",
                           "ask3-tab2-after-text.txt", "ask3-tab3-after-two.txt", "ask3-review.txt", "choice-tabs3-5-after.txt"]
    private func inboxWithoutSessionFile(_ pane: ScriptedPane) -> AgentInboxModel { inbox(pane) }

    func testTheRealScreenOfAThreeQuestionCallHasTheNamesAndTheTypeSomethingNumber() throws {
        let first = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("ask3-tab1.txt"), state: .blocked))
        XCTAssertEqual(first.tabs, ["Temizlik", "Kurulum", "Sıradaki"])
        XCTAssertEqual(first.options.filter { !$0.isSpecial }.map(\.label), ["Evet, yedekle ve sil", "Hayır, kalsın"])
        XCTAssertEqual(first.typeNumber, 3)
        XCTAssertEqual(first.tabAnswered, [false, false, false])
        let third = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("ask3-tab3.txt"), state: .blocked))
        XCTAssertEqual(third.options.filter { !$0.isSpecial }.count, 3)
        XCTAssertEqual(third.typeNumber, 4)
        let review = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("ask3-review.txt"), state: .blocked))
        XCTAssertTrue(review.isReview)
        XCTAssertNil(review.typeNumber)
    }

    func testTheRealJsonlLineShapeWithNonAsciiHeadersIsRead() throws {
        // The shape of the PM's real line (extra keys, a thinking block before it, Turkish text), without its personal text.
        let line = #"{"parentUuid":"a1","isSidechain":false,"message":{"model":"m","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"AskUserQuestion","input":{"questions":[{"question":"Dosya silinsin mi?","header":"Temizlik","multiSelect":false,"options":[{"label":"Evet, yedekle ve sil","description":"Önce yedek al."},{"label":"Hayır, kalsın","description":"Dokunma."}]},{"question":"Kurulsun mu?","header":"Kurulum","multiSelect":false,"options":[{"label":"Evet, kur","description":"x"},{"label":"Hayır, kalsın","description":"y"}]},{"question":"Sıradaki iş hangisi?","header":"Sıradaki","multiSelect":false,"options":[{"label":"Testleri çalıştır","description":"a"},{"label":"Kodu incele","description":"b"},{"label":"Kodu düzenle","description":"c"}]}]},"caller":{"type":"direct"}}],"stop_reason":"tool_use"},"type":"assistant","timestamp":"2026-10-20T18:09:17.479Z"}"#
        let call = try XCTUnwrap(AskCallReader.parse(#"{"type":"user","message":{"content":"Call the AskUserQuestion tool"}}"# + "\n" + line + "\n"))
        XCTAssertEqual(call.items.map(\.header), ["Temizlik", "Kurulum", "Sıradaki"])
        let screen = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("ask3-tab1.txt"), state: .blocked))
        XCTAssertTrue(call.isFresh(screen))
    }

    func testAPaneTheUserTypesToIsNeverSteppedAndShowsTheTabItIsOn() async throws {
        let pane = ScriptedPane(try turkish.map(fixture), after: [0, 1, 2, 3, 0])
        let m = inbox(pane)
        await refresh(m, typing: true)
        let q = try XCTUnwrap(m.questions.first).question
        XCTAssertNil(q.call)
        XCTAssertEqual(q.tabs, ["Temizlik", "Kurulum", "Sıradaki"])
        await refresh(m, typing: true)
        XCTAssertEqual(pane.events, [], "no key at all while the user is in the pane")
    }

    /// The Terminals screen's message box (N224): typing to the pane in Tentacl holds the stepping.
    func testAPaneTheUserTypesToInTentaclIsNotSteppedUntilTheBoxLetsGo() async throws {
        let pane = ScriptedPane(try turkish.map(fixture), after: [0, 1, 2, 3, 0])
        let m = inbox(pane)
        await refresh(m, typing: true)
        XCTAssertNil(m.questions.first?.question.call)
        XCTAssertEqual(pane.events, [], "no key while the user types to this agent")
        await refresh(m)
        XCTAssertEqual(m.questions.first?.question.call?.items.count, 3)
        XCTAssertEqual(pane.events.first, "keys:left,left,left")
    }


    func testTheCallIsReadOnTheNextRefreshOnceTheUserStopsTypingAndOnlyOnce() async throws {
        let pane = ScriptedPane(try turkish.map(fixture), after: [0, 1, 2, 3, 0])
        let m = inbox(pane)
        await refresh(m, typing: true)
        XCTAssertNil(m.questions.first?.question.call)
        XCTAssertEqual(pane.events, [])
        await refresh(m)   // same state counter: the held answer was not cached
        let call = try XCTUnwrap(m.questions.first?.question.call)
        XCTAssertEqual(call.items.map(\.header), ["Temizlik", "Kurulum", "Sıradaki"])
        XCTAssertEqual(pane.events, ["keys:left,left,left", "keys:right", "keys:right", "keys:right", "keys:left,left,left"])
        await refresh(m, typing: true)    // focus again: the known call is shown, nothing is stepped
        await refresh(m)
        XCTAssertEqual(m.questions.first?.question.call, call)
        XCTAssertEqual(pane.events.count, 5)
    }

    func testWithoutTheCallInTheSessionFileTheTabsAreSteppedThroughAndOneItemRemains() async throws {
        let pane = ScriptedPane(try turkish.map(fixture), after: [0, 1, 2, 3, 0])
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first).question
        XCTAssertEqual(m.questions.count, 1)
        let call = try XCTUnwrap(q.call)
        XCTAssertEqual(call.items.map(\.header), ["Temizlik", "Kurulum", "Sıradaki"])
        XCTAssertEqual(call.items.map(\.question), ["Dosya silinsin mi?", "Kurulsun mu?", "Sıradaki iş hangisi?"])
        XCTAssertEqual(call.items[2].options.map(\.label), ["Testleri çalıştır", "Kodu incele", "Kodu düzenle"])
        XCTAssertEqual(call.items[0].options.first?.description, "Önce yedek al, sonra dosyayı sil.")
        XCTAssertTrue(call.items.allSatisfy(\.canType))
        XCTAssertEqual(q.title, "3 questions · Temizlik · Kurulum · Sıradaki")
        XCTAssertEqual(pane.events, ["keys:left,left,left", "keys:right", "keys:right", "keys:right", "keys:left,left,left"], "only moves between tabs: no digit, no Enter")
        // The same screen on the next refresh is the same call: the tabs are not stepped through again.
        await refresh(m)
        XCTAssertEqual(m.questions.first?.question.call, call)
        XCTAssertEqual(pane.events.count, 5)
    }

    func testTheCallIsReadWhicheverTabIsOnScreen() async throws {
        let screens = try ["ask3-tab2.txt", "ask3-tab1.txt", "ask3-tab2.txt", "ask3-tab3.txt", "ask3-review-unanswered.txt"].map(fixture)
        let pane = ScriptedPane(screens, after: [1, 2, 3, 4, 1])
        let m = inbox(pane)
        await refresh(m)
        XCTAssertEqual(m.questions.first?.question.call?.items.map(\.header), ["Temizlik", "Kurulum", "Sıradaki"])
        XCTAssertEqual(m.questions.first?.question.call?.items.map(\.question).first, "Dosya silinsin mi?", "the first tab first, whatever tab the user left it on")
    }

    func testWhenTheTabsCannotBeSteppedThroughTheTabsStayOwnQuestionsAndTheAgentIsLeftOnItsFirstTab() async throws {
        let pane = ScriptedPane([try fixture("ask3-tab1.txt")], after: [])  // the screen never moves
        let m = inbox(pane)
        await refresh(m)
        XCTAssertNil(m.questions.first?.question.call)
        XCTAssertEqual(m.questions.first?.question.tabs, ["Temizlik", "Kurulum", "Sıradaki"])
        XCTAssertEqual(pane.events, ["keys:left,left,left", "keys:right", "keys:left,left,left"], "nothing but moves, and back to the first tab")
    }

    func testAnAnsweredTabIsNeverSteppedThrough() async throws {
        let pane = ScriptedPane([try fixture("ask3-tab2-after-text.txt")], after: [])
        let m = inbox(pane)
        await refresh(m)
        XCTAssertNil(m.questions.first?.question.call)
        XCTAssertEqual(pane.events, [])
    }

    func testSendFromASteppedCallGoesBackToTheFirstTabTypesOwnWordsAndSubmitsOnce() async throws {
        // refresh: ←, →, →, →, ← ; Send: ←, 3, text, Enter, 1, 2, 1
        let pane = ScriptedPane(try turkish.map(fixture), after: [0, 1, 2, 3, 0, 0, 4, 5, 6, 7, 8, 9])
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(pane.events.count, 5)
        let sent = await m.answerCall(q, answers: [.text("Kendi sözlerim"), .option(1), .option(2)])
        XCTAssertTrue(sent, m.error ?? "")
        XCTAssertEqual(Array(pane.events.dropFirst(5)), ["keys:left,left,left", "keys:3", "text:Kendi sözlerim", "keys:enter", "keys:1", "keys:2", "keys:1"])
        XCTAssertTrue(m.questions.isEmpty)
    }

    func testAnItemWithoutTypeSomethingOffersNoOwnWords() throws {
        let tab = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("choice-tabs3-1.txt"), state: .blocked))
        let plain = AgentQuestion(kind: .choice, title: "t", text: "Q?", options: tab.options.filter { !$0.isSpecial })
        let call = try XCTUnwrap(AskCall.read(headers: ["A", "B"], tabs: [plain, tab]))
        XCTAssertEqual(call.items.map(\.canType), [false, true])
        XCTAssertNil(AskCall.read(headers: ["A", "B"], tabs: [plain]), "every tab must have been read")
    }

    // MARK: own words on a single tab (N192)

    func testOwnWordsOnASingleTabPressTypeSomethingTypeTheTextAndEnter() async throws {
        let pane = ScriptedPane([try fixture("ask3-tab2-after-text.txt")], after: [0, 0, 0])
        let m = inbox(pane)
        await refresh(m)
        let q = try XCTUnwrap(m.questions.first)
        XCTAssertEqual(QuestionFocusContent(q).ownWords, .typed)
        let ok = await m.answerTyped(q, text: "Kendi\nsözlerim ")
        XCTAssertTrue(ok, m.error ?? "")
        XCTAssertEqual(pane.events, ["keys:3", "text:Kendi sözlerim", "keys:enter"])
        let none = await m.answerTyped(q, text: "  ")
        XCTAssertFalse(none)
    }

    // MARK: autopilot and Pass on to the PM

    private func callQuestion() throws -> AgentQuestion {
        let call = try XCTUnwrap(AskCallReader.parse(Self.three))
        return .call(call, from: AgentQuestion(kind: .choice, title: "", text: "x", options: []))
    }

    func testTheAutopilotAnswersAllQuestionsOrNone() throws {
        let q = try callQuestion()
        func decision(_ options: [Int]?, _ verdict: PMDecision.Verdict = .answer, _ confidence: PMDecision.Confidence = .high) -> PMDecision {
            PMDecision(verdict: verdict, options: options, why: "Card says so.", confidence: confidence)
        }
        guard case .sendCall(let picks, let s) = AutopilotRules.outcome(of: decision([2, 1, 2]), for: q) else { return XCTFail("a full set is sent") }
        XCTAssertEqual(picks, [2, 1, 2])
        XCTAssertEqual(s.summary, "Green · Small · Square")
        for bad in [[2, 1], [2, 1, 2, 1], [3, 1, 1], [0, 1, 1], nil] as [[Int]?] {
            guard case .escalate(_, let suggestion) = AutopilotRules.outcome(of: decision(bad), for: q) else { return XCTFail("\(String(describing: bad)) must not be sent") }
            XCTAssertNil(suggestion)
        }
        guard case .escalate(let reason, let kept) = AutopilotRules.outcome(of: decision([1, 1, 1], .answer, .low), for: q) else { return XCTFail() }
        XCTAssertEqual(reason, "PM is not sure.")
        XCTAssertEqual(kept?.summary, "Red · Small · Round")
    }

    func testThePMSeesTheWholeCallAndIsToldToAnswerAllOfIt() throws {
        let request = DecisionRequest(projectName: "P", cardID: "V1", cardText: "card", agentLabel: "Pixel", question: try callQuestion(), earlier: [])
        let text = PMPrompt.message(for: request)
        XCTAssertTrue(text.contains("one call of 3 questions"))
        XCTAssertTrue(text.contains("Question 2 (Size): Size?"))
        XCTAssertTrue(text.contains("  2. Large — Large detail"))
        XCTAssertTrue(PMPrompt.schema.contains("\"options\":{\"type\":\"array\""))
        XCTAssertTrue(PMPrompt.system.contains("Several questions in one call"))
    }

    func testPassOnToThePMNamesEveryQuestionAndItsAnswers() throws {
        let p = PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "Pixel", cardID: "V1", question: try callQuestion())
        let text = passOnToPMText(p)
        XCTAssertTrue(text.contains("asks 3 questions in one call"))
        XCTAssertTrue(text.contains("1. Colour? Answers: 1. Red; 2. Green."))
        XCTAssertTrue(text.contains("3. Shape? Answers: 1. Round; 2. Square."))
    }
}
