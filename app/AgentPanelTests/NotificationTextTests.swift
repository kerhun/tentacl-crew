import XCTest
@testable import AgentPanel

final class NotificationTextTests: XCTestCase {
    private func p(_ s: String) -> String { NotificationText.plain(s) }

    func testInlineMarks() {
        XCTAssertEqual(p("**b** __b__ *i* _i_ `code`"), "b b i i code")
        XCTAssertEqual(p("see [the docs](https://x.y/z) now"), "see the docs now")
    }

    func testBlocks() {
        XCTAssertEqual(p("# Title\n> quoted\n- one\n* two"), "Title\nquoted\n• one\n• two")
        XCTAssertEqual(p("```sh\nls -la\n```"), "ls -la")
        XCTAssertEqual(p("| a | b |\n|---|:-:|\n| 1 | 2 |"), "a · b\n1 · 2")
        XCTAssertEqual(p("a\n\n\n\n\nb"), "a\n\nb")
    }

    func testScreenshotText() {
        XCTAssertEqual(p("- **N334:** curl ile tek satırda kurulum ve kaldırma (`install.sh`)."), "• N334: curl ile tek satırda kurulum ve kaldırma (install.sh).")
    }

    func testNonMarkdownIsLeftAlone() {
        for s in ["snake_case_name here", "a * b = c", "path/to/my_file_name.txt", "2 * 3 * 4", "plain text."] { XCTAssertEqual(p(s), s) }
    }

    func testCheckMarkOnly() {
        for s in ["✓", " ✓. ", "✅", "✔", "**✓**"] { XCTAssertTrue(NotificationText.isOnlyCheckMark(s), s) }
        for s in ["✓ merged N333", "ok", ""] { XCTAssertFalse(NotificationText.isOnlyCheckMark(s), s) }
    }
}
