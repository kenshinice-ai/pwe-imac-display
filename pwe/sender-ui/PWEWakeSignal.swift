import Foundation

/// Lets the engine's retry loop (TBSenderAutomation) wait for something to
/// happen instead of looking every 250 ms (B2, 1.1.1). While the iMac was
/// absent the loop woke the process about four times a second to ask whether
/// Bonjour had listed it or a bridge redial had fallen due. Both only change
/// when an event arrives: Bonjour's list changes, or a link comes up or the
/// Mac wakes (TBBridgeRedial.noteTrigger). Those call `poke()`; the loop waits
/// with `wait(upTo:)`, whose timeout keeps every pause as short as before.
@MainActor
final class PWEWakeSignal {
    static let automation = PWEWakeSignal()

    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Ends every wait under way (they return true).
    func poke() {
        let woken = waiters
        waiters.removeAll()
        woken.values.forEach { $0.resume(returning: true) }
    }

    /// Waits until `poke()`, `seconds` pass or the task is cancelled. True
    /// only for a poke. A wait of zero or less returns false at once.
    func wait(upTo seconds: TimeInterval) async -> Bool {
        guard seconds > 0, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters[id] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    self?.end(id, poked: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.end(id, poked: false) }
        }
    }

    /// Waits under way, for tests.
    var waiting: Int { waiters.count }

    private func end(_ id: UUID, poked: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: poked)
    }
}
