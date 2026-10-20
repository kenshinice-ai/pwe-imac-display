import Combine
import XCTest
@testable import TargetBridge

/// T33 (test Mac 2026-10-20): after a reconnect the picture was up on the iMac
/// but the window, the menu and the menu bar icon kept "Connecting… · Waiting
/// for the picture". The first encoded frame had arrived while startCapture
/// was suspended; the engine then wrote "waiting for the first frame" over
/// captureActive and never moved on.
///
/// The rule tests pin the window's side: a streaming capture that has sent a
/// frame is connected, whatever a stale status says. The session tests drive a
/// real TBDisplaySenderSession through the engine's own setters, deliver its
/// objectWillChange the way PWESenderModel does, and read the phase back.
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEConnectionPhaseTests: XCTestCase {
    private let imac = PWEReceiver(id: "imac", name: "iMac", detail: "")

    // MARK: - Rules

    private func state(_ status: TBDisplaySenderStatusState?, streaming: Bool, firstFrame: Bool,
                       security: PWESecurityState = .encrypted(receiverName: "iMac")) -> PWEEngineState {
        PWEEngineState(status: status, isConnected: true, isStreaming: streaming, hasFirstFrame: firstFrame,
                       receivers: [imac], target: imac, security: security)
    }

    func testAStreamingCaptureWithItsFirstFrameIsConnectedWhateverTheStatusSays() {
        let stale: [TBDisplaySenderStatusState] = [
            .connecting("169.254.6.224"), .testingCable, .waitingDisplayProfile, .creatingVirtualDisplay,
            .startingCapture("5K", .extendedDesktop), .captureStartedWaitingFirstFrame, .ready, .stopped,
        ]
        for status in stale {
            XCTAssertEqual(PWEPhaseRules.phase(state(status, streaming: true, firstFrame: true), held: nil),
                           .connected(imac), "\(status)")
            // Also while the engine retries: a retry loop that is monitoring a live link.
            var retrying = state(status, streaming: true, firstFrame: true)
            retrying.retrying = true
            XCTAssertEqual(PWEPhaseRules.phase(retrying, held: .couldNotConnect), .connected(imac), "\(status)")
        }
    }

    func testWithoutAFrameItStillWaitsForThePicture() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.captureStartedWaitingFirstFrame, streaming: true, firstFrame: false),
                                           held: nil),
                       .connecting(imac, .waitingForPicture))
        XCTAssertEqual(PWEPhaseRules.phase(state(.startingCapture("5K", .extendedDesktop), streaming: false,
                                                 firstFrame: false), held: nil),
                       .connecting(imac, .preparing))
    }

    func testAFailureStillWinsOverTheFrameFlag() {
        // Not "fixed" by hiding a real failure (audit P1-01 acceptance).
        XCTAssertEqual(PWEPhaseRules.phase(state(.receiverClosedConnection, streaming: true, firstFrame: true), held: nil),
                       .interrupted(imac, .receiverQuit, retrying: false))
        XCTAssertEqual(PWEPhaseRules.phase(state(.hevcNoFrames, streaming: true, firstFrame: true), held: nil),
                       .interrupted(imac, .captureFailed, retrying: false))
    }

    func testAQuestionForThePersonStillComesFirst() {
        XCTAssertEqual(PWEPhaseRules.phase(state(.captureActive("", "", .extendedDesktop), streaming: true,
                                                 firstFrame: true, security: .checkingCode), held: nil),
                       .security(imac, .checkingCode))
    }

    // MARK: - A real engine session

    /// The model's way of reading a session: its objectWillChange, delivered on
    /// PWESenderModel.engineUpdates, read through PWEEngineState(session:).
    @MainActor
    private final class Observer {
        var phase: PWEPhase = .searching
        var deliveries = 0
        private var cancellable: AnyCancellable?

        init(_ session: TBDisplaySenderSession, target: PWEReceiver) {
            cancellable = session.objectWillChange
                .receive(on: PWESenderModel.engineUpdates)
                .sink { [weak self, weak session] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        var state = PWEEngineState(session: session)
                        state.receivers = [target]
                        state.target = target
                        self.phase = PWEPhaseRules.phase(state, held: nil)
                        self.deliveries += 1
                    }
                }
        }
    }

    @MainActor
    private func makeSession() -> TBDisplaySenderSession {
        TBDisplaySenderSession(language: .english, largeCursor: false, preventDisplaySleep: false,
                               autoRestartOnWake: false, audioEnabled: false)
    }

    /// Turns the main run loop in `mode` until the observer has seen every change.
    @MainActor
    private func settle(_ observer: Observer, mode: RunLoop.Mode = .default) {
        var quiet = 0
        var last = observer.deliveries
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, quiet < 3 {
            RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.02))
            if observer.deliveries == last { quiet += 1 } else { quiet = 0; last = observer.deliveries }
        }
    }

    private func isCaptureActive(_ status: TBDisplaySenderStatusState) -> Bool {
        if case .captureActive = status { return true }
        return false
    }

    @MainActor
    func testFirstFrameDuringCaptureStartEndsConnected() {
        let session = makeSession()
        let observer = Observer(session, target: imac)
        defer { session.pweTestCaptureEnd() }

        session.pweTestCaptureStart(firstFrameWhileStarting: true)
        settle(observer)

        XCTAssertTrue(isCaptureActive(session.statusState),
                      "the engine keeps captureActive: \(session.statusState)")
        XCTAssertTrue(session.pweHasFirstFrame)
        XCTAssertEqual(observer.phase, .connected(imac))
    }

    @MainActor
    func testFirstFrameAfterCaptureStartEndsConnected() {
        let session = makeSession()
        let observer = Observer(session, target: imac)
        defer { session.pweTestCaptureEnd() }

        session.pweTestCaptureStart(firstFrameWhileStarting: false)
        settle(observer)

        XCTAssertTrue(isCaptureActive(session.statusState), "\(session.statusState)")
        XCTAssertEqual(observer.phase, .connected(imac))
    }

    /// The picture switches Lee made on the test Mac: stop, start, four times,
    /// with the first frame landing early or late.
    @MainActor
    func testRepeatedReconnectsEachEndConnected() {
        let session = makeSession()
        let observer = Observer(session, target: imac)
        defer { session.pweTestCaptureEnd() }

        for (index, early) in [true, true, false, true].enumerated() {
            session.pweTestCaptureStart(firstFrameWhileStarting: early)
            settle(observer)
            XCTAssertEqual(observer.phase, .connected(imac), "switch \(index + 1)")
            XCTAssertTrue(isCaptureActive(session.statusState), "switch \(index + 1): \(session.statusState)")
            session.pweTestCaptureEnd()
            settle(observer)
            XCTAssertEqual(observer.phase, .ready(imac), "after switch \(index + 1)")
        }
    }

    /// While a menu is open the main run loop runs in the event-tracking mode;
    /// engine changes must still reach the model then.
    @MainActor
    func testChangesArriveWhileAMenuIsOpen() {
        let session = makeSession()
        let observer = Observer(session, target: imac)
        defer { session.pweTestCaptureEnd() }

        session.pweTestCaptureStart(firstFrameWhileStarting: true)
        settle(observer, mode: .eventTracking)

        XCTAssertGreaterThan(observer.deliveries, 0)
        XCTAssertEqual(observer.phase, .connected(imac))
    }
}
