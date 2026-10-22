import XCTest
@testable import TargetBridge

/// The retry loop's logging and pauses while the iMac is absent (PWERetryPacing).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWERetryPacingTests: XCTestCase {
    func testTheFirstThreeAttemptsLogThenEveryThirtieth() {
        let logged = (1...100).filter(PWERetryPacing.logsAttempt)
        XCTAssertEqual(logged, [1, 2, 3, 30, 60, 90])
    }

    func testThePauseGrowsAfterAMinuteOfAbsence() {
        XCTAssertEqual(PWERetryPacing.pauseCap(absentFor: nil), 2)
        XCTAssertEqual(PWERetryPacing.pauseCap(absentFor: 0), 2)
        XCTAssertEqual(PWERetryPacing.pauseCap(absentFor: 59.9), 2)
        XCTAssertEqual(PWERetryPacing.pauseCap(absentFor: 60), 5)
        XCTAssertEqual(PWERetryPacing.pauseCap(absentFor: 3600), 5)
    }
}
