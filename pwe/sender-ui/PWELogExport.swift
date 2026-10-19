import AppKit
import OSLog
import UniformTypeIdentifiers

/// This process's own log lines, for the diagnostic report in Settings › Advanced.
/// Reading the current process's entries needs no entitlement.
enum PWELogExport {
    static func recentLines(minutes: Int) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(TimeInterval(-60 * minutes)))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return try store.getEntries(at: since)
                .compactMap { $0 as? OSLogEntryLog }
                .suffix(3000)
                .map { "\(formatter.string(from: $0.date)) \($0.composedMessage)" }
        } catch {
            return ["(could not read the log: \(error.localizedDescription))"]
        }
    }

    /// Asks where to save, then writes the report there.
    @MainActor
    static func save(_ report: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("[pwe] could not save the report: \(error.localizedDescription)")
        }
    }
}
