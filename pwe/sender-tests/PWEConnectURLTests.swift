import XCTest
@testable import TargetBridge

/// T54: a connect URL from outside, while connected or not (PWEConnectURLRules).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEConnectURLTests: XCTestCase {
    private typealias Rules = PWEConnectURLRules

    private func plan(_ params: [String: String], knowsIMac: Bool = true, connected: Bool = true,
                      wantedPicture: TBDisplayCapturePreset? = nil, wantedMode: PWEDisplayMode? = nil) -> Rules.Plan {
        Rules.plan(plainAutomatic: Rules.isPlainAutomatic(params), knowsIMac: knowsIMac, connected: connected,
                   picture: .native5k60Experimental, wantedPicture: wantedPicture,
                   mode: .extended, wantedMode: wantedMode)
    }

    func testAChangedPictureWhileConnectedReconnects() {
        // The hardware run: receiver=auto&mode=extended&preset=smooth1440p60 while showing 5K 60.
        let params = ["receiver": "auto", "mode": "extended", "preset": "smooth1440p60"]
        XCTAssertEqual(plan(params, wantedPicture: .smooth1440p60, wantedMode: .extended), .reconnect)
        XCTAssertEqual(plan(params, wantedMode: .mirror), .reconnect)
    }

    func testTheSameChoiceDoesNothing() {
        XCTAssertEqual(plan(["receiver": "auto"], wantedPicture: .native5k60Experimental, wantedMode: .extended), .nothing)
        XCTAssertEqual(plan([:]), .nothing)
    }

    func testNotConnectedConnectsUnderPWEsRules() {
        XCTAssertEqual(plan(["receiver": "auto", "retry": "0"], connected: false), .connect)
    }

    func testAnythingElseStaysUpstreams() {
        XCTAssertEqual(plan(["receiver": "LL-iMac-2017"]), .notOurs)
        XCTAssertEqual(plan(["receiver": "auto", "transport": "network"]), .notOurs)
        XCTAssertEqual(plan(["receiver": "auto", "path": "fastest"]), .notOurs)
        XCTAssertEqual(plan(["session": "2"]), .notOurs)
        XCTAssertEqual(plan(["receiver": "auto"], knowsIMac: false), .notOurs)
    }

    /// Review 2026-10-24: only the Picture menu's choices for this iMac.
    func testOnlyOfferedPicturesAreAccepted() {
        let fiveK = PWEPictureRules.choices(panelWidth: 5120)
        let fourK = PWEPictureRules.choices(panelWidth: 4096)
        XCTAssertEqual(Rules.acceptedPicture(.crisp2160p60, choices: fiveK), .crisp2160p60)
        // The 30-frame 1440p is taken as the menu's Standard · 1440p.
        XCTAssertEqual(Rules.acceptedPicture(.standard1440p, choices: fiveK), .smooth1440p60)
        // 5K on a 21.5-inch 4K iMac, or a preset no menu offers: ignored.
        XCTAssertNil(Rules.acceptedPicture(.native5k60Experimental, choices: fourK))
        XCTAssertNil(Rules.acceptedPicture(.smooth1800p60, choices: fiveK))
    }
}
