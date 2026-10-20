import XCTest
@testable import TargetBridge

/// What a check reports (UpdateCheck, shared with three other PWE apps). The site has
/// no `screenencore` entry yet, so until it does every check gets the echo below — which
/// must read as "could not confirm", never as "you have the latest version".
@MainActor
final class PWEUpdateCheckTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "PWEUpdateCheckTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private static let ok = HTTPURLResponse(url: URL(string: "https://pwestudio.site/app/check")!,
                                            statusCode: 200, httpVersion: nil, headerFields: nil)!

    private func updates(answering json: String) -> UpdateCheck {
        UpdateCheck(defaults: defaults, now: { Date() }, fetch: { _ in (Data(json.utf8), Self.ok) })
    }

    /// As the site announces a release: a date and a download page with every entry.
    private static func announced(_ version: String) -> String {
        #"{"version":"\#(version)","published":"2026-10-28","download":"https://pwestudio.site/"}"#
    }

    /// `check.js` answers a product it has not been told about with the caller's own
    /// version and nothing else.
    func testAnEchoWithNoReleaseFieldsIsUnknown() async {
        let updates = updates(answering: #"{"version":"1.1.0"}"#)
        let outcome = await updates.check(version: "1.1.0", manual: true)
        XCTAssertEqual(outcome, .unknown)
        XCTAssertNil(updates.available)
    }

    func testAnAnnouncedReleaseEqualToThisBuildIsCurrent() async {
        let outcome = await updates(answering: Self.announced("1.1.0")).check(version: "1.1.0", manual: true)
        XCTAssertEqual(outcome, .current)
    }

    /// "Later" quiets the daily reminder; it does not change what the newest version is.
    func testAManualCheckShowsADismissedVersion() async {
        let updates = updates(answering: Self.announced("1.2.0"))
        await updates.check(version: "1.1.0")
        updates.dismiss()

        let daily = await updates.check(version: "1.1.0")
        XCTAssertEqual(daily, .newer(UpdateCheck.Release(version: "1.2.0", published: "2026-10-28",
                                                         download: "https://pwestudio.site/")))
        XCTAssertNil(updates.available, "the daily reminder respects Later")

        let asked = await updates.check(version: "1.1.0", manual: true)
        XCTAssertEqual(asked, daily)
        XCTAssertEqual(updates.available?.version, "1.2.0", "asked for, it is shown")
    }

    func testNoAnswerIsUnreachable() async {
        let updates = UpdateCheck(defaults: defaults, now: { Date() },
                                  fetch: { _ in throw URLError(.notConnectedToInternet) })
        let outcome = await updates.check(version: "1.1.0", manual: true)
        XCTAssertEqual(outcome, .unreachable)
    }
}
