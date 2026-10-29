import XCTest
@testable import TargetBridge

/// What PWE sets on a session before it connects, and when this Mac mutes
/// for the iMac (review 2026-10-24).
/// pwe/rebrand.py copies this file into the sender's test target.
@MainActor
final class PWEConnectionPrepTests: XCTestCase {
    private func makeSession() -> TBDisplaySenderSession {
        TBDisplaySenderSession(language: .english, largeCursor: false, preventDisplaySleep: false,
                               autoRestartOnWake: false, audioEnabled: false)
    }

    /// Render matching left on by the Full Console would turn Smooth · 4K 60
    /// into a 1920 × 1080 desktop; a PWE connection turns it off.
    func testAPWEConnectionTurnsRenderMatchingOff() {
        let session = makeSession()
        session.matchRenderToStream = true
        session.capturePreset = .crisp2160p60
        PWESenderModel.prepareForPWEConnection(session)
        XCTAssertFalse(session.matchRenderToStream)
        XCTAssertNil(TBDisplaySenderSession.virtualDisplayModeOverride(
            preset: session.capturePreset, matchRenderToStream: session.matchRenderToStream,
            captureSource: session.captureSource))
        // Already off: left alone.
        PWESenderModel.prepareForPWEConnection(session)
        XCTAssertFalse(session.matchRenderToStream)
    }

    /// The Mac mutes only while a capture really records its sound: on the
    /// direct path a failed audio stream must not leave sound nowhere.
    func testTheMacMutesOnlyWhileItsSoundIsCaptured() {
        XCTAssertTrue(PWESenderModel.relaysSound(streaming: true, audioEnabled: true, addonAvailable: true, capturingAudio: true))
        XCTAssertFalse(PWESenderModel.relaysSound(streaming: true, audioEnabled: true, addonAvailable: true, capturingAudio: false))
        XCTAssertFalse(PWESenderModel.relaysSound(streaming: false, audioEnabled: true, addonAvailable: true, capturingAudio: true))
    }
}
