import XCTest
@testable import TargetBridge

/// B11: system state that costs a query is read at most every 5 s
/// (PWEPollRules), and the engine's fps count no longer changes the session.
/// pwe/rebrand.py copies this file into the sender's test target.
@MainActor
final class PWEPollRulesTests: XCTestCase {
    func testAtMostEveryFiveSeconds() {
        XCTAssertTrue(PWEPollRules.isDue(lastAt: nil, now: 100))
        XCTAssertFalse(PWEPollRules.isDue(lastAt: 100, now: 104.9))
        XCTAssertTrue(PWEPollRules.isDue(lastAt: 100, now: 105))
        // A clock that went backwards (a new process's uptime) reads again.
        XCTAssertTrue(PWEPollRules.isDue(lastAt: 100, now: 50))
    }

    /// The fps counter lives on liveMetrics only: a tick must not make the
    /// session (and through it the service and every window) change.
    func testTheFPSCountDoesNotChangeTheSession() {
        let session = TBDisplaySenderSession(language: .english, largeCursor: false, preventDisplaySleep: false,
                                             autoRestartOnWake: false, audioEnabled: false)
        var changes = 0
        let watch = session.objectWillChange.sink { _ in changes += 1 }
        session.liveMetrics.senderFPS = 42
        XCTAssertEqual(session.senderFPS, 42)
        XCTAssertEqual(changes, 0)
        watch.cancel()
    }
}
