import Foundation

/// Why the code step asks for a new code.
enum PWECodeNote: Equatable {
    case wrong      // the last code did not match
    case expired    // the last code ran out before it was entered
}

/// The code step follows the connection (T9, T27 and T29 on the test Mac,
/// 2026-10-20). A code is typed only into a live exchange with the iMac:
///   - the link drops or the person cancels: the engine forgets the code
///     (TBDisplaySenderSession.stop) and the next connection asks again;
///   - a wrong or expired code: the Mac asks the iMac for a new one at once,
///     and the code step says why;
///   - five wrong codes: the iMac locks for a minute; the Mac counts down,
///     then asks again.
/// No engine and no clock here, so every rule has a test (PWEPairingRulesTests).
enum PWEPairingRules {
    /// What the code step says after `security`, given what it said before.
    static func note(after previous: PWECodeNote?, _ security: PWESecurityState) -> PWECodeNote? {
        switch security {
        case .wrongCode: return .wrong
        case .codeExpired: return .expired
        // Asking for the new code, showing it, checking it: keep saying why.
        case .negotiating, .needsCode, .checkingCode: return previous
        case .none, .locked, .refused, .legacyReceiver, .encrypted, .unencrypted: return nil
        }
    }

    /// The engine ended an exchange the person cannot finish: ask for a new code.
    static func asksForNewCode(_ security: PWESecurityState) -> Bool {
        security == .wrongCode || security == .codeExpired
    }

    /// Codes that run out unanswered are replaced this many times in a row; then
    /// the Mac stops asking, so an iMac left alone does not show codes all night.
    static let renewals = 2

    static func renewsExpiredCode(expiredInARow: Int) -> Bool { expiredInARow <= renewals }

    /// When the code on screen runs out. The iMac rounds its seconds down; one
    /// more second keeps the Mac from giving up on a code the iMac still shows.
    static func codeDeadline(secondsLeft: Int, shownAt: Date) -> Date {
        shownAt.addingTimeInterval(TimeInterval(max(secondsLeft, 0) + 1))
    }

    /// When a lock ends, from the seconds the iMac gave (rounded up there).
    static func lockEnd(seconds: Int, lockedAt: Date) -> Date {
        lockedAt.addingTimeInterval(TimeInterval(max(seconds, 1)))
    }

    /// How long after the lock ends the Mac asks again: covers the trip.
    static let lockGrace: TimeInterval = 0.5

    /// Whole seconds left for a countdown: never 0 while time is left.
    static func secondsLeft(until end: Date, now: Date) -> Int {
        max(Int(end.timeIntervalSince(now).rounded(.up)), 0)
    }

    /// Forgetting `receiver` ends the session (T37): it is encrypted, and with
    /// this iMac's key (`expectedID`: the key the session's Bonjour hint names),
    /// or, without a hint, with an iMac of this name.
    static func sessionUses(_ receiver: PWEPairedReceiver, security: PWESecurityState, expectedID: Data?) -> Bool {
        guard case .encrypted(let name) = security else { return false }
        if let expectedID { return PWEPairingStore.hex(expectedID) == receiver.id.lowercased() }
        return name == receiver.name
    }

    /// An encrypted session began with an iMac the paired list does not show:
    /// read the list again, so Settings › Advanced shows a pairing as it finishes.
    /// `sessionID`: the key id the session's Bonjour hint names; without a hint,
    /// the iMac's name. Only once the list has been read (Settings opened): no
    /// keychain reads for a list no one has looked at.
    static func pairedListIsStale(_ security: PWESecurityState, sessionID: Data?, listLoaded: Bool,
                                  listed: [PWEPairedReceiver]) -> Bool {
        guard listLoaded, case .encrypted(let name) = security else { return false }
        guard let sessionID else { return !listed.contains { $0.name == name } }
        let hex = PWEPairingStore.hex(sessionID)
        return !listed.contains { $0.id.lowercased() == hex }
    }

    /// While the Mac asks for a new code, the window stays on the code step,
    /// unless the attempt failed (then the usual failure shows).
    static func holdsCodeStep(_ note: PWECodeNote?, _ state: PWEEngineState) -> PWESecurityState? {
        guard let note, state.security == .negotiating, let status = state.status else { return nil }
        switch status {
        case .connecting, .testingCable, .waitingDisplayProfile:
            return note == .wrong ? .wrongCode : .codeExpired
        default:
            return nil
        }
    }
}
