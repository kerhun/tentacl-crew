import XCTest
@testable import AgentPanel

final class OnboardingPromptTests: XCTestCase {
    private func probe() -> ProjectProbe {
        var p = ProjectProbe(facts: RepoFacts(isGitRepo: true, isTopLevel: true, hasCommits: true, branch: "main"))
        p.remote = "git@github.com:me/app.git"; p.mainCandidates = ["main"]
        p.ecosystems = [.node]; p.buildCommand = "npm run build"; p.testCommand = "npm test"
        p.dirtyFiles = 3; p.unpushedCommits = 2; p.commitCount = 40; p.fileCount = 120
        p.agentDocs = [.init(name: "CLAUDE.md", isFolder: false, excerpt: "x"), .init(name: ".claude", isFolder: true, excerpt: "")]
        p.ciWorkflows = ["CI"]
        return p
    }
    private func build(_ p: ProjectProbe? = nil, run: Bool = true) -> String {
        OnboardingPrompt.build(name: "App", repoPath: "/r/app", dataDir: "/d/app", probe: p ?? probe(), runBuildAndTest: run)
    }

    func testPromptCarriesTheFactsAndThePaths() {
        let t = build()
        for s in ["App", "/r/app", "/d/app/summary.md", "/d/app/plan.json", "/d/app/tasks/", "git@github.com:me/app.git", "npm run build", "npm test", "CLAUDE.md", "CI", "3 changed", "2 unpushed"] {
            XCTAssertTrue(t.contains(s), s)
        }
    }

    func testPromptSaysWhatToWrite() {
        let t = build()
        XCTAssertTrue(t.contains("Do not change any code"))
        XCTAssertTrue(t.contains("status: todo"))
        XCTAssertTrue(t.contains("from: pm"))
        XCTAssertTrue(t.contains("\"waiting\""))
        XCTAssertTrue(t.contains("questions"))
    }

    func testRunningBuildAndTestIsReadOnlyWithTrimmedOutput() {
        let on = build(run: true)
        XCTAssertTrue(on.contains("last 30 lines"))
        XCTAssertFalse(on.contains("Do not run the build or test"))
    }

    func testSwitchedOffTellsThePMNotToRun() {
        let off = build(run: false)
        XCTAssertTrue(off.contains("Do not run the build or test"))
        XCTAssertFalse(off.contains("last 30 lines"))
    }

    func testNoCommandsFoundAsksThePMToFindThem() {
        var p = probe(); p.buildCommand = nil; p.testCommand = nil
        let t = build(p)
        XCTAssertTrue(t.contains("none found"))
        XCTAssertTrue(t.contains("questions"))
    }

    func testEmptyProjectAsksForTheGoal() {
        var p = ProjectProbe(facts: RepoFacts(isGitRepo: true, isTopLevel: true))
        p.fileCount = 0
        XCTAssertTrue(build(p).contains("goal.md"))
    }

    func testDifferentCommandIsReportedNotChanged() {
        XCTAssertTrue(build().contains("do not edit project.json"))
    }

    func testPolicyFlagDefaultsOnAndSurvivesOldFiles() throws {
        XCTAssertTrue(AutopilotPolicy().runBuildAndTest)
        XCTAssertTrue(try JSONDecoder().decode(AutopilotPolicy.self, from: Data("{}".utf8)).runBuildAndTest)
        var p = AutopilotPolicy(); p.runBuildAndTest = false
        let back = try JSONDecoder().decode(AutopilotPolicy.self, from: JSONEncoder().encode(p))
        XCTAssertFalse(back.runBuildAndTest)
    }
}
