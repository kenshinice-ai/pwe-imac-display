import XCTest
@testable import TargetBridge

/// A2: Settings › General's "Use only the iMac" rows (PWEOnlyIMacRules, PWESharingState).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEOnlyIMacTests: XCTestCase {
    private typealias Rules = PWEOnlyIMacRules
    private let ready = Rules.Inputs(screenRecording: true, launchAtLogin: true, launchAtLoginNeedsApproval: false,
                                     canRegisterLogin: true, autoConnect: true, inputRole: .iMacControlsMac,
                                     screenSharing: true, remoteLogin: true)

    func testAllDone() {
        for row in Rules.Row.allCases { XCTAssertEqual(Rules.state(row, ready), .done, row.rawValue) }
    }

    func testOwnSettingsTurnOn() {
        var input = ready
        input.autoConnect = false
        input.inputRole = .macControlsIMac
        input.launchAtLogin = false
        XCTAssertEqual(Rules.state(.autoConnect, input), .turnOn)
        XCTAssertEqual(Rules.state(.keyboardMouse, input), .turnOn)
        XCTAssertEqual(Rules.state(.openAtLogin, input), .turnOn)
        input.inputRole = .off
        XCTAssertEqual(Rules.state(.keyboardMouse, input), .turnOn)
    }

    func testOpenAtLoginFollowsTheApplicationsRule() {
        var input = ready
        input.launchAtLogin = false
        input.canRegisterLogin = false
        XCTAssertEqual(Rules.state(.openAtLogin, input), .moveToApplications)
        input.launchAtLoginNeedsApproval = true
        XCTAssertEqual(Rules.state(.openAtLogin, input), .openSettings)
    }

    func testSystemSettingsAreOnlyLinked() {
        var input = ready
        input.screenRecording = false
        input.screenSharing = false
        input.remoteLogin = nil
        XCTAssertEqual(Rules.state(.screenRecording, input), .openSettings)
        XCTAssertEqual(Rules.state(.screenSharing, input), .openSettings)
        XCTAssertEqual(Rules.state(.remoteLogin, input), .check)
    }

    func testSharingFromNetstat() {
        let output = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.168.1.5.52100      17.57.144.1.443        ESTABLISHED
        tcp6       0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  127.0.0.1.631          *.*                    LISTEN
        tcp4       0      0  192.168.1.5.22         192.168.1.9.50000      ESTABLISHED
        """
        XCTAssertEqual(PWESharingState.listeningPorts(netstat: output), [5900, 631])
        XCTAssertEqual(PWESharingState.from(netstat: output), PWESharingState(screenSharing: true, remoteLogin: false))
        XCTAssertEqual(PWESharingState.from(netstat: nil), PWESharingState(screenSharing: nil, remoteLogin: nil))
    }

    func testTheWordsInBothLanguages() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertEqual(en.onlyIMacTitle, "Use only the iMac")
        XCTAssertEqual(zh.onlyIMacTitle, "以后只用 iMac")
        XCTAssertEqual(zh.onlyIMacBody, "趁现在看得见这台 Mac 时做一次。之后只用 iMac 就行；只有重启后要在这台 Mac 的键盘上输入密码。")
        for row in Rules.Row.allCases { XCTAssertFalse(en.onlyIMacRow(row).isEmpty) }
    }
}
