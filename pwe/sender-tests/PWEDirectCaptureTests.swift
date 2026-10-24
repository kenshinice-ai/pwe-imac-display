import XCTest
@testable import TargetBridge

/// Which path captures the extended desktop (TBDisplaySenderSession.pweExtendedUsesDirectStream):
/// the direct CGDisplayStream when the iMac's virtual display is the only
/// display, ScreenCaptureKit otherwise unless asked for.
/// pwe/rebrand.py copies this file into the sender's test target.
@MainActor
final class PWEDirectCaptureTests: XCTestCase {
    private typealias Session = TBDisplaySenderSession
    private let virtual: CGDirectDisplayID = 7
    private let builtIn: CGDirectDisplayID = 1

    private func onlyVirtual(main: CGDirectDisplayID, online: [CGDirectDisplayID]) -> Bool {
        Session.shouldUseHeadlessVirtualDisplay(virtualDisplayID: virtual, mainDisplayID: main, onlineDisplayIDs: online)
    }

    private func defaults(_ value: Bool?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "pwe.tests.directCapture")!
        defaults.removePersistentDomain(forName: "pwe.tests.directCapture")
        if let value { defaults.set(value, forKey: Session.pweDirectCaptureExtendedKey) }
        return defaults
    }

    func testAHeadlessMacUsesTheDirectStreamByItself() {
        // Mac Studio, only the iMac attached (Lee, 2026-10-24).
        let headless = onlyVirtual(main: virtual, online: [virtual])
        XCTAssertTrue(headless)
        XCTAssertTrue(Session.pweExtendedUsesDirectStream(choice: .automatic, onlyVirtualDisplayOnline: headless))
    }

    func testALaptopKeepsScreenCaptureKitUnlessAskedFor() {
        let laptop = onlyVirtual(main: builtIn, online: [builtIn, virtual])
        XCTAssertFalse(laptop)
        XCTAssertFalse(Session.pweExtendedUsesDirectStream(choice: .automatic, onlyVirtualDisplayOnline: laptop))
        XCTAssertTrue(Session.pweExtendedUsesDirectStream(choice: .always, onlyVirtualDisplayOnline: laptop))
        // The virtual display made main beside a physical one is still not alone.
        XCTAssertFalse(onlyVirtual(main: virtual, online: [builtIn, virtual]))
    }

    func testNeverTurnsItOffEvenWhenHeadless() {
        XCTAssertFalse(Session.pweExtendedUsesDirectStream(choice: .never, onlyVirtualDisplayOnline: true))
    }

    func testTheSwitches() {
        XCTAssertEqual(Session.pweDirectCaptureChoice(environment: [:], defaults: defaults(nil)), .automatic)
        XCTAssertEqual(Session.pweDirectCaptureChoice(environment: [:], defaults: defaults(true)), .always)
        XCTAssertEqual(Session.pweDirectCaptureChoice(environment: [:], defaults: defaults(false)), .never)
        // The environment wins over the defaults key, for testing.
        XCTAssertEqual(Session.pweDirectCaptureChoice(environment: ["PWE_DIRECT_CAPTURE": "1"], defaults: defaults(false)), .always)
        XCTAssertEqual(Session.pweDirectCaptureChoice(environment: ["PWE_DIRECT_CAPTURE": "0"], defaults: defaults(true)), .never)
        XCTAssertEqual(Session.pweDirectCaptureChoice(environment: ["PWE_DIRECT_CAPTURE": "yes"], defaults: defaults(nil)), .automatic)
        XCTAssertEqual(Session.pweDirectCaptureExtendedKey, "PWEDirectCaptureExtended")
    }

    func testBGRAIsOnlyAnExperiment() {
        XCTAssertFalse(Session.pweSCKUsesBGRA(environment: [:]))
        XCTAssertTrue(Session.pweSCKUsesBGRA(environment: ["PWE_SCK_BGRA": "1"]))
    }
}
