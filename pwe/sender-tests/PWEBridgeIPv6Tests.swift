import Network
import XCTest
@testable import TargetBridge

/// The IPv6 link-local path over the Thunderbolt Bridge (T34): which address
/// the sender dials, how it scopes a receiver's `tbIP6` to this Mac's bridge,
/// and that Network.framework reaches a scoped link-local address.
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEBridgeIPv6Tests: XCTestCase {
    private let receiverV6 = "fe80::1c2:3ff:fe04:506"
    private var scopedV6: String { "\(receiverV6)%bridge0" }

    private func receiver(
        preferredIP: String = "",
        thunderboltIP: String = "",
        thunderboltIPv6: String = "",
        usbIP: String = "",
        networkIP: String = "",
        resolvedIPv4Addresses: [String] = []
    ) -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: "TargetBridge iMac", receiverName: "iMac",
            preferredIP: preferredIP, thunderboltIP: thunderboltIP, thunderboltIPv6: thunderboltIPv6,
            usbIP: usbIP, networkIP: networkIP, resolvedIPv4Addresses: resolvedIPv4Addresses,
            panelSummary: "", version: "1.1.0", supportsHEVCDecode: true, hostName: "iMac.local."
        )
    }

    // MARK: - Which address the bridge dials

    func testBridgeDialsIPv6WhileTheReceiverHasNoIPv4() {
        XCTAssertEqual(receiver(thunderboltIPv6: scopedV6).ip(for: .thunderboltBridge), scopedV6)
    }

    func testBridgeKeepsIPv4FirstWhenThereIsOne() {
        let both = receiver(preferredIP: "169.254.6.224", thunderboltIP: "169.254.6.224", thunderboltIPv6: scopedV6)
        XCTAssertEqual(both.ip(for: .thunderboltBridge), "169.254.6.224")
    }

    func testBridgeKeepsALegacyLinkLocalIPFirst() {
        let legacy = receiver(preferredIP: "169.254.89.80", thunderboltIPv6: scopedV6)
        XCTAssertEqual(legacy.ip(for: .thunderboltBridge), "169.254.89.80")
    }

    func testBridgeStillWaitsWithoutEitherAddress() {
        // Wi-Fi `ip` only, no tbIP, no tbIP6: as before, nothing to dial.
        XCTAssertEqual(receiver(preferredIP: "192.168.1.64", networkIP: "192.168.1.64").ip(for: .thunderboltBridge), "")
    }

    func testNetworkLinkNeverDialsTheBridgeIPv6() {
        XCTAssertEqual(receiver(thunderboltIPv6: scopedV6).ip(for: .networkLink), "")
        XCTAssertEqual(receiver(thunderboltIPv6: scopedV6).ip(for: .networkLink, localInterfaceIP: "169.254.3.3"), "")
        let withLAN = receiver(thunderboltIPv6: scopedV6, networkIP: "10.0.0.183")
        XCTAssertEqual(withLAN.ip(for: .networkLink), "10.0.0.183")
    }

    func testOnlyAScopedBridgeLinkLocalAddressIsKept() {
        XCTAssertEqual(receiver(thunderboltIPv6: receiverV6).thunderboltIPv6, "", "unscoped")
        XCTAssertEqual(receiver(thunderboltIPv6: "\(receiverV6)%en0").thunderboltIPv6, "", "not a bridge")
        XCTAssertEqual(receiver(thunderboltIPv6: "2001:db8::5%bridge0").thunderboltIPv6, "", "not link-local")
        XCTAssertEqual(receiver(thunderboltIPv6: "169.254.6.224").thunderboltIPv6, "", "IPv4")
        XCTAssertEqual(receiver(thunderboltIPv6: scopedV6).thunderboltIPv6, scopedV6)
    }

    func testDisplayTextShowsTheIPv6AddressOnlyWithoutIPv4() {
        XCTAssertEqual(receiver(thunderboltIPv6: scopedV6).displayText, "iMac (\(scopedV6))")
        XCTAssertEqual(
            receiver(preferredIP: "169.254.6.224", thunderboltIP: "169.254.6.224", thunderboltIPv6: scopedV6).displayText,
            "iMac (169.254.6.224)")
    }

    // MARK: - Scoping tbIP6 to this Mac's bridge

    func testScopeComesFromTheResolvedAddress() {
        let scoped = TBConnectionDiagnostics.scopedBridgeIPv6(
            advertised: receiverV6,
            resolved: ["fe80::99%en0", "fe80:0:0:0:1c2:3ff:fe04:506%bridge0"],
            localBridgeInterfaces: ["bridge0", "bridge100"])
        XCTAssertEqual(scoped, scopedV6)
    }

    func testAResolvedAddressOnAnotherInterfaceDoesNotCount() {
        // The same address heard on Wi-Fi is not the cable; one local bridge decides.
        let scoped = TBConnectionDiagnostics.scopedBridgeIPv6(
            advertised: receiverV6, resolved: ["\(receiverV6)%en0"], localBridgeInterfaces: ["bridge0"])
        XCTAssertEqual(scoped, scopedV6)
        XCTAssertEqual(TBConnectionDiagnostics.scopedBridgeIPv6(
            advertised: receiverV6, resolved: ["\(receiverV6)%en0"], localBridgeInterfaces: []), "")
    }

    func testSeveralBridgesAndNoResolvedAddressGiveNothing() {
        XCTAssertEqual(TBConnectionDiagnostics.scopedBridgeIPv6(
            advertised: receiverV6, resolved: [], localBridgeInterfaces: ["bridge0", "bridge100"]), "")
    }

    func testOnlyALinkLocalUnscopedAdvertisementIsScoped() {
        for advertised in ["2001:db8::5", "fd03::5", "169.254.6.224", "\(receiverV6)%bridge0", "", "not-an-address"] {
            XCTAssertEqual(TBConnectionDiagnostics.scopedBridgeIPv6(
                advertised: advertised, resolved: ["\(receiverV6)%bridge0"], localBridgeInterfaces: ["bridge0"]),
                "", advertised)
        }
    }

    func testScopedBridgeIPv6Recognition() {
        XCTAssertTrue(TBConnectionDiagnostics.isScopedBridgeIPv6(scopedV6))
        XCTAssertFalse(TBConnectionDiagnostics.isScopedBridgeIPv6(receiverV6))
        XCTAssertFalse(TBConnectionDiagnostics.isScopedBridgeIPv6("\(receiverV6)%en0"))
        XCTAssertFalse(TBConnectionDiagnostics.isScopedBridgeIPv6("169.254.6.224%bridge0"))
        XCTAssertFalse(TBConnectionDiagnostics.isScopedBridgeIPv6("\(receiverV6)%"))
        XCTAssertEqual(TBConnectionDiagnostics.ipv6Scope(of: scopedV6), "bridge0")
        XCTAssertNil(TBConnectionDiagnostics.ipv6Scope(of: receiverV6))
    }

    // MARK: - Network.framework reaches a scoped link-local address

    /// The dial the session builds for "fe80::…%bridge0" (TBDisplaySenderSession.connect),
    /// over this Mac's own link-local loopback address, fe80::1%lo0.
    func testScopedLinkLocalDialConnects() throws {
        guard let address = IPv6Address("fe80::1%lo0"), address.interface != nil else {
            throw XCTSkip("no fe80::1 on lo0")
        }
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = expectation(description: "listener accepted")
        accepted.assertForOverFulfill = false
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            accepted.fulfill()
        }
        let listening = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: .global())
        wait(for: [listening], timeout: 5)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port)

        let connection = NWConnection(host: .ipv6(address), port: port, using: .tcp)
        let ready = expectation(description: "dial ready")
        connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        connection.start(queue: .global())
        defer { connection.cancel() }
        wait(for: [ready, accepted], timeout: 5)
    }
}
