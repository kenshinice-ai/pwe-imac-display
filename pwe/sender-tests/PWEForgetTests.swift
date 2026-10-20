import XCTest
@testable import TargetBridge

/// Settings › Advanced › Forget (T37, test Mac 2026-10-21): the iMac's keychain
/// item `peer.<key id>` and every `pwe.pairedReceiverHints` entry naming that
/// key go; a failure says so; an encrypted session with that iMac ends.
/// Keychain items go under a throwaway service name and are deleted afterwards.
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEForgetTests: XCTestCase {
    private var store: PWEPairingStore!
    private var defaults: UserDefaults!
    private var service = ""

    override func setUp() {
        super.setUp()
        service = "com.pwegroup.pweimacdisplay.test.\(UUID().uuidString).forget"
        defaults = UserDefaults(suiteName: service)!
        store = PWEPairingStore(service: service, defaults: defaults)
    }

    override func tearDown() {
        store.deleteEverything()
        defaults.removePersistentDomain(forName: service)
        store = nil
        super.tearDown()
    }

    /// Stores a peer the way a finished pairing does; returns its key id (hex).
    private func pair(_ name: String) throws -> String {
        var pub = [UInt8](repeating: 0, count: Int(PWE_SEC_KEY_BYTES))
        for index in pub.indices { pub[index] = UInt8.random(in: 0...255) }
        var id = [UInt8](repeating: 0, count: Int(PWE_SEC_ID_BYTES))
        pwe_sec_id_from_public(pub, &id)
        guard pwe_keystore_save_peer(store.keystore, id, pub, name) == 0 else {
            throw XCTSkip("the login keychain is not writable here (\(store.keystore.pointee.last_status))")
        }
        return PWEPairingStore.hex(Data(id))
    }

    func testForgetDeletesTheKeychainItemAndEveryHintToIt() throws {
        let imac = try pair("LL iMac 2017")
        let other = try pair("Studio iMac")
        store.rememberReceiver(hint: "receiver:238CB1F1-0000-4000-8000-000000000000", id: PWEPairingStore.data(hex: imac)!)
        store.rememberReceiver(hint: "169.254.6.224", id: PWEPairingStore.data(hex: imac)!)
        store.rememberReceiver(hint: "receiver:OTHER", id: PWEPairingStore.data(hex: other)!)
        XCTAssertEqual(Set(store.pairedReceivers().map(\.id)), [imac, other])
        XCTAssertEqual(store.hints(forReceiverID: imac).count, 2)

        XCTAssertTrue(store.forget(receiverID: imac))

        XCTAssertEqual(store.pairedReceivers().map(\.id), [other], "only the forgotten iMac's item goes")
        XCTAssertTrue(store.hints(forReceiverID: imac).isEmpty)
        XCTAssertNil(store.expectedReceiverID(forHint: "receiver:238CB1F1-0000-4000-8000-000000000000"))
        XCTAssertNil(store.expectedReceiverID(forHint: "169.254.6.224"))
        XCTAssertEqual(store.expectedReceiverID(forHint: "receiver:OTHER"), PWEPairingStore.data(hex: other))
        // The keychain itself: no item under peer.<id> any more.
        var pub = [UInt8](repeating: 0, count: Int(PWE_SEC_KEY_BYTES))
        var name = [CChar](repeating: 0, count: Int(PWE_SEC_NAME_MAX) + 1)
        let id = [UInt8](PWEPairingStore.data(hex: imac)!)
        XCTAssertEqual(pwe_keystore_find_peer(store.keystore, id, &pub, &name), 1, "peer.\(imac) is gone")
    }

    func testForgetTakesTheKeyIDInEitherCase() throws {
        let imac = try pair("iMac")
        XCTAssertTrue(store.forget(receiverID: imac.uppercased()))
        XCTAssertTrue(store.pairedReceivers().isEmpty)
    }

    func testForgetRefusesSomethingThatIsNotAKeyID() throws {
        let imac = try pair("iMac")
        store.rememberReceiver(hint: "receiver:238CB1F1", id: PWEPairingStore.data(hex: imac)!)
        // A Bonjour identity is not a key id: refused, nothing changes.
        XCTAssertFalse(store.forget(receiverID: "receiver:238CB1F1"))
        XCTAssertFalse(store.forget(receiverID: String(imac.prefix(16))))
        XCTAssertEqual(store.pairedReceivers().map(\.id), [imac])
        XCTAssertEqual(store.hints(forReceiverID: imac), ["receiver:238CB1F1"])
    }

    // MARK: - Which session ends

    func testOnlyAnEncryptedSessionWithTheForgottenIMacEnds() {
        let imac = PWEPairedReceiver(id: "5c5e75379485c1fbbac84687d3bc01ac", name: "LL iMac 2017", pairedAt: Date())
        let itsKey = PWEPairingStore.data(hex: imac.id)
        let otherKey = PWEPairingStore.data(hex: "00112233445566778899aabbccddeeff")
        let encrypted = PWESecurityState.encrypted(receiverName: "LL iMac 2017")

        XCTAssertTrue(PWEPairingRules.sessionUses(imac, security: encrypted, expectedID: itsKey))
        XCTAssertFalse(PWEPairingRules.sessionUses(imac, security: encrypted, expectedID: otherKey),
                       "another iMac with the same name keeps its session")
        XCTAssertTrue(PWEPairingRules.sessionUses(imac, security: encrypted, expectedID: nil), "no hint: by name")
        XCTAssertFalse(PWEPairingRules.sessionUses(imac, security: .encrypted(receiverName: "Studio iMac"),
                                                   expectedID: nil))
        for security: PWESecurityState in [.none, .negotiating, .unencrypted, .checkingCode] {
            XCTAssertFalse(PWEPairingRules.sessionUses(imac, security: security, expectedID: itsKey), "\(security)")
        }
    }
}
