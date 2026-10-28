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

    // MARK: - Review 2026-10-28 (C3, C4)

    func testANoDisplayMomentStartsNothing() {
        var input = all
        input.noPhysicalDisplayFor = 2
        XCTAssertFalse(PWEHeadlessPairingRules.startsPairing(input), "a display dropped out for a moment")
        input.noPhysicalDisplayFor = 10
        XCTAssertTrue(PWEHeadlessPairingRules.startsPairing(input))
        input.settling = true
        XCTAssertFalse(PWEHeadlessPairingRules.startsPairing(input), "just woke")
        input.settling = false
        input.armed = false
        XCTAssertFalse(PWEHeadlessPairingRules.startsPairing(input), "no launch or cable event lately")
    }

    func testOnlyAnIMacSeenThroughThisMacsBridgeIsOnTheCable() {
        typealias Rules = PWEHeadlessPairingRules
        XCTAssertTrue(Rules.isOnCable(seenOnCableBridge: true, bridgeIPv4: "", resolvedIPv4: [],
                                      localBridgeIPv4: []))
        XCTAssertTrue(Rules.isOnCable(seenOnCableBridge: false, bridgeIPv4: "169.254.6.224",
                                      resolvedIPv4: ["169.254.6.224"], localBridgeIPv4: ["169.254.171.182"]))
        // On the LAN: it announces its bridge address, but was resolved on Wi-Fi.
        XCTAssertFalse(Rules.isOnCable(seenOnCableBridge: false, bridgeIPv4: "169.254.6.224",
                                       resolvedIPv4: ["192.168.1.20"], localBridgeIPv4: ["169.254.171.182"]))
        // This Mac has no bridge address.
        XCTAssertFalse(Rules.isOnCable(seenOnCableBridge: false, bridgeIPv4: "169.254.6.224",
                                       resolvedIPv4: ["169.254.6.224"], localBridgeIPv4: []))
    }

    /// Review 2026-10-28: a LAN receiver resolved only on en0, with one local
    /// bridge. Dialing still gets the lone-bridge guess; the cable count does not.
    func testTheLoneBridgeGuessIsNotASighting() {
        let advertised = "fe80::1c2b:3cff:fe4d:5e6f"
        XCTAssertEqual(TBConnectionDiagnostics.scopedBridgeIPv6(advertised: advertised, resolved: [],
                                                                cableBridges: ["bridge0"]),
                       "\(advertised)%bridge0")
        XCTAssertFalse(TBConnectionDiagnostics.seenOnCableBridge(advertised: advertised,
                                                                 resolved: ["192.168.1.20", "\(advertised)%en0"],
                                                                 cableBridges: ["bridge0"]))
        XCTAssertTrue(TBConnectionDiagnostics.seenOnCableBridge(advertised: advertised,
                                                                resolved: ["\(advertised)%bridge0"],
                                                                cableBridges: ["bridge0"]))
    }
}
