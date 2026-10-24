import XCTest
@testable import TargetBridge

/// A9: the idle receiver's language goes to one address at a time
/// (TBDisplaySenderService.pweLanguageAddresses, PWESecureOneShot.send(toFirstOf:)).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWELanguagePushTests: XCTestCase {
    func testEachAddressOnceInOrder() {
        // preferredIP, thunderboltIP, thunderboltIPv6, networkIP, as the receiver announces them.
        XCTAssertEqual(TBDisplaySenderService.pweLanguageAddresses(
            ["169.254.6.224", "169.254.6.224", "fe80::1c2b:3cff:fe4d:5e6f%bridge0", ""]),
            ["169.254.6.224", "fe80::1c2b:3cff:fe4d:5e6f%bridge0"])
        XCTAssertEqual(TBDisplaySenderService.pweLanguageAddresses(["", ""]), [])
    }

    func testNoAddressSendsNothing() {
        // Returns at once: no host, no connection.
        PWESecureOneShot.send(Data([1]), toFirstOf: [], expectedID: Data(count: 32))
    }
}
