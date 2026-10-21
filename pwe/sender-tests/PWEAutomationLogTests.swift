import OSLog
import XCTest
@testable import TargetBridge

/// The retry loop's `[automation]` lines reach the unified log, where a
/// diagnostic report and `log show` find them; NSLog reached only stderr (T38).
/// State changes are notice (kept on disk); per-attempt lines are info, so a
/// sender waiting for an absent iMac does not persist a line every 2 s.
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEAutomationLogTests: XCTestCase {
    private func entry(containing marker: String, since start: Date) throws -> OSLogEntryLog? {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let found = try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)))
                .compactMap({ $0 as? OSLogEntryLog })
                .first(where: { $0.composedMessage.contains(marker) }) {
                return found
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func marker() -> String { "pwetest\(UUID().uuidString.prefix(8).lowercased())" }

    @MainActor
    func testACommandLineIsANoticeInTheUnifiedLog() throws {
        let marker = marker()
        let start = Date()
        // An unknown action only logs a line.
        TBSenderAutomation.handle(url: URL(string: "pweimacdisplay://\(marker)")!)
        let entry = try XCTUnwrap(try entry(containing: marker, since: start),
                                  "no [automation] line with \(marker) in the unified log")
        XCTAssertEqual(entry.subsystem, "com.targetbridge.sender")
        XCTAssertEqual(entry.category, "automation")
        XCTAssertEqual(entry.level, .notice)
        XCTAssertTrue(entry.composedMessage.hasPrefix("[automation] unknown action"))
    }

    @MainActor
    func testAPerAttemptLineIsInfo() async throws {
        let marker = marker()
        let start = Date()
        // A connect for a session that cannot exist gives up at once, as an
        // attempt of the retry loop does, with one line.
        TBSenderAutomation.handle(url: URL(string: "pweimacdisplay://connect?session=\(marker)")!)
        try await Task.sleep(nanoseconds: 300_000_000)
        let entry = try XCTUnwrap(try entry(containing: marker, since: start),
                                  "no [automation] line with \(marker) in the unified log")
        XCTAssertEqual(entry.category, "automation")
        XCTAssertEqual(entry.level, .info)
        XCTAssertTrue(entry.composedMessage.hasPrefix("[automation] invalid session"))
    }
}
