import XCTest
@testable import AgentPanel

final class TaskInputTests: XCTestCase {
    func testAcceptsNormalIDs() {
        for id in ["A5", "B-12", "k1.2", "A", "task_1", String(repeating: "a", count: 40)] {
            XCTAssertTrue(TaskInput.validTaskID(id), id)
        }
    }

    func testRejectsPathLikeIDs() {
        for id in ["../x", "a/b", "", "-A", ".hidden", "_x", String(repeating: "a", count: 41), "A 5", "A5\n"] {
            XCTAssertFalse(TaskInput.validTaskID(id), id.debugDescription)
        }
    }

    func testAcceptsNormalBranches() {
        for b in ["pilot/a5-widget", "feat/x_1.2", "main", "fix/a5", "docs/a4-open-items", String(repeating: "a", count: 80)] {
            XCTAssertTrue(TaskInput.validBranch(b), b)
        }
    }

    /// Review Focus 1: a name that git or terminal would read as an option.
    func testRejectsOptionLikeBranch() {
        for b in ["--force", "-b", "-", "--upload-pack=x"] { XCTAssertFalse(TaskInput.validBranch(b), b) }
    }

    func testRejectsShellMetacharacters() {
        for b in ["x; rm -rf ~", "a b", "`id`", "$(x)", "a\nb", "a|b", "a&b", "a>b", "a'b", "a\"b", "a\\b", "a*b", "a?b", "a~b", "a^b", "a:b", "a@{b}", "a[b]"] {
            XCTAssertFalse(TaskInput.validBranch(b), b.debugDescription)
        }
    }

    func testRejectsDotDotAndDoubleSlash() {
        for b in ["a/../b", "..", "a//b", "../x", "a/./b", "a/.hidden"] { XCTAssertFalse(TaskInput.validBranch(b), b) }
    }

    func testRejectsLockSuffixAndTrailingSlashOrDot() {
        for b in ["a.lock", "a/b.lock", "a/", "a.", "a/b/", "x.lock/y"] { XCTAssertFalse(TaskInput.validBranch(b), b) }
    }

    func testRejectsNonASCIILookalikes() {
        for b in ["pilot/ａ5", "pilot/a５", "pilot/é", "ра", "feat/ｘ", "a\u{200B}b"] { XCTAssertFalse(TaskInput.validBranch(b), b) }
        XCTAssertFalse(TaskInput.validTaskID("Ａ5"))
    }

    func testRejectsTooLongBranch() {
        XCTAssertFalse(TaskInput.validBranch(String(repeating: "a", count: 81)))
        XCTAssertFalse(TaskInput.validBranch(""))
    }
}
