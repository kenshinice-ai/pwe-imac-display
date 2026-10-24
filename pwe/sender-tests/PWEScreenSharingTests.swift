import XCTest
@testable import TargetBridge

/// A14 (T50): telling that Screen Sharing shows the iMac in use (PWEScreenSharingRules).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEScreenSharingTests: XCTestCase {
    private let names = ["LL-iMac-2017", "LL-iMac-2017.local.", "LL iMac 2017", "169.254.6.224"]

    func testTheIMacsOwnNameMatches() {
        XCTAssertTrue(PWEScreenSharingRules.isViewing(windowTitles: ["LL iMac 2017"], names: names))
        XCTAssertTrue(PWEScreenSharingRules.isViewing(windowTitles: ["ll-imac-2017.local"], names: names))
        XCTAssertTrue(PWEScreenSharingRules.isViewing(windowTitles: ["Other", "169.254.6.224 (Observe)"], names: names))
    }

    func testAPartialNameOrAddressDoesNot() {
        // Review 2026-10-24: "iMac" matched "Office iMac", "10.0.0.5" matched "10.0.0.51".
        XCTAssertFalse(PWEScreenSharingRules.isViewing(windowTitles: ["Office iMac"], names: ["iMac"]))
        XCTAssertFalse(PWEScreenSharingRules.isViewing(windowTitles: ["10.0.0.51"], names: ["10.0.0.5"]))
        XCTAssertFalse(PWEScreenSharingRules.isViewing(windowTitles: ["LL iMac 2017 Pro"], names: names))
        XCTAssertTrue(PWEScreenSharingRules.isViewing(windowTitles: ["LL iMac 2017 (Observe)"], names: names))
        XCTAssertTrue(PWEScreenSharingRules.isViewing(windowTitles: ["10.0.0.5"], names: ["10.0.0.5"]))
        XCTAssertTrue(PWEScreenSharingRules.isAddress("fe80::1%bridge0"))
        XCTAssertFalse(PWEScreenSharingRules.isAddress("iMac 2017"))
    }

    func testAnotherMacDoesNot() {
        XCTAssertFalse(PWEScreenSharingRules.isViewing(windowTitles: ["Office Mac mini"], names: names))
        XCTAssertFalse(PWEScreenSharingRules.isViewing(windowTitles: [], names: names))
        XCTAssertFalse(PWEScreenSharingRules.isViewing(windowTitles: ["LL iMac 2017"], names: []))
    }

    func testVeryShortNamesAreIgnored() {
        XCTAssertFalse(PWEScreenSharingRules.isViewing(windowTitles: ["Den's MacBook"], names: ["De", ""]))
    }

    func testNormalising() {
        XCTAssertEqual(PWEScreenSharingRules.normalized("LL-iMac_2017.local."), "ll imac 2017")
        XCTAssertEqual(PWEScreenSharingRules.normalized("  Studio   iMac "), "studio imac")
    }

    func testTheNoticeInBothLanguages() {
        XCTAssertEqual(PWEStrings(language: .english).screenSharingNotice,
                       "You're viewing this iMac with Screen Sharing, so the picture repeats itself. To use the iMac directly, disconnect Screen Sharing.")
        XCTAssertEqual(PWEStrings(language: .chinese).screenSharingNotice,
                       "你在用屏幕共享看这台 iMac，画面会无限重复。要直接用 iMac，先断开屏幕共享。")
    }
}
