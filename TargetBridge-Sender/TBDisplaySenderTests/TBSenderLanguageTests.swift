import XCTest
@testable import TargetBridge

final class TBSenderLanguageTests: XCTestCase {
    func testFirstSupportedSystemLanguageWins() {
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["zh-Hans-AU", "en-AU"]), .chinese)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["de-CH"]), .german)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["fr-CA", "it-IT"]), .french)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["it"]), .italian)
    }

    func testUnsupportedLanguagesAreSkipped() {
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["ja-JP", "it-IT"]), .italian)
    }

    func testEnglishWhenNothingIsSupported() {
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: ["ja-JP", "ko-KR"]), .english)
        XCTAssertEqual(TBDisplaySenderLanguage.preferred(by: []), .english)
    }
}
