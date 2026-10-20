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
}
