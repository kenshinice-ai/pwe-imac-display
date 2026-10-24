import XCTest
@testable import TargetBridge

/// B2: the retry loop waits for an event, with a timeout (PWEWakeSignal).
/// pwe/rebrand.py copies this file into the sender's test target.
@MainActor
final class PWEWakeSignalTests: XCTestCase {
    func testAPokeEndsTheWaitAtOnce() async {
        let signal = PWEWakeSignal()
        let started = ProcessInfo.processInfo.systemUptime
        let waiter = Task { await signal.wait(upTo: 5) }
        while signal.waiting == 0 { await Task.yield() }
        signal.poke()
        let poked = await waiter.value
        XCTAssertTrue(poked)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(signal.waiting, 0)
    }

    func testTheTimeoutEndsTheWait() async {
        let signal = PWEWakeSignal()
        let started = ProcessInfo.processInfo.systemUptime
        let poked = await signal.wait(upTo: 0.2)
        XCTAssertFalse(poked)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.19)
        XCTAssertEqual(signal.waiting, 0)
    }

    func testCancellingEndsTheWait() async {
        let signal = PWEWakeSignal()
        let waiter = Task { await signal.wait(upTo: 5) }
        while signal.waiting == 0 { await Task.yield() }
        waiter.cancel()
        let poked = await waiter.value
        XCTAssertFalse(poked)
    }

    func testNoTimeLeftReturnsAtOnce() async {
        let poked = await PWEWakeSignal().wait(upTo: 0)
        XCTAssertFalse(poked)
    }

    func testOnePokeWakesEveryWaiter() async {
        let signal = PWEWakeSignal()
        let first = Task { await signal.wait(upTo: 5) }
        let second = Task { await signal.wait(upTo: 5) }
        while signal.waiting < 2 { await Task.yield() }
        signal.poke()
        let a = await first.value
        let b = await second.value
        XCTAssertTrue(a && b)
    }
}
