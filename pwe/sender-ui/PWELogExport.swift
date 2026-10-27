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
            return entries
                .compactMap { $0 as? OSLogEntryLog }
                .filter { isOwn(subsystem: $0.subsystem, sender: $0.sender) }
                .suffix(3000)
                .map { "\(formatter.string(from: $0.date)) \($0.composedMessage)" }
        } catch {
            return ["(could not read the log: \(error.localizedDescription))"]
        }
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
            let report = header + "\n" + recentLines(minutes: 30).joined(separator: "\n")
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                PWELog.note("[pwe] could not save the report: \(error.localizedDescription)")
            }
        }
    }
}
