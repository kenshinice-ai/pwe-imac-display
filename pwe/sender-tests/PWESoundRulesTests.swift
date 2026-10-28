import ScreenCaptureKit
import XCTest
@testable import TargetBridge

/// When a change of the sound choice reconnects (PWESoundRules, T14).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWESoundRulesTests: XCTestCase {
    private func reconnects(from: PWESound, to: PWESound, capturingAudio: Bool) -> Bool {
        PWESoundRules.needsReconnect(relayOn: to != .onlyThisMac, relayWasOn: from != .onlyThisMac,
                                     capturingAudio: capturingAudio)
    }

    func testOnlyThisMacToTheIMacReconnectsToAddAudio() {
        XCTAssertTrue(reconnects(from: .onlyThisMac, to: .onlyIMac, capturingAudio: false))
        XCTAssertTrue(reconnects(from: .onlyThisMac, to: .both, capturingAudio: false))
    }

    func testBetweenIMacModesNeverReconnects() {
        XCTAssertFalse(reconnects(from: .onlyIMac, to: .both, capturingAudio: true))
        XCTAssertFalse(reconnects(from: .both, to: .onlyIMac, capturingAudio: true))
    }

    func testToOnlyThisMacNeverReconnects() {
        XCTAssertFalse(reconnects(from: .onlyIMac, to: .onlyThisMac, capturingAudio: true))
        XCTAssertFalse(reconnects(from: .both, to: .onlyThisMac, capturingAudio: true))
    }

    func testBackToTheIMacOverACaptureWithAudioDoesNotReconnect() {
        // Relay was on when this picture started, then turned off: audio is still captured.
        XCTAssertFalse(reconnects(from: .onlyThisMac, to: .onlyIMac, capturingAudio: true))
    }

    /// K2: the direct path's sound stream stopped; choosing an iMac option
    /// again rebuilds it.
    func testARelayThatLostItsSoundReconnects() {
        XCTAssertTrue(reconnects(from: .onlyIMac, to: .onlyIMac, capturingAudio: false))
        XCTAssertTrue(reconnects(from: .both, to: .onlyIMac, capturingAudio: false))
    }

    /// K2: a sound stream's stop is acted on only for the running stream.
    func testOnlyTheRunningSoundStreamsStopCounts() {
        typealias Session = TBDisplaySenderSession
        XCTAssertTrue(Session.pweAuxAudioCallbackIsCurrent(sameCapture: true, sameStream: true, directRunning: true))
        XCTAssertFalse(Session.pweAuxAudioCallbackIsCurrent(sameCapture: false, sameStream: true, directRunning: true))
        XCTAssertFalse(Session.pweAuxAudioCallbackIsCurrent(sameCapture: true, sameStream: false, directRunning: true))
        XCTAssertFalse(Session.pweAuxAudioCallbackIsCurrent(sameCapture: true, sameStream: true, directRunning: false))
        XCTAssertEqual(Session.pweAuxAudioRetryDelays, [2, 5, 10])
    }

    /// K2: a stop callback for a stream that is not the session's (here: none
    /// running) leaves the session as it is.
    @MainActor func testAStaleStopCallbackChangesNothing() {
        let session = TBDisplaySenderSession(language: .english, largeCursor: false, preventDisplaySleep: false,
                                             autoRestartOnWake: false, audioEnabled: true)
        var changes = 0
        let watch = session.objectWillChange.sink { _ in changes += 1 }
        session.pweAuxAudioStopped(epoch: 99, stream: nil, message: "test")
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(session.pweCapturingAudio)
        watch.cancel()
    }
}
