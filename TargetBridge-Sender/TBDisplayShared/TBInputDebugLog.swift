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

    private func write(_ message: String) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let url = base
            .appendingPathComponent("TargetBridge", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("input-debug.log", isDirectory: false)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var line = "\(timestamp) \(message)\n"
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // PWE (1.1.1): a file written before 1.1.1 can hold the iMac's key codes.
        // Once per launch, remove any part that does not start with this
        // version's marker, and say so in the new file.
        if !checkedOldFormat {
            checkedOldFormat = true
            var removed = false
            for part in [url, url.appendingPathExtension("old")] where fileManager.fileExists(atPath: part.path) {
                if !TBInputDebugLog.startsWithMarker(firstLine(of: part)) {
                    try? fileManager.removeItem(at: part)
                    removed = true
                }
            }
            if removed {
                line = "\(timestamp) removed an input log from an earlier version (it could hold key codes)\n" + line
            }
        }

        // PWE: at most TBInputDebugLog.maxBytes, then one older part, and the
        // new part says so on its first line: nothing goes without a trace.
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if TBInputDebugLog.shouldRotate(size: size) {
            let old = url.appendingPathExtension("old")
            try? fileManager.removeItem(at: old)
            try? fileManager.moveItem(at: url, to: old)
            line = "\(timestamp) log rotated at \(TBInputDebugLog.maxBytes) bytes; the part before is \(old.lastPathComponent), and any older part was removed\n" + line
        }

        if !fileManager.fileExists(atPath: url.path) {
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
