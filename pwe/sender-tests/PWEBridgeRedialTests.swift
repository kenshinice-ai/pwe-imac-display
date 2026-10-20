import XCTest
@testable import TargetBridge

/// When the retry loop redials a receiver's last Thunderbolt Bridge address
/// instead of waiting for Bonjour (TBBridgeRedial.decide).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEBridgeRedialTests: XCTestCase {
    /// A replug a second ago: the link is up, Bonjour has not listed the iMac yet.
    private func replugged(_ change: (inout TBBridgeRedial.Inputs) -> Void = { _ in }) -> TBBridgeRedial.Decision {
        var inputs = TBBridgeRedial.Inputs(
            transport: .thunderboltBridge,
            sessionBusy: false,
            sleeping: false,
            listedWithBridgeAddress: false,
            rememberedAddress: "169.254.6.224",
            localBridgeIP: "169.254.171.182",
            secondsSinceTrigger: 1,
            secondsSinceLastDial: nil)
        change(&inputs)
        return TBBridgeRedial.decide(inputs)
    }

    private let dial = TBBridgeRedial.Decision.dial(receiverIP: "169.254.6.224", localIP: "169.254.171.182")

    func testLinkBackDialsTheLastBridgeAddress() {
        XCTAssertEqual(replugged(), dial)
    }

    func testOnlyOverTheThunderboltBridge() {
        XCTAssertEqual(replugged { $0.transport = .networkLink }, .wait)
    }

    func testNeverWhileConnectedOrAskingThePerson() {
        // A second dial would be a second connection to the receiver.
        XCTAssertEqual(replugged { $0.sessionBusy = true }, .wait)
    }

    func testNeverOnTheWayToSleep() {
        XCTAssertEqual(replugged { $0.sleeping = true }, .wait)
    }

    func testBonjourListedFirstLeavesItToBonjour() {
        // The normal path dials the listed bridge address at once.
        XCTAssertEqual(replugged { $0.listedWithBridgeAddress = true }, .wait)
    }

    func testNothingRememberedNothingToDial() {
        XCTAssertEqual(replugged { $0.rememberedAddress = "" }, .wait)
    }

    func testOnlyALinkLocalAddressIsRedialed() {
        // A Wi-Fi address remembered by mistake would never answer on the bridge.
        XCTAssertEqual(replugged { $0.rememberedAddress = "10.0.0.183" }, .wait)
    }

    func testNoBridgeAddressOnThisMacNoDial() {
        XCTAssertEqual(replugged { $0.localBridgeIP = "" }, .wait)
        XCTAssertEqual(replugged { $0.localBridgeIP = "10.0.0.126" }, .wait)
    }

    func testNoTriggerNoDial() {
        // Without a link coming up or a wake, Bonjour's path alone runs.
        XCTAssertEqual(replugged { $0.secondsSinceTrigger = nil }, .wait)
    }

    func testTheWindowLastsTenSeconds() {
        XCTAssertEqual(replugged { $0.secondsSinceTrigger = 0 }, dial)
        XCTAssertEqual(replugged { $0.secondsSinceTrigger = 9.9 }, dial)
        XCTAssertEqual(replugged { $0.secondsSinceTrigger = 10 }, .wait)
        XCTAssertEqual(replugged { $0.secondsSinceTrigger = 60 }, .wait)
    }

    func testOncePerSecond() {
        XCTAssertEqual(replugged { $0.secondsSinceLastDial = 0.4 }, .wait)
        XCTAssertEqual(replugged { $0.secondsSinceLastDial = 1 }, dial)
    }

    func testAClockThatWentBackDoesNotDial() {
        XCTAssertEqual(replugged { $0.secondsSinceTrigger = -1 }, .wait)
    }
}
