import Foundation

/// How the engine's retry loop (TBSenderAutomation.connectContinuously) paces
/// itself while the iMac is absent (PWERetryPacingTests). Before 1.1.1 every
/// attempt logged a line and waited at most 2 s: a Mac left on its desk with
/// the cable out wrote a line every 2 s and woke the process to match.
enum PWERetryPacing {
    /// The attempts that log: the first three, then every 30th (about once a
    /// minute at 2 s pauses, every 2.5 minutes at 5 s). A connection that
    /// becomes active starts the count again.
    static func logsAttempt(_ attempt: Int) -> Bool {
        attempt <= 3 || attempt % 30 == 0
    }

    /// Up to this long between attempts, as before.
    static let shortPause: TimeInterval = 2
    /// Once the iMac has been absent this long, up to this long. The pause is
    /// still cut short when a bridge redial falls due or the iMac is listed
    /// again, so a replug is noticed as fast as before.
    static let longPause: TimeInterval = 5
    static let longAbsence: TimeInterval = 60

    /// `absentFor`: seconds since the iMac was last connected in this loop;
    /// nil before the first failed attempt.
    static func pauseCap(absentFor: TimeInterval?) -> TimeInterval {
        guard let absentFor, absentFor >= longAbsence else { return shortPause }
        return longPause
    }
}
