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
        XCTAssertEqual(name("PWE iMac Display LL-iMac-2017.local"), "LL-iMac-2017")
        XCTAssertEqual(name("TargetBridge Studio-iMac.local."), "Studio-iMac")
        XCTAssertEqual(name("PWE iMac Display Receiver Office"), "Office")
    }

    func testAPlainNameStays() {
        XCTAssertEqual(name("Lee's iMac"), "Lee's iMac")
    }

    func testEmptyNamesFallBack() {
        XCTAssertEqual(name("", service: "PWE iMac Display Den.local"), "Den")
        XCTAssertEqual(name("PWE iMac Display ", service: "", host: "LL-iMac-2017.local."), "LL-iMac-2017")
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
        // 21.5-inch 4K: HEVC, but not a 5K panel.
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: true, panelWidth: 4096, engineDefault: .standard1440p),
                       .standard1440p)
        // Panel size unknown: do not guess.
        XCTAssertEqual(PWEPictureRules.defaultPicture(supportsHEVC: true, panelWidth: nil, engineDefault: .standard1440p),
                       .standard1440p)
    }

    func testPWEOrUpstreamReceiver() {
        XCTAssertTrue(PWEReceiverNaming.isPWE(receiverName: "PWE iMac Display LL-iMac-2017.local", serviceName: ""))
        XCTAssertFalse(PWEReceiverNaming.isPWE(receiverName: "TargetBridge Den.local", serviceName: "TargetBridge Den.local"))
    }
}
