import XCTest
@testable import TargetBridge

/// Words PWE shows that are chosen by a rule rather than written once
/// (PWEStrings, PWESenderModel.checks). pwe/rebrand.py copies this file into
/// the sender's test target.
final class PWEStringsTests: XCTestCase {
    private let snapshot = TBConfigurationDiagnosticSnapshot(
        hasScreenRecording: true, transportIsThunderbolt: true, localInterfaceName: "bridge0",
        receiverAddress: "169.254.1.2", receiverProfileAvailable: true, receiverSupportsHEVC: true,
        requiresHEVC: true, cableRate: 18.2,
        requiresSenderInputMonitoring: false, senderInputMonitoringGranted: false,
        requiresSenderAccessibility: false, senderAccessibilityGranted: false,
        requiresReceiverInputMonitoring: false, receiverInputMonitoringGranted: nil,
        requiresReceiverAccessibility: false, receiverAccessibilityGranted: nil)

    private func titles(_ language: TBDisplaySenderLanguage) -> [String] {
        let engine = TBConfigurationDiagnostics.checks(for: snapshot)
        return PWESenderModel.checks(engine, language: language).flatMap { [$0.title, $0.detail] }
    }

    /// 1.1.1: Settings › Advanced is English or Chinese throughout. The engine's
    /// own German, French and Italian stay in the full console.
    func testTheChecksSpeakPWEsTwoLanguages() {
        let english = titles(.english)
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(titles(.german), english)
        XCTAssertEqual(titles(.french), english)
        XCTAssertEqual(titles(.italian), english)
        XCTAssertNotEqual(titles(.chinese), english)
        // The engine does have German for these, so the rule is doing the work.
        let key = TBConfigurationDiagnostics.checks(for: snapshot)[0].titleKey
        XCTAssertNotEqual(TBDisplaySenderL10n.text(key, .german), TBDisplaySenderL10n.text(key, .english))
    }
}
