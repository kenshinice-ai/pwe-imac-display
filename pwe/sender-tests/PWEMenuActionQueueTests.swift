import XCTest
@testable import TargetBridge

/// The menu bar menu runs each chosen item once, for that click (T11, 2026-10-20:
/// every item ran one click late). pwe/rebrand.py copies this file into the
/// sender's test target.
@MainActor
final class PWEMenuActionQueueTests: XCTestCase {
    private var ran: [String] = []
    private var queue: PWEMenuActionQueue!

    override func setUp() {
        super.setUp()
        ran = []
        // Run scheduled work at once, so each step's effect is visible right away.
        queue = PWEMenuActionQueue(schedule: { work in work() })
    }

    private func work(_ name: String) -> PWEMenuActionQueue.Work {
        { [weak self] in self?.ran.append(name) }
    }

    /// AppKit's order for a status item: the menu closes, then the action arrives.
    private func click(_ name: String) {
        queue.menuWillOpen()
        queue.menuDidClose()
        queue.chose(work(name))
    }

    func testActionAfterTheCloseRunsAtOnce() {
        click("48 Hz")
        XCTAssertEqual(ran, ["48 Hz"])
    }

    func testActionBeforeTheCloseWaitsForTheClose() {
        queue.menuWillOpen()
        queue.chose(work("Settings"))
        XCTAssertEqual(ran, [])
        queue.menuDidClose()
        XCTAssertEqual(ran, ["Settings"])
    }

    /// The sequence from the test Mac: each click does its own item, not the last one.
    func testEachClickRunsItsOwnItemOnce() {
        for name in ["48 Hz", "60 Hz", "Settings", "Open window"] {
            click(name)
            XCTAssertEqual(ran.last, name)
        }
        XCTAssertEqual(ran, ["48 Hz", "60 Hz", "Settings", "Open window"])
        queue.menuWillOpen()
        queue.menuDidClose()
        XCTAssertEqual(ran.count, 4, "opening and closing without a choice runs nothing")
    }

    func testKeyEquivalentWithTheMenuClosedRunsAtOnce() {
        queue.chose(work("Quit"))
        XCTAssertEqual(ran, ["Quit"])
    }

    func testAChoiceDoesNotCarryIntoTheNextOpening() {
        queue.menuWillOpen()
        queue.chose(work("stale"))
        // The menu reopens without having closed (AppKit never does this; be safe anyway).
        queue.menuWillOpen()
        queue.menuDidClose()
        XCTAssertEqual(ran, [])
    }
}
