import Network
import XCTest
@testable import TargetBridge

/// T39: the heartbeat goes out while the main thread is blocked, and stops
/// once main has not answered for the dead-man limit.
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEHeartbeatTests: XCTestCase {
    /// Collects what the heartbeat sends, from its queue.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [Data] = []
        func add(_ packet: Data) { lock.lock(); packets.append(packet); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return packets }
    }

    /// Stands in for the NWConnection under a PWESecureLink.
    private final class Transport: PWEPacketTransport, @unchecked Sendable {
        let sink = Sink()
        func send(content: Data?, contentContext: NWConnection.ContentContext, isComplete: Bool,
                  completion: NWConnection.SendCompletion) {
            if let content { sink.add(content) }
            if case .contentProcessed(let handler) = completion { handler(nil) }
        }
        func cancel() {}
    }

    private func sequence(of packet: Data) throws -> UInt64 {
        XCTAssertEqual(packet[packet.startIndex + 4], TBMonitorPacketType.heartbeat.rawValue)
        let length = Int(TBMonitorProtocol.readBE32(packet, offset: 0))
        XCTAssertEqual(packet.count, 4 + length)
        let json = packet.subdata(in: packet.startIndex + 5 ..< packet.endIndex)
        return try JSONDecoder().decode(TBMonitorHeartbeat.self, from: json).sequence
    }

    func testHeartbeatsKeepFlowingWhileTheMainThreadIsBlocked() throws {
        XCTAssertTrue(Thread.isMainThread)
        let sink = Sink()
        let heartbeat = PWEHeartbeat(interval: 0.25) { sink.add($0) }
        heartbeat.start()
        defer { heartbeat.stop() }
        // Block the main thread for 3 s, as on the test Mac: upstream's Timer sent nothing.
        Thread.sleep(forTimeInterval: 3)
        let sent = sink.all
        XCTAssertGreaterThanOrEqual(sent.count, 9, "beats while main was blocked: \(sent.count)")
        XCTAssertEqual(try sent.map(sequence), Array(1...UInt64(sent.count)))
    }

    func testHeartbeatsGoThroughTheLinkOffTheMainThread() throws {
        let transport = Transport()
        let link = PWESecureLink(transport: transport, plaintext: true)
        let heartbeat = PWEHeartbeat(link: link, interval: 0.2)
        heartbeat.start()
        defer { heartbeat.stop() }
        Thread.sleep(forTimeInterval: 1.1)
        let sent = transport.sink.all
        XCTAssertGreaterThanOrEqual(sent.count, 4)
        XCTAssertEqual(try sent.map(sequence), Array(1...UInt64(sent.count)))
    }

    func testTheFirstBeatWaitsOneInterval() {
        let sink = Sink()
        let heartbeat = PWEHeartbeat(interval: 0.5) { sink.add($0) }
        heartbeat.start()
        defer { heartbeat.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sink.all.count, 0)
    }

    func testNoBeatAfterStop() {
        let sink = Sink()
        let heartbeat = PWEHeartbeat(interval: 0.1) { sink.add($0) }
        heartbeat.start()
        Thread.sleep(forTimeInterval: 0.35)
        heartbeat.stop()
        let atStop = sink.all.count
        XCTAssertGreaterThanOrEqual(atStop, 2)
        Thread.sleep(forTimeInterval: 0.4)
        // One beat already past its check may still finish; none starts after stop().
        XCTAssertLessThanOrEqual(sink.all.count, atStop + 1)
        heartbeat.start()   // stopped for good: a session starts a new heartbeat
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertLessThanOrEqual(sink.all.count, atStop + 1)
    }

    /// Stands in for the main queue: answers at once, or holds the probes
    /// until `answering` is set again, as a hung main thread would.
    private final class MainStandIn: @unchecked Sendable {
        private let lock = NSLock()
        private var answeringNow = true
        private var held: [@Sendable () -> Void] = []
        var answering: Bool {
            get { lock.lock(); defer { lock.unlock() }; return answeringNow }
            set {
                lock.lock()
                answeringNow = newValue
                let release = newValue ? held : []
                if newValue { held = [] }
                lock.unlock()
                release.forEach { $0() }
            }
        }
        var probe: PWEHeartbeat.MainProbe {
            { [self] answer in
                lock.lock()
                if answeringNow { lock.unlock(); answer(); return }
                held.append(answer)
                lock.unlock()
            }
        }
    }

    func testBeatsStopWhenMainStopsAnswering() throws {
        let sink = Sink()
        let main = MainStandIn()
        main.answering = false
        let heartbeat = PWEHeartbeat(interval: 0.1, mainStallLimit: 0.5, probeMain: main.probe) { sink.add($0) }
        heartbeat.start()
        defer { heartbeat.stop() }
        Thread.sleep(forTimeInterval: 1.0)
        let held = sink.all.count
        // Beats until main has been silent 0.5 s: about five, then none.
        XCTAssertGreaterThanOrEqual(held, 3)
        XCTAssertLessThanOrEqual(held, 6)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(sink.all.count, held, "beats went on while main was silent past the limit")
    }

    func testBeatsResumeWhenMainAnswersAgain() throws {
        let sink = Sink()
        let main = MainStandIn()
        main.answering = false
        let heartbeat = PWEHeartbeat(interval: 0.1, mainStallLimit: 0.5, probeMain: main.probe) { sink.add($0) }
        heartbeat.start()
        defer { heartbeat.stop() }
        Thread.sleep(forTimeInterval: 1.0)
        let held = sink.all.count
        main.answering = true
        Thread.sleep(forTimeInterval: 0.6)
        let sent = sink.all
        XCTAssertGreaterThanOrEqual(sent.count, held + 3, "beats after main answered: \(sent.count - held)")
        // Held beats are skipped, not counted: the sequence has no gaps.
        XCTAssertEqual(try sent.map(sequence), Array(1...UInt64(sent.count)))
    }

    func testTheRealMainQueueAnswersAndBeatsContinue() {
        // The default probe on a live main queue: well past the limit, beats go on.
        let sink = Sink()
        let heartbeat = PWEHeartbeat(interval: 0.1, mainStallLimit: 0.3) { sink.add($0) }
        heartbeat.start()
        defer { heartbeat.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertGreaterThanOrEqual(sink.all.count, 9)
    }

    func testTheDeadManLimitIsThirtySeconds() {
        XCTAssertEqual(PWEHeartbeat.mainStallLimit, 30)
    }

    func testTheSessionHeartbeatIsTwoSeconds() {
        // The receiver closes after 10 s of silence; upstream sent every 2 s.
        XCTAssertEqual(PWEHeartbeat.interval, 2)
    }
}
