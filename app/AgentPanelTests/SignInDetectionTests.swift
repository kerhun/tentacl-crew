import XCTest
@testable import AgentPanel

/// Login screens and sign-in errors of claude 2.1.316 / codex 0.164.0 (N330).
final class SignInDetectionTests: XCTestCase {
    private func tool(_ screen: String, _ state: AgentState = .idle) -> AgentTool? {
        let q = QuestionDetector.detect(screen: screen, state: state)
        return q?.kind == .signIn ? q?.signInTool : nil
    }

    func testClaudeLoginScreensAndErrors() {
        XCTAssertEqual(tool("Welcome to Claude Code\n\n Select login method:\n\n ❯ 1. Claude account with subscription\n   2. Anthropic Console account", .blocked), .claude)
        XCTAssertEqual(tool("● working\n\n  ⎿  Invalid API key · Please run /login\n\n> "), .claude)
        XCTAssertEqual(tool("Please run /login\n"), .claude)
        XCTAssertEqual(tool("  ⎿  API Error: 401 {\"error\":\"authentication_error\"} · Please run /login", .done), .claude)
        XCTAssertEqual(tool("OAuth token has expired. Please run /login"), .claude)
    }

    func testCodexSignInScreensAndErrors() {
        XCTAssertEqual(tool(" Welcome to Codex\n\n › 1. Sign in with ChatGPT\n   2. Provide your own API key", .blocked), .codex)
        XCTAssertEqual(tool("■ Your access token could not be refreshed. Please log out and sign in again.\n\n› "), .codex)
        XCTAssertEqual(tool("Not signed in. Please run 'codex login' to sign in with ChatGPT"), .codex)
    }

    func testOrdinaryScreensAreNotSignIn() {
        XCTAssertNil(tool("I fixed the login form.\nlet msg = \"Please run /login\"\n    if x { return }\n\n> "))
        XCTAssertNil(tool("The README says: Sign in with ChatGPT to use /usage.\n\n> "))
        XCTAssertNil(tool("Invalid API key format in config.\n\n> "))
        XCTAssertNil(tool("Please run /login\n" + (1...20).map { "line \($0)" }.joined(separator: "\n")), "old text far above the tail")
        XCTAssertNil(tool("Which colour?\n\n ❯ 1. Red\n   2. Blue\n\n Enter to select · Esc to cancel", .blocked))
    }
}
