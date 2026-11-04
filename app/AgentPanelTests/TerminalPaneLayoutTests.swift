import XCTest
import SwiftUI
@testable import AgentPanel

/// The Terminals screen's panes (N234): splits by drop zone, the 4-pane and 2 × 2 limits, move and swap, close, numbering, focus moves,
/// what is saved and the migration of the single/split/preview value.
@MainActor
final class TerminalPaneLayoutTests: XCTestCase {
    private func numbers(_ l: TerminalPaneLayout) -> [String] { l.panes.map(\.terminal) }

    func testSplittingOnAnEdgePutsTheNewTerminalOnThatSideAndFocusesIt() {
        var l = TerminalPaneLayout(terminal: "a")
        XCTAssertTrue(l.drop("b", on: 1, zone: .right))
        XCTAssertEqual(numbers(l), ["a", "b"], "pane 1 left, pane 2 right")
        XCTAssertEqual(l.focusedTerminal, "b")
        var left = TerminalPaneLayout(terminal: "a")
        left.drop("b", on: 1, zone: .left)
        XCTAssertEqual(numbers(left), ["b", "a"])
        var top = TerminalPaneLayout(terminal: "a")
        top.drop("b", on: 1, zone: .top)
        XCTAssertEqual(numbers(top), ["b", "a"])
        var bottom = TerminalPaneLayout(terminal: "a")
        bottom.drop("b", on: 1, zone: .bottom)
        XCTAssertEqual(numbers(bottom), ["a", "b"])
        XCTAssertEqual(bottom.root.rows, 2)
        XCTAssertEqual(bottom.root.columns, 1)
    }

    func testThreePanesNumberInReadingOrder() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        let paneB = l.pane(showing: "b")!.id
        XCTAssertTrue(l.drop("c", on: paneB, zone: .bottom), "board B: drop on 2's bottom edge")
        XCTAssertEqual(l.panes.map(\.number), [1, 2, 3])
        XCTAssertEqual(numbers(l), ["a", "b", "c"], "1 left, 2 top right, 3 bottom right")
        var m = TerminalPaneLayout(terminal: "a")
        m.drop("b", on: 1, zone: .bottom)
        m.drop("c", on: 1, zone: .right)
        XCTAssertEqual(numbers(m), ["a", "c", "b"], "top row first, left to right, then the bottom row")
    }

    func testAtMostFourPanesTwoAcrossAndTwoDown() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        XCTAssertFalse(l.canSplit(1, .left), "a third column")
        XCTAssertFalse(l.canSplit(l.pane(showing: "b")!.id, .right))
        XCTAssertTrue(l.canSplit(1, .bottom))
        XCTAssertEqual(l.accepted(.right, on: 1), .center, "an edge that cannot split replaces")
        l.drop("c", on: 1, zone: .bottom)
        l.drop("d", on: l.pane(showing: "b")!.id, zone: .bottom)
        XCTAssertEqual(l.count, 4)
        XCTAssertEqual(numbers(l), ["a", "b", "c", "d"], "2 × 2 in reading order")
        for pane in l.panes {
            for zone in [TerminalPaneLayout.Zone.left, .right, .top, .bottom] { XCTAssertFalse(l.canSplit(pane.id, zone), "4 open: only replace") }
        }
        XCTAssertTrue(l.drop("e", on: 1, zone: .left), "accepted as a replace")
        XCTAssertEqual(l.count, 4)
        XCTAssertEqual(numbers(l).first, "e")
        var stacked = TerminalPaneLayout(terminal: "a")
        stacked.drop("b", on: 1, zone: .bottom)
        XCTAssertFalse(stacked.canSplit(1, .top), "a third row")
        XCTAssertFalse(stacked.split(1, .top, with: "c"))
        XCTAssertEqual(stacked.count, 2, "a refused split changes nothing")
    }

    func testWithPreviewOpenAtMostTwoPanes() {
        var l = TerminalPaneLayout(terminal: "a")
        XCTAssertTrue(l.canSplit(1, .right, preview: true))
        l.drop("b", on: 1, zone: .right)
        XCTAssertFalse(l.canSplit(1, .bottom, preview: true))
        XCTAssertEqual(l.accepted(.bottom, on: 1, preview: true), .center)
        l.drop("c", on: 1, zone: .bottom)
        l.focus(l.pane(showing: "c")!.id)
        guard case .split(.column, .pane(_, "c"), .pane(_, let other), _) = l.withPreview() else { return XCTFail("\(l.withPreview())") }
        XCTAssertEqual(other, "a", "the focused pane (3) and the next one in reading order (back to 1)")
    }

    func testADroppedTerminalAlreadyOnScreenSwapsInTheMiddleAndMovesOnAnEdge() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        l.drop("b", on: 1, zone: .center)
        XCTAssertEqual(numbers(l), ["b", "a"], "replace with a terminal of another pane: the two swap")
        var m = TerminalPaneLayout(terminal: "a")
        m.drop("b", on: 1, zone: .right)
        m.drop("c", on: 1, zone: .bottom)
        XCTAssertTrue(m.drop("b", on: m.pane(showing: "c")!.id, zone: .right), "b leaves its pane and splits c")
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(numbers(m), ["a", "c", "b"], "a on top, c and b below")
        XCTAssertEqual(Set(m.terminals).count, 3, "a terminal is in one pane only")
        var one = TerminalPaneLayout(terminal: "a")
        XCTAssertFalse(one.split(1, .right, with: "a"), "a pane cannot split with its own terminal")
    }

    func testAClickLoadsTheFocusedPaneAndSwapsWithAnotherPane() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        l.focus(1)
        l.showInFocused("c")
        XCTAssertEqual(numbers(l), ["c", "b"])
        l.showInFocused("b")
        XCTAssertEqual(numbers(l), ["b", "c"])
        XCTAssertEqual(l.focusedPane?.number, 1, "the focus stays on the pane")
    }

    func testClosingAPaneKeepsTheOthersAndTheLastPaneStays() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        l.drop("c", on: l.pane(showing: "b")!.id, zone: .bottom)
        let c = l.pane(showing: "c")!.id
        l.close(c)
        XCTAssertEqual(numbers(l), ["a", "b"])
        XCTAssertEqual(l.focusedTerminal, "a", "the focus goes to pane 1")
        l.close(l.pane(showing: "b")!.id)
        l.close(1)
        XCTAssertEqual(numbers(l), ["a"], "the last pane cannot close")
    }

    func testOptionCommandArrowsMoveTheFocus() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        l.drop("c", on: 1, zone: .bottom)
        l.drop("d", on: l.pane(showing: "b")!.id, zone: .bottom)
        l.focus(1)
        l.moveFocus(.right); XCTAssertEqual(l.focusedTerminal, "b")
        l.moveFocus(.bottom); XCTAssertEqual(l.focusedTerminal, "d")
        l.moveFocus(.left); XCTAssertEqual(l.focusedTerminal, "c")
        l.moveFocus(.top); XCTAssertEqual(l.focusedTerminal, "a")
        l.moveFocus(.top); XCTAssertEqual(l.focusedTerminal, "a", "nothing above")
    }

    func testTheDropZoneIsTheOuterQuarterOfEachSide() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(TerminalPaneLayout.zone(at: CGPoint(x: 200, y: 100), in: size), .center)
        XCTAssertEqual(TerminalPaneLayout.zone(at: CGPoint(x: 20, y: 100), in: size), .left)
        XCTAssertEqual(TerminalPaneLayout.zone(at: CGPoint(x: 390, y: 100), in: size), .right)
        XCTAssertEqual(TerminalPaneLayout.zone(at: CGPoint(x: 200, y: 10), in: size), .top)
        XCTAssertEqual(TerminalPaneLayout.zone(at: CGPoint(x: 200, y: 190), in: size), .bottom)
        XCTAssertEqual(TerminalPaneGrid<EmptyView>.rect(of: .right, in: size), CGRect(x: 200, y: 0, width: 200, height: 200))
    }

    func testClosedTerminalsAreReplacedByTheNextFreeOneOrTheirPaneCloses() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        XCTAssertEqual(l.reconciled(with: ["a", "c"]).map(numbers), ["a", "c"], "b closed: the next terminal not on screen")
        XCTAssertEqual(l.reconciled(with: ["a"]).map(numbers), ["a"], "no free terminal: the pane closes")
        XCTAssertEqual(l.reconciled(with: ["x"]).map(numbers), ["x"])
        XCTAssertNil(l.reconciled(with: []))
        XCTAssertEqual(l.nextFree(in: ["a", "b", "c"]), "c")
    }

    func testTheLayoutIsSavedPerProjectAndRestored() {
        let defaults = makeTestDefaults()
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        l.setRatio(0.7, ofSplitAt: [])
        TerminalPaneStore.save(defaults, project: "one", l)
        let back = TerminalPaneStore.load(defaults, project: "one")
        XCTAssertEqual(back, l)
        XCTAssertEqual(back?.focusedTerminal, "b")
        guard case .split(_, _, _, let ratio)? = back?.root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.7, accuracy: 0.001)
        XCTAssertNil(TerminalPaneStore.load(defaults, project: "two"))
        l.setRatio(0.99, ofSplitAt: [])
        guard case .split(_, _, _, let kept) = l.root else { return XCTFail() }
        XCTAssertEqual(kept, 0.8, accuracy: 0.001, "a divider keeps both panes usable")
        XCTAssertFalse(TerminalPaneStore.sidebarCollapsed(defaults), "the sidebar is open by default")
        TerminalPaneStore.setSidebarCollapsed(defaults, true)
        XCTAssertTrue(TerminalPaneStore.sidebarCollapsed(defaults))
    }

    func testTheOldLayoutValueMigrates() {
        let defaults = makeTestDefaults()
        defaults.set("split", forKey: TerminalPaneStore.oldLayoutKey)
        defaults.set("p2", forKey: TerminalPaneStore.oldSelectedKey(project: "one"))
        defaults.set("p1", forKey: TerminalPaneStore.oldPreviousKey(project: "one"))
        let split = TerminalPaneStore.load(defaults, project: "one")
        XCTAssertEqual(split.map(numbers), ["p2", "p1"], "split: the selected terminal and the one before, side by side")
        XCTAssertEqual(split?.focusedTerminal, "p2")
        XCTAssertNil(defaults.string(forKey: TerminalPaneStore.oldSelectedKey(project: "one")), "the old per-project keys are gone")
        XCTAssertEqual(TerminalPaneStore.load(defaults, project: "one"), split, "saved in the new form")
        defaults.set("preview", forKey: TerminalPaneStore.oldLayoutKey)
        defaults.set("q1", forKey: TerminalPaneStore.oldSelectedKey(project: "two"))
        XCTAssertEqual(TerminalPaneStore.load(defaults, project: "two").map(numbers), ["q1"], "preview and single: one pane")
        defaults.set("garbage", forKey: TerminalPaneStore.oldLayoutKey)
        defaults.set(Data("{not json".utf8), forKey: TerminalPaneStore.key(project: "three"))
        XCTAssertNil(TerminalPaneStore.load(defaults, project: "three"), "an unreadable value is no error")
    }

    // MARK: N245

    func testALoadedLayoutIsCheckedAndBadOnesAreDropped() {
        let defaults = makeTestDefaults()
        func saved(_ root: TerminalPaneLayout.Node, _ name: String) -> TerminalPaneLayout? {
            TerminalPaneStore.save(defaults, project: name, TerminalPaneLayout(root: root, focused: 1))
            return TerminalPaneStore.load(defaults, project: name)
        }
        typealias N = TerminalPaneLayout.Node
        XCTAssertNotNil(saved(.split(.row, .pane(id: 1, terminal: "a"), .pane(id: 2, terminal: "b"), ratio: 0.5), "ok"))
        XCTAssertNil(saved(.split(.row, .pane(id: 1, terminal: "a"), .pane(id: 2, terminal: "a"), ratio: 0.5), "dupTerminal"), "one terminal in two panes")
        XCTAssertNil(saved(.split(.row, .pane(id: 1, terminal: "a"), .pane(id: 1, terminal: "b"), ratio: 0.5), "dupId"), "one pane id twice")
        XCTAssertNil(saved(.pane(id: 1, terminal: ""), "empty"))
        let three: N = .split(.row, .split(.row, .pane(id: 1, terminal: "a"), .pane(id: 2, terminal: "b"), ratio: 0.5), .pane(id: 3, terminal: "c"), ratio: 0.5)
        XCTAssertNil(saved(three, "threeColumns"), "more than 2 columns")
        let five: N = .split(.column, .split(.row, .pane(id: 1, terminal: "a"), .pane(id: 2, terminal: "b"), ratio: 0.5),
                             .split(.row, .pane(id: 3, terminal: "c"), .split(.column, .pane(id: 4, terminal: "d"), .pane(id: 5, terminal: "e"), ratio: 0.5), ratio: 0.5), ratio: 0.5)
        XCTAssertNil(saved(five, "five"), "more than 4 panes")
        let wide = saved(.split(.row, .pane(id: 1, terminal: "a"), .pane(id: 2, terminal: "b"), ratio: 0.99), "ratio")
        guard case .split(_, _, _, let r)? = wide?.root else { return XCTFail() }
        XCTAssertEqual(r, 0.8, accuracy: 0.001, "a ratio outside 0.2–0.8 is brought back")
        let nan = saved(.split(.row, .pane(id: 1, terminal: "a"), .pane(id: 2, terminal: "b"), ratio: 0.01), "low")
        guard case .split(_, _, _, let low)? = nan?.root else { return XCTFail() }
        XCTAssertEqual(low, 0.2, accuracy: 0.001)
    }

    func testAMissingTerminalIsShownReplacedButTheSavedLayoutKeepsIt() {
        var saved = TerminalPaneLayout(terminal: "a")
        saved.drop("b", on: 1, zone: .right)
        let shown = saved.reconciled(with: ["a", "c"])!
        XCTAssertEqual(numbers(shown), ["a", "c"], "b is gone for now: pane 2 shows c")
        // The user only moves the focus: the saved layout still has b in pane 2.
        var edited = shown
        edited.focus(1)
        XCTAssertEqual(numbers(edited.keepingMissingTerminals(saved: saved, shown: shown)), ["a", "b"])
        XCTAssertEqual(edited.keepingMissingTerminals(saved: saved, shown: shown).focused, 1)
        // The user puts another terminal into pane 2: that is saved.
        var replaced = shown
        replaced.show("d", in: 2)
        XCTAssertEqual(numbers(replaced.keepingMissingTerminals(saved: saved, shown: shown)), ["a", "d"])
        // When b is back the layout is the one the user had.
        XCTAssertEqual(numbers(saved.reconciled(with: ["a", "b", "c"])!), ["a", "b"])
    }

    func testClosingAnUnfocusedPaneGivesTheFocusBackToThePaneThatHadIt() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        l.drop("c", on: 2, zone: .bottom)
        l.focus(2)
        let before = l.focused
        let closing = l.pane(showing: "c")!.id
        // The × taps the pane first (focus moves to it), then closes it.
        var tapFirst = l
        tapFirst.focus(closing)
        tapFirst.close(closing, focusing: before)
        XCTAssertEqual(tapFirst.focused, before)
        XCTAssertEqual(tapFirst.count, 2)
        // Or closes first; the late tap finds no pane.
        var closeFirst = l
        closeFirst.close(closing, focusing: before)
        closeFirst.focus(closing)
        XCTAssertEqual(closeFirst.focused, before)
        // Closing the focused pane still moves the focus to the first one.
        var own = l
        own.close(before, focusing: before)
        XCTAssertEqual(own.focused, own.panes.first?.id)
    }

    func testSwapTradesTheFirstTwoPanesTerminalsAndKeepsTheFocusedPane() {
        var l = TerminalPaneLayout(terminal: "a")
        l.drop("b", on: 1, zone: .right)
        l.drop("c", on: 2, zone: .bottom)
        l.focus(1)
        l.swapFirstTwo()
        XCTAssertEqual(numbers(l), ["b", "a", "c"])
        XCTAssertEqual(l.focused, 1, "the focus stays on pane 1")
        var one = TerminalPaneLayout(terminal: "a")
        one.swapFirstTwo()
        XCTAssertEqual(numbers(one), ["a"], "one pane: nothing to swap")
    }
}
