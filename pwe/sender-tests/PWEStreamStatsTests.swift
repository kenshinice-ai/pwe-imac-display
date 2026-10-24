import XCTest
@testable import TargetBridge

/// The sender's 10-second stream line (PWEStreamStats).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEStreamStatsTests: XCTestCase {
    func testTheLineGivesRatesAndEncodeTimes() {
        var stats = PWEStreamStats()
        for _ in 0..<589 { stats.recordCaptured() }
        for _ in 0..<500 { stats.recordSubmitted() }
        for index in 0..<496 {
            // 1 ms to 20 ms, evenly: p50 near 10, p95 near 19.
            stats.recordEncoded(milliseconds: 1 + Double(index % 20))
            stats.recordSent()
        }
        let line = stats.summary(label: "native5k60Experimental", elapsed: 10)
        XCTAssertEqual(line, "stream 10 s (native5k60Experimental): captured 58.9/s submitted 50.0/s "
            + "encoded 49.6/s sent 49.6/s encode p50 10.0 ms p95 19.0 ms")
    }

    func testEachWindowStartsAfresh() {
        var stats = PWEStreamStats()
        stats.recordCaptured()
        stats.recordEncoded(milliseconds: 5)
        _ = stats.summary(label: "a", elapsed: 10)
        XCTAssertEqual(stats.captured, 0)
        XCTAssertEqual(stats.encoded, 0)
        XCTAssertEqual(stats.summary(label: "a", elapsed: 10),
                       "stream 10 s (a): captured 0.0/s submitted 0.0/s encoded 0.0/s sent 0.0/s encode n/a")
    }

    func testRatesUseTheRealWindowLength() {
        var stats = PWEStreamStats()
        for _ in 0..<600 { stats.recordSent() }
        XCTAssertTrue(stats.summary(label: "a", elapsed: 12).contains("sent 50.0/s"))
    }

    func testAFullRingKeepsTheLatestEncodes() {
        var stats = PWEStreamStats(capacity: 4)
        for ms in [100.0, 100, 100, 100, 1, 2, 3, 4] { stats.recordEncoded(milliseconds: ms) }
        XCTAssertEqual(stats.encoded, 8)
        XCTAssertTrue(stats.summary(label: "a", elapsed: 10).hasSuffix("encode p50 2.0 ms p95 4.0 ms"))
    }

    func testPercentileIsNearestRank() {
        XCTAssertEqual(PWEStreamStats.percentile([1, 2, 3, 4], 0.5), 2)
        XCTAssertEqual(PWEStreamStats.percentile([1, 2, 3, 4], 0.95), 4)
        XCTAssertEqual(PWEStreamStats.percentile([7], 0.95), 7)
        XCTAssertEqual(PWEStreamStats.percentile([], 0.5), 0)
    }

    func testTheEncodeStartTravelsInTheFrameReference() throws {
        let token = PWEStreamStats.startToken(now: 1_000_000_000)
        XCTAssertEqual(try XCTUnwrap(PWEStreamStats.milliseconds(since: token, now: 1_018_200_000)), 18.2, accuracy: 0.0001)
        XCTAssertNil(PWEStreamStats.milliseconds(since: nil))
        XCTAssertNil(PWEStreamStats.milliseconds(since: token, now: 999))
    }
}
