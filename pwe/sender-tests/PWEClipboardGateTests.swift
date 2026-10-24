import XCTest
@testable import TargetBridge

/// The receiver's clipboard reaches this Mac's only while the iMac controls
/// input, in an encrypted session (audit 2026-10-20 P1-02). The receive path
/// asks TBDisplaySenderSession.pweTakesReceiverClipboard; this is its whole
/// matrix: keyboard and mouse sharing × the link's security.
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEClipboardGateTests: XCTestCase {
    private let roles: [TBInputControlRole] = [.off, .senderMaster, .receiverMaster]
    private let modes: [PWESecureLink.Mode?] = [nil, .negotiating, .secure, .plaintext, .closed]

    func testOnlyIMacControlsMacInAnEncryptedSessionTakesTheClipboard() {
        for role in roles {
            for mode in modes {
                let takes = TBDisplaySenderSession.pweTakesReceiverClipboard(role: role, linkMode: mode)
                XCTAssertEqual(takes, role == .receiverMaster && mode == .secure,
                               "role \(role.rawValue), link \(mode.map { "\($0)" } ?? "none")")
            }
        }
    }

    func testTheSettingsChoicesMapToTheGate() {
        // What Settings › Keyboard and mouse offers, through the engine role it sets.
        let secure = PWESecureLink.Mode.secure
        XCTAssertFalse(TBDisplaySenderSession.pweTakesReceiverClipboard(role: PWEInputRole.off.engineRole, linkMode: secure))
        XCTAssertFalse(TBDisplaySenderSession.pweTakesReceiverClipboard(role: PWEInputRole.macControlsIMac.engineRole,
                                                                        linkMode: secure))
        XCTAssertTrue(TBDisplaySenderSession.pweTakesReceiverClipboard(role: PWEInputRole.iMacControlsMac.engineRole,
                                                                       linkMode: secure))
        XCTAssertFalse(TBDisplaySenderSession.pweTakesReceiverClipboard(role: PWEInputRole.iMacControlsMac.engineRole,
                                                                        linkMode: .plaintext))
    }

    /// A10: each sync logs its direction and size, never the text.
    func testTheClipboardLogLineCarriesNoText() {
        typealias Session = TBDisplaySenderSession
        XCTAssertEqual(Session.pweClipboardLogLine(sent: true, byteCount: 12), "clipboard: sent under 100 bytes to the iMac")
        XCTAssertEqual(Session.pweClipboardLogLine(sent: false, byteCount: 500), "clipboard: took 100 bytes-10 KB from the iMac")
        XCTAssertTrue(Session.pweClipboardLogLine(sent: false, byteCount: 20_000, taken: false).hasPrefix("clipboard: left the iMac's over 10 KB"))
        // The exact length never appears.
        XCTAssertFalse(Session.pweClipboardLogLine(sent: true, byteCount: 12).contains("12"))
    }
}
