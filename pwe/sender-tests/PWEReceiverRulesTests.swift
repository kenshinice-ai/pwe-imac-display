import CoreMedia
import XCTest
@testable import TargetBridge

/// iMac names, panel descriptions and the first Picture (PWEReceiverRules).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEReceiverRulesTests: XCTestCase {
    private func name(_ receiver: String, service: String = "", host: String? = nil) -> String {
        PWEReceiverNaming.friendlyName(receiverName: receiver, serviceName: service, hostName: host)
    }

    func testTheAppNameAndLocalSuffixGo() {
        // What the iMac18,3 baseline showed (2026-10-19).
        XCTAssertEqual(name("PWE Screen Encore LL-iMac-2017.local"), "LL-iMac-2017")
        XCTAssertEqual(name("TargetBridge Studio-iMac.local."), "Studio-iMac")
        XCTAssertEqual(name("PWE Screen Encore Receiver Office"), "Office")
    }

    func testReceiversFromBeforeTheRenameAreNamedTheSameWay() {
        XCTAssertEqual(name("PWE iMac Display LL-iMac-2017.local"), "LL-iMac-2017")
        XCTAssertEqual(name("PWE iMac Display Receiver Office"), "Office")
        XCTAssertEqual(name("PWE iMac Display ", service: "", host: "Den.local."), "Den")
    }

    func testAPlainNameStays() {
        XCTAssertEqual(name("Lee's iMac"), "Lee's iMac")
    }

    func testEmptyNamesFallBack() {
        XCTAssertEqual(name("", service: "PWE Screen Encore Den.local"), "Den")
        XCTAssertEqual(name("PWE Screen Encore ", service: "", host: "LL-iMac-2017.local."), "LL-iMac-2017")
        XCTAssertEqual(name("", service: "", host: nil), "iMac")
    }

    func testPanelDetail() {
        XCTAssertEqual(PWEReceiverNaming.friendlyDetail(panelSummary: "iMac (5120x2880)"), "5120 × 2880")
        XCTAssertEqual(PWEReceiverNaming.friendlyDetail(panelSummary: "4096x2304"), "4096 × 2304")
        XCTAssertEqual(PWEReceiverNaming.friendlyDetail(panelSummary: "iMac"), "iMac")
        XCTAssertEqual(PWEReceiverNaming.panelSize("iMac (5120x2880)")?.width, 5120)
        XCTAssertNil(PWEReceiverNaming.panelSize(""))
    }

    func testA2017FiveKStartsAtSixty() {
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: true, panelWidth: 5120, engineDefault: .standard1440p),
                       .native5k60Experimental)
    }

    func testOlderOrSmallerIMacsKeepTheEngineDefaultAt60Frames() {
        // 2014/2015 5K: no HEVC decode reported. The engine's own default is
        // the 30-frame 1440p; PWE offers the 60-frame one in its place (1.1.1).
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: false, panelWidth: 5120, engineDefault: .standard1440p),
                       .smooth1440p60)
        // Panel size unknown: do not guess.
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: true, panelWidth: nil, engineDefault: .standard1440p),
                       .smooth1440p60)
        // Anything else the engine was left at stays.
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: false, panelWidth: 5120, engineDefault: .native5k),
                       .native5k)
    }

    func testTheDefaultFor5KHEVCStaysFiveKSixty() {
        // Lee 2026-10-24: Smooth · 4K 60 is a choice, not the default.
        for engineDefault in TBDisplayCapturePreset.allCases {
            XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: true, panelWidth: 5120, engineDefault: engineDefault),
                           .native5k60Experimental)
        }
    }

    func testThirtyFrame1440pIsOfferedAsSixty() {
        XCTAssertEqual(PWEPictureRules.offered(.standard1440p), .smooth1440p60)
        for preset in TBDisplayCapturePreset.allCases where preset != .standard1440p {
            XCTAssertEqual(PWEPictureRules.offered(preset), preset)
        }
        XCTAssertEqual(TBDisplayCapturePreset.smooth1440p60.expectedFrameRate, 60)
        XCTAssertEqual(TBDisplayCapturePreset.standard1440p.expectedFrameRate, 30)
    }

    func testRemembered1440pMovesToSixtyFrames() {
        let migrated = PWEPictureRules.migrated1440p(["a": "standard1440p", "b": "native5k", "c": "standard1440p"])
        XCTAssertEqual(migrated, ["a": "smooth1440p60", "b": "native5k", "c": "smooth1440p60"])
        XCTAssertNil(PWEPictureRules.migrated1440p(["a": "native5k60Experimental", "b": "smooth1440p60"]))
        XCTAssertNil(PWEPictureRules.migrated1440p([:]))
    }

    /// Smooth · 4K 60 keeps the 5K desktop: no mode override, so the virtual
    /// display is the receiver's 5K panel, and only the capture is 4K.
    func testSmooth4KKeepsTheFiveKDesktop() {
        let preset = TBDisplayCapturePreset.crisp2160p60
        XCTAssertNil(TBDisplaySenderSession.virtualDisplayModeOverride(
            preset: preset, matchRenderToStream: false, captureSource: .extendedDesktop))
        XCTAssertNil(TBDisplaySenderSession.virtualDisplayModeOverride(
            preset: preset, matchRenderToStream: false, captureSource: .desktopMirror))
        XCTAssertEqual(preset.width, 3840)
        XCTAssertEqual(preset.height, 2160)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertEqual(preset.codecType, kCMVideoCodecType_HEVC)
        // Render matching would halve the desktop to 1920 × 1080: the reason
        // PWE leaves it off.
        XCTAssertEqual(TBDisplaySenderSession.virtualDisplayModeOverride(
            preset: preset, matchRenderToStream: true, captureSource: .extendedDesktop),
            TBVirtualDisplayModeSize(width: 1920, height: 1080))
    }

    func testTheOtherFiveKChoicesKeepTheFiveKDesktopToo() {
        for preset in PWEPictureRules.choices(panelWidth: 5120) {
            XCTAssertNil(TBDisplaySenderSession.virtualDisplayModeOverride(
                preset: preset, matchRenderToStream: false, captureSource: .extendedDesktop), "\(preset)")
        }
    }

    func testA215InchRetina4KStartsAtItsOwnResolution() {
        for hevc in [true, false] {
            XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: hevc, panelWidth: 4096, engineDefault: .standard1440p),
                           .retina4k60)
        }
        XCTAssertEqual(PWEPictureRules.choices(panelWidth: 4096), [.retina4k60, .smooth1440p60])
        XCTAssertFalse(PWEPictureRules.choices(panelWidth: 4096).contains(.native5k))
    }

    @MainActor func testFiveKAndUnknownPanelsKeepTheFiveKMenu() {
        // Smooth · 4K 60 sits between 5K · 48 and 1440p (1.1.1).
        let fiveK: [TBDisplayCapturePreset] = [.native5k60Experimental, .native5k, .crisp2160p60, .smooth1440p60]
        XCTAssertEqual(PWEPictureRules.choices(panelWidth: 5120), fiveK)
        XCTAssertEqual(PWEPictureRules.choices(panelWidth: nil), fiveK)
        XCTAssertEqual(PWESenderModel.pictureChoices, fiveK)
        XCTAssertFalse(fiveK.contains(.standard1440p))
        XCTAssertFalse(PWEPictureRules.isRetina4K(5120))
        XCTAssertFalse(PWEPictureRules.isRetina4K(1920))
    }

    func testPWEOrUpstreamReceiver() {
        XCTAssertTrue(PWEReceiverNaming.isPWE(receiverName: "PWE Screen Encore LL-iMac-2017.local", serviceName: ""))
        XCTAssertTrue(PWEReceiverNaming.isPWE(receiverName: "", serviceName: "PWE iMac Display LL-iMac-2017"))
        XCTAssertFalse(PWEReceiverNaming.isPWE(receiverName: "TargetBridge Den.local", serviceName: "TargetBridge Den.local"))
    }

    /// 1.1.1: "The picture did not start" points at the Picture menu, so its
    /// choices stay enabled for the remembered iMac while it is out of the list.
    func testThePictureBelongsToTheRememberedIMacWhileItIsAway() {
        XCTAssertEqual(PWEPictureRules.pictureKey(onScreen: "imac", remembered: "other"), "imac")
        XCTAssertEqual(PWEPictureRules.pictureKey(onScreen: nil, remembered: "imac"), "imac")
        XCTAssertNil(PWEPictureRules.pictureKey(onScreen: nil, remembered: ""))
        XCTAssertNil(PWEPictureRules.pictureKey(onScreen: nil, remembered: nil))
    }
}
