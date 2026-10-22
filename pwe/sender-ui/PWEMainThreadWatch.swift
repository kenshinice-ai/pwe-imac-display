import CoreFoundation
import Foundation

/// Logs when the main thread stops running for more than 2 s, and when it runs
/// again (T39: on the test Mac the sender went silent for 10 s and left no trace
/// of why). A background timer posts a ping and notes whether it ran:
///
///   - to the main queue: the main thread itself is blocked;
///   - to the main run loop in its default mode only: the run loop is held in
///     another mode (a menu open, a modal panel, a live resize). Upstream's
///     `Timer`s do not fire then, though the main thread is running.
///
/// One line when a stall is noticed, one every 10 s while it lasts, one when it
/// ends. No stack walking. Off: `defaults write com.pwegroup.pweimacdisplay
/// pwe.mainThreadWatch -bool false`, then relaunch.
///
/// It runs only while a session is under way (`watches`): a stall matters when
/// the iMac is waiting on this Mac. Idle, its two wake-ups a second were the
/// app's main cost (1.1.1).
final class PWEMainThreadWatch: @unchecked Sendable {
    static let enabledKey = "pwe.mainThreadWatch"
    static let shared = PWEMainThreadWatch()

    private static let checkEvery: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "pwe.main-thread-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Everything below is read and written on `queue` only.
    private var mainQueue = Probe()
    private var defaultMode = Probe()
    private var saidOff = false

    /// One kind of ping: when the unanswered one was posted, and what was reported.
    private struct Probe {
        var postedAt: TimeInterval?
        var tracker = PWEStallTracker()
    }

    /// The phases the watch runs in: the iMac is being reached, prepared or shown,
    /// or waits for an answer (PWEMainThreadWatchTests).
    static func watches(_ phase: PWEPhase) -> Bool {
        switch phase {
        case .connecting, .connected, .security: return true
        case .needsPermission, .searching, .choose, .ready, .interrupted: return false
        }
    }

    /// Starts or stops the watch to match the phase (PWESenderModel.refresh).
    func update(for phase: PWEPhase, defaults: UserDefaults = .standard) {
        if Self.watches(phase) { start(defaults: defaults) } else { stop() }
    }

    func start(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: Self.enabledKey) as? Bool ?? true else {
            if !saidOff { PWELog.note("[pwe] main thread watch is off (\(Self.enabledKey))") }
            saidOff = true
            return
        }
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.checkEvery, repeating: Self.checkEvery,
                           leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops the timer and forgets any ping in flight, so one answered after a
    /// restart is not read as a stall.
    func stop() {
        queue.async { [self] in
            guard let timer else { return }
            timer.cancel()
            self.timer = nil
            mainQueue = Probe()
            defaultMode = Probe()
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func check() {
        let now = Self.now
        if let report = mainQueue.tracker.check(now: now, pendingSince: mainQueue.postedAt) {
            log(report, what: .mainThread)
        }
        // While the main thread itself is stuck, the run loop is too: say it once.
        if !mainQueue.tracker.isStalled,
           let report = defaultMode.tracker.check(now: now, pendingSince: defaultMode.postedAt) {
            log(report, what: .defaultMode)
        }
        if mainQueue.postedAt == nil {
            mainQueue.postedAt = now
            DispatchQueue.main.async { [self] in
                let ranAt = Self.now
                queue.async { [self] in answered(\.mainQueue, at: ranAt, what: .mainThread) }
            }
        }
        if defaultMode.postedAt == nil {
            defaultMode.postedAt = now
            let loop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                let ranAt = Self.now
                queue.async { [self] in answered(\.defaultMode, at: ranAt, what: .defaultMode) }
            }
            CFRunLoopWakeUp(loop)
        }
    }

    private func answered(_ probe: ReferenceWritableKeyPath<PWEMainThreadWatch, Probe>, at ranAt: TimeInterval,
                          what: PWEStallTracker.Subject) {
        guard let postedAt = self[keyPath: probe].postedAt else { return }
        self[keyPath: probe].postedAt = nil
        if let report = self[keyPath: probe].tracker.answered(at: ranAt, postedAt: postedAt) {
            log(report, what: what)
        }
    }

    private func log(_ report: PWEStallTracker.Report, what: PWEStallTracker.Subject) {
        PWELog.note(PWEStallTracker.line(report, what))
    }
}

/// The rule, with no clock and no threads (PWEMainThreadWatchTests).
struct PWEStallTracker: Equatable {
    static let threshold: TimeInterval = 2
    static let repeatEvery: TimeInterval = 10

    enum Subject: Equatable { case mainThread, defaultMode }

    enum Report: Equatable {
        /// Seconds since the unanswered ping was posted.
        case stalled(TimeInterval)
        case stillStalled(TimeInterval)
        /// How long the ping waited before it ran.
        case recovered(TimeInterval)
    }

    private var reportedAt: TimeInterval?

    var isStalled: Bool { reportedAt != nil }

    /// A periodic look. `pendingSince`: when the ping that has not run yet was
    /// posted; nil when none is waiting. Measuring from the ping, not from the
    /// last look, keeps a late look (App Nap) from reading as a stall.
    mutating func check(now: TimeInterval, pendingSince: TimeInterval?) -> Report? {
        guard let pendingSince else { return nil }
        let waited = now - pendingSince
        guard waited > Self.threshold else { return nil }
        guard let reportedAt else {
            self.reportedAt = now
            return .stalled(waited)
        }
        guard now - reportedAt >= Self.repeatEvery else { return nil }
        self.reportedAt = now
        return .stillStalled(waited)
    }

    /// The ping posted at `postedAt` ran at `ranAt`.
    mutating func answered(at ranAt: TimeInterval, postedAt: TimeInterval) -> Report? {
        guard reportedAt != nil else { return nil }
        reportedAt = nil
        return .recovered(ranAt - postedAt)
    }

    static func line(_ report: Report, _ subject: Subject) -> String {
        switch (subject, report) {
        case (.mainThread, .stalled(let s)), (.mainThread, .stillStalled(let s)):
            return "[pwe] main thread stalled \(seconds(s)) s"
        case (.mainThread, .recovered(let s)):
            return "[pwe] main thread running again after \(seconds(s)) s"
        case (.defaultMode, .stalled(let s)), (.defaultMode, .stillStalled(let s)):
            return "[pwe] main run loop out of its default mode \(seconds(s)) s (menu, modal or resize)"
        case (.defaultMode, .recovered(let s)):
            return "[pwe] main run loop back in its default mode after \(seconds(s)) s"
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}
