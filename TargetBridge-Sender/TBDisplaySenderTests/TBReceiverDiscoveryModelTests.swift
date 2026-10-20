import XCTest
@testable import TargetBridge

/// Tests for the discovered-receiver value model: per-transport address
/// selection and the human-readable summary. These pin down which IP the
/// sender dials for Thunderbolt vs Network Link — the exact decision that
/// determines whether traffic goes over the bridge or the LAN.
final class TBReceiverDiscoveryModelTests: XCTestCase {

    private func makeReceiver(
        serviceName: String = "TargetBridge Test-iMac",
        receiverName: String = "Test-iMac",
        receiverID: String = "",
        preferredIP: String = "192.168.1.64",
        thunderboltIP: String = "",
        usbIP: String = "",
        networkIP: String = "",
        ethernetIP: String = "",
        wifiIP: String = "",
        resolvedIPv4Addresses: [String] = [],
        panelSummary: String = "",
        version: String = "3.1.0",
        supportsHEVCDecode: Bool = true,
        hostName: String? = nil
    ) -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: serviceName,
            receiverName: receiverName,
            receiverID: receiverID,
            preferredIP: preferredIP,
            thunderboltIP: thunderboltIP,
            usbIP: usbIP,
            networkIP: networkIP,
            ethernetIP: ethernetIP,
            wifiIP: wifiIP,
            resolvedIPv4Addresses: resolvedIPv4Addresses,
            panelSummary: panelSummary,
            version: version,
            supportsHEVCDecode: supportsHEVCDecode,
            hostName: hostName
        )
    }

    // MARK: - ip(for:) transport selection

    func testThunderboltTransportPrefersThunderboltIP() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64", thunderboltIP: "169.254.89.80", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "169.254.89.80")
    }

    func testThunderboltTransportNeverDialsTheLANAddress() {
        // A receiver whose bridge has no address yet advertises its Wi-Fi address as `ip`.
        let receiver = makeReceiver(preferredIP: "192.168.1.64", thunderboltIP: "", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "")
    }

    func testThunderboltTransportAcceptsALegacyLinkLocalIP() {
        // Receivers before 3.0 send no `tbIP`; their `ip` is the bridge address.
        let receiver = makeReceiver(preferredIP: "169.254.89.80", thunderboltIP: "")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "169.254.89.80")
    }

    func testThunderboltTransportNeverDialsTheUSBAddress() {
        let receiver = makeReceiver(preferredIP: "169.254.189.3", thunderboltIP: "", usbIP: "169.254.189.3")
        XCTAssertEqual(receiver.ip(for: .thunderboltBridge), "")
    }

    func testNetworkTransportPrefersNetworkIP() {
        let receiver = makeReceiver(preferredIP: "169.254.89.80", thunderboltIP: "169.254.89.80", networkIP: "192.168.1.64")
        XCTAssertEqual(receiver.ip(for: .networkLink), "192.168.1.64")
    }

    func testNetworkTransportNeverDialsTheBridgeAddress() {
        // A receiver announced on the cable only (PWE 1.1 without its network
        // allowed): `ip` and the resolved address are the bridge address.
        let receiver = makeReceiver(
            preferredIP: "169.254.6.224", thunderboltIP: "169.254.6.224", networkIP: "",
            resolvedIPv4Addresses: ["169.254.6.224"]
        )
        XCTAssertEqual(receiver.ip(for: .networkLink), "")
        XCTAssertEqual(receiver.ip(for: .networkLink, localInterfaceIP: "10.0.0.126"), "")
    }

    func testNetworkTransportNeverDialsTheUSBAddressFromTheLAN() {
        let receiver = makeReceiver(preferredIP: "169.254.189.3", usbIP: "169.254.189.3")
        XCTAssertEqual(receiver.ip(for: .networkLink, localInterfaceIP: "192.168.178.93"), "")
    }

    func testNetworkTransportUsesTheWiFiOrEthernetAddressWithoutNetIP() {
        let wifi = makeReceiver(preferredIP: "169.254.6.224", thunderboltIP: "169.254.6.224", wifiIP: "10.0.0.183")
        XCTAssertEqual(wifi.ip(for: .networkLink), "10.0.0.183")
        let ethernet = makeReceiver(preferredIP: "169.254.6.224", thunderboltIP: "169.254.6.224",
                                    ethernetIP: "192.168.1.20", wifiIP: "10.0.0.183")
        XCTAssertEqual(ethernet.ip(for: .networkLink), "192.168.1.20")
    }

    func testNetworkTransportUsesAResolvedNetworkAddress() {
        let receiver = makeReceiver(
            preferredIP: "169.254.6.224", thunderboltIP: "169.254.6.224",
            resolvedIPv4Addresses: ["10.0.0.183", "169.254.6.224"]
        )
        XCTAssertEqual(receiver.ip(for: .networkLink), "10.0.0.183")
    }

    func testNetworkTransportFallsBackToANetworkPreferredIP() {
        // An older receiver that sends only `ip`, and that is a LAN address.
        let receiver = makeReceiver(preferredIP: "192.168.1.64", thunderboltIP: "", networkIP: "")
        XCTAssertEqual(receiver.ip(for: .networkLink), "192.168.1.64")
    }

    func testNetworkTransportUsesUSBIPForLinkLocalLocalInterface() {
        let receiver = makeReceiver(
            preferredIP: "169.254.189.3",
            usbIP: "169.254.189.3",
            networkIP: "192.168.178.101"
        )
        XCTAssertEqual(
            receiver.ip(for: .networkLink, localInterfaceIP: "169.254.190.84"),
            "169.254.189.3"
        )
    }

    func testNetworkTransportKeepsLANIPForLANLocalInterface() {
        let receiver = makeReceiver(
            preferredIP: "169.254.189.3",
            usbIP: "169.254.189.3",
            networkIP: "192.168.178.101"
        )
        XCTAssertEqual(
            receiver.ip(for: .networkLink, localInterfaceIP: "192.168.178.93"),
            "192.168.178.101"
        )
    }

    // MARK: - Identity

    func testLegacyIDCombinesServiceNameAndPreferredIP() {
        let receiver = makeReceiver(serviceName: "TargetBridge Jonathans-iMac", preferredIP: "192.168.1.64")
        XCTAssertEqual(receiver.legacyID, "TargetBridge Jonathans-iMac|192.168.1.64")
        XCTAssertEqual(receiver.id, "service:TargetBridge Jonathans-iMac")
    }

    func testStableIdentityDoesNotChangeWhenTheReceiverIPChanges() {
        let beforeWake = makeReceiver(
            serviceName: "TargetBridge Jonathans-iMac",
            receiverID: "A4E28721-22A7-42A9-89D7-70F3DBB0E906",
            preferredIP: "169.254.89.80"
        )
        let afterWake = makeReceiver(
            serviceName: "TargetBridge Jonathans-iMac (2)",
            receiverID: "A4E28721-22A7-42A9-89D7-70F3DBB0E906",
            preferredIP: "169.254.12.44"
        )

        XCTAssertEqual(beforeWake.id, afterWake.id)
        XCTAssertEqual(beforeWake.stableIdentity, afterWake.stableIdentity)
    }

    func testDifferentReceiversWithTheSameNameRemainDistinct() {
        let first = makeReceiver(receiverID: "A4E28721-22A7-42A9-89D7-70F3DBB0E906")
        let second = makeReceiver(receiverID: "B4E28721-22A7-42A9-89D7-70F3DBB0E906")

        XCTAssertNotEqual(first.id, second.id)
    }

    func testPersistedIdentityMigratesLegacyServiceAndIPValue() {
        let receiver = makeReceiver(
            serviceName: "TargetBridge Jonathans-iMac",
            receiverID: "A4E28721-22A7-42A9-89D7-70F3DBB0E906",
            preferredIP: "169.254.12.44"
        )

        XCTAssertTrue(receiver.matchesPersistedIdentity("receiver:a4e28721-22a7-42a9-89d7-70f3dbb0e906"))
        XCTAssertTrue(receiver.matchesPersistedIdentity("A4E28721-22A7-42A9-89D7-70F3DBB0E906"))
        XCTAssertTrue(receiver.matchesPersistedIdentity("service:TargetBridge Jonathans-iMac"))
        XCTAssertTrue(receiver.matchesPersistedIdentity("TargetBridge Jonathans-iMac|169.254.89.80"))
        XCTAssertFalse(receiver.matchesPersistedIdentity("TargetBridge Other-iMac|169.254.89.80"))
    }

    // MARK: - shortHostName

    func testMalformedAdvertisedIDFallsBackToLegacyIdentity() {
        XCTAssertEqual(makeReceiver(receiverID: "not-a-uuid").id,
                       "service:TargetBridge Test-iMac")
    }

    func testAdvertisedUUIDCaseDoesNotChangePickerIdentity() {
        let uuid = "A4E28721-22A7-42A9-89D7-70F3DBB0E906"
        XCTAssertEqual(makeReceiver(receiverID: uuid).id,
                       makeReceiver(receiverID: uuid.lowercased()).id)
    }

    func testShortHostNameStripsTrailingDotAndDomain() {
        let receiver = makeReceiver(hostName: "Jonathans-iMac.local.")
        XCTAssertEqual(receiver.shortHostName, "Jonathans-iMac")
    }

    func testShortHostNameNilWhenHostMissingOrEmpty() {
        XCTAssertNil(makeReceiver(hostName: nil).shortHostName)
        XCTAssertNil(makeReceiver(hostName: "").shortHostName)
    }

    // MARK: - displayText

    func testDisplayTextShowsBothTransportsWhenAvailable() {
        let receiver = makeReceiver(
            thunderboltIP: "169.254.89.80",
            usbIP: "169.254.189.3",
            networkIP: "192.168.1.64",
            hostName: "Jonathans-iMac.local."
        )
        XCTAssertEqual(receiver.displayText, "Jonathans-iMac (TB 169.254.89.80 · USB 169.254.189.3 · NET 192.168.1.64)")
    }

    func testDisplayTextSingleTransportOnly() {
        XCTAssertEqual(makeReceiver(thunderboltIP: "169.254.89.80").displayText, "169.254.89.80")
        XCTAssertEqual(makeReceiver(networkIP: "192.168.1.64").displayText, "192.168.1.64")
    }

    func testDisplayTextFallsBackToPreferredIPWithoutTransportIPs() {
        let receiver = makeReceiver(preferredIP: "192.168.1.64")
        XCTAssertEqual(receiver.displayText, "192.168.1.64")
    }

    func testDisplayTextAppendsPanelSummary() {
        let receiver = makeReceiver(networkIP: "192.168.1.64", panelSummary: "iMac 5K (5120x2880)")
        XCTAssertEqual(receiver.displayText, "192.168.1.64 · iMac 5K (5120x2880)")
    }

    func testDisplayTextDistinguishesEthernetAndWiFiWhenAdvertised() {
        let receiver = TBDiscoveredReceiver(
            serviceName: "TargetBridge iMac",
            receiverName: "iMac",
            preferredIP: "192.168.178.101",
            thunderboltIP: "",
            usbIP: "",
            networkIP: "192.168.178.101",
            ethernetIP: "10.77.77.2",
            wifiIP: "192.168.178.101",
            resolvedIPv4Addresses: ["10.77.77.2", "192.168.178.101"],
            panelSummary: "",
            version: "3.2.1",
            supportsHEVCDecode: true,
            hostName: "iMac.local."
        )
        XCTAssertEqual(receiver.displayText, "iMac (ETH 10.77.77.2 · Wi-Fi 192.168.178.101)")
    }
}
