import XCTest
import AppKit
import SwiftUI
@testable import AgentPanel

@MainActor
final class ReviewViewTests: XCTestCase {
    private let head = "0123456789abcdef0123456789abcdef01234567"

    private func card(_ status: TaskStatus = .review, kind: String? = nil) -> TaskCard {
        TaskCard(id: "A4", project: "demo", status: status, agent: "dev-a4", branch: "feat/a4", kind: kind, files: ["App/A4.swift"], title: "Tighten the home header",
                 sections: ["Goal": "Make the header fit small phones.", "Report": "Done.",
                            "Review packet": "Head: \(head)\n\nBuild: passed (`b`), log: /l\n\nScreenshots:\n- tasks/A4/shots/a.png\n"],
                 url: URL(fileURLWithPath: "/tmp/A4.md"))
    }

    private func plan(analysis: Bool = false, ahead: Int = 2) -> ApprovalPlan {
        ApprovalPlan(card: card(kind: analysis ? "analysis" : nil), agentName: "dev-a4", branch: "feat/a4", worktreePath: "/repo/.agent-worktrees/feat-a4", base: "main",
                     head: head, ahead: ahead, filesChanged: 3, screenshotCount: 2, isAnalysis: analysis,
                     commandPreview: "merge-task.sh /p/project.json feat/a4 /repo/.agent-worktrees/feat-a4 --expect-head \(head)")
    }

    func testApproveSheetFieldsListWhatWillHappen() {
        let fields = approveSheetFields(plan: plan())
        XCTAssertEqual(fields.map(\.label), ["Branch", "Merge into", "Changes", "Screenshots", "Reviewed commit", "Command"])
        XCTAssertEqual(fields.first { $0.label == "Merge into" }?.value, "main (fast-forward only)")
        XCTAssertEqual(fields.first { $0.label == "Changes" }?.value, "2 commits, 3 files")
        XCTAssertEqual(fields.first { $0.label == "Reviewed commit" }?.value, "0123456")
    }

    func testApproveSheetFieldsForAnalysisAndEmptyBranch() {
        let analysis = approveSheetFields(plan: plan(analysis: true, ahead: 0))
        XCTAssertEqual(analysis.map(\.label), ["Branch", "Changes", "Reviewed commit"])
        XCTAssertEqual(analysis.first { $0.label == "Changes" }?.value, "none: nothing is merged")
        XCTAssertEqual(approveSheetFields(plan: plan(ahead: 0)).first { $0.label == "Changes" }?.value, "no commits of its own: nothing to merge")
        XCTAssertEqual(approveSheetFields(plan: plan(ahead: 1)).first { $0.label == "Changes" }?.value, "1 commit, 3 files")
    }

    func testRebaseTextNamesTheMainBranch() {
        let text = rebaseRequestText(base: "main")
        XCTAssertTrue(text.contains("rebase"))
        XCTAssertTrue(text.contains("main"))
    }

    private func png(_ view: some View, size: CGSize, name: String) throws -> Data {
        let data = try XCTUnwrap(SnapshotRenderer.render(view: view, size: size))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, Int(size.width) * 2)
        XCTAssertGreaterThan(data.count, 6_000)
        if let dir = ProcessInfo.processInfo.environment["AGENT_PANEL_SNAPSHOT_DIR"] { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
        return data
    }

    func testApproveSheetRenders() throws {
        _ = try png(ApproveSheet(plan: plan(), state: .idle, onConfirm: {}, onCancel: {}), size: CGSize(width: 560, height: 470), name: "approve-sheet")
        _ = try png(ApproveSheet(plan: plan(analysis: true, ahead: 0), state: .failed("Unsaved changes in your repository are in the way: a.txt."), onConfirm: {}, onCancel: {}),
                    size: CGSize(width: 560, height: 360), name: "approve-sheet-analysis-failed")
    }

    func testFixRequestSheetRenders() throws {
        _ = try png(FixRequestSheet(card: card(), notes: .constant("The title is cut off on small phones."), state: .idle, onSend: {}, onCancel: {}),
                    size: CGSize(width: 560, height: 400), name: "fix-sheet")
        _ = try png(FixRequestSheet(card: card(), notes: .constant(""), state: .running("Sending the fix request…"), onSend: {}, onCancel: {}),
                    size: CGSize(width: 560, height: 400), name: "fix-sheet-empty")
    }

    func testFixRequestSendIsDisabledForBlankNotesAndWhileRunning() {
        XCTAssertFalse(canSendFix(notes: "  \n", busy: false))
        XCTAssertFalse(canSendFix(notes: "x", busy: true))
        XCTAssertTrue(canSendFix(notes: "x", busy: false))
    }

    func testDetailViewShowsTheReviewActions() throws {
        let enabled = reviewButtonStates(card: card(), canAct: true, reason: nil)
        let view = TaskDetailView(card: card(), shots: [], opener: nil, startState: StartButtonState(enabled: false, help: ""), reviewState: enabled,
                                  onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {})
        _ = try png(view, size: CGSize(width: 700, height: 520), name: "detail-review")
    }

    /// The action bar in each phase (todo, working, finished, in review, needs fix, done).
    func testActionBarSnapshotsForEachPhase() throws {
        let off = StartButtonState(enabled: false, help: "")
        let cases: [(String, TaskStatus, TaskPhase?, Bool)] = [("todo", .todo, nil, false), ("working", .doing, .working, false), ("finished", .doing, .finished, false),
                                                              ("review", .review, .inReview, true), ("needs-fix", .needsFix, .needsFix, false), ("done", .done, nil, false)]
        for (name, status, phase, packet) in cases {
            let full = card(status)
            let c = packet ? full : TaskCard(id: full.id, project: full.project, status: status, agent: full.agent, branch: full.branch, kind: nil, files: full.files,
                                             title: full.title, sections: full.sections.filter { $0.key != "Review packet" }, url: full.url)
            let start = status == .todo ? StartButtonState(enabled: false, help: "Waiting for N86: it is not done yet.") : off
            let view = TaskDetailView(card: c, shots: [], opener: nil, phase: phase, startState: start,
                                      reviewState: reviewButtonStates(card: c, canAct: true, reason: nil, agentWorking: phase == .working),
                                      onStart: {}, onPrepare: {}, onApprove: {}, onRequestFix: {}, onEdit: {}, startTab: openingTab(card: c))
            _ = try png(view, size: CGSize(width: 700, height: 420), name: "action-bar-\(name)")
        }
    }
}
