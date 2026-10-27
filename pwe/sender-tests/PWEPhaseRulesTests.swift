import XCTest
@testable import TargetBridge

/// The PWE window's phase as a function of engine state (PWEPhaseRules).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEPhaseRulesTests: XCTestCase {
    private let imac = PWEReceiver(id: "imac", name: "iMac", detail: "")
    private let other = PWEReceiver(id: "other", name: "Studio iMac", detail: "")

    private func state(
        _ status: TBDisplaySenderStatusState? = .ready,
        retrying: Bool = false,
        connected: Bool = false,
        streaming: Bool = false,
        receivers: [PWEReceiver]? = nil,
        target: PWEReceiver?? = nil,
        permission: Bool = true,
        security: PWESecurityState = .none
    ) -> PWEEngineState {
        PWEEngineState(
            hasPermission: permission,
            status: status,
            isConnected: connected,
            isStreaming: streaming,
            retrying: retrying,
            receivers: receivers ?? [imac],
            target: target ?? imac,
            security: security)
    }

    /// Runs a sequence of engine states through the rules the way the model does.
    private func phases(_ states: [PWEEngineState]) -> [PWEPhase] {
        var held: PWEReason?
        return states.map { state in
            held = PWEPhaseRules.heldFailure(after: held, state)
            return PWEPhaseRules.phase(state, held: held)
        }
    }

    // MARK: - Basics

    func testPermissionComesFirst() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.captureActive("", "", .extendedDesktop), permission: false), held: nil),
                       .needsPermission)
    }

    func testIdleShowsReadyChooseOrSearching() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.stopped), held: nil), .ready(imac))
        XCTAssertEqual(PWEPhaseRules.phase(state(.ready, receivers: [imac, other], target: .some(nil)), held: nil),
                       .choose([imac, other]))
        XCTAssertEqual(PWEPhaseRules.phase(state(nil, receivers: [], target: .some(nil)), held: nil), .searching)
    }

    func testConnectingStagesAndConnected() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.connecting("10.0.0.2")), held: nil), .connecting(imac, .reaching))
        XCTAssertEqual(PWEPhaseRules.phase(state(.creatingVirtualDisplay), held: nil), .connecting(imac, .preparing))
        XCTAssertEqual(PWEPhaseRules.phase(state(.captureStartedWaitingFirstFrame), held: nil),
                       .connecting(imac, .waitingForPicture))
        XCTAssertEqual(PWEPhaseRules.phase(state(.captureActive("", "", .extendedDesktop)), held: nil), .connected(imac))
    }

    // MARK: - Without automatic connection (item 3)

    func testFailuresExplainThemselvesWithoutRetrying() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.connectionFailed("refused")), held: nil),
                       .interrupted(imac, .couldNotConnect, retrying: false))
        XCTAssertEqual(PWEPhaseRules.phase(state(.connectionClosed("eof")), held: nil),
                       .interrupted(imac, .cableOrReceiverGone, retrying: false))
        XCTAssertEqual(PWEPhaseRules.phase(state(.receiverClosedConnection), held: nil),
                       .interrupted(imac, .receiverQuit, retrying: false))
        XCTAssertEqual(PWEPhaseRules.phase(state(.hevcNoFrames), held: nil),
                       .interrupted(imac, .captureFailed, retrying: false))
    }

    // MARK: - While the engine retries (items 1 and 2)

    func testRetryCycleKeepsTheFailureOnScreen() {
        // Each failed attempt: connecting → failed → stopped (engine reset) → connecting again.
        let cycle = phases([
            state(.connecting("10.0.0.2"), retrying: true),
            state(.connectionFailed("refused"), retrying: true),
            state(.stopped, retrying: true),
            state(.connecting("10.0.0.2"), retrying: true),
            state(.connectionFailed("refused"), retrying: true),
            state(.stopped, retrying: true),
        ])
        XCTAssertEqual(cycle.first, .connecting(imac, .reaching))
        for phase in cycle.dropFirst() {
            XCTAssertEqual(phase, .interrupted(imac, .couldNotConnect, retrying: true))
        }
    }

    func testRetryThatReachesTheIMacShowsProgressThenConnects() {
        let run = phases([
            state(.connectionClosed("eof"), retrying: true),
            state(.stopped, retrying: true),
            state(.connecting("10.0.0.2"), retrying: true),
            state(.waitingDisplayProfile, retrying: true, connected: true),
            state(.captureActive("", "", .extendedDesktop), retrying: true, connected: true, streaming: true),
            state(.stopped, retrying: true),
        ])
        XCTAssertEqual(run, [
            .interrupted(imac, .cableOrReceiverGone, retrying: true),
            .interrupted(imac, .cableOrReceiverGone, retrying: true),
            .interrupted(imac, .cableOrReceiverGone, retrying: true),
            .connecting(imac, .preparing),
            .connected(imac),
            // A fresh drop after a good connection holds nothing from before.
            .connecting(imac, .reaching),
        ])
    }

    func testRetryingWithTheIMacGoneSaysSo() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.stopped, retrying: true, receivers: [], target: .some(nil)), held: nil),
                       .interrupted(nil, .cableOrReceiverGone, retrying: true))
        // A known reason beats the generic one: the receiver app quitting also leaves Bonjour.
        XCTAssertEqual(PWEPhaseRules.phase(state(.stopped, retrying: true, receivers: [], target: .some(nil)),
                                           held: .receiverQuit),
                       .interrupted(nil, .receiverQuit, retrying: true))
    }

    func testEngineStoppingItsRetriesEndsTryingAgain() {
        // A Stop from the menu bar: retrying ends, the session is stopped.
        var held: PWEReason? = .couldNotConnect
        let stopped = state(.stopped, retrying: false)
        held = PWEPhaseRules.heldFailure(after: held, stopped)
        XCTAssertNil(held)
        XCTAssertEqual(PWEPhaseRules.phase(stopped, held: held), .ready(imac))
        // A capture failure suspends retrying: the failure stays, without "Trying again…".
        XCTAssertEqual(PWEPhaseRules.phase(state(.noFirstFrame, retrying: false), held: nil),
                       .interrupted(imac, .captureFailed, retrying: false))
    }

    func testFirstAttemptWhileRetryingShowsConnecting() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.ready, retrying: true), held: nil), .connecting(imac, .reaching))
    }

    // MARK: - Pairing

    func testACodeToTypeBeatsTheConnectingStatus() {
        // The iMac shows its code while the TCP connection is up.
        let waiting = state(.waitingDisplayProfile, retrying: true, connected: true,
                            security: .needsCode(secondsLeft: 60, identityChanged: false))
        XCTAssertEqual(PWEPhaseRules.phase(waiting, held: nil),
                       .security(imac, .needsCode(secondsLeft: 60, identityChanged: false)))
        XCTAssertEqual(PWEPhaseRules.phase(state(.connecting("x"), security: .checkingCode), held: nil),
                       .security(imac, .checkingCode))
    }

    func testAClosedPairingStepIsNotACableFailure() {
        // The engine closes the connection after a wrong code and reports "connection failed".
        let wrong = state(.connectionFailed("PWE: wrong pairing code"), retrying: true, security: .wrongCode)
        XCTAssertNil(PWEPhaseRules.heldFailure(after: nil, wrong))
        XCTAssertEqual(PWEPhaseRules.phase(wrong, held: nil), .security(imac, .wrongCode))
        // The next code goes out: connecting, with no old failure held over it.
        var held = PWEPhaseRules.heldFailure(after: nil, wrong)
        let next = state(.connecting("x"), retrying: true)
        held = PWEPhaseRules.heldFailure(after: held, next)
        XCTAssertEqual(PWEPhaseRules.phase(next, held: held), .connecting(imac, .reaching))
    }

    func testQuestionsAndRefusalsWaitForThePerson() {
        for security in [PWESecurityState.legacyReceiver(previouslyPaired: false), .legacyReceiver(previouslyPaired: true),
                         .refused(.notOnCable), .locked(seconds: 60), .codeExpired] {
            XCTAssertEqual(PWEPhaseRules.phase(state(.stopped, retrying: true, security: security), held: nil),
                           .security(imac, security))
        }
    }

    func testEncryptedOrUnencryptedSessionsAreJustConnected() {
        let live = state(.captureActive("x", "y", .extendedDesktop), connected: true, streaming: true,
                         security: .unencrypted)
        XCTAssertEqual(PWEPhaseRules.phase(live, held: nil), .connected(imac))
        XCTAssertEqual(PWEPhaseRules.phase(state(.connecting("x"), security: .negotiating), held: nil),
                       .connecting(imac, .reaching))
    }

    func testPermissionStillComesFirst() {
        XCTAssertEqual(PWEPhaseRules.phase(state(permission: false, security: .wrongCode), held: nil), .needsPermission)
    }

    // MARK: - The first connection's extra lines (PWEFirstConnectionRules)

    /// Runs phases through the rule the way the model does; setup finishes the
    /// first time the lines show.
    private func tips(_ phases: [PWEPhase], setupFinished: Bool = false) -> [Bool] {
        var shows = false
        var finished = setupFinished
        return phases.map { phase in
            shows = PWEFirstConnectionRules.showsTips(previously: shows, setupFinished: finished, phase: phase)
            if shows { finished = true }
            return shows
        }
    }

    func testTheFirstConnectionShowsTheLines() {
        XCTAssertEqual(tips([.ready(imac), .connecting(imac, .reaching), .connected(imac)]), [false, false, true])
    }

    func testAReconnectToApplyASettingKeepsThem() {
        XCTAssertEqual(tips([.connected(imac), .connecting(imac, .reaching), .connected(imac)]), [true, true, true])
    }

    func testTheyNeverComeBackOnceTheConnectionEnds() {
        let afterDisconnect = tips([.connected(imac), .ready(imac), .connecting(imac, .reaching), .connected(imac)])
        XCTAssertEqual(afterDisconnect, [true, false, false, false])
        let afterCable = tips([.connected(imac), .interrupted(imac, .cableOrReceiverGone, retrying: true),
                               .connected(imac)])
        XCTAssertEqual(afterCable, [true, false, false])
    }

    func testSomeoneWhoHasConnectedBeforeNeverSeesThem() {
        XCTAssertEqual(tips([.connecting(imac, .reaching), .connected(imac)], setupFinished: true), [false, false])
    }

    func testAPairingQuestionIsNotTheFirstConnection() {
        XCTAssertEqual(tips([.security(imac, .needsCode(secondsLeft: 60, identityChanged: false)), .connected(imac)]),
                       [false, true])
    }
}

/// Use as Display after a failure shows Connecting, not the old failure (T28).
final class PWEFreshStatusTests: XCTestCase {
    private let imac = PWEReceiver(id: "imac", name: "iMac", detail: "")

    private func phase(_ status: TBDisplaySenderStatusState, stale: String?) -> (PWEPhase, Bool) {
        let fresh = PWEPhaseRules.freshStatus(status, stale: stale)
        let state = PWEEngineState(status: fresh.status, retrying: true, receivers: [imac], target: imac)
        let held = PWEPhaseRules.heldFailure(after: nil, state)
        return (PWEPhaseRules.phase(state, held: held), fresh.stillStale)
    }

    func testTheOldFailureReadsAsConnecting() {
        let old = TBDisplaySenderStatusState.connectionClosed("unplugged")
        let (shown, stale) = phase(old, stale: String(describing: old))
        XCTAssertEqual(shown, .connecting(imac, .reaching))
        XCTAssertTrue(stale)
    }

    func testANewStatusEndsIt() {
        let old = TBDisplaySenderStatusState.connectionClosed("unplugged")
        let (shown, stale) = phase(.waitingDisplayProfile, stale: String(describing: old))
        XCTAssertEqual(shown, .connecting(imac, .preparing))
        XCTAssertFalse(stale)
    }

    func testANewFailureShows() {
        let old = TBDisplaySenderStatusState.connectionClosed("unplugged")
        let (shown, stale) = phase(.connectionFailed("timed out"), stale: String(describing: old))
        XCTAssertEqual(shown, .interrupted(imac, .couldNotConnect, retrying: true))
        XCTAssertFalse(stale)
    }

    func testWithoutAPressNothingChanges() {
        let (shown, _) = phase(.connectionClosed("unplugged"), stale: nil)
        XCTAssertEqual(shown, .interrupted(imac, .cableOrReceiverGone, retrying: true))
    }
}
