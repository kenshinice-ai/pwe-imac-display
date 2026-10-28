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

    private let netstat = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
    tcp4       0      0  192.168.1.5.52100      17.57.144.1.443        ESTABLISHED
    tcp6       0      0  *.5900                 *.*                    LISTEN
    tcp4       0      0  *.5900                 *.*                    LISTEN
    tcp4       0      0  127.0.0.1.631          *.*                    LISTEN
    tcp4       0      0  192.168.1.5.22         192.168.1.9.50000      ESTABLISHED
    """

    func testOnlyListenersBeyondThisMacCount() {
        XCTAssertEqual(PWESharingState.externallyListeningPorts(netstat: netstat), [5900])
        // Audit A3: loopback-only listeners on both ports.
        let loopback = """
        tcp4       0      0  127.0.0.1.22           *.*                    LISTEN
        tcp6       0      0  ::1.5900               *.*                    LISTEN
        tcp6       0      0  fe80::1%lo0.5900       *.*                    LISTEN
        """
        XCTAssertEqual(PWESharingState.externallyListeningPorts(netstat: loopback), [])
        XCTAssertEqual(PWESharingState.from(netstat: loopback, printDisabled: ""),
                       PWESharingState(screenSharing: false, remoteLogin: false))
    }

    func testOnNeedsTheServiceEnabledAndReachable() {
        let enabled = """
        disabled services = {
            "com.apple.screensharing" => enabled
            "com.openssh.sshd" => disabled
        }
        """
        XCTAssertEqual(PWESharingState.launchdOverrides(enabled),
                       ["com.apple.screensharing": true, "com.openssh.sshd": false])
        XCTAssertEqual(PWESharingState.from(netstat: netstat, printDisabled: enabled),
                       PWESharingState(screenSharing: true, remoteLogin: false))
        // Disabled, yet something listens beyond this Mac on its port: check by hand.
        let disabledButListening = #""com.apple.screensharing" => disabled"#
        XCTAssertEqual(PWESharingState.from(netstat: netstat, printDisabled: disabledButListening),
                       PWESharingState(screenSharing: nil, remoteLogin: false))
        XCTAssertNil(PWESharingState.serviceState(enabled: false, listensBeyondThisMac: true))
        XCTAssertEqual(PWESharingState.serviceState(enabled: false, listensBeyondThisMac: false), false)
        // Older systems: true means disabled.
        XCTAssertEqual(PWESharingState.launchdOverrides(#""com.openssh.sshd" => true"#), ["com.openssh.sshd": false])
    }

    func testWeakEvidenceIsNeverOn() {
        // A listener with the service not on launchd's list, or no list at all: check by hand.
        XCTAssertEqual(PWESharingState.from(netstat: netstat, printDisabled: ""),
                       PWESharingState(screenSharing: nil, remoteLogin: false))
        XCTAssertEqual(PWESharingState.from(netstat: netstat, printDisabled: nil),
                       PWESharingState(screenSharing: nil, remoteLogin: false))
        // Enabled but not listening.
        XCTAssertNil(PWESharingState.serviceState(enabled: true, listensBeyondThisMac: false))
        // Empty or failed netstat output.
        XCTAssertEqual(PWESharingState.from(netstat: "", printDisabled: ""),
                       PWESharingState(screenSharing: false, remoteLogin: false))
        XCTAssertEqual(PWESharingState.from(netstat: nil, printDisabled: ""), PWESharingState())
    }

    func testTheWordsInBothLanguages() {
        let en = PWEStrings(language: .english), zh = PWEStrings(language: .chinese)
        XCTAssertEqual(en.onlyIMacTitle, "Use only the iMac")
        XCTAssertEqual(zh.onlyIMacTitle, "以后只用 iMac")
        XCTAssertEqual(zh.onlyIMacBody, "趁现在看得见这台 Mac 时做一次。之后只用 iMac 就行；只有重启后要在这台 Mac 的键盘上输入密码。")
        for row in Rules.Row.allCases { XCTAssertFalse(en.onlyIMacRow(row).isEmpty) }
    }
}
