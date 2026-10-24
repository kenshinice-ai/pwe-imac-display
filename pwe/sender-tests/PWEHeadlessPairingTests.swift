import XCTest
@testable import TargetBridge

/// A1: when the app starts pairing by itself on a Mac with no screen
/// (PWEHeadlessPairingRules, TBDisplaySenderSession.pweNoPhysicalDisplay).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEHeadlessPairingTests: XCTestCase {
    private let all = PWEHeadlessPairingRules.Inputs(
        noPhysicalDisplay: true, iMacsOnCable: 1, offeredIMacIsOnCable: true, offeredIMacIsPaired: false,
        disconnectedThisRun: false, alreadyStarted: false, autoConnect: true)

    func testEveryConditionHolds() {
        XCTAssertTrue(PWEHeadlessPairingRules.startsPairing(all))
    }

    func testEachConditionIsNeeded() {
        var cases: [(String, PWEHeadlessPairingRules.Inputs)] = []
        var input = all; input.noPhysicalDisplay = false; cases.append(("a screen is attached", input))
        input = all; input.iMacsOnCable = 0; cases.append(("no iMac on the cable", input))
        input = all; input.iMacsOnCable = 2; cases.append(("two iMacs on the cable", input))
        input = all; input.offeredIMacIsOnCable = false; cases.append(("the iMac is not on the cable", input))
        input = all; input.offeredIMacIsPaired = true; cases.append(("already paired", input))
        input = all; input.disconnectedThisRun = true; cases.append(("disconnected in this run", input))
        input = all; input.alreadyStarted = true; cases.append(("already started once", input))
        input = all; input.autoConnect = false; cases.append(("automatic connection off", input))
        for (name, input) in cases {
            XCTAssertFalse(PWEHeadlessPairingRules.startsPairing(input), name)
        }
    }

    func testNoPhysicalDisplay() {
        typealias Session = TBDisplaySenderSession
        // Nothing online at all, or only this app's own virtual display.
        XCTAssertTrue(Session.pweNoPhysicalDisplay(onlineDisplayIDs: [], ownVirtualDisplayIDs: []))
        XCTAssertTrue(Session.pweNoPhysicalDisplay(onlineDisplayIDs: [7], ownVirtualDisplayIDs: [7]))
        XCTAssertTrue(Session.pweNoPhysicalDisplay(onlineDisplayIDs: [kCGNullDirectDisplay], ownVirtualDisplayIDs: [0]))
        // A built-in or external screen.
        XCTAssertFalse(Session.pweNoPhysicalDisplay(onlineDisplayIDs: [1], ownVirtualDisplayIDs: []))
        XCTAssertFalse(Session.pweNoPhysicalDisplay(onlineDisplayIDs: [1, 7], ownVirtualDisplayIDs: [7]))
    }
}
