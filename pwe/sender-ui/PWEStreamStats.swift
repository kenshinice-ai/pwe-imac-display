import Foundation

/// The sender's per-stream counters (1.1.1), the Mac's half of the receiver's
/// `fps over 10 s` line: frames captured (ScreenCaptureKit or CGDisplayStream
/// callbacks), submitted to the encoder, encoded and sent, and how long each
/// encode took. One log line every `window` seconds while streaming, in the
/// report that Save Report writes.
///
/// Why: the menu showed 60 while the iMac received about 35 (FPS-TRACE
/// 2026-10-24), and only an ffmpeg bench found the encoder. With these lines
/// a report says where frames go missing on any Mac, a new chip included.
///
/// Owned by the video pipeline and touched only on its queue. Recording a
/// frame allocates nothing: encode times go into a ring allocated once.
struct PWEStreamStats {
    static let window: TimeInterval = 10

    private(set) var captured = 0
    private(set) var submitted = 0
    private(set) var encoded = 0
    private(set) var sent = 0
    private var encodeMilliseconds: [Double]
    private var samples = 0

    /// Room for 120 encodes a second over the window; past that the ring keeps the latest.
    init(capacity: Int = 1200) {
        encodeMilliseconds = [Double](repeating: 0, count: max(capacity, 1))
    }

    mutating func recordCaptured() { captured += 1 }
    mutating func recordSubmitted() { submitted += 1 }
    mutating func recordSent() { sent += 1 }

    /// One frame came out of the encoder; `milliseconds` is nil when its
    /// start time did not travel with it.
    mutating func recordEncoded(milliseconds: Double?) {
        encoded += 1
        guard let milliseconds, milliseconds >= 0 else { return }
        encodeMilliseconds[samples % encodeMilliseconds.count] = milliseconds
        samples += 1
    }

    /// The window's line, without the "[pwe] " prefix, and a fresh window.
    /// `label` names the stream (its preset); `elapsed` is the window's real
    /// length, which a busy queue can stretch.
    mutating func summary(label: String, elapsed: TimeInterval) -> String {
        let seconds = max(elapsed, 0.001)
        func rate(_ count: Int) -> String { String(format: "%.1f/s", Double(count) / seconds) }
        let kept = Array(encodeMilliseconds.prefix(min(samples, encodeMilliseconds.count))).sorted()
        let encode: String
        if kept.isEmpty {
            encode = "encode n/a"
        } else {
            encode = String(format: "encode p50 %.1f ms p95 %.1f ms",
                            Self.percentile(kept, 0.50), Self.percentile(kept, 0.95))
        }
        let line = "stream \(Int(seconds.rounded())) s (\(label)): captured \(rate(captured)) submitted \(rate(submitted)) "
            + "encoded \(rate(encoded)) sent \(rate(sent)) \(encode)"
        captured = 0
        submitted = 0
        encoded = 0
        sent = 0
        samples = 0
        return line
    }

    /// Nearest rank: the smallest value with at least `p` of the values at or below it.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    // MARK: - Can this Mac keep up with 5K 60 (plan A, 1.1.1)

    /// Remembered per Mac: its encoder fell behind at 5K 60. The Picture menu
    /// then suggests Smooth · 4K 60 under it; the choice stays the person's.
    /// Why: an M1 MacBook encodes about 47 5K frames a second, an M4 Max over
    /// 100 (docs/pwe/PLAN-5k60-2026-10-28.md), so one answer cannot fit every Mac.
    static let fiveK60FallsBehindKey = "pwe.fiveK60FallsBehind"

    private var behindStreak = 0

    /// What one window says about the encoder at 5K 60: true when it kept up,
    /// false when it fell behind, nil when the screen was too still to tell.
    static func keepsUp(capturedPerSecond captured: Double, sentPerSecond sent: Double) -> Bool? {
        guard captured >= 45 else { return nil }
        if sent >= 57 { return true }
        if sent < 55 && captured - sent >= 3 { return false }
        return nil
    }

    /// Call before `summary`, while the window's counts are still there. Returns
    /// whether this Mac falls behind at 5K 60 once a window has shown it: true
    /// after two behind windows in a row, false after one that kept up.
    mutating func fiveK60Verdict(elapsed: TimeInterval) -> Bool? {
        let seconds = max(elapsed, 0.001)
        switch Self.keepsUp(capturedPerSecond: Double(captured) / seconds, sentPerSecond: Double(sent) / seconds) {
        case true?:
            behindStreak = 0
            return false
        case false?:
            behindStreak += 1
            return behindStreak >= 2 ? true : nil
        case nil:
            return nil
        }
    }

    // MARK: - Encode timing

    /// The encode's start, carried to the encoder's callback in its frame
    /// reference (a pointer-sized value, never dereferenced).
    static func startToken(now: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: UInt(now))
    }

    static func milliseconds(since token: UnsafeMutableRawPointer?,
                             now: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) -> Double? {
        guard let token else { return nil }
        let start = UInt64(UInt(bitPattern: token))
        guard now >= start else { return nil }
        return Double(now - start) / 1_000_000
    }
}
