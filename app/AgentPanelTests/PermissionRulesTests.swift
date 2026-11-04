import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

/// N213: "Always allow in this project" rules.
@MainActor
final class PermissionRulesTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent-screens/\(name)"), encoding: .utf8) }
    private let worktrees = URL(fileURLWithPath: "/repo/.agent-worktrees")
    private var dir: TempDir!
    private var reader: AutopilotModelTests.Reader!
    private var sender: AutopilotModelTests.Sender!

    override func setUpWithError() throws { dir = try TempDir(); reader = AutopilotModelTests.Reader(); sender = AutopilotModelTests.Sender() }

    /// The real Bash prompt of Claude Code v2.1.305 (`touch n213-a.txt`), with the command swapped for another.
    private func screen(_ command: String = "touch n213-a.txt") throws -> String {
        try fixture("permission-bash-touch.txt").replacingOccurrences(of: " touch n213-a.txt", with: " " + command)
    }
    private func question(_ command: String = "touch n213-a.txt") throws -> AgentQuestion {
        try XCTUnwrap(QuestionDetector.detect(screen: try screen(command), state: .blocked))
    }

    // MARK: matching

    func testTheDetectorReadsTheCommandBetweenTheDashedLinesNotTheTipOrDescription() throws {
        let q = try question()
        XCTAssertEqual(q.kind, .permission)
        XCTAssertEqual(q.command, "touch n213-a.txt")
        XCTAssertEqual(PermissionRules.pattern(for: q), "Bash(touch:*)")
        XCTAssertEqual(PermissionRules.answer(for: q)?.number, 1, "only the plain one-time Yes; not 'always allow access', not auto mode")
    }

    func testAPatternKeepsTheScriptOrTheSubcommandAndRefusesRunnersAndChains() throws {
        XCTAssertEqual(PermissionRules.pattern(for: try question("scripts/app-test.sh -only-testing:X")), "Bash(scripts/app-test.sh:*)")
        XCTAssertEqual(PermissionRules.pattern(for: try question("bash tests/run.sh")), "Bash(bash tests/run.sh:*)")
        XCTAssertEqual(PermissionRules.pattern(for: try question("git checkout -b task/x")), "Bash(git checkout:*)")
        for bad in ["bash", "bash -c ls", "env FOO=1 ls", "xargs rm", "scripts/a.sh && rm x", "scripts/a.sh | tail", "scripts/a.sh > out", "scripts/a.sh $(whoami)", "FOO=1 scripts/a.sh"] {
            XCTAssertNil(PermissionRules.pattern(for: try question(bad)), bad)
        }
    }

    func testARuleCoversTheSameProgramOnlyAndNothingChainedOn() throws {
        let rule = PermissionRule(pattern: "Bash(scripts/app-test.sh:*)", added: Date())
        XCTAssertTrue(PermissionRules.matches(rule, try question("scripts/app-test.sh")))
        XCTAssertTrue(PermissionRules.matches(rule, try question("scripts/app-test.sh -only-testing:AgentPanelTests/X")))
        XCTAssertFalse(PermissionRules.matches(rule, try question("scripts/app-test.sh-evil")))
        XCTAssertFalse(PermissionRules.matches(rule, try question("scripts/other.sh")))
        XCTAssertFalse(PermissionRules.matches(rule, try question("scripts/app-test.sh; echo hi")))
        XCTAssertFalse(PermissionRules.matches(rule, try question("scripts/app-test.sh `id`")))
        XCTAssertFalse(PermissionRules.matches(PermissionRule(pattern: "Bash(:*)", added: Date()), try question("anything")))
        XCTAssertFalse(PermissionRules.matches(PermissionRule(pattern: "Edit(x:*)", added: Date()), try question("x")))
    }

    func testTheAlwaysYoursNeverMatchOrGetARuleEvenWithAMatchingRule() throws {
        let commands = ["git push origin task/x", "git push -f", "curl https://x.y", "npm install left-pad", "pip install x", "brew install x", "sudo ls", "rm -rf /tmp/x", "rm ../x", "rm ~/x",
                        "gh pr create", "ssh host", "launchctl list", "defaults write a b", "git reset --hard", "scp a b", "cat .env", "git remote add o u"]
        for cmd in commands {
            let q = try question(cmd)
            XCTAssertNotNil(AutopilotRules.mustEscalate(q), cmd)
            XCTAssertNil(PermissionRules.pattern(for: q), "no rule can be made for: \(cmd)")
            let first = cmd.split(separator: " ").first.map(String.init) ?? cmd
            for pattern in ["Bash(\(first):*)", "Bash(\(cmd):*)", "Bash(git:*)"] {
                XCTAssertFalse(PermissionRules.matches(PermissionRule(pattern: pattern, added: Date()), q), "\(pattern) must not cover: \(cmd)")
            }
        }
    }

    func testOnlyBashPromptsGetARule() throws {
        let edit = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("permission-edit-menu.txt"), state: .blocked))
        XCTAssertNil(PermissionRules.pattern(for: edit))
        let fetch = try XCTUnwrap(QuestionDetector.detect(screen: try fixture("permission-fetch-before.txt"), state: .blocked))
        XCTAssertNil(PermissionRules.pattern(for: fetch))
    }

    // MARK: the store

    func testRulesSurviveARestartAndRemovingOneIsSavedAtOnce() throws {
        let store = AutopilotStore(folder: dir.url)
        let a = PermissionRule(pattern: "Bash(touch:*)", added: Date(timeIntervalSince1970: 100))
        let b = PermissionRule(pattern: "Bash(scripts/app-test.sh:*)", added: Date(timeIntervalSince1970: 200))
        try store.saveRules([a, b], for: "demo")
        XCTAssertEqual(store.loadRules("demo"), [a, b])
        XCTAssertEqual(store.rulesURL("demo")?.lastPathComponent, "demo.permissions.json")
        XCTAssertEqual(store.loadRules("other"), [])
        XCTAssertNil(store.rulesURL("../x"))
    }

    // MARK: the autopilot

    private let project = ProjectConfig(id: "demo", name: "Demo", repoPath: "/repo", dataDir: "/data", maxParallel: 2, buildCommand: nil, xcodeProject: nil, simulator: nil, sharedFiles: [], openWith: nil)
    private let agent: AgentStatus = { var a = AgentStatus(paneID: "w1:p1", workspaceID: "w1", state: .blocked, cwd: "/repo/.agent-worktrees/test-v1", title: "t", sessionID: "s1"); a.changeSeq = 1; a.name = "dev-v1"; return a }()
    private var card: TaskCard {
        TaskCard(id: "V1", project: "d", status: .doing, agent: "dev-v1", branch: "test/v1", kind: nil, files: [], title: "V1", sections: [:], url: dir.url.appendingPathComponent("V1.md"))
    }

    private func make(mode: AutopilotMode, permissions: DecisionOwner = .you) throws -> (AutopilotModel, AgentInboxModel, AutopilotStore) {
        let store = AutopilotStore(folder: dir.url.appendingPathComponent("autopilot"))
        var p = AutopilotPolicy(); p.mode = mode; p.setOwner(permissions, for: .permission)
        try store.save(p, for: project.id)
        try "# V1\n## Goal\nx".write(to: card.url, atomically: true, encoding: .utf8)
        let inbox = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([agent])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let decider = AutopilotModelTests.Decider(.failure(PMDecisionError.notInstalled))
        let model = AutopilotModel(inbox: inbox, store: store, makeDecider: { _ in decider })
        model.setProject(project)
        return (model, inbox, store)
    }

    private func tick(_ model: AutopilotModel, _ inbox: AgentInboxModel) async {
        await inbox.refresh(agents: [agent], cards: [card], projectWorktrees: worktrees, label: { _ in "Pixel · V1" })
        model.process(inbox.questions, cards: [card])
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAlwaysAllowAnswersOnceSavesTheRuleAndTheNextMatchingPromptIsAnsweredByIt() async throws {
        reader.screens["w1:p1"] = try screen()
        let (m, inbox, store) = try make(mode: .on)
        await tick(m, inbox)
        let first = try XCTUnwrap(inbox.questions.first)
        XCTAssertEqual(m.forUser(inbox.questions).count, 1, "no rule yet: the user decides")

        let ok = await m.alwaysAllow(first)
        XCTAssertTrue(ok, inbox.error ?? "")
        XCTAssertEqual(sender.keys, [["1"]], "this prompt is answered with the one-time Yes")
        XCTAssertEqual(m.permissionRules.map(\.pattern), ["Bash(touch:*)"])
        XCTAssertEqual(store.loadRules("demo").map(\.pattern), ["Bash(touch:*)"], "saved in the project's autopilot folder")

        // The agent asks again (a new screen): the rule answers by itself.
        reader.screens["w1:p1"] = try screen("touch n213-b.txt")
        await tick(m, inbox)
        await settle { sender.keys.count == 2 }
        XCTAssertEqual(sender.keys, [["1"], ["1"]])
        let r = try XCTUnwrap(m.records.last { $0.result == .answered })
        XCTAssertEqual(r.by, .pm)
        XCTAssertEqual(r.answer, "Yes")
        XCTAssertTrue(r.why.hasPrefix("Allowed by rule Bash(touch:*)"), r.why)
    }

    func testARuleDoesNotAnswerAnythingElseOrWhenTheAutopilotIsOffOrAfterItIsRemoved() async throws {
        let (m, inbox, _) = try make(mode: .on)
        reader.screens["w1:p1"] = try screen()
        await tick(m, inbox)
        _ = await m.alwaysAllow(try XCTUnwrap(inbox.questions.first))
        let sent = sender.keys.count
        let rule = try XCTUnwrap(m.permissionRules.first)

        // another command, and the always-yours
        for cmd in ["rm other.txt", "git push origin x", "touch a; git push"] {
            reader.screens["w1:p1"] = try screen(cmd)
            await tick(m, inbox)
            XCTAssertNil(PermissionRules.rule(for: try question(cmd), in: m.permissionRules), cmd)
        }
        XCTAssertEqual(sender.keys.count, sent)

        m.removeRule(rule)
        XCTAssertEqual(m.permissionRules, [])
        XCTAssertNil(PermissionRules.rule(for: try question("touch n213-a.txt"), in: m.permissionRules))

        // Off: nothing is answered by itself.
        let (off, offInbox, offStore) = try make(mode: .off)
        try offStore.saveRules([rule], for: "demo")
        off.setProject(nil); off.setProject(project)
        reader.screens["w1:p1"] = try screen()
        await tick(off, offInbox)
        XCTAssertEqual(sender.keys.count, sent)
        XCTAssertEqual(off.forUser(offInbox.questions).count, 1)
    }

    func testRemovingARuleActsAtOnceAndIsStoredWhileShadowOnlySuggests() async throws {
        let (m, inbox, store) = try make(mode: .shadow)
        try store.saveRules([PermissionRule(pattern: "Bash(touch:*)", added: Date())], for: "demo")
        m.setProject(nil); m.setProject(project)
        reader.screens["w1:p1"] = try screen()
        await tick(m, inbox)
        let q = try XCTUnwrap(inbox.questions.first)
        XCTAssertEqual(sender.keys, [], "shadow sends nothing")
        XCTAssertEqual(m.suggestion(for: q)?.optionLabel, "Yes")
        XCTAssertEqual(m.records.last?.result, .suggested)
        XCTAssertTrue(m.records.last?.why.contains("Allowed by rule Bash(touch:*)") == true)

        m.removeRule(try XCTUnwrap(m.permissionRules.first))
        XCTAssertNil(m.suggestion(for: q), "the suggestion the rule made is gone with it")
        XCTAssertEqual(store.loadRules("demo"), [])
    }

    // MARK: the screens

    func testTheRulesSheetListsRulesWithRemoveAndTheWindowOffersTheButton() throws {
        let rules = [PermissionRule(pattern: "Bash(scripts/app-test.sh:*)", added: Date()), PermissionRule(pattern: "Bash(touch:*)", added: Date())]
        let sheet = try XCTUnwrap(SnapshotRenderer.render(view: AutopilotRulesSheet(policy: AutopilotPolicy(), permissionRules: rules, onSave: { _ in }, onCancel: {}), size: CGSize(width: 720, height: 780)))
        try save(sheet, "N213-rules.png")

        let q = PendingQuestion(paneID: "w1:p1", sessionID: "s1", agentLabel: "dev · V1", cardID: "V1", question: try question("scripts/app-test.sh"))
        let inbox = AgentInboxModel(reader: reader, keys: sender, commander: sender, adapter: FakeTerminal(agentsResult: .success([agent])), log: ActionLog(fileURL: dir.url.appendingPathComponent("log")))
        let window = try XCTUnwrap(SnapshotRenderer.render(view: QuestionFocusSheet(inbox: inbox, questions: [q], shown: q, onAlwaysAllow: { _ in }), size: CGSize(width: 860, height: 560)))
        try save(window, "N213-window.png")
    }

    private func save(_ data: Data, _ name: String) throws {
        if let out = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }
}
