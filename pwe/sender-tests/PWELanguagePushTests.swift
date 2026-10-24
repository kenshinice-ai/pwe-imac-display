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
        XCTAssertFalse(PWESecureOneShot.send(Data([1]), toFirstOf: [], expectedID: Data(count: 32)))
    }

    /// A dead address ahead of others holds them up 1 s, not 3.
    func testEachAddressBeforeTheLastGetsOneSecond() {
        XCTAssertEqual(PWESecureOneShot.timeout(remaining: 3), 1)
        XCTAssertEqual(PWESecureOneShot.timeout(remaining: 2), 1)
        XCTAssertEqual(PWESecureOneShot.timeout(remaining: 1), 3)
    }
}
