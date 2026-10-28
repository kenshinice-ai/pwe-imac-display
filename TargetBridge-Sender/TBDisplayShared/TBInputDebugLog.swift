import ApplicationServices
import Foundation

private final class TBAsyncInputDebugLogWriter: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let writeQueue = DispatchQueue(label: "fd.tbdisplaysender.input-debug-log", qos: .utility)
    private var checkedOldFormat = false

    func enqueue(_ message: String) {
        writeQueue.async { [self] in
            write(message)
        }
    }

    /// PWE (C2): at launch, before anything is written. A file written before
    /// 1.1.1 can hold the iMac's key codes; any part that does not start with
    /// this version's marker is removed, and the new file says so.
    func removeOldFormat() {
        writeQueue.async { [self] in
            if removeOldFormatOnce() {
                write("removed an input log from an earlier version (it could hold key codes)")
            }
        }
    }

    private var url: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("input-debug.log", isDirectory: false)
    }

    /// True when it removed something. Runs once per launch, on `writeQueue`.
    private func removeOldFormatOnce() -> Bool {
        guard !checkedOldFormat else { return false }
        checkedOldFormat = true
        var removed = false
        for part in [url, url.appendingPathExtension("old")] where fileManager.fileExists(atPath: part.path) {
            if !TBInputDebugLog.startsWithMarker(firstLine(of: part)) {
                try? fileManager.removeItem(at: part)
                removed = true
            }
        }
        return removed
    }

    private func write(_ message: String) {
        let url = self.url
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var line = "\(timestamp) \(message)\n"
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // A write before the launch's clean-up (removeOldFormat) still does it first.
        if removeOldFormatOnce() {
            line = "\(timestamp) removed an input log from an earlier version (it could hold key codes)\n" + line
        }

        // PWE: at most TBInputDebugLog.maxBytes, then one older part, and the
        // new part says so on its first line: nothing goes without a trace.
        // If the older part cannot be replaced, the file starts over in place
        // (and says so) rather than growing and retrying on every line.
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        var startedOver = false
        if TBInputDebugLog.shouldRotate(size: size) {
            let old = url.appendingPathExtension("old")
            try? fileManager.removeItem(at: old)
            if (try? fileManager.moveItem(at: url, to: old)) != nil {
                line = "\(timestamp) log rotated at \(TBInputDebugLog.maxBytes) bytes; the part before is \(old.lastPathComponent), and any older part was removed\n" + line
            } else {
                try? Data().write(to: url)
                startedOver = true
                line = "\(timestamp) log started over: \(old.lastPathComponent) could not be replaced\n" + line
            }
        }

        if startedOver || !fileManager.fileExists(atPath: url.path) {
            line = "\(timestamp) \(TBInputDebugLog.formatMarker)\n" + line
        }
        guard let data = line.data(using: .utf8) else { return }
        if fileManager.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func firstLine(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        return String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}

@MainActor
enum TBInputDebugLog {
    private static let writer = TBAsyncInputDebugLogWriter()
    private static var inputEventCount: UInt64 = 0
    private static let inputEventBurstLimit: UInt64 = 20
    private static let inputEventSampleInterval: UInt64 = 100

    private static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("input-debug.log", isDirectory: false)
    }

    static func log(_ message: String) {
        writer.enqueue(message)
    }

    /// PWE (C2): removes an input log from before 1.1.1 at launch (it could
    /// hold key codes), instead of waiting for the first line to be written.
    static func removeOldLogAtLaunch() {
        writer.removeOldFormat()
    }

    /// PWE (1.1.1): an event from the iMac. With PWE_INPUT_DEBUG=1, the first
    /// 20 and every 100th are written in full. Otherwise none is written on its
    /// own: they are counted, one line per 10 s at most (InputTally), so the
    /// log shows neither which keys nor when each was pressed.
    static func receivedEvent(count: UInt64, kind: String, dx: Int?, dy: Int?, scrollX: Int?, scrollY: Int?,
                              keyCode: UInt16?) {
        if detailed {
            guard count <= inputEventBurstLimit || count.isMultiple(of: inputEventSampleInterval) else { return }
            log(receivedEventLine(count: count, kind: kind, dx: dx, dy: dy, scrollX: scrollX, scrollY: scrollY,
                                  keyCode: keyCode, detailed: true))
        } else if let line = tally.add(now: ProcessInfo.processInfo.systemUptime) {
            log(line)
        }
    }

    private static var tally = InputTally()

    /// PWE: whether this Mac lets the app inject input, written when it changes
    /// (read at most every 5 s), not for each event as upstream did. With
    /// PWE_INPUT_DEBUG=1, upstream's line for each event.
    static func injectionState(context: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if detailed {
            if context == "mouseMove" {
                logInputEvent("sender input injection state trusted=\(AXIsProcessTrusted()) context=\(context)")
            } else {
                log("sender input injection state trusted=\(AXIsProcessTrusted()) context=\(context)")
            }
            return
        }
        if let checked = trustedCheckedAt, now - checked < 5 { return }
        trustedCheckedAt = now
        let trusted = AXIsProcessTrusted()
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        log("sender input injection trusted=\(trusted)")
    }

    private static var trustedCheckedAt: TimeInterval?
    private static var lastTrusted: Bool?

    /// Mouse motion can arrive hundreds of times per second. Keep the first few
    /// records plus a periodic sample, without putting file I/O on the input path.
    static func logInputEvent(_ message: @autoclosure () -> String) {
        inputEventCount &+= 1
        let count = inputEventCount

        guard count <= inputEventBurstLimit || count.isMultiple(of: inputEventSampleInterval) else { return }
        log(message())
    }

    static var currentLogPath: String {
        logURL.path
    }

    // MARK: - PWE: what a release build writes

    /// PWE (1.1.1): the file is capped at 1 MB with one older part beside it;
    /// upstream let it grow without end.
    nonisolated static let maxBytes = 1_048_576

    nonisolated static func shouldRotate(size: Int) -> Bool { size >= maxBytes }

    /// PWE (1.1.1): the first line of every file this version starts, rotated
    /// or new. A file without it was written by 1.1.0 or upstream and is removed.
    nonisolated static let formatMarker = "input log format 2: kind and count only unless PWE_INPUT_DEBUG=1"

    nonisolated static func startsWithMarker(_ firstLine: String) -> Bool {
        firstLine.contains(formatMarker)
    }

    /// PWE (1.1.1): the iMac's key codes, pointer movements and which modifier
    /// keys changed are written only with `PWE_INPUT_DEBUG=1` in the
    /// environment, never by default. Key codes in sequence can spell out
    /// what was typed on the iMac's keyboard; by default a line says what
    /// kind of event it was and how many there have been.
    nonisolated static let detailed = ProcessInfo.processInfo.environment["PWE_INPUT_DEBUG"] == "1"

    nonisolated static func receivedEventLine(count: UInt64, kind: String, dx: Int?, dy: Int?, scrollX: Int?,
                                              scrollY: Int?, keyCode: UInt16?, detailed: Bool = detailed) -> String {
        guard detailed else { return "sender received #\(count) kind=\(kind)" }
        return "sender received #\(count) kind=\(kind) dx=\(dx ?? 0) dy=\(dy ?? 0) sx=\(scrollX ?? 0) sy=\(scrollY ?? 0) key=\(keyCode ?? 0)"
    }

    /// `modifiersHeld`: how many modifier keys are down after the change.
    /// Written only with PWE_INPUT_DEBUG=1 (the detailed form); the short form
    /// stays for a caller that needs one.
    nonisolated static func remoteModifierLine(keyCode: UInt16, isDown: Bool, flags: UInt64, modifiersHeld: Int,
                                               detailed: Bool = detailed) -> String {
        guard detailed else { return "sender remote modifier change (\(modifiersHeld) held)" }
        return "sender remote modifier key=\(keyCode) down=\(isDown) flags=\(flags)"
    }

    /// A shortcut binding fired: which one only in the detailed form.
    nonisolated static func bindingLine(trigger: String, action: String, detailed: Bool = detailed) -> String {
        detailed ? "binding MATCH: trigger=\(trigger) -> inject \(action)" : "binding matched; injecting its shortcut"
    }

    /// System Events refused a shortcut: its error number, or the whole reply
    /// (which quotes the script, and so the shortcut) in the detailed form.
    nonisolated static func injectErrorLine(_ info: NSDictionary, detailed: Bool = detailed) -> String {
        if detailed { return "system-events inject error: \(info)" }
        let number = (info[NSAppleScript.errorNumber] as? NSNumber).map { "\($0)" } ?? "?"
        return "system-events inject error \(number)"
    }
}

/// PWE (1.1.1): counts the iMac's input events and gives one line per window
/// (10 s by default) once the window has passed and another event arrives.
struct InputTally {
    static let window: TimeInterval = 10
    private(set) var count = 0
    private var since: TimeInterval?

    mutating func add(now: TimeInterval, window: TimeInterval = InputTally.window) -> String? {
        if since == nil { since = now }
        count += 1
        guard let start = since, now - start >= window else { return nil }
        let line = "input: \(count) events from the iMac in \(Int((now - start).rounded())) s"
        count = 0
        since = nil
        return line
    }
}
