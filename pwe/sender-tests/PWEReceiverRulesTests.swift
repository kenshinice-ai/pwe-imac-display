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

    func testOlderOrSmallerIMacsKeepTheEngineDefault() {
        // 2014/2015 5K: no HEVC decode reported.
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: false, panelWidth: 5120, engineDefault: .standard1440p),
                       .standard1440p)
        // Panel size unknown: do not guess.
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: true, panelWidth: nil, engineDefault: .standard1440p),
                       .standard1440p)
    }

    func testA215InchRetina4KStartsAtItsOwnResolution() {
        for hevc in [true, false] {
            XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: hevc, panelWidth: 4096, engineDefault: .standard1440p),
                           .retina4k60)
        }
        XCTAssertEqual(PWEPictureRules.choices(panelWidth: 4096), [.retina4k60, .standard1440p])
        XCTAssertFalse(PWEPictureRules.choices(panelWidth: 4096).contains(.native5k))
    }

    func testFiveKAndUnknownPanelsKeepTheFiveKMenu() {
        let fiveK: [TBDisplayCapturePreset] = [.native5k60Experimental, .native5k, .standard1440p]
        XCTAssertEqual(PWEPictureRules.choices(panelWidth: 5120), fiveK)
        XCTAssertEqual(PWEPictureRules.choices(panelWidth: nil), fiveK)
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
