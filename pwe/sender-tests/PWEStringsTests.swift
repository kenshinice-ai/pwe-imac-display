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

    /// The menu's line while the picture is up: size, then frames sent in the
    /// last second; a still screen shows the size alone, never "0 fps".
    func testTheLiveLine() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertEqual(en.liveLine(.native5k60Experimental, fps: 60), "5K · 60 fps")
        XCTAssertEqual(en.liveLine(.native5k, fps: 48), "5K · 48 fps")
        XCTAssertEqual(en.liveLine(.retina4k60, fps: 59), "4K · 59 fps")
        XCTAssertEqual(en.liveLine(.standard1440p, fps: 30), "1440p · 30 fps")
        XCTAssertEqual(en.liveLine(.native5k60Experimental, fps: 0), "5K")
        XCTAssertEqual(zh.liveLine(.native5k60Experimental, fps: 60), "5K · 60 帧/秒")
    }

    /// The permission goes by System Settings' name for it, which macOS 15
    /// changed (Privacy & Security).
    func testScreenRecordingIsCalledWhatSystemSettingsCallsIt() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertEqual(en.screenRecording(macOS: 14), "Screen Recording")
        XCTAssertEqual(zh.screenRecording(macOS: 14), "屏幕录制")
        XCTAssertEqual(en.screenRecording(macOS: 15), "Screen & System Audio Recording")
        XCTAssertEqual(zh.screenRecording(macOS: 15), "录屏与系统录音")
        XCTAssertEqual(zh.screenRecording(macOS: 26), "录屏与系统录音")
    }
}
