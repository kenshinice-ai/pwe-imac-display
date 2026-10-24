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
}
