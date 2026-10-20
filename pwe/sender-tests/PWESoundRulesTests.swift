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
}
