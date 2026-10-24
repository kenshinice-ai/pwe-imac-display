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
}
