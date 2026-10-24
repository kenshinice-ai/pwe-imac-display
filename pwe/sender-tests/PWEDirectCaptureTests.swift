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

    // MARK: - Review 2026-10-24

    private func decide(_ choice: Session.PWEDirectCaptureChoice, online: [CGDirectDisplayID],
                        failed: Bool = false, raw: Bool = false) -> Bool {
        Session.pweExtendedCapturesDirect(choice: choice, virtualDisplayID: virtual, onlineDisplayIDs: online,
                                          directFailed: failed, usesRawNV12: raw)
    }

    func testAFailedDirectStartStaysOnScreenCaptureKit() {
        XCTAssertTrue(decide(.automatic, online: [virtual]))
        // Once it failed on this connection, no display change brings it back:
        // the comparison that restarts capture sees no change, so no restarts.
        XCTAssertFalse(decide(.automatic, online: [virtual], failed: true))
        XCTAssertFalse(decide(.always, online: [virtual, builtIn], failed: true))
    }

    func testRawFramesNeverTakeTheDirectPath() {
        XCTAssertFalse(decide(.always, online: [virtual], raw: true))
        XCTAssertFalse(decide(.automatic, online: [virtual], raw: true))
    }

    func testOnlyDisplayDoesNotWaitForItToBecomeMain() {
        // At a connection's start the virtual display may not be main yet.
        XCTAssertTrue(Session.pweOnlyDisplayOnline(virtual, onlineDisplayIDs: [virtual]))
        XCTAssertTrue(Session.pweOnlyDisplayOnline(virtual, onlineDisplayIDs: [virtual, kCGNullDirectDisplay]))
        XCTAssertFalse(Session.pweOnlyDisplayOnline(virtual, onlineDisplayIDs: [builtIn, virtual]))
        // Offline (asleep, mid-change): not the only display, so no decision for direct.
        XCTAssertFalse(Session.pweOnlyDisplayOnline(virtual, onlineDisplayIDs: []))
        XCTAssertFalse(decide(.automatic, online: [builtIn, virtual]))
        XCTAssertFalse(decide(.automatic, online: [kCGNullDirectDisplay]))
    }

    func testADirectStreamWithNoFrameFallsBackInsteadOfStopping() {
        XCTAssertTrue(Session.pweFallsBackFromDirect(usingDirect: true, canRestart: true))
        // ScreenCaptureKit with no frame, or no restart possible: the session stops as before.
        XCTAssertFalse(Session.pweFallsBackFromDirect(usingDirect: false, canRestart: true))
        XCTAssertFalse(Session.pweFallsBackFromDirect(usingDirect: true, canRestart: false))
    }

    // MARK: - T53 (Mac Studio, 2026-10-24: pmset displaysleepnow)

    func testAStallWhileTheScreensSleepIsNoFailure() {
        XCTAssertFalse(Session.pweStallIsDirectFailure(screensAsleep: true, systemSleeping: false))
        XCTAssertFalse(Session.pweStallIsDirectFailure(screensAsleep: false, systemSleeping: true))
    }

    func testAStallWhileAwakeIsAFailure() {
        XCTAssertTrue(Session.pweStallIsDirectFailure(screensAsleep: false, systemSleeping: false))
    }

    func testAStallJustBeforeTheSleepNoticeIsForgottenAtTheWake() {
        // The screens slept at 100; a stall at 95 came with it, one at 60 did not.
        XCTAssertTrue(Session.pweStallWasTheSleep(stalledAt: 95, screensAsleepAt: 100))
        XCTAssertTrue(Session.pweStallWasTheSleep(stalledAt: 110, screensAsleepAt: 100))
        XCTAssertFalse(Session.pweStallWasTheSleep(stalledAt: 60, screensAsleepAt: 100))
        XCTAssertFalse(Session.pweStallWasTheSleep(stalledAt: nil, screensAsleepAt: 100))
        XCTAssertFalse(Session.pweStallWasTheSleep(stalledAt: 95, screensAsleepAt: nil))
    }
}
