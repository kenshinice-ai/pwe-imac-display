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

    // MARK: - IPv6 link-local (T34 bridges, RC4 Q3 wake)

    private let receiver6 = "fe80::1c5d:cde7:9ef:fc5b"

    /// Woke a second ago; the last session ran over IPv6; this Mac's bridge has
    /// its link-local address but no IPv4 one yet (DHCP).
    private func woke6(_ change: (inout TBBridgeRedial.Inputs) -> Void = { _ in }) -> TBBridgeRedial.Decision {
        replugged {
            $0.rememberedAddress = receiver6
            $0.localBridgeIP = ""
            $0.cableBridgesIPv6 = ["bridge0"]
            change(&$0)
        }
    }

    func testAnIPv6SessionIsRedialedOnTheCableBridge() {
        XCTAssertEqual(woke6(), .dial(receiverIP: "\(receiver6)%bridge0", localIP: ""))
        // A local IPv4 address does not matter to an IPv6 dial.
        XCTAssertEqual(woke6 { $0.localBridgeIP = "169.254.171.182" },
                       .dial(receiverIP: "\(receiver6)%bridge0", localIP: ""))
    }

    func testIPv6NeedsExactlyOneCableBridge() {
        // No link-local address on a listed bridge yet: wait for the next look.
        XCTAssertEqual(woke6 { $0.cableBridgesIPv6 = [] }, .wait)
        // Two cable bridges: which one is the iMac on? Leave it to Bonjour.
        XCTAssertEqual(woke6 { $0.cableBridgesIPv6 = ["bridge0", "bridge1"] }, .wait)
    }

    func testIPv6KeepsEveryOtherRule() {
        // Above all: never while this Mac still holds a session. The receiver
        // hands its connection to a new cable dial after 2.5 s of silence.
        XCTAssertEqual(woke6 { $0.sessionBusy = true }, .wait)
        XCTAssertEqual(woke6 { $0.sleeping = true }, .wait)
        XCTAssertEqual(woke6 { $0.listedWithBridgeAddress = true }, .wait)
        XCTAssertEqual(woke6 { $0.secondsSinceTrigger = nil }, .wait)
        XCTAssertEqual(woke6 { $0.secondsSinceTrigger = 10 }, .wait)
        XCTAssertEqual(woke6 { $0.secondsSinceLastDial = 0.5 }, .wait)
        XCTAssertEqual(woke6 { $0.transport = .networkLink }, .wait)
    }

    func testOnlyALinkLocalIPv6AddressIsRedialed() {
        XCTAssertEqual(woke6 { $0.rememberedAddress = "2001:db8::1" }, .wait)
        // Remembered without a scope; a stored scope is not trusted.
        XCTAssertEqual(woke6 { $0.rememberedAddress = "\(self.receiver6)%en0" }, .wait)
    }

    func testWhatIsRemembered() {
        XCTAssertEqual(TBBridgeRedial.rememberable("169.254.6.224%bridge0"), "169.254.6.224")
        XCTAssertEqual(TBBridgeRedial.rememberable("169.254.6.224"), "169.254.6.224")
        XCTAssertEqual(TBBridgeRedial.rememberable("\(receiver6)%bridge0"), receiver6)
        XCTAssertEqual(TBBridgeRedial.rememberable("10.0.0.183"), "")
        XCTAssertEqual(TBBridgeRedial.rememberable("2001:db8::1"), "")
        XCTAssertEqual(TBBridgeRedial.rememberable(""), "")
    }
}
