import OSLog
import XCTest
@testable import TargetBridge

/// The retry loop's `[automation]` lines reach the unified log, where a
/// diagnostic report and `log show` find them; NSLog reached only stderr (T38).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEAutomationLogTests: XCTestCase {
    @MainActor
    func testAutomationLinesAreInTheUnifiedLog() throws {
        let marker = "pwetest\(UUID().uuidString.prefix(8).lowercased())"
        let start = Date()
        // An unknown action only logs a line.
        TBSenderAutomation.handle(url: URL(string: "pweimacdisplay://\(marker)")!)
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        var found: OSLogEntryLog?
        let deadline = Date().addingTimeInterval(5)
        while found == nil, Date() < deadline {
            found = try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)))
                .compactMap { $0 as? OSLogEntryLog }
                .first { $0.composedMessage.contains(marker) }
            if found == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        let entry = try XCTUnwrap(found, "no [automation] line with \(marker) in the unified log")
        XCTAssertEqual(entry.subsystem, "com.targetbridge.sender")
        XCTAssertEqual(entry.category, "automation")
        XCTAssertEqual(entry.level, .notice)
        XCTAssertTrue(entry.composedMessage.hasPrefix("[automation] unknown action"))
    }
}
