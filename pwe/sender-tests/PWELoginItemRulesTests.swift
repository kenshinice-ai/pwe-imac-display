import XCTest
@testable import TargetBridge

/// Open at login is registered only for a copy that stays where it is
/// (PWELoginItemRules, the receiver's rule in tb_login_item.m).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWELoginItemRulesTests: XCTestCase {
    private let home = "/Users/lee"

    private func canRegister(_ path: String) -> Bool {
        PWELoginItemRules.canRegister(bundlePath: path, home: home)
    }

    func testACopyInApplicationsMayBeRegistered() {
        XCTAssertTrue(canRegister("/Applications/PWE Screen Encore.app"))
        XCTAssertTrue(canRegister("/Applications/Utilities/PWE Screen Encore.app"))
        XCTAssertTrue(canRegister("/Users/lee/Applications/PWE Screen Encore.app"))
    }

    func testACopyThatMayNotBeThereAtLoginIsNot() {
        // A mounted disk image or an external drive.
        XCTAssertFalse(canRegister("/Volumes/PWE Screen Encore/PWE Screen Encore.app"))
        // Gatekeeper's randomised read-only mount of an unmoved download.
        XCTAssertFalse(canRegister("/private/var/folders/c2/T/AppTranslocation/1A2B/d/PWE Screen Encore.app"))
        // Downloads, the Desktop, a build folder.
        XCTAssertFalse(canRegister("/Users/lee/Downloads/PWE Screen Encore.app"))
        XCTAssertFalse(canRegister("/Users/lee/Desktop/PWE Screen Encore.app"))
        XCTAssertFalse(canRegister("/Users/lee/Developer/Build/PWE Screen Encore.app"))
        // Another user's Applications folder is not this user's.
        XCTAssertFalse(canRegister("/Users/janet/Applications/PWE Screen Encore.app"))
        // Not an app bundle at all.
        XCTAssertFalse(canRegister("/Applications/PWE Screen Encore"))
        XCTAssertFalse(canRegister("/ApplicationsBackup/PWE Screen Encore.app"))
    }
}
