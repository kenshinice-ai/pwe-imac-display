import XCTest
@testable import TargetBridge

/// When a wake restarts the capture pipeline (pweCaptureNeedsWakeRestart).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEWakeRestartTests: XCTestCase {
    func testCaptureRunningThroughTheSleepRestarts() {
        XCTAssertTrue(TBDisplaySenderSession.pweCaptureNeedsWakeRestart(captureStartedAt: 100, screensAsleepAt: 200))
    }

    func testCaptureStartedAfterTheWakeDoesNot() {
        // T15: slept at 13:31:51, connected again at 13:31:56, unlock at 13:31:59.
        XCTAssertFalse(TBDisplaySenderSession.pweCaptureNeedsWakeRestart(captureStartedAt: 205, screensAsleepAt: 200))
    }

    func testNoSleepSeenKeepsUpstreamsRestart() {
        XCTAssertTrue(TBDisplaySenderSession.pweCaptureNeedsWakeRestart(captureStartedAt: 100, screensAsleepAt: nil))
        XCTAssertTrue(TBDisplaySenderSession.pweCaptureNeedsWakeRestart(captureStartedAt: nil, screensAsleepAt: 200))
    }
}
