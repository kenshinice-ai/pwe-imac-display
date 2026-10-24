import XCTest
@testable import TargetBridge

/// The report's log keeps this app's lines only (T16).
final class PWELogExportTests: XCTestCase {
    func testOwnLinesAreKept() {
        XCTAssertTrue(PWELogExport.isOwn(subsystem: "com.targetbridge.sender", sender: "PWE Screen Encore"))
        XCTAssertTrue(PWELogExport.isOwn(subsystem: "com.pwegroup.pweimacdisplay", sender: "PWE Screen Encore"))
        XCTAssertTrue(PWELogExport.isOwn(subsystem: "", sender: "Foundation"))
    }

    func testFrameworkLinesAreDropped() {
        XCTAssertFalse(PWELogExport.isOwn(subsystem: "com.apple.xpc", sender: "libxpc.dylib"))
        XCTAssertFalse(PWELogExport.isOwn(subsystem: "com.apple.spotlight", sender: "CoreSpotlight"))
        XCTAssertFalse(PWELogExport.isOwn(subsystem: "", sender: "AppKit"))
    }

    /// The report's log comes back filtered by the store itself, with our own
    /// line in it, and quickly (T46: the unfiltered read took about 15 s).
    func testRecentLinesFindsOurOwnLineQuickly() {
        let marker = "[pwe] report test \(UUID().uuidString)"
        PWELog.note(marker)
        let started = Date()
        let lines = PWELogExport.recentLines(minutes: 5)
        XCTAssertTrue(lines.contains { $0.hasSuffix(marker) }, "the line just logged is in the report")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - The header (1.1.1)

    func testThisMacSaysHowTheAppRuns() {
        XCTAssertEqual(PWELogExport.thisMacLine(model: "Mac14,2", arm64: true, translated: false),
                       "This Mac: Mac14,2 arm64 (native)")
        XCTAssertEqual(PWELogExport.thisMacLine(model: "Mac14,2", arm64: false, translated: true),
                       "This Mac: Mac14,2 x86_64 (Rosetta)")
        XCTAssertEqual(PWELogExport.thisMacLine(model: "MacBookPro15,1", arm64: false, translated: false),
                       "This Mac: MacBookPro15,1 x86_64 (native)")
        XCTAssertTrue(PWELogExport.thisMacLine().hasPrefix("This Mac: "))
    }

    private func receiver(model: String = "", os: String = "") -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(serviceName: "iMac", receiverName: "Studio iMac", preferredIP: "169.254.1.2",
                             thunderboltIP: "169.254.1.2", networkIP: "", panelSummary: "5120x2880",
                             version: "1.1.1", supportsHEVCDecode: true, hostName: nil,
                             receiverModel: model, receiverOS: os)
    }

    func testTheReceiversModelAndMacOSShowWhenAnnounced() {
        XCTAssertEqual(PWELogExport.receiverLine(receiver(model: "iMac18,3", os: "13.7.8")),
                       "Receiver: Studio iMac version=1.1.1 hevc=true panel=5120x2880 tb=yes model=iMac18,3 macOS=13.7.8")
        // A receiver before 1.1.1 announces neither: the line is as it was.
        XCTAssertEqual(PWELogExport.receiverLine(receiver()),
                       "Receiver: Studio iMac version=1.1.1 hevc=true panel=5120x2880 tb=yes")
    }

    /// A11: the report's newest lines came twice, at the same millisecond.
    func testRepeatedEntriesAreDropped() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entries: [(date: Date, message: String)] = [
            (t, "[pwe] a"), (t.addingTimeInterval(1), "[pwe] b"),
            (t.addingTimeInterval(1), "[pwe] b"), (t, "[pwe] a"),
            // The same text at another time is a new line.
            (t.addingTimeInterval(2), "[pwe] a"),
        ]
        let kept = PWELogExport.droppingRepeats(entries)
        XCTAssertEqual(kept.map(\.message), ["[pwe] a", "[pwe] b", "[pwe] a"])
        XCTAssertEqual(kept.map(\.date), [t, t.addingTimeInterval(1), t.addingTimeInterval(2)])
    }

    // T52: the report's own file, for Macs whose unified log has nothing from us.
    private func tempLogFile() -> PWELogFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pwe-logfile-\(UUID().uuidString)")
        return PWELogFile(directory: dir)
    }

    func testLogFileKeepsRecentLinesOnly() {
        let file = tempLogFile()
        let now = Date()
        file.append("[pwe] old", at: now.addingTimeInterval(-3600))
        file.append("[pwe] new", at: now.addingTimeInterval(-60))
        let lines = file.lines(since: now.addingTimeInterval(-1800))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix(" [pwe] new"))
        XCTAssertFalse(lines[0].hasPrefix("2026-") || lines[0].hasPrefix("2027-"), "the date part is dropped, the time stays")
        XCTAssertFalse(lines[0].contains("+"), "the UTC offset is dropped too")
    }

    func testLogFileRotatesAtTheLimit() throws {
        let file = tempLogFile()
        let chunk = String(repeating: "x", count: 64 * 1024)
        for _ in 0..<40 { file.append(chunk) }   // about 2.5 MB
        file.flush()
        let size = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, PWELogFile.maxBytes)
        let old = file.url.deletingLastPathComponent().appendingPathComponent("sender.old.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    // MARK: - Review 2026-10-24

    func testAWriteRotatesAtMostOnce() {
        XCTAssertEqual(PWELogFile.room(currentSize: 0, adding: 10, limit: 100), .fits)
        XCTAssertEqual(PWELogFile.room(currentSize: 95, adding: 10, limit: 100), .rotate)
        // An empty file takes any line that fits the limit; a longer one is dropped,
        // never rotated again and again.
        XCTAssertEqual(PWELogFile.room(currentSize: 0, adding: 100, limit: 100), .fits)
        XCTAssertEqual(PWELogFile.room(currentSize: 0, adding: 101, limit: 100), .drop)
        XCTAssertEqual(PWELogFile.room(currentSize: 50, adding: 101, limit: 100), .drop)
    }

    /// The old part cannot be replaced (here: a folder that cannot be emptied).
    /// The file starts over instead of growing or recursing.
    func testAnOldPartThatCannotBeReplacedStartsTheLogOver() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pwe-logfile-\(UUID().uuidString)")
        let blocker = dir.appendingPathComponent("sender.old.log", isDirectory: true)
        try fm.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocker.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocker.path)
            try? fm.removeItem(at: dir)
        }
        let file = PWELogFile(directory: dir)
        let chunk = String(repeating: "y", count: 64 * 1024)
        for _ in 0..<40 { file.append(chunk) }
        file.flush()
        let size = try fm.attributesOfItem(atPath: file.url.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, PWELogFile.maxBytes)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(text.contains("could not be replaced; the log started over"))
    }

    func testALineBreakInAMessageStaysOnItsLine() {
        let file = tempLogFile()
        file.append("[pwe] first\nsecond")
        let lines = file.lines(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("[pwe] first⏎second"))
    }

    func testTheReportAddsTheFilesLinesItHasNotShown() {
        let unified = ["10:00:00.000 [pwe] a", "10:00:01.000 [automation] b"]
        let fromFile = ["09:50:00.000 [pwe] from the run before", "10:00:00.000 [pwe] a"]
        let lines = PWELogExport.combined(unified: unified, fromFile: fromFile, filePath: "/x/sender.log")
        XCTAssertEqual(lines, unified + ["", "From /x/sender.log (last 30 minutes, lines not shown above):",
                                         "09:50:00.000 [pwe] from the run before"])
        XCTAssertEqual(PWELogExport.combined(unified: unified, fromFile: ["10:00:00.000 [pwe] a"], filePath: "/x"),
                       unified)
    }
}
