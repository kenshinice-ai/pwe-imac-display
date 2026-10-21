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

}
