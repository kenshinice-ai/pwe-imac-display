import XCTest
@testable import TargetBridge

/// T39: the main thread watch reports a stall once, every 10 s while it lasts,
/// then its end (PWEStallTracker). pwe/rebrand.py copies this file into the
/// sender's test target.
final class PWEMainThreadWatchTests: XCTestCase {
    func testAStallIsReportedOnceThenEveryTenSecondsThenItsEnd() {
        var tracker = PWEStallTracker()
        // Answered pings and pings not yet late: nothing.
        XCTAssertNil(tracker.check(now: 100, pendingSince: nil))
        XCTAssertNil(tracker.check(now: 101.5, pendingSince: 100))
        XCTAssertNil(tracker.answered(at: 101.6, postedAt: 100))
        // Late by more than 2 s: one line.
        XCTAssertNil(tracker.check(now: 112, pendingSince: 110))
        XCTAssertEqual(tracker.check(now: 112.5, pendingSince: 110), .stalled(2.5))
        XCTAssertTrue(tracker.isStalled)
        XCTAssertNil(tracker.check(now: 113, pendingSince: 110))
        XCTAssertNil(tracker.check(now: 122.25, pendingSince: 110))
        XCTAssertEqual(tracker.check(now: 122.5, pendingSince: 110), .stillStalled(12.5))
        // It runs again: one line with how long the ping waited.
        XCTAssertEqual(tracker.answered(at: 124.25, postedAt: 110), .recovered(14.25))
        XCTAssertFalse(tracker.isStalled)
        XCTAssertNil(tracker.answered(at: 124.4, postedAt: 124))
    }

    func testALateLookIsNotAStall() {
        // App Nap may delay the watch's own timer; only an unanswered ping counts.
        var tracker = PWEStallTracker()
        XCTAssertNil(tracker.check(now: 200, pendingSince: nil))
        XCTAssertNil(tracker.check(now: 230, pendingSince: 229.9))
    }

    func testTheLines() {
        XCTAssertEqual(PWEStallTracker.line(.stalled(2.14), .mainThread), "[pwe] main thread stalled 2.1 s")
        XCTAssertEqual(PWEStallTracker.line(.recovered(14.3), .mainThread),
                       "[pwe] main thread running again after 14.3 s")
        XCTAssertTrue(PWEStallTracker.line(.stalled(3), .defaultMode).contains("out of its default mode 3.0 s"))
    }

    /// 1.1.1: the watch runs only while the iMac is being reached, shown, or
    /// waits for an answer. Idle, its two wake-ups a second were the app's cost.
    func testTheWatchRunsOnlyWhileASessionIsUnderWay() {
        let imac = PWEReceiver(id: "imac", name: "iMac", detail: "")
        XCTAssertTrue(PWEMainThreadWatch.watches(.connecting(imac, .reaching)))
        XCTAssertTrue(PWEMainThreadWatch.watches(.connected(imac)))
        XCTAssertTrue(PWEMainThreadWatch.watches(.security(imac, .needsCode(secondsLeft: 60, identityChanged: false))))
        XCTAssertFalse(PWEMainThreadWatch.watches(.searching))
        XCTAssertFalse(PWEMainThreadWatch.watches(.ready(imac)))
        XCTAssertFalse(PWEMainThreadWatch.watches(.choose([imac])))
        XCTAssertFalse(PWEMainThreadWatch.watches(.needsPermission))
        XCTAssertFalse(PWEMainThreadWatch.watches(.interrupted(imac, .cableOrReceiverGone, retrying: true)))
    }
}
