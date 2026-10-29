import CoreGraphics
import XCTest
@testable import TargetBridge

/// Relayed mouse moves from the receiver (input role receiverMaster): where the
/// pointer starts and where it lands (TBRelayedPointer).
final class TBRelayedPointerTests: XCTestCase {
    // The test Mac of 2026-10-20: MacBook 1680 × 1050 at the origin, the iMac's
    // 2560 × 1440 virtual display to its right, raised 390 points. Only the
    // MacBook's right edge, y 0 to 1050, touches the iMac.
    private let raised = [CGRect(x: 0, y: 0, width: 1680, height: 1050),
                          CGRect(x: 1680, y: -390, width: 2560, height: 1440)]
    // The other way round: both top edges level, the iMac reaching 390 points lower.
    private let level = [CGRect(x: 0, y: 0, width: 1680, height: 1050),
                         CGRect(x: 1680, y: 0, width: 2560, height: 1440)]

    private func target(_ x: CGFloat, _ y: CGFloat, _ dx: Int, _ dy: Int, _ displays: [CGRect]) -> CGPoint {
        TBRelayedPointer.target(from: CGPoint(x: x, y: y), dx: dx, dy: dy, displays: displays)
    }

    func testAMoveOntoADisplayIsTakenAsIs() {
        XCTAssertEqual(target(100, 100, 30, -20, raised), CGPoint(x: 130, y: 80))
        // Across the shared edge onto the iMac.
        XCTAssertEqual(target(1670, 500, 40, 0, raised), CGPoint(x: 1710, y: 500))
        // Up into the iMac's raised part, above the MacBook.
        XCTAssertEqual(target(2000, 10, 0, -300, raised), CGPoint(x: 2000, y: -290))
    }

    func testADiagonalMoveNearTheEndOfTheSharedEdgeSlidesAcross() {
        // From near the MacBook's bottom-right corner, right and down. Raised,
        // the iMac ends at y 1050 too: the move crosses and slides along its
        // bottom edge. The old clamp kept the pointer on the MacBook.
        XCTAssertEqual(target(1670, 1040, 40, 30, raised), CGPoint(x: 1710, y: 1049))
        // Level, the iMac goes on to y 1440: the target is on it.
        XCTAssertEqual(target(1670, 1040, 40, 30, level), CGPoint(x: 1710, y: 1070))
        // Up and right out of the MacBook's top-right corner, level: crosses and
        // slides along the iMac's top edge (the old clamp: stuck at x 1679).
        XCTAssertEqual(target(1670, 5, 40, -30, level), CGPoint(x: 1710, y: 0))
    }

    func testTheGapBesideADisplayStillBlocks() {
        // Level layout: the iMac's left edge below y 1050 has no neighbour.
        XCTAssertEqual(target(1690, 1200, -60, 0, level), CGPoint(x: 1680, y: 1200))
        // Raised layout: the iMac's left edge above y 0 has none either.
        XCTAssertEqual(target(1690, -200, -60, 0, raised), CGPoint(x: 1680, y: -200))
    }

    func testTheOuterEdgesPinInside() {
        XCTAssertEqual(target(4200, 500, 100, 0, raised), CGPoint(x: 4239, y: 500))
        XCTAssertEqual(target(10, 10, -50, -50, raised), CGPoint(x: 0, y: 0))
        // Exactly on maxX is off the display.
        XCTAssertEqual(target(4230, 500, 10, 0, raised), CGPoint(x: 4239, y: 500))
    }

    func testAPointerOnNoDisplayComesBackToTheNearestOne() {
        // A start on no display comes back to the nearest display, not to displays[0] by chance.
        XCTAssertEqual(target(3000, -1000, 0, 0, raised), CGPoint(x: 3000, y: -390))
        XCTAssertEqual(target(100, -500, 0, 0, raised), CGPoint(x: 100, y: 0))
    }

    func testNoDisplaysLeavesTheMoveAlone() {
        XCTAssertEqual(target(5, 5, 3, 4, []), CGPoint(x: 8, y: 9))
    }

    func testTheRelayStartsFromItsOwnPointWhileThePointerIsWhereItLeftIt() {
        let cached = CGPoint(x: 2000, y: 300)
        XCTAssertEqual(TBRelayedPointer.start(cached: cached, recentTargets: [], real: cached), cached)
        // A posted drag not yet applied: the pointer is still at an earlier injected point.
        XCTAssertEqual(TBRelayedPointer.start(cached: cached, recentTargets: [CGPoint(x: 1990, y: 298)],
                                              real: CGPoint(x: 1990.5, y: 298)), cached)
    }

    func testSomethingElseMovedThePointerSoTheRelayStartsFromThere() {
        // The trackpad took the pointer to the MacBook: the next iMac move goes on from there.
        let real = CGPoint(x: 400, y: 600)
        XCTAssertEqual(TBRelayedPointer.start(cached: CGPoint(x: 2000, y: 300),
                                              recentTargets: [CGPoint(x: 1990, y: 298)], real: real), real)
        XCTAssertEqual(TBRelayedPointer.start(cached: nil, recentTargets: [], real: real), real)
        XCTAssertEqual(TBRelayedPointer.start(cached: real, recentTargets: [], real: nil), real)
    }

    // T57: the log names where the pointer went, so "it vanished" can be told apart.
    func testTheLandingDisplayIsNamed() {
        XCTAssertEqual(TBRelayedPointer.displayName(44, iMac: 44, builtIn: false), "the iMac")
        XCTAssertEqual(TBRelayedPointer.displayName(1, iMac: 44, builtIn: true), "this Mac's built-in display")
        XCTAssertEqual(TBRelayedPointer.displayName(3, iMac: 44, builtIn: false), "display 3")
    }
}
