import AppKit
import OSLog
import UniformTypeIdentifiers

/// PWE's own log lines (the `[pwe]` lines), in the unified log under this
/// subsystem. NSLog from the shipped app reached only stderr, never the log:
/// neither `log stream` nor the diagnostic report saw a single `[pwe]` line on
/// the test Mac (T38, 2026-10-21). Notice level is kept on disk; the text is
/// public because it carries no personal data (names of iMacs at most).
enum PWELog {
    private static let logger = Logger(subsystem: "com.pwegroup.pweimacdisplay", category: "pwe")

    static func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        PWELogFile.shared.append(line)
    }
}

/// PWE (1.1.1, T52): the same lines in a file of our own,
/// `~/Library/Logs/PWE Screen Encore/sender.log`, as the receiver keeps
/// `receiver.log`. On the Mac Studio (macOS 27.0.1, 2026-10-24) the unified log
/// held no line from this process at all, so the report came out empty; the
/// file does not depend on it. Rotated to `sender.old.log` at 2 MB.
final class PWELogFile: @unchecked Sendable {
    static let shared = PWELogFile(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PWE Screen Encore", isDirectory: true))

    static let maxBytes = 2 * 1024 * 1024
    let url: URL
    private let oldURL: URL
    private let queue = DispatchQueue(label: "com.pwegroup.pweimacdisplay.logfile")
    private var handle: FileHandle?

    init(directory: URL) {
        url = directory.appendingPathComponent("sender.log")
        oldURL = directory.appendingPathComponent("sender.old.log")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    func append(_ line: String, at date: Date = Date()) {
        let text = Self.stamp(date) + " " + line + "\n"
        queue.async { self.write(Data(text.utf8)) }
    }

    /// Waits for the lines already handed to `append` (tests, and the report).
    func flush() { queue.sync {} }

    private func write(_ data: Data) {
        let fm = FileManager.default
        if handle == nil {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        if let size = try? handle.offset(), size + UInt64(data.count) > UInt64(Self.maxBytes) {
            try? handle.close()
            self.handle = nil
            try? fm.removeItem(at: oldURL)
            try? fm.moveItem(at: url, to: oldURL)
            write(data)
            return
        }
        try? handle.write(contentsOf: data)
    }

    /// Lines written since `since`, oldest first, as "HH:mm:ss.SSS text".
    func lines(since: Date) -> [String] {
        flush()
        let cutoff = Self.stamp(since)
        var out: [String] = []
        for file in [oldURL, url] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // "yyyy-MM-dd HH:mm:ss.SSS " sorts as text.
                guard line.count > 24, String(line.prefix(23)) >= cutoff else { continue }
                out.append(String(line.dropFirst(11)))
            }
        }
        return out
    }
}

/// This app's own log lines, for the diagnostic report in Settings › Advanced.
/// Reading the current process's entries needs no entitlement.
enum PWELogExport {
    /// A line the app wrote itself: the engine's loggers and NSLog (the
    /// `[pwe]`, `[automation]` lines). The frameworks in this process log far
    /// more (window scenes, Spotlight, privacy checks): 4,109 lines, 12 about
    /// the connection, in the test Mac's report (T16, 2026-10-20).
    static func isOwn(subsystem: String, sender: String) -> Bool {
        if subsystem.hasPrefix("com.targetbridge") || subsystem.hasPrefix("com.pwegroup") { return true }
        return subsystem.isEmpty && sender == "Foundation"   // NSLog
    }

    // MARK: - The report's header (1.1.1)

    /// This Mac in one line: its model and what the app runs as. "x86_64
    /// (Rosetta)" is the Intel build translated on Apple silicon, which costs
    /// encoding speed (PWELogExportTests).
    static func thisMacLine(model: String, arm64: Bool, translated: Bool) -> String {
        let arch = arm64 ? "arm64" : "x86_64"
        return "This Mac: \(model.isEmpty ? "?" : model) \(arch) (\(translated ? "Rosetta" : "native"))"
    }

    static func thisMacLine() -> String {
        #if arch(arm64)
        let arm64 = true
        #else
        let arm64 = false
        #endif
        return thisMacLine(model: sysctlString("hw.model") ?? "", arm64: arm64,
                           translated: sysctlInt("sysctl.proc_translated") == 1)
    }

    /// One iMac in sight. Its model and macOS come from the receiver's
    /// announcement and are left out when it does not make them (receivers
    /// before 1.1.1).
    static func receiverLine(_ receiver: TBDiscoveredReceiver) -> String {
        var line = "Receiver: \(receiver.receiverName) version=\(receiver.version) hevc=\(receiver.supportsHEVCDecode)"
            + " panel=\(receiver.panelSummary) tb=\(receiver.thunderboltIP.isEmpty ? "no" : "yes")"
        if !receiver.receiverModel.isEmpty { line += " model=\(receiver.receiverModel)" }
        if !receiver.receiverOS.isEmpty { line += " macOS=\(receiver.receiverOS)" }
        return line
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// nil when the name does not exist (`sysctl.proc_translated` on an Intel Mac).
    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// The store filters by subsystem itself, so the frameworks' thousands of
    /// lines are never materialised; reading them all kept the main thread busy
    /// for about 15 s before the save panel appeared (T46, test Mac 2026-10-21).
    /// Call it off the main thread.
    static var ownPredicate: NSPredicate {
        NSPredicate(format:
            "subsystem BEGINSWITH 'com.targetbridge' OR subsystem BEGINSWITH 'com.pwegroup' OR (subsystem == '' AND sender == 'Foundation')")
    }

    static func recentLines(minutes: Int) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(TimeInterval(-60 * minutes)))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            // A store that refuses the predicate is read in full and filtered here.
            let entries = try (try? store.getEntries(at: since, matching: ownPredicate)) ?? store.getEntries(at: since)
            let own = entries
                .compactMap { $0 as? OSLogEntryLog }
                .filter { isOwn(subsystem: $0.subsystem, sender: $0.sender) }
                .map { (date: $0.date, message: $0.composedMessage) }
            return droppingRepeats(own)
                .suffix(3000)
                .map { "\(formatter.string(from: $0.date)) \($0.message)" }
        } catch {
            return ["(could not read the log: \(error.localizedDescription))"]
        }
    }

    /// The unified log's lines when it has any; otherwise our own file's
    /// (T52: a Mac whose unified log held nothing from this app).
    static func reportLines(minutes: Int, file: PWELogFile = .shared) -> [String] {
        let unified = recentLines(minutes: minutes)
        let hasOwn = unified.contains { !$0.hasPrefix("(could not read the log") }
        if hasOwn { return unified }
        let fromFile = file.lines(since: Date().addingTimeInterval(TimeInterval(-60 * minutes)))
        guard !fromFile.isEmpty else { return unified }
        return ["(the system log had no lines from this app; these are from \(file.url.path))"]
            + fromFile.suffix(3000)
    }

    /// The store can return the newest entries twice, once from memory and once
    /// from disk: the RC6 report ended with its last four lines each repeated
    /// at the same millisecond (U1, 2026-10-22). An entry with the same time
    /// and text as one already kept is that copy (PWELogExportTests).
    static func droppingRepeats(_ entries: [(date: Date, message: String)]) -> [(date: Date, message: String)] {
        var seen = Set<String>()
        return entries.filter { seen.insert("\($0.date.timeIntervalSinceReferenceDate)|\($0.message)").inserted }
    }

    /// Asks where to save at once, then reads the log off the main thread and
    /// writes the report there; the file shows in the Finder when it is written.
    @MainActor
    static func save(header: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            let report = header + "\n" + reportLines(minutes: 30).joined(separator: "\n")
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                PWELog.note("[pwe] could not save the report: \(error.localizedDescription)")
            }
        }
    }
}
