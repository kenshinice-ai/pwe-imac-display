import XCTest
@testable import TargetBridge

/// When the remembered iMac's bridge address counts as a replug (PWEReplugRules).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEReplugRulesTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func change(_ old: String, _ new: String, lostSecondsAgo: TimeInterval? = nil) -> PWEReplugRules.BridgeChange {
        PWEReplugRules.bridgeChange(
            from: old, to: new,
            lostAt: lostSecondsAgo.map { now.addingTimeInterval(-$0) },
            now: now)
    }

    func testNoChangeIsNothing() {
        XCTAssertEqual(change("169.254.45.128", "169.254.45.128"), .none)
        XCTAssertEqual(change("", ""), .none)
    }

    func testCableOutLosesTheBridge() {
        XCTAssertEqual(change("169.254.45.128", ""), .lost)
    }

    func testCableBackAfterAWhileIsAReplug() {
        XCTAssertEqual(change("", "169.254.45.128", lostSecondsAgo: 6), .replugged)
    }

    func testABlinkIsNotAReplug() {
        // A Bonjour update can drop the address for a moment; no cable moved.
        XCTAssertEqual(change("", "169.254.45.128", lostSecondsAgo: 0.5), .none)
    }

    func testFirstBridgeAddressIsAReplug() {
        // Listed through Wi-Fi only (the receiver came back with no bridge
        // address), then the cable goes in: never seen leaving, still a replug.
        XCTAssertEqual(change("", "169.254.45.128"), .replugged)
    }

    func testANewBridgeAddressIsAReplug() {
        XCTAssertEqual(change("169.254.45.128", "169.254.9.7"), .replugged)
    }
}
