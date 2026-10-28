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
    /// last second, said to be sent (A3); a still screen shows the size alone,
    /// never "0 fps".
    func testTheLiveLine() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertEqual(en.liveLine(.native5k60Experimental, fps: 35), "5K · 35 fps sent")
        XCTAssertEqual(en.liveLine(.native5k, fps: 48), "5K · 48 fps sent")
        XCTAssertEqual(en.liveLine(.retina4k60, fps: 59), "4K · 59 fps sent")
        XCTAssertEqual(en.liveLine(.crisp2160p60, fps: 60), "4K · 60 fps sent")
        XCTAssertEqual(en.liveLine(.smooth1440p60, fps: 60), "1440p · 60 fps sent")
        XCTAssertEqual(en.liveLine(.native5k60Experimental, fps: 0), "5K")
        XCTAssertEqual(zh.liveLine(.native5k60Experimental, fps: 35), "5K · 已发送 35 帧/秒")
        // The engine's count catching up after a pause never reads above 60.
        XCTAssertEqual(en.liveLine(.native5k60Experimental, fps: 140), "5K · 60 fps sent")
    }

    /// Snapshots (`--pwe-snapshot`) have no engine: no frame count, so no
    /// sample number in pictures that go on the product page.
    @MainActor func testSnapshotsShowNoFrameCount() {
        XCTAssertEqual(PWESenderModel(preview: .searching).framesPerSecond, 0)
    }

    /// The Picture menu's names (1.1.1): Standard is the 60-frame 1440p, and
    /// the 30-frame one, if the Full Console chose it, says what it is.
    func testPictureNames() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertEqual(en.pictureName(.crisp2160p60), "Smooth · 4K 60")
        XCTAssertEqual(zh.pictureName(.crisp2160p60), "流畅 · 4K 60")
        XCTAssertEqual(en.pictureName(.smooth1440p60), "Standard · 1440p")
        XCTAssertEqual(zh.pictureName(.smooth1440p60), "标准 · 1440p")
        XCTAssertEqual(en.pictureName(.standard1440p), "1440p · 30 Hz")
        XCTAssertNotEqual(en.pictureName(.standard1440p), en.pictureName(.smooth1440p60))
        XCTAssertEqual(en.liveLine(.crisp2160p60, fps: 0), "4K")
        XCTAssertEqual(en.liveLine(.smooth1440p60, fps: 0), "1440p")
    }

    /// T19: with the menu bar item hidden, the tip does not point at it.
    func testTheHiddenMenuBarTip() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertTrue(en.menuBarHiddenTip(macOS: 26).hasSuffix("Show it in System Settings › Menu Bar."))
        XCTAssertFalse(en.menuBarHiddenTip(macOS: 15).contains("System Settings"))
        XCTAssertTrue(zh.menuBarHiddenTip(macOS: 27).contains("菜单栏"))
        XCTAssertFalse(PWEMenuBarPresence.isHidden(itemVisible: true, windowVisible: true))
        XCTAssertTrue(PWEMenuBarPresence.isHidden(itemVisible: false, windowVisible: true))
        XCTAssertTrue(PWEMenuBarPresence.isHidden(itemVisible: true, windowVisible: false))
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

    // Plan A: advice under 5K · 60 Hz, in both languages, with no frame counts.
    func testTheFiveK60Advice() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertEqual(en.fiveK60Advice, "On this Mac, Smooth · 4K 60 is smoother")
        XCTAssertEqual(zh.fiveK60Advice, "这台 Mac 上「流畅 · 4K 60」更顺")
        for line in [en.fiveK60Advice, en.fiveK60AdviceDetail, zh.fiveK60Advice, zh.fiveK60AdviceDetail] {
            XCTAssertFalse(line.contains("fps") || line.contains("帧/秒") || line.contains("Hz"), line)
        }
    }
}
