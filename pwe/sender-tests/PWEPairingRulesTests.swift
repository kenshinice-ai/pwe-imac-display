import XCTest
@testable import TargetBridge

/// The code step follows the connection (PWEPairingRules; T9, T27, T29 on the
/// test Mac, 2026-10-20). pwe/rebrand.py copies this file into the sender's test target.
final class PWEPairingRulesTests: XCTestCase {
    private let imac = PWEReceiver(id: "imac", name: "iMac", detail: "")
    private let code = PWESecurityState.needsCode(secondsLeft: 59, identityChanged: false)

    private func state(_ status: TBDisplaySenderStatusState?, _ security: PWESecurityState,
                       note: PWECodeNote? = nil, retrying: Bool = true) -> PWEEngineState {
        PWEEngineState(status: status, retrying: retrying, receivers: [imac], target: imac,
                       security: security, codeNote: note)
    }

    /// Security states in, notes and phases out, the way the model runs them.
    private func run(_ states: [(TBDisplaySenderStatusState?, PWESecurityState)]) -> [(PWECodeNote?, PWEPhase)] {
        var note: PWECodeNote?
        var held: PWEReason?
        return states.map { status, security in
            note = PWEPairingRules.note(after: note, security)
            let engine = state(status, security, note: note)
            held = PWEPhaseRules.heldFailure(after: held, engine)
            return (note, PWEPhaseRules.phase(engine, held: held))
        }
    }

    // MARK: - Notes

    func testWrongCodeIsSaidUntilTheNextCodeIsEntered() {
        let notes = run([
            (.waitingDisplayProfile, .checkingCode),
            (.connectionFailed("wrong"), .wrongCode),
            (.connecting("10.0.0.2"), .negotiating),
            (.waitingDisplayProfile, code),
            (.waitingDisplayProfile, .checkingCode),
            (.waitingDisplayProfile, .encrypted(receiverName: "iMac")),
        ]).map(\.0)
        XCTAssertEqual(notes, [nil, .wrong, .wrong, .wrong, .wrong, nil])
    }

    func testANewNoteReplacesTheOld() {
        XCTAssertEqual(PWEPairingRules.note(after: .wrong, .codeExpired), .expired)
        XCTAssertEqual(PWEPairingRules.note(after: .expired, .wrongCode), .wrong)
    }

    func testLosingTheLinkOrALockClearsTheNote() {
        XCTAssertNil(PWEPairingRules.note(after: .wrong, .none))
        XCTAssertNil(PWEPairingRules.note(after: .wrong, .locked(seconds: 60)))
        XCTAssertNil(PWEPairingRules.note(after: .expired, .refused(.notOnCable)))
    }

    func testOnlyWrongAndExpiredCodesAskForANewOne() {
        XCTAssertTrue(PWEPairingRules.asksForNewCode(.wrongCode))
        XCTAssertTrue(PWEPairingRules.asksForNewCode(.codeExpired))
        for security: PWESecurityState in [.none, .negotiating, code, .checkingCode, .locked(seconds: 60),
                                           .refused(.cancelled), .legacyReceiver(previouslyPaired: false)] {
            XCTAssertFalse(PWEPairingRules.asksForNewCode(security), "\(security)")
        }
    }

    // MARK: - Phases

    /// T27/T9: after a wrong code the window stays on the code step while the Mac
    /// asks for the new code, then shows the field again; no Connecting flash.
    func testAskingForANewCodeStaysOnTheCodeStep() {
        let phases = run([
            (.connectionFailed("wrong"), .wrongCode),
            (.connecting("10.0.0.2"), .negotiating),
            (.waitingDisplayProfile, .negotiating),
            (.waitingDisplayProfile, code),
        ]).map(\.1)
        XCTAssertEqual(phases, [
            .security(imac, .wrongCode),
            .security(imac, .wrongCode),
            .security(imac, .wrongCode),
            .security(imac, code),
        ])
    }

    /// T29: the code ran out; the same, with the expiry said.
    func testAnExpiredCodeIsReplaced() {
        let phases = run([
            (.waitingDisplayProfile, code),
            (.connectionFailed("expired"), .codeExpired),
            (.connecting("10.0.0.2"), .negotiating),
            (.waitingDisplayProfile, code),
        ])
        XCTAssertEqual(phases.map(\.1), [
            .security(imac, code),
            .security(imac, .codeExpired),
            .security(imac, .codeExpired),
            .security(imac, code),
        ])
        XCTAssertEqual(phases.last?.0, .expired)
    }

    /// The new code could not be fetched (the cable is out): the usual failure shows.
    func testAFailedRequestShowsTheFailure() {
        let phases = run([
            (.connectionFailed("wrong"), .wrongCode),
            (.connecting("10.0.0.2"), .negotiating),
            (.connectionFailed("no route"), .none),
        ]).map(\.1)
        XCTAssertEqual(phases.last, .interrupted(imac, .couldNotConnect, retrying: true))
    }

    /// T9: the link dropped while the code was shown. The engine forgets the code
    /// (needsCode becomes none), so the window leaves the code step at once.
    func testALostLinkLeavesTheCodeStep() {
        let phases = run([
            (.waitingDisplayProfile, code),
            (.connectionClosed("unplugged"), .none),
            (.connecting("10.0.0.2"), .none),
        ]).map(\.1)
        XCTAssertEqual(phases[0], .security(imac, code))
        XCTAssertEqual(phases[1], .interrupted(imac, .cableOrReceiverGone, retrying: true))
        XCTAssertEqual(phases[2], .interrupted(imac, .cableOrReceiverGone, retrying: true))
    }

    /// A first connection is not held on the code step: there is no note.
    func testAFirstConnectionShowsConnecting() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.connecting("10.0.0.2"), .negotiating), held: nil),
                       .connecting(imac, .reaching))
    }

    /// T27: five wrong codes lock the iMac; the window says so.
    func testALockShowsTheLock() {
        let phases = run([
            (.connectionFailed("wrong"), .wrongCode),
            (.connecting("10.0.0.2"), .negotiating),
            (.connectionFailed("locked"), .locked(seconds: 60)),
        ])
        XCTAssertEqual(phases.last?.1, .security(imac, .locked(seconds: 60)))
        XCTAssertNil(phases.last?.0)
    }

    // MARK: - Time

    func testTheCodeRunsOutASecondAfterTheIMacSays() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(PWEPairingRules.codeDeadline(secondsLeft: 59, shownAt: now), now.addingTimeInterval(60))
        XCTAssertEqual(PWEPairingRules.codeDeadline(secondsLeft: -3, shownAt: now), now.addingTimeInterval(1))
    }

    func testTheLockCountsDownInWholeSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let end = PWEPairingRules.lockEnd(seconds: 60, lockedAt: now)
        XCTAssertEqual(end, now.addingTimeInterval(60))
        XCTAssertEqual(PWEPairingRules.secondsLeft(until: end, now: now), 60)
        XCTAssertEqual(PWEPairingRules.secondsLeft(until: end, now: now.addingTimeInterval(0.2)), 60)
        XCTAssertEqual(PWEPairingRules.secondsLeft(until: end, now: now.addingTimeInterval(59.6)), 1)
        XCTAssertEqual(PWEPairingRules.secondsLeft(until: end, now: now.addingTimeInterval(60)), 0)
        XCTAssertEqual(PWEPairingRules.lockEnd(seconds: 0, lockedAt: now), now.addingTimeInterval(1))
    }

    func testUnansweredCodesAreRenewedTwice() {
        XCTAssertTrue(PWEPairingRules.renewsExpiredCode(expiredInARow: 1))
        XCTAssertTrue(PWEPairingRules.renewsExpiredCode(expiredInARow: 2))
        XCTAssertFalse(PWEPairingRules.renewsExpiredCode(expiredInARow: 3))
    }
}
